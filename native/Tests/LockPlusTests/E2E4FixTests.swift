import Foundation
import LPModel
import NetworkExtension
import Security
import Synchronization
import SystemExtensions
import Testing
@testable import LockPlus

/// E2E-4 (2026-10-30, macOS 26 and 27; PENDING-FOLD 58): the decisions the VM measurements forced.
/// - U7 reversal: a running profile's own flags that the system WEAKENED are healed on the connected session.
/// - Orphans and strays: `loadAll` removes nothing; this user's go at idle only; ANY configuration's live session is busy.
/// - U15: a failed replacement with the old extension still enabled is "couldn't update", not "damaged".
/// - The settings reset: no write before settings.json was read; an unreadable file is moved aside and reported.
@MainActor @Suite("E2E-4 fixes", .serialized)
struct E2E4FixTests {
    let t4 = OnDemandPause4Tests()

    func setUp(_ h: Harness) async throws -> (auto: Profile, work: Profile) { try await t4.setUp(h) }
    func connected(_ h: Harness, _ p: Profile) async { await t4.connected(h, p) }
    func saves(_ h: Harness, of p: Profile? = nil) -> Int { t4.saves(h, of: p) }
    func never(_ condition: () -> Bool) async -> Bool { await t4.never(condition) }

    // MARK: U7 reversal

