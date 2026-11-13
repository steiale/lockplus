import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import Testing
@testable import LockPlus

/// 2.0.2 review round 5 (Fable r5 L2 = Codex r5 #2, Codex r5 #5, #7): the app side.
@MainActor @Suite(.timeLimit(.minutes(1)), .serialized) struct Round5FixTests {
    let r2 = Round2FixTests()
    let nn = NoNetworkRestartTests()

    func never(_ condition: () -> Bool) async -> Bool { await nn.never(condition) }

    // MARK: Fable r5 L2 = Codex r5 #2: a refused start made elsewhere is never a pause's signed target

    /// A start of the owner's kill-switch profile made elsewhere (`scutil --nc start`) ends without ever being active:
    /// online (225 or no error yet: the "start ended early" hold) and offline (NE's "No network available": the
    /// network-restart hold, sealed by this run). Pause inside that hold stops it but signs nothing, and its end arms and
    /// starts nothing.
    @Test func aRefusedOutsideStartPausedInItsHoldIsNeverSigned() async throws {
        for offline in [false, true] {
            let w = try await nn.world(offline ? NoNetworkRestartTests.offline : NoNetworkRestartTests.online)
            defer { w.h.dir.cleanup() }
            w.h.env.profiles.extensionCapabilities = [.startAuthorisation]
            w.h.managers.lastError = offline ? nn.noNetwork : nil
            w.h.managers.emit(w.work.id, .disconnecting)                    // the start made elsewhere, refused
            w.h.managers.emit(w.work.id, .disconnected)
            #expect(await eventually { w.h.env.connection.startHold?.reason == (offline ? .awaitingNetwork : .startEndedEarly) })
            await w.h.env.connection.pause(minutes: 5)
            #expect(await eventually { w.h.managers.stops.contains(w.work.id) })   // the pause still holds
            #expect(w.h.env.settings.value.pausedState?.profileID == nil)
            #expect(w.h.env.settings.value.pausedState?.intent == nil)
            w.net.change(to: NoNetworkRestartTests.online)
            let starts = w.h.managers.starts.count
            await w.h.env.connection.resume().value
            #expect(await never { w.h.managers.starts.count > starts })
            #expect(w.h.service.state.withLock { $0.arms.isEmpty })
        }
    }

    /// The same hold after this app's own Connect (an issued start NE refused for want of a network) stays a target.
    @Test func ourRefusedStartPausedInItsHoldIsStillResumed() async throws {
        let w = try await nn.world()
        defer { w.h.dir.cleanup() }
        await nn.refused(w)
        await w.h.env.connection.pause(minutes: 5)
        #expect(w.h.env.settings.value.pausedState?.profileID == w.work.id && w.h.env.settings.value.pausedState?.intent != nil)
    }

    // MARK: Codex r5 #5: "nothing paused" spends the pause's one-time value

    /// The agent: a genuine expired pause whose `pausedUntil` was removed is seen as "nothing paused" (and the value
    /// spent; a keychain that can't delete it now keeps the agent registered for the next run). Written back with its
    /// expiry, it arms and starts nothing.
    @Test func theAgentSpendsThePauseValueWhenNothingIsPaused() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        try await h.env.managers.loadAll()
        let until = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        let intent = await resumeIntent(work.id, until: until, keychain: h.keychain, dir: h.dir.data)
        var s = AppSettings()
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1", intent: intent)
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)              // other code removed `pausedUntil`
        let agent = ProbeResumeAgent()
        h.keychain.failure.withLock { $0 = errSecInteractionNotAllowed }
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain) == .keychainUnavailable)
        #expect(agent.calls.isEmpty)                                     // still registered: the next run retries
        h.keychain.failure.withLock { $0 = nil }
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain) == .nothingPaused)
        s.autoConnect.pausedUntil = until                                // the genuine record and expiry written back
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain,
                                             service: h.service)
        #expect(r == .resumed(restarted: nil, onDemand: []))
        #expect(h.managers.starts.isEmpty)
        #expect(h.service.state.withLock { $0.arms.isEmpty })
    }

    /// The GUI: a pause of a live session → quit → other code removes `pausedUntil` → the launch sees nothing paused
    /// and spends the value (retried while the keychain fails) → the genuine record and expiry written back → a relaunch
    /// arms and starts nothing.
    @Test func theLaunchSpendsThePauseValueWhenNothingIsPaused() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let a = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        try await h.env.managers.loadAll()
        h.env.connection.start()
        await Round4FixTests().connected(h, a)
        await h.env.connection.pause(minutes: 5)
        let genuine = try #require(h.env.settings.value.pausedState)
        let until = try #require(h.env.settings.value.autoConnect.pausedUntil)
        #expect(genuine.profileID == a.id && genuine.intent != nil)
        h.managers.emit(a.id, .disconnected)
        try await r2.editSettingsFile(h) { $0.autoConnect.pausedUntil = nil }
        let h2 = try await r2.relaunch(h)
        h.keychain.failure.withLock { $0 = errSecInteractionNotAllowed }  // the launch's first delete fails
        h2.env.connection.timerSleep = { [keychain = h.keychain] _ in keychain.failure.withLock { $0 = nil } }
        h2.env.connection.start()
        await h2.env.connection.awaitPauseValueSpend()
        h.keychain.failure.withLock { $0 = nil }
        #expect(await ConnectionStore.checkResumeIntent(genuine, profileID: a.id, until: until, now: Date(),
                                                        repository: h2.env.profiles.repository) == .changedOutside)
        try await r2.editSettingsFile(h2) { $0.pausedState = genuine; $0.autoConnect.pausedUntil = until }
        let starts = h.managers.starts.count
        let h3 = try await r2.relaunch(h2)
        h3.env.connection.start()
        await h3.env.connection.resume().value                          // the pause's end
        #expect(await never { h.managers.starts.count > starts })
        #expect(h3.service.state.withLock { $0.arms.isEmpty })
    }

    // MARK: Codex r5 #7: an "off" left unsealed by a quit is sealed at the next launch, also after a locked keychain

    /// Auto-Connect on (its tag copied) → turned off while the keychain is unavailable (the seal fails) → quit → relaunch
    /// still unavailable: the seal is owed → the keychain recovers and the next `load()` seals "off" → the copied enabled
    /// choice written back gives no plan.
    @Test func anOffUnsealedAcrossARelaunchIsSealedWhenTheKeychainRecovers() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.env.profiles.sealRetrySleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = work.id }
        await h.env.profiles.awaitAutoConnectSeal()
        let copy = h.env.settings.value.autoConnect
        h.keychain.failure.withLock { $0 = errSecNotAvailable }
        h.env.settings.update { $0.autoConnect.enabled = false }
        await h.env.profiles.awaitAutoConnectSeal()
        #expect(h.env.profiles.autoConnectSealOwed)
        let h2 = try await r2.relaunch(h)                               // quit before the retry; still unavailable
        await h2.env.profiles.awaitAutoConnectSeal()
        #expect(h2.env.profiles.autoConnectSealOwed)
        h.keychain.failure.withLock { $0 = nil }
        await h2.env.profiles.load()
        await h2.env.profiles.awaitAutoConnectSeal()
        #expect(!h2.env.profiles.autoConnectSealOwed)
        #expect(h2.env.settings.value.autoConnect.choiceTag != nil)
        try await r2.editSettingsFile(h2) { $0.autoConnect = copy }
        let h3 = try await r2.relaunch(h2)
        #expect(h3.env.profiles.onDemandPlan(for: work) == nil)
        #expect(!h3.env.settings.value.autoConnect.enabled)
    }
}
