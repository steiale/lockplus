import Foundation
import LPModel

// settings.json, history.json and migration.json (DESIGN §3.2, §3.3, §10.4, §13.1). Every field has a default and
// decoding is lenient PER FIELD (`try? decodeIfPresent`, E2E-4 review L6): an older or newer file, or one field of a
// type this build doesn't expect, never fails the whole file (and never resets the other settings).

struct AutoConnectRules: Codable, Sendable, Equatable {
    var enabled = false
    /// The one on-demand profile (§10.4).
    var profileID: UUID?
    /// ≤ 64 entries, each ≤ 32 bytes UTF-8.
    var trustedSSIDs: [String] = []
    var connectOnUntrustedWiFi = true
    var connectOnEthernet = false
    /// "Pause protection" (§10.4); nil = not paused.
    var pausedUntil: Date?

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        profileID = try? c.decodeIfPresent(UUID.self, forKey: .profileID)
        trustedSSIDs = (try? c.decodeIfPresent([String].self, forKey: .trustedSSIDs)) ?? []
        connectOnUntrustedWiFi = (try? c.decodeIfPresent(Bool.self, forKey: .connectOnUntrustedWiFi)) ?? true
        connectOnEthernet = (try? c.decodeIfPresent(Bool.self, forKey: .connectOnEthernet)) ?? false
        pausedUntil = try? c.decodeIfPresent(Date.self, forKey: .pausedUntil)
    }

    /// The profile the user just turned Auto-Connect on for: the toggle went on, or another profile was picked while
    /// it is on. That is fresh intent, so it ends a "suspended until the next network change" (§10.4, E2E-2).
    static func turnedOn(from old: AutoConnectRules, to new: AutoConnectRules) -> UUID? {
        guard new.enabled, let id = new.profileID, !old.enabled || old.profileID != id else { return nil }
        return id
    }

    /// §3.2 caps.
    static func sanitizedSSIDs(_ s: [String]) -> [String] {
        var out: [String] = []
        for x in s where !x.isEmpty && x.utf8.count <= 32 && !out.contains(x) && out.count < 64 { out.append(x) }
        return out
    }
}

/// §4.2 step 3 / §4.6 step 2: what to restore after the extension is replaced.
struct PendingResume: Codable, Sendable, Equatable {
    enum Reason: String, Codable, Sendable { case extensionUpdate, reinstall }
    var profileID: UUID?
    var onDemandEnabledIDs: [UUID]
    var reason: Reason
}

/// §12.3 step 2 (variant B): Sparkle's postpone hook records the install it is about to perform. The §4.2 preflight
/// treats it as a resume marker; `resumeAfterUpdate()` (or a failed install) clears it.
struct ExpectedUpdate: Codable, Sendable, Equatable {
    var from: String
    var to: String
}

/// §10.4 pause record: what to restore at expiry.
struct PausedState: Codable, Sendable, Equatable {
    var profileID: UUID?
    var onDemandEnabledIDs: [UUID]
    var agentBuild: String
}

struct AppSettings: Codable, Sendable, Equatable {
    /// v2.0 ships English and German (lead decision); an older file's "ko"/"ja" decodes as `.system`.
    enum Language: String, Codable, Sendable { case system, en, de }
    /// §6.14: the window appearance; `.system` follows macOS. Applied through `AppAppearanceApplier`.
    enum Appearance: String, Codable, Sendable { case system, light, dark }
    enum RateLabel: String, Codable, Sendable { case off, download, both }
    enum IconStyle: String, Codable, Sendable { case monochrome, color }
    enum Notifications: String, Codable, Sendable { case problemsOnly, connectDisconnect, off }
    enum Level: String, Codable, Sendable { case error, warning, info, debug }