    /// The kill switch of the connected Work disappears from its manager (nehelper's rewrite, an administrator): the
    /// next reload saves the plan's flags onto the live session at once (U7: NE applies them without a teardown), and
    /// Diagnostics says so. Before: noted and left weakened until the session ended (review N3).
    @Test func aWeakenedConnectedSessionIsHealedAtOnce() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await connected(h, work)
        h.managers.log = []
        h.managers.entries[work.id]?.cfg.flags.includeAllNetworks = false
        try await h.env.managers.loadAll()                                // the reload NEVPNConfigurationChange triggers
        await h.env.profiles.load()
        #expect(saves(h, of: work) == 1)
        #expect(h.managers.entries[work.id]?.cfg.flags.includeAllNetworks == true)
        #expect(h.managers.stops.isEmpty)                                  // no teardown, no restart
        #expect(h.env.profiles.problems.last?.message.contains("LockPlus restored them") == true)
    }

    /// The same weakening while Work is still `.connecting` (its own pending kill-switch start): nothing is saved then
    /// (E2E-3), it is noted, and it is healed at `.connected`.
    @Test func aWeakeningWhileConnectingIsHealedAtConnected() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .connecting)
        h.managers.log = []
        h.managers.entries[work.id]?.cfg.flags.includeAllNetworks = false
        try await h.env.managers.loadAll()                                // the reload NEVPNConfigurationChange triggers
        await h.env.profiles.load()
        #expect(saves(h, of: work) == 0)
        #expect(h.env.profiles.problems.last?.message.contains("as soon as it is connected") == true)
        h.managers.emit(work.id, .connected)
        #expect(await eventually { h.managers.entries[work.id]?.cfg.flags.includeAllNetworks == true })
        #expect(saves(h, of: work) == 1)
    }

    /// Only the protective direction: a manager that protects MORE than the plan (here `excludeLocalNetworks` off while
    /// the profile allows the LAN) is not saved while the session runs (L-KS-2).
    @Test func aDriftThatOnlyAddsProtectionWaitsForTheSessionToEnd() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        try await h.env.profiles.updatePolicy(work.id) { $0.allowLAN = true }
        try await h.env.managers.loadAll()
        #expect(h.managers.entries[work.id]?.cfg.flags.excludeLocalNetworks == true)
        await connected(h, work)
        h.managers.log = []
        h.managers.entries[work.id]?.cfg.flags.excludeLocalNetworks = false
        try await h.env.managers.loadAll()                                // the reload NEVPNConfigurationChange triggers
        await h.env.profiles.load()
        #expect(saves(h, of: work) == 0)
        #expect(h.env.profiles.hasDeferredSync)
    }

    /// A configuration the system keeps weakening is healed once per revision on the live session and then reported,
    /// never looped (review M1). The idle path still gets its own attempt: a manager that is weak when the session ends
    /// would run an on-demand start (which never goes through `prepareForStart`) without the kill switch.
    @Test func aRepeatedWeakeningIsReportedNotLoopedAndGetsItsIdleAttempt() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await connected(h, work)
        h.managers.log = []
        h.managers.dropIncludeAllNetworksOnSave = true
        h.managers.entries[work.id]?.cfg.flags.includeAllNetworks = false
        try await h.env.managers.loadAll()                                // the reload NEVPNConfigurationChange triggers
        await h.env.profiles.load()
        try await h.env.managers.loadAll()
        await h.env.profiles.load()
        try await h.env.managers.loadAll()
        await h.env.profiles.load()
        #expect(saves(h, of: work) == 1)                                   // live: once
        #expect(h.env.profiles.problems.contains { $0.message.contains("tries once more when it disconnects") })
        #expect(h.env.profiles.hasDeferredSync)                           // the repeat branch asks for the idle attempt
        h.managers.dropIncludeAllNetworksOnSave = false                   // this time the system leaves it alone
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[work.id]?.cfg.flags.includeAllNetworks == true })
        #expect(saves(h, of: work) == 2)                                   // one more, at idle
    }

    /// When the idle attempt is undone too, it is reported with the way out; nothing loops.
    @Test func aWeakeningThatSurvivesTheIdleAttemptIsReportedLast() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await connected(h, work)
        h.managers.log = []
        h.managers.dropIncludeAllNetworksOnSave = true
        h.managers.entries[work.id]?.cfg.flags.includeAllNetworks = false
        for _ in 0..<2 {
            try await h.env.managers.loadAll()
            await h.env.profiles.load()
        }
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { saves(h, of: work) == 2 })
        for _ in 0..<2 {
            try await h.env.managers.loadAll()
            await h.env.profiles.load()
        }
        #expect(saves(h, of: work) == 2)
        #expect(h.env.profiles.problems.contains { $0.message.contains("couldn't be restored") })
    }

    /// The connected profile's weakened flags while ANOTHER user's session is live (`mutationBlocked`): not healed, said,
    /// and healed as soon as theirs ends (review test gap b).
    @Test func aWeakenedConnectedSessionBesideAnotherUsersSessionIsHealedWhenTheirsEnds() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await connected(h, work)
        let theirs = otherUsersManager(h, like: work, status: .connecting)
        h.managers.log = []
        h.managers.entries[work.id]?.cfg.flags.includeAllNetworks = false
        try await h.env.managers.loadAll()
        await h.env.profiles.load()
        #expect(saves(h, of: work) == 0)
        #expect(h.env.profiles.problems.last?.message.contains("as soon as no other connection is starting") == true)
        #expect(h.env.profiles.hasDeferredSync)
        h.managers.emit(theirs, .disconnected)
        #expect(await eventually { h.managers.entries[work.id]?.cfg.flags.includeAllNetworks == true })
        #expect(saves(h, of: work) == 1)
    }

    @Test func weakerIsOnlyTheProtectiveDirection() {
        let plan = ProtocolFlags(policy: NetworkPolicy(killSwitch: true), isFullTunnel: true)
        var f = plan
        #expect(!f.isWeaker(than: plan))
        f.includeAllNetworks = false
        #expect(f.isWeaker(than: plan))
        f = plan; f.excludeLocalNetworks = true
        #expect(f.isWeaker(than: plan))
        f = plan; f.excludeAPNs = !plan.excludeAPNs
        #expect(f.isWeaker(than: plan) == f.excludeAPNs)
        let off = ProtocolFlags(policy: NetworkPolicy(killSwitch: false), isFullTunnel: true)
        #expect(!plan.isWeaker(than: off))                              // more protection than planned: not "weaker"
    }

    // MARK: Orphans, strays, and another user's session

    func otherUsersManager(_ h: Harness, like p: Profile, status: TunnelStatus) -> UUID {
        var cfg = ManagerConfiguration(profile: p, onDemand: nil)
        cfg.profileID = UUID()
        cfg.provider.profileID = cfg.profileID
        cfg.provider.ownerUID = getuid() &+ 1
        h.managers.entries[cfg.profileID] = .init(cfg: cfg, status: status, onDemand: false)
        return cfg.profileID
    }

    /// This user's strays go at idle; another user's (U3) and one whose owner can't be read are never touched.
    @Test func onlyThisUsersStraysAreRemovedAndOnlyAtIdle() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await setUp(h)
        let mine = StraySnapshot(key: UUID(), ownerUID: getuid(), status: .disconnected)
        let theirs = StraySnapshot(key: UUID(), ownerUID: getuid() &+ 1, status: .disconnected)
        let unknown = StraySnapshot(key: UUID(), ownerUID: nil, status: .disconnected)
        h.managers.strayEntries = [mine, theirs, unknown]
        try await h.env.managers.loadAll()
        await h.env.profiles.load()
        #expect(h.managers.removed == [mine.key])
        #expect(Set(h.managers.strays.map(\.key)) == [theirs.key, unknown.key])
    }

    /// Another user's session (U2/U13: any configuration change inside it breaks it) holds every non-essential
    /// mutation: this user's orphan and stray wait, and go when it ends.
    @Test func anotherUsersSessionHoldsTheOrphanSweep() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let theirs = otherUsersManager(h, like: work, status: .connecting)
        var orphan = ManagerConfiguration(profile: auto, onDemand: nil)
        orphan.profileID = UUID()
        orphan.provider.profileID = orphan.profileID
        h.managers.entries[orphan.profileID] = .init(cfg: orphan, status: .disconnected, onDemand: false)
        let stray = StraySnapshot(key: UUID(), ownerUID: getuid(), status: .disconnected)
        h.managers.strayEntries = [stray]
        try await h.env.managers.loadAll()
        #expect(h.env.connection.isBusy)
        await h.env.profiles.load()
        #expect(h.managers.removed.isEmpty)
        #expect(h.env.profiles.hasDeferredSync)
        h.managers.emit(theirs, .disconnected)
        #expect(await eventually { Set(h.managers.removed) == [orphan.profileID, stray.key] })
        #expect(h.managers.entries[theirs] != nil)                         // theirs is not an orphan of ours
    }

    /// A live stray of ours counts as busy too, so nothing mutates beside it.
    @Test func aLiveStraySessionIsBusy() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await setUp(h)
        h.managers.strayEntries = [StraySnapshot(key: UUID(), ownerUID: getuid(), status: .connected)]
        try await h.env.managers.loadAll()
        #expect(h.env.connection.isBusy)
        await h.env.profiles.load()
        #expect(h.managers.removed.isEmpty)
    }

    /// A delete while another user's session starts: the removal waits for idle (it would break that start, U13).
    @Test func aDeleteWaitsForAnotherUsersSession() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        let theirs = otherUsersManager(h, like: work, status: .connecting)
        try await h.env.managers.loadAll()
        await h.env.profiles.delete(work.id)
        #expect(h.managers.entries[work.id] != nil)
        h.managers.emit(theirs, .connected)
        h.managers.emit(theirs, .disconnected)
        #expect(await eventually { h.managers.entries[work.id] == nil })
    }

    /// The user's own Connect still proceeds beside another user's live configuration (a kill-switch start replaces
    /// any other tunnel anyway); its pause saves are unchanged.
    @Test func theUsersConnectProceedsBesideAnotherUsersConfiguration() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        _ = otherUsersManager(h, like: work, status: .disconnected)
        try await h.env.managers.loadAll()
        #expect(h.env.connection.connect(work.id))
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.onDemandChanges[auto.id] == [false])
    }

    // MARK: U15: failed replacement, old extension still enabled

    /// Code 8 (an invalid signature) over an installed older extension: "couldn't update", the tunnels handed back
    /// through NE (U12), not "damaged". With nothing installed it stays "damaged".
    @Test func aFailedReplacementOverAWorkingExtensionIsCouldNotUpdate() async throws {
        let a = OnDemandPause5Tests.Answering(watchdog: .seconds(60))
        let activation = Task { await a.m.activate() }
        #expect(await a.answer(0, [OnDemandPause5Tests.entry(OnDemandPause5Tests.old)]))
        await activation.value
        a.m.request(a.rec.requests[1], didFailWithError: NSError(domain: OSSystemExtensionErrorDomain, code: SystemExtensionErrorCode.codeSignatureInvalid.rawValue))
        #expect(a.m.state == .updateFailed(installed: OnDemandPause5Tests.old.description, code: 8))
        #expect(await eventually { a.q.calls.contains("resume") })

        let b = OnDemandPause5Tests.Answering(watchdog: .seconds(60))
        let fresh = Task { await b.m.activate() }
        #expect(await b.answer(0, []))
        await fresh.value
        b.m.request(b.rec.requests[1], didFailWithError: NSError(domain: OSSystemExtensionErrorDomain, code: SystemExtensionErrorCode.codeSignatureInvalid.rawValue))
        #expect(b.m.state == .failed(.broken(code: 8)))
    }

    @Test func activationFailureStateMapping() {
        let old = OnDemandPause5Tests.old
        #expect(SystemExtensionManager.activationFailureState(.broken(code: 9), code: 9, installed: old) == .updateFailed(installed: old.description, code: 9))
        #expect(SystemExtensionManager.activationFailureState(.broken(code: 9), code: 9, installed: nil) == .failed(.broken(code: 9)))
        #expect(SystemExtensionManager.activationFailureState(.notInApplications, code: 3, installed: old) == .failed(.notInApplications))
    }

    /// The UI: Connect isn't blocked (row 1 not entered), a connected session isn't "not responding" for the expected
    /// unreachable XPC link, and the window and the menu carry the honest line; "Try again" re-activates.
    @Test func couldNotUpdateIsHonestAndKeepsConnectAvailable() async throws {
        #expect(ExtensionMapping.readiness(.updateFailed(installed: "2.0.0 (200005)", code: 8), endedWithoutResult: false) == .updateFailed)
        #expect(!ExtensionReadiness.updateFailed.blocksTunnel)
        var i = DerivedStateInputs(profileName: "Work")
        i.extensionReadiness = .updateFailed
        i.status = .connected
        i.link = .unavailable
        #expect(i.condition == .protected)
        i.extensionReadiness = .ready
        #expect(i.condition == .tunnelProcessUnresponsive)

        let h = Harness()
        defer { h.dir.cleanup() }
        h.ext.state = .updateFailed(installed: "2.0.0 (200005)", code: 8)
        UIBinder.render(h.env)
        let line = try #require(h.env.ui.connection.extensionUpdateFailedMessage)
        #expect(line.hasPrefix("LockPlus couldn't update its tunnel component. Profiles set up before the update still connect"))
        #expect(line.hasSuffix("(8)"))
        if case .failed(let m) = ExtensionMapping.onboardingStep(h.ext.state, endedWithoutResult: false) { #expect(m == line) } else { Issue.record("onboarding step") }
        h.env.ui.actions.installExtension()
        #expect(await eventually { h.ext.retries == 1 })
    }

    /// A profile read that fails (here: the keychain refuses) is not an empty library: the reason is kept for the UI and
    /// Diagnostics, once.
    @Test func anUnreadableProfileListIsNotNoProfiles() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        await h.env.profiles.repository.resetKeyCache()
        h.keychain.failure.withLock { $0 = errSecInteractionNotAllowed }
        await h.env.profiles.load()
        await h.env.profiles.load()
        #expect(h.env.profiles.loadError != nil)
        #expect(h.env.profiles.problems.filter { $0.message.hasPrefix("Profiles could not be read") }.count == 1)
        UIBinder.render(h.env)
        #expect(h.env.ui.profiles.readError == h.env.profiles.loadError)
        h.keychain.failure.withLock { $0 = nil }
        await h.env.profiles.load()
        #expect(h.env.profiles.loadError == nil)
    }

    // MARK: Settings reset (E2E-4, 26 under 200005)

    func writeSettings(_ dir: TestDir, onboarded: Bool = true) throws -> AppSettings {
        var s = AppSettings()
        s.onboardingComplete = onboarded
        s.lastUsedProfileID = UUID()
        try AtomicFile.saveJSON(s, to: dir.data.settings)
        return s
    }

    /// The root cause: a quit before `start()` read settings.json wrote the in-memory defaults over it (the quit path's
    /// synchronous write; a queued update too). Nothing is written before the read now.
    @Test func aQuitBeforeTheSettingsWereReadWritesNothing() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let saved = try writeSettings(dir)
        let h = Harness(dir: dir, settingsWritableBeforeLoad: false)
        h.env.recordMenuOpened()                                            // a queued write before the read
        await h.env.settings.flush()
        h.env.stop()                                                        // applicationWillTerminate
        #expect(AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings) == saved)

        let s = SettingsStore(files: SettingsFileStore(dir: dir.data), loadedFromDisk: false)
        s.update { $0.lastQuitAt = Date() }
        s.writeSynchronously()
        await s.flush()
        #expect(AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings) == saved)
        s.replaceAll(saved)
        s.update { $0.onboardingComplete = false }
        await s.flush()
        #expect(AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings)?.onboardingComplete == false)
    }

    @Test func aMissingSettingsFileIsDefaultsWithoutAProblem() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let r = await SettingsFileStore(dir: dir.data).loadSettingsChecked(retryDelay: .zero)
        #expect(r.settings == AppSettings())
        #expect(r.problem == nil && r.movedAside == nil)
    }

    /// An unreadable or corrupt file is moved aside (kept, never overwritten) as settings.unreadable-<UTC>.json.
    @Test func aCorruptSettingsFileIsMovedAsideAndReported() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        try AtomicFile.ensureDirectory(dir.url)
        let junk = Data("{\"onboardingComplete\": tru".utf8)
        try junk.write(to: dir.data.settings)
        let r = await SettingsFileStore(dir: dir.data).loadSettingsChecked(retryDelay: .zero)
        #expect(r.settings == AppSettings())
        let moved = try #require(r.movedAside)
        #expect(moved.lastPathComponent.hasPrefix("settings.unreadable-") && moved.pathExtension == "json")
        #expect(try Data(contentsOf: moved) == junk)
        #expect(!FileManager.default.fileExists(atPath: dir.data.settings.path))

        // A file that can't be opened (no read permission) is retried once, then moved aside the same way. NOTE: this
        // relies on `chmod 0` denying the read, which root ignores: run as root, the file reads fine, the settings
        // decode fails instead, and the assertion below still holds only because `junk` isn't valid JSON (it passes,
        // but doesn't exercise the unreadable branch). CI runs as a user.
        try junk.write(to: dir.data.settings)
        chmod(dir.data.settings.path, 0)
        let r2 = await SettingsFileStore(dir: dir.data).loadSettingsChecked(retryDelay: .zero)
        #expect(r2.movedAside != nil && r2.problem != nil)
    }

    /// At launch the problem reaches Diagnostics › Problems and the defaults are in use.
    @Test func launchNotesAnUnreadableSettingsFile() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        try AtomicFile.ensureDirectory(dir.url)
        try Data("not json".utf8).write(to: dir.data.settings)
        let h = Harness(dir: dir, settingsWritableBeforeLoad: false)
        let problem = await h.env.loadSettingsAtLaunch()
        #expect(h.env.settings.loadedFromDisk)
        #expect(h.env.settings.value == AppSettings())
        h.env.noteSettingsProblem(problem)
        #expect(h.env.profiles.problems.contains { $0.message.contains("couldn't read its settings") && $0.message.contains("settings.unreadable-") })
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(names.contains { $0.hasPrefix("settings.unreadable-") })
    }

    /// The headless resume never defaults over an unreadable file: it changes nothing and keeps its registration.
    @Test func theHeadlessResumeLeavesAnUnreadableFileAlone() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        try AtomicFile.ensureDirectory(dir.url)
        let junk = Data("{".utf8)
        try junk.write(to: dir.data.settings)
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: dir.data, managers: FakeVPNManager(), agent: agent, keychain: InMemoryKeychain())
        #expect(r == .settingsUnreadable)
        #expect(agent.calls.isEmpty)
        #expect(try Data(contentsOf: dir.data.settings) == junk)
    }

    // MARK: Busy reasons (review L1)

    /// What holds everything back is said: one of ours, another user's connection, or one LockPlus can't address.
    @Test func theBusyReasonSaysWhoseSessionItIs() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        func reason(strays: [StraySnapshot]) async throws -> ConnectionStore.BusyReason? {
            h.managers.strayEntries = strays
            try await h.env.managers.loadAll()                              // the app reads a snapshot taken at the load
            return h.env.connection.busyReason
        }
        #expect(h.env.connection.busyReason == nil)
        #expect(try await reason(strays: [StraySnapshot(key: UUID(), ownerUID: getuid(), status: .connected)]) == .unaddressable)
        #expect(try await reason(strays: [StraySnapshot(key: UUID(), ownerUID: nil, status: .connecting)]) == .unaddressable)
        #expect(try await reason(strays: [StraySnapshot(key: UUID(), ownerUID: getuid() &+ 1, status: .connected)]) == .anotherUser)
        #expect(try await reason(strays: [StraySnapshot(key: UUID(), ownerUID: getuid() &+ 1, status: .disconnected)]) == nil)
        let theirs = otherUsersManager(h, like: work, status: .connected)
        try await h.env.managers.loadAll()
        #expect(h.env.connection.busyReason == .anotherUser)
        h.managers.emit(theirs, .disconnected)
        await connected(h, work)
        #expect(h.env.connection.busyReason == .profile(work.id))
        #expect(h.env.connection.busyProfile == work.id)
    }

    /// The Auto-Connect pane and Diagnostics say it (once per appearance); the line goes when the session ends.
    @Test func anotherUsersSessionIsShownInThePaneAndDiagnostics() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        #expect(UIBinder.autoConnectStatusLine(h.env) == nil)
        let theirs = otherUsersManager(h, like: work, status: .connected)
        try await h.env.managers.loadAll()
        h.env.connection.configurationChanged()
        h.env.connection.configurationChanged()
        let line = try #require(UIBinder.autoConnectStatusLine(h.env))
        #expect(line.hasPrefix("Another user's VPN connection is active."))
        #expect(h.env.profiles.problems.filter { $0.message == line }.count == 1)
        h.managers.emit(theirs, .disconnected)
        try await h.env.managers.loadAll()
        #expect(UIBinder.autoConnectStatusLine(h.env) == nil)
        h.managers.emit(theirs, .connected)                                // a new appearance is noted again
        try await h.env.managers.loadAll()
        h.env.connection.configurationChanged()
        #expect(h.env.profiles.problems.filter { $0.message == line }.count == 2)
        h.managers.emit(theirs, .disconnected)
        h.managers.strayEntries = [StraySnapshot(key: UUID(), ownerUID: getuid(), status: .connected)]
        try await h.env.managers.loadAll()
        #expect(UIBinder.autoConnectStatusLine(h.env)?.hasPrefix("A VPN configuration LockPlus can't address is active.") == true)
    }

    @Test func theOnboardingLineNamesWhatItWaitsFor() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let line = { (r: ConnectionStore.BusyReason?) in AppActions.deferredFirstSaveLine(auto, busy: r, profiles: h.env.profiles) }
        #expect(line(.profile(work.id)) == "LockPlus adds the VPN configuration for \(auto.name) when \(work.name) disconnects.")
        #expect(line(.anotherUser) == "LockPlus adds the VPN configuration for \(auto.name) when another user's VPN connection ends.")
        #expect(line(.unaddressable).contains("can't address"))
        #expect(line(nil) == "LockPlus adds the VPN configuration for \(auto.name) when the current VPN connection ends.")
        #expect(line(.profile(UUID())) == line(nil))                        // a profile that isn't ours to name
    }

    // MARK: Classification (review L2, test gap c)

    typealias Candidate = ManagerClassifier.Candidate<String>

    @Test func theClassifierSortsAddressableFromStrays() {
        let me: uid_t = 501, other: uid_t = 502
        let id = UUID(), id2 = UUID()
        func c(_ name: String, _ profile: String?, owner: uid_t? = 501, rev: UInt64? = 1) -> Candidate {
            Candidate(manager: name, profileID: profile, owner: owner, metaRev: rev)
        }
        // No profile ID, or one that isn't a UUID: strays (review M3).
        var r = ManagerClassifier.classify([c("none", nil), c("junk", "not-a-uuid"), c("ok", id.uuidString)], me: me)
        #expect(r.addressable == [id: "ok"] && r.strays == ["none", "junk"])
        // Two of this user's: the newer metadata is addressable, the older a stray (either order); a tie keeps the first.
        r = ManagerClassifier.classify([c("old", id.uuidString, rev: 3), c("new", id.uuidString, rev: 5)], me: me)
        #expect(r.addressable == [id: "new"] && r.strays == ["old"])
        r = ManagerClassifier.classify([c("new", id.uuidString, rev: 5), c("old", id.uuidString, rev: 3)], me: me)
        #expect(r.addressable == [id: "new"] && r.strays == ["old"])
        r = ManagerClassifier.classify([c("first", id.uuidString), c("second", id.uuidString)], me: me)
        #expect(r.addressable == [id: "first"] && r.strays == ["second"])
        // An own duplicate whose metadata can't be read counts as the oldest.
        r = ManagerClassifier.classify([c("unparsed", id.uuidString, rev: nil), c("parsed", id.uuidString, rev: 1)], me: me)
        #expect(r.addressable == [id: "parsed"] && r.strays == ["unparsed"])
        // L2: a duplicate that isn't wholly this user's is a stray too, never dropped from both lists.
        r = ManagerClassifier.classify([c("mine", id.uuidString), c("theirs", id.uuidString, owner: other, rev: 9)], me: me)
        #expect(r.addressable == [id: "mine"] && r.strays == ["theirs"])
        r = ManagerClassifier.classify([c("theirs", id.uuidString, owner: other), c("mine", id.uuidString, rev: 9)], me: me)
        #expect(r.addressable == [id: "theirs"] && r.strays == ["mine"])
        r = ManagerClassifier.classify([c("a", id.uuidString, owner: nil), c("b", id.uuidString, owner: nil)], me: me)
        #expect(r.addressable == [id: "a"] && r.strays == ["b"])
        // Different profile IDs never collide.
        r = ManagerClassifier.classify([c("x", id.uuidString), c("y", id2.uuidString)], me: me)
        #expect(r.addressable == [id: "x", id2: "y"] && r.strays.isEmpty)
    }

    /// The owner of a configuration is readable when the rest of its dictionary isn't (the stray's owner fallback).
    @Test func theOwnerIsReadableFromAnUnparsableDictionary() {
        let d: [String: Any] = ["ownerUID": NSNumber(value: 7)]
        #expect(ProviderConfigurationValues.stored(d) == nil)
        #expect(ProviderConfigurationValues.ownerUID(d) == 7)
        #expect(ProviderConfigurationValues.ownerUID(["v": 1]) == nil)
        #expect(ProviderConfigurationValues.ownerUID(nil) == nil)
        #expect(ProviderConfigurationValues.stored(["v": 1, "revision": NSNumber(value: 2), "metaRev": NSNumber(value: 3), "ownerUID": NSNumber(value: 7)])
                == .init(revision: 2, metaRev: 3, ownerUID: 7))
    }

    // MARK: Update install before the settings were read (review L3)

    @Test func anUpdateIsRefusedUntilTheSettingsWereRead() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let saved = try writeSettings(dir)
        let store = SettingsStore(files: SettingsFileStore(dir: dir.data), loadedFromDisk: false)
        let c = UpdateCoordinator(settings: store, extensionStore: { nil }, currentBuild: "41")
        #expect(c.refusalReason == "LockPlus is still starting. Try again in a moment.")
        c.prepareForInstall(toVersion: "42")                                // logged; nothing written over the file
        await store.flush()
        #expect(AtomicFile.loadJSON(AppSettings.self, from: dir.data.settings) == saved)
        store.replaceAll(saved)
        #expect(c.refusalReason == nil)
    }

    // MARK: Import after a failed update (review L5)

    @Test func anImportAfterAFailedUpdateSaysItCantConnectYet() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.env.importer.onImported?(p.id)
        #expect(!h.env.profiles.problems.contains { $0.message.contains("can't connect yet") })
        h.ext.state = .updateFailed(installed: "2.0.0 (200005)", code: 8)
        h.env.importer.onImported?(p.id)
        #expect(h.env.profiles.problems.last?.message == "LockPlus couldn't update its tunnel component, so \(p.name) can't connect yet. Profiles set up before the update still connect.")
    }

    // MARK: Settings decode per field (review L6)

    /// One field of an unexpected type costs that field, not every setting.
    @Test func aTypeMismatchInOneSettingsFieldKeepsTheOthers() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        try AtomicFile.ensureDirectory(dir.url)
        let id = UUID()
        let json = """
        {"onboardingComplete": true, "language": 5, "launches": "x", "lastUsedProfileID": "\(id.uuidString)",
         "autoConnect": {"enabled": true, "trustedSSIDs": 3, "pausedUntil": "not a date"}, "onDemandPausedByStart": {"a": 1}}
        """
        try Data(json.utf8).write(to: dir.data.settings)
        let r = await SettingsFileStore(dir: dir.data).loadSettingsChecked(retryDelay: .zero)
        #expect(r.problem == nil && r.movedAside == nil)
        #expect(r.settings.onboardingComplete)
        #expect(r.settings.lastUsedProfileID == id)
        #expect(r.settings.language == .system)
        #expect(r.settings.launches.isEmpty)
        #expect(r.settings.autoConnect.enabled && r.settings.autoConnect.trustedSSIDs.isEmpty && r.settings.autoConnect.pausedUntil == nil)
        #expect(r.settings.onDemandPausedByStart.isEmpty)
    }

    /// A moved-aside file that mentioned Auto-Connect (or a pause) says it is off now; one that didn't says nothing.
    @Test func aResetThatDropsAutoConnectSaysSo() async throws {
        for (text, mentions) in [("{\"autoConnect\": {\"pausedUntil\": \"2026-", true), ("{\"onboardingComplete\": tru", false)] {
            let dir = TestDir()
            defer { dir.cleanup() }
            try AtomicFile.ensureDirectory(dir.url)
            try Data(text.utf8).write(to: dir.data.settings)
            let h = Harness(dir: dir, settingsWritableBeforeLoad: false)
            let problem = await h.env.loadSettingsAtLaunch()
            #expect(problem?.mayHaveHeldAutoConnect == mentions)
            h.env.noteSettingsProblem(problem)
            #expect(h.env.profiles.problems.contains { $0.message == "Auto-connect is off after this reset; turn it on again in Settings." } == mentions)
        }
    }

    // MARK: Restore at `.disconnecting` (200008, 6/6 on 26 and 27)

    var pluginFailed: NSError { NSError(domain: NEVPNConnectionErrorDomain, code: 12) }

    /// The VM sequence: Work (kill switch, no on-demand rules) runs with the auto profile paused; its tunnel process is
    /// killed. NE reports `.disconnecting` (~5 s after the kill), `.disconnected` (~1.4 s later) and restarts the
    /// session itself (`.connecting` ~1 s later). Nothing turns the auto profile's on-demand back on at any of these
    /// steps (200008 restored it 12 ms after `.disconnecting`: `.disconnecting` was not busy, no entry existed yet), nor
    /// while the restarted session runs; it returns only when that session ends. `restoring` is set synchronously by the
    /// status handler, so each check right after an `emit` is exact (no window).
    @Test func aCrashedKillSwitchSessionsTeardownRestoresNothing() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper                    // no store timer runs on real time
        await connected(h, work)
        #expect(h.managers.onDemandChanges[auto.id] == [false])
        h.service.state.withLock { $0.linkInterruptedAt = Date() }      // the kill: the XPC link drops at once
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnecting)                        // no user stop
        #expect(!h.env.connection.restoring)
        #expect(h.env.connection.isBusy)
        #expect(h.env.connection.holdsBackOnDemand(of: auto.id))
        #expect(h.env.connection.busyReason == .profile(work.id))
        #expect(h.env.connection.startHold == ConnectionStore.StartHold(profile: work.id, reason: .readingDisconnect))
        h.managers.emit(work.id, .disconnected)
        #expect(!h.env.connection.restoring)
        #expect(await eventually { h.env.connection.startHold?.reason == .awaitingRestart })   // the crash decision
        #expect(!h.env.connection.restoring)
        #expect(await eventually { timers.armed.contains(h.env.connection.systemRestartTimeout) })
        h.managers.emit(work.id, .connecting)                           // NE's own restart
        #expect(!h.env.connection.restoring)
        h.managers.emit(work.id, .connected)
        #expect(!h.env.connection.restoring)
        #expect(h.env.connection.startHold == nil)
        #expect(h.managers.onDemandChanges[auto.id] == [false])         // zero changes since the pause
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(h.env.settings.value.onDemandPausedByStart == [auto.id])
        h.env.connection.disconnect()                                   // the restarted session ends normally
        #expect(await eventually { h.managers.stops == [work.id] })
        h.managers.emit(work.id, .disconnecting)
        #expect(!h.env.connection.restoring)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.onDemandChanges[auto.id] == [false, true])
        #expect(h.managers.starts.count == 1)                           // no app restart (NE's own)
    }

    /// nb2 showed the same at a user's Disconnect (od TRUE 30 ms after `.disconnecting`): the session ends at
    /// `.disconnected`, so the restore runs there, not inside the teardown.
    @Test func aUserStopRestoresAtDisconnectedNotAtDisconnecting() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.env.connection.disconnect()
        #expect(await eventually { h.managers.stops == [work.id] })
        h.managers.emit(work.id, .disconnecting)
        #expect(!h.env.connection.restoring)
        #expect(h.env.connection.isBusy)
        #expect(h.env.connection.startHold == nil)                      // the user's stop: no entry
        #expect(h.managers.onDemandChanges[auto.id] == [false])
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.onDemandChanges[auto.id] == [false, true])
    }

    /// Every busy path counts a teardown: `load()` (the `NEVPNConfigurationChange` reload) defers a heal while another
    /// configuration is `.disconnecting`, and runs it when that session has ended.
    @Test func aReloadDuringATeardownDefersItsMutations() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.env.connection.disconnect()
        #expect(await eventually { h.managers.stops == [work.id] })
        h.managers.emit(work.id, .disconnecting)
        #expect(h.env.connection.mutationBlocked(auto.id))
        h.managers.entries[auto.id]?.cfg.flags.excludeAPNs.toggle()      // a drift the reload would heal
        try await h.env.managers.loadAll()                              // the app reads a snapshot taken at the load
        h.managers.log = []
        await h.env.profiles.load()
        #expect(saves(h) == 0)
        #expect(h.env.profiles.hasDeferredSync)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { saves(h, of: auto) > 0 && !h.env.profiles.hasDeferredSync })
    }

    /// Connect of another profile while Work is `.disconnecting` after the user's Disconnect: it waits for Work's
    /// `.disconnected` (no prepare, pause or start inside the teardown), then starts with the auto profile off.
    @Test func aConnectOfAnotherProfileWhileOneStopsWaitsForTheStop() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let other = try await h.add("Other.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        await connected(h, work)
        h.env.connection.disconnect()
        #expect(await eventually { h.managers.stops == [work.id] })
        h.managers.emit(work.id, .disconnecting)
        h.managers.log = []
        #expect(h.env.connection.connect(other.id))
        #expect(h.env.connection.startHold == ConnectionStore.StartHold(profile: other.id, reason: .waitingForStop(of: work.id)))
        #expect(await never { h.managers.starts.count > 1 || saves(h) > 0 })
        #expect(!h.env.connection.restoring)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.starts.count == 2 })
        #expect(h.managers.starts.last?.0 == other.id)
        #expect(h.managers.onDemandAtStart.last?.contains(auto.id) == false)
        #expect(h.managers.onDemandChanges[auto.id] == [false])
    }

    /// Connect during a crashed session's teardown: another profile's Connect is ignored (its prepare and pause would
    /// save managers inside NE's pending restart) and its Connect is held in the UI; the same profile's Connect takes
    /// the teardown over and starts at `.disconnected` (N1b).
    @Test func aConnectDuringACrashedTeardown() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let other = try await h.add("Other.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        await connected(h, work)
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnecting)
        h.managers.log = []
        #expect(!h.env.connection.connect(other.id))
        #expect(h.env.connection.connectHold(for: other.id) != nil)
        #expect(h.env.connection.connectHold(for: work.id) != nil)       // review e321e10 LOW 2: NE may restart it
        #expect(h.env.connection.connect(work.id))                      // the store still takes it (N1b)
        #expect(h.env.connection.startHold == ConnectionStore.StartHold(profile: work.id, reason: .waitingForStop(of: work.id)))
        #expect(await never { h.managers.starts.count > 1 || saves(h) > 0 })
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.starts.count == 2 })
        #expect(h.managers.starts.last?.0 == work.id)
        #expect(h.managers.onDemandChanges[auto.id] == [false])
    }

    /// U10's no-live-link branch: the crash happened while the XPC link was down, so the 12 reads as sticky (no fresh
    /// crash). Work has the kill switch and no on-demand rules, so NE restarts it itself: the app waits for that restart
    /// like for a seen crash (no restore at `.disconnected`), and restores only after the fallback with Work still down.
    @Test func aCrashWithoutALiveLinkStillWaitsForNEsRestart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        await connected(h, work)
        h.service.state.withLock { $0.linkInterruptedAt = nil }        // no interruption seen
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.env.connection.startHold?.reason == .mayRestart })   // hedged (review e321e10)
        #expect(!h.env.connection.restoring)
        #expect(h.managers.onDemandChanges[auto.id] == [false])
        await timers.fire(h.env.connection.systemRestartTimeout)       // NE's restart never came
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.onDemandChanges[auto.id] == [false, true])
        #expect(h.managers.starts.count == 1)
    }

    // MARK: Review e321e10

    /// HIGH: Delete of the connected profile. The stop is a user stop through the connection store (no teardown entry,
    /// no error fetch), and NE never delivers the `.disconnected` (the configuration is removed meanwhile). After the
    /// bounded wait the removal reports `.invalid`: the session has ended, nothing is busy, the auto profile returns.
    @Test func deletingAConnectedProfileWhoseEndIsNeverReportedEndsItsSession() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.removalStopTimeout = .seconds(9)
        await connected(h, work)
        h.managers.stopReport = .reports(nil)                           // `.disconnecting`, then nothing
        let deletion = Task { await h.env.profiles.delete(work.id) }
        #expect(await eventually { h.env.connection.statuses[work.id] == .disconnecting })
        #expect(h.env.connection.startHold == nil)                      // a user stop: no teardown entry
        #expect(!h.env.connection.restoring)
        #expect(h.managers.removed.isEmpty)                             // the removal waits for the end
        await timers.fire(.seconds(9))
        await deletion.value
        #expect(h.managers.removed == [work.id])
        #expect(h.env.connection.statuses[work.id] == nil)
        #expect(!h.env.connection.isBusy)
        #expect(h.env.connection.busyReason == nil)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.fetchCount == 0)
    }

    /// HIGH, the ordinary case: the removal follows the session's `.disconnected` (nothing lost), and the stop is the
    /// user's (no "stopped unexpectedly", no fetch).
    @Test func deletingAConnectedProfileRemovesAfterItsEnd() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        var notices: [ConnectionNotice] = []
        h.env.connection.onNotice = { notices.append($0) }
        h.managers.stopReport = .reports(.disconnected)
        await h.env.profiles.delete(work.id)
        #expect(h.managers.removed == [work.id])
        #expect(h.managers.fetchCount == 0)
        #expect(!notices.contains(.stoppedUnexpectedly(work.id)))
        #expect(!h.env.connection.isBusy)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// LOW 3: `.disconnecting` → `.invalid` with the manager still present ends the session (no stale teardown hold).
    @Test func invalidAfterDisconnectingEndsTheSession() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.managers.emit(work.id, .disconnecting)                        // NE stops it (no user stop)
        #expect(h.env.connection.startHold?.reason == .readingDisconnect)
        h.managers.emit(work.id, .invalid)
        #expect(h.env.connection.startHold == nil)
        #expect(!h.env.connection.isBusy)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.fetchCount == 0)
    }

    /// Test gap: an unwatched session's `.disconnecting` (another user's) is busy by its status alone, with no entry.
    @Test func anotherUsersTeardownIsBusyWithoutAnEntry() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        let theirs = otherUsersManager(h, like: work, status: .disconnecting)
        try await h.env.managers.loadAll()
        #expect(h.env.connection.isBusy)
        #expect(h.env.connection.startHold == nil)
        #expect(h.env.connection.busyReason == .anotherUser)
        h.managers.emit(theirs, .disconnected)
        #expect(!h.env.connection.isBusy)
    }

    /// Test gap: the teardown entry's timer ends the entry only; the status still holds the restore until the
    /// `.disconnected`, which is then read as usual.
    @Test func theTeardownTimerEndsOnlyTheEntry() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.stopTimeout = .seconds(22)
        await connected(h, work)
        h.managers.emit(work.id, .disconnecting)
        #expect(h.env.connection.startHold?.reason == .readingDisconnect)
        await timers.fire(.seconds(22))
        #expect(await eventually { h.env.connection.startHold == nil })
        #expect(h.env.connection.isBusy)
        #expect(!h.env.connection.restoring)
        #expect(h.managers.onDemandChanges[auto.id] == [false])
        h.managers.emit(work.id, .disconnected)                         // no error: no crash
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.managers.fetchCount == 1)
    }

    /// Test gap: the U10 wait ends at NE's `.connecting` (no restore while the restarted session runs; it reads as a
    /// restart after a crash), and Cancel ends a hedged wait.
    @Test func theNoLinkWaitEndsAtNEsRestartOrCancel() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        await connected(h, work)
        h.service.state.withLock { $0.linkInterruptedAt = nil }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.env.connection.startHold?.reason == .mayRestart })
        h.managers.emit(work.id, .connecting)                           // NE's own restart
        #expect(h.env.connection.startHold == nil)
        #expect(!h.env.connection.restoring)
        h.managers.emit(work.id, .connected)
        #expect(h.env.connection.restartedAfterCrash == work.id)
        #expect(h.managers.onDemandChanges[auto.id] == [false])
        // Again, and this time the user cancels the wait.
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.env.connection.startHold?.reason == .mayRestart })
        h.env.connection.disconnect()
        #expect(h.env.connection.startHold == nil)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// Test gap, negative: with on-demand rules NE doesn't restart it, so a sticky 12 without a seen interruption is no
    /// wait; the restore runs and the app restarts nothing (no fresh crash).
    @Test func theNoLinkWaitNeedsAProfileWithoutRules() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        h.managers.entries[work.id]?.onDemand = true
        h.service.state.withLock { $0.linkInterruptedAt = nil }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        #expect(h.env.connection.startHold == nil)
        #expect(h.managers.starts.count == 1)
    }

    /// Test gap: the extension update's quiesce stops as the user (no teardown entry, no error fetch, no crash wait).
    @Test func theQuiesceStopIsAUserStop() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await connected(h, work)
        h.managers.lastError = pluginFailed                             // a sticky 12 from an earlier crash
        h.managers.stopReport = .reports(.disconnected)
        var holds: [ConnectionStore.StartHold?] = []
        h.env.connection.onStatusForDiagnostics = { [weak c = h.env.connection] _, _ in holds.append(c?.startHold) }
        let q = ManagerQuiescer()
        q.attach(managers: h.env.managers, settings: h.env.settings, connection: h.env.connection)
        await q.quiesce(reason: .extensionUpdate)
        #expect(h.managers.stops == [work.id])
        #expect(await eventually { h.env.connection.statuses[work.id] == .disconnected })
        #expect(holds.allSatisfy { $0 == nil })
        #expect(h.managers.fetchCount == 0)
    }

    // MARK: Review 385b6ea

    func serialized(_ h: Harness) throws -> SerializedVPNManager { try #require(h.env.managers as? SerializedVPNManager) }

    /// L-A: ONE load that misses a live manager (a partial list) ends nothing: status, busy and the restore hold stay,
    /// and a manager that is back in the next load was never gone.
    @Test func aReloadThatMissesALiveManagerOnceEndsNothing() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        try serialized(h).confirmSleep = FakeTimers().sleeper              // the confirming reload is released by hand
        await connected(h, work)
        var ended: [UUID] = []
        h.env.connection.onObservedDisconnect = { id, _ in ended.append(id) }
        let kept = try #require(h.managers.entries[work.id])
        h.managers.entries[work.id] = nil
        try await h.env.managers.loadAll()                              // the partial list
        h.env.connection.configurationChanged()
        #expect(h.env.connection.statuses[work.id] == .connected)
        #expect(h.env.connection.isBusy)
        #expect(await never { h.managers.entries[auto.id]?.onDemand == true })
        h.managers.entries[work.id] = kept                              // the next load has it again
        try await h.env.managers.loadAll()
        try await h.env.managers.loadAll()
        #expect(h.env.connection.statuses[work.id] == .connected)
        #expect(ended.isEmpty)
        #expect(h.managers.onDemandChanges[auto.id] == [false])
    }

    /// Test gap (a), L-A, L-C: a configuration removed from outside (System Settings) while its session is live ends
    /// when the SECOND load agrees, through the one end path (`onObservedDisconnect`, connected-since, crash flag).
    @Test func aConfigurationRemovedFromOutsideEndsItsSessionAtTheSecondLoad() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        try serialized(h).confirmSleep = FakeTimers().sleeper
        await connected(h, work)
        var ended: [(UUID, LPErrorCode?)] = []
        h.env.connection.onObservedDisconnect = { ended.append(($0, $1)) }
        #expect(h.env.connection.connectedSince != nil)
        h.managers.entries[work.id] = nil
        try await h.env.managers.loadAll()
        #expect(h.env.connection.isBusy)
        #expect(ended.isEmpty)
        try await h.env.managers.loadAll()
        #expect(h.env.connection.statuses[work.id] == nil)
        #expect(!h.env.connection.isBusy)
        #expect(ended.count == 1 && ended[0].0 == work.id && ended[0].1 == nil)
        #expect(h.env.connection.connectedSince == nil)
        #expect(h.env.connection.restartedAfterCrash == nil)
        #expect(h.managers.fetchCount == 0)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// L-A: nobody may reload again soon, so the first miss schedules the confirming reload itself.
    @Test func theFirstMissSchedulesTheConfirmingReload() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        try serialized(h).confirmSleep = timers.sleeper
        await connected(h, work)
        h.managers.entries[work.id] = nil
        try await h.env.managers.loadAll()
        #expect(h.env.connection.isBusy)
        let delay = try serialized(h).confirmDelay
        await timers.fire(delay)
        #expect(await eventually { h.env.connection.statuses[work.id] == nil })
        #expect(!h.env.connection.isBusy)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// Test gap (b): while a Delete waits for its session to end, nothing is restored.
    @Test func nothingIsRestoredWhileADeleteWaitsForTheEnd() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.removalStopTimeout = .seconds(9)
        await connected(h, work)
        h.managers.stopReport = .reports(nil)
        let deletion = Task { await h.env.profiles.delete(work.id) }
        #expect(await eventually { h.env.connection.statuses[work.id] == .disconnecting })
        #expect(await never { h.managers.entries[auto.id]?.onDemand == true || h.managers.removed.contains(work.id) })
        await timers.fire(.seconds(9))
        await deletion.value
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// L-B: `.invalid` for a live session whose manager still exists is no end: the status and the session stay, the
    /// following `.connected` is no new session (no second notice, no end reported), nothing is restored.
    @Test func invalidOfALiveSessionWithItsManagerPresentIsNotAnEnd() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, work)
        var notices: [ConnectionNotice] = []
        var ended: [UUID] = []
        h.env.connection.onNotice = { notices.append($0) }
        h.env.connection.onObservedDisconnect = { id, _ in ended.append(id) }
        h.managers.emit(work.id, .invalid)
        #expect(h.env.connection.statuses[work.id] == .connected)
        #expect(h.env.connection.isBusy)
        h.managers.emit(work.id, .connected)
        #expect(notices.isEmpty)
        #expect(ended.isEmpty)
        #expect(await never { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// L-D: a Delete of a profile whose start waits for another profile's stop ends that start; the old session's end
    /// no longer starts the deleted profile.
    @Test func deletingAProfileWhoseStartWaitsForAStopEndsTheStart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        await connected(h, auto)
        h.managers.stopReport = .reports(nil)                           // auto's stop never ends by itself
        h.env.connection.connect(work.id)
        #expect(await eventually { h.env.connection.startHold == ConnectionStore.StartHold(profile: work.id, reason: .waitingForStop(of: auto.id)) })
        #expect(await eventually { h.managers.stops == [auto.id] })
        h.managers.stopReport = .silent
        await h.env.profiles.delete(work.id)
        #expect(h.env.connection.startHold == nil || h.env.connection.startHold?.profile != work.id)
        h.managers.emit(auto.id, .disconnected)
        #expect(await never { h.managers.starts.count > 1 })
        #expect(h.managers.starts.map(\.0) == [auto.id])
    }

    /// L-E (test gap d): NE's restart lands after the user's Cancel of the `.mayRestart` wait: it is stopped again.
    @Test func aRestartThatLandsAfterCancelIsStoppedAgain() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await connected(h, work)
        h.service.state.withLock { $0.linkInterruptedAt = nil }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.env.connection.startHold?.reason == .mayRestart })
        h.env.connection.disconnect()
        #expect(await eventually { h.managers.stops == [work.id] })
        h.managers.emit(work.id, .connecting)                           // NE's own restart
        #expect(await eventually { h.managers.stops == [work.id, work.id] })
    }

    /// L-E, negative: the user's own Connect right after a Disconnect has its entry and is not stopped.
    @Test func aConnectRightAfterADisconnectIsNotStopped() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await connected(h, work)
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.env.connection.startHold == nil })
        h.env.connection.disconnect()                                   // already down: no transition follows
        #expect(await eventually { h.managers.stops == [work.id] })
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 2 })
        h.managers.emit(work.id, .connecting)
        h.managers.emit(work.id, .connected)
        #expect(await never { h.managers.stops.count > 1 })
    }

    /// L-F: a user stop during NE's own `.disconnecting` ends the teardown hold at the stop's `.disconnected`, not at
    /// its 22 s timer.
    @Test func aUserStopDuringATeardownEndsItsHoldAtTheEnd() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        await connected(h, work)
        h.managers.emit(work.id, .disconnecting)                        // NE stops it: the teardown hold
        #expect(h.env.connection.startHold?.reason == .readingDisconnect)
        h.env.connection.disconnect()                                   // the user stops it too
        h.managers.emit(work.id, .disconnected)
        #expect(h.env.connection.startHold == nil)
        #expect(h.managers.fetchCount == 0)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    // MARK: 200009: a kill-switch session killed while `.connecting`

    /// The 200009 VM run (26, U10 early variant): the extension was killed 0.17 s after the app's hello, with the session
    /// `.connecting`. NE restarts a kill-switch session without on-demand rules that dies before `.connected` too, so
    /// the restore waits for that restart (before: it ran at `.disconnected`, and NE's restart ran beside it).
    /// `ours`: the app issued the start; otherwise a session NE or the system started (the paused record is set by hand).
    func killedWhileConnecting(ours: Bool, error: NSError?, restartAt: Bool) async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        if ours {
            h.env.connection.connect(work.id)
            #expect(await eventually { h.managers.starts.count == 1 })
        } else {
            h.managers.entries[auto.id]?.onDemand = false
            h.env.settings.update { $0.onDemandPausedByStart = [auto.id] }
        }
        h.managers.emit(work.id, .connecting)                           // never reaches `.connected`
        #expect(h.managers.onDemandChanges[auto.id] ?? [] == (ours ? [false] : []))
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = error
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.env.connection.startHold?.reason == .mayRestart })
        #expect(!h.env.connection.restoring)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        if restartAt {
            h.managers.emit(work.id, .connecting)                       // NE's restart, 1 s later
            #expect(h.env.connection.startHold == nil)
            #expect(await never { h.env.connection.restoring })
            h.managers.emit(work.id, .connected)
            #expect(await never { h.env.connection.restoring })
            #expect(h.managers.entries[auto.id]?.onDemand == false)     // no on-demand change beside the session
            #expect(h.managers.starts.count == (ours ? 1 : 0))          // no app restart (NE's own)
            h.env.connection.disconnect()                               // it ends normally: the restore follows
            #expect(await eventually { h.managers.stops == [work.id] })
            h.managers.emit(work.id, .disconnecting)
            h.managers.emit(work.id, .disconnected)
            #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
        } else {
            await timers.fire(h.env.connection.systemRestartTimeout)    // NE's restart never came
            #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
            #expect(h.env.connection.startHold == nil)
            #expect(h.managers.starts.count == (ours ? 1 : 0))
        }
    }

    @Test func ourOwnStartKilledWhileConnectingWaitsForNEsRestart() async throws {
        try await killedWhileConnecting(ours: true, error: pluginFailed, restartAt: true)
    }

    @Test func aForeignSessionKilledWhileConnectingWaitsForNEsRestart() async throws {
        try await killedWhileConnecting(ours: false, error: pluginFailed, restartAt: true)
    }

    @Test func aKilledConnectingSessionWithoutAnErrorWaitsToo() async throws {
        try await killedWhileConnecting(ours: true, error: nil, restartAt: true)
    }

    @Test func noRestartAfterAConnectingKillRestoresAfterTheFallback() async throws {
        try await killedWhileConnecting(ours: true, error: pluginFailed, restartAt: false)
    }

    @Test func noRestartAfterAForeignConnectingKillRestoresAfterTheFallback() async throws {
        try await killedWhileConnecting(ours: false, error: pluginFailed, restartAt: false)
    }

    /// The issued start's own entry dies without any active status ever read (`.disconnected` only): the start failure
    /// path holds the restore for NE's restart too, and the fallback restores.
    @Test func anIssuedStartThatEndsWithoutAnActiveStatusHoldsForNEsRestart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .disconnected)
        #expect(h.env.connection.startHold?.reason == .startEndedEarly)   // L-3 copy: not "stopped unexpectedly"
        #expect(!h.env.connection.restoring)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        h.managers.emit(work.id, .connecting)                           // NE's restart
        #expect(h.env.connection.startHold == nil)
        #expect(await never { h.env.connection.restoring })
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        h.managers.emit(work.id, .connected)
        h.env.connection.disconnect()                                   // a later normal end restores
        #expect(await eventually { h.managers.stops == [work.id] })
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// Negative: a user stop while `.connecting` (Cancel) is not held (the on-demand-rules negative is its own test below).
    @Test func aUserStopWhileConnectingIsNotHeld() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .connecting)
        h.env.connection.disconnect()
        #expect(await eventually { h.managers.stops == [work.id] })
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(h.env.connection.startHold == nil)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    // MARK: Review 5c3a899/f18c0d6

    /// M-1 (test gap c): a Delete while the profile's OWN prepare is in flight (its manager saved, the prepare parked
    /// inside its verifying reload) must end that start, not let it re-create the configuration (with on-demand on, for
    /// the auto profile) after the removal. Before: the removal ran at once, then the prepare's reload re-saved the manager.
    /// Deterministic: the reload is held by `loadGate` until the Delete has begun.
    @Test func deletingAProfileDuringItsOwnPrepareLeavesNoConfiguration() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = work.id }
        h.managers.entries[work.id] = nil                               // behind: the prepare saves it, then reloads
        let (stream, release) = AsyncStream<Void>.makeStream()
        var parked = false
        h.managers.loadGate = { parked = true; for await _ in stream { break } }
        h.env.connection.connect(work.id)
        #expect(await eventually { parked })                            // the prepare is inside its reload
        #expect(saves(h, of: work) == 1)
        let deletion = Task { await h.env.profiles.delete(work.id) }
        #expect(await eventually { h.env.settings.value.autoConnect.profileID == nil })   // the Delete has begun
        release.yield()
        await deletion.value
        #expect(await never { h.managers.entries[work.id] != nil })
        #expect(saves(h, of: work) == 1)
        #expect(h.managers.starts.isEmpty)
        #expect(h.env.connection.startHold == nil)
    }

    /// Review b061b46-d4feb3a LOW-1: a Delete that begins inside the start's own save (no manager yet, so the first
    /// on-demand-off check skips) must still turn the on-demand that save lands OFF before the removal.
    @Test func aDeleteInsideTheStartsSaveTurnsOnDemandOffBeforeTheRemoval() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = work.id }
        h.managers.entries[work.id] = nil
        var deletion: Task<Void, Never>?
        h.managers.onSave = { [h] id in
            guard id == work.id, deletion == nil else { return }
            deletion = Task { await h.env.profiles.delete(work.id) }
        }
        h.env.connection.connect(work.id)
        #expect(await eventually { deletion != nil })
        await deletion?.value
        #expect(h.managers.onDemandChanges[work.id] == [false])         // the save landed ON, then off before the removal
        #expect(h.managers.removed.contains(work.id))
        #expect(h.managers.entries[work.id] == nil)
        #expect(await never { h.managers.entries[work.id] != nil })
    }

    /// Review b061b46-d4feb3a LOW-2: while a Delete is under way no save site re-creates the configuration
    /// (`resaveOnDemand`, `saveOnDemand`, `saveManagerUnlessBlocked`).
    @Test func noSaveSiteRecreatesAConfigurationWhileItsProfileIsBeingDeleted() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        let (stream, release) = AsyncStream<Void>.makeStream()
        var inside = false
        h.env.profiles.stopSessionBeforeRemoval = { _ in inside = true; for await _ in stream { break } }
        let deletion = Task { await h.env.profiles.delete(work.id) }
        #expect(await eventually { inside })
        h.managers.entries[work.id] = nil                               // the removal landed
        h.managers.log = []
        await h.env.profiles.resaveOnDemand()
        await #expect(throws: LPError.self) { try await h.env.profiles.saveOnDemand(work) }
        await #expect(throws: LPError.self) { _ = try await h.env.profiles.saveManagerUnlessBlocked(work) }
        #expect(saves(h, of: work) == 0)
        #expect(h.managers.entries[work.id] == nil)
        release.yield()
        await deletion.value
    }

    /// Review b061b46-d4feb3a LOW-3: an issued start whose manager vanished before any status ends with it, not at the
    /// 30 s `startingTimeout`.
    @Test func anIssuedStartWhoseManagerIsGoneEndsAtOnce() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.env.connection.startHold?.profile == work.id)
        h.managers.entries[work.id] = nil
        try await h.env.managers.loadAll()                              // the snapshot without it
        h.env.connection.configurationChanged()
        #expect(h.env.connection.startHold == nil)
    }

    /// M-1: nothing re-creates the configuration of a profile that is gone.
    @Test func prepareForStartOfADeletedProfileThrowsAndSavesNothing() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await h.env.profiles.delete(work.id)
        h.managers.log = []
        await #expect(throws: LPError.self) { try await h.env.profiles.prepareForStart(work) }
        #expect(saves(h) == 0)
        #expect(h.managers.entries[work.id] == nil)
    }

    /// L-1 (test gap d): the user's Cancel of the `.mayRestart` wait, then an on-demand start the app itself re-enabled
    /// lands within 2 s: no second stop (it would loop with the on-demand).
    @Test func aRestartWithOnDemandOnAfterCancelIsNotStoppedAgain() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        await connected(h, work)
        h.service.state.withLock { $0.linkInterruptedAt = nil }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.env.connection.startHold?.reason == .mayRestart })
        h.env.connection.disconnect()
        #expect(await eventually { h.managers.stops == [work.id] })
        h.managers.entries[work.id]?.onDemand = true                    // the restore turned on-demand on again
        h.managers.emit(work.id, .connecting)                           // its on-demand start
        #expect(await never { h.managers.stops.count > 1 })
    }

    /// L-2 (test gap e): a confirming reload that throws is rescheduled, and the gone manager's session then ends.
    @Test func aFailedConfirmingReloadIsRescheduled() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        let timers = FakeTimers()
        try serialized(h).confirmSleep = timers.sleeper
        await connected(h, work)
        h.managers.entries[work.id] = nil
        try await h.env.managers.loadAll()                              // the first miss schedules the confirming reload
        let delay = try serialized(h).confirmDelay
        h.managers.loadError = LPError(.extensionUnavailable, detail: "load failed")
        let before = h.managers.loads
        await timers.fire(delay)
        #expect(await eventually { h.managers.loads == before + 1 })    // it ran and threw
        #expect(h.env.connection.isBusy)
        h.managers.loadError = nil
        await timers.fire(delay)                                        // rescheduled
        #expect(await eventually { h.env.connection.statuses[work.id] == nil })
        #expect(!h.env.connection.isBusy)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// L-2: bounded: a reload that keeps failing is tried `maxConfirmRetries` times in all, then left.
    @Test func aConfirmingReloadThatKeepsFailingIsBounded() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        let timers = FakeTimers()
        try serialized(h).confirmSleep = timers.sleeper
        await connected(h, work)
        h.managers.entries[work.id] = nil
        try await h.env.managers.loadAll()
        let delay = try serialized(h).confirmDelay
        h.managers.loadError = LPError(.extensionUnavailable, detail: "load failed")
        for round in 1...SerializedVPNManager.maxConfirmRetries {
            let before = h.managers.loads
            await timers.fire(delay)
            #expect(await eventually { h.managers.loads == before + 1 }, "attempt \(round)")
        }
        #expect(await never { !timers.armed.isEmpty })
    }

    /// L-3: an issued start that ends with no status read is held, but it is no recorded crash: our own `.connected`
    /// afterwards is a normal connect, not "reconnected after a tunnel process restart".
    @Test func anIssuedStartEndedHoldIsNoCrashAndClaimsNoRestart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        var notices: [ConnectionNotice] = []
        h.env.connection.onNotice = { notices.append($0) }
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .disconnected)                         // the old session's end, replayed
        #expect(h.env.connection.startHold?.reason == .startEndedEarly)
        h.managers.emit(work.id, .connecting)                           // our own start proceeds
        h.managers.emit(work.id, .connected)
        #expect(h.env.connection.restartedAfterCrash == nil)
        #expect(notices == [.connected(work.id)])
    }

    /// Test gap (a), Q3: an error the extension recorded itself (here a connect timeout) at the end of a session that
    /// never connected is its own deliberate end, which NE doesn't restart: no hold.
    @Test func anExtensionRecordedErrorWhileConnectingIsNotHeld() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (auto, work) = try await setUp(h)
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .connecting)
        h.managers.lastError = NSError(domain: LPTunnelError.errorDomain, code: LPErrorCode.connectTimeout.rawValue)
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.fetchCount == 1 })
        #expect(await never { h.env.connection.startHold?.reason == .mayRestart })
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// Test gap (b): a profile whose manager has on-demand rules enabled is restarted by on-demand, not NE's own restart:
    /// its end while `.connecting` is not held.
    @Test func aSessionWithOnDemandRulesEndingWhileConnectingIsNotHeld() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await setUp(h)
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .connecting)
        h.managers.entries[work.id]?.onDemand = true
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = pluginFailed
        h.managers.emit(work.id, .disconnecting)
        h.managers.emit(work.id, .disconnected)
        #expect(await eventually { h.managers.fetchCount == 1 })
        #expect(await never { h.env.connection.startHold?.reason == .mayRestart })
        #expect(h.env.connection.startHold == nil)
    }
}
