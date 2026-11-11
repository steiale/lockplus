import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// §7.2 rows after Connected: reasserting, backoff, held, sleep/wake, watchdog, after-Connected auth (L-RC-1..5, L-LC-1).
@Suite struct ControllerConnectedTests {
    static let wifi = PathSnapshot(status: .satisfied, interfaces: ["en0:wifi"], gateways: ["192.168.1.1"])
    static let ethernet = PathSnapshot(status: .satisfied, interfaces: ["en7:wiredEthernet"], gateways: ["10.0.0.1"])
    static let none = PathSnapshot(status: .unsatisfied)

    /// Connected, with the path watcher primed with `wifi`.
    func connected(_ h: Harness) async -> FakeAdapter {
        await h.provision()
        let a = await h.connect()
        _ = await waitUntil { h.paths.subscribed }
        h.paths.send(Self.wifi)
        await h.advance(h.clock, by: .milliseconds(500), sleepers: 2)    // watchdog + debounce
        _ = await waitUntil { await h.controller.pathState.settled == Self.wifi }
        return a
    }

    func settle(_ h: Harness, _ p: PathSnapshot) async {
        h.paths.send(p)
        _ = await waitUntil { h.clock.sleeperCount >= 2 }
        try? await Task.sleep(for: .milliseconds(5))
        h.clock.advance(by: .milliseconds(500))
        _ = await waitUntil { await !h.controller.pathState.pending }
    }

    // MARK: path

    @Test func pathChangeReasserts() async {
        let h = Harness()
        let a = await connected(h)
        await settle(h, Self.ethernet)
        #expect(await h.waitPhase(.reasserting(.pathChanged)))
        #expect(h.host.lastReasserting == true)
        #expect(await waitUntil { a.reconnectReasons == [.pathChanged] })
        a.emit { .reconnected(epoch: $0) }
        #expect(await h.waitPhase(.connected))
        #expect(h.host.lastReasserting == false)
        #expect(await h.controller.snapshot().attempt == 0)
    }

    @Test func pathUnsatisfiedWaitsWithoutBackoff() async {
        let h = Harness()
        let a = await connected(h)
        await settle(h, Self.none)
        #expect(await h.waitPhase(.reasserting(.noNetwork)))
        #expect(a.reconnectReasons.isEmpty)
        await settle(h, Self.ethernet)
        #expect(await waitUntil { a.reconnectReasons == [.pathChanged] })
        #expect(await h.controller.snapshot().attempt == 0)
    }

    /// No real-time sleeps: each path is waited for by the debounce sleeper it registers (`registrations` counts every
    /// one, so a re-armed debounce is distinguishable from the one it replaced), then the clock advances once and the
    /// settled debounce is observed. `none` is therefore processed before `wifi` is sent, and `wifi` before the advance.
    @Test func pathIsDebounced() async {
        let h = Harness()
        let a = await connected(h)
        let before = h.clock.registrations
        h.paths.send(Self.none)
        _ = await waitUntil { h.clock.registrations >= before + 1 }       // `none` taken, its debounce armed
        h.paths.send(Self.wifi)                                           // flapped back within 500 ms
        _ = await waitUntil { h.clock.registrations >= before + 2 }       // the debounce re-armed for `wifi`
        h.clock.advance(by: .milliseconds(500))
        _ = await waitUntil { await !h.controller.pathState.pending }
        #expect(await h.controller.pathState.settled == Self.wifi)
        #expect(await h.phase == .connected)
        #expect(a.reconnectReasons.isEmpty)
    }

    @Test func engineReconnectingReasserts() async {
        let h = Harness()
        let a = await connected(h)
        a.emit { .reconnecting(.engine, epoch: $0) }
        #expect(await h.waitPhase(.reasserting(.engine)))
        a.emit { .reconnected(epoch: $0) }
        #expect(await h.waitPhase(.connected))
    }

    // MARK: attempts, backoff, budget

