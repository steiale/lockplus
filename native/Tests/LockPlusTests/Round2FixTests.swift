import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// 2.0.2 review round 2 (Fable M1, M2, L1–L8, N2, N4): the app side.
@MainActor @Suite(.timeLimit(.minutes(1))) struct Round2FixTests {

    /// The next launch over the same data directory, keychain and NE configurations: settings read from disk, managers
    /// and profiles loaded.
    func relaunch(_ h: Harness) async throws -> Harness {
        await h.env.settings.flush()
        let h2 = Harness(dir: h.dir, managers: h.managers, keychain: h.keychain)
        h2.env.settings.replaceAll(try #require(await h2.env.files?.loadSettingsChecked().settings))
        try await h2.env.managers.loadAll()
        await h2.env.profiles.load()
        return h2
    }

    func editSettingsFile(_ h: Harness, _ change: (inout AppSettings) -> Void) async throws {
        await h.env.profiles.awaitAutoConnectSeal()
        await h.env.settings.flush()                                       // the store's own pending write lands first
        var s = AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings) ?? h.env.settings.value
        change(&s)
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
    }

    // MARK: M1b: the Auto-Connect choice

    /// A choice made in LockPlus survives a relaunch; one written into settings.json by other code gives no plan, is
    /// turned off and said.
    @Test func aForgedAutoConnectChoiceGivesNoPlan() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let nas = try await h.add("Home NAS.conf", Harness.splitConf, killSwitch: false)
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = work.id }
        await h.env.profiles.awaitAutoConnectSeal()
        #expect(h.env.settings.value.autoConnect.choiceTag != nil)
        let genuine = try await relaunch(h)
        #expect(genuine.env.profiles.onDemandPlan(for: work) != nil)
        #expect(genuine.env.settings.value.autoConnect.enabled)
        // Same-user code re-points the choice (keeping the old tag), or drops the tag.
        try await editSettingsFile(genuine) { $0.autoConnect.profileID = nas.id }
        let forged = try await relaunch(h)
        #expect(forged.env.profiles.onDemandPlan(for: nas) == nil)
        #expect(forged.env.profiles.onDemandPlan(for: work) == nil)
        #expect(!forged.env.settings.value.autoConnect.enabled && forged.env.settings.value.autoConnect.profileID == nil)
        #expect(forged.env.profiles.problems.contains { $0.message.contains("changed outside LockPlus") })
        try await editSettingsFile(forged) { $0.autoConnect.enabled = true; $0.autoConnect.profileID = work.id; $0.autoConnect.choiceTag = nil }
        let untagged = try await relaunch(h)
        #expect(untagged.env.profiles.onDemandPlan(for: work) == nil)
    }

    /// A choice made by 2.0.1 (no record of the kind ever sealed on this Mac) is trusted once and sealed: an update
    /// doesn't turn Auto-Connect off.
    @Test func aChoiceFromBefore202IsTrustedOnceAndSealed() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        await h.env.settings.flush()
        try await editSettingsFile(h) { $0.autoConnect.enabled = true; $0.autoConnect.profileID = work.id; $0.autoConnect.choiceTag = nil }
        let h2 = try await relaunch(h)
        #expect(h2.env.profiles.onDemandPlan(for: work) != nil)
        await h2.env.profiles.awaitAutoConnectSeal()
        #expect(h2.env.settings.value.autoConnect.choiceTag != nil)
        // From now on a missing tag is a forgery.
        try await editSettingsFile(h2) { $0.autoConnect.choiceTag = nil }
        let h3 = try await relaunch(h2)
        #expect(h3.env.profiles.onDemandPlan(for: work) == nil)
    }

    /// An unreadable keychain at launch: no plan for the enabled choice, nothing turned off, checked again later.
    @Test func anUnreadableKeychainLeavesTheChoiceUnverifiedNotOff() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = work.id }
        await h.env.profiles.awaitAutoConnectSeal()
        await h.env.settings.flush()
        let h2 = Harness(dir: h.dir, managers: h.managers, keychain: h.keychain)
        h2.env.settings.replaceAll(try #require(await h2.env.files?.loadSettingsChecked().settings))
        h.keychain.failure.withLock { $0 = -25308 }
        await h2.env.profiles.load()
        #expect(h2.env.profiles.autoConnectTrust == .unverified)
        #expect(h2.env.settings.value.autoConnect.enabled)
        h.keychain.failure.withLock { $0 = nil }
        await h2.env.profiles.load()
        #expect(h2.env.profiles.autoConnectTrust == .trusted)
        #expect(h2.env.profiles.onDemandPlan(for: work) != nil)
    }

    // MARK: M1a: the extension update's resume record

    @Test func aForgedPendingResumeStartsNothingAndAGenuineOneVerifies() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let q = ManagerQuiescer()
        q.retrySleep = { _ in }
        q.attach(managers: h.managers, settings: h.env.settings, connection: h.env.connection)
        h.env.connection.start()
        // Forged: a record naming a profile, written by other code (no intent).
        h.env.settings.update { $0.pendingResume = PendingResume(profileID: work.id, onDemandEnabledIDs: [], reason: .extensionUpdate) }
        await q.resumeAfterUpdate()
        #expect(h.managers.starts.isEmpty && h.service.state.withLock { $0.arms.isEmpty })
        #expect(h.env.settings.value.pendingResume == nil)
        #expect(h.env.profiles.problems.contains { $0.message.contains("changed outside LockPlus") })
        // Genuine: the quiesce of a connected profile seals it; a changed profile doesn't verify, and it is one shot.
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .connecting); h.managers.emit(work.id, .connected)
        #expect(await eventually { h.env.connection.statuses[work.id] == .connected })
        await q.quiesce(reason: .extensionUpdate)
        let r = try #require(h.env.settings.value.pendingResume)
        #expect(r.profileID == work.id && r.intent != nil)
        let repo = h.env.profiles.repository
        #expect(await ManagerQuiescer.checkIntent(r, profileID: work.id, repository: repo, sleep: { _ in }) == .valid)
        #expect(await ManagerQuiescer.checkIntent(r, profileID: UUID(), repository: repo, sleep: { _ in }) == .invalid)
        var reinstall = r
        reinstall.reason = .reinstall
        #expect(await ManagerQuiescer.checkIntent(reinstall, profileID: work.id, repository: repo, sleep: { _ in }) == .invalid)
        await repo.consumeRecord(.pendingResume)
        #expect(await ManagerQuiescer.checkIntent(r, profileID: work.id, repository: repo, sleep: { _ in }) == .neverSealed)
    }

    // MARK: L5: the pause record

    /// Extending a pause signs only what that pause stops itself: a record other code wrote is never laundered.
    @Test func extendingAPauseDoesNotLaunderAForgedRecord() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.connection.start()
        h.env.settings.update {
            $0.autoConnect.pausedUntil = ResumeIntent.wholeSeconds(Date().addingTimeInterval(600))
            $0.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1")
        }
        await h.env.connection.pause(minutes: 15)
        #expect(h.env.settings.value.pausedState?.profileID == nil)
        #expect(h.env.settings.value.pausedState?.intent == nil)
    }

    /// Codex r2 #4: an unsigned record naming B with no pause end; the user pauses while A is connected: A is the
    /// target, B never gets an intent or a start.
    @Test func aPlantedRecordWithoutAPauseEndIsNotSigned() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let a = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let b = try await h.add("Home NAS.conf", Harness.splitConf, killSwitch: false)
        h.env.connection.start()
        h.env.settings.update { $0.pausedState = PausedState(profileID: b.id, onDemandEnabledIDs: [], agentBuild: "1") }
        h.env.connection.connect(a.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(a.id, .connecting); h.managers.emit(a.id, .connected)
        #expect(await eventually { h.env.connection.statuses[a.id] == .connected })
        await h.env.connection.pause(minutes: 5)
        let s = h.env.settings.value
        #expect(s.pausedState?.profileID == a.id)
        #expect(await ConnectionStore.checkResumeIntent(s.pausedState, profileID: a.id, until: s.autoConnect.pausedUntil, now: Date(),
                                                        repository: h.env.profiles.repository) == .holds)
        #expect(!h.managers.starts.contains { $0.0 == b.id })
    }

    /// A genuine pause extended keeps its profile and a fresh intent for the new end.
    @Test func extendingAGenuinePauseKeepsItsProfile() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.connection.start()
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .connecting); h.managers.emit(work.id, .connected)
        #expect(await eventually { h.env.connection.statuses[work.id] == .connected })
        await h.env.connection.pause(minutes: 5)
        h.managers.emit(work.id, .disconnected)
        await h.env.connection.pause(minutes: 15)
        let s = h.env.settings.value
        #expect(s.pausedState?.profileID == work.id)
        #expect(await ConnectionStore.checkResumeIntent(s.pausedState, profileID: work.id, until: s.autoConnect.pausedUntil, now: Date(),
                                                        repository: h.env.profiles.repository) == .holds)
    }

    /// A pause whose intent can't be written doesn't happen, and says so.
    @Test func aPauseThatCantSealItsIntentFailsVisibly() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.connection.start()
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .connecting); h.managers.emit(work.id, .connected)
        #expect(await eventually { h.env.connection.statuses[work.id] == .connected })
        h.keychain.failure.withLock { $0 = -25308 }
        await h.env.connection.pause(minutes: 5)
        #expect(h.env.settings.value.autoConnect.pausedUntil == nil && h.env.settings.value.pausedState == nil)
        #expect(h.env.profiles.problems.contains { $0.message.contains("wasn't paused") })
        #expect(h.managers.stops.isEmpty)
    }

    /// The headless agent with the keychain unavailable: nothing changes, the next run retries (never "forged").
    @Test func theAgentRetriesWhenTheKeychainIsUnavailable() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        var s = AppSettings()
        s.autoConnect.pausedUntil = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1",
                                   intent: await resumeIntent(work.id, until: s.autoConnect.pausedUntil!, keychain: h.keychain, dir: h.dir.data))
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        h.keychain.failure.withLock { $0 = -25308 }
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain, service: h.service)
        #expect(r == .keychainUnavailable)
        #expect(h.managers.starts.isEmpty && agent.calls.isEmpty)
        #expect(try #require(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)).pausedState == s.pausedState)
        // Once readable: resumed, and the intent is spent.
        h.keychain.failure.withLock { $0 = nil }
        let again = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain, service: h.service)
        #expect(again == .resumed(restarted: work.id, onDemand: []))
        #expect(await ConnectionStore.checkResumeIntent(s.pausedState, profileID: work.id, until: s.autoConnect.pausedUntil, now: Date(),
                                                        repository: h.env.profiles.repository) == .changedOutside)
    }

    @Test func theResumeNoteNamesTheReason() {
        #expect(ConnectionStore.resumeRefusedNote(.tooOld, name: "W").contains("more than 7 days"))
        #expect(ConnectionStore.resumeRefusedNote(.unavailable, name: "W").contains("keychain"))
        #expect(ConnectionStore.resumeRefusedNote(.olderRecord, name: "W").contains("earlier version"))
        #expect(ConnectionStore.resumeRefusedNote(.changedOutside, name: "W").contains("changed outside"))
    }

    // MARK: L6: kill-switch starts on an extension that can't authorise them

    @Test func noKillSwitchStartOnALegacyExtensionWithoutAnUpdateMarker() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let ks = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.env.connection.start()
        h.service.state.withLock { $0.armError = LPError(.extensionUnavailable); $0.startAuthorisation = false }
        #expect(!h.env.settings.value.extensionHandOver)
        h.env.connection.connect(ks.id)
        #expect(await eventually { h.env.connection.observedError?.code == .versionMismatch })
        #expect(h.managers.starts.isEmpty)
    }

    @Test func theAgentStartsNoKillSwitchSessionOnALegacyExtension() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let ks = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        var s = AppSettings()
        s.autoConnect.pausedUntil = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        s.pausedState = PausedState(profileID: ks.id, onDemandEnabledIDs: [], agentBuild: "1",
                                   intent: await resumeIntent(ks.id, until: s.autoConnect.pausedUntil!, keychain: h.keychain, dir: h.dir.data))
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        h.service.state.withLock { $0.armError = LPError(.extensionUnavailable); $0.startAuthorisation = false }
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain,
                                             service: h.service)
        #expect(r == .resumed(restarted: nil, onDemand: []))
        #expect(h.managers.starts.isEmpty)
    }

    // MARK: L7: open events

    func write(_ h: Harness, _ name: String, _ text: String) throws -> URL {
        let u = h.dir.url.appending(path: name)
        try Data(text.utf8).write(to: u)
        return u
    }

    /// An open event that arrives while the user's own import is being analysed waits for it (and for its sheet).
    @Test func anOpenEventWaitsForTheUsersOwnAnalysis() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let mine = try write(h, "Office.ovpn", PreviewSeed.officeOvpn)
        let theirs = try write(h, "Theirs.conf", Harness.splitConf)
        let importer = h.env.importer
        h.validator.beforeAnswer.withLock { $0 = { @MainActor in
            h.validator.beforeAnswer.withLock { $0 = nil }
            importer.importOpened([theirs])                                 // arrives mid-analysis
            #expect(importer.queuedOpenEvents == 1)
        } }
        importer.importFiles([mine])
        #expect(await eventually { h.env.ui.importer.preview?.fileName == "Office.ovpn" })
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.env.ui.importer.preview?.fileName == "Office.ovpn")       // never replaced
        #expect(importer.queuedOpenEvents == 1)
        importer.cancel()
        #expect(await eventually { h.env.ui.importer.preview?.fileName == "Theirs.conf" })
    }

    /// At most 5 open events wait; more are refused with one message.
    @Test func theOpenQueueIsCapped() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let u = try write(h, "Work.conf", Harness.wgConf)
        h.env.importer.importOpened([u])
        await h.env.importer.idle()
        #expect(h.env.ui.importer.preview != nil)
        for _ in 0..<(ImportCoordinator.maxQueuedOpenEvents + 3) { h.env.importer.importOpened([u]) }
        #expect(h.env.importer.queuedOpenEvents == ImportCoordinator.maxQueuedOpenEvents)
        #expect(h.env.ui.importer.errorMessage?.contains("Too many files") == true)
    }

    // MARK: N4

    @Test func aFolderNamedTildeIsNotTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ImportCoordinator.sourceDescription([URL(fileURLWithPath: "/tmp/~/Downloads/w.ovpn")]) == "/tmp/“~”/Downloads/w.ovpn")
        #expect(ImportCoordinator.sourceDescription([URL(fileURLWithPath: home + "/~x/w.ovpn")]) == "~/“~x”/w.ovpn")
        #expect(ImportCoordinator.sourceDescription([URL(fileURLWithPath: home + "/Downloads/w.ovpn")]) == "~/Downloads/w.ovpn")
    }

    // MARK: L8: a file that keeps the check busy

    func unverified(_ h: Harness, _ v: FakeProfileValidator, name: String) async throws -> Profile {
        v.outcome = .fails(LPError(.extensionUnavailable))
        let a = await ImportCoordinator.analyse(fileName: name + ".ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        return try await h.env.profiles.create(try #require(h.env.importer.draft(a, name: name, killSwitch: false, allowLAN: false)))
    }

    @Test func timeoutsAreCappedPerRunAndAcrossLaunches() async throws {
        let v = FakeProfileValidator()
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        var ps: [Profile] = []
        for i in 0..<4 { ps.append(try await unverified(h, v, name: "P\(i)")) }
        let before = v.checked.count
        v.outcome = .fails(LPError(.timeout, detail: "evaluateProfile"))
        await h.env.profiles.verifyPending()
        await h.env.profiles.verifyPending()
        #expect(v.checked.count == before + ProfilesStore.maxTimeoutsPerRunTotal)
        // A profile that timed out in `maxTimeoutRuns` launches is left to "Check Again".
        let p = ps[0]
        #expect(h.env.settings.value.verifyTimeoutRuns[p.id.uuidString] == 1)
        h.env.settings.update { $0.verifyTimeoutRuns[p.id.uuidString] = ProfilesStore.maxTimeoutRuns }
        #expect(h.env.profiles.verificationStalled(p.id))
        let h2 = try await relaunch(h)
        h2.env.profiles.validator = v
        let n = v.checked.count
        await h2.env.profiles.verifyPending()
        #expect(v.checked.count == n + ProfilesStore.maxTimeoutsPerRunTotal)        // the other three, not P0
        v.outcome = .accepted(autologin: true)
        await h2.env.profiles.checkAgain(p.id)
        #expect(h2.env.profiles.profile(p.id)?.engineVerified == true)
        #expect(h2.env.settings.value.verifyTimeoutRuns[p.id.uuidString] == nil)
    }

    /// Reconcile installs what is verified first, and checks pending files last.
    @Test func reconcileVerifiesAfterProvisioning() async throws {
        let v = FakeProfileValidator()
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let p = try await unverified(h, v, name: "Office")
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        await h.env.profiles.load()
        v.outcome = .accepted(autologin: true)
        let callsAtCheck = Mutex<[LPMethod]>([])
        let service = h.service
        v.beforeAnswer.withLock { $0 = { @MainActor in callsAtCheck.withLock { $0 = service.state.withLock { $0.calls } } } }
        await h.env.profiles.reconcile()
        let seen = callsAtCheck.withLock { $0 }
        #expect(seen.contains(.listProvisioned) && seen.contains(.provisionProfile) && seen.contains(.revokeUnattended))
        #expect(h.env.profiles.profile(p.id)?.engineVerified == true)
        #expect(h.service.state.withLock { $0.provisioned[p.id] } != nil)          // provisioned by verifyPending itself
    }

    // MARK: Codex r2 #1: an unverified Save Only revision is not a deleted profile

    /// A connected kill-switch OpenVPN profile is edited with Save Only while the file check is unavailable: the new
    /// revision is "Not yet verified". Reconcile must keep the extension's approved copy (payload, credentials and the
    /// session's start authorisation), never remove it: NE's restart of the running session must still be admitted.
    @Test func reconcileKeepsTheApprovedCopyOfAnUnverifiedSaveOnly() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Office.ovpn", PreviewSeed.officeOvpn, killSwitch: true)
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        await h.env.profiles.load()
        await h.env.profiles.reconcile()
        let approved = try #require(h.service.state.withLock { $0.provisioned[p.id] })
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        #expect(await eventually { h.env.connection.statuses[p.id] == .connected })
        h.validator.outcome = .fails(LPError(.extensionUnavailable))
        _ = try await h.env.editorBackend.save(.existing(p.id), name: "Office", text: PreviewSeed.officeOvpn + "\nverb 4\n", mode: .saveOnly)
        #expect(h.env.profiles.profile(p.id)?.engineVerified == false)
        let removalsBefore = h.service.calls(.removeProfile)
        await h.env.profiles.reconcile()
        #expect(h.service.calls(.removeProfile) == removalsBefore)
        #expect(h.service.state.withLock { $0.provisioned[p.id] } == approved)
        // Once verified, the new revision replaces it (an approved replacement, never a removal).
        h.validator.outcome = .accepted(autologin: true)
        await h.env.profiles.reconcile()
        #expect(h.service.state.withLock { $0.provisioned[p.id]?.revision } == approved.revision + 1)
        #expect(h.service.calls(.removeProfile) == removalsBefore)
    }

    @Test func theReconcilePlanSeparatesProvisionableFromExisting() {
        let id = UUID()
        let entry = ProvisionedEntry(id: id, revision: 1, digest: "d")
        #expect(ProfilesStore.reconcilePlan(local: [], existing: [id], remote: [entry], pendingRemovals: []).remove.isEmpty)
        #expect(ProfilesStore.reconcilePlan(local: [], existing: [], remote: [entry], pendingRemovals: []).remove == [id])
    }

    // MARK: L1, L2, L3: revocation

    @Test func aLiveOrPendingProfileKeepsItsConsent() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let other = try await h.add("Home NAS.conf", Harness.splitConf, killSwitch: false)
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        #expect(await eventually { h.env.connection.statuses[p.id] == .connected })
        await h.env.profiles.revokeUnattended()
        let keep = try #require(h.service.state.withLock { $0.revokeKeeps.last })
        #expect(keep.contains(p.id) && !keep.contains(other.id))
        // Round 3 (Codex r3 #4): a hold record in settings.json alone (unauthenticated) keeps nothing; the hold the app
        // itself holds is a pending entry, kept above like any other.
        h.env.settings.update { $0.networkRestartHold = other.id }
        await h.env.profiles.revokeUnattended()
        #expect(h.service.state.withLock { $0.revokeKeeps.last?.contains(other.id) } == false)
    }

    @Test func aBusyExtensionIsAskedAgain() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        h.env.profiles.revokeRetryDelay = .zero
        h.env.profiles.revokeRetrySleep = { _ in }
        h.service.state.withLock { $0.revokeError = LPError(.extensionBusy) }
        await h.env.profiles.revokeUnattended()
        h.service.state.withLock { $0.revokeError = nil }
        #expect(await eventually { h.service.state.withLock { $0.revokeKeeps.count } == 1 })
    }

    /// L2: when everything has settled after a session, the extension is asked to drop planless records.
    @Test func theEndOfASessionSendsARevoke() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        h.env.connection.start()
        h.env.connection.connect(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(p.id, .connecting); h.managers.emit(p.id, .connected)
        #expect(await eventually { h.env.connection.statuses[p.id] == .connected })
        let before = h.service.calls(.revokeUnattended)
        h.env.connection.disconnect()
        h.managers.emit(p.id, .disconnecting); h.managers.emit(p.id, .disconnected)
        #expect(await eventually { h.service.calls(.revokeUnattended) > before })
    }

    // MARK: M2: unknown connections

    @Test func unknownLiveConnectionsReloadCoalescedAndNeverLoop() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let fake = FakeSettleClock()
        let inner = FakeVPNManager()
        let m = SerializedVPNManager(inner: inner, settleClock: fake.clock)
        try await m.loadAll()
        var changes = 0
        m.onConfigurationChange = { changes += 1 }
        let loads = inner.loads
        for _ in 0..<50 { inner.onUnknownConnectionActive?() }
        #expect(await eventually { m.unknownReloads >= 1 })
        try await Task.sleep(for: .milliseconds(200))
        // Round 3 (Fable N4): triggers that arrived during the reload or inside the quiet period are made up by at most
        // ONE reload when the quiet ends (the fake clock's sleep advances time), which again finds nothing new: bounded.
        let afterFirst = m.unknownReloads
        #expect(afterFirst <= 2)
        for _ in 0..<50 { inner.onUnknownConnectionActive?() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(m.unknownReloads <= afterFirst + 1)
        #expect(inner.loads <= loads + m.unknownReloads)                   // (one may still be loading)
        #expect(changes == 0)                                              // nothing new: silenced, no config-change fan-out
        #expect(await m.waitUntilSettled(.seconds(1), cap: .milliseconds(1)))   // not a mutation: nothing to settle
        // After the quiet period, a reload that finds a new configuration fans out.
        fake.advance(SerializedVPNManager.unknownReloadQuiet)
        inner.entries[work.id] = try #require(h.managers.entries[work.id])
        inner.onUnknownConnectionActive?()
        #expect(await eventually { changes == 1 })
    }
}
