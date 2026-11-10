import Foundation

// Pure decision logic of the app's SystemExtensionManager (DESIGN §4.1–§4.3, §4.6). Kept free of the
// SystemExtensions framework so every outcome is unit-tested without an activation; the app maps framework values in.

/// (CFBundleShortVersionString, CFBundleVersion) of an extension, compared numerically component by component.
/// Dev builds carry `200000.<stamp>` in CFBundleVersion (§2.6), which sorts above 200000 and below 200001.
public struct ExtensionVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var shortVersion: String
    public var bundleVersion: String

    public init(shortVersion: String, bundleVersion: String) {
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
    }

    public var description: String { "\(shortVersion) (\(bundleVersion))" }

    /// Numeric components; a non-numeric component counts as 0 (never produced by our version scheme).
    static func components(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = components(a), y = components(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func < (a: Self, b: Self) -> Bool {
        switch compare(a.shortVersion, b.shortVersion) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: compare(a.bundleVersion, b.bundleVersion) == .orderedAscending
        }
    }

    /// Numeric equality (so "2.0" == "2.0.0"). The system replaces on ANY string difference; that case only reaches
    /// our replacement callback in developer mode (§4.2 table).
    public func numericallyEqual(_ o: Self) -> Bool { !(self < o) && !(o < self) }
}

/// `actionForReplacingExtension` (§4.2 table, §4.3): a pure compare with no side effects.
public enum ReplacementPolicy {
    public enum Action: Sendable, Equatable { case replace, cancel }

    /// Higher → replace; equal (developer mode only) → replace; lower → cancel (state `.failed(.downgradeRefused)`).
    public static func decide(existing: ExtensionVersion, embedded: ExtensionVersion) -> Action {
        embedded < existing ? .cancel : .replace
    }
}

/// One `OSSystemExtensionProperties` entry, as a Sendable copy.
public struct ExtensionEntry: Sendable, Equatable {
    public var version: ExtensionVersion
    public var isEnabled: Bool
    public var isAwaitingUserApproval: Bool
    public var isUninstalling: Bool

    public init(version: ExtensionVersion, isEnabled: Bool, isAwaitingUserApproval: Bool, isUninstalling: Bool) {
        self.version = version; self.isEnabled = isEnabled
        self.isAwaitingUserApproval = isAwaitingUserApproval; self.isUninstalling = isUninstalling
    }
}

/// §4.2 step 2: what to do after the properties preflight.
public enum ActivationPreflight {
    public enum Decision: Sendable, Equatable {
        /// Submit the activation request (step 4). `quiesce` = an update is pending: run step 3 first.
        case activate(quiesce: Bool)
        /// No enabled entry but owned on-demand managers or a pendingResume/expectedUpdate marker: the extension was
        /// removed before this launch (Finder drag-replace). Set `.removedDuringUpdate`, then activate.
        case removedDuringUpdate
        /// The enabled extension is newer than the embedded one: never submit; `.failed(.olderAppThanExtension)`.
        case refuseOlderApp(installed: ExtensionVersion)
    }

    public struct Result: Sendable, Equatable {
        public var decision: Decision
        /// Some entry awaits approval: show the approval banner rather than a new modal.
        public var awaitingApproval: Bool
    }

    /// - Parameters:
    ///   - entries: the propertiesRequest result, or nil when it timed out (5 s): "unknown", activate without quiescing.
    ///   - hasOnDemandOrResumeMarker: owned managers with on-demand enabled, or a pendingResume/expectedUpdate marker.
    public static func decide(entries: [ExtensionEntry]?, embedded: ExtensionVersion,
                              hasOnDemandOrResumeMarker: Bool) -> Result {
        guard let entries else { return Result(decision: .activate(quiesce: false), awaitingApproval: false) }
        let awaiting = entries.contains { $0.isAwaitingUserApproval }
        guard let enabled = entries.first(where: { $0.isEnabled && !$0.isUninstalling }) else {
            return Result(decision: hasOnDemandOrResumeMarker ? .removedDuringUpdate : .activate(quiesce: false),
                          awaitingApproval: awaiting)
        }
        let decision: Decision
        if enabled.version < embedded { decision = .activate(quiesce: true) }
        else if embedded < enabled.version { decision = .refuseOlderApp(installed: enabled.version) }
        else { decision = .activate(quiesce: false) }
        return Result(decision: decision, awaitingApproval: awaiting)
    }
}