    @Test func failedAttemptsBackOffAndPublishNextRetry() async {
        let h = Harness()
        let a = await connected(h)
        await settle(h, Self.ethernet)
        #expect(await waitUntil { a.reconnectReasons.count == 1 })
        await h.advance(h.clock, by: .seconds(15), sleepers: 2)         // attempt timeout
        #expect(await waitUntil { await h.controller.snapshot().attempt == 1 })
        #expect(await h.controller.snapshot().nextRetryAt != nil)
        await h.advance(h.clock, by: .seconds(2), sleepers: 2)          // backoff ~1 s → retry
        #expect(await waitUntil { a.reconnectReasons.count == 2 })
    }

    @Test func budgetExhaustedKillSwitchOffCancels() async {
        let h = Harness()
        _ = await connected(h)
        await settle(h, Self.none)
        #expect(await h.waitPhase(.reasserting(.noNetwork)))
        await h.advance(h.clock, by: .seconds(300), sleepers: 1)
        #expect(await waitUntil { h.host.cancelledCodes == [.peerUnreachable] })
        #expect(await h.phase == .idle)
    }

    @Test func budgetNeverExhaustsWithKillSwitchOn() async {
        let h = Harness(killSwitch: true)
        _ = await connected(h)
        await settle(h, Self.none)
        #expect(await h.waitPhase(.reasserting(.noNetwork)))
        for _ in 0..<5 { h.clock.advance(by: .seconds(300)); try? await Task.sleep(for: .milliseconds(2)) }
        #expect(h.host.cancelledCodes.isEmpty)
        #expect(await h.phase == .reasserting(.noNetwork))
    }

    // MARK: after-Connected .fatal rows

