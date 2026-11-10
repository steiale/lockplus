import Foundation
import LPModel

/// What the copy needs to know about the profile beyond the condition.
struct ProfileContext: Sendable, Equatable {
    var name: String
    /// "Frankfurt" or the endpoint host; nil when unknown.
    var place: String?
    var protocolName: String
    /// The error detail for codes whose copy names a thing (`LPError.detail`).
    var errorDetail: String?
    /// "Last connected yesterday, 1 h 29 m" (row 15).
    var lastSessionSummary: String?

    /// "Work · Frankfurt · WireGuard": a list, not a sentence, so joining is fine for every locale (§8.3).
    var throughWhat: String {
        [name, place, protocolName].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Hero and header copy for one condition (§6.6 "Hero / header copy" column).
struct ConditionCopy: Sendable, Equatable {
    /// The state word or headline ("Protected", "Blocked", "Connecting to Work…").
    var title: String
    /// The explanatory line under it.
    var message: String?
    /// Retry or phase line ("Reconnecting… attempt 3 · next try in 20 s"); only where the table says it's real.
    var detail: String?
    /// One-line hint ("On a hotel or café network? Pause protection to sign in.").
    var hint: String?
}

extension ConnectionCondition {
    func copy(for p: ProfileContext, now: Date = Date()) -> ConditionCopy {
        let name = p.name
        switch self {
        case .extensionNotReady(let r):
            switch r {
            case .needsUserApproval:
                return ConditionCopy(title: String(localized: "The tunnel component isn't allowed yet", comment: "Row 1"),
                                     message: String(localized: "If the switch turned itself off, turn it on again.", comment: "Row 1, macOS 27 approval hint (§6.14)"))
            case .disabledByUser:
                return ConditionCopy(title: String(localized: "The tunnel component is turned off in System Settings", comment: "Row 1"))
            case .removedDuringUpdate:
                return ConditionCopy(title: String(localized: "The tunnel component was removed during the update", comment: "Row 1"),
                                     message: String(localized: "Approve it again to reconnect.", comment: "Row 1"))
            case .failed:
                return ConditionCopy(title: String(localized: "The tunnel component is damaged", comment: "Row 1"),
                                     message: String(localized: "Reinstall it to connect again.", comment: "Row 1"))
            case .rebootRequired:
                return ConditionCopy(title: String(localized: "Restart your Mac to finish installing the tunnel component", comment: "Row 1, will complete after reboot"),
                                     message: String(localized: "LockPlus can connect after the restart.", comment: "Row 1, reboot"))
            case .ready, .activating, .updateFailed:
                return ConditionCopy(title: String(localized: "Not protected", comment: "State word"))
            }
        case .paused(let until):
            let left = DurationFormat.short(DurationFormat.minutesLeft(until: until, now: now))
            return ConditionCopy(title: String(localized: "Paused — \(left) left", comment: "Row 2; the argument is a duration like '12 min'"),
                                 message: String(localized: "Your Mac is not protected.", comment: "Row 2"))
        case .authMidStart(let approval, let blocked):
            return ConditionCopy(
                title: approval ? String(localized: "Waiting for sign-in approval…", comment: "Row 3, AUTH_PENDING")
                                : String(localized: "Sign in to connect \(name).", comment: "Row 3: the prompt answers into the pending connect"),
                message: blocked ? String(localized: "No traffic leaves this Mac until you sign in or disconnect.", comment: "Row 3 with kill switch (S2 E14a: blocked)")
                                 : String(localized: "\(name) is waiting for you to sign in.", comment: "Row 3"))
        case .blockedBeforeConnected(let e, let attempt, let next):
            return ConditionCopy(title: String(localized: "Blocked", comment: "State word"),
                                 message: String(localized: "\(name) couldn't connect: \(e.reason(detail: p.errorDetail)). No traffic leaves this Mac.", comment: "Row 3a"),
                                 detail: attempt > 0 ? Self.retryLine(attempt: attempt, next: next, now: now, firstConnect: true) : nil)
        case .nonRetryableBeforeConnected(let e, _), .heldNonRetryable(let e, _), .startLatched(let e):
            return ConditionCopy(title: e.message(detail: p.errorDetail),
                                 message: String(localized: "Auto-connect is paused for \(name).", comment: "Rows 3b, 8, 13a"))
        case .switching(let target):
            return ConditionCopy(title: String(localized: "Switching to \(target) — not protected for a moment.", comment: "§6.2 profile switch"))
        case .connecting(let phase):
            return ConditionCopy(title: String(localized: "Connecting to \(name)…", comment: "Row 4"), detail: phase.phaseLine)
        case .tunnelProcessReconnecting:
            return ConditionCopy(title: String(localized: "Reconnecting to the tunnel process…", comment: "Row 4a"),
                                 message: String(localized: "macOS still reports the VPN as connected.", comment: "Row 4a"))
        case .tunnelProcessUnresponsive:
            return ConditionCopy(title: String(localized: "\(name)'s tunnel process isn't responding.", comment: "Row 4a, link unavailable"))
        case .protectedDNSWarning(let dns):
            return ConditionCopy(title: String(localized: "Protected", comment: "State word"),
                                 message: p.throughWhat,
                                 detail: dns == .overridden ? String(localized: "DNS overridden by another profile", comment: "Row 5")
                                                            : String(localized: "Couldn't verify DNS", comment: "Row 5"))
        case .protected:
            return ConditionCopy(title: String(localized: "Protected", comment: "State word"), message: p.throughWhat)
        case .blockedAfterFailure(let e):
            return ConditionCopy(title: String(localized: "Blocked", comment: "State word"),
                                 message: String(localized: "\(name) stopped: \(e.reason(detail: p.errorDetail)). No traffic leaves this Mac.", comment: "Row 7. No retry text."))
        case .reconnectNeedsCode:
            return ConditionCopy(title: String(localized: "Enter a new code to reconnect \(name).", comment: "Row 9"),
                                 message: String(localized: "Traffic is blocked meanwhile.", comment: "Row 9"),
                                 hint: String(localized: "Your server asks for a new code on reconnect.", comment: "§6.5"))
        case .blockedReconnecting(let attempt, let next):
            return ConditionCopy(title: String(localized: "Blocked", comment: "State word"),
                                 message: String(localized: "\(name) lost its connection. No traffic leaves this Mac until LockPlus reconnects.", comment: "Row 10"),
                                 detail: Self.retryLine(attempt: attempt, next: next, now: now),
                                 hint: String(localized: "On a hotel or café network? Pause protection to sign in.", comment: "Row 10"))
        case .reconnecting(let attempt):
            return ConditionCopy(title: String(localized: "Reconnecting \(name)…", comment: "Row 11"),
                                 detail: attempt > 0 ? String(localized: "Attempt \(Int(attempt))", comment: "Row 11 retry count") : nil)
        case .disconnecting:
            return ConditionCopy(title: String(localized: "Disconnecting…", comment: "Row 12"))
        case .startHeld(let h):
            switch h.reason {
            case .preparing, .readingDisconnect:
                return ConditionCopy(title: String(localized: "Preparing to connect \(h.name)…", comment: "Row 12a: the app prepares a start (verify, pause other auto-connect, settle); no NEVPNStatus yet, so never 'Connecting'"),
                                     message: String(localized: "Not protected yet.", comment: "Row 12a, preparing"))
            case .waitingForStop(let old):
                return ConditionCopy(title: String(localized: "Waiting for \(old) to disconnect…", comment: "Row 12a: a start waits until macOS has stopped the old session; the argument is a profile name"),
                                     message: String(localized: "Then LockPlus connects \(h.name). Not protected meanwhile.", comment: "Row 12a, waiting for a stop"))
            case .awaitingRestart:
                return ConditionCopy(title: String(localized: "Waiting for \(h.name)'s tunnel process to restart…", comment: "Row 12a: after a tunnel-process crash, the restart is awaited (≤ 30 s)"),
                                     message: String(localized: "Not protected until \(h.name) is back.", comment: "Row 12a, awaiting a restart; the argument is a profile name"))
            case .mayRestart:
                return ConditionCopy(title: String(localized: "Checking whether \(h.name) restarts…", comment: "Row 12a: a kill-switch profile stopped with an error that may be a tunnel-process crash; macOS may restart it (≤ 10 s). The argument is a profile name"),
                                     message: String(localized: "\(h.name) stopped unexpectedly. Not protected meanwhile.", comment: "Row 12a, a restart may follow; the argument is a profile name"))
            case .startEndedEarly:
                return ConditionCopy(title: String(localized: "Checking whether \(h.name) starts…", comment: "Row 12a: LockPlus's own start ended before any status; macOS may still start the profile (≤ 10 s). The argument is a profile name"),
                                     message: String(localized: "The start ended early. Not protected meanwhile.", comment: "Row 12a, the start ended early; a start by macOS may follow"))
            case .waitingForNetwork:
                return ConditionCopy(title: String(localized: "Waiting for a network to connect \(h.name)…", comment: "Row 12a (E2E-4 200011): the Mac has no network; LockPlus starts the profile when one is available. The argument is a profile name"),
                                     message: String(localized: "Not protected until a network is available.", comment: "Row 12a, waiting for a network"))
            case .awaitingNetwork:
                return ConditionCopy(title: String(localized: "\(h.name) connects when a network is available.", comment: "Row 12a (E2E-4 200011): macOS refused the start for want of a network and starts the profile by itself when one returns. The argument is a profile name"),
                                     message: String(localized: "Not protected until a network is available.", comment: "Row 12a, waiting for a network"))
            }
        case .stoppedWithError(let e):
            return ConditionCopy(title: e.message(detail: p.errorDetail),
                                 message: String(localized: "Not protected.", comment: "Row 14"))
        case .unprotected:
            return ConditionCopy(title: String(localized: "Not protected", comment: "State word"), message: p.lastSessionSummary)
        }
    }

    /// The menu header (§6.2) is never truncated: it grows to its text. Rows whose hero title is a long sentence get
    /// a short header title here; the full sentence moves to the message line or stays in the hero and window.
    func headerCopy(for p: ProfileContext, now: Date = Date()) -> ConditionCopy {
        switch self {
        case .extensionNotReady(let r):
            let full = copy(for: p, now: now)
            let title: String? = switch r {
            case .needsUserApproval: String(localized: "Tunnel component not allowed", comment: "Menu header, row 1 (short for 'The tunnel component isn't allowed yet')")
            case .disabledByUser: String(localized: "Tunnel component turned off", comment: "Menu header, row 1 (short for 'The tunnel component is turned off in System Settings')")
            case .removedDuringUpdate: String(localized: "Tunnel component removed", comment: "Menu header, row 1 (short for 'The tunnel component was removed during the update')")
            case .failed: String(localized: "Tunnel component damaged", comment: "Menu header, row 1 (short for 'The tunnel component is damaged')")
            case .rebootRequired: String(localized: "Restart needed", comment: "Menu header, row 1 (short for 'Restart your Mac to finish installing the tunnel component')")
            case .ready, .activating, .updateFailed: nil
            }
            guard let title else { return full }
            return ConditionCopy(title: title, message: full.message)
        case .nonRetryableBeforeConnected(let e, _), .heldNonRetryable(let e, _), .startLatched(let e):
            return ConditionCopy(title: String(localized: "Auto-connect paused for \(p.name)", comment: "Menu header, rows 3b, 8, 13a; the error sentence follows below"),
                                 message: e.message(detail: p.errorDetail))
        case .switching(let target):
            return ConditionCopy(title: String(localized: "Switching to \(target)…", comment: "Menu header, profile switch; the argument is a profile name"),
                                 message: String(localized: "Not protected for a moment.", comment: "Menu header, profile switch"))
        case .tunnelProcessReconnecting:
            return ConditionCopy(title: String(localized: "Reconnecting…", comment: "Menu header, row 4a (short for 'Reconnecting to the tunnel process…')"),
                                 message: String(localized: "macOS still reports the VPN as connected.", comment: "Row 4a"))
        case .tunnelProcessUnresponsive:
            return ConditionCopy(title: String(localized: "\(p.name) isn't responding", comment: "Menu header, row 4a, link unavailable; the argument is a profile name"),
                                 message: String(localized: "The tunnel process doesn't answer.", comment: "Menu header, row 4a, link unavailable"))
        case .reconnectNeedsCode:
            return ConditionCopy(title: String(localized: "New code needed for \(p.name)", comment: "Menu header, row 9; the argument is a profile name"),
                                 message: String(localized: "Traffic is blocked meanwhile.", comment: "Row 9"))
        case .stoppedWithError(let e):
            return ConditionCopy(title: String(localized: "Stopped, not protected", comment: "Menu header, row 14; the error sentence follows below"),
                                 message: e.message(detail: p.errorDetail))
        case .blockedReconnecting(let attempt, let next):
            return ConditionCopy(title: String(localized: "Blocked — reconnecting \(p.name)", comment: "Menu header, row 10"),
                                 message: String(localized: "No traffic leaves this Mac", comment: "Menu header, row 10"),
                                 detail: Self.retryLine(attempt: attempt, next: next, now: now))
        case .unprotected:
            return ConditionCopy(title: String(localized: "Not protected", comment: "State word"), message: p.name)
        case .startHeld(let h):
            // Row 12a in 300 pt (German runs 30–40 % longer): the profile only, the message as in the hero.
            let full = copy(for: p, now: now)
            let title = switch h.reason {
            case .preparing, .readingDisconnect: String(localized: "Preparing \(h.name)…", comment: "Menu header, row 12a: a start is prepared (never 'Connecting')")
            case .waitingForStop(let old): String(localized: "Waiting for \(old) to disconnect…", comment: "Row 12a: a start waits until macOS has stopped the old session; the argument is a profile name")
            case .awaitingRestart: String(localized: "Waiting for \(h.name) to restart…", comment: "Menu header, row 12a: a crash restart is awaited")
            case .startEndedEarly: String(localized: "Checking \(h.name)…", comment: "Menu header, row 12a: macOS may still start the profile after the start ended early")
            case .mayRestart: String(localized: "Checking \(h.name)…", comment: "Menu header, row 12a: macOS may restart the profile after an unexpected stop")
            case .waitingForNetwork, .awaitingNetwork: String(localized: "Waiting for a network…", comment: "Menu header, row 12a (E2E-4 200011): a start waits for a network")
            }
            return ConditionCopy(title: title, message: full.message)
        case .protected:
            return ConditionCopy(title: String(localized: "Protected", comment: "State word"),
                                 message: [p.name, p.protocolName].joined(separator: " · "))
        default:
            var c = copy(for: p, now: now)
            c.hint = nil
            return c
        }
    }

    /// `firstConnect`: row 3a (a held start retrying) says "Retrying", not "Reconnecting".
    static func retryLine(attempt: UInt32, next: Date?, now: Date, firstConnect: Bool = false) -> String? {
        if firstConnect {
            if let next, next > now {
                let wait = DurationFormat.seconds(next.timeIntervalSince(now).rounded(.up))
                return String(localized: "Retrying… attempt \(Int(attempt)) · next try in \(wait)", comment: "Row 3a retry line; the second argument is like '20 sec'")
            }
            return String(localized: "Retrying… attempt \(Int(attempt))", comment: "Row 3a retry line while the attempt runs")
        }
        guard attempt > 0 else { return String(localized: "Reconnecting…", comment: "Row 10 before the first retry") }
        if let next, next > now {
            let wait = DurationFormat.seconds(next.timeIntervalSince(now).rounded(.up))
            return String(localized: "Reconnecting… attempt \(Int(attempt)) · next try in \(wait)", comment: "Row 10 retry line; the second argument is like '20 sec'")
        }
        return String(localized: "Reconnecting… attempt \(Int(attempt))", comment: "Row 10 retry line without a countdown")
    }

    /// Status item accessibility label: one wording everywhere (§6.1, DESIGN §11.6).
    func statusItemAccessibilityLabel(for p: ProfileContext, rate: Rate?, now: Date = Date()) -> String {
        switch self {
        case .protected, .protectedDNSWarning:
            if let rate {
                return String(localized: "LockPlus, protected, \(p.name), download \(RateFormat.spoken(rate.down)), upload \(RateFormat.spoken(rate.up)).", comment: "Status item VoiceOver label")
            }
            return String(localized: "LockPlus, protected, \(p.name).", comment: "Status item VoiceOver label")
        case .blockedReconnecting:
            return String(localized: "LockPlus, blocked, waiting to reconnect \(p.name).", comment: "Status item VoiceOver label")
        case .blockedAfterFailure(let e):
            return String(localized: "LockPlus, blocked, \(p.name) stopped: \(e.reason(detail: p.errorDetail)).", comment: "Status item VoiceOver label")
        case .blockedBeforeConnected(let e, _, _):
            return String(localized: "LockPlus, blocked, \(p.name) couldn't connect: \(e.reason(detail: p.errorDetail)).", comment: "Status item VoiceOver label")
        case .heldNonRetryable(let e, let blocked), .nonRetryableBeforeConnected(let e, let blocked):
            return blocked
                ? String(localized: "LockPlus, blocked, \(p.name) stopped: \(e.reason(detail: p.errorDetail)). Auto-connect is paused.", comment: "Status item VoiceOver label, held non-retryable with kill switch")
                : String(localized: "LockPlus, not protected, \(p.name) stopped: \(e.reason(detail: p.errorDetail)). Auto-connect is paused.", comment: "Status item VoiceOver label, held non-retryable")
        case .authMidStart, .reconnectNeedsCode:
            return String(localized: "LockPlus, sign-in required, \(p.name).", comment: "Status item VoiceOver label")
        case .paused(let until):
            let left = DurationFormat.spoken(DurationFormat.minutesLeft(until: until, now: now))
            return String(localized: "LockPlus, paused, \(left) left.", comment: "Status item VoiceOver label; the argument is like '12 minutes'")
        case .connecting, .switching:
            return String(localized: "LockPlus, connecting to \(p.name).", comment: "Status item VoiceOver label")
        case .reconnecting, .tunnelProcessReconnecting:
            return String(localized: "LockPlus, reconnecting \(p.name).", comment: "Status item VoiceOver label")
        case .unprotected, .disconnecting:
            return String(localized: "LockPlus, not protected.", comment: "Status item VoiceOver label")
        default:
            return String(localized: "LockPlus, not protected. \(copy(for: p, now: now).title)", comment: "Status item VoiceOver label with the error headline")
        }
    }

    /// The one-time VoiceOver announcement when the state is entered (§6.6 last bullet). nil: no announcement.
    func announcement(for p: ProfileContext) -> String? {
        switch self {
        case .blockedReconnecting:
            return String(localized: "Blocked. Traffic is held until \(p.name) reconnects.", comment: "VoiceOver announcement, row 10")
        case .blockedAfterFailure(let e):
            return String(localized: "Blocked. \(p.name) stopped because \(e.causeReason(detail: p.errorDetail)). Disconnect to restore internet.", comment: "VoiceOver announcement, row 7")
        case .authMidStart:
            return String(localized: "Sign-in required to connect \(p.name).", comment: "VoiceOver announcement, row 3")
        case .reconnectNeedsCode:
            return String(localized: "Enter a new code to reconnect \(p.name).", comment: "VoiceOver announcement, row 9")
        case .blockedBeforeConnected(let e, _, _):
            return String(localized: "Blocked. \(p.name) couldn't connect because \(e.causeReason(detail: p.errorDetail)). Disconnect to restore internet.", comment: "VoiceOver announcement, row 3a")
        case .protected:
            return String(localized: "Protected.", comment: "VoiceOver announcement on connect")
        case .unprotected:
            return String(localized: "Not protected.", comment: "VoiceOver announcement on disconnect")
        default:
            return nil
        }
    }
}

extension StartHoldUI {
    /// Why Connect is unavailable (help text and tooltip on every disabled Connect, review 5 §3).
    var explanation: String {
        switch reason {
        case .preparing:
            String(localized: "LockPlus is preparing to connect \(name).", comment: "Help on a disabled Connect while a start is prepared (review 5)")
        case .waitingForStop(let old):
            String(localized: "LockPlus is waiting for \(old) to disconnect, then connects \(name).", comment: "Help on a disabled Connect while a start waits for a stop (review 5)")
        case .awaitingRestart:
            String(localized: "LockPlus is waiting for \(name)'s tunnel process to restart.", comment: "Help on a disabled Connect while a crash restart is awaited (review 5)")
        case .readingDisconnect:
            String(localized: "LockPlus is checking why \(name) stopped.", comment: "Help on a disabled Connect while the cause of a disconnect is read (review 5)")
        case .startEndedEarly:
            String(localized: "LockPlus is checking whether \(name)'s tunnel process starts.", comment: "Help on a disabled Connect while the start ended early and macOS may still start it (L-3 copy)")
        case .mayRestart:
            String(localized: "LockPlus is checking whether \(name)'s tunnel process restarts.", comment: "Help on a disabled Connect while a restart by macOS may follow an unexpected stop (review e321e10)")
        case .waitingForNetwork:
            String(localized: "LockPlus connects \(name) when a network is available.", comment: "Help on a disabled Connect while a start waits for a network (E2E-4 200011)")
        case .awaitingNetwork:
            String(localized: "\(name) connects when a network is available.", comment: "Help on a disabled Connect while macOS starts the profile once a network returns (E2E-4 200011)")
        }
    }
}

extension TunnelPhaseUI {
    /// Phase line under "Connecting to Work…" (§6.4 hero states).
    var phaseLine: String? {
        switch self {
        case .starting: String(localized: "Starting the tunnel…", comment: "Connect phase line")
        case .connecting: String(localized: "Contacting the server…", comment: "Connect phase line")
        case .establishing: String(localized: "Waiting for handshake…", comment: "Connect phase line")
        case .awaitingAuth: String(localized: "Waiting for sign-in…", comment: "Connect phase line")
        default: nil
        }
    }
}

/// A throughput pair in bytes per second.
struct Rate: Sendable, Equatable {
    var down: Double
    var up: Double
}
