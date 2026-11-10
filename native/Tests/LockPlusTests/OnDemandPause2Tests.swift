import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import Testing
@testable import LockPlus

/// Fable review 2026-10-30, second round (docs/native/reviews/2026-10-30-fable-ondemand-pause-2.md): R1–R12, the nits
/// and the missing tests the review lists.
@MainActor @Suite("On-demand pause review 2 (R1–R12)", .serialized)
struct OnDemandPause2Tests {
    func autoProfile(_ h: Harness) async throws -> Profile {
        let p = try await h.add("Home NAS.conf", Harness.splitConf)
        h.env.settings.update {
            $0.autoConnect.enabled = true
            $0.autoConnect.profileID = p.id
        }
        await h.env.profiles.resaveOnDemand()
        try await h.env.managers.loadAll()
        return p
    }

    func setUp(_ h: Harness) async throws -> (auto: Profile, work: Profile) {
        let auto = try await autoProfile(h)
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        h.managers.onDemandChanges = [:]
        h.env.connection.start()
        return (auto, work)
    }

    func connected(_ h: Harness, _ work: Profile) async {
        h.env.connection.connect(work.id)
        _ = await eventually { h.managers.starts.count == 1 }
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
    }

    var pluginFailed: NSError { NSError(domain: NEVPNConnectionErrorDomain, code: 12) }

    func saves(_ h: Harness) -> Int { h.managers.log.filter { $0.hasPrefix("begin save") }.count }

    /// A clock for which every sleep is followed by another configuration change: a steady stream that never settles.
    func streamingClock(_ inner: FakeVPNManager) -> SettleClock {
        let t = Mutex<Duration>(.zero)
        let managers = inner
        return SettleClock(now: { t.withLock { $0 } }, sleep: { d in
            t.withLock { $0 += d }
            await MainActor.run { managers.onConfigurationChange?() }
        })
    }

    // MARK: R1