/// Review 5 #3: after the activation watchdog (no callback at all from sysextd), the tunnels are handed back to the
/// installed extension only if a fresh properties read shows it is still the enabled one and nothing waits for the
/// user's approval. A silent sysextd may still finish the replacement, and a late `.completed` would replace the
/// extension under the handed-back tunnels; then the hand-over stays until "Try again".
public enum WatchdogHandBack {
    /// - Parameters:
    ///   - entries: the fresh properties read; nil (timed out) → no hand-back.
    ///   - installed: the version the preflight saw enabled before the quiesce; nil (nothing was quiesced, or the
    ///     preflight timed out) → any enabled entry.
    public static func allowed(entries: [ExtensionEntry]?, installed: ExtensionVersion?) -> Bool {
        guard let entries, !entries.contains(where: \.isAwaitingUserApproval),
              let enabled = entries.first(where: { $0.isEnabled && !$0.isUninstalling }) else { return false }
        return installed.map { enabled.version.numericallyEqual($0) } ?? true
    }
}

/// Terminal failures of the extension lifecycle (§4.1 `failed(ExtensionFailure)`).
public enum ExtensionFailure: Sendable, Equatable, Hashable {
    /// The enabled extension is newer than this app's (user installed an older app). UI offers "Reinstall" (§4.6).
    case olderAppThanExtension(installed: String)
    /// Our own `.cancel` in the replacement callback (cannot normally happen; §4.2).
    case downgradeRefused
    /// "This copy of LockPlus is damaged. Reinstall." (codes 1, 2, 4 on activation, 5–9).
    case broken(code: Int)
    /// `.forbiddenBySystemPolicy` (10): "Your organization blocks this extension."
    case managed
    /// `.unsupportedParentBundleLocation` (3): "Move LockPlus to Applications".
    case notInApplications
    /// `.authorizationRequired` (13), deactivation only: "Administrator approval required", user-initiated retry.
    case authorizationRequired
    /// A 4102 from the extension's reply: "The tunnel component is damaged. Reinstall LockPlus." (§5.4)
    case unauthorizedPeer
}

/// The `OSSystemExtensionError.Code` raw values (SystemExtensions.h). Spelled out so the mapping is testable.
public enum SystemExtensionErrorCode: Int, Sendable, CaseIterable {
    case unknown = 1, missingEntitlement, unsupportedParentBundleLocation, extensionNotFound, extensionMissingIdentifier,
         duplicateExtensionIdentifer, unknownExtensionCategory, codeSignatureInvalid, validationFailed,
         forbiddenBySystemPolicy, requestCanceled, requestSuperseded, authorizationRequired
}

/// §4.2 `didFailWithError` table.
public enum SystemExtensionErrorPolicy {
    public enum Phase: Sendable { case activation, deactivation }
    public enum Outcome: Sendable, Equatable {
        case fail(ExtensionFailure)
        /// 11, 12: the state stays as it was.
        case ignore
        /// 4 on deactivation from an app whose embedded version differs (forum 737969): §4.6 guided manual removal.
        case guidedRemoval
    }

    public static func outcome(code: Int, phase: Phase) -> Outcome {
        guard let c = SystemExtensionErrorCode(rawValue: code) else { return .fail(.broken(code: code)) }
        switch c {
        case .requestCanceled, .requestSuperseded: return .ignore
        case .unsupportedParentBundleLocation: return .fail(.notInApplications)
        case .forbiddenBySystemPolicy: return .fail(.managed)
        case .authorizationRequired: return .fail(.authorizationRequired)
        case .extensionNotFound: return phase == .deactivation ? .guidedRemoval : .fail(.broken(code: code))
        case .unknown, .missingEntitlement, .extensionMissingIdentifier, .duplicateExtensionIdentifer,
             .unknownExtensionCategory, .codeSignatureInvalid, .validationFailed:
            return .fail(.broken(code: code))
        }
    }
}

/// System Settings deep links (§4.2). Undocumented URL: it opens the pane, not the item (forum 765970). On 27 the
/// first toggle may not stick, so the UI keeps a persistent "Show the Switch Again" action with the same URL (D7-13).
public enum SystemSettingsLink {
    public static let extensions = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    public static let textualPath = "System Settings › General › Login Items & Extensions › Network Extensions"
}
