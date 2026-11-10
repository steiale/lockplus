import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import SystemExtensions
import Testing
@testable import LockPlus

/// Fable review 2026-10-30, fourth round (docs/native/reviews/2026-10-30-fable-ondemand-pause-4.md): findings 1–8 and
/// the missing tests §5 lists.
@MainActor @Suite("On-demand pause review 4", .serialized)
struct OnDemandPause4Tests {
    /// A auto (on-demand on), X a kill-switch manual profile, the connection store started.
    func setUp(_ h: Harness) async throws -> (auto: Profile, work: Profile) {
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        h.env.settings.update {
            $0.autoConnect.enabled = true
            $0.autoConnect.profileID = auto.id
        }
        await h.env.profiles.resaveOnDemand()
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        h.managers.onDemandChanges = [:]
        h.env.connection.start()
        return (auto, work)
    }

    func connected(_ h: Harness, _ p: Profile) async {
        let n = h.managers.starts.count
        h.env.connection.connect(p.id)
        _ = await eventually { h.managers.starts.count == n + 1 }
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
    }

    func saves(_ h: Harness, of p: Profile? = nil) -> Int {
        h.managers.log.filter { line in line.hasPrefix("begin save") && (p.map { line == "begin save \($0.name)" } ?? true) }.count
    }

    /// A negative check: `condition` stays false for a short window (a wrong second start would land within it).
    func never(_ condition: () -> Bool) async -> Bool { !(await eventually(.milliseconds(300), condition)) }

    // MARK: #1

    /// A's own on-demand comes back inside A's start (it was recorded). The user connects Work inside A's settle: the
    /// Connect is ignored. The old code started Work beside A, and Work's pause turned A's on-demand off again inside A's
    /// pending start (a save of another manager there, E2E-3).
    @Test func aConnectOfAnotherProfileInsideAPendingStartIsIgnored() async throws {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)             // a 1 s settle (on the fake clock)
        let (auto, work) = try await setUp(h)
        h.managers.entries[auto.id]?.onDemand = false                   // paused by an earlier start of another profile
        try await h.env.managers.loadAll()
        await h.env.settings.updateDurably { $0.onDemandPausedByStart = [auto.id] }
        let connection = h.env.connection, workID = work.id
        fake.onFirstSleep { await MainActor.run { connection.connect(workID) } }
        h.managers.log = []
        h.env.connection.connect(auto.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(fake.sleeps.count == 1)                                 // the hook ran inside A's settle
        #expect(await never { h.managers.starts.count > 1 })
        #expect(h.managers.starts.map(\.0) == [auto.id])
        #expect(h.managers.onDemandChanges[auto.id] == [true])          // its own restore, no pause after it
        #expect(saves(h, of: work) == 0)
    }

