import Foundation
import LPModel

/// The one mapping from engine state to UI state (UI-CONCEPT §6.6, DESIGN §11.2, F-4). The menu bar, the menu
/// header, the hero and the sidebar all read this; nothing else interprets `NEVPNStatus`.
/// Each case is one row of the table; the associated values are what its copy and actions need.
enum ConnectionCondition: Sendable, Equatable {
    /// Row 1: the system extension isn't usable.
    case extensionNotReady(ExtensionReadiness)
    /// Row 2.
    case paused(until: Date)
    /// Row 3: sign-in inside the pending start (draft 9: every first-connect prompt; the answer connects this start).
    case authMidStart(awaitingApproval: Bool, trafficBlocked: Bool)
    /// Row 3a (draft 9, S2 E14): the start is held before Connected after a failure, kill switch on. The extension
    /// retries retryable failures inside the hold (`attempt`/`nextRetryAt`); a non-retryable one waits for Disconnect.
    case blockedBeforeConnected(LPErrorCode, attempt: UInt32, nextRetryAt: Date?)
    /// Row 3b: non-retryable hold before Connected under on-demand.
    case nonRetryableBeforeConnected(LPErrorCode, blocked: Bool)
    /// §6.2 "Switching is an unprotected moment" (not a numbered row; see `derive`).
    case switching(to: String)
    /// Row 4.
    case connecting(phase: TunnelPhaseUI)
    /// Row 4a: macOS still says connected, but the tunnel process link is down.
    case tunnelProcessReconnecting
    /// Row 4a, link `.unavailable`.
    case tunnelProcessUnresponsive
    /// Row 5.
    case protectedDNSWarning(DNSVerdict)
    /// Row 6.
    case protected
    /// Row 7: held after a fatal error, kill switch on. Never shows retry text.
    case blockedAfterFailure(LPErrorCode)
    /// Row 8: held non-retryable error under on-demand.
    case heldNonRetryable(LPErrorCode, blocked: Bool)
    /// Row 9.
    case reconnectNeedsCode
    /// Row 10: reasserting with the kill switch; retry text is real.
    case blockedReconnecting(attempt: UInt32, nextRetryAt: Date?)
    /// Row 11.
    case reconnecting(attempt: UInt32)
    /// Row 12.
    case disconnecting
    /// Row 12a (review 5 §3): not active, and the app's own start work holds a Connect back.
    case startHeld(StartHoldUI)
    /// Row 13a: a hard start latch.
    case startLatched(LPErrorCode)
    /// Row 14.
    case stoppedWithError(LPErrorCode)
    /// Row 15.
    case unprotected
}

/// What a state offers. The order of `ConnectionCondition.actions` is the button order (primary first).
enum StateAction: Sendable, Equatable, Hashable {
    case connect
    case disconnect
    case disconnectAndRestoreInternet
    case cancel
    case enterCode
    case signIn
    case pause
    case resumeNow
    case details
    case runDiagnostics
    case openSystemSettings
    case showSwitchAgain
    case approve
    case reinstall
    /// Row 1 `.rebootRequired`: asks macOS to restart (System Events shows its own confirmation).
    case restartMac
}