    /// 2: the menu bar icon default became the colour tile (UI review 2026-11-09); see `init(from:)`.
    static let currentSchema = 2
    var schema = AppSettings.currentSchema
    var language: Language = .system
    var appearance: Appearance = .system
    var menuBarRateLabel: RateLabel = .both
    var menuBarIconStyle: IconStyle = .color
    var openWindowAtLogin = false
    var notifications: Notifications = .problemsOnly
    var receiveReleaseCandidates = false
    var logLevel: Level = .info
    var onboardingComplete = false
    var supportNoteShown = false
    /// E2E-5 F5: LockPlus 1.0.x's LaunchAgent was retired; the "Open LockPlus at login?" offer stays until answered
    /// (pre-release review LOW: it lived only in memory, so a quit before answering lost both).
    var launchAtLoginOffer = false
    /// Last launches in which the menu was opened (§11.3 visibility policy); ≤ 5 entries.
    var menuOpenedLaunches: [Date] = []
    /// Launch timestamps, newest last (≤ 5), for the "menu not opened in the last 5 launches" rule.
    var launches: [Date] = []
    /// 2.0.1 E2E: the build (`CFBundleVersion`) of the last launch; a different one is a first launch or an update, and
    /// the main window opens (UI-CONCEPT §11.3 visibility: "opens once on first launch and after every update").
    var lastLaunchedBuild: String?
    var autoConnect = AutoConnectRules()
    var newProfileDefaults = NetworkPolicy(killSwitch: true)
    /// §5.5 / §11.2: a launch-time snapshot error is shown only if it is newer than this.
    var lastQuitAt: Date?
    var lastUsedProfileID: UUID?
    var pausedState: PausedState?
    var pendingResume: PendingResume?
    var expectedUpdate: ExpectedUpdate?
    /// §10.4: on-demand turned off by a user Disconnect, "until the next network change" (review H2).
    var onDemandSuspended: [UUID] = []
    /// The network signature when it was suspended; a different one restores on-demand.
    var onDemandSuspendedNetwork: String?
    /// E2E-3 / review 2026-10-30: the configurations whose on-demand a start turned off (or a restore still owes),
    /// recorded BEFORE the pause. Restored exactly, then cleared, when nothing else is active or starting; kept until
    /// a restore succeeds (and across a quit or crash).
    var onDemandPausedByStart: [UUID] = []
    /// E2E-4 200011: the kill-switch profile whose session NE refused or ended with "No network available"
    /// (`NEVPNConnectionErrorDomain` 2) and restarts by itself once an interface returns. While set (and still
    /// applicable), nothing paused is restored, at launch and by the headless resume too. Written durably when the hold
    /// begins; cleared when NE's restart is active, the user stops it, or the fallback after the network's return ends it.
    var networkRestartHold: UUID?

    /// §12.3, review N2: between `quiesce` (or Sparkle's `prepareForInstall`) and `resumeAfterUpdate` no configuration's
    /// on-demand is turned on (`ProfilesStore.onDemandPlan` holds it) and nothing is restored or dropped from the pause
    /// record; `resumeAfterUpdate` hands everything back through the record.
    var extensionHandOver: Bool { pendingResume != nil || expectedUpdate != nil }

