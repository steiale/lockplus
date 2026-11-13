import Foundation
import LPModel
import LPRouteProbe
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// 2.0.2 review round 3 (Fable M1, L2–L4, N4–N6; Codex r3 #2, #4–#8): the app side.
@MainActor @Suite(.timeLimit(.minutes(1))) struct Round3FixTests {
    let r2 = Round2FixTests()

    func relaunch(_ h: Harness) async throws -> Harness { try await r2.relaunch(h) }
    func editSettingsFile(_ h: Harness, _ change: (inout AppSettings) -> Void) async throws { try await r2.editSettingsFile(h, change) }

    func connected(_ h: Harness, _ p: Profile) async {
        let n = h.managers.starts.count
        h.env.connection.connect(p.id)
        _ = await eventually { h.managers.starts.count == n + 1 }
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        _ = await eventually { h.env.connection.statuses[p.id] == .connected }
    }

    // MARK: Fable M1 / Codex r3 #2: the Auto-Connect choice

    /// The first 2.0.2 launch seals the choice whatever it is ("off" included): from then on an untagged enabled choice
    /// is a forgery, never "a choice from before 2.0.2", although the user never turned Auto-Connect on.
    @Test func theFirstLaunchSealsAnOffChoiceSoAForgedOneIsNeverTrusted() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let first = try await relaunch(h)                                  // Auto-Connect off
        await first.env.profiles.awaitAutoConnectSeal()
        #expect(first.env.settings.value.autoConnect.choiceTag != nil)
        let again = try await relaunch(first)                              // repeated launches with it off
        await again.env.profiles.awaitAutoConnectSeal()
        try await editSettingsFile(again) { $0.autoConnect.enabled = true; $0.autoConnect.profileID = work.id; $0.autoConnect.choiceTag = nil }
        let forged = try await relaunch(again)
        #expect(forged.env.profiles.onDemandPlan(for: work) == nil)
        #expect(!forged.env.settings.value.autoConnect.enabled)
        #expect(forged.env.profiles.problems.contains { $0.message.contains("changed outside LockPlus") })
    }

    /// A genuine enabled record copied before the user turned Auto-Connect off doesn't verify after "off": the off state
    /// is sealed and replaced the one-time value.
    @Test func aChoiceCopiedBeforeOffGivesNoPlanAfterIt() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = work.id }
        await h.env.profiles.awaitAutoConnectSeal()
        let copy = h.env.settings.value.autoConnect
        #expect(copy.choiceTag != nil)
        h.env.settings.update { $0.autoConnect.enabled = false }
        await h.env.profiles.awaitAutoConnectSeal()
        #expect(h.env.settings.value.autoConnect.choiceTag != nil && h.env.settings.value.autoConnect.choiceTag != copy.choiceTag)
        try await editSettingsFile(h) { $0.autoConnect = copy }
        let replayed = try await relaunch(h)
        #expect(replayed.env.profiles.onDemandPlan(for: work) == nil)
        #expect(!replayed.env.settings.value.autoConnect.enabled)
    }

    // MARK: Fable L2: one-shot values are spent at every end

    /// A genuine pause record altered at the pause's end (the check fails, nothing reconnects) and written back later
    /// never verifies: the end spent its one-time value whatever the check said.
    @Test func aFailedPauseCheckSpendsTheOneTimeValue() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let a = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let b = try await h.add("Home NAS.conf", Harness.splitConf, killSwitch: false)
        h.env.connection.start()
        await connected(h, a)
        await h.env.connection.pause(minutes: 5)
        let genuine = try #require(h.env.settings.value.pausedState)
        let until = try #require(h.env.settings.value.autoConnect.pausedUntil)
        h.managers.emit(a.id, .disconnected)
        h.env.settings.update { $0.pausedState?.profileID = b.id }        // other code, right before the end
        await h.env.connection.resume().value
        #expect(!h.managers.starts.contains { $0.0 == b.id })
        #expect(await ConnectionStore.checkResumeIntent(genuine, profileID: a.id, until: until, now: Date(),
                                                        repository: h.env.profiles.repository) != .holds)
    }

    /// The same for the extension update's record.
    @Test func aFailedUpdateResumeCheckSpendsTheOneTimeValue() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let q = ManagerQuiescer()
        q.retrySleep = { _ in }
        q.attach(managers: h.managers, settings: h.env.settings, connection: h.env.connection)
        h.env.connection.start()
        await connected(h, work)
        await q.quiesce(reason: .extensionUpdate)
        let genuine = try #require(h.env.settings.value.pendingResume)
        h.env.settings.update { $0.pendingResume?.profileID = UUID() }
        await q.resumeAfterUpdate()
        #expect(await ManagerQuiescer.checkIntent(genuine, profileID: work.id, repository: h.env.profiles.repository, sleep: { _ in }) != .valid)
    }

    // MARK: Codex r3 #4: the network-restart hold is authenticated

    /// Other code writes `networkRestartHold = B` (a saved, disconnected manual kill-switch profile). At launch it is not
    /// accepted as a recovery hold, and a Pause (offline, nothing live) signs nothing for B.
    @Test func aForgedNetworkRestartHoldIsNeverAPauseTarget() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let b = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        try await editSettingsFile(h) { $0.networkRestartHold = b.id; $0.networkRestartHoldTag = nil }
        let h2 = try await relaunch(h)
        let timers = FakeTimers()
        h2.env.connection.timerSleep = timers.sleeper
        h2.env.connection.start()
        #expect(h2.env.connection.unverifiedHold == b.id)                   // entered, not yet verified
        #expect(await eventually { h2.env.connection.unverifiedHold == nil && h2.env.settings.value.networkRestartHold == nil })
        #expect(h2.env.connection.startHold == nil)
        await h2.env.connection.pause(minutes: 5)
        #expect(h2.env.settings.value.pausedState?.profileID == nil && h2.env.settings.value.pausedState?.intent == nil)
    }

    /// While the hold's record can't be checked (keychain unavailable) it holds the restore back but is no pause target.
    @Test func anUncheckedHoldIsNeverSigned() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let b = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        try await editSettingsFile(h) { $0.networkRestartHold = b.id; $0.networkRestartHoldTag = "00" }
        let h2 = try await relaunch(h)
        h2.env.connection.timerSleep = FakeTimers().sleeper
        h.keychain.failure.withLock { $0 = -25308 }
        h2.env.connection.start()
        #expect(h2.env.connection.unverifiedHold == b.id)
        #expect(h2.env.connection.startHold?.profile == b.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h2.env.connection.unverifiedHold == b.id)                   // unchecked: still held, still unverified
        await h2.env.connection.pause(minutes: 5)
        h.keychain.failure.withLock { $0 = nil }
        #expect(h2.env.settings.value.pausedState?.profileID == nil && h2.env.settings.value.pausedState?.intent == nil)
    }

    // MARK: Codex r3 #8: more than one page

    @Test func moreThan500KeptProfilesAreSentAsOneBatchOfPages() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        let held = Set((0..<700).map { _ in UUID() })
        h.env.profiles.revocationHeld = { held }
        await h.env.profiles.revokeUnattended()
        let sent = h.service.state.withLock { $0.revokeRequests }
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.pageCount == 2 && $0.batch != nil && $0.batch == sent[0].batch && $0.isWireValid })
        #expect(Set(sent.flatMap(\.keepProfileIDs)) == held)
    }

    // MARK: Fable L3: quarantine and reconcile

    /// A connected kill-switch profile whose metadata fails its MAC: quarantined, and still reported at the next loads;
    /// reconcile never removes its extension copy. Its Delete removes the quarantined copy too.
    @Test func aQuarantineIsDurableAndReconcileKeepsTheCopy() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        await h.env.profiles.load()
        await h.env.profiles.reconcile()
        #expect(h.service.state.withLock { $0.provisioned[p.id] } != nil)
        await h.env.profiles.repository.quarantine(p.id)
        await h.env.profiles.load()
        await h.env.profiles.load()
        #expect(h.env.profiles.tampered == [p.id])
        let removals = h.service.calls(.removeProfile)
        await h.env.profiles.reconcile()
        #expect(h.service.calls(.removeProfile) == removals)
        await h.env.profiles.delete(p.id)
        await h.env.profiles.load()
        #expect(h.env.profiles.tampered.isEmpty)
    }

    /// An extension copy with no local profile (so reconcile would remove it) whose session is live or held is queued,
    /// and removed once it is idle.
    @Test func reconcileDefersTheRemovalOfALiveProfile() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        h.env.profiles.extensionCapabilities = [.startAuthorisation]
        await h.env.profiles.load()
        let orphan = UUID()
        h.service.state.withLock { $0.provisioned[orphan] = ProvisionedEntry(id: orphan, revision: 1, digest: "d") }
        h.env.profiles.revocationHeld = { [orphan] }
        let removals = h.service.calls(.removeProfile)
        await h.env.profiles.reconcile()
        #expect(h.service.calls(.removeProfile) == removals)
        #expect(h.env.settings.value.pendingRemovals == [orphan])
        h.env.profiles.revocationHeld = { [] }
        await h.env.profiles.reconcile()
        #expect(h.service.calls(.removeProfile) == removals + 1)
        #expect(h.env.settings.value.pendingRemovals.isEmpty)
    }

    // MARK: Fable N6

    /// Verified by a pass that ran before provisioning was allowed (the launch's un-awaited pass): installed by the first
    /// reconcile's own pass, not at the next reconcile.
    @Test func aProfileVerifiedBeforeProvisioningIsInstalledByTheFirstReconcile() async throws {
        let v = FakeProfileValidator()
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        v.outcome = .fails(LPError(.extensionUnavailable))
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        let p = try await h.env.profiles.create(try #require(h.env.importer.draft(a, name: "Office", killSwitch: false, allowLAN: false)))
        v.outcome = .accepted(autologin: true)
        await h.env.profiles.verifyPending()                               // the launch's pass: verified, not installed
        #expect(h.env.profiles.profile(p.id)?.engineVerified == true)
        #expect(h.service.state.withLock { $0.provisioned[p.id] } == nil)
        await h.env.profiles.verifyPending(provisionVerified: true)        // the first reconcile's
        #expect(h.service.state.withLock { $0.provisioned[p.id] } != nil)
    }

    // MARK: Fable L4, N5; Codex r3 #7: imports

    func write(_ h: Harness, _ name: String, _ text: String) throws -> URL {
        let u = h.dir.url.appending(path: name)
        try Data(text.utf8).write(to: u)
        return u
    }

    /// Hung reads run on the import queue, never the cooperative pool, and at most `maxHungReads` of them are left
    /// running: a further read is refused at once.
    @Test func hungReadsAreBoundedAndOffThePool() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let u = try write(h, "Work.conf", Harness.wgConf)
        let gate = DispatchSemaphore(value: 0)
        let reads = Mutex(0)
        let importer = h.env.importer
        importer.readTimeout = .milliseconds(50)
        importer.readFile = { _ in reads.withLock { $0 += 1 }; gate.wait(); return .unreadable }
        for _ in 0..<(ImportCoordinator.maxHungReads + 2) {
            importer.importFiles([u])
            await importer.idle()
        }
        #expect(importer.hungReads == ImportCoordinator.maxHungReads)
        #expect(reads.withLock { $0 } == ImportCoordinator.maxHungReads)
        for _ in 0..<ImportCoordinator.maxHungReads { gate.signal() }
        #expect(await eventually { importer.hungReads == 0 })
        importer.readFile = { ImportCoordinator.readChosen($0) }
        importer.importFiles([u])
        #expect(await eventually { h.env.ui.importer.preview?.fileName == "Work.conf" })
    }

    /// A burst of open events delivered before any of their tasks runs: one import runs, the rest queue against the cap.
    @Test func aBurstOfOpenEventsReservesTheSlotSynchronously() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let u = try write(h, "Work.conf", Harness.wgConf)
        let importer = h.env.importer
        for _ in 0..<(ImportCoordinator.maxQueuedOpenEvents + 4) { importer.importOpened([u]) }    // no yield in between
        #expect(importer.analysing == 1)
        #expect(importer.queuedOpenEvents == ImportCoordinator.maxQueuedOpenEvents)
    }

    /// An opened import that started first still waits for the user's own import begun during its analysis: the user's
    /// preview is shown first, the opened one after it is dismissed.
    @Test func anOpenedImportWaitsForTheUsersLaterAnalysis() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let theirs = try write(h, "Theirs.ovpn", PreviewSeed.officeOvpn)
        let mine = try write(h, "Mine.conf", Harness.wgConf)
        let importer = h.env.importer
        let release = DispatchSemaphore(value: 0)
        importer.readFile = { url in
            if url.lastPathComponent == "Mine.conf" { release.wait() }
            return ImportCoordinator.readChosen(url)
        }
        h.validator.beforeAnswer.withLock { $0 = { @MainActor in
            h.validator.beforeAnswer.withLock { $0 = nil }
            importer.importFiles([mine])                                   // the user's import, mid-analysis of theirs
        } }
        importer.importOpened([theirs])
        #expect(await eventually { importer.analysing == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.env.ui.importer.preview == nil)                          // theirs waits for mine
        release.signal()
        #expect(await eventually { h.env.ui.importer.preview?.fileName == "Mine.conf" })
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.env.ui.importer.preview?.fileName == "Mine.conf")
        importer.cancel()
        #expect(await eventually { h.env.ui.importer.preview?.fileName == "Theirs.ovpn" })
    }

    // MARK: Codex r3 #5, #6: self-test evidence

    final class Net: SelfTestNetworking, @unchecked Sendable {
        var v6: ProbeFetch
        var defaultV6: RouteProbe.RouteLookup = .noRoute
        var routes: [String: RouteProbe.RouteLookup] = [:]
        init(v6: ProbeFetch) { self.v6 = v6 }
        func fetchProbe(_ family: IPFamily, url: URL, timeout: Duration) async -> ProbeFetch {
            family == .v4 ? ConnectionSelfTestTests.ok(from: ConnectionSelfTestTests.tunnelV4, on: "utun4") : v6
        }
        func interface(forIP ip: String) -> String? { ip == "10.8.0.1" ? "utun4" : nil }
        func routeLookup(forIP ip: String) -> RouteProbe.RouteLookup { routes[ip] ?? .noRoute }
        func interfaces(owningAddress ip: String) -> [String] { ip == ConnectionSelfTestTests.tunnelV4 ? ["utun4"] : [] }
        func hasDefaultRoute(_ family: IPFamily, excludingTunnels: Bool) -> Bool { if case .via(let i) = defaultV6 { !i.hasPrefix("utun") } else { false } }
        func defaultRouteLookup(_ family: IPFamily) -> RouteProbe.RouteLookup { defaultV6 }
    }

    /// #5, the real sequence: waiting (no path) → preparing on en0 (TCP may be under way) → TLS stalls → timeout. The
    /// stale "no path" is gone, and the timeout is inconclusive, never "blocked" (green).
    @Test func aTimeoutAfterAnAttemptIsNeverBlocked() async {
        var e = ProbeEvidence()
        e.waited(.noPath, error: "no path", remote: nil)
        e.preparing(pathUsable: true, remote: "2001:db8::77")
        e.waited(.noPath, error: "no path again", remote: nil)              // a later wait doesn't bring the evidence back
        let f = e.timedOut()
        #expect(f.attempted && f.failure == nil && f.timedOut && !f.ready)
        #expect(ConnectionSelfTest.classify(f, family: .v6, facts: ConnectionSelfTestTests.facts(), hasPhysicalDefault: false) != .blocked)
        #expect(ConnectionSelfTest.classify(f, family: .v6, facts: ConnectionSelfTestTests.facts(), hasPhysicalDefault: false) != .noIPv6Here)
        let net = Net(v6: f)
        let report = await ConnectionSelfTest.run(facts: ConnectionSelfTestTests.facts(), dns: (.ok, ConnectionSelfTestTests.resolvers), net: net)
        #expect(report.ipv6 != .blocked && report.overall != .ok)
        // A failure after the attempt is no local refusal either.
        #expect(e.failedBeforeReady(.noPath) == .other)
        // Without an attempt (the first `.preparing` has no usable path), "no path" still counts.
        var plain = ProbeEvidence()
        plain.preparing(pathUsable: false, remote: nil)
        plain.waited(.noPath, error: "no path", remote: nil)
        #expect(plain.timedOut().failure == .noPath && !plain.timedOut().attempted)
        #expect(ConnectionSelfTest.classify(plain.timedOut(), family: .v6, facts: ConnectionSelfTestTests.facts(), hasPhysicalDefault: true) == .blocked)
    }

    /// #6: an IPv4-only full tunnel with Block IPv6: the default route points at the utun (the blackhole), but the attempted
    /// destination routes out en0 (a LAN on-link prefix): never "no IPv6 here"; a failed lookup is uncertainty too.
    @Test func theDefaultRouteNeverOverridesDestinationEvidence() async {
        let dest = "2001:db8::77"
        let facts = ConnectionSelfTestTests.facts(ks: false, block: true)
        for fetch in [ProbeFetch(error: "timed out", timedOut: true, remoteAddress: dest),
                      ProbeFetch(error: "unreachable", failure: .unreachable, remoteAddress: dest)] {
            let net = Net(v6: fetch)
            net.defaultV6 = .via("utun4")
            net.routes = [dest: .via("en0")]
            let r = await ConnectionSelfTest.run(facts: facts, dns: (.ok, ConnectionSelfTestTests.resolvers), net: net)
            #expect(r.ipv6 != .noIPv6Here && r.ipv6 != .blocked && r.overall != .ok)
            net.routes = [dest: .failed]
            #expect(await ConnectionSelfTest.run(facts: facts, dns: (.ok, ConnectionSelfTestTests.resolvers), net: net).ipv6 != .noIPv6Here)
            net.routes = [:]
            net.defaultV6 = .failed                                        // the default lookup failed: unknown, not absent
            #expect(await ConnectionSelfTest.run(facts: facts, dns: (.ok, ConnectionSelfTestTests.resolvers), net: net).ipv6 != .noIPv6Here)
        }
        // Proven absent (no default, the destination has no route either, no attempt): "no IPv6 here" stands.
        let none = Net(v6: ProbeFetch(error: "no path", failure: .noPath, remoteAddress: dest))
        #expect(await ConnectionSelfTest.run(facts: ConnectionSelfTestTests.facts(ks: false), dns: (.ok, ConnectionSelfTestTests.resolvers), net: none).ipv6 == .noIPv6Here)
    }

    // MARK: Fable N4

    /// A trigger suppressed during the quiet period is made up once when it ends (a new copy that posted inside it is
    /// still found); never more than one reload per quiet period.
    @Test func aSuppressedUnknownTriggerReloadsOnceAfterTheQuiet() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let fake = FakeSettleClock()
        let inner = FakeVPNManager()
        let m = SerializedVPNManager(inner: inner, settleClock: fake.clock)
        try await m.loadAll()
        var changes = 0
        m.onConfigurationChange = { changes += 1 }
        inner.onUnknownConnectionActive?()
        #expect(await eventually { m.unknownReloads == 1 })                 // nothing new: the quiet begins
        try await Task.sleep(for: .milliseconds(200))                       // (the reload has finished)
        #expect(changes == 0)
        inner.entries[work.id] = h.managers.entries[work.id]               // a real copy appears inside the quiet
        for _ in 0..<20 { inner.onUnknownConnectionActive?() }
        #expect(await eventually { m.unknownReloads == 2 && changes == 1 })  // made up once, when the quiet ended
        try await Task.sleep(for: .milliseconds(100))
        #expect(m.unknownReloads == 2)
    }
}
