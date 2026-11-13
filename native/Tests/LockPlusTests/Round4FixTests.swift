import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import Testing
@testable import LockPlus

/// 2.0.2 review round 4 (Codex r4 #4; Fable L2a, L2d, N4–N6): the app side.
@MainActor @Suite(.timeLimit(.minutes(1)), .serialized) struct Round4FixTests {
    let r2 = Round2FixTests()
    let nn = NoNetworkRestartTests()

    func relaunch(_ h: Harness) async throws -> Harness { try await r2.relaunch(h) }

    func connected(_ h: Harness, _ p: Profile) async {
        let n = h.managers.starts.count
        h.env.connection.connect(p.id)
        _ = await eventually { h.managers.starts.count == n + 1 }
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        _ = await eventually { h.env.connection.statuses[p.id] == .connected }
    }

    // MARK: Fable L2a: the hello

    /// A failed hello is retried; the capabilities are known after it.
    @Test func aFailedHelloIsRetried() async throws {
        let w = try await nn.world()
        defer { w.h.dir.cleanup() }
        let gate = AsyncStream<Void>.makeStream()
        w.h.env.helloRetrySleep = { _ in for await _ in gate.stream { return } }
        w.h.service.state.withLock { $0.helloError = LPError(.extensionUnavailable) }
        w.h.env.helloAndReconcile()
        #expect(await nn.never { w.h.env.profiles.extensionCapabilities != nil })
        w.h.service.state.withLock { $0.helloError = nil }
        gate.continuation.yield()
        #expect(await eventually { w.h.env.profiles.extensionCapabilities != nil })
    }

    // MARK: Fable L2d: Pause in a crash gap

    /// A watched kill-switch session crashed and NE's restart is awaited (`.awaitingRestart`): Pause stops it (the
    /// restart is cancelled) and signs it as the pause's target (round 5: this run saw it Connected), so the pause's end
    /// reconnects it.
    @Test func pauseInACrashGapStopsAndResumesIt() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        h.env.connection.crashRestartGrace = .zero
        h.env.connection.timerSleep = FakeTimers().sleeper
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        h.env.connection.start()
        await connected(h, p)
        HeldStartRecoveryTests().crashed(h, p.id)
        #expect(await eventually { h.env.connection.crashGapHolder == p.id })
        await h.env.connection.pause(minutes: 5)
        #expect(await eventually { h.managers.stops.contains(p.id) })
        #expect(h.env.connection.crashGapHolder == nil)
        #expect(h.env.settings.value.pausedState?.profileID == p.id && h.env.settings.value.pausedState?.intent != nil)
        h.managers.emit(p.id, .disconnected)
        let starts = h.managers.starts.count
        await h.env.connection.resume().value
        #expect(await eventually { h.managers.starts.count == starts + 1 })
        #expect(h.managers.starts.last?.0 == p.id)
    }

    // MARK: Codex r4 #4: the pause's one-time value is spent when the record names no profile

    /// Genuine pause of a live session → other code removes `pausedState.profileID` before the end → the pause ends (no
    /// reconnect) → the genuine record written back never verifies, and a relaunch starts nothing.
    @Test func aPauseWhoseProfileWasRemovedSpendsTheOneTimeValue() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let a = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        try await h.env.managers.loadAll()
        h.env.connection.start()
        await connected(h, a)
        await h.env.connection.pause(minutes: 5)
        let genuine = try #require(h.env.settings.value.pausedState)
        let until = try #require(h.env.settings.value.autoConnect.pausedUntil)
        #expect(genuine.profileID == a.id)
        h.managers.emit(a.id, .disconnected)
        h.env.settings.update { $0.pausedState?.profileID = nil }
        let starts = h.managers.starts.count
        await h.env.connection.resume().value
        #expect(h.managers.starts.count == starts)
        #expect(await ConnectionStore.checkResumeIntent(genuine, profileID: a.id, until: until, now: Date(),
                                                        repository: h.env.profiles.repository) != .holds)
        // The same with no record at all.
        await h.env.connection.pause(minutes: 5)
        let second = try #require(h.env.settings.value.pausedState)
        let until2 = try #require(h.env.settings.value.autoConnect.pausedUntil)
        h.env.settings.update { $0.pausedState = nil }
        await h.env.connection.resume().value
        #expect(await ConnectionStore.checkResumeIntent(second, profileID: a.id, until: until2, now: Date(),
                                                        repository: h.env.profiles.repository) != .holds)
    }

    @Test func theAgentSpendsThePauseValueWhenTheRecordNamesNoProfile() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        try await h.env.managers.loadAll()
        let until = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        let intent = await resumeIntent(work.id, until: until, keychain: h.keychain, dir: h.dir.data)
        let genuine = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1", intent: intent)
        var s = AppSettings()
        s.autoConnect.pausedUntil = until
        s.pausedState = genuine
        s.pausedState?.profileID = nil                                   // other code, before the end
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(r == .resumed(restarted: nil, onDemand: []))
        // The genuine record written back: refused, nothing armed or started.
        s.pausedState = genuine
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        let r2 = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain,
                                              service: h.service)
        #expect(r2 == .resumed(restarted: nil, onDemand: []))
        #expect(h.managers.starts.isEmpty)
        #expect(h.service.state.withLock { $0.arms.isEmpty })
    }

    // MARK: Fable N4: an "off" that couldn't be sealed is sealed later

    @Test func anOffThatCouldNotBeSealedIsSealedLater() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.env.profiles.sealRetrySleep = { _ in try? await Task.sleep(for: .seconds(3600)) }   // only the explicit retry below
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = work.id }
        await h.env.profiles.awaitAutoConnectSeal()
        let copy = h.env.settings.value.autoConnect
        h.keychain.failure.withLock { $0 = -25308 }
        h.env.settings.update { $0.autoConnect.enabled = false }
        await h.env.profiles.awaitAutoConnectSeal()
        #expect(h.env.profiles.autoConnectSealOwed && h.env.settings.value.autoConnect.choiceTag == nil)
        h.keychain.failure.withLock { $0 = nil }
        h.env.profiles.retryOwedSeal()
        await h.env.profiles.awaitAutoConnectSeal()
        #expect(!h.env.profiles.autoConnectSealOwed)
        #expect(h.env.settings.value.autoConnect.choiceTag != nil)
        try await r2.editSettingsFile(h) { $0.autoConnect = copy }
        let replayed = try await relaunch(h)
        #expect(replayed.env.profiles.onDemandPlan(for: work) == nil)
        #expect(!replayed.env.settings.value.autoConnect.enabled)
    }

    // MARK: Fable N5: an orphaned kill-switch configuration and its copy outlast NE's restart gap

    /// A kill-switch profile's file vanishes (same-user tampering) while NE may be about to restart its session in a gap
    /// this run doesn't track: its configuration is kept for the grace, and its extension copy as long as the configuration
    /// exists; after the grace both go.
    @Test func anOrphanedKillSwitchConfigurationAndItsCopyOutlastTheGrace() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let gone = try await h.add("Home NAS.conf", Harness.splitConf, killSwitch: true)
        var clock = Date()
        h.env.profiles.now = { clock }
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        await h.env.profiles.load()
        await h.env.profiles.reconcile()
        let orphan = gone.id
        h.managers.entries[orphan] = .init(cfg: ManagerConfiguration(profile: gone, onDemand: nil), status: .disconnected, onDemand: false)
        try await h.env.managers.loadAll()
        #expect(h.service.state.withLock { $0.provisioned[orphan] } != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: h.dir.data.profiles.path).filter { $0.hasPrefix(orphan.uuidString) }
        for f in files { try FileManager.default.removeItem(at: h.dir.data.profiles.appending(path: f)) }
        await h.env.profiles.load()
        #expect(h.env.profiles.profile(orphan) == nil)
        #expect(h.managers.entries[orphan] != nil)                       // kept for the grace
        let removals = h.service.calls(.removeProfile)
        await h.env.profiles.reconcile()
        #expect(h.service.calls(.removeProfile) == removals)
        #expect(h.env.settings.value.pendingRemovals == [orphan])
        clock = clock.addingTimeInterval(ProfilesStore.orphanKillSwitchGrace + 1)
        await h.env.profiles.load()
        #expect(h.managers.entries[orphan] == nil)
        await h.env.profiles.reconcile()
        #expect(h.service.calls(.removeProfile) == removals + 1)
        #expect(h.env.settings.value.pendingRemovals.isEmpty)
    }

    // MARK: Fable N6

    /// A consume of the hold's record queued right before a seal runs before it: the seal's tag verifies.
    @Test func aHoldSealedRightAfterAConsumeKeepsItsValue() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let id = UUID()
        _ = try await h.env.profiles.repository.sealRecord(.networkRestartHold, AppSettings.networkRestartHoldMessage(id))
        h.env.connection.consumeHoldRecord()
        let tag = await h.env.connection.holdRecordOp { repo in
            try? await repo.sealRecord(.networkRestartHold, AppSettings.networkRestartHoldMessage(id))
        }
        await h.env.connection.awaitHoldRecordOps()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await h.env.profiles.repository.checkRecord(.networkRestartHold, tag: tag, AppSettings.networkRestartHoldMessage(id)) == .valid)
    }
}
