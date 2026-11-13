import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import Testing
@testable import LockPlus

/// 2.0.2 review round 6 (Fable r6 L1, N2, N4b; Codex r6 #3): the app side.
@MainActor @Suite(.timeLimit(.minutes(1)), .serialized) struct Round6FixTests {
    let r2 = Round2FixTests()
    let nn = NoNetworkRestartTests()

    func never(_ condition: () -> Bool) async -> Bool { await nn.never(condition) }

    /// The pause stopped `id` (a live session, or its hold) and signed nothing; `refuse` ends the session as NE's refusal
    /// does; the pause's end then arms and starts nothing.
    func endsWithoutReconnecting(_ w: NoNetworkRestartTests.World, _ id: UUID, refuse: Bool) async {
        #expect(await eventually { w.h.managers.stops.contains(id) })
        #expect(w.h.env.settings.value.pausedState?.profileID == nil)
        #expect(w.h.env.settings.value.pausedState?.intent == nil)
        if refuse { w.h.managers.emit(id, .disconnected) }
        let starts = w.h.managers.starts.count, arms = w.h.service.state.withLock { $0.arms.count }
        await w.h.env.connection.resume().value
        #expect(await never { w.h.managers.starts.count > starts })
        #expect(w.h.service.state.withLock { $0.arms.count } == arms)
    }

    /// Instant pause-value retries; every other timer as usual.
    static let instantRetries: @Sendable (Duration) async -> Void = { d in
        if d != .seconds(30) { try? await Task.sleep(for: d) }       // `ConnectionStore.resumeIntentRetryDelay`
    }

    // MARK: Fable r6 L1: Pause signs a live session only if this run started it or saw it connected

    /// Fable's test: a start of the owner's kill-switch profile made elsewhere is `.connecting` (NE delivers the refused
    /// attempt's `.connecting`); nothing of ours started it. Pause stops it but signs nothing; its end arms and starts
    /// nothing. Kills: signing `statuses.first { isActive }` without the `resumableSession` filter (either place).
    @Test func aStartMadeElsewherePausedWhileConnectingIsNeverSigned() async throws {
        let w = try await nn.world()
        defer { w.h.dir.cleanup() }
        w.h.env.profiles.extensionCapabilities = [.startAuthorisation]
        w.h.managers.emit(w.work.id, .connecting)
        #expect(await eventually { w.h.env.connection.statuses[w.work.id] == .connecting })
        await w.h.env.connection.pause(minutes: 5)
        await endsWithoutReconnecting(w, w.work.id, refuse: true)          // refused (225)
    }

    /// Fable's realistic order: the owner connects P and disconnects it; later a start of P made elsewhere is
    /// `.connecting`; Pause. Kills: dropping `resumableSession.remove` at a new attempt this app didn't issue.
    @Test func anOutsideStartAfterTheOwnersSessionPausedWhileConnectingIsNeverSigned() async throws {
        let w = try await nn.world()
        defer { w.h.dir.cleanup() }
        w.h.env.profiles.extensionCapabilities = [.startAuthorisation]
        await Round4FixTests().connected(w.h, w.work)
        w.h.env.connection.disconnect()
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.statuses[w.work.id] == .disconnected })
        w.h.managers.emit(w.work.id, .connecting)                         // the start made elsewhere
        #expect(await eventually { w.h.env.connection.statuses[w.work.id] == .connecting })
        await w.h.env.connection.pause(minutes: 5)
        await endsWithoutReconnecting(w, w.work.id, refuse: true)
    }

    /// The same order with refused outside starts that are never active (no `.connecting` delivered): the first one
    /// settles the owner's stop, the second is held ("the start ended early"); Pause in that hold signs nothing.
    /// Kills: dropping `resumableSession.remove` at the never-active end of a start made elsewhere.
    @Test func anOutsideStartAfterTheOwnersSessionPausedInItsHoldIsNeverSigned() async throws {
        let w = try await nn.world()
        defer { w.h.dir.cleanup() }
        w.h.env.profiles.extensionCapabilities = [.startAuthorisation]
        await Round4FixTests().connected(w.h, w.work)
        w.h.env.connection.disconnect()
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.statuses[w.work.id] == .disconnected })
        for _ in 0..<2 {
            w.h.managers.emit(w.work.id, .disconnecting)
            w.h.managers.emit(w.work.id, .disconnected)
        }
        #expect(await eventually { w.h.env.connection.startHold?.reason == .startEndedEarly })
        await w.h.env.connection.pause(minutes: 5)
        await endsWithoutReconnecting(w, w.work.id, refuse: false)
    }

    /// The control: our own Connect, paused while `.connecting`, is signed and resumed.
    @Test func ourStartPausedWhileConnectingIsStillSigned() async throws {
        let w = try await nn.world()
        defer { w.h.dir.cleanup() }
        w.h.env.profiles.extensionCapabilities = [.startAuthorisation]
        w.h.env.connection.connect(w.work.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(w.work.id, .connecting)
        #expect(await eventually { w.h.env.connection.statuses[w.work.id] == .connecting })
        await w.h.env.connection.pause(minutes: 5)
        #expect(w.h.env.settings.value.pausedState?.profileID == w.work.id && w.h.env.settings.value.pausedState?.intent != nil)
    }

    /// At launch a session found `.reasserting` (it was connected) is signable.
    @Test func aSessionReassertingAtLaunchIsSigned() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let a = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        try await h.env.managers.loadAll()
        h.managers.emit(a.id, .reasserting)
        h.env.connection.start()
        await h.env.connection.pause(minutes: 5)
        #expect(h.env.settings.value.pausedState?.profileID == a.id && h.env.settings.value.pausedState?.intent != nil)
    }

    // MARK: Codex r6 #3: the pause's value stays owed until it is spent

    /// A paused live session; quit; other code removes `pausedUntil`; the relaunch sees nothing paused and its spend
    /// fails through every retry (owed, durably; the agent stays registered); the keychain recovers; the genuine record
    /// and expiry are written back; a relaunch: the pause's end spends the owed value first, then arms and starts nothing.
    @Test func anExhaustedSpendStaysOwedAndARestoredPauseNeverResumes() async throws {
        let (h, a, genuine, until) = try await pausedThenHidden()
        defer { h.dir.cleanup() }
        let h2 = try await r2.relaunch(h)
        let agent = ProbeResumeAgent()
        agent.status = .enabled
        h2.env.connection.resumeAgent = agent
        h.keychain.failure.withLock { $0 = errSecInteractionNotAllowed }     // stays unavailable through every retry
        h2.env.connection.timerSleep = Self.instantRetries
        h2.env.connection.start()
        await h2.env.connection.awaitPauseValueSpend()
        #expect(h2.env.settings.value.pauseValueOwed)
        await h2.env.settings.flush()
        #expect(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)?.pauseValueOwed == true)
        await h2.env.connection.reconcileResumeAgent()
        #expect(agent.calls.isEmpty)                                           // kept for the owed spend
        h.keychain.failure.withLock { $0 = nil }                               // the keychain recovers
        try await r2.editSettingsFile(h2) { $0.pausedState = genuine; $0.autoConnect.pausedUntil = until }
        let starts = h.managers.starts.count
        let h3 = try await r2.relaunch(h2)
        h3.env.connection.start()
        await h3.env.connection.resume().value                                 // the pause's end
        #expect(await never { h.managers.starts.count > starts })
        #expect(h3.service.state.withLock { $0.arms.isEmpty })
        #expect(!h3.env.settings.value.pauseValueOwed)
        #expect(a.id == genuine.profileID)
    }

    /// The same debt is spent by the next `load()` or wake once the keychain recovers (then the kept agent goes).
    @Test(arguments: [false, true]) func anOwedValueIsSpentAtTheNextLoadOrWake(wake: Bool) async throws {
        let (h, a, genuine, until) = try await pausedThenHidden()
        defer { h.dir.cleanup() }
        let h2 = try await r2.relaunch(h)
        let agent = ProbeResumeAgent()
        agent.status = .enabled
        h2.env.connection.resumeAgent = agent
        h.keychain.failure.withLock { $0 = errSecInteractionNotAllowed }
        h2.env.connection.timerSleep = Self.instantRetries
        h2.env.connection.start()
        await h2.env.connection.awaitPauseValueSpend()
        #expect(h2.env.settings.value.pauseValueOwed)
        h.keychain.failure.withLock { $0 = nil }
        if wake { h2.env.connection.didWake() } else { await h2.env.profiles.load() }
        await h2.env.connection.awaitPauseValueSpend()
        #expect(!h2.env.settings.value.pauseValueOwed)
        #expect(agent.calls.contains { $0.hasPrefix("unregister") })
        #expect(await ConnectionStore.checkResumeIntent(genuine, profileID: a.id, until: until, now: Date(),
                                                        repository: h2.env.profiles.repository) == .changedOutside)
    }

    /// Fable r6 N4b: at a pause's end the record checks, but the delete right after fails: the session is reconnected
    /// (the user's pause), the value is owed and the agent kept; after the keychain recovers, the retry spends it, so
    /// the record copied before never verifies again. Kills: ignoring `consumeRecord`'s result in `resume()`.
    @Test func aFailedSpendAtThePausesEndStaysOwedUntilItSucceeds() async throws {
        let w = try await nn.world()
        defer { w.h.dir.cleanup() }
        let agent = ProbeResumeAgent()
        w.h.env.connection.resumeAgent = agent
        await nn.refused(w)                                                   // our Connect, held: a signed target
        await w.h.env.connection.pause(minutes: 5)
        let genuine = try #require(w.h.env.settings.value.pausedState)
        let until = try #require(w.h.env.settings.value.autoConnect.pausedUntil)
        #expect(genuine.profileID == w.work.id && genuine.intent != nil)
        w.net.change(to: NoNetworkRestartTests.online)
        w.h.keychain.deleteFailure.withLock { $0 = errSecInteractionNotAllowed }
        await w.h.env.connection.resume().value
        #expect(await eventually { w.h.managers.starts.count == 2 })          // reconnected
        #expect(w.h.env.settings.value.pauseValueOwed)
        #expect(!agent.calls.contains { $0.hasPrefix("unregister") })
        w.h.keychain.deleteFailure.withLock { $0 = nil }
        await w.timers.fire(.seconds(30))                                     // the owed spend's retry
        await w.h.env.connection.awaitPauseValueSpend()
        #expect(!w.h.env.settings.value.pauseValueOwed)
        #expect(await ConnectionStore.checkResumeIntent(genuine, profileID: w.work.id, until: until, now: Date(),
                                                        repository: w.h.env.profiles.repository) == .changedOutside)
    }

    /// The agent: a value owed from an earlier run goes before any check; while it can't, nothing changes. The genuine
    /// record and expiry written back then restart nothing.
    @Test func theAgentSpendsAnOwedValueBeforeAnyCheck() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let until = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        var s = AppSettings()
        s.autoConnect.pausedUntil = until
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1",
                                   intent: await resumeIntent(work.id, until: until, keychain: h.keychain, dir: h.dir.data))
        s.pauseValueOwed = true
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        let agent = ProbeResumeAgent()
        h.keychain.deleteFailure.withLock { $0 = errSecInteractionNotAllowed }
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service) == .keychainUnavailable)
        #expect(h.managers.starts.isEmpty && agent.calls.isEmpty)
        h.keychain.deleteFailure.withLock { $0 = nil }
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain, service: h.service)
        #expect(r == .resumed(restarted: nil, onDemand: []))
        #expect(h.managers.starts.isEmpty)
        #expect(h.service.state.withLock { $0.arms.isEmpty })
        #expect(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)?.pauseValueOwed == false)
    }

    /// The agent: the delete right before its start fails: it restarts the profile, records the debt and stays
    /// registered; its next run (nothing paused) spends it and unregisters.
    @Test func theAgentStaysRegisteredWhileTheValueIsOwed() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        var s = AppSettings()
        s.autoConnect.pausedUntil = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1",
                                   intent: await resumeIntent(work.id, until: s.autoConnect.pausedUntil!, keychain: h.keychain, dir: h.dir.data))
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        let agent = ProbeResumeAgent()
        h.keychain.deleteFailure.withLock { $0 = errSecInteractionNotAllowed }
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain, service: h.service)
        #expect(r == .resumed(restarted: work.id, onDemand: []))
        #expect(agent.calls.isEmpty)
        #expect(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)?.pauseValueOwed == true)
        h.keychain.deleteFailure.withLock { $0 = nil }
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain) == .nothingPaused)
        #expect(agent.calls.count == 1 && agent.calls[0].hasPrefix("unregister"))
        #expect(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)?.pauseValueOwed == false)
    }

    /// A pause of a live session, then quit, then other code removes `pausedUntil` (Codex r6 #3's first steps).
    func pausedThenHidden() async throws -> (Harness, Profile, PausedState, Date) {
        let h = Harness()
        let a = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        try await h.env.managers.loadAll()
        h.env.connection.start()
        await Round4FixTests().connected(h, a)
        await h.env.connection.pause(minutes: 5)
        let genuine = try #require(h.env.settings.value.pausedState)
        let until = try #require(h.env.settings.value.autoConnect.pausedUntil)
        #expect(genuine.profileID == a.id && genuine.intent != nil)
        #expect(await eventually { h.managers.stops.contains(a.id) })
        h.managers.emit(a.id, .disconnected)
        try await r2.editSettingsFile(h) { $0.autoConnect.pausedUntil = nil }
        return (h, a, genuine, until)
    }
}