    @Test func fatalKillSwitchOffCancelsImmediately() async {
        let h = Harness()
        let a = await connected(h)
        a.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await waitUntil { h.host.cancelledCodes == [.engineFatal] })
        #expect(await waitUntil { a.stopCount == 1 })
        #expect(await h.phase == .idle)
    }

    /// Draft 9 (S2 E3): NE never calls `stopTunnel` after `cancelTunnelWithError`, so the adapter is stopped, the
    /// session summary written and the path watcher ended BEFORE the cancel; the cancel waits for the adapter's stop.
    /// 2.0.1 round 3: the session stays tracked (`.stopping`) through the teardown; its protection is read again, then
    /// the summary, then the cancel.
    @Test func cancelComesAfterTheTeardownAndTheSummary() async {
        let h = Harness()
        let a = await connected(h)
        a.s.withLock { $0.hangStop = true }
        a.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await waitUntil { a.stopCount == 1 })
        #expect(await h.phase == .stopping)
        #expect(!(await h.controller.isWatchingPath))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.host.cancelledCodes.isEmpty)                            // the adapter hasn't finished stopping
        a.releaseStop()
        #expect(await waitUntil { h.host.cancelledCodes == [.engineFatal] })
        #expect(await h.phase == .idle)
        #expect(h.state.load().sessions.count == 1 && h.state.load().sessions[0].summary.endReason == "error:\(LPErrorCode.engineFatal.rawValue)")
    }

    /// 2.0.1 round 3 (Codex 1): the kill switch enabled live while reasserting: the reconnect budget's expiry never
    /// cancels the session (kill switch on: retry at the cap).
    @Test func aKillSwitchEnabledLiveEndsTheReconnectBudget() async {
        let h = Harness()
        _ = await connected(h)
        await settle(h, Self.none)
        #expect(await h.waitPhase(.reasserting(.noNetwork)))
        h.host.setIncludeAllNetworks(true)
        for _ in 0..<3 { h.clock.advance(by: .seconds(300)); try? await Task.sleep(for: .milliseconds(2)) }
        #expect(h.host.cancelledCodes.isEmpty)
        #expect(await h.phase == .reasserting(.noNetwork))
    }

    // MARK: Round 4 (Fable M1): protected when the live OR the start-time flags say so

    static let flagsOff = ProviderProtection(includeAllNetworks: false, enforceRoutes: false)

    /// A kill-switch session whose live flags the system weakened (start-time on, live off), then an engine fatal:
    /// held, never cancelled.
    @Test(arguments: [false, true])
    func aWeakenedLiveFlagStillHoldsOnAFatal(routeProtection: Bool) async {
        let h = Harness(killSwitch: true, routeProtection: routeProtection)
        let a = await connected(h)
        h.host.setProtection(Self.flagsOff)
        a.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.engineFatal))))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.host.cancelledCodes.isEmpty && h.host.lastReasserting == true)
    }

    /// Start-time on, live off, the network gone: no reconnect budget is armed and nothing cancels the session.
    @Test func aWeakenedLiveFlagArmsNoReconnectBudget() async {
        let h = Harness(killSwitch: true)
        _ = await connected(h)
        h.host.setProtection(Self.flagsOff)
        await settle(h, Self.none)
        #expect(await h.waitPhase(.reasserting(.noNetwork)))
        for _ in 0..<3 { h.clock.advance(by: .seconds(300)); try? await Task.sleep(for: .milliseconds(2)) }
        #expect(h.host.cancelledCodes.isEmpty)
        #expect(await h.phase == .reasserting(.noNetwork))
    }

    /// Start-time on, live off, before Connected: a connect timeout is WITHHELD (the start stays pending, retrying),
    /// never a failed start.
    @Test func aWeakenedLiveFlagStillWithholdsBeforeConnected() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        h.host.setProtection(Self.flagsOff)
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        let done = Mutex(false)
        let waiter = Task { _ = await t.value; done.withLock { $0 = true } }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!done.withLock { $0 })                                   // still pending: withheld, not failed
        await h.controller.stop(reason: .userInitiated)
        _ = await waiter.value
    }

    /// The other direction before Connected: start-time off, the live `includeAllNetworks` on (saved while connecting):
    /// a connect timeout is withheld, not a failed start (a failed start would be open, E14c).
    @Test func aLiveKillSwitchWithholdsBeforeConnected() async {
        let h = Harness()
        await h.provision()
        let t = h.start()
        h.host.setIncludeAllNetworks(true)
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// The before-Connected latch (an on-demand start's retryable failure under the kill switch arms the backoff latch)
    /// reads the union too: live route protection on with start-time off, and start-time on with live off.
    @Test(arguments: [false, true])
    func theBeforeConnectedLatchReadsLiveOrStartTimeFlags(startTimeOn: Bool) async {
        let h = Harness(killSwitch: startTimeOn, routeProtection: true)
        await h.provision()
        let t = h.start(manual: false)
        h.host.setProtection(startTimeOn ? Self.flagsOff : ProviderProtection(includeAllNetworks: false, enforceRoutes: true))
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(h.code(await t.value) == .connectTimeout)                // no `includeAllNetworks`: the start fails
        #expect(h.latch?.kind == .backoff)
    }

    /// Draft 9 (S2 E3/E4): with the kill switch on, nothing after Connected ever calls `cancelTunnelWithError`:
    /// every fatal row holds with the adapter down (`reasserting` alone would not block, E4r).
    @Test(arguments: [LPErrorCode.engineFatal, .engineDied, .peerUnreachable, .authTimedOut, .serverIdentityMismatch])
    func killSwitchNeverCancelsAfterConnected(code: LPErrorCode) async {
        let h = Harness(killSwitch: true)
        let a = await connected(h)
        a.emit { .fatal(LPTunnelError(code), epoch: $0) }
        #expect(await h.waitPhase(.held(.blockedAfterFailure(code))))
        #expect(await waitUntil { a.stopCount == 1 })                    // adapter DOWN, not just `reasserting`
        h.clock.advance(by: .seconds(3600)); try? await Task.sleep(for: .milliseconds(10))
        #expect(h.host.cancelledCodes.isEmpty && h.host.lastReasserting == true)
    }

    /// Route protection (split tunnel, `enforceRoutes`) is a kill switch too: never cancelled after Connected.
    @Test func routeProtectionNeverCancelsAfterConnected() async {
        let h = Harness(killSwitch: true, routeProtection: true)
        let a = await connected(h)
        a.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.engineFatal))))
        #expect(h.host.cancelledCodes.isEmpty)
    }

    @Test func fatalKillSwitchOnHoldsBlocked() async {
        let h = Harness(killSwitch: true)
        let a = await connected(h)
        a.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.engineFatal))))
        #expect(h.host.lastReasserting == true && h.host.cancelledCodes.isEmpty)
        #expect(await waitUntil { a.stopCount == 1 })
        let snap = await h.controller.snapshot()
        #expect(snap.holdReason == .blockedAfterFailure(.engineFatal) && !snap.holdBeforeConnected && snap.lastError?.code == .engineFatal)
        // no retries while held: time passes, nothing restarts
        h.clock.advance(by: .seconds(600)); try? await Task.sleep(for: .milliseconds(10))
        #expect(h.factory.adapters.count == 1)
        await h.controller.stop(reason: .userInitiated)                   // Disconnect ends the hold
        #expect(await h.phase == .idle)
    }

    @Test(arguments: [false, true])
    func nonRetryableUnderOnDemandHolds(killSwitch: Bool) async {
        let h = Harness(killSwitch: killSwitch, onDemandRules: true)
        let a = await connected(h)
        a.emit { .fatal(LPTunnelError(.authFailed), epoch: $0) }
        #expect(await h.waitPhase(.held(.nonRetryable(.authFailed))))      // C16 wins over the kill-switch row
        #expect(h.sink.endedCodes == [.authFailed] && h.host.cancelledCodes.isEmpty && h.host.lastReasserting == true)
    }

    @Test func engineDiedIsFatal() async {
        let h = Harness()
        let a = await connected(h)
        a.emit { .fatal(LPTunnelError(.engineDied), epoch: $0) }
        #expect(await waitUntil { h.host.cancelledCodes == [.engineDied] })
    }

    // MARK: watchdog

    @Test func watchdogStaleReassertsDeadPeer() async {
        let h = Harness()
        let a = await connected(h)
        a.s.withLock { $0.liveness = .stale(.seconds(200)) }
        await h.advance(h.clock, by: .seconds(10))
        #expect(await h.waitPhase(.reasserting(.deadPeer)))
        #expect(await waitUntil { a.reconnectReasons == [.deadPeer] })
    }

    @Test func watchdogDeadIsEngineDied() async {
        let h = Harness()
        let a = await connected(h)
        a.s.withLock { $0.liveness = .dead }
        await h.advance(h.clock, by: .seconds(10))
        #expect(await waitUntil { h.host.cancelledCodes == [.engineDied] })
    }

    // MARK: sleep / wake (L-RC-5)

    @Test func sleepThenWakeReconnects() async {
        let h = Harness(killSwitch: true)
        let a = await connected(h)
        await h.controller.sleep()
        #expect(await h.phase == .sleeping)
        #expect(h.host.lastReasserting == true && a.s.withLock { $0.sleeps } == 1)
        await h.controller.wake()
        #expect(await h.phase == .reasserting(.wake))
        #expect(await waitUntil { a.s.withLock { $0.wakes } == 1 })
        a.emit { .reconnected(epoch: $0) }
        #expect(await h.waitPhase(.connected))
    }

    @Test func wakeFailuresInTheFirst10sConsumeNoBackoff() async {
        let h = Harness(configure: { $0.wakeAttemptTimeout = .seconds(4) })
        let a = await connected(h)
        await h.controller.sleep()
        await h.controller.wake()
        await h.advance(h.clock, by: .seconds(4), sleepers: 2)           // attempt fails 4 s after wake: inside the grace
        #expect(await waitUntil { a.reconnectReasons == [.wake] })       // re-attempted at once, no backoff
        #expect(await h.controller.snapshot().attempt == 0)
        await h.advance(h.clock, by: .seconds(15), sleepers: 2)          // 19 s after wake: outside the grace
        #expect(await waitUntil { await h.controller.snapshot().attempt == 1 })
    }

    @Test func sleepCompletesWithinTwoSecondsEvenIfTheAdapterHangs() async {
        let h = Harness()
        let a = await connected(h)
        a.s.withLock { $0.hangSleep = true }
        let t = Task { await h.controller.sleep() }
        #expect(await waitUntil { a.s.withLock { $0.sleepK != nil } })
        await h.advance(h.clock, by: .seconds(2), sleepers: 1)            // only the 2 s cap is armed
        await t.value
        #expect(await h.phase == .sleeping)
        a.releaseSleep()
    }

    // MARK: after-Connected auth (L-RC-4)

    @Test func reconnectAuthPausesTheBudgetAndAnswerResumes() async throws {
        let h = Harness()
        let a = await connected(h)
        await settle(h, Self.none)
        #expect(await h.waitPhase(.reasserting(.noNetwork)))
        await h.advance(h.clock, by: .seconds(100))                     // 100 s of the 300 s budget used
        a.emit { .authRequired(AuthChallenge(kind: .userPass, reason: .reconnect), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: false)))
        let p = try #require(h.sink.prompts.last)
        #expect(!p.nextStart && p.expiresAt == h.wall.now.addingTimeInterval(600))
        await h.advance(h.clock, by: .seconds(400))                     // paused: no budget exhaustion
        #expect(h.host.cancelledCodes.isEmpty)
        try await h.controller.answerAuth(promptID: p.promptID, answer: AuthAnswerSecrets(password: .text("otp")), callerUID: h.owner)
        #expect(await waitUntil { a.s.withLock { $0.provided.count } == 1 })
        #expect(await h.phase == .reasserting(.auth))
        a.emit { .reconnected(epoch: $0) }
        #expect(await h.waitPhase(.connected))
    }

    @Test func reconnectAuthDeadlineIsAuthTimedOut() async {
        let h = Harness()
        let a = await connected(h)
        a.emit { .authRequired(AuthChallenge(kind: .userPass, reason: .reconnect), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: false)))
        await h.advance(h.clock, by: .seconds(600))
        #expect(await waitUntil { h.host.cancelledCodes == [.authTimedOut] })
    }

    /// T10: sleep while an after-Connected prompt shows: wake returns to the prompt (no reassert budget), and the
    /// prompt's deadline still ends it.
    @Test func sleepDuringReconnectPromptKeepsThePrompt() async throws {
        let h = Harness()
        let a = await connected(h)
        a.emit { .authRequired(AuthChallenge(kind: .userPass, reason: .reconnect), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: false)))
        await h.controller.sleep()
        #expect(await h.phase == .sleeping)
        await h.controller.wake()
        #expect(await h.phase == .awaitingAuth(beforeConnected: false))
        #expect(await h.controller.pendingAuthPrompt(profileID: h.pid, ownerUID: h.owner) != nil)
        await h.advance(h.clock, by: .seconds(600))
        #expect(await waitUntil { h.host.cancelledCodes == [.authTimedOut] })
    }

    /// T10: the deadline passing while asleep ends the prompt at wake.
    @Test func reconnectPromptDeadlinePassingAsleepEndsItAtWake() async throws {
        let h = Harness()
        let a = await connected(h)
        a.emit { .authRequired(AuthChallenge(kind: .userPass, reason: .reconnect), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: false)))
        await h.controller.sleep()
        await h.advance(h.clock, by: .seconds(600))
        try? await Task.sleep(for: .milliseconds(5))
        #expect(await h.phase == .sleeping && h.host.cancelledCodes.isEmpty)
        await h.controller.wake()
        #expect(await waitUntil { h.host.cancelledCodes == [.authTimedOut] })
    }

    /// T15: answering a prompt tells the owner's other instances it is resolved.
    @Test func answerEmitsPromptResolved() async throws {
        let h = Harness()
        let a = await connected(h)
        a.emit { .authRequired(AuthChallenge(kind: .userPass, reason: .reconnect), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: false)))
        let p = try #require(h.sink.prompts.last)
        #expect(p.savedUsername == "alice")                                // T15: prefilled from the stored record
        try await h.controller.answerAuth(promptID: p.promptID, answer: AuthAnswerSecrets(password: .text("x")), callerUID: h.owner)
        #expect(h.sink.s.withLock { $0.resolved } == [p.promptID])
    }

    @Test func reconnectAuthCancelUnderKillSwitchHolds() async throws {
        let h = Harness(killSwitch: true)
        let a = await connected(h)
        a.emit { .authRequired(AuthChallenge(kind: .userPass, reason: .reconnect), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: false)))
        try await h.controller.cancelAuth(promptID: try #require(h.sink.prompts.last).promptID, callerUID: h.owner)
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.authRequired))))
    }

    // MARK: sessions

    @Test func sessionSummaryRecorded() async {
        let h = Harness()
        let a = await connected(h)
        // T4: never sampled before the stop — the teardown's final sample fills the summary.
        a.s.withLock { $0.stats = AdapterStats(rxBytes: 10, txBytes: 20) }
        await h.controller.stop(reason: .userInitiated)
        let s = h.state.load().sessions.map(\.summary)
        #expect(s.count == 1 && s[0].rxBytes == 10 && s[0].txBytes == 20 && s[0].profileID == h.pid)
        #expect(h.state.load().sessions[0].ownerUID == h.owner)
        #expect(await h.controller.sessionSummaries(ownerUID: h.owner, after: nil).count == 1)
        #expect(await h.controller.sessionSummaries(ownerUID: h.owner, after: s[0].id).isEmpty)
        #expect(await h.controller.sessionSummaries(ownerUID: 502, after: nil).isEmpty)       // another uid sees none
    }

    /// NEW-6: `wipeAllSecrets` drops the caller's last errors, cached endpoint IPs and session-ring entries too;
    /// another uid's survive.
    @Test func secretsWipedDropsCallerStateOnly() async {
        let other: uid_t = 502
        let sid = UUID(), otherSID = UUID()
        let h = Harness(state: { pid in
            var st = PersistedTunnelState()
            let mine = ProfileKey(ownerUID: 501, profileID: pid), theirs = ProfileKey(ownerUID: other, profileID: pid)
            for k in [mine, theirs] {
                st.lastErrors[k] = .init(error: LPError(.connectTimeout), at: Date(timeIntervalSince1970: 1))
                st.endpointHosts[k] = ["vpn.example": ["198.51.100.7"]]
                st.authFailedAt[k] = Date(timeIntervalSince1970: 1)
            }
            let summary = { (id: UUID) in SessionSummary(id: id, profileID: pid, start: Date(timeIntervalSince1970: 1),
                                                         end: Date(timeIntervalSince1970: 2), rxBytes: 1, txBytes: 1, endReason: "user") }
            st.sessions = [.init(ownerUID: 501, summary: summary(sid)), .init(ownerUID: other, summary: summary(otherSID))]
            return st
        })
        #expect(h.owner == 501)
        await h.controller.secretsWiped(ownerUID: h.owner)
        let st = h.state.load()
        let theirs = ProfileKey(ownerUID: other, profileID: h.pid)
        #expect(st.lastErrors[h.key] == nil && st.endpointHosts[h.key] == nil && st.authFailedAt[h.key] == nil)
        #expect(st.sessions.map(\.summary.id) == [otherSID])
        #expect(st.lastErrors[theirs] != nil && st.endpointHosts[theirs] == ["vpn.example": ["198.51.100.7"]] && st.authFailedAt[theirs] != nil)
        #expect(await h.controller.sessionSummaries(ownerUID: h.owner, after: nil).isEmpty)
        #expect(await h.controller.sessionSummaries(ownerUID: other, after: nil).map(\.id) == [otherSID])
        #expect(await h.controller.snapshot(profileID: h.pid, ownerUID: h.owner).lastError == nil)
    }

    /// NEW-7: a snapshot for anything but the running session carries epoch 0 (the adapter generation is the running
    /// session owner's detail), whether a session runs or not.
    @Test func nonRunningSnapshotHasEpochZero() async {
        let h = Harness()
        _ = await connected(h)
        let own = await h.controller.snapshot(profileID: h.pid, ownerUID: h.owner)
        #expect(own.phase == .connected && own.epoch > 0)
        let otherUID = await h.controller.snapshot(profileID: h.pid, ownerUID: 502)
        let otherProfile = await h.controller.snapshot(profileID: UUID(), ownerUID: h.owner)
        for snap in [otherUID, otherProfile] { #expect(snap.phase == .idle && snap.epoch == 0) }
        await h.controller.stop(reason: .userInitiated)
        let after = await h.controller.snapshot(profileID: h.pid, ownerUID: h.owner)
        #expect(after.phase == .idle && after.epoch == 0)
    }
}
