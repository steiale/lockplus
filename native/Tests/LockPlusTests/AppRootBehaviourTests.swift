import Foundation
import LPModel
import LPParsing
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// The app root over fakes: the stale-error rule (S12), the action rules (lp.manual, 4102, cancelled uninstall),
/// the two-start auth flow, the store and the Go migration (fixtures only).
@MainActor @Suite("App root: behaviour", .serialized)
struct AppRootBehaviourTests {
    /// Lets the stores' main-actor tasks run.
    func settle(_ ms: Int = 50) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    // MARK: S12: fetchLastDisconnectError only after an observed disconnect

    @Test func noDisconnectErrorIsReadAtLaunch() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.managers.lastError = NSError(domain: LPTunnelError.errorDomain, code: LPErrorCode.authFailed.rawValue)
        h.env.connection.start()
        try await settle()
        #expect(h.managers.fetchCount == 0)
        #expect(h.env.connection.observedError == nil)
        #expect(h.env.connection.currentID == p.id)
    }

    @Test func anObservedFailedStartReadsTheError() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        h.managers.lastError = NSError(domain: LPTunnelError.errorDomain, code: LPErrorCode.connectTimeout.rawValue,
                                       userInfo: [LPTunnelError.detailKey: "50 s"])
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .disconnected)
        // Waits for the error read itself (a fixed 50 ms settle flaked under a loaded full run).
        #expect(await eventually { h.env.connection.observedError != nil })
        #expect(h.managers.fetchCount == 1)
        #expect(h.env.connection.observedError == ObservedError(code: .connectTimeout, origin: .failedStart))
        #expect(h.env.connection.errorDetail == "50 s")
        UIBinder.render(h.env)
        #expect(h.env.ui.connection.inputs.condition.row == "14")      // E14c untested: not "blocked"
    }

    @Test func providerCancelAfterConnectedIsMarkedAsSuch() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        h.managers.lastError = NSError(domain: LPTunnelError.errorDomain, code: LPErrorCode.engineDied.rawValue)
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        h.managers.emit(p.id, .disconnected)
        #expect(await eventually { h.env.connection.observedError?.origin == .providerCancel })
    }

    @Test func ourOwnDisconnectNeverShowsTheStickyError() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        h.managers.lastError = NSError(domain: LPTunnelError.errorDomain, code: LPErrorCode.authFailed.rawValue)
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        h.env.connection.disconnect()
        try await settle()
        #expect(h.managers.stops == [p.id])
        h.managers.emit(p.id, .disconnecting)
        h.managers.emit(p.id, .disconnected)
        try await settle()
        #expect(h.managers.fetchCount == 0)
        #expect(h.env.connection.observedError == nil)
        #expect(h.env.connection.userStoppedSinceError)
    }

    @Test func launchSnapshotErrorFollowsTheLaunchRule() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let quit = Date().addingTimeInterval(-60)
        h.env.settings.update { $0.lastQuitAt = quit }
        // Older than the last quit, no latch, no prompt: stale, not shown.
        h.env.connection.apply(snapshot: TunnelSnapshot(profileID: p.id, lastError: LPError(.authFailed), lastErrorAt: quit.addingTimeInterval(-10)), for: p.id)
        #expect(h.env.connection.observedError == nil)

        let h2 = Harness()
        defer { h2.dir.cleanup() }
        let p2 = try await h2.add("Work.conf", Harness.wgConf)
        h2.env.settings.update { $0.lastQuitAt = quit }
        h2.env.connection.apply(snapshot: TunnelSnapshot(profileID: p2.id, lastError: LPError(.connectTimeout), lastErrorAt: quit.addingTimeInterval(10)), for: p2.id)
        #expect(h2.env.connection.observedError?.code == .connectTimeout)

        let h3 = Harness()
        defer { h3.dir.cleanup() }
        let p3 = try await h3.add("Work.conf", Harness.wgConf)
        h3.env.settings.update { $0.lastQuitAt = quit }
        h3.env.connection.apply(snapshot: TunnelSnapshot(profileID: p3.id, startLatch: StartLatch(code: .authFailed, kind: .hard, notBefore: nil, revision: 1),
                                                         lastError: LPError(.authFailed), lastErrorAt: quit.addingTimeInterval(-10)), for: p3.id)
        #expect(h3.env.connection.observedError?.code == .authFailed)
    }

    // MARK: Action rules

    @Test func connectPassesManualAsNSNumber() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        h.env.ui.actions.connect(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })      // the start verifies and settles first
        let (id, options) = try #require(h.managers.starts.first)
        #expect(id == p.id)
        #expect((options[StartOptionKey.manual] as? NSNumber)?.intValue == 1)
    }

    @Test func tryAgainApproveAndReinstallGoThroughTheExtensionStore() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        h.env.ui.actions.installExtension()
        h.env.ui.actions.perform(.approve)
        h.env.ui.actions.reinstallExtension()
        try await settle()
        #expect(h.ext.retries == 2)
        #expect(h.ext.reinstalls == 1)
        #expect(h.hooks.calls.contains("authenticate"))
    }

    /// 4102: the link's unauthorizedPeer fails the extension state; Try Again clears the client's 4102 state first.
    @Test func unauthorizedPeerIsClearedOnlyByTheUser() async throws {
        final class Rec { var n = 0 }
        let rec = Rec()
        let manager = SystemExtensionManager(bundle: .main, quiescer: NoTunnelsQuiescer(), submitter: { _ in rec.n += 1 },
                                             propertiesTimeout: .milliseconds(20))
        let service = FakeTunnelService()
        let store = ExtensionStore(manager: manager, service: service)
        store.apply(ServiceLinkStatus(link: .unavailable(LPError(.unauthorizedPeer)), busy: false))
        #expect(store.state == .failed(.unauthorizedPeer))
        #expect(ExtensionMapping.readiness(store.state, endedWithoutResult: false) == .failed)
        #expect(service.state.withLock { $0.resets } == 0)               // never automatic
        await store.retryAfterUserAction()
        #expect(service.state.withLock { $0.resets } == 1)
        #expect(rec.n == 2)                                               // properties preflight + activation, no sysextd
        #expect(store.state == .activating)
    }

    @Test func cancelledUninstallLeavesTheComponentInstalled() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        try await h.add("Work.conf", Harness.wgConf)
        h.ext.deactivateError = LPError(.cancelled, detail: "admin dialog cancelled")
        await Uninstaller(env: h.env).run()
        #expect(h.env.ui.settings.uninstallPhase == .componentStillInstalled)
        #expect(h.ext.deactivations == 1)
        #expect(h.service.calls(.wipeAllSecrets) == 1)
        #expect(h.managers.entries.isEmpty)
        #expect(!h.hooks.calls.contains("finishUninstall"))
        #expect(try await h.keychain.load(service: KeychainServices.payloadKey, account: "v1") != nil)   // nothing local deleted
    }

    @Test func completedUninstallFinishes() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        await Uninstaller(env: h.env).run()
        #expect(h.hooks.calls.contains("finishUninstall"))
    }

    /// §4.2 step 3: quiesce before replacing the extension, resume after `.completed`.
    @Test func quiesceAndResumeAroundAnExtensionUpdate() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.managers.entries[p.id]?.status = .connected
        h.managers.entries[p.id]?.onDemand = true
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = p.id }     // its plan wants on-demand (R5: restores go through the plan)
        let q = ManagerQuiescer()
        q.attach(managers: h.managers, settings: h.env.settings, connection: h.env.connection)
        #expect(await q.hasOnDemandOrResumeMarker())
        await q.quiesce(reason: .extensionUpdate)
        #expect(h.env.settings.value.pendingResume == PendingResume(profileID: p.id, onDemandEnabledIDs: [p.id], reason: .extensionUpdate))
        #expect(h.managers.entries[p.id]?.onDemand == false)
        #expect(h.managers.stops == [p.id])
        await q.resumeAfterUpdate()
        #expect(h.env.settings.value.pendingResume == nil)
        #expect(await eventually { h.managers.starts.count == 1 })      // the start verifies and settles first
        #expect(h.managers.entries[p.id]?.onDemand == true)
        #expect((h.managers.starts.first?.1[StartOptionKey.manual] as? NSNumber)?.intValue == 1)
    }

    // MARK: Auth (§8.4, draft 9: answered into the pending start)

    @Test func knownInteractiveProfilePromptsBeforeTheStartThenStartsWithoutAPromptID() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Office.ovpn", PreviewSeed.officeOvpn)
        #expect(p.auth?.needsUserPass == true)
        h.env.connection.start()
        h.env.ui.actions.connect(p.id)
        try await settle()
        #expect(h.managers.starts.isEmpty)                                     // nothing started before the answer
        let prompt = try #require(h.env.auth.prompt)
        #expect(prompt.nextStart)
        h.env.ui.actions.submitAuth(AuthAnswer(promptID: prompt.promptID, username: "alex", password: "pw", response: "", savePassword: false))
        try await settle(100)
        #expect(h.service.state.withLock { $0.answers.count } == 1)
        let (_, options) = try #require(h.managers.starts.first)
        #expect((options[StartOptionKey.manual] as? NSNumber)?.intValue == 1)
        #expect(options["lp.promptID"] == nil)                                 // nothing one-shot in the options (S2 E1)
        #expect(h.managers.starts.count == 1)
    }

    /// Draft 9: a prompt the server asks for during the connect is pulled while the start is pending (`.connecting`)
    /// and answered into it; the app never starts a second time.
    @Test func inStartPromptIsAnsweredIntoThePendingStart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        let live = AuthPrompt(promptID: UUID(), profileID: p.id, kind: .dynamicChallenge, challengeText: "Code?", echo: true,
                              lockedUsername: "alex", reason: .initial, savedUsername: nil, nextStart: false,
                              expiresAt: Date().addingTimeInterval(300))
        h.service.state.withLock { $0.prompt = live }
        h.managers.emit(p.id, .connecting)
        try await settle(100)
        #expect(h.env.auth.prompt?.promptID == live.promptID)
        h.service.state.withLock { $0.snapshot = TunnelSnapshot(profileID: p.id, phase: .awaitingAuth, epoch: 3) }
        h.env.connection.refreshSnapshot()
        try await settle(100)
        UIBinder.render(h.env)
        #expect(h.env.ui.connection.inputs.condition.row == "3")
        h.env.ui.actions.submitAuth(AuthAnswer(promptID: live.promptID, username: "", password: "", response: "123456", savePassword: false))
        try await settle(100)
        #expect(h.service.state.withLock { $0.answers.count } == 1)
        #expect(h.managers.starts.isEmpty)                                     // no second start
    }

    /// Cancel on an in-start prompt is a user stop too (with the kill switch the start would stay held, blocked).
    @Test func cancellingAnInStartPromptStopsTheStart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        let live = AuthPrompt(promptID: UUID(), profileID: p.id, kind: .userPass, challengeText: nil, echo: false,
                              lockedUsername: nil, reason: .rejected, savedUsername: "alex", nextStart: false,
                              expiresAt: Date().addingTimeInterval(600))
        h.service.state.withLock { $0.prompt = live }
        h.managers.emit(p.id, .connecting)
        try await settle(100)
        #expect(h.env.auth.prompt?.promptID == live.promptID)
        h.env.auth.cancel(live.promptID)
        try await settle(100)
        #expect(h.managers.stops.contains(p.id))
        #expect(h.env.auth.prompt == nil)
    }

    @Test func appendOTPConcatenatesAndNeverSavesTheConcatenation() {
        let prompt = AuthPrompt(promptID: UUID(), profileID: UUID(), kind: .userPass, challengeText: nil, echo: false, lockedUsername: nil,
                                reason: .initial, savedUsername: nil, nextStart: true, expiresAt: Date())
        let a = AuthAnswer(promptID: prompt.promptID, username: "u", password: "base", response: "123456", savePassword: true)
        let w = AuthCoordinator.wireAnswer(a, prompt: prompt, appendOTP: true)
        #expect(w.password == Data("base123456".utf8) && w.response == nil && !w.save)
        let plain = AuthCoordinator.wireAnswer(a, prompt: prompt, appendOTP: false)
        #expect(plain.password == Data("base".utf8) && plain.save)
    }

    // MARK: Store

    @Test func profileFilesAreSealedAndTamperIsDetected() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let sealed = try Data(contentsOf: h.dir.data.profiles.appending(path: "\(p.id.uuidString).\(p.payloadRevision).sealed"))
        #expect(sealed.range(of: Data("PrivateKey".utf8)) == nil)
        let payload = try await h.env.profiles.payload(p.id)
        #expect(String(decoding: payload.copyBytes(), as: UTF8.self).contains("PrivateKey"))
        #expect(h.service.state.withLock { $0.provisioned[p.id]?.digest } == p.payloadDigest)

        let meta = h.dir.data.profiles.appending(path: "\(p.id.uuidString).json")
        var text = try String(contentsOf: meta, encoding: .utf8)
        text = text.replacingOccurrences(of: #"\"killSwitch\":true"#, with: #"\"killSwitch\":false"#)
        try text.write(to: meta, atomically: true, encoding: .utf8)
        await h.env.profiles.load()
        #expect(h.env.profiles.tampered == [p.id])
        #expect(h.env.profiles.profiles.isEmpty)
    }

    @Test func replayOfOlderMetadataIsTampering() {
        let p = Profile(id: UUID(), name: "P", kind: .wireGuard, policy: NetworkPolicy(killSwitch: true), auth: nil, notes: "",
                        summary: ProfileSummary(isFullTunnel: true), payloadRevision: 2, payloadDigest: "d", metaRevision: 4,
                        ownerUID: 501, createdAt: Date(), updatedAt: Date(), origin: .editor, importReport: nil, engineVerified: true)
        let flags = ProtocolFlags(policy: p.policy, isFullTunnel: true)
        func m(_ rev: UInt64, _ meta: UInt64, _ f: ProtocolFlags) -> ManagerSnapshot {
            ManagerSnapshot(profileID: p.id, stored: .init(revision: rev, metaRev: meta, ownerUID: 501), flags: f, onDemandEnabled: false, status: .disconnected)
        }
        #expect(!ProfilesStore.isReplay(p, manager: m(2, 4, flags)))
        #expect(ProfilesStore.isReplay(p, manager: m(2, 5, flags)))
        #expect(ProfilesStore.isReplay(p, manager: m(3, 4, flags)))
        // E2E-1: equal revisions with other flags are drift (macOS rewrote the configuration), not replay.
        let weaker = ProtocolFlags(policy: NetworkPolicy(killSwitch: false), isFullTunnel: true)
        #expect(!ProfilesStore.isReplay(p, manager: m(2, 4, weaker)))
        #expect(ProfilesStore.flagsDrifted(p, manager: m(2, 4, weaker)))
        #expect(!ProfilesStore.flagsDrifted(p, manager: m(2, 4, flags)))
        #expect(!ProfilesStore.flagsDrifted(p, manager: m(2, 5, weaker)))   // a replay is never "drift"
        #expect(!ProfilesStore.isReplay(p, manager: m(1, 3, flags)))      // newer local write: load/start re-save it (H1)
    }

    /// E2E-1 (LP-macOS-26/27): nehelper re-derived the first saved configuration from its SCNetworkService and dropped
    /// includeAllNetworks; the reload quarantined the user's first profile. Now the drift is healed from the metadata.
    @Test func flagDriftAfterSaveIsHealedNotQuarantined() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Home.conf", Harness.wgConf, killSwitch: true)
        h.managers.entries[p.id]?.cfg.flags.includeAllNetworks = false        // the system's rewrite …
        try await h.env.managers.loadAll()                                    // … seen by the notification's reload
        #expect(h.env.profiles.protectionMismatch(p.id))
        await h.env.profiles.load()
        #expect(h.env.profiles.tampered.isEmpty)
        #expect(h.env.profiles.profile(p.id) != nil)
        #expect(h.managers.entries[p.id]?.cfg.flags.includeAllNetworks == true)   // re-saved from the metadata
        #expect(!h.env.profiles.protectionMismatch(p.id))
        // A second drift of the same revision is not re-saved in a loop; it is reported instead.
        h.managers.entries[p.id]?.cfg.flags.includeAllNetworks = false
        try await h.env.managers.loadAll()
        await h.env.profiles.load()
        #expect(h.managers.entries[p.id]?.cfg.flags.includeAllNetworks == false)
        #expect(h.env.profiles.problems.contains { $0.message.contains("protection settings") })
        #expect(h.env.profiles.tampered.isEmpty)
    }

    /// E2E-1, fail closed: when the system keeps dropping the kill switch, Connect is refused; nothing starts.
    @Test func persistentFlagDriftBlocksConnect() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Home.conf", Harness.wgConf, killSwitch: true)
        h.managers.dropIncludeAllNetworksOnSave = true
        h.managers.entries[p.id]?.cfg.flags.includeAllNetworks = false
        await #expect(throws: LPError.self) { try await h.env.profiles.prepareForStart(p) }
        h.env.connection.connect(p.id)
        #expect(await eventually { h.env.connection.observedError?.code == .killSwitchNotApplied })
        #expect(h.managers.starts.isEmpty)
        #expect(h.env.profiles.problems.contains { $0.message.contains("won't connect unprotected") })
        // Once the system keeps the flag again, the same Connect goes through.
        h.managers.dropIncludeAllNetworksOnSave = false
        h.env.connection.connect(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.starts.map(\.0) == [p.id])
        #expect(h.managers.entries[p.id]?.cfg.flags.includeAllNetworks == true)
    }

    /// E2E-1, honest UI: while the configuration lacks the flags, the derived state doesn't claim the kill switch and
    /// the profile shows the repair strip.
    @Test func driftedProfileNeverClaimsTheKillSwitch() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Home.conf", Harness.wgConf, killSwitch: true)
        let i = UIMapping.inputs(profile: p, fallbackName: "", status: .disconnected, observedError: nil, userStoppedSinceError: false,
                                 snapshot: nil, awaitingApproval: false, pausedUntil: nil, readiness: .ready, link: .validated,
                                 switchingTo: nil, protectionMismatch: true, now: Date())
        #expect(!i.killSwitch)
        let ok = UIMapping.inputs(profile: p, fallbackName: "", status: .disconnected, observedError: nil, userStoppedSinceError: false,
                                  snapshot: nil, awaitingApproval: false, pausedUntil: nil, readiness: .ready, link: .validated,
                                  switchingTo: nil, now: Date())
        #expect(ok.killSwitch)
        h.managers.entries[p.id]?.cfg.flags.includeAllNetworks = false
        try await h.env.managers.loadAll()
        UIBinder.render(h.env)
        let item = try #require(h.env.ui.profiles.profile(p.id))
        #expect(item.protectionRepairing && item.killSwitch)
    }

    @Test func reconcilePlan() {
        func prof(_ rev: UInt64, _ digest: String) -> Profile {
            Profile(id: UUID(), name: "P", kind: .wireGuard, policy: NetworkPolicy(killSwitch: false), auth: nil, notes: "",
                    summary: ProfileSummary(), payloadRevision: rev, payloadDigest: digest, metaRevision: 1, ownerUID: 501,
                    createdAt: Date(), updatedAt: Date(), origin: .editor, importReport: nil, engineVerified: true)
        }
        let same = prof(1, "a"), changed = prof(2, "b"), missing = prof(1, "c")
        let orphan = UUID(), queued = UUID()
        let plan = ProfilesStore.reconcilePlan(
            local: [same, changed, missing],
            remote: [ProvisionedEntry(id: same.id, revision: 1, digest: "a"), ProvisionedEntry(id: changed.id, revision: 1, digest: "b0"),
                     ProvisionedEntry(id: orphan, revision: 1, digest: "x")],
            pendingRemovals: [queued])
        #expect(Set(plan.provision) == [changed.id, missing.id])
        #expect(Set(plan.remove) == [orphan, queued])
    }

    @Test func reconcileProvisionsAndRemoves() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        await h.env.profiles.load()
        let orphan = UUID()
        h.service.state.withLock {
            $0.provisioned[p.id] = nil
            $0.provisioned[orphan] = ProvisionedEntry(id: orphan, revision: 1, digest: "x")
        }
        await h.env.profiles.reconcile()
        #expect(h.service.state.withLock { $0.provisioned[p.id]?.revision } == 1)
        #expect(h.service.calls(.removeProfile) == 1)
    }

    @Test func unverifiedOpenVPNProfileCannotConnect() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        h.service.state.withLock { $0.failAll = LPError(.extensionUnavailable) }
        let p = try await h.add("Office.ovpn", PreviewSeed.officeOvpn)
        #expect(!p.engineVerified)
        h.env.connection.connect(p.id)
        try await settle()
        #expect(h.managers.starts.isEmpty)
        #expect(h.env.connection.observedError?.code == .profileInvalid)
    }

    // MARK: Go migration (fixtures only)

    @Test func goMigrationFromAFixtureDirectory() async throws {
        let h = Harness(goSource: { PreviewSeed.GoFixture() })
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        #expect(offer.profileNames == ["old-office"])
        let report = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(report.imported + report.needsAttention == ["old-office"])
        let p = try #require(h.env.profiles.profiles.first)
        #expect(p.origin == .migratedGo("old-office"))
        #expect(p.notes == "from the Go app")
        #expect(p.policy.killSwitch)                                     // Go kill_switch → killSwitch
        #expect(h.env.settings.value.menuBarIconStyle == .color)         // tray_icon_style
        let marker = await h.env.files?.loadMigrationMarker()
        #expect(marker?.items.first?.newID == p.id)
        #expect(await h.env.migrator.detect() == nil)                    // the marker stops automatic runs
        #expect(await h.env.migrator.detect(force: true) == nil)         // manual re-run dedupes by digest
    }
}