/// 2.0.2 review round 7 (Fable r7 L1, L2, N1–N3; Codex r7 #1–#3): the app side.
@MainActor @Suite(.timeLimit(.minutes(1)), .serialized) struct Round7FixTests {
    let r2 = Round2FixTests()
    let r6 = Round6FixTests()
    let nn = NoNetworkRestartTests()

    func never(_ condition: () -> Bool) async -> Bool { await nn.never(condition) }

    // MARK: Fable r7 L1: NE's restart of a signable hold stays signable while it is `.connecting`

    /// Our Connect refused for want of a network (a signable network-restart hold); the network returns and NE restarts
    /// P (`.connecting`); Pause: P is signed, stopped, and started at the pause's end. Kills: clearing `resumableSession`
    /// at that unissued new attempt although it is the restart of a signable hold (`wasSignableHold`).
    @Test func neRestartOfOurRefusedStartPausedWhileConnectingIsSignedAndReconnected() async throws {
        let w = try await nn.world()
        defer { w.h.dir.cleanup() }
        w.h.env.profiles.extensionCapabilities = [.startAuthorisation]
        await nn.refused(w)
        w.net.change(to: NoNetworkRestartTests.online)
        w.h.managers.emit(w.work.id, .connecting)                         // NE's own restart
        #expect(await eventually { w.h.env.connection.statuses[w.work.id] == .connecting })
        await pausedWhileConnectingReconnects(w.h, w.work.id)
    }

    /// The same after a tunnel-process crash of our connected kill-switch session: NE's restart is `.connecting`; Pause.
    @Test func neRestartAfterACrashPausedWhileConnectingIsSignedAndReconnected() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        h.env.connection.crashRestartGrace = .zero
        h.env.connection.timerSleep = FakeTimers().sleeper
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        h.env.connection.start()
        await Round4FixTests().connected(h, p)
        HeldStartRecoveryTests().crashed(h, p.id)
        #expect(await eventually { h.env.connection.crashGapHolder == p.id })
        h.managers.emit(p.id, .connecting)                                // NE's own restart
        #expect(await eventually { h.env.connection.statuses[p.id] == .connecting })
        await pausedWhileConnectingReconnects(h, p.id)
    }

    func pausedWhileConnectingReconnects(_ h: Harness, _ id: UUID) async {
        await h.env.connection.pause(minutes: 5)
        #expect(await eventually { h.managers.stops.contains(id) })
        #expect(h.env.settings.value.pausedState?.profileID == id && h.env.settings.value.pausedState?.intent != nil)
        h.managers.emit(id, .disconnected)
        let starts = h.managers.starts.count
        await h.env.connection.resume().value
        #expect(await eventually { h.managers.starts.count == starts + 1 })
        #expect(h.managers.starts.last?.0 == id)
    }

    // MARK: Codex r7 #2 = Fable r7 N1: the agent records a failed spend before any return

    /// Other code removes the target of a genuine expired pause and names a live session in `networkRestartHold`; the
    /// agent's spend fails and it returns `.networkRestartPending`: the debt is on disk already. The keychain recovers,
    /// the genuine target is written back and the hold removed: the next run spends the owed value first and arms and
    /// starts nothing. Kills: a failed spend that is only written at the run's end (`saveOwed()` after the checks).
    @Test func aFailedSpendBeforeANetworkRestartPendingReturnStaysOwed() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let until = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        let genuine = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1",
                                  intent: await resumeIntent(work.id, until: until, keychain: h.keychain, dir: h.dir.data))
        var s = AppSettings()
        s.autoConnect.pausedUntil = until
        s.pausedState = genuine
        s.pausedState?.profileID = nil                                        // the target removed
        s.networkRestartHold = work.id                                        // a live session named as NE's restart
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        h.managers.emit(work.id, .connecting)
        let agent = ProbeResumeAgent()
        h.keychain.deleteFailure.withLock { $0 = errSecInteractionNotAllowed }
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service) == .networkRestartPending)
        #expect(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)?.pauseValueOwed == true)
        #expect(agent.calls.isEmpty)
        h.keychain.deleteFailure.withLock { $0 = nil }                        // the keychain recovers
        var back = try #require(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings))
        back.pausedState = genuine
        back.networkRestartHold = nil
        try AtomicFile.saveJSON(back, to: h.dir.data.settings)
        h.managers.emit(work.id, .disconnected)
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain, service: h.service)
        #expect(r == .resumed(restarted: nil, onDemand: []))
        #expect(h.managers.starts.isEmpty)
        #expect(h.service.state.withLock { $0.arms.isEmpty })
        #expect(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)?.pauseValueOwed == false)
    }

    // MARK: Codex r7 #3 = Fable r7 N2: the launch's reconcile waits for the launch's spend

    /// Nothing paused at launch, a registered agent; the launch's spend (its delete slow, then failing) is pending when
    /// the launch reconciles the agent right after `start()`, as `AppEnvironment` does: the agent is kept; the spend
    /// fails through its retries (owed); still kept. After the keychain recovers, the next `load()` spends it and the
    /// agent goes. Kills: reconcile unregistering while the launch's spend is pending.
    @Test func theLaunchReconcileKeepsTheAgentWhileTheInitialSpendIsPending() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        try await h.env.managers.loadAll()
        let agent = ProbeResumeAgent()
        agent.status = .enabled
        h.env.connection.resumeAgent = agent
        h.env.connection.timerSleep = Round6FixTests.instantRetries
        let gate = AsyncStream<Void>.makeStream()
        h.keychain.beforeDelete.withLock { $0 = { for await _ in gate.stream { return } } }
        h.keychain.deleteFailure.withLock { $0 = errSecInteractionNotAllowed }
        h.env.connection.start()
        await h.env.connection.reconcileResumeAgent()                         // the launch's, right after `start()`
        #expect(agent.calls.isEmpty)
        #expect(!h.env.settings.value.pauseValueOwed)                         // the delete hasn't failed yet
        h.keychain.beforeDelete.withLock { $0 = nil }
        gate.continuation.finish()
        await h.env.connection.awaitPauseValueSpend()
        #expect(h.env.settings.value.pauseValueOwed)
        #expect(agent.calls.isEmpty)
        h.keychain.deleteFailure.withLock { $0 = nil }
        await h.env.profiles.load()
        await h.env.connection.awaitPauseValueSpend()
        #expect(!h.env.settings.value.pauseValueOwed)
        #expect(agent.calls.count == 1 && agent.calls.first?.hasPrefix("unregister") == true)
    }

    // MARK: Fable r7 N3: extending a pause while a value is owed carries nothing

    /// The value is owed (exhausted spend); the genuine record and expiry are written back (the pause runs again); the
    /// owner's Pause extends it: the old record's profile is not carried (it would verify against the surviving value).
    /// Kills: carrying the old record's profile while `pauseValueOwed`.
    @Test func extendingAPauseWhileAValueIsOwedCarriesNoProfile() async throws {
        let (h, _, genuine, until) = try await r6.pausedThenHidden()
        defer { h.dir.cleanup() }
        let h2 = try await r2.relaunch(h)
        h.keychain.failure.withLock { $0 = errSecInteractionNotAllowed }
        h2.env.connection.timerSleep = Round6FixTests.instantRetries
        h2.env.connection.start()
        await h2.env.connection.awaitPauseValueSpend()
        #expect(h2.env.settings.value.pauseValueOwed)
        h.keychain.failure.withLock { $0 = nil }
        try await r2.editSettingsFile(h2) { $0.pausedState = genuine; $0.autoConnect.pausedUntil = until }
        let h3 = try await r2.relaunch(h2)
        h3.env.connection.timerSleep = FakeTimers().sleeper
        h3.env.connection.start()
        #expect(h3.env.settings.value.pauseValueOwed)
        await h3.env.connection.pause(minutes: 10)
        #expect(h3.env.settings.value.pausedState?.profileID == nil)
        #expect(h3.env.settings.value.pausedState?.intent == nil)
    }

    // MARK: Fable r7 L2 = Codex r7 #1: DOCUMENTED RESIDUAL (DESIGN §20 risk 31 (b), D10.10-3)

    /// DOCUMENTED RESIDUAL, not a guarantee: this test asserts today's behaviour so a change to it is noticed. A copy of
    /// the whole settings.json taken during a genuine pause is written back after the value became owed (the
    /// data-protection keychain's delete failed through a whole GUI run): the copy carries `pauseValueOwed: false`, so the
    /// pause's end checks the genuine record against the surviving value and P is armed and started. The precondition is
    /// a delete failing through a whole GUI run, which same-user code isn't known to be able to cause; the gain is at most
    /// one unattended start of the owner's own verified profile within `ResumeIntent.maxAge` of the pause's end. No full
    /// cure without storage the same user can't write.
    @Test func documentedResidualAWholeSettingsRollbackClearsTheDebtAndThePauseResumes() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let a = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        try await h.env.managers.loadAll()
        h.env.connection.start()
        await Round4FixTests().connected(h, a)
        await h.env.connection.pause(minutes: 5)
        #expect(h.env.settings.value.pausedState?.profileID == a.id)
        #expect(await eventually { h.managers.stops.contains(a.id) })
        h.managers.emit(a.id, .disconnected)
        await h.env.settings.flush()
        let copy = try Data(contentsOf: h.dir.data.settings)                  // the whole file, during the pause
        try await r2.editSettingsFile(h) { $0.autoConnect.pausedUntil = nil }
        let h2 = try await r2.relaunch(h)
        h.keychain.failure.withLock { $0 = errSecInteractionNotAllowed }
        h2.env.connection.timerSleep = Round6FixTests.instantRetries
        h2.env.connection.start()
        await h2.env.connection.awaitPauseValueSpend()
        #expect(h2.env.settings.value.pauseValueOwed)
        h.keychain.failure.withLock { $0 = nil }
        await h2.env.settings.flush()
        try copy.write(to: h.dir.data.settings)                               // the whole copy back: owed flag false
        let starts = h.managers.starts.count
        let h3 = try await r2.relaunch(h2)
        #expect(!h3.env.settings.value.pauseValueOwed)
        h3.env.connection.start()
        await h3.env.connection.resume().value
        #expect(await eventually { h.managers.starts.count == starts + 1 })   // the residual: P is started
        #expect(!h3.service.state.withLock { $0.arms.isEmpty })
    }
}
