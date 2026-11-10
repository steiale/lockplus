import AppKit
import CoreText
import Foundation
import LPModel
import Testing
@testable import LockPlus

/// UI-CONCEPT §6.6 / DESIGN §15.1: one test per row of the derived-state table, plus the ordering and the
/// invariants the table promises ("held" never shows retry text, Pause is not offered in 7/13/13b, …).
@MainActor @Suite("Derived state (§6.6)")
struct DerivedStateTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func inputs(_ configure: (inout DerivedStateInputs) -> Void) -> DerivedStateInputs {
        var i = DerivedStateInputs(profileName: "Work")
        i.now = now
        configure(&i)
        return i
    }

    let work = ProfileContext(name: "Work", place: "Frankfurt", protocolName: "WireGuard")

    // MARK: Row by row

    @Test("Row 1: extension not ready, per sub-state", arguments: [
        (ExtensionReadiness.needsUserApproval, [StateAction.openSystemSettings, .showSwitchAgain], "The tunnel component isn't allowed yet"),
        (.disabledByUser, [.openSystemSettings], "The tunnel component is turned off in System Settings"),
        (.removedDuringUpdate, [.approve], "The tunnel component was removed during the update"),
        (.failed, [.reinstall], "The tunnel component is damaged"),
        (.rebootRequired, [.restartMac], "Restart your Mac to finish installing the tunnel component"),
    ])
    func row1(readiness: ExtensionReadiness, actions: [StateAction], title: String) {
        // Row 1 wins over everything, even a connected tunnel.
        let c = inputs { $0.extensionReadiness = readiness; $0.status = .connected }.condition
        #expect(c.row == "1")
        #expect(c.glyph == .attention)
        #expect(c.actions == actions)
        #expect(c.copy(for: work).title == title)
    }

    @Test("Row 1 is not entered while the extension is ready or activating", arguments: [ExtensionReadiness.ready, .activating])
    func row1NotEntered(readiness: ExtensionReadiness) {
        #expect(inputs { $0.extensionReadiness = readiness }.condition.row == "15")
    }

    @Test("Row 2: paused, with minutes left rounded up")
    func row2() {
        let c = inputs { $0.pausedUntil = now.addingTimeInterval(11 * 60 + 10); $0.status = .connected }.condition
        #expect(c.row == "2")
        #expect(c.glyph == .paused)
        #expect(c.actions == [.resumeNow])
        #expect(c.copy(for: work, now: now).message == "Your Mac is not protected.")
        #expect(c.copy(for: work, now: now).title.contains("12"))
    }

    @Test("Row 2 ends when pausedUntil is in the past")
    func row2Expired() {
        #expect(inputs { $0.pausedUntil = now.addingTimeInterval(-1) }.condition.row == "15")
    }

    @Test("Row 3: sign-in inside the pending start (draft 9); blocked under the kill switch (S2 E14a)")
    func row3() {
        let base = inputs { $0.status = .connecting; $0.snapshot.phase = .awaitingAuth; $0.killSwitch = true }
        #expect(base.condition == .authMidStart(awaitingApproval: false, trafficBlocked: true))
        #expect(base.condition.glyph == .attention)
        #expect(base.condition.actions == [.enterCode, .cancel])
        #expect(base.condition.copy(for: work).title == "Sign in to connect Work.")
        #expect(base.condition.copy(for: work).message == "No traffic leaves this Mac until you sign in or disconnect.")
        var approval = base; approval.awaitingApproval = true
        #expect(approval.condition.copy(for: work).title == "Waiting for sign-in approval…")
        var open = base; open.killSwitch = false
        #expect(open.condition.copy(for: work).message == "Work is waiting for you to sign in.")
    }

    @Test("Row 4: connecting with a phase line, never before the system says .connecting")
    func row4() {
        let c = inputs { $0.status = .connecting; $0.snapshot.phase = .establishing }.condition
        #expect(c.row == "4")
        #expect(c.glyph == .connecting)
        #expect(c.actions == [.cancel])
        #expect(c.copy(for: work).title == "Connecting to Work…")
        #expect(c.copy(for: work).detail == "Waiting for handshake…")
        #expect(inputs { $0.status = .disconnected }.condition.row != "4")
    }

    @Test("Row 4a: connected but the tunnel process link is reconnecting — never 'Protected'")
    func row4a() {
        let c = inputs { $0.status = .connected; $0.link = .reconnecting; $0.dns = .verified }.condition
        #expect(c == .tunnelProcessReconnecting)
        #expect(c.row == "4a")
        #expect(c.glyph == .reasserting)
        #expect(c.actions == [.disconnect, .details])
        #expect(c.copy(for: work).title == "Reconnecting to the tunnel process…")
        #expect(c.copy(for: work).title != "Protected")
        #expect(!c.showsRateLabel)
        let unavailable = inputs { $0.status = .connected; $0.link = .unavailable }.condition
        #expect(unavailable == .tunnelProcessUnresponsive)
        #expect(unavailable.copy(for: work).title == "Work's tunnel process isn't responding.")
    }

    @Test("Row 5: protected, DNS not verified", arguments: [DNSVerdict.unverified, .overridden])
    func row5(dns: DNSVerdict) {
        let c = inputs { $0.status = .connected; $0.dns = dns }.condition
        #expect(c.row == "5")
        #expect(c.glyph == .attention)
        #expect(c.actions == [.runDiagnostics, .disconnect])
        #expect(c.copy(for: work).title == "Protected")
        #expect(c.showsRateLabel)
    }

    @Test("Row 6: protected (a pending DNS check doesn't flag anything)", arguments: [DNSVerdict.verified, .pending])
    func row6(dns: DNSVerdict) {
        let c = inputs { $0.status = .connected; $0.dns = dns }.condition
        #expect(c == .protected)
        #expect(c.glyph == .protected)
        #expect(c.actions == [.disconnect])
        #expect(c.copy(for: work).message == "Work · Frankfurt · WireGuard")
        #expect(c.showsRateLabel)
        #expect(c.heroTint == .protected)
    }

    @Test("Row 7: held after a fatal error — no retry text, no Pause")
    func row7() {
        let c = inputs {
            $0.status = .reasserting; $0.killSwitch = true
            $0.snapshot.holdReason = .blockedAfterFailure(.serverIdentityMismatch)
            $0.snapshot.attempt = 4; $0.snapshot.nextRetryAt = now.addingTimeInterval(20)   // stale retry facts must not show
        }.condition
        #expect(c == .blockedAfterFailure(.serverIdentityMismatch))
        #expect(c.glyph == .blocked)
        #expect(c.actions == [.disconnectAndRestoreInternet, .details])
        #expect(!c.showsRetryText)
        #expect(c.copy(for: work, now: now).detail == nil)
        #expect(c.copy(for: work).message == "Work stopped: the server's certificate is not trusted. No traffic leaves this Mac.")
        #expect(c.forbidsPause)
        #expect(!c.showsPauseMenu(anyOnDemandEnabled: true))
    }

    @Test("Row 8: non-retryable hold under on-demand; blocked glyph only with the kill switch")
    func row8() {
        let off = inputs { $0.status = .reasserting; $0.snapshot.holdReason = .nonRetryable(.authFailed) }.condition
        #expect(off == .heldNonRetryable(.authFailed, blocked: false))
        #expect(off.glyph == .errorStopped)
        #expect(off.actions == [.signIn, .disconnect])
        #expect(off.copy(for: work).message == "Auto-connect is paused for Work.")
        let on = inputs { $0.status = .reasserting; $0.killSwitch = true; $0.snapshot.holdReason = .nonRetryable(.profileInvalid) }.condition
        #expect(on.glyph == .blocked)
        #expect(on.actions == [.disconnect, .details])
        #expect(!on.showsRetryText)
    }

    @Test("Row 9: reconnect needs a new code")
    func row9() {
        let c = inputs { $0.status = .reasserting; $0.killSwitch = true; $0.snapshot.phase = .awaitingAuth }.condition
        #expect(c == .reconnectNeedsCode)
        #expect(c.glyph == .attention)
        #expect(c.actions == [.enterCode, .disconnect])
        #expect(c.copy(for: work).title == "Enter a new code to reconnect Work.")
        // The header's short wording (review 2026-11-09: never truncated); the full sentence stays in the hero.
        #expect(c.headerCopy(for: work).title == "New code needed for Work")
        #expect(c.headerCopy(for: work).message == "Traffic is blocked meanwhile.")
    }

    @Test("Row 10: blocked, reconnecting — the retry text is real")
    func row10() {
        let c = inputs { $0.status = .reasserting; $0.killSwitch = true; $0.snapshot.attempt = 3; $0.snapshot.nextRetryAt = now.addingTimeInterval(20) }.condition
        #expect(c == .blockedReconnecting(attempt: 3, nextRetryAt: now.addingTimeInterval(20)))
        #expect(c.glyph == .blocked)
        #expect(c.actions == [.disconnectAndRestoreInternet, .pause, .details])
        #expect(c.showsRetryText)
        #expect(c.copy(for: work, now: now).detail == "Reconnecting… attempt 3 · next try in \(DurationFormat.seconds(20))")
        #expect(c.headerCopy(for: work, now: now).title == "Blocked — reconnecting Work")
        #expect(!c.showsRateLabel)                            // hidden while blocked (§6.6)
        #expect(c.showsPauseMenu(anyOnDemandEnabled: false))
    }

    @Test("Row 11: reconnecting without the kill switch")
    func row11() {
        let c = inputs { $0.status = .reasserting; $0.snapshot.attempt = 3 }.condition
        #expect(c == .reconnecting(attempt: 3))
        #expect(c.glyph == .reasserting)
        #expect(c.actions == [.disconnect])
        #expect(c.copy(for: work).title == "Reconnecting Work…")
        #expect(c.copy(for: work).detail == "Attempt 3")
    }

    @Test("Row 12: disconnecting")
    func row12() {
        let c = inputs { $0.status = .disconnecting }.condition
        #expect(c == .disconnecting)
        #expect(c.glyph == .connecting)
        #expect(c.actions.isEmpty)
        #expect(c.copy(for: work).title == "Disconnecting…")
    }

    /// Draft 9 (S2 E3, E14c): `.disconnected` is never blocked any more, whatever the kill switch: the extension holds
    /// instead of cancelling or failing a start. A failed start and a provider cancel are plain row 14.
    @Test("No blocked row while disconnected (rows 13 and 13b are gone)", arguments: [ObservedError.Origin.failedStart, .providerCancel, .other])
    func disconnectedIsNeverBlocked(origin: ObservedError.Origin) {
        for code in [LPErrorCode.connectTimeout, .authRequired, .authFailed, .engineFatal] {
            let c = inputs {
                $0.status = .disconnected; $0.killSwitch = true
                $0.lastError = ObservedError(code: code, origin: origin)
            }.condition
            #expect(c == .stoppedWithError(code))
            #expect(!c.isBlocked)
        }
    }

    @Test("Row 13a: a hard start latch — auto-connect is paused")
    func row13a() {
        let c = inputs { $0.status = .disconnected; $0.snapshot.startLatch = StartLatchUI(code: .authFailed, kind: .hard) }.condition
        #expect(c == .startLatched(.authFailed))
        #expect(c.glyph == .errorStopped)
        #expect(c.actions == [.signIn, .details])
        #expect(c.copy(for: work).message == "Auto-connect is paused for Work.")
        let nonAuth = inputs { $0.status = .disconnected; $0.snapshot.startLatch = StartLatchUI(code: .profileInvalid, kind: .hard) }.condition
        #expect(nonAuth.actions == [.connect, .details])
        let backoff = inputs { $0.status = .disconnected; $0.snapshot.startLatch = StartLatchUI(code: .secretStoreUnavailable, kind: .backoff) }.condition
        #expect(backoff.row == "15")
    }

    @Test("Row 14: stopped with an error; pluginFailed/engineDied copy")
    func row14() {
        let c = inputs { $0.status = .disconnected; $0.lastError = ObservedError(code: .engineDied) }.condition
        #expect(c == .stoppedWithError(.engineDied))
        #expect(c.glyph == .errorStopped)
        #expect(c.actions == [.connect, .details])
        #expect(c.copy(for: work).title == "LockPlus's tunnel process stopped unexpectedly.")
        #expect(c.copy(for: work).message == "Not protected.")
    }

    @Test("Row 15: not protected", arguments: [TunnelStatus.disconnected, .invalid])
    func row15(status: TunnelStatus) {
        let c = inputs { $0.status = status }.condition
        #expect(c == .unprotected)
        #expect(c.glyph == .unprotected)
        #expect(c.actions == [.connect])
        #expect(c.heroTint == .none)
        #expect(ProfileContext(name: "Work", protocolName: "WireGuard", lastSessionSummary: "Last connected yesterday")
                    .throughWhat == "Work · WireGuard")
    }

    @Test(".invalid with a lastError is still row 15 (rows 13–14 need .disconnected)")
    func invalidIgnoresError() {
        #expect(inputs { $0.status = .invalid; $0.lastError = ObservedError(code: .engineDied) }.condition.row == "15")
    }

    // MARK: Withhold alternative (rows 3a/3b)

    @Test("Rows 3a/3b: the withheld start (draft 9, S2 E14) never reads 'Connecting…'")
    func withheldStart() {
        let alt = inputs {
            $0.status = .connecting; $0.killSwitch = true
            $0.snapshot.holdReason = .blockedAfterFailure(.peerUnreachable); $0.snapshot.holdBeforeConnected = true
        }
        #expect(alt.condition == .blockedBeforeConnected(.peerUnreachable, attempt: 0, nextRetryAt: nil))
        #expect(alt.condition.glyph == .blocked)
        #expect(alt.condition.actions == [.disconnectAndRestoreInternet, .details])
        #expect(alt.condition.copy(for: work).title != "Connecting to Work…")
        #expect(alt.condition.copy(for: work).detail == nil && !alt.condition.showsRetryText)
        #expect(alt.condition.forbidsPause)
        // a retryable failure: the extension retries inside the hold, and the retry text is real
        var retrying = alt; retrying.snapshot.attempt = 2; retrying.snapshot.nextRetryAt = now.addingTimeInterval(4)
        #expect(retrying.condition.showsRetryText)
        #expect(retrying.condition.copy(for: work, now: now).detail?.hasPrefix("Retrying… attempt 2") == true)

        var b = alt; b.snapshot.holdReason = .nonRetryable(.authFailed); b.killSwitch = false
        #expect(b.condition == .nonRetryableBeforeConnected(.authFailed, blocked: false))
        #expect(b.condition.row == "3b")
        #expect(b.condition.glyph == .errorStopped)
        #expect(b.condition.copy(for: work).message == "Auto-connect is paused for Work.")

        // Row 3 stays ahead of 3a.
        var row3 = alt; row3.snapshot.phase = .awaitingAuth
        #expect(row3.condition.row == "3")
    }

    // MARK: Switching (§6.2)

    @Test("Switching reads 'not protected for a moment' while the target is connecting")
    func switching() {
        let c = inputs { $0.status = .connecting; $0.switchingTo = "Home NAS" }.condition
        #expect(c == .switching(to: "Home NAS"))
        #expect(c.copy(for: work).title == "Switching to Home NAS — not protected for a moment.")
        // Without NE's `.connecting` the row would say "Connecting…" with no status: the plain rows instead (review 2518e93 #3).
        #expect(inputs { $0.status = .disconnected; $0.switchingTo = "Home NAS" }.condition == .unprotected)
        #expect(inputs { $0.status = .disconnecting; $0.switchingTo = "Home NAS" }.condition == .disconnecting)
        #expect(inputs { $0.status = .connected; $0.switchingTo = "Home NAS" }.condition == .protected)
        // A failed switch shows the error, not "switching".
        #expect(inputs { $0.status = .disconnected; $0.switchingTo = "Home NAS"; $0.lastError = ObservedError(code: .peerUnreachable) }.condition.row == "14")
    }

    @Test("A switch whose target NE hasn't reported yet is row 12a, never 'switching' or 'Connecting…' (E2E-4 200012)")
    func switchingBeforeAnyStatusIsTheWaitingRow() {
        let hold = StartHoldUI(name: "Work", reason: .waitingForStop(of: "Home NAS"))
        let c = inputs { $0.status = .disconnected; $0.switchingTo = "Work"; $0.startHold = hold }.condition
        #expect(c == .startHeld(hold))
        #expect(c.shortStateWord == "Waiting…")
        let prep = StartHoldUI(name: "Work", reason: .preparing)
        #expect(inputs { $0.status = .disconnected; $0.switchingTo = "Work"; $0.startHold = prep }.condition.shortStateWord == "Preparing…")
        #expect(inputs { $0.status = .disconnecting; $0.switchingTo = "Work"; $0.startHold = hold }.condition.row == "12")
        let reading = StartHoldUI(name: "Work", reason: .readingDisconnect)
        #expect(inputs { $0.status = .disconnected; $0.switchingTo = "Work"; $0.startHold = reading }.condition.row == "15")
        // Once NE says `.connecting`, the switch row (and its word) is honest again.
        #expect(inputs { $0.status = .connecting; $0.switchingTo = "Work"; $0.startHold = hold }.condition == .switching(to: "Work"))
    }

    // MARK: Order and invariants

    @Test("Pause beats everything below it; extension readiness beats pause")
    func ordering() {
        #expect(inputs { $0.pausedUntil = now.addingTimeInterval(60); $0.status = .reasserting; $0.killSwitch = true }.condition.row == "2")
        #expect(inputs { $0.pausedUntil = now.addingTimeInterval(60); $0.extensionReadiness = .failed }.condition.row == "1")
    }

    @Test("Only retrying rows show retry text (10, 11, and 3a while the held start retries); held rows never do")
    func retryTextOnlyWhenRetrying() {
        for row in PreviewData.allRows {
            let c = PreviewData.inputs(row: row).condition
            #expect(c.showsRetryText == (row == "10" || row == "11" || row == "3a"), "row \(row)")
        }
    }

    @Test("Every preview fixture lands on its own row")
    func fixturesMatchRows() {
        for row in PreviewData.allRows {
            #expect(PreviewData.inputs(row: row).condition.row == String(row.prefix { $0 != "-" }), "fixture for row \(row)")
        }
    }

    @Test("Pause rule: offered while active or on-demand, never in 7/3a, replaced while paused")
    func pauseRule() {
        #expect(ConnectionCondition.protected.showsPauseMenu(anyOnDemandEnabled: false))
        #expect(ConnectionCondition.connecting(phase: .starting).showsPauseMenu(anyOnDemandEnabled: false))
        #expect(!ConnectionCondition.unprotected.showsPauseMenu(anyOnDemandEnabled: false))
        #expect(ConnectionCondition.unprotected.showsPauseMenu(anyOnDemandEnabled: true))
        #expect(!ConnectionCondition.paused(until: now).showsPauseMenu(anyOnDemandEnabled: true))
        #expect(!ConnectionCondition.blockedBeforeConnected(.connectTimeout, attempt: 1, nextRetryAt: nil).showsPauseMenu(anyOnDemandEnabled: true))
        #expect(!ConnectionCondition.blockedAfterFailure(.connectTimeout).showsPauseMenu(anyOnDemandEnabled: true))
    }

    @Test("Blocked glyph ⇔ a blocked row; the menu bar label hides while blocked")
    func blockedInvariant() {
        for row in PreviewData.allRows {
            let c = PreviewData.inputs(row: row).condition
            if c.isBlocked { #expect(!c.showsRateLabel, "row \(row)") }
        }
    }

    @Test("Menu header switch follows the derived state (on while protected, off when not)")
    func headerSwitch() {
        for (row, on) in [("6", true), ("10", true), ("4", true), ("3a", true), ("15", false), ("14", false)] {
            let model = MenuHeaderModel()
            model.refresh(from: UIEnvironment.preview(row: row), now: PreviewData.now)
            #expect(model.snapshot.isOn == on, "row \(row)")
        }
    }

    // MARK: Accessibility wording (§6.1, §6.6)

    @Test("Status item labels use the one wording")
    func statusItemLabels() {
        let rate = Rate(down: 1_200_000, up: 30_000)
        let protected = ConnectionCondition.protected.statusItemAccessibilityLabel(for: work, rate: rate)
        // Number and unit formatting follow the test host's locale; the wording around them doesn't.
        #expect(protected.hasPrefix("LockPlus, protected, Work, download "))
        #expect(protected.contains(RateFormat.spoken(1_200_000)))
        #expect(protected.contains(", upload \(RateFormat.spoken(30_000))."))
        #expect(ConnectionCondition.blockedReconnecting(attempt: 1, nextRetryAt: nil).statusItemAccessibilityLabel(for: work, rate: nil)
                == "LockPlus, blocked, waiting to reconnect Work.")
        #expect(ConnectionCondition.blockedAfterFailure(.serverIdentityMismatch).statusItemAccessibilityLabel(for: work, rate: nil)
                == "LockPlus, blocked, Work stopped: the server's certificate is not trusted.")
        #expect(ConnectionCondition.blockedBeforeConnected(.connectTimeout, attempt: 0, nextRetryAt: nil).statusItemAccessibilityLabel(for: work, rate: nil)
                == "LockPlus, blocked, Work couldn't connect: the server didn't answer.")
        #expect(ConnectionCondition.reconnectNeedsCode.statusItemAccessibilityLabel(for: work, rate: nil) == "LockPlus, sign-in required, Work.")
        let paused = ConnectionCondition.paused(until: now.addingTimeInterval(12 * 60)).statusItemAccessibilityLabel(for: work, rate: nil, now: now)
        #expect(paused == "LockPlus, paused, \(DurationFormat.spoken(12 * 60)) left.")
    }

    @Test("High-priority announcements for Blocked and auth")
    func announcements() {
        #expect(ConnectionCondition.blockedReconnecting(attempt: 1, nextRetryAt: nil).announcement(for: work) == "Blocked. Traffic is held until Work reconnects.")
        #expect(ConnectionCondition.blockedAfterFailure(.serverIdentityMismatch).announcement(for: work)
                == "Blocked. Work stopped because the server's certificate is not trusted. Disconnect to restore internet.")
        #expect(ConnectionCondition.blockedBeforeConnected(.connectTimeout, attempt: 0, nextRetryAt: nil).announcement(for: work)
                == "Blocked. Work couldn't connect because the server didn't answer. Disconnect to restore internet.")
        #expect(ConnectionCondition.authMidStart(awaitingApproval: false, trafficBlocked: true).announcement(for: work) == "Sign-in required to connect Work.")
        for c in [ConnectionCondition.blockedReconnecting(attempt: 1, nextRetryAt: nil), .blockedAfterFailure(.engineFatal),
                  .blockedBeforeConnected(.engineFatal, attempt: 0, nextRetryAt: nil), .authMidStart(awaitingApproval: false, trafficBlocked: true)] {
            #expect(c.announcesWithHighPriority)
        }
        #expect(!ConnectionCondition.protected.announcesWithHighPriority)
    }
}