extension DerivedStateInputs {
    /// Rows are evaluated in the listed order; the first match wins (UI-CONCEPT §6.6).
    var condition: ConnectionCondition {
        // 1
        if extensionReadiness.blocksTunnel { return .extensionNotReady(extensionReadiness) }
        // 2
        if let pausedUntil, pausedUntil > now { return .paused(until: pausedUntil) }
        // 3: S2 E14a measured `.connecting` as blocked under the kill switch.
        if status == .connecting, snapshot.phase == .awaitingAuth {
            return .authMidStart(awaitingApproval: awaitingApproval, trafficBlocked: killSwitch)
        }
        // 3a / 3b (draft 9, S2 E14: the withheld start): before row 4, also while a held start retries.
        if status == .connecting, let hold = snapshot.holdReason {
            switch hold {
            case .blockedAfterFailure(let e) where killSwitch:
                return .blockedBeforeConnected(e, attempt: snapshot.attempt, nextRetryAt: snapshot.nextRetryAt)
            case .nonRetryable(let e): return .nonRetryableBeforeConnected(e, blocked: killSwitch)
            case .blockedAfterFailure: break
            }
        }
        // Switching (§6.2): "not protected for a moment" until the new status is .connected. Placed before row 4 so
        // the target's .connecting reads as the switch; a failed switch carries lastError and falls through to 13–14.
        // E2E-4 200012 (review 2518e93 #3): the switching row says "Connecting…", so it needs NE's `.connecting` for the
        // target. Before that the app's own work is row 12a ("Waiting for Home NAS to disconnect…", "Preparing…", "Waiting
        // for a network…") or, with no hold to show, the plain status rows (12, 14, 15): UI-CONCEPT allows no
        // "Connecting…" without an NEVPNStatus.
        if let target = switchingTo, lastError == nil, status == .connecting {
            return .switching(to: target)
        }
        switch status {
        case .connecting:
            // 4
            return .connecting(phase: snapshot.phase)
        case .connected:
            // 4a
            if link == .reconnecting { return .tunnelProcessReconnecting }
            // E2E-4 (U15): after a failed update the old extension runs the session but is unreachable over XPC by
            // design; the window banner says why. NE's `.connected` is the truth here, not "isn't responding".
            if link == .unavailable, extensionReadiness != .updateFailed { return .tunnelProcessUnresponsive }
            // 5
            if dns == .overridden || dns == .unverified { return .protectedDNSWarning(dns) }
            // 6
            return .protected
        case .reasserting:
            // 7
            if killSwitch, case .blockedAfterFailure(let e) = snapshot.holdReason { return .blockedAfterFailure(e) }
            // 8
            if case .nonRetryable(let e) = snapshot.holdReason { return .heldNonRetryable(e, blocked: killSwitch) }
            // 9
            if killSwitch, snapshot.phase == .awaitingAuth { return .reconnectNeedsCode }
            // 10
            if killSwitch { return .blockedReconnecting(attempt: snapshot.attempt, nextRetryAt: snapshot.nextRetryAt) }
            // 11
            return .reconnecting(attempt: snapshot.attempt)
        case .disconnecting:
            // 12
            return .disconnecting
        case .disconnected, .invalid:
            // 12a (review 5 §3): before 13a/14/15, so a Connect that would be ignored is never offered.
            if let hold = startHold, hold.showsRow { return .startHeld(hold) }
            guard status == .disconnected else { return .unprotected }      // 15
            // Draft 9 (S2 E3, E14c): `.disconnected` is never blocked, so rows 13 and 13b are gone. With the kill switch
            // the extension never cancels and never fails a start: a failure is held (rows 3a, 7) instead.
            // 13a
            if let latch = snapshot.startLatch, latch.kind == .hard { return .startLatched(latch.code) }
            // 14
            if let e = lastError { return .stoppedWithError(e.code) }
            // 15
            return .unprotected
        }
    }
}

extension ConnectionCondition {
    /// The table's row label, for tests and debug overlays.
    var row: String {
        switch self {
        case .extensionNotReady: "1"
        case .paused: "2"
        case .authMidStart: "3"
        case .blockedBeforeConnected: "3a"
        case .nonRetryableBeforeConnected: "3b"
        case .switching: "switch"
        case .connecting: "4"
        case .tunnelProcessReconnecting, .tunnelProcessUnresponsive: "4a"
        case .protectedDNSWarning: "5"
        case .protected: "6"
        case .blockedAfterFailure: "7"
        case .heldNonRetryable: "8"
        case .reconnectNeedsCode: "9"
        case .blockedReconnecting: "10"
        case .reconnecting: "11"
        case .disconnecting: "12"
        case .startHeld: "12a"
        case .startLatched: "13a"
        case .stoppedWithError: "14"
        case .unprotected: "15"
        }
    }

    /// §7.2 glyph column.
    var glyph: GlyphState {
        switch self {
        case .extensionNotReady: .attention
        case .paused: .paused
        case .authMidStart: .attention
        case .blockedBeforeConnected: .blocked
        case .nonRetryableBeforeConnected(_, let blocked): blocked ? .blocked : .errorStopped
        case .switching: .connecting
        case .connecting: .connecting
        case .tunnelProcessReconnecting, .tunnelProcessUnresponsive: .reasserting
        case .protectedDNSWarning: .attention
        case .protected: .protected
        case .blockedAfterFailure: .blocked
        case .heldNonRetryable(_, let blocked): blocked ? .blocked : .errorStopped
        case .reconnectNeedsCode: .attention
        case .blockedReconnecting: .blocked
        case .reconnecting: .reasserting
        case .disconnecting: .connecting
        case .startHeld: .connecting
        case .startLatched: .errorStopped
        case .stoppedWithError: .errorStopped
        case .unprotected: .unprotected
        }
    }