    /// A switch to Y waits for X's stop; a Connect of Z meanwhile is ignored (the old code issued Z into NE's Stopping,
    /// where it is silently dropped, S2), and only Y starts at X's `.disconnected`.
    @Test func aConnectDuringASwitchIsIgnored() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        let y = try await h.add("Travel.conf", Harness.wgConf, killSwitch: true)
        let z = try await h.add("Office.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        await connected(h, work)
        h.env.connection.connect(y.id)
        #expect(await eventually { h.managers.stops == [work.id] })
        h.env.connection.connect(z.id)
        #expect(await never { h.managers.starts.count > 1 })
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.starts.count == 2 })
        #expect(await never { h.managers.starts.count > 2 })
        #expect(h.managers.starts.map(\.0) == [work.id, y.id])
    }

    /// The hand-back's connect (the end of a pause, an extension update) is ignored while another start is pending: what
    /// it handed back stays recorded and returns when that start's session ends, never silently off.
    @Test func anIgnoredHandBackConnectLeavesItsIdsRecorded() async throws {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)             // a 1 s settle (on the fake clock)
        let (auto, work) = try await setUp(h)
        let connection = h.env.connection, autoID = auto.id
        fake.onFirstSleep { await connection.returnOnDemand([autoID], thenConnect: autoID) }
        h.env.connection.connect(work.id)                              // pauses A (recorded), then the settle
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(fake.sleeps.count == 1)
        #expect(await never { h.managers.starts.count > 1 })
        #expect(h.managers.starts.map(\.0) == [work.id])
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        #expect(UIBinder.autoConnectStatusLine(h.env) == "Auto-connect resumes when you disconnect \(work.name).")
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(await eventually { h.env.settings.value.onDemandPausedByStart.isEmpty })
    }

    // MARK: #5

    /// A Connect of the running profile (the sidebar's context menu offers it) starts nothing and saves nothing: no
    /// `prepareForStart` on a live manager (L-KS-2), no `startVPNTunnel` into a live session.
    @Test func aConnectOfTheActiveProfileDoesNothing() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await connected(h, work)
        for s in [TunnelStatus.connected, .reasserting, .connecting] {
            h.managers.emit(work.id, s)
            h.managers.log = []
            h.env.connection.connect(work.id)
            #expect(await never { h.managers.starts.count > 1 || saves(h) > 0 })
            #expect(h.env.connection.startFailure == nil)
        }
    }

    // MARK: #2

    /// Install-and-Relaunch records `expectedUpdate`; a re-save in that window holds A's plan off; Sparkle then aborts.
    /// Clearing the marker restores A at once (the old code only cleared it: A stayed off until a status event that, with
    /// nothing running, never came).
    @Test func anInstallThatDidNotHappenRestoresWhatTheMarkerHeldOff() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, _) = try await setUp(h)
        h.env.updates.prepareForInstall(toVersion: "99")
        await h.env.profiles.resaveOnDemand()                          // the plan is held while the marker is set
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        h.env.updates.installDidNotHappen()
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.env.settings.value.expectedUpdate == nil)
        #expect(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)?.expectedUpdate == nil)
    }

    /// The same through `resumeAfterUpdate` when nothing was quiesced (only `expectedUpdate` set): the activation
    /// completed, the marker clears, and A comes back without a status event.
    @Test func aCompletedActivationWithNothingQuiescedRestoresWhatTheMarkerHeldOff() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, _) = try await setUp(h)
        let q = ManagerQuiescer()
        q.attach(managers: h.env.managers, settings: h.env.settings, connection: h.env.connection)
        h.env.settings.update { $0.expectedUpdate = ExpectedUpdate(from: "1", to: "2") }
        await h.env.profiles.resaveOnDemand()
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        await q.resumeAfterUpdate()
        #expect(h.env.settings.value.expectedUpdate == nil)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    // MARK: #3

    final class RecordingQuiescer: TunnelQuiescing {
        var calls: [String] = []
        func hasOnDemandOrResumeMarker() async -> Bool { false }
        func quiesce(reason: QuiesceReason) async { calls.append("quiesce \(reason.rawValue)") }
        func resumeAfterUpdate() async { calls.append("resume") }
    }

    func extensionManager(_ q: any TunnelQuiescing) -> (SystemExtensionManager, SystemExtensionManagerTests.Recorder) {
        let rec = SystemExtensionManagerTests.Recorder()
        let m = SystemExtensionManager(bundle: .main, quiescer: q, submitter: { rec.requests.append($0) },
                                       propertiesTimeout: .milliseconds(50), activationWatchdog: .seconds(60), openSettings: {})
        return (m, rec)
    }

    func sysextError(_ code: SystemExtensionErrorCode) -> NSError { NSError(domain: OSSystemExtensionErrorDomain, code: code.rawValue) }

    /// An extension update quiesced (A off, `pendingResume`), then the activation fails: the installed extension keeps
    /// working, so the hand-over ends and A comes back (the old code left `pendingResume` set: every plan held, the
    /// pane silent). While the hand-over lasts, the pane says so.
    @Test func aFailedActivationAfterAQuiesceHandsBack() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, _) = try await setUp(h)
        let q = ManagerQuiescer()
        q.attach(managers: h.env.managers, settings: h.env.settings, connection: h.env.connection)
        await q.quiesce(reason: .extensionUpdate)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(UIBinder.autoConnectStatusLine(h.env) == "Auto-connect is paused while the tunnel component is updated.")
        let (m, rec) = extensionManager(q)
        await m.activate()
        m.request(rec.requests[1], didFailWithError: sysextError(.validationFailed))
        #expect(m.state == .failed(.broken(code: SystemExtensionErrorCode.validationFailed.rawValue)))
        #expect(await eventually { h.env.settings.value.pendingResume == nil })
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(UIBinder.autoConnectStatusLine(h.env) == nil)
    }

    /// Every activation failure hands back (a refusal, a cancel with no successor, the watchdog); a superseded one
    /// doesn't (the newer request owns the outcome).
    @Test func everyActivationFailureHandsBack() async throws {
        for code in [SystemExtensionErrorCode.forbiddenBySystemPolicy, .requestCanceled, .requestSuperseded] {
            let q = RecordingQuiescer()
            let (m, rec) = extensionManager(q)
            await m.activate()
            if code == .requestSuperseded { _ = m.submitSecondActivationForTesting() }
            m.request(rec.requests[1], didFailWithError: sysextError(code))
            if code == .requestSuperseded {
                #expect(await never { q.calls.contains("resume") })
            } else {
                #expect(await eventually { q.calls == ["resume"] })
            }
        }
        // The watchdog's failure: review 5 #3 reads the properties again and hands back to the enabled extension.
        let a = OnDemandPause5Tests.Answering()
        let activation = Task { await a.m.activate() }
        #expect(await a.answer(0, []))                                  // nothing installed: no quiesce
        await activation.value
        #expect(await a.answer(2, [OnDemandPause5Tests.entry(try #require(a.m.embeddedVersion))]))
        #expect(await eventually { a.q.calls == ["resume"] })
    }

    /// A reinstall: a deactivation that is cancelled hands back (nothing was removed); once our deactivation removed
    /// the extension, a failed activation keeps the hand-over (there is nothing to hand back to).
    @Test func aReinstallHandsBackOnlyWhileTheOldExtensionIsInstalled() async throws {
        do {
            let q = RecordingQuiescer()
            let (m, rec) = extensionManager(q)
            await m.activate()
            m.request(rec.requests[1], didFinishWithResult: .completed)
            let n = rec.requests.count
            let t = Task { @MainActor () -> LPError? in do throws(LPError) { try await m.reinstall(); return nil } catch { return error } }
            #expect(await eventually { rec.requests.count == n + 1 })
            m.request(rec.requests[n], didFailWithError: sysextError(.requestCanceled))
            #expect(await t.value?.code == .cancelled)
            #expect(await eventually { q.calls == ["resume", "quiesce reinstall", "resume"] })
        }
        do {
            let q = RecordingQuiescer()
            let (m, rec) = extensionManager(q)
            await m.activate()
            m.request(rec.requests[1], didFinishWithResult: .completed)
            let n = rec.requests.count
            let t = Task { @MainActor () -> LPError? in do throws(LPError) { try await m.reinstall(); return nil } catch { return error } }
            #expect(await eventually { rec.requests.count == n + 1 })
            m.request(rec.requests[n], didFinishWithResult: .completed)      // deactivated: removed
            #expect(await t.value == nil)
            #expect(rec.requests.count == n + 2)
            m.request(rec.requests[n + 1], didFailWithError: sysextError(.validationFailed))
            #expect(await never { q.calls.count > 2 })
            #expect(q.calls == ["resume", "quiesce reinstall"])
        }
    }

    // MARK: #6

    /// The previous headless run started the target and the watchdog ended it before its final write: the next run finds
    /// the pause still set and the target live. It neither verifies (no save of the live manager, L-KS-2) nor starts it
    /// again; it records what stays off and clears the pause.
    @Test func aHeadlessRetryLeavesALiveTargetAlone() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        var s = AppSettings()
        s.autoConnect.pausedUntil = Date().addingTimeInterval(-5)
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [work.id, auto.id], agentBuild: "1")
        s.onDemandPausedByStart = [auto.id]                            // the first run's early write
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        h.managers.entries[work.id]?.onDemand = true                   // the first run turned it on, then started it
        h.managers.entries[work.id]?.cfg.flags.includeAllNetworks = false   // and nehelper rewrote it since
        h.managers.entries[work.id]?.status = .connecting
        h.managers.log = []
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(r == .resumed(restarted: work.id, onDemand: [work.id]))
        #expect(h.managers.starts.isEmpty)
        #expect(h.managers.log.filter { $0.hasPrefix("begin save") }.isEmpty)
        let disk = AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)
        #expect(disk?.autoConnect.pausedUntil == nil)
        #expect(disk?.onDemandPausedByStart == [auto.id])
    }

    // MARK: #8

    /// While Work runs (and, the same predicate, while its kill-switch start is pending), no other own manager is saved
    /// or removed: an import, a policy change and an editor save of another profile, the onboarding's first save and a
    /// delete all leave the managers alone (the metadata is saved). When Work ends, the deferred sync brings every
    /// manager up to date: created, re-saved, removed.
    @Test func managerSavesOfOtherProfilesWaitWhileAnotherRuns() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let other = try await h.add("Office.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        await connected(h, work)
        let apns = try #require(h.env.profiles.profile(auto.id)).policy.excludeAPNs
        h.managers.log = []
        let travel = try await h.add("Travel.conf", Harness.wgConf, killSwitch: true)
        try await h.env.profiles.updatePolicy(auto.id) { $0.excludeAPNs.toggle() }
        let a = await ImportCoordinator.analyse(fileName: "Home NAS.conf", bytes: Array(Harness.splitConf.utf8), service: h.service, probe: NullProbe())
        let d = try #require(h.env.importer.draft(a, name: auto.name, killSwitch: false, allowLAN: false))
        try await h.env.profiles.replacePayload(auto.id, with: d)
        h.env.ui.actions.allowVPNConfiguration()
        // Review 5 #5: the step says the save is deferred.
        #expect(await eventually { if case .deferred = h.env.ui.onboarding.configurationStep { true } else { false } })
        await h.env.profiles.delete(other.id)
        #expect(saves(h) == 0)
        #expect(h.managers.entries[travel.id] == nil)
        #expect(h.managers.entries[other.id] != nil)
        #expect(h.env.profiles.profile(auto.id)?.policy.excludeAPNs == !apns)      // the metadata is saved
        #expect(h.env.profiles.hasDeferredSync)
        h.env.connection.disconnect()
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[travel.id] != nil })
        #expect(await eventually { h.managers.entries[auto.id]?.cfg.flags.excludeAPNs == !apns })
        #expect(await eventually { h.managers.entries[auto.id]?.cfg.provider.revision == 2 })
        #expect(await eventually { h.managers.entries[other.id] == nil })
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }
}
