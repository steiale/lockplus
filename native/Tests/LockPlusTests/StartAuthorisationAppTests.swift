import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import Testing
@testable import LockPlus

/// 2.0.2 (PLAN-2.0.2 §3, D-1): every start the app makes of a manual profile is armed over XPC first and carries the
/// arm's nonce; unattended starts (PF 52 crash restart) are not armed; a refused outside start (225) is said in Diagnostics.
@MainActor @Suite("2.0.2: start authorisation (app)", .serialized, .timeLimit(.minutes(1)))
struct StartAuthorisationAppTests {
    let nn = NoNetworkRestartTests()
    let t4 = OnDemandPause4Tests()

    var unauthorised: NSError { LPTunnelError(.startNotAuthorised, detail: "start not authorised by the profile's owner") as NSError }

    func nonce(_ options: [String: NSObject]) -> String? { options[StartOptionKey.startNonce] as? String }

    // MARK: options and copy

    @Test func startOptionsCarryNonceAsUUIDString() {
        let n = UUID()
        let o = StartOptionsBuilder.options(endpoints: ["a.example": ["192.0.2.1"]], nonce: n)
        #expect(o[StartOptionKey.startNonce] as? NSString == n.uuidString as NSString)
        #expect(o[StartOptionKey.manual] as? NSNumber == 1)
        #expect(UUID(uuidString: nonce(o) ?? "") == n)
        #expect(StartOptionsBuilder.options()[StartOptionKey.startNonce] == nil)
        #expect(StartOptionsBuilder.crashRestart[StartOptionKey.startNonce] == nil)
    }