@Suite("lastError input rule (S12)")
struct LastErrorPolicyTests {
    let quit = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func observedDisconnectIsAlwaysShown() {
        #expect(LastErrorPolicy.isShowable(source: .observedDisconnect, hasStartLatch: false, lastQuitAt: quit))
    }

    @Test func staleLaunchErrorIsHidden() {
        #expect(!LastErrorPolicy.isShowable(source: .launchSnapshot(recordedAt: quit.addingTimeInterval(-60)),
                                            hasStartLatch: false, lastQuitAt: quit))
        #expect(!LastErrorPolicy.isShowable(source: .launchSnapshot(recordedAt: nil), hasStartLatch: false, lastQuitAt: quit))
    }

    @Test func launchErrorShownWithLatchOrWhenNewer() {
        let stale = LastErrorPolicy.Source.launchSnapshot(recordedAt: quit.addingTimeInterval(-60))
        #expect(LastErrorPolicy.isShowable(source: stale, hasStartLatch: true, lastQuitAt: quit))
        #expect(LastErrorPolicy.isShowable(source: .launchSnapshot(recordedAt: quit.addingTimeInterval(60)),
                                           hasStartLatch: false, lastQuitAt: quit))
        #expect(LastErrorPolicy.isShowable(source: .launchSnapshot(recordedAt: quit), hasStartLatch: false, lastQuitAt: nil))
    }
}

