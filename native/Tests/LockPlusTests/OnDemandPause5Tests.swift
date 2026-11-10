import Foundation
import LPModel
import NetworkExtension
import Synchronization
import SystemExtensions
import Testing
@testable import LockPlus

/// Fable review 2026-10-30, fifth round (docs/native/reviews/2026-10-30-fable-ondemand-pause-5.md): findings 1–6, the
/// ignored-Connect UX gap (§3: `startHold`, row 12a, every Connect disabled with the reason, the hand-back note) and
/// the test gaps §5 lists (`stopTimeout` firing, Disconnect during `.waitingForStop` and a pre-issue start, #8 inside a
/// pending start).
@MainActor @Suite("On-demand pause review 5", .serialized)
struct OnDemandPause5Tests {
    let t4 = OnDemandPause4Tests()

    func setUp(_ h: Harness) async throws -> (auto: Profile, work: Profile) { try await t4.setUp(h) }
    func connected(_ h: Harness, _ p: Profile) async { await t4.connected(h, p) }
    func saves(_ h: Harness, of p: Profile? = nil) -> Int { t4.saves(h, of: p) }
    func never(_ condition: () -> Bool) async -> Bool { await t4.never(condition) }

    /// A harness whose start settles on a fake clock: the first sleep is inside Work's pending start, after the pause.
    func pendingStartHarness() -> (Harness, FakeSettleClock) {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        h.env.profiles.settleAfterSave = .milliseconds(500)             // a 1 s settle (on the fake clock)
        return (h, fake)
    }

    var pluginFailed: NSError { NSError(domain: NEVPNConnectionErrorDomain, code: 12) }

    // MARK: #1

    /// Cancel (row 12a's action, the user's Disconnect) inside Work's settle: the pre-issue start ends, nothing starts,
    /// and what it paused comes back. The old code cleared only a `.waitingForStop`: Work's start landed afterwards.
    @Test func cancelDuringAPreIssueStartEndsIt() async throws {
        let (h, fake) = pendingStartHarness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let env = h.env, seen = Mutex<ConnectionStore.StartHold?>(nil)
        fake.onFirstSleep { @MainActor in
            seen.withLock { $0 = env.connection.startHold }
            env.ui.actions.perform(.cancel)
        }
        #expect(h.env.connection.connect(work.id))
        #expect(await eventually { fake.sleeps.count == 1 })
        #expect(seen.withLock { $0 } == ConnectionStore.StartHold(profile: work.id, reason: .preparing))
        #expect(await never { !h.managers.starts.isEmpty })
        #expect(h.env.connection.startHold == nil)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
    }

    /// Pause inside Work's settle: the pre-issue start ends (no kill-switch session inside "Paused"), and the pause keeps
    /// what the start had paused for its own restore.
    @Test func pauseDuringAPreIssueStartEndsIt() async throws {
        let (h, fake) = pendingStartHarness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let connection = h.env.connection
        fake.onFirstSleep { await connection.pause(minutes: 15) }
        connection.connect(work.id)
        #expect(await eventually { fake.sleeps.count == 1 })
        #expect(await eventually { connection.pausedUntil != nil })
        #expect(await never { !h.managers.starts.isEmpty })
        #expect(connection.startHold == nil)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.settings.value.pausedState?.onDemandEnabledIDs.contains(auto.id) == true)
    }

    // MARK: §5 gaps: Disconnect during `.waitingForStop`, `stopTimeout`, #8 inside a pending start

    /// A switch to Y waits for Work's stop; the user's Disconnect ends the wait: Work's `.disconnected` starts nothing.
    @Test func disconnectDuringAWaitForStopEndsIt() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let y = try await h.add("Travel.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        await connected(h, work)
        h.env.connection.connect(y.id)
        #expect(await eventually { h.managers.stops == [work.id] })
        #expect(h.env.connection.startHold == ConnectionStore.StartHold(profile: y.id, reason: .waitingForStop(of: work.id)))
        h.env.connection.disconnect()
        #expect(h.env.connection.startHold == nil)
        #expect(h.env.connection.switchingTo == nil)
        h.managers.emit(work.id, .disconnected)
        #expect(await never { h.managers.starts.count > 1 })
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// N1b with an old session that never reports `.disconnected`: the `stopTimeout` timer starts the waiting Connect.
    @Test func theStopTimeoutStartsAWaitingConnect() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.stopTimeout = .seconds(22)                     // released by hand
        await connected(h, work)
        h.managers.emit(work.id, .disconnecting)                         // stopped elsewhere; never reports the end
        h.env.connection.connect(work.id)
        #expect(h.env.connection.startHold == ConnectionStore.StartHold(profile: work.id, reason: .waitingForStop(of: work.id)))
        #expect(h.managers.starts.count == 1)
        await timers.fire(.seconds(22))
        #expect(await eventually { h.managers.starts.count == 2 })      // the timer fired: started anyway
    }