    /// Ends "suspended until the next network change" for `ids` (the network is forgotten with the last one).
    mutating func endOnDemandSuspension(_ ids: [UUID]) {
        onDemandSuspended.removeAll { ids.contains($0) }
        if onDemandSuspended.isEmpty { onDemandSuspendedNetwork = nil }
    }
    /// §6.4 step 4: extension removals that failed, retried on the next reconcile.
    var pendingRemovals: [UUID] = []
    /// User-defined sidebar order (default alphabetical).
    var profileOrder: [UUID] = []

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = AppSettings()
        schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? 1
        language = (try? c.decodeIfPresent(Language.self, forKey: .language)) ?? def.language
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? def.appearance
        menuBarRateLabel = (try? c.decodeIfPresent(RateLabel.self, forKey: .menuBarRateLabel)) ?? def.menuBarRateLabel
        menuBarIconStyle = (try? c.decodeIfPresent(IconStyle.self, forKey: .menuBarIconStyle)) ?? def.menuBarIconStyle
        openWindowAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .openWindowAtLogin)) ?? false
        notifications = (try? c.decodeIfPresent(Notifications.self, forKey: .notifications)) ?? def.notifications
        receiveReleaseCandidates = (try? c.decodeIfPresent(Bool.self, forKey: .receiveReleaseCandidates)) ?? false
        logLevel = (try? c.decodeIfPresent(Level.self, forKey: .logLevel)) ?? def.logLevel
        onboardingComplete = (try? c.decodeIfPresent(Bool.self, forKey: .onboardingComplete)) ?? false
        supportNoteShown = (try? c.decodeIfPresent(Bool.self, forKey: .supportNoteShown)) ?? false
        launchAtLoginOffer = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLoginOffer)) ?? false
        menuOpenedLaunches = (try? c.decodeIfPresent([Date].self, forKey: .menuOpenedLaunches)) ?? []
        launches = (try? c.decodeIfPresent([Date].self, forKey: .launches)) ?? []
        lastLaunchedBuild = try? c.decodeIfPresent(String.self, forKey: .lastLaunchedBuild)
        autoConnect = (try? c.decodeIfPresent(AutoConnectRules.self, forKey: .autoConnect)) ?? AutoConnectRules()
        newProfileDefaults = (try? c.decodeIfPresent(NetworkPolicy.self, forKey: .newProfileDefaults)) ?? def.newProfileDefaults
        lastQuitAt = try? c.decodeIfPresent(Date.self, forKey: .lastQuitAt)
        lastUsedProfileID = try? c.decodeIfPresent(UUID.self, forKey: .lastUsedProfileID)
        pausedState = try? c.decodeIfPresent(PausedState.self, forKey: .pausedState)
        pendingResume = try? c.decodeIfPresent(PendingResume.self, forKey: .pendingResume)
        expectedUpdate = try? c.decodeIfPresent(ExpectedUpdate.self, forKey: .expectedUpdate)
        onDemandSuspended = (try? c.decodeIfPresent([UUID].self, forKey: .onDemandSuspended)) ?? []
        onDemandSuspendedNetwork = try? c.decodeIfPresent(String.self, forKey: .onDemandSuspendedNetwork)
        onDemandPausedByStart = (try? c.decodeIfPresent([UUID].self, forKey: .onDemandPausedByStart)) ?? []
        networkRestartHold = try? c.decodeIfPresent(UUID.self, forKey: .networkRestartHold)
        pendingRemovals = (try? c.decodeIfPresent([UUID].self, forKey: .pendingRemovals)) ?? []
        profileOrder = (try? c.decodeIfPresent([UUID].self, forKey: .profileOrder)) ?? []
        // Schema 1 wrote the default (monochrome) into every file, so a stored "monochrome" can't be told from "never
        // changed": it moves to the new default. Any choice made from schema 2 on is kept as stored.
        if schema < 2 {
            if menuBarIconStyle == .monochrome { menuBarIconStyle = .color }
            schema = Self.currentSchema
        }
    }

    /// §11.3 visibility (2.0.1 E2E): the first launch of a build (a first launch or an update) opens the main window.
    static func isNewBuildLaunch(previous: String?, current: String) -> Bool { previous != current }

    /// §11.3 item 2: the menu wasn't opened in any of the last 5 launches.
    var iconMayBeHidden: Bool {
        guard launches.count >= 5, let oldest = launches.suffix(5).first else { return false }
        return !menuOpenedLaunches.contains { $0 >= oldest }
    }
}

/// §3.2 history entry (capped at 500).
struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    enum EndReason: Codable, Sendable, Equatable {
        case user, error(Int), sleep, onDemand, replaced, other
        init(summary s: String) {
            switch s {
            case "user": self = .user
            case "sleep": self = .sleep
            case "onDemand": self = .onDemand
            case "replaced": self = .replaced
            default:
                if s.hasPrefix("error:"), let n = Int(s.dropFirst(6)) { self = .error(n) } else { self = .other }
            }
        }
    }
    let id: UUID
    var profileID: UUID?
    var profileName: String
    var start: Date
    var end: Date?
    var rxBytes: UInt64
    var txBytes: UInt64
    var endReason: EndReason

    static let cap = 500
}

/// migration.json (§13.1 step 9). Automatic migration runs only while no COMPLETE marker exists. E2E-5 F4: the file is
/// written after every step with `complete == false`, so an interrupted migration (the app killed during the saved-
/// password prompt) is resumed instead of lost; files from before carry no `complete` and were complete.
struct MigrationMarker: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable {
        var oldName: String
        var newID: UUID?
        var digest: String?
        var result: String
    }
    /// When the migration finished; while `complete` is false, the time of the last step.
    var completedAt: Date
    var source: String
    var items: [Item]
    var complete = true
    /// The finished steps of an incomplete migration (`Step.rawValue`).
    var steps: [String] = []

    enum Step: String, Sendable { case credentials, settings, history }

    init(completedAt: Date, source: String, items: [Item], complete: Bool = true, steps: [String] = []) {
        self.completedAt = completedAt
        self.source = source
        self.items = items
        self.complete = complete
        self.steps = steps
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        completedAt = try c.decode(Date.self, forKey: .completedAt)
        source = try c.decode(String.self, forKey: .source)
        items = try c.decode([Item].self, forKey: .items)
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? true
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
    }

    func did(_ step: Step) -> Bool { steps.contains(step.rawValue) }

    /// One item per old tunnel: a retried tunnel's result replaces its earlier one (pre-release review LOW).
    mutating func record(_ item: Item) {
        items.removeAll { $0.oldName == item.oldName }
        items.append(item)
    }
}
