import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import Testing
@testable import LockPlus

/// Fable review 2026-10-30, third round (docs/native/reviews/2026-10-30-fable-ondemand-pause-3.md): N1–N10 and the
/// missing tests the review lists.
@MainActor @Suite("On-demand pause review 3 (N1–N10)", .serialized)
struct OnDemandPause3Tests {
    func autoProfile(_ h: Harness, killSwitch: Bool? = nil) async throws -> Profile {
        let p = try await h.add("Home NAS.conf", Harness.splitConf, killSwitch: killSwitch)
        h.env.settings.update {
            $0.autoConnect.enabled = true
            $0.autoConnect.profileID = p.id
        }
        await h.env.profiles.resaveOnDemand()
        try await h.env.managers.loadAll()
        return p
    }

    /// A auto (on-demand on), X a kill-switch manual profile, the connection store started.
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

    // MARK: N1

    /// (a) The previous session's `.disconnected` lands inside the start window (before the start is issued): the start
    /// keeps holding A back, and X starts with A off.
    @Test func aStaleDisconnectedInsideTheStartWindowKeepsTheStart() async throws {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)
        let (auto, work) = try await setUp(h)
        let managers = h.managers, workID = work.id
        fake.onFirstSleep { await MainActor.run { managers.emit(workID, .disconnected) } }
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.onDemandAtStart.last?.contains(auto.id) == false)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.connection.holdsBackOnDemand(of: auto.id))
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
    }

    /// (b) Connect while the same profile is still disconnecting: nothing is issued into NE's Stopping (S2); the start
    /// follows its `.disconnected`, with A still off.
    @Test func aReconnectWhileDisconnectingStartsAfterTheDisconnect() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnecting)
        h.env.connection.connect(work.id)
        try await Task.sleep(for: .milliseconds(100))                   // window: the old code started within it
        #expect(h.managers.starts.count == 1)
        #expect(h.env.connection.holdsBackOnDemand(of: auto.id))
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.starts.count == 2 })
        #expect(h.managers.onDemandAtStart.last?.contains(auto.id) == false)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
    }

    // MARK: N2

    /// An extension update (`quiesce`) while X runs with A paused: X's `.disconnected` restores nothing, `load()` turns
    /// nothing on, the record and `pendingResume` stay; `resumeAfterUpdate` restarts X with A off, and A returns when X
    /// ends.
    @Test func anExtensionUpdateHoldsOnDemandUntilItHandsBack() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        let q = ManagerQuiescer()
        q.attach(managers: h.env.managers, settings: h.env.settings, connection: h.env.connection)
        await q.quiesce(reason: .extensionUpdate)
        #expect(h.managers.stops == [work.id])
        h.managers.emit(work.id, .disconnected)                         // MQ's stop is a user stop (review e321e10)
        h.managers.entries[auto.id]?.cfg.flags.includeAllNetworks = true        // nehelper rewrote A meanwhile
        try await h.env.managers.loadAll()
        await h.env.profiles.load()
        try await Task.sleep(for: .milliseconds(100))                   // window for a (wrong) restore
        #expect(h.managers.fetchCount == 0)                             // no error fetch for a user stop
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.managers.onDemandChanges[auto.id] == [false])
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        #expect(h.env.settings.value.pendingResume?.profileID == work.id)
        await q.resumeAfterUpdate()
        #expect(h.env.settings.value.pendingResume == nil)
        #expect(await eventually { h.managers.starts.count == 2 })
        #expect(h.managers.onDemandAtStart.last?.contains(auto.id) == false)
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
    }

    // MARK: N4

    /// A write that read an older value and reaches the file store after a newer one (in flight on the actor while the
    /// quit path wrote) is dropped.
    @Test func anOlderSettingsWriteNeverLandsAfterANewerOne() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let files = SettingsFileStore(dir: dir.data)
        var older = AppSettings(), newer = AppSettings()
        older.lastUsedProfileID = UUID()
        newer.lastUsedProfileID = UUID()
        files.saveNow(newer, seq: 2)
        await files.save(older, seq: 1)
        #expect(AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings)?.lastUsedProfileID == newer.lastUsedProfileID)
    }

    /// A durable update returns with its value on disk, through the same ordered queue as every other write.
    @Test func aDurableUpdateIsOnDiskWhenItReturns() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let s = SettingsStore(files: SettingsFileStore(dir: dir.data))
        let first = UUID(), second = UUID(), third = UUID()
        for _ in 0..<20 { s.update { $0.lastUsedProfileID = UUID() } }      // a queue of writes in flight
        s.update { $0.lastUsedProfileID = first }
        await s.updateDurably { $0.onDemandPausedByStart = [second] }
        let disk = AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings)
        #expect(disk?.lastUsedProfileID == first && disk?.onDemandPausedByStart == [second])
        s.update { $0.lastUsedProfileID = third }                       // queued, then the quit path
        s.writeSynchronously()
        await s.flush()
        #expect(AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings)?.lastUsedProfileID == third)
    }

    // MARK: N3

    /// NE's on-demand start of A is pending (`.connecting`) and A's manager drifted: `load()` saves nothing (the old
    /// exemption counted `.connecting` as running).
    @Test func aDriftedManagerInsideItsOwnPendingStartIsNotSaved() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, _) = try await setUp(h)
        h.managers.emit(auto.id, .connecting)
        h.managers.entries[auto.id]?.cfg.flags.includeAllNetworks = true
        try await h.env.managers.loadAll()
        h.managers.log = []
        await h.env.profiles.load()
        await h.env.profiles.resaveOnDemand()
        #expect(saves(h) == 0)
        #expect(h.env.profiles.hasDeferredSync)
    }

    /// The exemption that stays (S2 E9): a rule edit saves the CONNECTED auto profile's own manager when nothing else
    /// is busy; the same edit inside its pending start waits.
    @Test func aRuleEditSavesTheConnectedManagerButNotAConnectingOne() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, _) = try await setUp(h)
        h.managers.emit(auto.id, .connecting)
        h.managers.log = []
        h.env.settings.update { $0.autoConnect.trustedSSIDs = ["Home"] }
        await h.env.profiles.resaveOnDemand()
        #expect(saves(h) == 0)
        h.managers.emit(auto.id, .connected)
        await h.env.profiles.resaveOnDemand()
        #expect(saves(h) == 1)
        #expect(h.managers.entries[auto.id]?.onDemand == true)
    }

    /// A recorded profile that is itself starting (a System Settings start of A) is not restored: nothing is saved
    /// inside its own pending start; it is restored once it ends.
    @Test func aRecordedProfileThatIsItselfStartingIsNotRestored() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, _) = try await setUp(h)
        h.managers.entries[auto.id]?.onDemand = false
        try await h.env.managers.loadAll()
        await h.env.settings.updateDurably { $0.onDemandPausedByStart = [auto.id] }
        h.managers.log = []
        h.managers.emit(auto.id, .connecting)
        try await Task.sleep(for: .milliseconds(100))                   // window for a (wrong) restore
        #expect(saves(h) == 0)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        h.managers.emit(auto.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    // MARK: N5

    /// X runs with A recorded: X's status events start no restore (the pane line doesn't flicker).
    @Test func statusEventsWhileXRunsDoNotFlipRestoring() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        for s in [TunnelStatus.reasserting, .connected, .reasserting, .connected] {
            h.managers.emit(work.id, s)
            #expect(!h.env.connection.restoring)
        }
        #expect(UIBinder.autoConnectStatusLine(h.env) == "Auto-connect resumes when you disconnect \(work.name).")
    }

    // MARK: N6

    /// X's manager lost `includeAllNetworks` (nehelper) while X ran with the kill switch, then X crashed: the decision
    /// reads the session's flags, so NE's own restart is expected and A stays held back (the old code restored A
    /// after the grace, inside NE's pending restart).
    @Test func aCrashDecidesByTheFlagsTheSessionStartedWith() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        h.env.connection.crashRestartGrace = .zero
        await connected(h, work)
        h.managers.entries[work.id]?.cfg.flags.includeAllNetworks = false
        try await h.env.managers.loadAll()
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.fetchCount >= 1 })
        try await Task.sleep(for: .milliseconds(200))                   // window: grace zero, the fallback is 30 s
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.connection.holdsBackOnDemand(of: auto.id))
        h.managers.emit(work.id, .connecting)                           // NE's own restart
        h.managers.emit(work.id, .connected)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
    }

    // MARK: N7

    /// X crashed (NE's own restart expected) and is deleted meanwhile: its manager is gone, nothing can restart it,
    /// and A returns at the configuration change instead of after the 30 s fallback.
    @Test func deletingACrashedProfileEndsTheWaitForItsRestart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.fetchCount >= 1 })
        try await Task.sleep(for: .milliseconds(100))                   // window: the crash decision (fake XPC) is made
        #expect(h.env.connection.holdsBackOnDemand(of: auto.id))
        await h.env.profiles.delete(work.id)
        h.env.connection.configurationChanged()                         // NEVPNConfigurationChange of the removal
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(!h.env.connection.holdsBackOnDemand(of: auto.id))
    }

    // MARK: N8

    /// The headless resume writes what stays off (the record) before it starts the target, so a watchdog exit after
    /// the start still leaves it recorded.
    @Test func theHeadlessResumeRecordsWhatStaysOffBeforeTheStart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        var s = AppSettings()
        s.autoConnect.pausedUntil = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [work.id, auto.id], agentBuild: "1",
                                   intent: await resumeIntent(work.id, until: s.autoConnect.pausedUntil!, keychain: h.keychain, dir: h.dir.data))
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        let dir = h.dir.data
        var recordAtStart: [UUID]?
        h.managers.onStart = { _ in recordAtStart = AtomicFile.loadJSON(AppSettings.self, from: dir.settings)?.onDemandPausedByStart }
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(r == .resumed(restarted: work.id, onDemand: [work.id]))
        #expect(recordAtStart == [auto.id])
    }

    /// The settle is capped by what is left of the watchdog's budget (less the 1 s reserve): with a 1.6 s budget about
    /// 0.6 s is left when the settle begins, so the settle (1 s, on a fake clock) sleeps only the remainder, doesn't
    /// settle, and nothing starts (the run never ends in the watchdog's exit). Review 4 (§5): the old version used a
    /// budget below the reserve, so it only tested `cap > 0`. 2.0.2 RC review (Fable M1): out of time is retried, not a
    /// failure: the pause stays for the next run.
    @Test func theHeadlessSettleFitsTheBudget() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        var s = AppSettings()
        s.autoConnect.pausedUntil = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [work.id, auto.id], agentBuild: "1",
                                   intent: await resumeIntent(work.id, until: s.autoConnect.pausedUntil!, keychain: h.keychain, dir: h.dir.data))
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        let fake = FakeSettleClock()
        let managers = SerializedVPNManager(inner: h.managers, settleClock: fake.clock)   // the target's on-demand save starts the settle
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: managers, agent: ProbeResumeAgent(), keychain: h.keychain,
                                             budget: .milliseconds(1600))
        #expect(fake.sleeps.count == 1)
        let slept = try #require(fake.sleeps.first)
        #expect(slept > .zero && slept <= .milliseconds(600))          // the remainder, not the 1 s settle
        #expect(r == .outOfTime(.settle))
        #expect(h.managers.starts.isEmpty)
        let disk = AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)
        #expect(disk?.autoConnect.pausedUntil == s.autoConnect.pausedUntil && disk?.pausedState == s.pausedState)
    }

    // MARK: N9

    /// Pause protection leaves another user's on-demand configuration alone (and doesn't list it for the restore).
    @Test func pauseLeavesAnotherUsersOnDemandAlone() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, _) = try await setUp(h)
        h.managers.entries[auto.id]?.cfg.provider.ownerUID = getuid() &+ 1
        try await h.env.managers.loadAll()
        await h.env.connection.pause(minutes: 5)
        try await Task.sleep(for: .milliseconds(100))                   // window: the pause's on-demand-off Task
        #expect(h.managers.entries[auto.id]?.onDemand == true)
        #expect(h.managers.onDemandChanges[auto.id] == nil)
        #expect(h.env.settings.value.pausedState?.onDemandEnabledIDs.isEmpty == true)
    }

    // MARK: Tests the review listed as missing

    func crashed(_ h: Harness, _ id: UUID) {
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = pluginFailed
        h.managers.emit(id, .disconnected)
    }

    /// The app's own `.restart` (a kill-switch profile with on-demand rules) is one pending start: a user Connect
    /// inside the grace takes the entry over, and the grace then issues no second start (the old code started twice).
    @Test func aConnectInsideTheCrashGraceTakesTheRestartOver() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.managers.entries[p.id]?.onDemand = true
        h.env.connection.crashRestartGrace = .milliseconds(300)
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        crashed(h, p.id)
        #expect(await eventually { h.managers.fetchCount >= 1 })
        h.env.connection.connect(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        try await Task.sleep(for: .milliseconds(500))                   // window: past the grace
        #expect(h.managers.starts.count == 1)
        #expect(h.managers.starts.first?.1.isEmpty == false)            // the user's start (lp.manual), not the restart
    }

    /// The flake behind `theCrashRestartIsAPendingStartWithItsTimer`: the store cancels an entry's timer and arms the next
    /// one (same duration) in one turn; a cancelled sleeper that stayed in `armed` until its task next ran let `fire`
    /// release the stale one and leave the live timer armed for good. A cancel removes it at once.
    @Test func aCancelledSleeperIsNotArmedAnyMore() async throws {
        let timers = FakeTimers()
        let task = Task { await timers.sleeper(.seconds(150)) }
        #expect(await eventually { timers.armed == [.seconds(150)] })
        task.cancel()
        #expect(timers.armed.isEmpty)                                   // no hop in between
        await task.value
    }

    /// The restart is a pending start like any other: it holds everything back until a status, and stops holding when
    /// NE reports none (the timer); a restart whose start throws ends at once.
    /// Coverage only (review 4, §5): the pre-refactor `beginStarting`/timer/`clearStarting` passed this too.
    @Test func theCrashRestartIsAPendingStartWithItsTimer() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.managers.entries[p.id]?.onDemand = true
        h.env.connection.crashRestartGrace = .zero
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.startingTimeout = .seconds(150)                // released by hand
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        crashed(h, p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.starts.first?.1.isEmpty == true)             // on-demand semantics
        #expect(h.env.connection.isBusy)                                // issued, no status yet
        await timers.fire(.seconds(150))
        #expect(await eventually { !h.env.connection.isBusy })          // the timer: NE dropped it

        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        h.managers.startError = LPError(.extensionUnavailable, detail: "start threw")
        h.env.connection.startingTimeout = .seconds(30)
        crashed(h, p.id)
        #expect(await eventually { h.managers.fetchCount >= 2 })
        #expect(await eventually { !h.env.connection.isBusy })          // at once, not after 30 s
        #expect(h.managers.starts.count == 1)
    }

    /// The end of a pause hands back through the record and connects the paused profile; that connect fails at once
    /// (the profile isn't verified any more): the failure restores what was handed back.
    /// Coverage only (review 4, §5): the pre-refactor `fail` → `restoreIfIdle` passed this too.
    @Test func aHandBackWhoseConnectFailsRestoresTheRest() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        await h.env.connection.pause(minutes: 5)
        #expect(await eventually { h.managers.stops == [work.id] })
        h.managers.emit(work.id, .disconnected)
        #expect(h.env.settings.value.pausedState?.profileID == work.id)
        try await h.env.profiles.updateMetadata(work.id) { $0.engineVerified = false }
        await h.env.connection.resume().value
        #expect(h.env.connection.startFailure?.code == .profileInvalid)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
        #expect(h.managers.starts.count == 1)
    }

    /// Review 4 (#5) reframed this onto a reachable path (a Connect of an active profile is ignored now): NE stops X (not
    /// the user), the user connects X while it is still `.disconnecting` (N1b: the start waits for the stop), then the
    /// old session's `.disconnected` arrives. The disconnect's bookkeeping (the error fetch) runs once and does not
    /// replace the waiting start with an `.awaitingRestart` (that would have dropped it: no second start); the start
    /// follows with A off.
    @Test func anUnexpectedEndOfTheOldSessionKeepsAPendingStart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.managers.emit(work.id, .disconnecting)                        // NE stops it: no user Disconnect
        h.env.connection.connect(work.id)
        #expect(h.env.connection.holdsBackOnDemand(of: auto.id))
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.starts.count == 2 })
        #expect(await eventually { h.managers.fetchCount == 1 })
        #expect(h.managers.onDemandAtStart.last?.contains(auto.id) == false)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
    }
}
