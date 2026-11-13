import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import Testing
@testable import LockPlus

/// Fable review 2026-10-30 (docs/native/reviews/2026-10-30-fable-ondemand-pause.md): the durable pause record, one
/// restore function, one shared "another profile is active or starting" predicate, and what each finding changed.
@MainActor @Suite("On-demand pause review (F1–F11)", .serialized, .timeLimit(.minutes(1)))   // `until` has no deadline of its own
struct OnDemandPauseReviewTests {
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

    /// A auto (on-demand on), X a kill-switch manual profile, the connection store started.
    func setUp(_ h: Harness) async throws -> (auto: Profile, work: Profile) {
        let auto = try await autoProfile(h)
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        h.managers.onDemandChanges = [:]
        h.env.connection.start()
        return (auto, work)
    }

    /// X is connected through the app; A was paused by its start.
    func connected(_ h: Harness, _ work: Profile) async {
        h.env.connection.connect(work.id)
        _ = await eventually { h.managers.starts.count == 1 }
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
    }

    var pluginFailed: NSError { NSError(domain: NEVPNConnectionErrorDomain, code: 12) }

    // MARK: F1: a crash

    /// The crash of the manual profile's tunnel process (no on-demand rules): NE restarts it by itself (≈2–3 s later
    /// in reality). The app waits for that restart (`.awaitingRestart`, review R1), not for a grace: nothing is restored
    /// before the session is back, and not at all while it runs.
    @Test func aCrashWaitsForNEsOwnRestartAndRestoresNothingWhileItRuns() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.fetchCount >= 1 })
        try await Task.sleep(for: .milliseconds(100))                   // window: the crash decision is made
        #expect(h.managers.entries[auto.id]?.onDemand == false)         // waiting for NE's restart: still held back
        #expect(h.env.connection.holdsBackOnDemand(of: auto.id))
        h.managers.emit(work.id, .connecting)                           // NE's own restart
        h.managers.emit(work.id, .connected)
        try await Task.sleep(for: .milliseconds(100))                   // window: a (wrong) restore after the restart
        #expect(h.managers.entries[auto.id]?.onDemand == false)         // X is running, so no restore
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        #expect(h.managers.onDemandChanges[auto.id] == [false])
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// The same crash with no restart by anyone: NE's restart is expected (no on-demand rules), and once the fallback
    /// (`systemRestartTimeout`, E2E-4 U8) says it never came and the session is still down, the auto profile returns.
    @Test func aCrashWithoutARestartRestoresAfterTheFallback() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.systemRestartTimeout = .seconds(250)           // never elapses: released by hand
        await connected(h, work)
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.fetchCount >= 1 })
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        await timers.fire(.seconds(250))                                // the fallback: NE's restart never came
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.onDemandChanges[auto.id] == [false, true])
        #expect(h.managers.starts.count == 1)                           // work has no on-demand: not restarted by the app
    }

    // MARK: F2, F3, F4

    /// F2: Y's start fails (the kill switch can't be applied) after a switch from X: the auto profile comes back.
    @Test func aFailedPrepareAfterASwitchRestoresTheAutoProfile() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper                    // no real stop/grace timer beside the test
        let other = try await h.add("Other.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        h.env.connection.connect(work.id)
        await until(h.managers) { h.managers.starts.count == 1 }
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        h.managers.entries[other.id]?.cfg.flags.includeAllNetworks = false   // Y's manager lost the flag, and keeps losing it
        h.managers.dropIncludeAllNetworksOnSave = true
        h.env.connection.connect(other.id)
        await until(h.managers) { h.managers.stops == [work.id] }
        h.managers.emit(work.id, .disconnected)
        // The failure, the restore and the cleared pause record are each awaited on the state change itself.
        await until(h.managers) {
            h.env.connection.observedError?.code == .killSwitchNotApplied
                && h.managers.entries[auto.id]?.onDemand == true
                && h.env.settings.value.onDemandPausedByStart.isEmpty
        }
        #expect(h.managers.onDemandChanges[auto.id] == [false, true])
        #expect(h.managers.starts.count == 1)
    }

    /// F3: a pause that fails is a start failure with a note; nothing starts beside the enabled configuration.
    @Test func aFailedPauseRefusesTheStart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        h.managers.onDemandError = LPError(.extensionUnavailable, detail: "saveToPreferences: NEVPNErrorDomain 5")
        h.env.connection.connect(work.id)
        #expect(await eventually { h.env.connection.startFailure != nil })
        #expect(h.managers.starts.isEmpty)
        #expect(h.env.profiles.problems.contains { $0.message == "Auto-connect of \(auto.name) couldn't be paused; not connecting." })
        h.managers.onDemandError = nil
        #expect(h.managers.entries[auto.id]?.onDemand == true)
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })   // nothing owed: it never went off
    }

    /// F4: a failed restore is noted (never `try?`), stays recorded, the pane says so, and the next status event retries.
    @Test func aFailedRestoreIsNotedShownAndRetried() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.managers.saveError = LPError(.extensionUnavailable, detail: "saveToPreferences: NEVPNErrorDomain 5")
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.env.profiles.problems.contains { $0.message.contains("couldn't be turned back on") } })
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        #expect(await eventually { !h.env.connection.restoring })
        #expect(UIBinder.autoConnectStatusLine(h.env) == "Auto-connect is off; LockPlus couldn't turn it back on.")
        h.managers.saveError = nil
        h.managers.emit(work.id, .disconnected)                          // any status event retries
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
        #expect(UIBinder.autoConnectStatusLine(h.env) == nil)
    }

    // MARK: F5

    /// The settle is relative to the last mutation, whoever made it, on a test clock (no wall-clock sleeping).
    @Test func theSettleCountsFromTheLastMutationWhoeverMadeIt() async throws {
        let fake = FakeSettleClock()
        let inner = FakeVPNManager()
        let sm = SerializedVPNManager(inner: inner, settleClock: fake.clock)
        await sm.waitUntilSettled(.seconds(1))
        #expect(fake.sleeps.isEmpty)                                     // nothing mutated yet
        try await sm.loadAll()
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        try await sm.save(ManagerConfiguration(profile: p, onDemand: nil))            // a foreign save at t = 0
        fake.advance(.milliseconds(300))
        await sm.waitUntilSettled(.seconds(1))
        #expect(fake.sleeps == [.milliseconds(700)])                     // the rest of the second, not a fresh one
        await sm.waitUntilSettled(.seconds(1))
        #expect(fake.sleeps == [.milliseconds(700)])                     // settled
        try await sm.setOnDemandEnabled(true, for: p.id)
        await sm.waitUntilSettled(.milliseconds(500))
        #expect(fake.sleeps == [.milliseconds(700), .milliseconds(500)])
        inner.onConfigurationChange?()                                   // the system's own rewrite counts too
        await sm.waitUntilSettled(.milliseconds(500))
        #expect(fake.sleeps.count == 3 && fake.sleeps.last == .milliseconds(500))
    }

    /// A start waits for the last mutation to be 1 s old, even a save the start didn't make.
    @Test func aStartWaitsOutAForeignSave() async throws {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)               // settleBeforeStart = 1 s
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let other = try await h.add("Other.conf", Harness.splitConf)
        try await h.env.managers.loadAll()
        h.env.connection.start()
        try await h.env.managers.save(ManagerConfiguration(profile: other, onDemand: nil))      // a save by another path
        fake.advance(.milliseconds(250))
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(fake.sleeps == [.milliseconds(750)])
    }

    /// `load()` makes no manager changes while a start is under way; they run when idle again.
    @Test func loadDefersManagerResavesWhileStarting() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        let other = try await h.add("Other.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })       // started, no status yet: still "starting"
        h.managers.entries[other.id]?.cfg.flags.includeAllNetworks = false     // drift of another configuration
        try await h.env.managers.loadAll()
        await h.env.profiles.load()
        #expect(h.managers.entries[other.id]?.cfg.flags.includeAllNetworks == false)
        #expect(h.env.profiles.hasDeferredSync)
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        await h.env.profiles.load()
        #expect(h.managers.entries[other.id]?.cfg.flags.includeAllNetworks == false)    // still running: still deferred
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[other.id]?.cfg.flags.includeAllNetworks == true })
    }

    /// Simplification 3: a restore of a manager that already carries the plan saves nothing.
    @Test func aRestoreThatChangesNothingSavesNothing() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let auto = try await autoProfile(h)
        h.env.connection.start()
        h.managers.log = []
        try await h.env.profiles.saveOnDemand(auto)
        #expect(!h.managers.log.contains { $0.hasPrefix("begin save") })
    }

    // MARK: F6

    /// NE's own on-demand start of the auto profile lands while X is between pause and start: X does not start beside
    /// it; the auto profile is stopped (no suspension) and X starts once it has reported `.disconnected`.
    @Test func anOnDemandStartMidWindowTurnsTheStartIntoASwitch() async throws {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)
        let (auto, work) = try await setUp(h)
        let managers = h.managers
        let autoID = auto.id
        fake.onFirstSleep { await MainActor.run { managers.emit(autoID, .connecting) } }
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.stops == [auto.id] })
        #expect(h.managers.starts.isEmpty)
        #expect(h.env.settings.value.onDemandSuspended.isEmpty)          // a switch, not a Disconnect
        h.managers.emit(auto.id, .disconnected)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.starts.first?.0 == work.id)
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    // MARK: F7

    @Test func anotherUsersOnDemandConfigurationIsLeftAlone() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        h.managers.entries[auto.id]?.cfg.provider.ownerUID = getuid() &+ 1
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.entries[auto.id]?.onDemand == true)
        #expect(h.managers.onDemandChanges[auto.id] == nil)
        #expect(h.env.settings.value.onDemandPausedByStart.isEmpty)
    }

    // MARK: F9

    @Test func aStartWithoutAnyStatusStopsHoldingTheAutoProfileBack() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.startingTimeout = .seconds(30)                 // never elapses: released by hand
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.env.connection.holdsBackOnDemand(of: auto.id))        // issued, no status: held until the timer
        await timers.fire(.seconds(30))
        #expect(await eventually { !h.env.connection.holdsBackOnDemand(of: auto.id) })
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.env.settings.value.onDemandPausedByStart.isEmpty)
    }

    // MARK: F10

    /// (a) Switching away from the auto profile records no Disconnect suspension; it returns when the other ends.
    /// (b)/(c) The pane says "resumes when you disconnect X" during the window and while the recorded pause holds,
    /// but not for a session started elsewhere.
    @Test func switchingAwayFromTheAutoProfileComesBackWhenTheOtherEnds() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        h.managers.emit(auto.id, .connecting)
        h.managers.emit(auto.id, .connected)
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.stops == [auto.id] })
        #expect(h.env.settings.value.onDemandSuspended.isEmpty)
        #expect(h.managers.entries[auto.id]?.onDemand == false)          // paused BEFORE the stop: nothing restarts it
        h.managers.emit(auto.id, .disconnected)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.entries[auto.id]?.onDemand == false)          // not restored beside the starting work profile
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        #expect(UIBinder.autoConnectStatusLine(h.env) == "Auto-connect resumes when you disconnect \(work.name).")
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.onDemandChanges[auto.id] == [false, true])
        #expect(UIBinder.autoConnectStatusLine(h.env) == nil)
    }

    @Test func thePaneShowsThePauseInTheStartWindowButNotForAForeignSession() async throws {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)
        let (_, work) = try await setUp(h)
        // A session started in System Settings: nothing was paused, so the pane doesn't promise a resume.
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        #expect(UIBinder.autoConnectStatusLine(h.env) == nil)
        h.managers.emit(work.id, .disconnected)

        let env = h.env
        let line = LockBox<String?>(nil)
        fake.onFirstSleep { await MainActor.run { line.set(UIBinder.autoConnectStatusLine(env)) } }
        h.env.connection.connect(work.id)                                 // the start window: paused, no status yet
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(line.value == "Auto-connect resumes when you disconnect \(work.name).")
    }

    /// (d) A second Connect while the first start is in flight is ignored.
    @Test func aSecondConnectWhileStartingIsIgnored() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        h.env.connection.connect(work.id)
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count >= 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.managers.starts.count == 1)
    }

    // MARK: durability

    /// The record is on disk before the pause: a relaunch with the profile still running keeps it; with nothing running it
    /// restores exactly what was paused.
    @Test func thePauseRecordSurvivesARelaunch() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        let onDisk = AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)
        #expect(onDisk?.onDemandPausedByStart == [auto.id])

        func relaunch() async throws -> Harness {
            let h2 = Harness(dir: h.dir, managers: h.managers, keychain: h.keychain)
            h2.env.settings.replaceAll(try #require(await h2.env.files?.loadSettingsChecked().settings))
            try await h2.env.managers.loadAll()
            await h2.env.profiles.load()
            h.managers.onDemandChanges = [:]
            h2.env.connection.start()
            return h2
        }
        let running = try await relaunch()                                // X still connected: stays recorded
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(running.env.settings.value.onDemandPausedByStart == [auto.id])

        h.managers.entries[work.id]?.status = .disconnected               // it ended while LockPlus wasn't running
        let idle = try await relaunch()
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.onDemandChanges[auto.id] == [true])
        #expect(await eventually { idle.env.settings.value.onDemandPausedByStart.isEmpty })
        #expect(await eventually { AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)?.onDemandPausedByStart.isEmpty == true })
    }

    /// The pause record is handed to a user's "Pause protection": it is restored with the rest at the pause's end.
    @Test func aUserPauseTakesOverTheRecord() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        await h.env.connection.pause(minutes: 5)
        #expect(h.env.settings.value.onDemandPausedByStart.isEmpty)
        #expect(h.env.settings.value.pausedState?.onDemandEnabledIDs.contains(auto.id) == true)
        #expect(h.env.settings.value.pausedState?.profileID == work.id)
    }

    /// F8: whatever a start paused is restored through the record, not guessed from the auto-connect rules; a profile
    /// whose plan no longer wants on-demand (Auto-Connect turned off meanwhile) is dropped from it, not re-enabled.
    @Test func theRecordIsDroppedForAPlanThatNoLongerWantsOnDemand() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.env.settings.update { $0.autoConnect.enabled = false }
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
        #expect(h.managers.entries[auto.id]?.onDemand == false)
    }
}
