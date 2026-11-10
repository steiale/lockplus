import Foundation
import LPModel

// Inputs of the derived-state table (UI-CONCEPT §6.6, DESIGN §11.2). These are UI-side mirrors of the engine and
// store types, so the table is a pure function that tests can drive without NetworkExtension objects or XPC.
// The stores (ConnectionStore, ExtensionStore, PauseStore, AuthCoordinator) map their values into these.

/// Mirror of `NEVPNStatus` (mapping in `TunnelStatus+NE.swift`).
enum TunnelStatus: Sendable, Equatable, CaseIterable {
    case invalid, disconnected, connecting, connected, reasserting, disconnecting
}

/// `ExtensionStore.state` as far as the UI cares (DESIGN §4.2). Row 1 covers the last four.
enum ExtensionReadiness: Sendable, Equatable, CaseIterable {
    case ready
    case activating
    case needsUserApproval
    case disabledByUser
    case removedDuringUpdate
    case failed
    /// `.willCompleteAfterReboot`: approved, but macOS finishes the install at the next restart.
    case rebootRequired
    /// E2E-4 (U15): the update of the extension failed; the previous one still runs the profiles (NE starts them), but
    /// the app can't reach it over XPC. Not row 1: Connect works; the window says so (`WindowBanners`).
    case updateFailed

    var blocksTunnel: Bool {
        switch self {
        case .needsUserApproval, .disabledByUser, .removedDuringUpdate, .failed, .rebootRequired: true
        case .ready, .activating, .updateFailed: false
        }
    }
}

/// The XPC client's link status as exposed by `ExtensionStore` (DESIGN §5.4, draft 7).
enum XPCLinkState: Sendable, Equatable {
    case validated, reconnecting, unavailable
}

/// `DNSVerifier` result (UI-CONCEPT §6.4). `.pending` means "not checked yet" and never flags anything.
enum DNSVerdict: Sendable, Equatable {
    case pending, verified, overridden, unverified
}

/// Mirror of `TunnelPhase` (DESIGN §5.2).
enum TunnelPhaseUI: String, Sendable, Equatable {
    case idle, starting, connecting, awaitingAuth, establishing, connected, reasserting, sleeping, held, stopping
}

/// Mirror of `HoldReason` (DESIGN §5.2).
enum HoldReasonUI: Sendable, Equatable {
    case blockedAfterFailure(LPErrorCode)
    case nonRetryable(LPErrorCode)
}

/// Mirror of `StartLatch` (DESIGN §5.2): only the parts the UI reads.
struct StartLatchUI: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case hard, backoff }
    var code: LPErrorCode
    var kind: Kind
}

/// The extension's `TunnelSnapshot` detail the table reads.
struct SnapshotFacts: Sendable, Equatable {
    var phase: TunnelPhaseUI = .idle
    var attempt: UInt32 = 0
    var nextRetryAt: Date?
    var holdReason: HoldReasonUI?
    var holdBeforeConnected = false
    var startLatch: StartLatchUI?
}

/// A `lastError` that passed the input rule (`LastErrorPolicy`), with where it came from.
struct ObservedError: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        /// The provider cancelled an established session (`cancelTunnelWithError`).
        case providerCancel
        /// A start failed before Connected (kill switch off; with it, draft 9 holds the start instead).
        case failedStart
        /// Anything else, or unknown (launch-time snapshot without context).
        case other
    }
    var code: LPErrorCode
    var origin: Origin = .other
    /// Server text for a rejection (AUTH_FAILED reason). Shown verbatim, in quotes, marked as the server's (§8.3).
    var serverReason: String?
}

/// Everything the table reads. One value per active (or last-used) profile.
struct DerivedStateInputs: Sendable, Equatable {
    var profileName: String
    var status: TunnelStatus = .disconnected
    var killSwitch = false
    var lastError: ObservedError?
    /// The user stopped the tunnel (or restored internet) after `lastError` was recorded.
    var userStoppedSinceError = false
    var snapshot = SnapshotFacts()
    /// `AUTH_PENDING`: waiting for a push approval (row 3 copy variant).
    var awaitingApproval = false
    var pausedUntil: Date?
    var extensionReadiness: ExtensionReadiness = .ready
    var link: XPCLinkState = .validated
    var dns: DNSVerdict = .pending
    /// Set by the store while a profile switch is in flight (UI-CONCEPT §6.2): the name of the target profile.
    var switchingTo: String?
    /// Review 5 §3: the app's own start work that holds a Connect back (`ConnectionStore.startHold`), row 12a.
    var startHold: StartHoldUI?
    var now = Date()
}

/// Why a Connect is held back by the app's own work before any NEVPNStatus exists (review 5 §3, UI-CONCEPT §6.6 row
/// 12a): preparing a start (verify, pause the others, settle), waiting for a session to stop, or waiting for NE's (or
/// our) restart after a tunnel-process crash. Not a status: nothing says "Connecting…" for it.
struct StartHoldUI: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case preparing
        /// The name of the profile whose stop is awaited (the held profile itself for a reconnect, N1b).
        case waitingForStop(of: String)
        case awaitingRestart
        /// Review e321e10: NE may restart it (no crash was seen, U10); hedged copy, Cancel ends the wait.
        case mayRestart
        /// Review 5c3a899/f18c0d6 L-3 copy: our own start ended before any status; "the start ended early", not "stopped".
        case startEndedEarly
        /// The cause of a disconnect is being read: only another profile's Connect is held, and no row shows it.
        case readingDisconnect
        /// E2E-4 200011: the Connect waits for a network before anything is started; Cancel ends it.
        case waitingForNetwork
        /// E2E-4 200011: macOS connects the profile by itself when a network is available; Cancel stops it.
        case awaitingNetwork
    }
    /// The profile the hold is about.
    var name: String
    var reason: Reason

    /// Row 12a shows for every reason but `readingDisconnect`.
    var showsRow: Bool { reason != .readingDisconnect }
}

/// The input rule for `lastError` (UI-CONCEPT §6.6, DESIGN §5.5, S12): `fetchLastDisconnectError` is sticky, so a
/// launch-time error is only shown with a start latch, or when it is newer than the last quit.
enum LastErrorPolicy {
    enum Source: Sendable, Equatable {
        /// From `fetchLastDisconnectError` after a `.disconnected` transition this app instance observed.
        case observedDisconnect
        /// From `tunnelSnapshot.lastError` at launch.
        case launchSnapshot(recordedAt: Date?)
    }

    static func isShowable(source: Source, hasStartLatch: Bool, lastQuitAt: Date?) -> Bool {
        switch source {
        case .observedDisconnect:
            return true
        case .launchSnapshot(let recordedAt):
            if hasStartLatch { return true }
            guard let recordedAt else { return false }
            guard let lastQuitAt else { return true }      // first launch ever: nothing stale to hide
            return recordedAt > lastQuitAt
        }
    }
}