    /// NE restarts a crashed kill-switch profile without on-demand rules ≈2–3 s after `.disconnected`. With the app's
    /// own grace at 300 ms, nothing is saved before that restart (a save inside NE's pending start is the 200003 mode).
    /// The claim doesn't depend on the 3 s: 500 ms (past the grace) distinguishes it from a grace-based restore.
    @Test func neRestartThreeSecondsAfterTheDisconnectIsNotRacedBySaves() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        h.env.connection.crashRestartGrace = .milliseconds(300)
        await connected(h, work)
        h.managers.log = []
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.fetchCount >= 1 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(saves(h) == 0)                                          // grace over, NE not back yet: still nothing
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.connection.holdsBackOnDemand(of: auto.id))
        h.managers.emit(work.id, .connecting)                           // NE's own restart, 3 s after `.disconnected`
        h.managers.emit(work.id, .connected)
        #expect(saves(h) == 0)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    // MARK: R2

    /// Auto-Connect turned on for B while X runs (moved from A): nothing is saved meanwhile (R3), and when X ends B comes
    /// on, A (no longer the auto profile) stays off and the record is empty.
    @Test func autoConnectEnabledForAnotherProfileWhileXRunsIsAppliedWhenXEnds() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let b = try await h.add("Cabin.conf", Harness.splitConf)
        try await h.env.managers.loadAll()
        await connected(h, work)
        h.managers.log = []
        h.env.settings.update { $0.autoConnect.profileID = b.id }
        await h.env.profiles.resaveOnDemand()
        #expect(saves(h) == 0)
        #expect(h.env.profiles.hasDeferredSync)
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[b.id]?.onDemand == true })
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
    }

    /// The restore set is the record plus every profile whose plan wants on-demand while its manager is off.
    @Test func theRestoreSetIncludesAProfileWhosePlanWantsOnDemand() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let b = try await h.add("Cabin.conf", Harness.splitConf)
        try await h.env.managers.loadAll()
        await connected(h, work)
        h.env.settings.update { $0.autoConnect.profileID = b.id }       // no resave: only the plan changed
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[b.id]?.onDemand == true })
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
    }

    /// Nit: a status event with nothing to restore does not flip the observable `restoring`.
    @Test func aStatusEventWithNothingToRestoreDoesNotFlipRestoring() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        #expect(h.env.settings.value.onDemandPausedByStart.isEmpty)
        h.managers.emit(work.id, .disconnected)
        #expect(!h.env.connection.restoring)
        h.managers.emit(work.id, .invalid)
        #expect(!h.env.connection.restoring)
    }

    // MARK: R3

    /// A rule edit (or Add Current Network) inside the start window saves no manager; it runs when idle.
    @Test func aRuleEditInTheStartWindowSavesNothingUntilIdle() async throws {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)
        let (_, work) = try await setUp(h)
        let b = try await h.add("Cabin.conf", Harness.splitConf)
        try await h.env.managers.loadAll()
        let env = h.env
        let managers = h.managers
        let during = LockBox<[Int]>([])
        let bID = b.id
        fake.onFirstSleep {
            await MainActor.run { env.settings.update { $0.autoConnect.profileID = bID } }
            let before = await MainActor.run { managers.log.filter { $0.hasPrefix("begin save") }.count }
            await env.profiles.resaveOnDemand()
            let after = await MainActor.run { managers.log.filter { $0.hasPrefix("begin save") }.count }
            during.set([before, after])
        }
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(during.value.count == 2 && during.value[0] == during.value[1])
        #expect(h.env.profiles.hasDeferredSync)
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[b.id]?.onDemand == true })
    }

    // MARK: R4

    /// GUI launch with X still running (restarted by the headless agent) and A's manager drifted: `profiles.load()`
    /// runs before `connection.start()` and must neither save A nor turn its on-demand on beside X.
    @Test func launchWithXRunningAndADriftedManagerLeavesAOff() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let auto = try await autoProfile(h)
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        h.managers.entries[auto.id]?.onDemand = false                  // paused by X's start in the previous instance
        h.env.settings.update { $0.onDemandPausedByStart = [auto.id] }
        h.managers.entries[work.id]?.status = .connected
        h.managers.entries[auto.id]?.cfg.flags.includeAllNetworks = true        // nehelper rewrote it
        try await h.env.managers.loadAll()                              // AppEnvironment.start(): managers first
        h.managers.log = []
        await h.env.profiles.load()                                     // AppEnvironment.start() order: before connection.start()
        #expect(saves(h) == 0)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        h.env.connection.start()
        try await Task.sleep(for: .milliseconds(80))                    // window: start()'s restoreIfIdle (no awaits before its save)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
    }

    // MARK: R5

    /// Pause while X is in its start window (`pausedState.profileID == nil`); the pause ends while X runs: A does not
    /// come on beside it; it comes back through the record when X ends.
    @Test func resumeWhileSomethingRunsHandsBackThroughTheRecord() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })      // started, no status yet
        await h.env.connection.pause(minutes: 5)
        #expect(h.env.settings.value.pausedState?.profileID == nil)
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        await h.env.connection.resume().value
        try await Task.sleep(for: .milliseconds(80))                    // window: a (wrong) restore after the hand-back
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        #expect(h.env.settings.value.pausedState == nil)
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
    }

    /// The same hand-back after an extension update (`ManagerQuiescer`): what was on goes through the record.
    @Test func resumeAfterAnUpdateHandsBackThroughTheRecord() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        h.managers.entries[work.id]?.status = .connected                // something runs
        h.env.settings.update { $0.pendingResume = PendingResume(profileID: nil, onDemandEnabledIDs: [auto.id], reason: .extensionUpdate) }
        h.managers.entries[auto.id]?.onDemand = false
        try await h.env.managers.loadAll()
        let q = ManagerQuiescer()
        q.attach(managers: h.managers, settings: h.env.settings, connection: h.env.connection)
        await q.resumeAfterUpdate()
        try await Task.sleep(for: .milliseconds(80))                    // window: a (wrong) restore after the hand-back
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        #expect(h.env.settings.value.pendingResume == nil)
        h.managers.emit(work.id, .disconnected)
        h.managers.entries[work.id]?.status = .disconnected
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    // MARK: R6

    /// The headless resume waits out the settle after its own saves before it starts.
    @Test func theHeadlessResumeSettlesBeforeTheStart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let fake = FakeSettleClock()
        let sm = SerializedVPNManager(inner: h.managers, settleClock: fake.clock)
        let work = try await h.add("Work.conf", Harness.wgConf)
        var s = AppSettings()
        s.autoConnect.pausedUntil = Date().addingTimeInterval(-5)
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [work.id], agentBuild: "1")
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        let managers = h.managers
        let startsAtSleep = LockBox<Int>(-1)
        fake.onFirstSleep { startsAtSleep.set(await MainActor.run { managers.starts.count }) }
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: sm, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(r == .resumed(restarted: work.id, onDemand: [work.id]))
        #expect(startsAtSleep.value == 0)                               // it settled BEFORE the start
        #expect(fake.sleeps == [.seconds(1)])
    }

    /// A configuration that never settles: no headless start, everything paused comes back, fail closed.
    @Test func aConfigurationThatNeverSettlesIsNoHeadlessStart() async throws {
        let inner = FakeVPNManager()
        let h = Harness(managers: inner)
        defer { h.dir.cleanup() }
        let sm = SerializedVPNManager(inner: inner, settleClock: streamingClock(inner))
        let work = try await h.add("Work.conf", Harness.wgConf)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        var s = AppSettings()
        s.autoConnect.pausedUntil = Date().addingTimeInterval(-5)
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [work.id, auto.id], agentBuild: "1")
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: sm, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(r == .resumed(restarted: nil, onDemand: [work.id, auto.id]))
        #expect(inner.starts.isEmpty)
    }

    /// Nit: the headless run never rebuilds `credential-facts.json` from the keychain.
    @Test func theHeadlessRunDoesNotRebuildCredentialFacts() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf)
        var s = AppSettings()
        s.autoConnect.pausedUntil = Date().addingTimeInterval(-5)
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1")
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        try? FileManager.default.removeItem(at: h.dir.data.credentialFacts)
        _ = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(!FileManager.default.fileExists(atPath: h.dir.data.credentialFacts.path))
    }

    // MARK: R7

    /// The F9 timeout abandons a start whose pre-start phase is slow: it never starts afterwards (X beside A enabled).
    @Test func aStartThatTimedOutBeforeItsStartNeverStarts() async throws {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.startingTimeout = .seconds(30)                 // released by hand
        let wedged = AsyncStream<Void>.makeStream()
        fake.onFirstSleep { for await _ in wedged.stream { break } }    // a wedged nesessionmanager, until released
        h.env.connection.connect(work.id)
        await timers.fire(.seconds(30))
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })     // the timeout restored A
        wedged.continuation.yield()                                     // the settle ends after the timeout
        try await Task.sleep(for: .milliseconds(200))                   // window: a (wrong) start after it
        #expect(h.managers.starts.isEmpty)
        #expect(h.managers.entries[auto.id]?.onDemand == true)
        #expect(h.env.settings.value.onDemandPausedByStart.isEmpty)
    }

    // MARK: R8

    /// A configuration that never settles within the cap is no start: noted, A restored.
    @Test func aStartWhoseConfigurationNeverSettlesFailsClosed() async throws {
        let inner = FakeVPNManager()
        let h = Harness(settleClock: streamingClock(inner), managers: inner)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)
        let (auto, work) = try await setUp(h)
        h.env.connection.connect(work.id)
        #expect(await eventually { h.env.connection.startFailure != nil })
        #expect(h.env.connection.startFailure?.code == .killSwitchNotApplied)
        #expect(h.env.connection.startFailure?.detail == "configuration not settled")
        #expect(inner.starts.isEmpty)
        #expect(h.env.profiles.problems.contains { $0.message.contains("kept changing") })
        #expect(await eventually { inner.entries[auto.id]?.onDemand == true })
    }

    /// The wait itself: capped, and it says so.
    @Test func waitUntilSettledIsCapped() async throws {
        let inner = FakeVPNManager()
        let sm = SerializedVPNManager(inner: inner, settleClock: streamingClock(inner))
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        try await sm.loadAll()
        try await sm.save(ManagerConfiguration(profile: p, onDemand: nil))
        #expect(await sm.waitUntilSettled(.seconds(1), cap: .seconds(5)) == false)
        let quiet = SerializedVPNManager(inner: FakeVPNManager())
        #expect(await quiet.waitUntilSettled(.seconds(1), cap: .seconds(5)))
    }

    // MARK: R9

    /// A `fetchLastDisconnectError` that never answers is bounded: no crash, no endless `.awaitingRestart`.
    @Test func aWedgedDisconnectErrorFetchStopsHoldingTheRestore() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.env.connection.disconnectErrorTimeout = .milliseconds(100)
        h.managers.fetchNeverAnswers = true
        h.managers.emit(work.id, .disconnected)                         // not the user's
        #expect(h.env.connection.isBusy)
        #expect(await eventually { !h.env.connection.isBusy })
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    // MARK: R10, U7

    /// `load()` re-checks the deferral before EVERY mutation: a start that begins during the first save stops the rest.
    @Test func loadRechecksTheDeferralBeforeEachSave() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p1 = try await h.add("One.conf", Harness.splitConf, killSwitch: false)
        let p2 = try await h.add("Two.conf", Harness.wgConf, killSwitch: false)
        try await h.env.managers.loadAll()
        for id in [p1.id, p2.id] { h.managers.entries[id]?.cfg.flags.includeAllNetworks = true }
        try await h.env.managers.loadAll()
        var calls = 0
        h.env.profiles.mutationBlocked = { _ in calls += 1; return calls > 1 }  // busy from the second mutation on
        await h.env.profiles.load()
        let healed = [p1.id, p2.id].filter { h.managers.entries[$0]?.cfg.flags.includeAllNetworks == false }
        #expect(healed.count == 1)
        #expect(h.env.profiles.hasDeferredSync)
        h.env.profiles.mutationBlocked = { _ in false }
        await h.env.profiles.runDeferredSync()
        #expect(!h.env.profiles.hasDeferredSync)
        #expect([p1.id, p2.id].allSatisfy { h.managers.entries[$0]?.cfg.flags.includeAllNetworks == false })
    }

    /// U7, reopened by review 3 (N3), reversed by E2E-4: a drift that WEAKENS the connected running profile is healed on
    /// the live session at once (NE applies a flag save to a connected session immediately, U7); every other manager
    /// waits for the session to end.
    @Test func theRunningProfilesDriftIsNotedAndHealedWhenItEnds() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        let other = try await h.add("Other.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        await connected(h, work)
        h.managers.entries[work.id]?.cfg.flags.includeAllNetworks = false
        h.managers.entries[other.id]?.cfg.flags.includeAllNetworks = false
        try await h.env.managers.loadAll()
        h.managers.log = []
        await h.env.profiles.load()
        #expect(h.managers.log.filter { $0 == "begin save \(work.name)" }.count == 1)
        #expect(h.managers.log.filter { $0 == "begin save \(other.name)" }.isEmpty)
        #expect(h.managers.entries[work.id]?.cfg.flags.includeAllNetworks == true)
        #expect(h.env.profiles.problems.contains { $0.message.contains("while it was connected. LockPlus restored them") })
        #expect(h.env.profiles.hasDeferredSync)
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[other.id]?.cfg.flags.includeAllNetworks == true })
    }

    // MARK: R11

    /// A queued write never puts an older state over a later durable one.
    /// Coverage only (review 4, §5): with N4's one ordered queue this is ordered by construction; the in-flight case is
    /// `OnDemandPause3Tests.anOlderSettingsWriteNeverLandsAfterANewerOne`.
    @Test func aQueuedSettingsWriteNeverOverwritesALaterDurableOne() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let s = SettingsStore(files: SettingsFileStore(dir: dir.data))
        let first = UUID(), second = UUID()
        s.update { $0.lastUsedProfileID = first }                       // queued
        await s.updateDurably { $0.lastUsedProfileID = second }         // on disk now
        #expect(AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings)?.lastUsedProfileID == second)
        await s.flush()
        #expect(AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings)?.lastUsedProfileID == second)
    }

    // MARK: Nits

    /// A pause that failed leaves the manager on: nothing is owed, so the record doesn't promise a resume.
    @Test func aFailedPauseLeavesNothingInTheRecord() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        h.managers.onDemandError = LPError(.extensionUnavailable, detail: "saveToPreferences: NEVPNErrorDomain 5")
        h.env.connection.connect(work.id)
        #expect(await eventually { h.env.connection.startFailure != nil })
        #expect(h.env.settings.value.onDemandPausedByStart.isEmpty)     // at once, not at the next restore
        #expect(h.env.connection.holder(of: auto.id) == nil)
    }
}