@Suite("Formatters")
struct FormatterTests {
    let en = Locale(identifier: "en_US")
    let de = Locale(identifier: "de_DE")

    @Test func compactLabel() {
        #expect(RateFormat.compact(1_234_567, locale: en) == "1.2M")
        #expect(RateFormat.compact(30_120, locale: en) == "30K")
        #expect(RateFormat.compact(999_000, locale: en) == "999K")
        #expect(RateFormat.compact(0, locale: en) == "0K")
        #expect(RateFormat.compact(1_234_567, locale: de) == "1,2M")
        #expect(RateFormat.compact(2_500_000_000, locale: en) == "2.5G")
    }

    @Test("Compact labels never exceed 4 characters, so the fixed width holds")
    func compactWidth() {
        for v in stride(from: 0.0, through: 5e12, by: 3.7e9) + [999.4, 9_960, 99_600, 999_600, 9_960_000] {
            #expect(RateFormat.compact(v, locale: en).count <= 4, "\(v)")
        }
    }

    /// Owner test 2026-11-10: the centred label moved sideways as "6,5K" became "658K".
    @Test("Menu bar values are always exactly 4 characters (space padded, rendered equally wide), so the label never moves")
    func compactFixedWidth() {
        for locale in [en, de] {
            for v in stride(from: 0.0, through: 5e12, by: 3.7e9) + [0, 450, 6_500, 65_000, 658_000, 999.4, 9_960, 99_600, 999_600, 9_960_000] {
                let s = RateFormat.compactFixed(v, locale: locale)
                #expect(s.count == 4, "\(v): \(s)")
                #expect(s.trimmingCharacters(in: .whitespaces) == RateFormat.compact(v, locale: locale))
            }
        }
        #expect(RateFormat.compactFixed(6_500, locale: de) == "6,5K")
        #expect(RateFormat.compactFixed(12_000, locale: en) == " 12K")
    }