    /// #8 inside a pending start (the same predicate as while connected): an import and a policy change of another
    /// profile save no manager inside Work's settle; the deferred sync runs when Work ends.
    @Test func managerSavesWaitInsideAPendingStart() async throws {
        let (h, fake) = pendingStartHarness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let apns = try #require(h.env.profiles.profile(auto.id)).policy.excludeAPNs
        let added = Mutex<UUID?>(nil)
        fake.onFirstSleep { @MainActor in
            let p = try? await h.add("Travel.conf", Harness.wgConf, killSwitch: true)
            added.withLock { $0 = p?.id }
            try? await h.env.profiles.updatePolicy(auto.id) { $0.excludeAPNs.toggle() }
        }
        h.managers.log = []
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        let travel = try #require(added.withLock { $0 })
        #expect(saves(h, of: auto) == 0)
        #expect(h.managers.entries[travel] == nil)
        #expect(h.env.profiles.profile(auto.id)?.policy.excludeAPNs == !apns)    // the metadata is saved
        #expect(h.env.profiles.hasDeferredSync)
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[travel] != nil })
        #expect(await eventually { h.managers.entries[auto.id]?.cfg.flags.excludeAPNs == !apns })
    }

    // MARK: #2

    /// NE is already Stopping (the live status) while the handled event still says `.connected`: a Connect waits for the
    /// stop instead of issuing into it (S2: silently dropped).
    @Test func aConnectWhileTheLiveStatusIsDisconnectingWaits() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await connected(h, work)
        h.managers.entries[work.id]?.status = .disconnecting               // live, not yet handled
        #expect(h.env.connection.statuses[work.id] == .connected)
        h.managers.log = []
        #expect(h.env.connection.connect(work.id))
        #expect(h.env.connection.startHold == ConnectionStore.StartHold(profile: work.id, reason: .waitingForStop(of: work.id)))
        #expect(await never { h.managers.starts.count > 1 || saves(h, of: work) > 0 })
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.starts.count == 2 })
    }

    // MARK: #3

    @MainActor final class Answering {
        let rec = SystemExtensionManagerTests.Recorder()
        let q = OnDemandPause4Tests.RecordingQuiescer()
        let m: SystemExtensionManager
        init(watchdog: Duration = .milliseconds(100)) {
            m = SystemExtensionManager(bundle: .main, quiescer: q, submitter: { [rec] in rec.requests.append($0) },
                                       propertiesTimeout: .seconds(2), activationWatchdog: watchdog, openSettings: {})
        }
        func answer(_ index: Int, _ entries: [ExtensionEntry]) async -> Bool {
            guard await eventually(.seconds(3), { self.rec.requests.count > index }) else { return false }
            m.deliverProperties(ObjectIdentifier(rec.requests[index]), entries)
            return true
        }
    }

    static func entry(_ v: ExtensionVersion, awaiting: Bool = false, enabled: Bool = true) -> ExtensionEntry {
        ExtensionEntry(version: v, isEnabled: enabled, isAwaitingUserApproval: awaiting, isUninstalling: false)
    }
    static let old = ExtensionVersion(shortVersion: "0.0.1", bundleVersion: "1")

    /// An update quiesced for the installed (older) extension; sysextd never answers the activation. The watchdog reads
    /// the properties again and hands back only while the old version is still the enabled entry and nothing awaits
    /// approval; a replacement that finished silently, a pending approval or no answer keep the hand-over.
    @Test func theWatchdogHandsBackOnlyToTheStillEnabledOldExtension() async throws {
        let embedded = try #require(Answering().m.embeddedVersion)
        let cases: [([ExtensionEntry]?, Bool)] = [
            ([Self.entry(Self.old)], true),
            ([Self.entry(embedded)], false),                                            // replaced meanwhile
            ([Self.entry(Self.old), Self.entry(embedded, awaiting: true, enabled: false)], false),
            (nil, false),                                                               // no answer (timed out)
        ]
        for (fresh, handsBack) in cases {
            let a = Answering()
            let activation = Task { await a.m.activate() }
            #expect(await a.answer(0, [Self.entry(Self.old)]))                          // the preflight: an update
            await activation.value
            #expect(a.q.calls == ["quiesce extensionUpdate"])
            #expect(await eventually { a.rec.requests.count == 3 })                     // the watchdog's properties read
            if let fresh { #expect(await a.answer(2, fresh)) }
            if handsBack {
                #expect(await eventually { a.q.calls == ["quiesce extensionUpdate", "resume"] })
            } else {
                #expect(await never { a.q.calls.contains("resume") })
            }
            // E2E-4 (U14/U15): handed back to the still-enabled old extension = "couldn't update", not "damaged".
            if handsBack {
                #expect(await eventually { a.m.state == .updateFailed(installed: Self.old.description, code: 0) })
            } else {
                #expect(a.m.state == .failed(.broken(code: 0)))
            }
        }
    }

    // MARK: #4

    /// Deleting a profile whose on-demand couldn't be turned off while another runs: no deferral (an enabled on-demand
    /// configuration beside the session is the E2E-3 trigger), the configuration is removed now, and Diagnostics says so.
    @Test func aDeleteWhoseDisableFailedIsNotDeferred() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.managers.entries[auto.id]?.onDemand = true                     // turned on in System Settings meanwhile
        try await h.env.managers.loadAll()
        h.managers.onDemandError = LPError(.extensionUnavailable, detail: "test")
        await h.env.profiles.delete(auto.id)
        #expect(h.managers.entries[auto.id] == nil)
        #expect(h.env.profiles.problems.contains { $0.message.hasPrefix("Auto-connect of Home NAS couldn't be turned off before it was deleted") })
    }

    // MARK: #5

    /// The onboarding's first save while Work runs is deferred: the step says when it happens instead of "done".
    @Test func allowVPNConfigurationSaysWhenTheSaveIsDeferred() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.managers.log = []
        h.env.ui.actions.allowVPNConfiguration()
        let expected = OnboardingUIModel.ConfigurationStep.deferred(message: "LockPlus adds the VPN configuration for \(auto.name) when \(work.name) disconnects.")
        #expect(await eventually { h.env.ui.onboarding.configurationStep == expected })
        #expect(saves(h) == 0)
    }

    // MARK: §3 the ignored Connect

    /// While Work's start is prepared, the UI shows row 12a for it (Cancel, no Connect) and every profile's Connect is
    /// disabled with the reason; afterwards nothing is held.
    @Test func theUIHoldsEveryConnectDuringAPendingStart() async throws {
        let (h, fake) = pendingStartHarness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let env = h.env
        let seen = Mutex<(ConnectionCondition, String?, String?, Bool)?>(nil)
        fake.onFirstSleep { @MainActor in
            UIBinder.render(env)
            let header = MenuHeaderModel()
            header.refresh(from: env.ui)
            seen.withLock { $0 = (env.ui.connection.condition, env.ui.profiles.profile(auto.id)?.connectHeld,
                                  env.ui.profiles.profile(work.id)?.connectHeld, header.snapshot.toggleEnabled) }
        }
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        let (condition, autoHeld, workHeld, toggle) = try #require(seen.withLock { $0 })
        #expect(condition == .startHeld(StartHoldUI(name: work.name, reason: .preparing)))
        #expect(condition.actions == [.cancel])
        #expect(condition.copy(for: ProfileContext(name: work.name, protocolName: "WireGuard")).title == "Preparing to connect Work…")
        #expect(autoHeld == "LockPlus is preparing to connect Work.")
        #expect(workHeld == "LockPlus is preparing to connect Work.")
        #expect(!toggle)
        h.managers.emit(work.id, .connecting)
        UIBinder.render(h.env)
        #expect(h.env.ui.connection.condition.row == "4")                 // the status is real now
        #expect(h.env.ui.profiles.profile(auto.id)?.connectHeld == nil)
    }

    /// A fresh crash: while the cause is read, every Connect is held without a row (the crashed one's too: it has no
    /// on-demand rules, so NE may restart it, review e321e10 LOW 2); once NE's restart is
    /// awaited, row 12a says so (no action) and every Connect is held, the crashed profile's too.
    @Test func aCrashHoldsConnectsWhileTheRestartIsAwaited() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = pluginFailed
        h.managers.fetchNeverAnswers = true
        h.env.connection.disconnectErrorTimeout = .milliseconds(300)
        h.managers.emit(work.id, .disconnected)
        #expect(h.env.connection.startHold == ConnectionStore.StartHold(profile: work.id, reason: .readingDisconnect))
        #expect(h.env.connection.connectHold(for: work.id) != nil)      // review e321e10 LOW 2: no rules, NE may restart it
        #expect(h.env.connection.connectHold(for: auto.id) != nil)
        UIBinder.render(h.env)
        #expect(h.env.ui.connection.condition.row != "12a")
        #expect(h.env.ui.profiles.profile(auto.id)?.connectHeld == "LockPlus is checking why Work stopped.")
        #expect(h.env.ui.profiles.profile(work.id)?.connectHeld == "LockPlus is checking why Work stopped.")
        // The fetch timed out: treated as no crash, nothing held.
        #expect(await eventually { h.env.connection.startHold == nil })

        // A crash decided: NE's own restart is awaited (Work has no on-demand rules).
        h.managers.fetchNeverAnswers = false
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.env.connection.startHold?.reason == .awaitingRestart })
        #expect(h.env.connection.connectHold(for: work.id)?.reason == .awaitingRestart)
        UIBinder.render(h.env)
        #expect(h.env.ui.connection.condition == .startHeld(StartHoldUI(name: work.name, reason: .awaitingRestart)))
        #expect(h.env.ui.connection.condition.actions.isEmpty)
        #expect(h.env.ui.profiles.profile(work.id)?.connectHeld == "LockPlus is waiting for Work's tunnel process to restart.")
        h.managers.emit(work.id, .connecting)                            // NE's restart
        #expect(h.env.connection.startHold == nil)
    }

    /// The hand-back's connect (the end of a pause, an update) ignored because another start is in flight: Diagnostics
    /// says the profile wasn't reconnected. A target that already runs is no note.
    @Test func anIgnoredHandBackConnectIsNoted() async throws {
        let (h, fake) = pendingStartHarness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let connection = h.env.connection, autoID = auto.id
        fake.onFirstSleep { await connection.returnOnDemand([autoID], thenConnect: autoID) }
        connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.env.profiles.problems.map(\.message) == ["Home NAS wasn't reconnected: Work was starting at the time. Connect Home NAS again if you need it."])
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        await connection.returnOnDemand([], thenConnect: work.id)           // runs already: ignored, but no note
        #expect(h.env.profiles.problems.count == 1)
    }

    /// Row 12a in the table: only while not active, before 13a/14/15 (a Connect would be ignored there), after the
    /// switch row, the pause and the extension rows; never "Connecting…"; `readingDisconnect` shows no row.
    @Test func row12aInTheDerivedStateTable() {
        func c(_ hold: StartHoldUI.Reason?, _ change: (inout DerivedStateInputs) -> Void = { _ in }) -> ConnectionCondition {
            var i = DerivedStateInputs(profileName: "Work")
            i.startHold = hold.map { StartHoldUI(name: "Work", reason: $0) }
            change(&i)
            return i.condition
        }
        let ctx = ProfileContext(name: "Work", protocolName: "WireGuard")
        let preparing = c(.preparing)
        #expect(preparing == .startHeld(StartHoldUI(name: "Work", reason: .preparing)))
        #expect(preparing.row == "12a" && preparing.glyph == .connecting && preparing.heroTint == .transition && !preparing.isActive)
        #expect(preparing.actions == [.cancel])
        #expect(preparing.copy(for: ctx).message == "Not protected yet.")
        #expect(preparing.shortStateWord == "Preparing…")
        let waiting = c(.waitingForStop(of: "Home NAS"))
        #expect(waiting.copy(for: ctx) == ConditionCopy(title: "Waiting for Home NAS to disconnect…", message: "Then LockPlus connects Work. Not protected meanwhile."))
        #expect(waiting.actions == [.cancel] && waiting.shortStateWord == "Waiting…")
        let restart = c(.awaitingRestart) { $0.lastError = ObservedError(code: .engineDied) }       // before row 14
        #expect(restart.copy(for: ctx) == ConditionCopy(title: "Waiting for Work's tunnel process to restart…", message: "Not protected until Work is back."))
        #expect(restart.actions.isEmpty)
        // Review 5c3a899/f18c0d6 L-3 copy: our own start ended early: never "stopped unexpectedly", Cancel stays.
        let early = c(.startEndedEarly)
        #expect(early.row == "12a" && early.actions == [.cancel])
        #expect(early.copy(for: ctx) == ConditionCopy(title: "Checking whether Work starts…", message: "The start ended early. Not protected meanwhile."))
        #expect(!early.copy(for: ctx).message!.contains("unexpectedly"))
        #expect(early.headerCopy(for: ctx).title == "Checking Work…")
        #expect(StartHoldUI(name: "Work", reason: .startEndedEarly).explanation == "LockPlus is checking whether Work's tunnel process starts.")
        let may = c(.mayRestart)
        #expect(may.copy(for: ctx).message == "Work stopped unexpectedly. Not protected meanwhile.")
        #expect(c(.preparing) { $0.snapshot.startLatch = StartLatchUI(code: .authFailed, kind: .hard) }.row == "12a")    // before 13a
        #expect(c(.preparing) { $0.status = .invalid }.row == "12a")
        #expect(c(.readingDisconnect).row == "15")
        #expect(c(.readingDisconnect) { $0.lastError = ObservedError(code: .engineDied) }.row == "14")
        #expect(c(.preparing) { $0.status = .connecting }.row == "4")                    // a real status wins
        #expect(c(.preparing) { $0.status = .disconnecting }.row == "12")
        #expect(c(.preparing) { $0.switchingTo = "Home NAS" }.row == "12a")             // E2E-4 200012: the hold, not "switching"
        #expect(c(.preparing) { $0.switchingTo = "Home NAS"; $0.status = .connecting }.row == "switch")
        #expect(c(.preparing) { $0.pausedUntil = Date().addingTimeInterval(60) }.row == "2")
        for r in [StartHoldUI.Reason.preparing, .waitingForStop(of: "Home NAS"), .awaitingRestart] {
            let condition = c(r)
            #expect(!condition.copy(for: ctx).title.contains("Connecting"))
            #expect(condition.shortStateWord != "Connecting…")
        }
    }

    /// The store's hold → the UI's (names), and the help text per reason.
    @Test func theHoldMapping() {
        let a = UUID(), b = UUID()
        let name: (UUID) -> String? = { $0 == a ? "Work" : $0 == b ? "Home NAS" : nil }
        #expect(UIMapping.startHold(nil, name: name) == nil)
        #expect(UIMapping.startHold(.init(profile: a, reason: .waitingForStop(of: b)), name: name)
                == StartHoldUI(name: "Work", reason: .waitingForStop(of: "Home NAS")))
        #expect(StartHoldUI(name: "Work", reason: .waitingForStop(of: "Home NAS")).explanation
                == "LockPlus is waiting for Home NAS to disconnect, then connects Work.")
        #expect(UIMapping.startHold(.init(profile: UUID(), reason: .preparing), name: name)?.name == "")
        #expect(!StartHoldUI(name: "Work", reason: .readingDisconnect).showsRow)
    }

    /// `connect` says whether it was taken.
    @Test func connectReportsWhetherItWasTaken() async throws {
        let (h, fake) = pendingStartHarness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let connection = h.env.connection, autoID = auto.id
        let second = Mutex<Bool?>(nil)
        fake.onFirstSleep { @MainActor in second.withLock { $0 = connection.connect(autoID) } }
        #expect(connection.connect(work.id))
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(second.withLock { $0 } == false)
        h.managers.emit(work.id, .connecting)
        #expect(!connection.connect(work.id))                              // active (#5)
        #expect(!connection.connect(UUID()))                               // unknown
    }
}