    @Test func theCopyTellsTheUserToConnectFromLockPlus() {
        #expect(ConnectionStore.observedError(unauthorised).0.code == .startNotAuthorised)
        #expect(LPErrorCode.startNotAuthorised.message()
                == "This profile was started outside LockPlus (for example from System Settings) and was refused. Connect it from LockPlus.")
        #expect(LPErrorCode.startNotAuthorised.reason() == "it was started outside LockPlus")
        #expect(LPErrorCode.startNotAuthorised.causeReason() == "it was started outside LockPlus")
    }

    // MARK: the GUI path

    @Test func everyGUIStartArmsFirst() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.connection.start()
        var armsAtStart: Int?
        h.managers.onStart = { _ in armsAtStart = h.service.state.withLock { $0.arms.count } }
        h.env.connection.connect(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(armsAtStart == 1)                                        // the arm was answered before startVPNTunnel
        let arm = try #require(h.service.state.withLock { $0.arms.first })
        #expect(arm.profileID == p.id)
        let (id, options) = try #require(h.managers.starts.first)
        #expect(id == p.id)
        #expect(nonce(options) == arm.nonce.uuidString)                  // the same nonce
        // A second start (after a stop) arms anew, with a new nonce.
        h.managers.emit(p.id, .connecting); h.managers.emit(p.id, .connected)
        h.env.connection.disconnect()
        h.managers.emit(p.id, .disconnecting); h.managers.emit(p.id, .disconnected)
        #expect(await eventually { h.env.connection.statuses[p.id] == .disconnected })
        h.env.connection.connect(p.id)
        #expect(await eventually { h.managers.starts.count == 2 })
        let arms = h.service.state.withLock { $0.arms }
        #expect(arms.count == 2 && arms[0].nonce != arms[1].nonce)
        #expect(nonce(h.managers.starts[1].1) == arms[1].nonce.uuidString)
    }

    /// A definite refusal by the extension (here: the profile isn't provisioned in this user's namespace) is a failed
    /// start, never a start without an arm.
    @Test func armFailureDoesNotStart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.connection.start()
        h.service.state.withLock { $0.armError = LPError(.profileNotProvisioned) }
        h.env.connection.connect(p.id)
        #expect(await eventually { h.env.connection.observedError?.code == .profileNotProvisioned })
        #expect(h.managers.starts.isEmpty)
    }

    /// A transport failure against an extension that supports authorisation fails the start too; against one whose
    /// hello says it predates the capability, the start goes ahead without a nonce.
    @Test func armingAgainstOlderAndCurrentExtensions() async {
        let fake = FakeTunnelService()
        let id = UUID()
        fake.state.withLock { $0.armError = LPError(.extensionUnavailable) }
        #expect(await StartArming.arm(id, service: fake) == .failed(LPError(.extensionUnavailable)))
        fake.state.withLock { $0.startAuthorisation = false }        // an extension whose hello predates the capability
        #expect(await StartArming.arm(id, service: fake) == .legacyExtension)
        // A definite answer is never read as "older", whatever the hello says.
        fake.state.withLock { $0.armError = LPError(.profileNotProvisioned) }
        #expect(await StartArming.arm(id, service: fake) == .failed(LPError(.profileNotProvisioned)))
        // A timeout is never read as "older" either.
        fake.state.withLock { $0.armError = LPError(.timeout) }
        #expect(await StartArming.arm(id, service: fake) == .failed(LPError(.timeout)))
        fake.state.withLock { $0.armError = nil; $0.startAuthorisation = true }
        guard case .armed(let n) = await StartArming.arm(id, service: fake) else { Issue.record("not armed"); return }
        #expect(fake.state.withLock { $0.arms.last } == ArmStartRequest(profileID: id, nonce: n))
    }

    @Test func anOlderExtensionIsStartedWithoutNonce() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.connection.start()
        h.service.state.withLock { $0.armError = LPError(.extensionUnavailable); $0.startAuthorisation = false }   // an older extension
        h.env.connection.connect(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(nonce(h.managers.starts[0].1) == nil)
        #expect(h.managers.starts[0].1[StartOptionKey.manual] as? NSNumber == 1)
    }

    /// Round 1 (Fable L4): while the old extension still runs and its replacement awaits approval, a kill-switch profile
    /// isn't started without a nonce (NE's restart into the new extension would be refused, and that start is open).
    @Test func noKillSwitchStartWithoutANonceDuringAnExtensionUpdate() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let ks = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let split = try await h.add("Home NAS.conf", Harness.splitConf, killSwitch: false)
        h.env.connection.start()
        h.service.state.withLock { $0.armError = LPError(.extensionUnavailable); $0.startAuthorisation = false }
        h.env.settings.update { $0.expectedUpdate = ExpectedUpdate(from: "200025", to: "200026") }
        h.env.connection.connect(ks.id)
        #expect(await eventually { h.env.connection.observedError?.code == .versionMismatch })
        #expect(h.managers.starts.isEmpty)
        h.env.connection.connect(split.id)                                      // no kill switch: started as before
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.starts[0].0 == split.id && nonce(h.managers.starts[0].1) == nil)
    }

    @Test func crashRestartUsesUnattendedOptions() async throws {
        let net = FixtureNetworkWatcher()
        let h = Harness(network: net)
        defer { h.dir.cleanup() }
        h.env.connection.endpointPushSettle = .zero
        h.env.connection.crashRestartGrace = .zero
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.managers.entries[p.id]?.onDemand = true
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = NSError(domain: NEVPNConnectionErrorDomain, code: 12)
        h.managers.emit(p.id, .disconnected)
        #expect(await eventually { h.managers.starts.count == 1 })
        let (_, options) = try #require(h.managers.starts.first)
        #expect(options.isEmpty)                                          // no lp.manual, no nonce
        #expect(h.service.state.withLock { $0.arms.isEmpty })             // unattended: nothing armed
    }

    // MARK: 225 as the app observes it

    func world() async throws -> (NoNetworkRestartTests.World, Profile) {
        let w = try await nn.world(NoNetworkRestartTests.online)
        let split = try await w.h.add("Split.conf", Harness.splitConf, killSwitch: false)
        w.h.env.connection.apply(snapshot: TunnelSnapshot(profileID: split.id), for: split.id)     // spend the S12 launch rule
        return (w, split)
    }

    func snapshot(_ w: NoNetworkRestartTests.World, _ id: UUID, at: Date = Date()) {
        w.h.service.state.withLock { $0.snapshot = TunnelSnapshot(profileID: id, lastError: LPError(.startNotAuthorised), lastErrorAt: at) }
    }

    func outsideLines(_ w: NoNetworkRestartTests.World, _ name: String) -> Int {
        w.h.env.profiles.problems.filter { $0.message.contains(name) && $0.message.contains("outside LockPlus") }.count
    }

    /// `.connecting` → `.disconnected` with 225 for a start the app didn't make (System Settings, `scutil`, another
    /// instance): exactly one Diagnostics line (the shared 5 minute throttle), the hero says what to do.
    @Test func unexpected225PostsOneDiagnosticsLine() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        w.h.managers.lastError = unauthorised
        snapshot(w, split.id)
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { outsideLines(w, "Split") == 1 })
        #expect(w.h.env.connection.observedError?.code == .startNotAuthorised)
        #expect(w.h.managers.stops.isEmpty && w.h.managers.starts.isEmpty)
        // The same refusal again within the throttle: no second line.
        snapshot(w, split.id)
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await t4.never { outsideLines(w, "Split") > 1 })
    }

    /// Round 1 (E2E F6, 26.6.2): NE reports `.disconnected` before it stores the refusal; the first read finds nothing.
    /// The read is repeated, and the reason still shows (hero and Diagnostics).
    @Test func aRefusalStoredAfterTheDisconnectIsStillShown() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        let gate = AsyncStream<Void>.makeStream()
        w.h.env.connection.refusalReadSleep = { _ in for await _ in gate.stream { return } }
        w.h.managers.lastError = nil
        snapshot(w, split.id)
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        try await Task.sleep(for: .milliseconds(200))
        #expect(outsideLines(w, "Split") == 0)                                   // nothing stored yet
        w.h.managers.lastError = unauthorised                                    // NE stores it ~1 s later
        gate.continuation.yield()
        #expect(await eventually { outsideLines(w, "Split") == 1 })
        #expect(w.h.env.connection.observedError?.code == .startNotAuthorised)
        gate.continuation.finish()
    }

    /// A sticky 225 older than this attempt is not this attempt's end.
    @Test func aStale225IsIgnored() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        w.h.managers.lastError = unauthorised
        snapshot(w, split.id, at: Date().addingTimeInterval(-3600))
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await t4.never { outsideLines(w, "Split") > 0 })
    }

    /// A 225 right after this app armed a start of the profile is the app's own failure, not an outside start: the
    /// hero says it, Diagnostics doesn't claim "outside LockPlus".
    @Test func a225AfterOurOwnArmIsNotAnOutsideStart() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(split.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        #expect(w.h.service.state.withLock { $0.arms.count } == 1)
        w.h.managers.lastError = unauthorised
        snapshot(w, split.id)
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.env.connection.observedError?.code == .startNotAuthorised })
        #expect(await t4.never { outsideLines(w, "Split") > 0 })
    }

    // MARK: headless resume

    struct Fixture {
        let h: Harness
        let work: Profile
        let agent = ProbeResumeAgent()
        var service: FakeTunnelService { h.service }
    }

    /// A paused `work` whose pause has expired; `onDemand`: whether it has on-demand rules (it was in the pause record).
    func fixture(onDemand: Bool) async throws -> Fixture {
        let h = Harness()
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        var s = AppSettings()
        s.autoConnect.pausedUntil = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        s.pausedState = PausedState(profileID: work.id, onDemandEnabledIDs: onDemand ? [work.id] : [], agentBuild: "1",
                                   intent: await resumeIntent(work.id, until: s.autoConnect.pausedUntil!, keychain: h.keychain, dir: h.dir.data))
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        return Fixture(h: h, work: work)
    }

    // MARK: Round 1, Codex 3: the pause record's resume intent

    /// Same-user code writes an expired pause naming a manual profile and runs `--resume-protection`: without the
    /// record's intent the signed executable arms and starts nothing (on-demand is still restored as recorded).
    @Test func anUnsignedPauseRecordArmsAndStartsNothing() async throws {
        let f = try await fixture(onDemand: true)
        defer { f.h.dir.cleanup() }
        var s = try #require(AtomicFile.loadJSON(AppSettings.self, from: f.h.dir.data.settings))
        s.pausedState?.intent = nil
        try AtomicFile.saveJSON(s, to: f.h.dir.data.settings)
        let r = await HeadlessResume.perform(dir: f.h.dir.data, managers: f.h.managers, agent: f.agent, keychain: f.h.keychain,
                                             service: f.service)
        #expect(r == .resumed(restarted: nil, onDemand: [f.work.id]))
        #expect(f.h.managers.starts.isEmpty && f.service.state.withLock { $0.arms.isEmpty })
    }

    /// The intent binds the profile and the pause's end: another profile, another end or another keychain fails, and a
    /// genuine record older than `ResumeIntent.maxAge` is not resumed.
    @Test func theResumeIntentBindsProfileEndAndAge() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let until = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        let tag = await resumeIntent(work.id, until: until, keychain: h.keychain, dir: h.dir.data)
        let state = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1", intent: tag)
        let repo = h.env.profiles.repository
        #expect(await ConnectionStore.checkResumeIntent(state, profileID: work.id, until: until, now: Date(), repository: repo) == .holds)
        #expect(await ConnectionStore.checkResumeIntent(state, profileID: UUID(), until: until, now: Date(), repository: repo) == .changedOutside)
        #expect(await ConnectionStore.checkResumeIntent(state, profileID: work.id, until: until.addingTimeInterval(1), now: Date(), repository: repo) == .changedOutside)
        #expect(await ConnectionStore.checkResumeIntent(state, profileID: work.id, until: until,
                                                        now: until.addingTimeInterval(ResumeIntent.maxAge + 1), repository: repo) == .tooOld)
        let other = ProfileRepository(directory: h.dir.data.profiles, keys: InMemoryKeychain())
        #expect(await ConnectionStore.checkResumeIntent(state, profileID: work.id, until: until, now: Date(), repository: other) != .holds)
        // Round 2 (L5): one shot. Once consumed, a copy of the same record no longer verifies; a later pause's seal
        // also retires every earlier record.
        await repo.consumeRecord(.pause)
        #expect(await ConnectionStore.checkResumeIntent(state, profileID: work.id, until: until, now: Date(), repository: repo) == .changedOutside)
        let tag2 = await resumeIntent(work.id, until: until, keychain: h.keychain, dir: h.dir.data)
        _ = await resumeIntent(work.id, until: until, keychain: h.keychain, dir: h.dir.data)
        let older = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1", intent: tag2)
        #expect(await ConnectionStore.checkResumeIntent(older, profileID: work.id, until: until, now: Date(), repository: repo) == .changedOutside)
        // Round 2 (N3): the record keys are separate from the metadata key and from each other.
        let sealed = try await repo.sealRecord(.pendingResume, ResumeIntent.message(profileID: work.id, until: until))
        let crossKind = PausedState(profileID: work.id, onDemandEnabledIDs: [], agentBuild: "1", intent: sealed)
        #expect(await ConnectionStore.checkResumeIntent(crossKind, profileID: work.id, until: until, now: Date(), repository: repo) == .changedOutside)
    }

    /// The GUI's own pause writes an intent that its resume (and the agent) accept.
    @Test func theGUIsPauseWritesAValidIntent() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.connection.start()
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(work.id, .connecting); h.managers.emit(work.id, .connected)
        #expect(await eventually { h.env.connection.statuses[work.id] == .connected })
        await h.env.connection.pause(minutes: 5)
        let s = h.env.settings.value
        let until = try #require(s.autoConnect.pausedUntil)
        #expect(until == ResumeIntent.wholeSeconds(until))
        #expect(s.pausedState?.profileID == work.id)
        #expect(await ConnectionStore.checkResumeIntent(s.pausedState, profileID: work.id, until: until, now: Date(),
                                                        repository: h.env.profiles.repository) == .holds)
    }

    // MARK: Round 1, Codex 4: unattended-start consent

    @Test func aSelectedButDisabledAutoConnectProfileHasNoOnDemandConsent() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        var rules = AutoConnectRules()
        rules.profileID = p.id
        rules.enabled = false
        #expect(OnDemandPlan.plan(for: p, rules: rules, paused: false) == nil)
        #expect(ManagerConfiguration(profile: p, onDemand: OnDemandPlan.plan(for: p, rules: rules, paused: false)).provider.onDemand == false)
        rules.enabled = true
        #expect(OnDemandPlan.plan(for: p, rules: rules, paused: true)?.enabled == false)            // a pause keeps the consent
        #expect(OnDemandPlan.plan(for: p, rules: rules, paused: false)?.enabled == true)
        var unverified = p
        unverified.engineVerified = false
        #expect(OnDemandPlan.plan(for: unverified, rules: rules, paused: false) == nil)              // Fable L1
    }

    /// Turning Auto-Connect off re-saves the configuration without the consent flag and asks the extension to drop the
    /// profile's recorded unattended admission.
    @Test func turningAutoConnectOffRevokesTheUnattendedConsent() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = p.id }
        await h.env.profiles.resaveOnDemand()
        try await h.env.managers.loadAll()
        #expect(h.env.managers.managers.first { $0.profileID == p.id }?.stored?.onDemand == true)
        #expect(h.service.state.withLock { $0.revokeKeeps.last?.contains(p.id) == true })
        h.env.settings.update { $0.autoConnect.enabled = false }
        await h.env.profiles.resaveOnDemand()
        try await h.env.managers.loadAll()
        #expect(h.env.managers.managers.first { $0.profileID == p.id }?.stored?.onDemand == false)
        #expect(h.service.state.withLock { $0.revokeKeeps.last?.contains(p.id) == false })
        // An extension without start authorisation gets no revoke.
        h.env.profiles.extensionCapabilities = []
        let before = h.service.calls(.revokeUnattended)
        await h.env.profiles.resaveOnDemand()
        #expect(h.service.calls(.revokeUnattended) == before)
    }

    // MARK: Round 1, Fable H1a: Save Only on a connected profile

    /// "Save Only" provisions the new revision and leaves the connected session alone: no stop, no new arm, no start.
    /// (The extension keeps that session's authorisation: TunnelEngine `aHigherRevisionProvisionKeepsTheLiveSessionsAuthorisation`.)
    @Test func saveOnlyOnAConnectedProfileLeavesTheSessionAndArmsNothing() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.env.connection.start()
        h.env.connection.connect(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(p.id, .connecting); h.managers.emit(p.id, .connected)
        #expect(await eventually { h.env.connection.statuses[p.id] == .connected })
        let arms = h.service.state.withLock { $0.arms.count }
        let rev = try #require(h.env.profiles.profile(p.id)).payloadRevision
        _ = try await h.env.editorBackend.save(.existing(p.id), name: "Work", text: Harness.wgConf + "\n# edited\n", mode: .saveOnly)
        #expect(h.env.profiles.profile(p.id)?.payloadRevision == rev + 1)
        #expect(h.service.state.withLock { $0.provisioned[p.id]?.revision } == rev + 1)
        #expect(h.managers.starts.count == 1 && h.managers.stops.isEmpty)
        #expect(h.service.state.withLock { $0.arms.count } == arms)
    }

    @Test func headlessResumeArmsBeforeStart() async throws {
        let f = try await fixture(onDemand: false)
        defer { f.h.dir.cleanup() }
        var armsAtStart: Int?
        f.h.managers.onStart = { _ in armsAtStart = f.h.service.state.withLock { $0.arms.count } }
        let r = await HeadlessResume.perform(dir: f.h.dir.data, managers: f.h.managers, agent: f.agent, keychain: f.h.keychain,
                                             service: f.service)
        #expect(r == .resumed(restarted: f.work.id, onDemand: []))
        #expect(armsAtStart == 1)
        let arm = try #require(f.h.service.state.withLock { $0.arms.first })
        #expect(arm.profileID == f.work.id)
        let (_, options) = try #require(f.h.managers.starts.first)
        #expect(nonce(options) == arm.nonce.uuidString)
        #expect(options[StartOptionKey.manual] as? NSNumber == 1)
    }

    @Test func headlessArmFailureFallsBackForOnDemandProfile() async throws {
        let f = try await fixture(onDemand: true)
        defer { f.h.dir.cleanup() }
        f.h.service.state.withLock { $0.armError = LPError(.extensionUnavailable) }
        let r = await HeadlessResume.perform(dir: f.h.dir.data, managers: f.h.managers, agent: f.agent, keychain: f.h.keychain,
                                             service: f.service)
        #expect(r == .resumed(restarted: f.work.id, onDemand: [f.work.id]))
        let (_, options) = try #require(f.h.managers.starts.first)
        #expect(options.isEmpty)                                          // unattended (crashRestart): the on-demand rules admit it
        #expect(AtomicFile.loadJSON(AppSettings.self, from: f.h.dir.data.settings)?.autoConnect.pausedUntil == nil)
    }

    @Test func headlessArmFailureKeepsAgentForManualProfile() async throws {
        let f = try await fixture(onDemand: false)
        defer { f.h.dir.cleanup() }
        f.h.service.state.withLock { $0.armError = LPError(.extensionUnavailable) }
        let r = await HeadlessResume.perform(dir: f.h.dir.data, managers: f.h.managers, agent: f.agent, keychain: f.h.keychain,
                                             service: f.service)
        #expect(r == .armUnavailable)
        #expect(f.h.managers.starts.isEmpty)
        #expect(!f.agent.calls.contains { $0.hasPrefix("unregister") })   // stays registered: the next run retries
        let saved = AtomicFile.loadJSON(AppSettings.self, from: f.h.dir.data.settings)
        #expect(saved?.autoConnect.pausedUntil != nil && saved?.pausedState?.profileID == f.work.id)
    }

    /// An extension that predates the capability: the restart goes ahead, without a nonce (it enforces nothing).
    @Test func headlessResumeAgainstAnOlderExtensionStartsWithoutNonce() async throws {
        let f = try await fixture(onDemand: false)
        defer { f.h.dir.cleanup() }
        f.h.service.state.withLock { $0.armError = LPError(.extensionUnavailable); $0.startAuthorisation = false }
        let r = await HeadlessResume.perform(dir: f.h.dir.data, managers: f.h.managers, agent: f.agent, keychain: f.h.keychain,
                                             service: f.service)
        #expect(r == .resumed(restarted: f.work.id, onDemand: []))
        #expect(nonce(f.h.managers.starts[0].1) == nil)
    }

    /// A definite refusal (not provisioned here) is the existing fail-closed outcome: nothing starts, the pause ends.
    @Test func headlessDefiniteArmRefusalIsAFailedStart() async throws {
        let f = try await fixture(onDemand: false)
        defer { f.h.dir.cleanup() }
        f.h.service.state.withLock { $0.armError = LPError(.profileNotProvisioned) }
        let r = await HeadlessResume.perform(dir: f.h.dir.data, managers: f.h.managers, agent: f.agent, keychain: f.h.keychain,
                                             service: f.service)
        #expect(r == .resumed(restarted: nil, onDemand: []))
        #expect(f.h.managers.starts.isEmpty)
    }
}