    /// L1: the pad is rendered in the menu bar's font; the typographic width of a padded "12K" equals the widest label's.
    @MainActor @Test("A padded label has the same rendered width as the widest one, in the status item's font")
    func compactFixedRenderedWidth() {
        func width(_ s: String) -> Double {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: MenuBarController.labelAttributes)),
                                       nil, nil, nil)
        }
        let widest = width(RateFormat.widestCompact())
        for v in [0.0, 450, 6_500, 12_000, 65_000, 658_000, 9_960_000] {
            let s = RateFormat.compactFixed(v, locale: en)
            #expect(abs(width(s) - widest) < 0.01, "\(s): \(width(s)) vs \(widest)")
        }
        #expect(abs(width(" 12K") - width("888M")) < 0.01)
    }

    @Test func rateText() {
        #expect(RateFormat.text(1_234_567, locale: en) == "1.2 MB/s")
        #expect(RateFormat.text(30_120, locale: en) == "30 kB/s")
        #expect(RateFormat.text(10_000, locale: en) == "10 kB/s")           // never "10.0" (UI-L24)
        #expect(RateFormat.text(1_234_567, locale: de) == "1,2 MB/s")
    }

    @Test func clock() {
        #expect(DurationFormat.clock(2 * 3_600 + 14 * 60 + 7) == "02:14:07")
    }
}