    /// §6.6 actions column, primary first.
    var actions: [StateAction] {
        switch self {
        case .extensionNotReady(let r):
            switch r {
            case .needsUserApproval: [.openSystemSettings, .showSwitchAgain]
            case .disabledByUser: [.openSystemSettings]
            case .removedDuringUpdate: [.approve]
            case .failed: [.reinstall]
            case .rebootRequired: [.restartMac]
            case .ready, .activating, .updateFailed: []
            }
        case .paused: [.resumeNow]
        case .authMidStart: [.enterCode, .cancel]
        case .blockedBeforeConnected: [.disconnectAndRestoreInternet, .details]
        case .nonRetryableBeforeConnected(let e, _): e.isAuthError ? [.signIn, .disconnect] : [.disconnect, .details]
        case .switching: [.cancel]
        case .connecting: [.cancel]
        case .tunnelProcessReconnecting, .tunnelProcessUnresponsive: [.disconnect, .details]
        case .protectedDNSWarning: [.runDiagnostics, .disconnect]     // §6.6 row 5: Run Diagnostics first
        case .protected: [.disconnect]
        case .blockedAfterFailure: [.disconnectAndRestoreInternet, .details]
        case .heldNonRetryable(let e, _): e.isAuthError ? [.signIn, .disconnect] : [.disconnect, .details]
        case .reconnectNeedsCode: [.enterCode, .disconnect]
        case .blockedReconnecting: [.disconnectAndRestoreInternet, .pause, .details]
        case .reconnecting: [.disconnect]
        case .disconnecting: []
        case .startHeld(let h): h.reason == .awaitingRestart ? [] : [.cancel]     // `.mayRestart`: Cancel ends the wait
        case .startLatched(let e): e.isAuthError ? [.signIn, .details] : [.connect, .details]
        case .stoppedWithError: [.connect, .details]
        case .unprotected: [.connect]
        }
    }

    /// A tunnel is connecting, up, reasserting or held: the header switch shows "on" and the standard item says
    /// "Disconnect <profile>" (§6.2).
    var isActive: Bool {
        switch self {
        case .authMidStart, .blockedBeforeConnected, .nonRetryableBeforeConnected, .switching, .connecting,
             .tunnelProcessReconnecting, .tunnelProcessUnresponsive, .protectedDNSWarning, .protected,
             .blockedAfterFailure, .heldNonRetryable, .reconnectNeedsCode, .blockedReconnecting, .reconnecting:
            true
        case .extensionNotReady, .paused, .disconnecting, .startHeld, .startLatched, .stoppedWithError, .unprotected:
            false
        }
    }

    /// Row 1 (replaces stringly `row == "1"` checks, UI-L19).
    var isExtensionNotReady: Bool { if case .extensionNotReady = self { true } else { false } }

    /// Any blocked row: traffic outside the tunnel is held (§7.2 "Blocked covers every blocked row").
    var isBlocked: Bool { glyph == .blocked }

    /// Pause is not offered in rows 7 and 3a: there is no network problem to sign in to (§6.6).
    var forbidsPause: Bool {
        switch self {
        case .blockedAfterFailure, .blockedBeforeConnected: true
        default: false
        }
    }

    /// The pause rule (§6.2, DESIGN §11.3): shown while a tunnel is connecting, connected, reasserting or held, or
    /// when any profile has on-demand enabled; replaced by "Resume" while paused; otherwise hidden.
    func showsPauseMenu(anyOnDemandEnabled: Bool) -> Bool {
        if case .paused = self { return false }
        if forbidsPause { return false }
        return isActive || anyOnDemandEnabled
    }

    /// The menu bar rate label is shown only while connected (§6.1) and hidden while blocked (§6.6).
    var showsRateLabel: Bool {
        switch self {
        case .protected, .protectedDNSWarning: true
        default: false
        }
    }

    /// Retry text ("attempt 3 · next try in 20 s") is real only while the extension is retrying (rows 10, 11, and
    /// row 3a for a retryable failure).
    var showsRetryText: Bool {
        switch self {
        case .blockedReconnecting, .reconnecting: true
        case .blockedBeforeConnected(_, let attempt, _): attempt > 0
        default: false
        }
    }

    var heroTint: StateTint {
        switch self {
        case .protected, .protectedDNSWarning: .protected
        case .connecting, .switching, .reconnecting, .tunnelProcessReconnecting, .disconnecting, .startHeld: .transition
        case .blockedBeforeConnected, .blockedAfterFailure, .blockedReconnecting,
             .reconnectNeedsCode, .authMidStart, .paused, .extensionNotReady:
            .attention
        case .heldNonRetryable(_, let blocked), .nonRetryableBeforeConnected(_, let blocked):
            blocked ? .attention : .critical
        case .tunnelProcessUnresponsive, .startLatched, .stoppedWithError: .critical
        case .unprotected: .none
        }
    }

    /// The error a critical strip shows (DESIGN §11.7), if any.
    var error: LPErrorCode? {
        switch self {
        case .blockedBeforeConnected(let e, _, _), .nonRetryableBeforeConnected(let e, _), .blockedAfterFailure(let e),
             .heldNonRetryable(let e, _), .startLatched(let e), .stoppedWithError(let e):
            e
        default:
            nil
        }
    }

    /// Whether this state needs a VoiceOver announcement with high priority (§6.6 last bullet, §8.2).
    var announcesWithHighPriority: Bool {
        switch self {
        case .blockedReconnecting, .blockedAfterFailure, .blockedBeforeConnected, .authMidStart, .reconnectNeedsCode:
            true
        default:
            false
        }
    }
}

extension LPErrorCode {
    var isAuthError: Bool {
        switch self {
        case .authFailed, .authRequired, .authTimedOut, .keyPassphraseRequired: true
        default: false
        }
    }
}
