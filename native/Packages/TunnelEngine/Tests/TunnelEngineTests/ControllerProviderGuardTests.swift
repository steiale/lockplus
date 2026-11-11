import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// The 2.0.1 start guard (DESIGN §7.2). Phase 0 (2026-11-10, macOS 26.6.2 and 27.2): macOS runs a second LockPlus
/// configuration beside a running one, both providers in the one extension process; the second start displaced the
/// first session while NE kept reporting it Connected. Now a start beside another instance's CURRENT session (or an
/// accepted kill-switch start's reservation) is refused with `.anotherTunnelActive` and leaves it alone, except the
/// kill-switch priority rule (review H1, decided on the incumbent's live protection, Codex final 1) and a duplicate
/// kill-switch configuration of the running kill-switch profile, which waits (final review M1); a stale session (own,
/// stopped, freed or reused instance) is still replaced.
/// Review M4: a time limit, and every start's completion is awaited with a bound that names it (no silent hang).
@Suite(.timeLimit(.minutes(1))) struct ControllerProviderGuardTests {
    /// What `ProcessProviderHost.bind` would have bound, in order.
    final class Binds: Sendable {
        private let s = Mutex<[ProviderToken]>([])
        func record(_ t: ProviderToken) { s.withLock { $0.append(t) } }
        var list: [ProviderToken] { s.withLock { $0 } }
    }

    typealias StartTask = Task<Result<Void, LPTunnelError>, Never>

    struct World {
        let h: Harness
        let binds = Binds()
        /// Profile B: another configuration of the same owner.
        let otherPID = UUID()
        var providers: ProviderInstances { h.controller.providers }

        /// `killSwitch`: profile A (the harness profile) has `includeAllNetworks`, or with `routeProtection` the split
        /// tunnel's `enforceRoutes` (`policy.killSwitch` true, `includeAllNetworks` false).
        /// `latchOther`: profile B has a `.hard` start latch (`.authFailed`), loaded with the state at the controller's init.
        /// `routed`: the controller talks to the production `ProviderHostRouter`; each accepted start binds its own
        /// `FakeHost` (`hosts`) under its instance's identity (`objects`), as `PacketTunnelProvider` does.
        final class Instance: Sendable {}
        final class Registry: Sendable {
            let hosts = Mutex<[ProviderLease: FakeHost]>([:])
            let objects = Mutex<[ProviderToken: Instance]>([:])
        }
        let reg = Registry()
        let routed: Bool

        /// `latchSelf`: profile A has a `.hard` start latch (`.authFailed`) at the controller's init.
        /// `summaries`: that many session summaries of profile B stored at the controller's init (the ring's cap is 100).
        init(killSwitch: Bool = false, routeProtection: Bool = false, latchOther: Bool = false, latchSelf: Bool = false,
             summaries: Int = 0, routed: Bool = false) {
            self.routed = routed
            let other = otherPID
            h = Harness(killSwitch: killSwitch, routeProtection: routeProtection, state: { pid in
                var st = PersistedTunnelState()
                for i in 0..<summaries {
                    let t = Date(timeIntervalSinceReferenceDate: Double(i) * 60)
                    st.sessions.append(.init(ownerUID: 501, summary: SessionSummary(id: UUID(), profileID: other, start: t,
                        end: t.addingTimeInterval(30), rxBytes: 0, txBytes: 0, endReason: "user")))
                }
                if latchSelf {
                    st.latches[ProfileKey(ownerUID: 501, profileID: pid)] =
                        .init(latch: StartLatch(code: .authFailed, kind: .hard, notBefore: nil, revision: 1), interval: nil)
                }
                if latchOther {
                    st.latches[ProfileKey(ownerUID: 501, profileID: other)] =
                        .init(latch: StartLatch(code: .authFailed, kind: .hard, notBefore: nil, revision: 1), interval: nil)
                }
                return st
            }, routed: routed)
        }

        /// A new provider instance whose `startTunnel` was delivered.
        func instance() -> ProviderLease { started(providers.makeToken()) }

        /// `startTunnel` delivered on `t` (again, for a reused instance): published through the router's lifecycle gate,
        /// as `ProviderSeat` does (round 4, Codex 3).
        func started(_ t: ProviderToken) -> ProviderLease {
            let providers = providers
            return h.router.publish(t) { providers.started(t) }
        }

        func provision() async {
            await h.provision()
            try? await h.secrets.put(.payload, otherPID, ownerUID: h.owner, revision: 1, .text(Harness.payload(h.kind)))
            try? await h.secrets.put(.credential, otherPID, ownerUID: h.owner, revision: 1,
                                     CredentialCodec.encode(CredentialSecrets(username: .text("bob"), password: .text("pw"))))
        }

        func config(other: Bool, killSwitch: Bool?) -> ProviderConfiguration {
            var cfg = h.config()
            if other { cfg.profileID = otherPID }
            if let killSwitch { cfg.policy = NetworkPolicy(killSwitch: killSwitch); cfg.includeAllNetworks = killSwitch }
            return cfg
        }

        /// `startTunnel` of `inst` for profile A (`other: false`) or B; `killSwitch` overrides its `includeAllNetworks`.
        func start(_ inst: ProviderLease, other: Bool = false, killSwitch: Bool? = nil, manual: Bool = true,
                   bindSucceeds: Bool = true) -> StartTask {
            start(inst, StartRequest(options: StartOptions(isManual: manual), configuration: config(other: other, killSwitch: killSwitch)),
                  bindSucceeds: bindSucceeds)
        }

        /// The identity of `t`'s provider object (one per instance, reused across its starts).
        func object(_ t: ProviderToken) -> ObjectIdentifier {
            ObjectIdentifier(reg.objects.withLock { o in if let x = o[t] { return x }; let x = Instance(); o[t] = x; return x })
        }

        /// The fake host `lease`'s start was bound with (routed worlds).
        func host(_ lease: ProviderLease) -> FakeHost? { reg.hosts.withLock { $0[lease] } }

        func start(_ inst: ProviderLease, _ req: StartRequest, bindSucceeds: Bool = true) -> StartTask {
            let c = h.controller, binds = binds, router = routed ? h.router : nil, id = object(inst.token), reg = reg
            return Task {
                do throws(LPTunnelError) {
                    try await c.start(req, owner: inst, bind: {
                        binds.record(inst.token)
                        if let router {                                 // routed worlds only (final review N4)
                            let fh = FakeHost()
                            reg.hosts.withLock { $0[inst] = fh }
                            // Round 4 (Codex 3): the router's answer is the provider's (`ProviderRef.bind`).
                            guard router.bind(id: id, lease: inst, host: fh) else { return false }
                        }
                        return bindSucceeds
                    })
                    return .success(())
                } catch { return .failure(error) }
            }
        }

        /// The n-th adapter once started; an Issue (never the harness's crash) when it never starts, with a detached
        /// placeholder whose ticket answers at once (review M4: a regression fails the test, it doesn't kill the run).
        func adapter(_ n: Int) async -> FakeAdapter {
            if await waitUntil({ h.factory.adapters.count > n && h.factory.adapters[n].started }) { return h.factory.adapters[n] }
            Issue.record("adapter \(n) never started")
            return FakeAdapter(kind: h.kind)
        }

        /// Drives `a`'s start to Connected (nothing for a placeholder).
        func finish(_ a: FakeAdapter) async {
            guard a.started else { return }
            let ticket = a.requestSettings(Harness.plan), answered = Mutex(false)
            Task { _ = await ticket.value(); answered.withLock { $0 = true } }
            guard await waitUntil({ answered.withLock { $0 } }) else { Issue.record("settings never applied"); return }
            a.finishStart()
        }

        /// start → settings → data plane up → connected.
        @discardableResult
        func connect(_ inst: ProviderLease, other: Bool = false, killSwitch: Bool? = nil) async -> FakeAdapter {
            let n = h.factory.adapters.count                             // Codex final 7: before the start can make one
            let t = start(inst, other: other, killSwitch: killSwitch)
            let a = await adapter(n)
            await finish(a)
            #expect(code(await value(t, "connect")) == nil)
            #expect(await h.waitPhase(.connected))
            return a
        }

        /// `stopTunnel` of `inst`: marked at once on the provider queue, then the controller's stop.
        func stopTunnel(_ inst: ProviderLease) async {
            providers.stopped(inst.token)
            await h.controller.stop(reason: .userInitiated, owner: inst)
        }

        var otherKey: ProfileKey { ProfileKey(ownerUID: h.owner, profileID: otherPID) }

        /// The start's result, or an Issue naming it when it never completes (review M4).
        func value(_ t: StartTask, _ what: String, within: Duration = .seconds(5)) async -> Result<Void, LPTunnelError>? {
            let box = Mutex<Result<Void, LPTunnelError>?>(nil)
            let waiter = Task { let r = await t.value; box.withLock { $0 = r } }
            let done = await waitUntil(timeout: within) { box.withLock { $0 } != nil }
            if !done { Issue.record("start \"\(what)\" never completed"); waiter.cancel() }
            return box.withLock { $0 }
        }

        func code(_ r: Result<Void, LPTunnelError>?) -> LPErrorCode? {
            guard let r else { return .timeout }                            // a hang reads as a wrong result too
            return h.code(r)
        }
    }

    // MARK: refused beside a live instance

    @Test func aStartBesideAnotherLiveInstancesSessionIsRefusedAndLeavesItAlone() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        let appliedBefore = w.h.host.appliedCount

        let r = await w.value(w.start(b, other: true, manual: false), "B")   // System Settings / scutil: options nil
        #expect(w.code(r) == .anotherTunnelActive)
        #expect(await w.h.phase == .connected)
        #expect(adapterA.stopCount == 0)                                    // A's engine keeps running
        #expect(w.h.factory.adapters.count == 1)                            // B never got an engine
        #expect(w.binds.list == [a.token])                                  // B never bound: A keeps host and packet flow
        #expect(w.h.host.appliedCount == appliedBefore)
        #expect(w.h.host.cancelledCodes.isEmpty)
        #expect(w.h.sink.endedCodes.isEmpty)
        let snap = await w.h.controller.snapshot()
        #expect(snap.profileID == w.h.pid && snap.phase == .connected)
        // B's own error is recorded (the app's freshness check reads it as this attempt's); A's isn't touched.
        #expect(w.h.state.load().lastErrors[w.otherKey]?.error.code == .anotherTunnelActive)
        #expect(w.h.state.load().lastErrors[w.h.key] == nil)
        #expect(w.h.state.load().latches.isEmpty)                           // no latch: B may start once A is down
    }

    @Test func aStartBesideAPendingStartIsRefusedAndThePendingStartStillConnects() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let ta = w.start(a)
        let adapterA = await w.adapter(0)
        #expect(w.code(await w.value(w.start(b, other: true), "B")) == .anotherTunnelActive)
        await w.finish(adapterA)
        #expect(w.code(await w.value(ta, "A")) == nil)
        #expect(await w.h.waitPhase(.connected))
        #expect(w.binds.list == [a.token])
    }

    /// Kill switch against kill switch: first wins. A's held session (blocked by design) is not displaced.
    @Test func aHeldKillSwitchSessionIsNotDisplacedByAnotherKillSwitchStart() async {
        let w = World(killSwitch: true)
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        adapterA.emit { .fatal(LPTunnelError(.peerUnreachable), epoch: $0) }
        #expect(await w.h.waitPhase(.held(.blockedAfterFailure(.peerUnreachable))))
        #expect(w.code(await w.value(w.start(b, other: true), "B")) == .anotherTunnelActive)
        #expect(await w.h.phase == .held(.blockedAfterFailure(.peerUnreachable)))
        #expect(w.h.host.cancelledCodes.isEmpty)
        #expect(w.binds.list == [a.token])
    }

    /// A start without the kill switch beside a kill-switch session is refused (the running one keeps protecting).
    @Test func aSplitStartBesideAKillSwitchSessionIsRefused() async {
        let w = World(killSwitch: true)
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        #expect(w.code(await w.value(w.start(b, other: true, killSwitch: false), "B")) == .anotherTunnelActive)
        #expect(adapterA.stopCount == 0)
        #expect(await w.h.phase == .connected)
    }

    /// Review M4: an on-demand `includeAllNetworks` start beside another kill-switch session, unlatched and latched
    /// (a held latch must not slip past the guard): refused, no engine, no bind.
    @Test(arguments: [false, true])
    func anOnDemandKillSwitchStartBesideAKillSwitchSessionIsRefused(latched: Bool) async {
        // A hard latch on B: with the flag it would be held (no I/O); beside A it is refused instead.
        let w = World(killSwitch: true, latchOther: latched)
        await w.provision()
        // Codex review 7: the latch is in the controller (seeded before its init), not only in the store.
        let latch = await w.h.controller.snapshot(profileID: w.otherPID, ownerUID: w.h.owner).startLatch
        #expect((latch != nil) == latched)
        let a = w.instance(), b = w.instance()
        await w.connect(a)
        #expect(w.code(await w.value(w.start(b, other: true, killSwitch: true, manual: false), "B")) == .anotherTunnelActive)
        #expect(w.h.factory.adapters.count == 1)
        #expect(w.binds.list == [a.token])
        #expect(await w.h.phase == .connected)
    }

    /// NE may call `stopTunnel` on the refused instance: it must not end A's session.
    @Test func theRefusedInstancesStopDoesNotEndTheRunningSession() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        #expect(w.code(await w.value(w.start(b, other: true), "B")) == .anotherTunnelActive)
        await w.stopTunnel(b)
        #expect(await w.h.phase == .connected)
        #expect(adapterA.stopCount == 0)
        #expect(w.h.state.load().sessions.isEmpty)                          // no session summary written for A
    }

    /// Review L4: another instance's sleep or wake never drives this session.
    @Test func anotherInstancesSleepAndWakeAreIgnored() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        await w.h.controller.sleep(owner: b)
        #expect(await w.h.phase == .connected)
        #expect(adapterA.s.withLock { $0.sleeps } == 0)
        await w.h.controller.sleep(owner: a)
        #expect(await w.h.phase == .sleeping)
        await w.h.controller.wake(owner: b)
        #expect(await w.h.phase == .sleeping)
        await w.h.controller.wake(owner: a)
        #expect(await w.h.phase != .sleeping)
    }

    /// Review L3: repeated refusals of one profile write the disk at most once a minute; the snapshot stays current.
    @Test func repeatedRefusalsCoalesceTheirWrite() async {
        let w = World()
        await w.provision()
        let a = w.instance()
        await w.connect(a)
        #expect(w.code(await w.value(w.start(w.instance(), other: true, manual: false), "B1")) == .anotherTunnelActive)
        let first = w.h.state.load().lastErrors[w.otherKey]?.at
        w.h.wall.advance(10)
        #expect(w.code(await w.value(w.start(w.instance(), other: true, manual: false), "B2")) == .anotherTunnelActive)
        #expect(w.h.state.load().lastErrors[w.otherKey]?.at == first)       // not written again
        let snap = await w.h.controller.snapshot(profileID: w.otherPID, ownerUID: w.h.owner)
        #expect(snap.lastErrorAt == first.map { $0.addingTimeInterval(10) })  // but current in memory
        w.h.wall.advance(60)
        #expect(w.code(await w.value(w.start(w.instance(), other: true, manual: false), "B3")) == .anotherTunnelActive)
        #expect(w.h.state.load().lastErrors[w.otherKey]?.at == first.map { $0.addingTimeInterval(70) })
    }

    // MARK: kill-switch priority (review H1)

    /// A kill-switch start beside a connected split session: the split session is torn down and ITS provider cancelled
    /// with `.supersededByKillSwitch`; then the kill-switch start is bound and connects.
    @Test func aKillSwitchStartEndsAConnectedSplitSessionVisiblyAndConnects() async {
        let w = World()                                                     // A: split, no kill switch
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        let adapterK = await w.connect(k, other: true, killSwitch: true)
        #expect(adapterA.stopCount == 1)
        #expect(w.h.host.cancelledCodes == [.supersededByKillSwitch])
        #expect(w.h.host.cancelledOwners == [a])                            // A's own provider, not K's
        #expect(w.binds.list == [a.token, k.token])
        #expect(adapterK.stopCount == 0)
        let snap = await w.h.controller.snapshot()
        #expect(snap.profileID == w.otherPID && snap.phase == .connected)
        #expect(w.h.state.load().lastErrors[w.h.key]?.error.code == .supersededByKillSwitch)
        #expect(w.h.state.load().sessions.last?.summary.endReason == "superseded by a kill-switch profile")
    }

    /// The same beside a split start that is still pending: that start fails with the code (no cancel needed).
    @Test func aKillSwitchStartFailsAPendingSplitStart() async {
        let w = World()
        await w.provision()
        let a = w.instance(), k = w.instance()
        let ta = w.start(a)
        _ = await w.adapter(0)
        await w.connect(k, other: true, killSwitch: true)
        #expect(w.code(await w.value(ta, "A")) == .supersededByKillSwitch)
        #expect(w.h.host.cancelledCodes.isEmpty)
        #expect(w.binds.list == [a.token, k.token])
    }

    /// An on-demand kill-switch start (NE's restart of K) beside a split session gets in too.
    @Test func anOnDemandKillSwitchStartEndsASplitSession() async {
        let w = World()
        await w.provision()
        let a = w.instance(), k = w.instance()
        await w.connect(a)
        let tk = w.start(k, other: true, killSwitch: true, manual: false)
        await w.finish(await w.adapter(1))
        #expect(w.code(await w.value(tk, "K")) == nil)
        #expect(w.h.host.cancelledOwners == [a])
    }

    /// Test gap: a route-protection session (`policy.killSwitch` true, `includeAllNetworks` false) yields too.
    @Test func aKillSwitchStartEndsARouteProtectionSession() async {
        let w = World(killSwitch: true, routeProtection: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        await w.connect(k, other: true, killSwitch: true)
        #expect(adapterA.stopCount == 1)
        #expect(w.h.host.cancelledCodes == [.supersededByKillSwitch])
        #expect(w.h.host.cancelledOwners == [a])
        #expect(w.binds.list == [a.token, k.token])
    }

    /// Test gap: a split (route-protection) session held after Connected yields to a kill-switch start.
    @Test func aKillSwitchStartEndsAHeldSplitSession() async {
        let w = World(killSwitch: true, routeProtection: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        adapterA.emit { .fatal(LPTunnelError(.peerUnreachable), epoch: $0) }
        #expect(await w.h.waitPhase(.held(.blockedAfterFailure(.peerUnreachable))))
        await w.connect(k, other: true, killSwitch: true)
        #expect(w.h.host.cancelledCodes == [.supersededByKillSwitch])
        #expect(w.h.host.cancelledOwners == [a])
        let snap = await w.h.controller.snapshot()
        #expect(snap.profileID == w.otherPID && snap.phase == .connected)
    }

    /// Codex final 3: starts arriving during the preemption's teardown meet the kill-switch start's reservation and are
    /// refused (none gets the slot), however many arrive; the kill-switch start then runs. Bounded progress: one
    /// teardown, one cancel, one bind for K.
    @Test func sustainedStartsDuringThePreemptionAreRefusedAndTheKillSwitchStartRuns() async {
        let w = World()
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        let tk = w.start(k, other: true, killSwitch: true)
        #expect(await waitUntil { adapterA.stopCount == 1 })                // K waits in A's teardown
        for i in 0..<6 {                                                    // split and kill-switch interlopers alike
            let r = await w.value(w.start(w.instance(), killSwitch: i % 2 == 1, manual: false), "interloper \(i)")
            #expect(w.code(r) == .anotherTunnelActive)
        }
        #expect(w.binds.list == [a.token])
        #expect(w.h.factory.adapters.count == 1)
        adapterA.releaseStop()
        await w.finish(await w.adapter(1))
        #expect(w.code(await w.value(tk, "K")) == nil)
        #expect(w.h.host.cancelledOwners == [a])
        #expect(w.binds.list == [a.token, k.token])
        #expect(await w.h.phase == .connected)
        // The reservation ended with K's acceptance: K's own session now refuses a split start as usual.
        #expect(w.code(await w.value(w.start(w.instance()), "after")) == .anotherTunnelActive)
    }

    /// Re-check L3: a kill-switch start NE stopped before its Task ran ends nothing.
    @Test func aKillSwitchStartStoppedBeforeItRunsLeavesTheSplitSessionAlone() async {
        let w = World()
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        w.providers.stopped(k.token)                                        // `scutil --nc start K; scutil --nc stop K`
        #expect(w.code(await w.value(w.start(k, other: true, killSwitch: true), "K")) == .startCancelled)
        #expect(adapterA.stopCount == 0)
        #expect(await w.h.phase == .connected)
        #expect(w.h.host.cancelledCodes.isEmpty)
        #expect(w.binds.list == [a.token])
    }

    /// Re-check L3: stopped during the preemption's teardown: K never binds or runs.
    @Test func aKillSwitchStartStoppedDuringThePreemptionNeverRuns() async {
        let w = World()
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        let tk = w.start(k, other: true, killSwitch: true)
        #expect(await waitUntil { adapterA.stopCount == 1 })
        w.providers.stopped(k.token)
        adapterA.releaseStop()
        #expect(w.code(await w.value(tk, "K")) == .startCancelled)
        #expect(w.binds.list == [a.token])
        #expect(w.h.factory.adapters.count == 1)
        #expect(await w.h.phase == .idle)
    }

    /// Test gap: a latched on-demand kill-switch start preempts a split session, then is held with no I/O.
    @Test func aLatchedOnDemandKillSwitchStartPreemptsAndIsHeld() async {
        let w = World(latchOther: true)
        await w.provision()
        #expect(await w.h.controller.snapshot(profileID: w.otherPID, ownerUID: w.h.owner).startLatch?.kind == .hard)
        let a = w.instance(), k = w.instance()
        await w.connect(a)
        _ = w.start(k, other: true, killSwitch: true, manual: false)
        #expect(await w.h.waitPhase(.held(.nonRetryable(.authFailed))))
        #expect(w.h.host.cancelledOwners == [a])
        #expect(w.binds.list == [a.token, k.token])
        #expect(w.h.factory.adapters.count == 1)                            // no engine for the held start
    }

    /// Re-check N3: a start whose `providerConfiguration` didn't parse still carries the protocol's `includeAllNetworks`:
    /// it has kill-switch priority and is held (closed), not failed (open).
    @Test func anUnparsedKillSwitchStartKeepsPriorityAndIsHeld() async {
        let w = World()
        await w.provision()
        let a = w.instance(), k = w.instance()
        await w.connect(a)
        var req = StartRequest(options: StartOptions(isManual: false), configuration: nil)
        req.protocolIncludeAllNetworks = true
        _ = w.start(k, req)
        #expect(await w.h.waitPhase(.held(.nonRetryable(.profileInvalid))))
        #expect(w.h.host.cancelledOwners == [a])
    }

    /// Re-check N1: a late stop that is ignored (another instance's session now runs) still waits for its own engine's
    /// teardown, even though that start's own replace began awaiting it first.
    @Test func anIgnoredLateStopWaitsForItsEnginesTeardown() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        w.providers.stopped(a.token)
        let tb = w.start(b, other: true)                                    // replaces A's stale session, awaits its stop
        #expect(await waitUntil { adapterA.stopCount == 1 })
        let done = Mutex(false)
        let c = w.h.controller
        let lateStop = Task { await c.stop(reason: .userInitiated, owner: a); done.withLock { $0 = true } }
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { done.withLock { $0 } }))
        adapterA.releaseStop()
        #expect(await waitUntil { done.withLock { $0 } })
        await lateStop.value
        await w.finish(await w.adapter(1))
        #expect(w.code(await w.value(tb, "B")) == nil)
    }

    // MARK: ProviderBindings (ProcessProviderHost's bookkeeping, re-check L2, N2)

    @Test func bindingsCancelAndUnbindOnlyTheirOwnStart() {
        final class Obj {}
        let p = ProviderInstances()
        let o1 = Obj(), o2 = Obj()
        let t1 = p.makeToken(), t2 = p.makeToken()
        let l1 = p.started(t1), l2 = p.started(t2)
        var b = ProviderBindings<String>()
        b.bind(id: ObjectIdentifier(o1), lease: l1, host: "A1")
        #expect(b.host(for: l1) == "A1" && b.currentHost == "A1" && b.host(for: nil) == "A1")
        #expect(b.host(for: l2) == nil)                                     // N2: an owner not in the map is nil, not current
        b.bind(id: ObjectIdentifier(o2), lease: l2, host: "B")
        #expect(b.currentHost == "B" && b.host(for: l1) == "A1")            // M1: A's own host stays for its late cancel

        // L2: the instance o1 is reused (generation 2) and bound again before generation 1's cancel or unbind.
        p.stopped(t1)
        let l1b = p.started(t1)
        b.bind(id: ObjectIdentifier(o1), lease: l1b, host: "A2")
        #expect(b.host(for: l1) == nil)                                     // the late cancel never reaches the newer start
        #expect(b.host(for: l1b) == "A2")
        let lateUnbind = b.unbind(id: ObjectIdentifier(o1), lease: l1)
        #expect(!lateUnbind)                                                // the late unbind leaves the newer start bound
        #expect(b.currentHost == "A2" && b.host(for: l1b) == "A2")
        let ownUnbind = b.unbind(id: ObjectIdentifier(o1), lease: l1b)
        #expect(ownUnbind)
        #expect(b.currentHost == nil && b.host(for: l1b) == nil)
        #expect(b.host(for: l2) == "B")
        let freed = b.release(id: ObjectIdentifier(o2), token: t2)
        #expect(!freed)                                                     // freed: not current, but its entry goes
        #expect(b.host(for: l2) == nil)
    }

    @Test func bindingsReleaseClearsCurrent() {
        final class Obj {}
        let p = ProviderInstances(), o = Obj(), t = p.makeToken()
        var b = ProviderBindings<Int>()
        b.bind(id: ObjectIdentifier(o), lease: p.started(t), host: 1)
        let wasCurrent = b.release(id: ObjectIdentifier(o), token: t)
        #expect(wasCurrent)
        #expect(b.currentHost == nil)
    }

    // MARK: stale sessions are still replaced

    /// The same instance starting again (NE reusing the provider after a cancel): its own session is torn down first.
    @Test func theSameInstancesOwnSessionIsReplaced() async {
        let w = World()
        await w.provision()
        let a1 = w.instance()
        let first = await w.connect(a1)
        let a2 = w.started(a1.token)                              // the same instance, a new startTunnel
        let second = await w.connect(a2)
        #expect(first.stopCount == 1)
        #expect(second.started)
        #expect(w.binds.list == [a1.token, a1.token])
        #expect(w.h.state.load().sessions.count == 1)                       // the first session's summary
        #expect(w.h.state.load().sessions[0].summary.endReason == "superseded")
    }

    /// Codex review 3: two distinct configurations sharing one profile key (a duplicate, `ManagerClassifier`), the
    /// incumbent live with the kill switch, the duplicate without it: refused. Key equality never overrides a live lease.
    @Test func aDuplicateConfigurationsSplitStartBesideALiveKillSwitchSessionIsRefused() async {
        let w = World(killSwitch: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()                            // two configurations, two instances
        let first = await w.connect(a1)
        #expect(w.code(await w.value(w.start(a2, killSwitch: false), "A2")) == .anotherTunnelActive)
        #expect(first.stopCount == 0)
        #expect(await w.h.phase == .connected)
        #expect(w.binds.list == [a1.token])
        #expect(w.h.host.cancelledCodes.isEmpty)
    }

    /// Codex review 3: a duplicate configuration without the kill switch beside a live split session of the same
    /// profile: first wins (refused), like any other profile.
    @Test func aDuplicateConfigurationsSplitStartBesideALiveSplitSessionIsRefused() async {
        let w = World()
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let first = await w.connect(a1)
        #expect(w.code(await w.value(w.start(a2), "A2")) == .anotherTunnelActive)
        #expect(first.stopCount == 0)
        #expect(w.h.host.cancelledCodes.isEmpty)
    }

    /// Codex review 3: the normal kill-switch priority applies between duplicates too: a kill-switch duplicate ends a
    /// live split session of the same profile visibly (its own provider cancelled with 223).
    @Test func aKillSwitchDuplicateEndsALiveSplitSessionOfTheSameProfile() async {
        let w = World()
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let first = await w.connect(a1)
        await w.connect(a2, killSwitch: true)
        #expect(first.stopCount == 1)
        #expect(w.h.host.cancelledCodes == [.supersededByKillSwitch])
        #expect(w.h.host.cancelledOwners == [a1])
    }

    /// Codex review 3: the same profile's incumbent is replaced once its lease is no longer current (NE stopped it).
    @Test func theSameProfilesStoppedIncumbentIsReplaced() async {
        let w = World(killSwitch: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let first = await w.connect(a1)
        w.providers.stopped(a1.token)
        let second = await w.connect(a2)
        #expect(first.stopCount == 1)
        #expect(second.started)
        #expect(w.h.host.cancelledCodes.isEmpty)
        await w.h.controller.stop(reason: .userInitiated, owner: a1)        // its late stop
        #expect(await w.h.phase == .connected)
        #expect(second.stopCount == 0)
    }

    // MARK: Final review M1: a duplicate kill-switch configuration waits (closed), never fails (open)

    /// A duplicate kill-switch configuration's start beside the running kill-switch session of the same profile stays
    /// pending, bound to nothing, with no engine; it proceeds when the incumbent's instance stops.
    @Test func aDuplicateKillSwitchStartWaitsAndProceedsAfterTheIncumbentStops() async {
        let w = World(killSwitch: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let first = await w.connect(a1)
        let t2 = w.start(a2)
        #expect(!(await waitUntil(timeout: .milliseconds(300)) { w.h.factory.adapters.count > 1 }))
        #expect(w.binds.list == [a1.token])
        #expect(first.stopCount == 0)
        #expect(await w.h.phase == .connected)
        await w.stopTunnel(a1)                                              // the incumbent's own stop
        await w.finish(await w.adapter(1))
        #expect(w.code(await w.value(t2, "A2")) == nil)
        #expect(w.binds.list == [a1.token, a2.token])
        #expect(w.h.host.cancelledCodes.isEmpty)
    }

    /// The waiting start's own stop ends it cleanly (`.startCancelled`); the incumbent is untouched.
    @Test func aStopOfTheWaitingStartEndsIt() async {
        let w = World(killSwitch: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let first = await w.connect(a1)
        let t2 = w.start(a2)
        try? await Task.sleep(for: .milliseconds(50))
        await w.stopTunnel(a2)
        #expect(w.code(await w.value(t2, "A2")) == .startCancelled)
        #expect(first.stopCount == 0)
        #expect(await w.h.phase == .connected)
        #expect(w.binds.list == [a1.token])
    }

    /// An incumbent instance NE abandoned (never stopped, never freed) keeps the duplicate's start pending: closed, no
    /// engine, nothing bound. Its release (deinit) lets it proceed.
    @Test func anAbandonedIncumbentKeepsTheDuplicatePendingUntilReleased() async {
        let w = World(killSwitch: true)
        await w.provision()
        let seatA = ProviderSeat(controller: w.h.controller)
        let doneA = Mutex(false)
        seatA.startTunnel(StartRequest(options: StartOptions(isManual: true), configuration: w.config(other: false, killSwitch: nil)),
                          bind: { _ in true }) { _ in doneA.withLock { $0 = true } }
        await w.finish(await w.adapter(0))
        #expect(await waitUntil { doneA.withLock { $0 } })
        let a2 = w.instance()
        let t2 = w.start(a2)
        #expect(!(await waitUntil(timeout: .milliseconds(500)) { w.h.factory.adapters.count > 1 }))
        #expect(w.binds.list.isEmpty)                                       // (the seat's own bind isn't recorded)
        #expect(await w.h.phase == .connected)
        seatA.released()                                                    // NE frees it at last
        await w.finish(await w.adapter(1))
        #expect(w.code(await w.value(t2, "A2")) == nil)
    }

    // MARK: Codex final 1: the incumbent's live protection decides

    /// A split session whose configuration got `includeAllNetworks` while connected (U7: enforced at once) is not
    /// preempted: a kill-switch start beside it is refused (first wins).
    @Test func aSessionProtectedSinceItStartedIsNotPreempted() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        w.host(a)?.setIncludeAllNetworks(true)
        #expect(w.code(await w.value(w.start(k, other: true, killSwitch: true), "K")) == .anotherTunnelActive)
        #expect(adapterA.stopCount == 0)
        #expect(w.host(a)?.cancelledCodes == [])
        #expect(await w.h.phase == .connected)
    }

    /// A kill-switch session whose configuration lost `includeAllNetworks` while connected no longer protects: a
    /// kill-switch start preempts it (a stale "true" never refuses a genuine kill-switch start).
    @Test func aSessionUnprotectedSinceItStartedIsPreempted() async {
        let w = World(killSwitch: true, routed: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        w.host(a)?.setIncludeAllNetworks(false)
        await w.connect(k, other: true, killSwitch: true)
        #expect(adapterA.stopCount == 1)
        #expect(w.host(a)?.cancelledCodes == [.supersededByKillSwitch])
    }

    // MARK: Codex final 2: retired at startTunnel, before the bind

    // MARK: Round 3, Codex 4: a vetoed cancel keeps the session tracked

    /// The incumbent got `includeAllNetworks` during its preemption's teardown: it is not cancelled (that would be open)
    /// and not left untracked: it is HELD (closed), the snapshot shows it, and the kill-switch start re-decides against
    /// it (another profile, both kill switch: refused). Once A is stopped, K can start.
    @Test func aSessionProtectedDuringItsTeardownIsHeldAndTheStartReDecides() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        let tk = w.start(k, other: true, killSwitch: true)
        #expect(await waitUntil { adapterA.stopCount == 1 })
        #expect(await w.h.phase == .stopping)                                // still tracked during the teardown
        w.host(a)?.setIncludeAllNetworks(true)
        adapterA.releaseStop()
        #expect(w.code(await w.value(tk, "K")) == .anotherTunnelActive)
        #expect(await w.h.phase == .held(.blockedAfterFailure(.sessionInterrupted)))
        let snap = await w.h.controller.snapshot()
        #expect(snap.profileID == w.h.pid)
        #expect(w.host(a)?.cancelledCodes == [])
        #expect(w.host(a)?.lastReasserting == true)
        #expect(w.binds.list == [a.token])
        await w.stopTunnel(a)
        #expect(await w.h.phase == .idle)
        await w.connect(w.instance(), other: true, killSwitch: true)
    }

    // MARK: Round 3, Codex 1: every hold-vs-cancel decision reads the live protection

    /// The kill switch enabled live on a split session, then an engine fatal: held, never cancelled.
    @Test func aKillSwitchEnabledLiveHoldsOnAFatal() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance()
        let adapterA = await w.connect(a)
        w.host(a)?.setIncludeAllNetworks(true)
        adapterA.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await w.h.waitPhase(.held(.blockedAfterFailure(.engineFatal))))
        #expect(w.host(a)?.cancelledCodes == [])
    }

    /// Route protection (`enforceRoutes`) enabled live counts as the kill switch too.
    @Test func routeProtectionEnabledLiveHoldsOnAFatal() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance()
        let adapterA = await w.connect(a)
        w.host(a)?.setProtection(ProviderProtection(includeAllNetworks: false, enforceRoutes: true))
        adapterA.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await w.h.waitPhase(.held(.blockedAfterFailure(.engineFatal))))
        #expect(w.host(a)?.cancelledCodes == [])
    }

    /// The kill switch enabled live DURING a fatal's teardown: the cancel is vetoed, the session held and tracked.
    @Test func aKillSwitchEnabledDuringAFatalsTeardownHolds() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        adapterA.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await w.h.waitPhase(.stopping))
        w.host(a)?.setIncludeAllNetworks(true)
        adapterA.releaseStop()
        #expect(await w.h.waitPhase(.held(.blockedAfterFailure(.engineFatal))))
        #expect(w.host(a)?.cancelledCodes == [])
        #expect(await w.h.controller.snapshot().profileID == w.h.pid)
    }

    /// Without the flag the fatal still cancels after the teardown (control), on the session's own provider; a start of
    /// another instance during that teardown waits for it (the session is still tracked), then runs.
    @Test func aStartDuringAFatalsTeardownWaitsThenRuns() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        adapterA.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await w.h.waitPhase(.stopping))
        let tb = w.start(b, other: true)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.h.factory.adapters.count > 1 }))
        #expect(w.h.host.cancelledCodes.isEmpty)
        adapterA.releaseStop()
        #expect(await waitUntil { w.h.host.cancelledCodes == [.engineFatal] })
        #expect(w.h.host.cancelledOwners == [a])
        await w.finish(await w.adapter(1))
        #expect(w.code(await w.value(tb, "B")) == nil)
        #expect(w.binds.list == [a.token, b.token])
    }

    // MARK: Round 4 (Fable L3): finishEnding's guard and wake, the seat's protection wiring

    /// The session's own stop arrives during a fatal's teardown and a new start (another instance) runs meanwhile: the
    /// fatal's late `finishEnding` leaves the successor alone (no cancel, no end).
    @Test func aLateFinishEndingLeavesTheSuccessorAlone() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        adapterA.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await w.h.waitPhase(.stopping))
        let stopA = Task { await w.stopTunnel(a) }                         // waits on the hung teardown
        #expect(await w.h.waitPhase(.idle))
        let adapterB = await w.connect(b, other: true)
        adapterA.releaseStop()
        await stopA.value
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await w.h.phase == .connected)
        #expect(adapterB.stopCount == 0)
        #expect(w.h.host.cancelledCodes.isEmpty)
        #expect(await w.h.controller.snapshot().profileID == w.otherPID)
    }

    /// A start waiting beside a fatal's teardown that ends HELD (the kill switch enabled live meanwhile) is woken by
    /// the hold and re-decides: refused beside the held session, never left waiting.
    @Test func aHoldAtTheEndOfATeardownWakesTheWaitingStart() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        adapterA.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await w.h.waitPhase(.stopping))
        let tb = w.start(b, other: true)
        #expect(!(await waitUntil(timeout: .milliseconds(100)) { w.binds.list.count > 1 }))
        w.host(a)?.setIncludeAllNetworks(true)
        adapterA.releaseStop()
        #expect(w.code(await w.value(tb, "B")) == .anotherTunnelActive)
        #expect(await w.h.phase == .held(.blockedAfterFailure(.engineFatal)))
        #expect(w.host(a)?.cancelledCodes == [])
    }

    /// `ProviderSeat.protectionChanged` (the provider's KVO) reaches the controller: a duplicate waiting beside a
    /// kill-switch session whose flag was removed live re-decides and preempts it.
    @Test func theSeatsProtectionChangeWakesAWaitingStart() async {
        let w = World(killSwitch: true, routed: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        await w.connect(a1)
        let t2 = w.start(a2)
        #expect(!(await waitUntil(timeout: .milliseconds(100)) { w.h.factory.adapters.count > 1 }))
        w.host(a1)?.setIncludeAllNetworks(false)
        ProviderSeat(controller: w.h.controller).protectionChanged()
        await w.finish(await w.adapter(1))
        #expect(w.code(await w.value(t2, "A2")) == nil)
        #expect(w.host(a1)?.cancelledCodes == [.supersededByKillSwitch])
    }

    /// Round 4 (N4): a preempted session that turns out protected at the end of its teardown is kept, and 223 is not
    /// recorded as its last error (only a session that ends carries it).
    @Test func aKeptPreemptedSessionCarriesNo223() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        let tk = w.start(k, other: true, killSwitch: true)
        #expect(await waitUntil { adapterA.stopCount == 1 })
        w.host(a)?.setIncludeAllNetworks(true)
        adapterA.releaseStop()
        #expect(w.code(await w.value(tk, "K")) == .anotherTunnelActive)
        #expect(w.h.state.load().lastErrors[w.h.key]?.error.code != .supersededByKillSwitch)
        #expect(w.h.state.load().sessions.isEmpty)
        // Round 5 (Codex 6, Fable N1): held as interrupted, not as superseded (that start was refused).
        #expect(await w.h.phase == .held(.blockedAfterFailure(.sessionInterrupted)))
        #expect(await w.h.controller.snapshot().holdReason == .blockedAfterFailure(.sessionInterrupted))
    }

    /// Round 5 (Fable L2, N2): a preemption whose incumbent gains the flag DURING the summary save: held (as
    /// interrupted), not cancelled, no summary and no 223 left behind, and the summary the full ring trimmed for the
    /// withdrawn one is back.
    @Test func aPreemptionWhoseIncumbentGainsTheFlagDuringTheSummarySaveIsRolledBack() async {
        let w = World(summaries: 100, routed: true)
        await w.provision()
        let before = w.h.state.load().sessions
        let a = w.instance(), k = w.instance()
        _ = await w.connect(a)
        let hostA = w.host(a), pid = w.h.pid
        w.h.state.setOnSave { st in if st.sessions.contains(where: { $0.summary.profileID == pid }) { hostA?.setIncludeAllNetworks(true) } }
        let tk = w.start(k, other: true, killSwitch: true)
        #expect(w.code(await w.value(tk, "K")) == .anotherTunnelActive)
        w.h.state.setOnSave(nil)
        #expect(await w.h.phase == .held(.blockedAfterFailure(.sessionInterrupted)))
        #expect(hostA?.cancelledCodes == [])
        let st = w.h.state.load()
        #expect(st.sessions == before)
        #expect(st.lastErrors[w.h.key] == nil)
        #expect(await w.h.controller.snapshot().lastError == nil)
    }

    /// Round 4 (Codex 2): the kill switch is enabled live DURING the final summary save (after the last read before
    /// the I/O): the read right before the cancel sees it, the session is kept, tracked and held, and its summary and
    /// end are withdrawn.
    @Test func aKillSwitchEnabledDuringTheSummarySaveHolds() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance()
        let adapterA = await w.connect(a)
        let hostA = w.host(a)
        w.h.state.setOnSave { st in if !st.sessions.isEmpty { hostA?.setIncludeAllNetworks(true) } }
        adapterA.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await w.h.waitPhase(.held(.blockedAfterFailure(.engineFatal))))
        w.h.state.setOnSave(nil)
        #expect(hostA?.cancelledCodes == [])
        #expect(await w.h.controller.snapshot().profileID == w.h.pid)
        #expect(w.h.state.load().sessions.isEmpty)
    }

    /// Round 4 (N3): a session preempted while its after-Connected prompt shows: the prompt is resolved for the app.
    @Test func aPreemptedSessionsPromptIsResolved() async throws {
        let w = World()
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        adapterA.emit { .authRequired(AuthChallenge(kind: .userPass, reason: .reconnect), epoch: $0) }
        #expect(await w.h.waitPhase(.awaitingAuth(beforeConnected: false)))
        let p = try #require(w.h.sink.prompts.last)
        await w.connect(k, other: true, killSwitch: true)
        #expect(w.h.sink.resolved == [p.promptID])
    }

    // MARK: Round 3 N1, final review L5: waking waiting starts

    /// A duplicate kill-switch start waits beside the running kill-switch session; that session's flag is removed live
    /// (KVO → `recheckWaitingStarts`): the duplicate re-decides and preempts it.
    @Test func aWaitingDuplicateReDecidesWhenTheIncumbentsProtectionChanges() async {
        let w = World(killSwitch: true, routed: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        await w.connect(a1)
        let t2 = w.start(a2)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.h.factory.adapters.count > 1 }))
        w.host(a1)?.setIncludeAllNetworks(false)
        await w.h.controller.recheckWaitingStarts()
        await w.finish(await w.adapter(1))
        #expect(w.code(await w.value(t2, "A2")) == nil)
        #expect(w.host(a1)?.cancelledCodes == [.supersededByKillSwitch])
    }

    enum Invalidation: String, CaseIterable { case removed, changed, wiped }

    /// Round 5 (Codex 2): a duplicate waiting behind its profile's held start, when that profile is removed, changed (a
    /// higher revision provisioned) or its owner's secrets are wiped, through the real XPC backend (the payload goes):
    /// both end, and the duplicate never binds or begins on the removed or old configuration.
    @Test(arguments: Invalidation.allCases)
    func aWaitingDuplicateEndsWhenItsProfileIsInvalidated(_ how: Invalidation) async {
        let w = World(killSwitch: true)
        await w.provision()
        let backend = EngineServiceBackend(controller: w.h.controller, secrets: w.h.secrets, validator: FakeValidator())
        let peer = PeerContext(uid: w.h.owner, pid: 1)
        let a1 = w.instance(), a2 = w.instance()
        let ta1 = w.start(a1)
        let adapter1 = await w.adapter(0)
        adapter1.finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await waitUntil { if case .held = await w.h.phase { true } else { false } })
        let t2 = w.start(a2)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        let r: Result<Data?, LPError>
        switch how {
        case .removed:
            r = await backend.handle(.removeProfile, request: try! LPWire.encode(ProfileRequest(profileID: w.h.pid)), peer: peer)
        case .changed:
            r = await backend.handle(.provisionProfile, request: try! LPWire.encode(ProvisionRequest(
                profileID: w.h.pid, kind: w.h.kind, revision: 2, payload: Data(Harness.payload(w.h.kind).utf8), credentials: nil)), peer: peer)
        case .wiped:
            r = await backend.handle(.wipeAllSecrets, request: try! LPWire.encode(EmptyRequest()), peer: peer)
        }
        if case .failure(let e) = r { Issue.record("backend: \(e.code)") }
        #expect(w.code(await w.value(ta1, "A1")) != nil)
        #expect(w.code(await w.value(t2, "A2")) == .startCancelled)
        #expect(w.binds.list == [a1.token])
        #expect(await w.h.phase == .idle)
    }

    /// Round 5 (Codex 2): the same for the start holding the RESERVATION across a preemption's teardown: its profile is
    /// removed (or its owner's secrets wiped) while the preempted session tears down, and it never begins. Round 6
    /// (Fable L3): the preempted session can't be undone: B ends as preempted (223, cancelled on its own provider).
    @Test(arguments: [false, true])
    func aPreemptingStartEndsWhenItsProfileIsRemovedDuringTheTeardown(wipe: Bool) async {
        let w = World(routed: true)
        await w.provision()
        let b = w.instance(), k = w.instance()
        let adapterB = await w.connect(b, other: true)                        // split, profile B
        adapterB.s.withLock { $0.hangStop = true }
        let tk = w.start(k, killSwitch: true)                                 // profile A, kill switch: preempts B
        #expect(await waitUntil { adapterB.stopCount == 1 })
        if wipe { await w.h.controller.secretsWiped(ownerUID: w.h.owner) } else { await w.h.controller.profileRemoved(w.h.pid, ownerUID: w.h.owner) }
        adapterB.releaseStop()
        #expect(w.code(await w.value(tk, "K")) == .startCancelled)
        #expect(w.binds.list == [b.token])
        #expect(await waitUntil { w.host(b)?.cancelledCodes == [.supersededByKillSwitch] })
        #expect(await w.h.phase == .idle)
    }

    /// Round 6 (Fable L3): a higher revision of the preempting start's profile during the preempted session's teardown
    /// doesn't take it down too: it proceeds on the new payload and connects with the kill switch; B ends as preempted.
    /// A duplicate of the old revision waiting behind its reservation still ends.
    @Test func aPreemptingStartProceedsWhenItsProfileChangesDuringTheTeardown() async {
        let w = World(routed: true)
        await w.provision()
        let b = w.instance(), k = w.instance(), d = w.instance()
        let adapterB = await w.connect(b, other: true)
        adapterB.s.withLock { $0.hangStop = true }
        let n = w.h.factory.adapters.count
        let tk = w.start(k, killSwitch: true)
        #expect(await waitUntil { adapterB.stopCount == 1 })
        let td = w.start(d, killSwitch: true)                                 // waits behind K's reservation
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        let backend = EngineServiceBackend(controller: w.h.controller, secrets: w.h.secrets, validator: FakeValidator())
        let r = await backend.handle(.provisionProfile, request: try! LPWire.encode(ProvisionRequest(
            profileID: w.h.pid, kind: w.h.kind, revision: 2, payload: Data(Harness.payload(w.h.kind).utf8), credentials: nil)),
            peer: PeerContext(uid: w.h.owner, pid: 1))
        if case .failure(let e) = r { Issue.record("provision: \(e.code)") }
        #expect(w.code(await w.value(td, "D", within: .seconds(1))) == .startCancelled)
        adapterB.releaseStop()
        await w.finish(await w.adapter(n))
        #expect(w.code(await w.value(tk, "K")) == nil)
        #expect(await w.h.waitPhase(.connected))
        #expect(w.binds.list == [b.token, k.token])
        #expect(await waitUntil { w.host(b)?.cancelledCodes == [.supersededByKillSwitch] })
    }

    /// Round 7 (Codex M3): the same for a PENDING incumbent (its start completion still open): it gains the flag while
    /// its 223 is written; it is kept (its start not failed), the 223 withdrawn, and the kill-switch start re-decides
    /// against it (another profile, both protected now: refused).
    @Test func aPendingIncumbentThatGainsTheFlagDuringTheRecordIsKept() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let ta = w.start(a)                                                   // profile A, split, pending
        let adapterA = await w.adapter(0)
        let hostA = w.host(a), key = w.h.key
        w.h.state.setOnSave { st in if st.lastErrors[key]?.error.code == .supersededByKillSwitch { hostA?.setIncludeAllNetworks(true) } }
        let tk = w.start(k, other: true, killSwitch: true)
        #expect(w.code(await w.value(tk, "K")) == .anotherTunnelActive)
        w.h.state.setOnSave(nil)
        #expect(w.h.state.load().lastErrors[w.h.key] == nil)
        #expect(hostA?.cancelledCodes == [])
        #expect(w.binds.list == [a.token])
        await w.finish(adapterA)                                              // A's start goes on and connects
        #expect(w.code(await w.value(ta, "A")) == nil)
        #expect(await w.h.waitPhase(.connected))
    }

    /// Round 7 (Fable L1, probe P1): the exempted reservation holder (a kill-switch duplicate of A, revision 1, with A
    /// provisioned at revision 2 during the teardown) whose preemption is vetoed (A regained the flag) would wait as a
    /// duplicate of the OLD revision: it ends instead, and never binds once A ends.
    @Test func anExemptedHolderWhosePreemptionIsVetoedEnds() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        let tk = w.start(k, killSwitch: true)
        #expect(await waitUntil { adapterA.stopCount == 1 })
        await w.h.controller.profileProvisioned(w.h.pid, ownerUID: w.h.owner, revision: 2)
        w.host(a)?.setIncludeAllNetworks(true)
        adapterA.releaseStop()
        #expect(w.code(await w.value(tk, "K")) == .startCancelled)
        #expect(await w.h.phase == .held(.blockedAfterFailure(.sessionInterrupted)))
        await w.stopTunnel(a)
        #expect(!(await waitUntil(timeout: .milliseconds(300)) { w.binds.list.count > 1 }))
    }

    /// Round 8 (Fable L1, probe P1): the other order: the preemption is vetoed FIRST (the duplicate then waits), and
    /// only then A is provisioned at revision 2: the duplicate gave the reservation back, so it is invalidated like any
    /// waiter of the old revision and never binds once A ends.
    @Test func aVetoedPreemptorIsInvalidatedByALaterRevision() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance(), k = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        let tk = w.start(k, killSwitch: true)
        #expect(await waitUntil { adapterA.stopCount == 1 })
        w.host(a)?.setIncludeAllNetworks(true)
        adapterA.releaseStop()
        #expect(await w.h.waitPhase(.held(.blockedAfterFailure(.sessionInterrupted))))
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))   // K waits
        await w.h.controller.profileProvisioned(w.h.pid, ownerUID: w.h.owner, revision: 2)
        #expect(w.code(await w.value(tk, "K", within: .seconds(1))) == .startCancelled)
        await w.stopTunnel(a)
        #expect(!(await waitUntil(timeout: .milliseconds(300)) { w.binds.list.count > 1 }))
    }

    /// Round 9 (Codex LOW): B's start is refused (222) beside A while B's payload is missing; the refusal is recorded
    /// before any payload lookup, and the app reads its time through the real XPC backend anyway (its own key only).
    @Test func aRefusalOfAnUnprovisionedProfileIsReadable() async throws {
        let w = World()
        await w.h.provision()                                                 // A only: B has no payload
        let a = w.instance(), b = w.instance()
        _ = await w.connect(a)
        #expect(w.code(await w.value(w.start(b, other: true), "B")) == .anotherTunnelActive)
        let backend = EngineServiceBackend(controller: w.h.controller, secrets: w.h.secrets, validator: FakeValidator())
        let r = await backend.handle(.tunnelSnapshot, request: try LPWire.encode(ProfileRequest(profileID: w.otherPID)),
                                     peer: PeerContext(uid: w.h.owner, pid: 1))
        let snap = try LPWire.decode(TunnelSnapshot.self, try #require(try r.get()), max: 1 << 16)
        #expect(snap.lastError?.code == .anotherTunnelActive && snap.lastErrorAt != nil)
        #expect(snap.phase == .idle)
        // Another uid asking for the same profile ID sees nothing (not provisioned, as before).
        let r2 = await backend.handle(.tunnelSnapshot, request: try LPWire.encode(ProfileRequest(profileID: w.otherPID)),
                                      peer: PeerContext(uid: w.h.owner &+ 1, pid: 2))
        if case .failure(let e) = r2 { #expect(e.code == .profileNotProvisioned) } else { Issue.record("another uid read a snapshot") }
    }

    /// Round 9 (Fable N2): a third start (another kill-switch duplicate of A) waits on the preemptor's reservation
    /// during the teardown; after the veto it re-decides (it waits on the kept session now) and proceeds once A ends:
    /// exactly one of the two waiting duplicates binds.
    @Test func aStartWaitingOnAVetoedReservationReDecides() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance(), k = w.instance(), d = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        let tk = w.start(k, killSwitch: true)
        #expect(await waitUntil { adapterA.stopCount == 1 })
        let td = w.start(d, killSwitch: true)                                 // waits on K's reservation
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        w.host(a)?.setIncludeAllNetworks(true)
        adapterA.releaseStop()
        #expect(await w.h.waitPhase(.held(.blockedAfterFailure(.sessionInterrupted))))
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.stopTunnel(a)
        #expect(await waitUntil { w.binds.list.count == 2 })
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 2 }))
        _ = (tk, td)
    }

    /// Round 6 (Codex M2): the credential write fails after the new payload was written; the waiter of the OLD revision
    /// ends with that write, and a successful retry of the same revision (no longer "higher") ends one too. Released
    /// incumbent: the waiter never binds.
    @Test func aPartialProvisionStillEndsAWaiterOfTheOldRevision() async {
        let w = World(killSwitch: true)
        await w.provision()
        let backend = EngineServiceBackend(controller: w.h.controller, secrets: w.h.secrets, validator: FakeValidator())
        let peer = PeerContext(uid: w.h.owner, pid: 1)
        let a1 = w.instance(), a2 = w.instance(), a3 = w.instance()
        _ = await w.connect(a1)
        let t2 = w.start(a2)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        func provision() async -> Result<Data?, LPError> {
            await backend.handle(.provisionProfile, request: try! LPWire.encode(ProvisionRequest(
                profileID: w.h.pid, kind: w.h.kind, revision: 2, payload: Data(Harness.payload(w.h.kind).utf8),
                credentials: CredentialRecord(username: Data("a".utf8), password: Data("p".utf8)))), peer: peer)
        }
        await w.h.secrets.setFailure(LPError(.secretStoreUnavailable), for: .credential)
        if case .success = await provision() { Issue.record("the credential write should fail") }
        #expect(w.code(await w.value(t2, "A2", within: .seconds(1))) == .startCancelled)
        let t3 = w.start(a3)                                                 // another waiter of the old revision
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.h.secrets.setFailure(nil, for: .credential)
        if case .failure(let e) = await provision() { Issue.record("retry: \(e.code)") }
        #expect(w.code(await w.value(t3, "A3", within: .seconds(1))) == .startCancelled)
        await w.stopTunnel(a1)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        #expect(w.binds.list == [a1.token])
    }

    /// Round 6 (Fable N3): the credential delete of a removal fails after the payload delete: the removal still ends
    /// the waiting start.
    @Test func aPartialRemovalStillEndsTheWaiter() async {
        let w = World(killSwitch: true)
        await w.provision()
        let backend = EngineServiceBackend(controller: w.h.controller, secrets: w.h.secrets, validator: FakeValidator())
        let a1 = w.instance(), a2 = w.instance()
        _ = await w.connect(a1)
        let t2 = w.start(a2)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.h.secrets.setFailure(LPError(.secretStoreUnavailable), for: .credential)
        let r = await backend.handle(.removeProfile, request: try! LPWire.encode(ProfileRequest(profileID: w.h.pid)),
                                     peer: PeerContext(uid: w.h.owner, pid: 1))
        if case .success = r { Issue.record("the credential delete should fail") }
        #expect(w.code(await w.value(t2, "A2", within: .seconds(1))) == .startCancelled)
        await w.stopTunnel(a1)
        #expect(w.binds.list == [a1.token])
    }

    /// Round 7 (Fable N3): the PAYLOAD delete fails: nothing was removed, so the waiting start keeps waiting.
    @Test func aFailedPayloadDeleteLeavesTheWaiterWaiting() async {
        let w = World(killSwitch: true)
        await w.provision()
        let backend = EngineServiceBackend(controller: w.h.controller, secrets: w.h.secrets, validator: FakeValidator())
        let a1 = w.instance(), a2 = w.instance()
        _ = await w.connect(a1)
        let t2 = w.start(a2)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.h.secrets.setFailure(LPError(.secretStoreUnavailable), for: .payload)
        let r = await backend.handle(.removeProfile, request: try! LPWire.encode(ProfileRequest(profileID: w.h.pid)),
                                     peer: PeerContext(uid: w.h.owner, pid: 1))
        if case .success = r { Issue.record("the payload delete should fail") }
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.h.secrets.setFailure(nil, for: .payload)
        await w.stopTunnel(a1)
        #expect(await waitUntil { w.binds.list == [a1.token, a2.token] })
        _ = t2
    }

    /// Round 5 (Codex 2): a higher revision of ANOTHER profile, or the same revision again, leaves a waiting duplicate
    /// waiting; it proceeds once its incumbent ends.
    @Test func anUnrelatedProvisionLeavesAWaitingDuplicateWaiting() async {
        let w = World(killSwitch: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let ta1 = w.start(a1)
        _ = await w.adapter(0)
        let t2 = w.start(a2)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.h.controller.profileProvisioned(w.otherPID, ownerUID: w.h.owner, revision: 2)
        await w.h.controller.profileProvisioned(w.h.pid, ownerUID: w.h.owner, revision: 1)
        await w.h.controller.profileRemoved(w.otherPID, ownerUID: w.h.owner)            // another profile
        await w.h.controller.profileRemoved(w.h.pid, ownerUID: w.h.owner &+ 1)          // another user's namesake
        await w.h.controller.secretsWiped(ownerUID: w.h.owner &+ 1)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.stopTunnel(a1)
        #expect(w.code(await w.value(ta1, "A1")) == .startCancelled)
        #expect(await waitUntil { w.binds.list == [a1.token, a2.token] })
        _ = t2
    }

    /// Round 5: the incumbent's held start ends by itself (a higher revision ends the old configuration's start), not
    /// by a stop: a waiting duplicate that already carries the new revision is not invalidated; `endSession` wakes it
    /// and it proceeds.
    @Test func aWaitingDuplicateOfTheNewRevisionProceedsWhenTheOldOneEnds() async {
        let w = World(killSwitch: true)
        await w.provision()
        let backend = EngineServiceBackend(controller: w.h.controller, secrets: w.h.secrets, validator: FakeValidator())
        let a1 = w.instance(), a2 = w.instance()
        let ta1 = w.start(a1)
        let adapter1 = await w.adapter(0)
        adapter1.finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await waitUntil { if case .held = await w.h.phase { true } else { false } })
        let t2 = w.start(a2, StartRequest(options: StartOptions(isManual: true), configuration: w.h.config(revision: 2)))
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        _ = await backend.handle(.provisionProfile, request: try! LPWire.encode(ProvisionRequest(
            profileID: w.h.pid, kind: w.h.kind, revision: 2, payload: Data(Harness.payload(w.h.kind).utf8), credentials: nil)),
            peer: PeerContext(uid: w.h.owner, pid: 1))
        #expect(w.code(await w.value(ta1, "A1")) != nil)
        #expect(await waitUntil { w.binds.list == [a1.token, a2.token] })
        _ = t2
    }

    /// Round 5 (Codex 2): beside a CONNECTED session of its profile (which the change doesn't end), a waiting duplicate
    /// of the old revision ends at once; the connected session stays.
    @Test func aDuplicateWaitingBesideAConnectedSessionEndsAtOnceWhenItsProfileChanges() async {
        let w = World(killSwitch: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        _ = await w.connect(a1)
        let t2 = w.start(a2)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.h.controller.profileProvisioned(w.h.pid, ownerUID: w.h.owner, revision: 2)
        #expect(w.code(await w.value(t2, "A2", within: .seconds(1))) == .startCancelled)
        #expect(await w.h.phase == .connected)
        #expect(w.binds.list == [a1.token])
    }

    // MARK: Round 5, Codex 5: the latch at admission

    /// Round 6 (Fable L4): a latched on-demand start without the flag beside a running session fails at entry with the
    /// latch's code, before the guard: no 222 and no refusal recorded.
    @Test func aLatchedStartWithoutTheFlagFailsBeforeTheGuard() async {
        let w = World(latchOther: true)
        await w.provision()
        let a = w.instance(), b = w.instance()
        _ = await w.connect(a)
        let tb = w.start(b, other: true, killSwitch: false, manual: false)
        #expect(w.code(await w.value(tb, "B")) == .authFailed)
        #expect(await w.h.controller.snapshot(profileID: w.otherPID, ownerUID: w.h.owner).lastError == nil)
        #expect(w.h.state.load().lastErrors[w.otherKey] == nil)
        #expect(w.binds.list == [a.token])
    }

    /// Round 6 (Fable L4): an on-demand start without the flag waits on a `.stopping` session (a fatal's teardown); a
    /// latch of its profile installed meanwhile makes it fail at admission (never a hold of a split start).
    @Test func aLatchInstalledWhileAStartWithoutTheFlagWaitsMakesItFail() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }
        adapterA.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await w.h.waitPhase(.stopping))
        let tb = w.start(b, other: true, killSwitch: false, manual: false)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.h.controller.installLatchForTesting(w.otherKey, StartLatch(code: .authFailed, kind: .hard, notBefore: nil, revision: 1))
        adapterA.releaseStop()
        #expect(w.code(await w.value(tb, "B")) == .authFailed)
        #expect(w.binds.list == [a.token])
    }

    /// Credentials updated while an on-demand duplicate waits behind its latched (held) profile: the hard latch it saw
    /// at its start is gone at admission, so it starts its engine instead of holding on the stale latch.
    @Test func credentialsUpdatedWhileWaitingClearTheLatchAtAdmission() async {
        let w = World(killSwitch: true, latchSelf: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let ta1 = w.start(a1, manual: false)                                  // latched: held, no I/O
        #expect(await w.h.waitPhase(.held(.nonRetryable(.authFailed))))
        let t2 = w.start(a2, manual: false)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.h.controller.credentialsUpdated(w.h.pid, ownerUID: w.h.owner)
        #expect(w.h.latch == nil)
        await w.stopTunnel(a1)
        _ = await w.value(ta1, "A1")
        #expect(await waitUntil { w.binds.list == [a1.token, a2.token] })
        _ = await w.adapter(0)                                                // A2's engine starts (A1 never had one)
        #expect(await w.h.waitPhase(.connecting))
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { if case .held = await w.h.phase { true } else { false } }))
        _ = t2
    }

    /// A latch installed while an on-demand duplicate waits (its incumbent's kill-switch start failed under on-demand:
    /// a backoff latch) is honoured at admission: held, no engine.
    @Test func aLatchInstalledWhileWaitingIsHonouredAtAdmission() async {
        let w = World(killSwitch: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let ta1 = w.start(a1, manual: false)
        let adapter1 = await w.adapter(0)
        let t2 = w.start(a2, manual: false)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        adapter1.finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await w.h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        #expect(w.h.latch?.kind == .backoff)
        await w.stopTunnel(a1)
        _ = await w.value(ta1, "A1")
        #expect(await waitUntil { w.binds.list == [a1.token, a2.token] })
        #expect(await w.h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.h.factory.adapters.count > 1 }))
        _ = t2
    }

    /// A same-profile duplicate kill-switch start behind a kill-switch start's RESERVATION waits (never refused); once
    /// that start began it re-checks against its session (still waiting), and proceeds when that session's start stops.
    @Test func aDuplicateWaitsBehindAReservationThenBehindTheSession() async {
        let w = World()
        await w.provision()
        let b = w.instance(), k = w.instance(), d = w.instance()
        let adapterB = await w.connect(b, other: true)                        // split, profile B
        adapterB.s.withLock { $0.hangStop = true }
        let tk = w.start(k, killSwitch: true)                                 // profile A, kill switch: preempts B
        #expect(await waitUntil { adapterB.stopCount == 1 })
        let td = w.start(d, killSwitch: true)                                 // profile A again: a duplicate of K
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        adapterB.releaseStop()
        let adapterK = await w.adapter(1)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 2 }))   // D waits on K's session
        #expect(w.binds.list == [b.token, k.token])
        await w.stopTunnel(k)
        #expect(w.code(await w.value(tk, "K")) == .startCancelled)
        await w.finish(await w.adapter(2))
        #expect(w.code(await w.value(td, "D")) == nil)
        _ = adapterK
    }

    // MARK: Round 3, Codex 2/3: the lifecycle gate

    /// One native provider object, two generations of hosts on it (as NE reuses an instance).
    final class NativeProvider: @unchecked Sendable {
        let cancels = Mutex<[String]>([])
    }
    final class GenerationHost: ProviderHost, @unchecked Sendable {
        let native: NativeProvider, name: String
        let packetFlow: any PacketFlowSource = FakeFlow()
        var onCancel: (() -> Void)?
        let pinned: AnyObject?
        init(_ native: NativeProvider, _ name: String, pinned: AnyObject? = nil) { self.native = native; self.name = name; self.pinned = pinned }
        func apply(_ settings: TunnelSettingsSpec) async throws(LPTunnelError) {}
        func setReasserting(_ on: Bool) {}
        func cancel(with error: LPTunnelError, owner: ProviderLease?) { native.cancels.withLock { $0.append(name) }; onCancel?() }
        func tunnelFileDescriptor(matching address: String?) -> Int32? { nil }
        func liveProtection(owner: ProviderLease?) -> ProviderProtection? { nil }
        func pin() -> AnyObject? { pinned }
    }

    /// A generation-1 cancel issued while generation 2 is being published (a barrier inside `publish`) waits for the
    /// gate and then reaches nothing: generation 2's publication raised the watermark first. A generation-1 bind after
    /// it is refused.
    @Test func theGateOrdersAGeneration1CancelAfterGeneration2sPublication() {
        let p = ProviderInstances(), router = ProviderHostRouter<GenerationHost>()
        let native = NativeProvider(), id = ObjectIdentifier(native), t = p.makeToken()
        let g1 = router.publish(t) { p.started(t) }
        #expect(router.bind(id: id, lease: g1, host: GenerationHost(native, "g1")))
        let inside = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0), published = DispatchSemaphore(value: 0)
        let g2box = Mutex<ProviderLease?>(nil)
        Thread {
            let g2 = router.publish(t) { inside.signal(); go.wait(); return p.started(t) }
            g2box.withLock { $0 = g2 }
            published.signal()
        }.start()
        inside.wait()                                                          // generation 2 is being published
        let cancelled = DispatchSemaphore(value: 0)
        Thread { router.cancel(with: LPTunnelError(.engineFatal), owner: g1); cancelled.signal() }.start()
        #expect(cancelled.wait(timeout: .now() + .milliseconds(150)) == .timedOut)   // held at the gate
        go.signal()
        published.wait()
        #expect(cancelled.wait(timeout: .now() + .seconds(3)) == .success)
        #expect(native.cancels.withLock { $0 }.isEmpty)                        // the shared native provider: untouched
        #expect(!router.bind(id: id, lease: g1, host: GenerationHost(native, "g1-late")))   // below the watermark
        let g2 = g2box.withLock { $0 }!
        #expect(router.bind(id: id, lease: g2, host: GenerationHost(native, "g2")))
        router.cancel(with: LPTunnelError(.engineFatal), owner: g2)
        #expect(native.cancels.withLock { $0 } == ["g2"])
    }

    /// The seat publishes through the gate synchronously in `startTunnel`, before its Task: the older start can no
    /// longer be bound or cancelled through the router.
    @Test func theSeatPublishesThroughTheGateSynchronously() {
        let w = World()
        let router = ProviderHostRouter<GenerationHost>()
        let native = NativeProvider(), id = ObjectIdentifier(native)
        let seat = ProviderSeat(controller: w.h.controller, gate: router)
        seat.startTunnel(StartRequest(options: StartOptions(isManual: true), configuration: nil), bind: { _ in false }) { _ in }
        let g1 = seat.currentLease!
        #expect(router.bind(id: id, lease: g1, host: GenerationHost(native, "g1")))
        seat.startTunnel(StartRequest(options: StartOptions(isManual: true), configuration: nil), bind: { _ in false }) { _ in }
        router.cancel(with: LPTunnelError(.engineFatal), owner: g1)
        #expect(native.cancels.withLock { $0 }.isEmpty)
        #expect(!router.bind(id: id, lease: g1, host: GenerationHost(native, "g1-late")))
    }

    /// The provider's last reference goes during a cancel's dispatch (NE releasing it): its `deinit` calls the router's
    /// `release`. The router pins it across the dispatch, so that cleanup runs after the unlock: no deadlock, and the
    /// binding is gone afterwards.
    @Test func aProviderReleasedDuringACancelCleansUpAfterTheUnlock() {
        final class Dying: @unchecked Sendable {
            let cleanup: () -> Void
            init(_ c: @escaping () -> Void) { cleanup = c }
            deinit { cleanup() }
        }
        final class Box: @unchecked Sendable { var ref: Dying? }
        final class PinningHost: ProviderHost, @unchecked Sendable {
            weak var obj: Dying?
            let native: NativeProvider
            var dropExternal: (() -> Void)?
            let inDispatch = Mutex(false)
            let packetFlow: any PacketFlowSource = FakeFlow()
            init(_ n: NativeProvider) { native = n }
            func apply(_ settings: TunnelSettingsSpec) async throws(LPTunnelError) {}
            func setReasserting(_ on: Bool) {}
            func cancel(with error: LPTunnelError, owner: ProviderLease?) {
                inDispatch.withLock { $0 = true }
                dropExternal?()                                                // NE drops its last reference mid-call
                native.cancels.withLock { $0.append("g1") }
                inDispatch.withLock { $0 = false }
            }
            func tunnelFileDescriptor(matching address: String?) -> Int32? { nil }
            func liveProtection(owner: ProviderLease?) -> ProviderProtection? { nil }
            func pin() -> AnyObject? { obj }
        }
        let p = ProviderInstances(), router = ProviderHostRouter<PinningHost>(), t = p.makeToken()
        let native = NativeProvider(), id = ObjectIdentifier(native)
        let g = router.publish(t) { p.started(t) }
        let released = Mutex(false), ranInsideDispatch = Mutex(false)
        let box = Box()
        let host = PinningHost(native)
        box.ref = Dying { [host] in
            ranInsideDispatch.withLock { $0 = host.inDispatch.withLock { $0 } }
            router.release(id: id, token: t); released.withLock { $0 = true }
        }
        host.obj = box.ref
        host.dropExternal = { box.ref = nil }
        #expect(router.bind(id: id, lease: g, host: host))
        let done = DispatchSemaphore(value: 0)
        Thread { router.cancel(with: LPTunnelError(.engineFatal), owner: g); done.signal() }.start()
        #expect(done.wait(timeout: .now() + .seconds(3)) == .success)          // no deadlock, no trap
        #expect(released.withLock { $0 })
        #expect(!ranInsideDispatch.withLock { $0 })                            // the pin: cleanup after the dispatch
        #expect(native.cancels.withLock { $0 } == ["g1"])
        #expect(router.liveProtection(owner: g) == nil)                        // the binding went with it
    }

    /// Round 4 (Codex 3): a bind of generation 1 that arrives while generation 2 is being published, AFTER
    /// `providers.started` made it current but before the watermark, waits for the gate and is then refused.
    @Test func aBindDuringPublicationIsRefused() {
        let p = ProviderInstances(), router = ProviderHostRouter<GenerationHost>()
        let native = NativeProvider(), id = ObjectIdentifier(native), t = p.makeToken()
        let g1 = router.publish(t) { p.started(t) }
        let inside = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0), published = DispatchSemaphore(value: 0)
        Thread {
            _ = router.publish(t) { let l = p.started(t); inside.signal(); go.wait(); return l }
            published.signal()
        }.start()
        inside.wait()                                                          // g2 current, watermark not raised yet
        #expect(!p.isCurrent(g1))
        let bound = Mutex<Bool?>(nil), done = DispatchSemaphore(value: 0)
        Thread {
            let r = router.bind(id: id, lease: g1, host: GenerationHost(native, "g1"))
            bound.withLock { $0 = r }
            done.signal()
        }.start()
        #expect(done.wait(timeout: .now() + .milliseconds(150)) == .timedOut)  // held at the gate
        go.signal()
        published.wait()
        #expect(done.wait(timeout: .now() + .seconds(3)) == .success)
        #expect(bound.withLock { $0 } == false)
        router.cancel(with: LPTunnelError(.engineFatal), owner: nil)
        #expect(native.cancels.withLock { $0 }.isEmpty)                        // nothing current was installed
    }

    /// Round 4 (Codex 5, N2): repeated publish, bind, refuse and release of fresh instances leave no bookkeeping behind.
    @Test func theRoutersBookkeepingIsBoundedUnderChurn() {
        final class Obj {}
        let p = ProviderInstances(), router = ProviderHostRouter<FakeHost>()
        let keep = Obj(), tk = p.makeToken()
        let lk = router.publish(tk) { p.started(tk) }
        router.bind(id: ObjectIdentifier(keep), lease: lk, host: FakeHost())
        for i in 0..<500 {
            let o = Obj(), t = p.makeToken()
            let l1 = router.publish(t) { p.started(t) }
            if i.isMultiple(of: 2) { router.bind(id: ObjectIdentifier(o), lease: l1, host: FakeHost()) }
            p.stopped(t)
            _ = router.publish(t) { p.started(t) }                             // NE reuses it once
            p.stopped(t)
            router.release(id: ObjectIdentifier(o), token: t)
        }
        #expect(router.trackedInstanceCount == 1)                              // only the instance still running
        _ = keep
    }

    // MARK: Final review L2

    /// The router swaps the packet flow with the current binding: K's after K binds, still K's after A's late unbind,
    /// none after K's own unbind.
    @Test func theRouterSwapsThePacketFlowWithTheBinding() {
        final class Obj {}
        let p = ProviderInstances(), router = ProviderHostRouter<FakeHost>()
        let oa = Obj(), ok = Obj(), ta = p.makeToken(), tk = p.makeToken()
        let la = p.started(ta), lk = p.started(tk)
        let ha = FakeHost(), hk = FakeHost()
        router.bind(id: ObjectIdentifier(oa), lease: la, host: ha)
        #expect(router.packetFlow.writePackets([Data([1])], protocols: [2]))
        #expect(ha.flow.s.withLock { $0.written.count } == 1)
        router.bind(id: ObjectIdentifier(ok), lease: lk, host: hk)
        #expect(router.packetFlow.writePackets([Data([2])], protocols: [2]))
        #expect(hk.flow.s.withLock { $0.written.count } == 1)
        router.unbind(id: ObjectIdentifier(oa), lease: la)                  // A's late unbind
        #expect(router.packetFlow.writePackets([Data([3])], protocols: [2]))
        #expect(hk.flow.s.withLock { $0.written.count } == 2)
        router.unbind(id: ObjectIdentifier(ok), lease: lk)
        #expect(!router.packetFlow.writePackets([Data([4])], protocols: [2]))
        router.bind(id: ObjectIdentifier(ok), lease: lk, host: hk)
        router.release(id: ObjectIdentifier(ok), token: tk)
        #expect(!router.packetFlow.writePackets([Data([5])], protocols: [2]))
    }

    /// Incumbent liveness is by lease, not instance: a session whose instance NE has since reused (a new generation,
    /// not yet at the controller) is stale, and another instance's start replaces it.
    @Test func aSessionOfAReusedInstanceIsStaleForAnotherStart() async {
        let w = World()
        await w.provision()
        let a1 = w.instance(), b = w.instance()
        let adapterA = await w.connect(a1)
        w.providers.stopped(a1.token)
        _ = w.started(a1.token)                                   // reused: live again, under generation 2
        await w.connect(b, other: true)
        #expect(adapterA.stopCount == 1)
    }

    /// A stop from an instance whose own start never reached the controller ends a session whose lease is no longer
    /// current (stale), rather than being ignored.
    @Test func aStopEndsASessionWhoseLeaseIsNoLongerCurrent() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        w.providers.stopped(a.token)
        await w.h.controller.stop(reason: .userInitiated, owner: b)
        #expect(await w.h.phase == .idle)
        #expect(adapterA.stopCount == 1)
    }

    // MARK: Codex review 1 and 2: reused instances, through the real router

    /// Codex review 1: a cancel for a live, current start does reach that start's own host (not the current one).
    @Test func theRouterCancelsTheOwnersHostNotTheCurrentOne() async {
        let w = World(routed: true)
        await w.provision()
        let a = w.instance(), b = w.instance()
        await w.connect(a)
        let hostA = w.host(a)
        await w.connect(b, other: true, killSwitch: true)                   // H1: A preempted, its own provider cancelled
        #expect(hostA?.cancelledCodes == [.supersededByKillSwitch])
        #expect(w.host(b)?.cancelledCodes == [])
    }

    /// Codex review 2: generation 1's START arrives late (actor order isn't FIFO), after generation 2 of the same
    /// instance connected: it ends with `.startCancelled` and touches nothing of generation 2.
    @Test(arguments: [false, true])
    func aDelayedGeneration1StartLeavesGeneration2Alone(killSwitch: Bool) async {
        let w = World(routed: true)
        await w.provision()
        let t = w.providers.makeToken()
        let g1 = w.started(t)
        w.providers.stopped(t)
        let g2 = w.started(t)
        let adapter2 = await w.connect(g2, killSwitch: killSwitch)
        #expect(w.code(await w.value(w.start(g1, other: true, killSwitch: !killSwitch), "gen 1")) == .startCancelled)
        #expect(adapter2.stopCount == 0)
        #expect(await w.h.phase == .connected)
        #expect(w.host(g2)?.cancelledCodes == [])
        #expect(w.binds.list == [t])
    }

    /// `stopTunnel` of A was delivered (marked at once) but its Task hasn't reached the controller when B's start does:
    /// A's session is stale and B replaces it; A's late stop then leaves B's session alone.
    @Test func aStartAfterTheOwnersStopWasDeliveredReplacesTheSessionAndTheLateStopIsIgnored() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        w.providers.stopped(a.token)                                        // ProviderSeat.stopTunnel, synchronous part
        let adapterB = await w.connect(b, other: true)
        #expect(adapterA.stopCount == 1)
        await w.h.controller.stop(reason: .userInitiated, owner: a)         // A's stop Task arrives late
        #expect(await w.h.phase == .connected)
        #expect(adapterB.stopCount == 0)
        let snap = await w.h.controller.snapshot()
        #expect(snap.profileID == w.otherPID)
        #expect(w.binds.list == [a.token, b.token])
    }

    /// Review M3, reuse: the same instance's stop (generation 1) and next start (generation 2) reach the controller in
    /// reverse order. The late stop must not end the new session.
    @Test func aReusedInstancesLateStopDoesNotEndItsNewerSession() async {
        let w = World()
        await w.provision()
        let a1 = w.instance()
        await w.connect(a1)
        w.providers.stopped(a1.token)                                       // stopTunnel (gen 1) delivered
        let a2 = w.started(a1.token)                              // startTunnel (gen 2) delivered
        let adapter2 = await w.connect(a2)                                  // its Task runs first
        await w.h.controller.stop(reason: .userInitiated, owner: a1)        // then gen 1's stop
        #expect(await w.h.phase == .connected)
        #expect(adapter2.stopCount == 0)
    }

    /// Review M3: the starting instance is stopped while its start waits for a stale session's teardown: the start
    /// ends with `.startCancelled`, nothing is bound and no session begins.
    @Test func aStartWhoseInstanceStoppedDuringTheReplaceIsCancelled() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        adapterA.s.withLock { $0.hangStop = true }                          // a slow engine teardown
        w.providers.stopped(a.token)                                        // A's session is stale
        let tb = w.start(b, other: true)
        #expect(await waitUntil { adapterA.stopCount == 1 })                // B waits in the replace
        w.providers.stopped(b.token)                                        // NE stops B meanwhile
        let stopB = Task { await w.h.controller.stop(reason: .userInitiated, owner: b) }
        adapterA.releaseStop()
        #expect(w.code(await w.value(tb, "B")) == .startCancelled)
        await stopB.value
        #expect(w.binds.list == [a.token])
        #expect(w.h.factory.adapters.count == 1)
        #expect(await w.h.phase == .idle)
    }

    /// Review M3: `bind` reports the provider gone: the start fails instead of running unbound.
    @Test func aStartWhoseProviderIsGoneAtBindIsCancelled() async {
        let w = World()
        await w.provision()
        let r = await w.value(w.start(w.instance(), bindSucceeds: false), "A")
        #expect(w.code(r) == .startCancelled)
        #expect(w.h.factory.adapters.isEmpty)
        #expect(await w.h.phase == .idle)
    }

    /// A provider freed without `stopTunnel` (deinit marks it stopped): its session is stale.
    @Test func aFreedInstancesSessionIsReplaced() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)
        w.providers.stopped(a.token)                                        // PacketTunnelProvider.deinit
        await w.connect(b, other: true)
        #expect(adapterA.stopCount == 1)
    }

    /// A session no instance named (tests, an older caller) is replaced as before.
    @Test func aSessionWithoutAnOwnerIsReplaced() async {
        let w = World()
        await w.provision()
        let legacy = await w.h.connect()                                    // start(_:) without an owner
        await w.connect(w.instance(), other: true)
        #expect(legacy.stopCount == 1)
    }

    @Test func afterTheRunningInstanceStopsAnotherCanStart() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        await w.connect(a)
        #expect(w.code(await w.value(w.start(b, other: true), "B")) == .anotherTunnelActive)
        await w.stopTunnel(a)
        #expect(await w.h.phase == .idle)
        let b2 = w.instance()                                               // NE's next start of B: a new instance
        await w.connect(b2, other: true)
        let snap = await w.h.controller.snapshot()
        #expect(snap.profileID == w.otherPID && snap.phase == .connected)
        #expect(w.binds.list == [a.token, b2.token])
    }

    /// Review M4: a refused instance's later start on the same instance (NE reusing it once A is gone) is accepted.
    @Test func aRefusedInstanceIsAcceptedOnItsNextStart() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b1 = w.instance()
        await w.connect(a)
        #expect(w.code(await w.value(w.start(b1, other: true), "B1")) == .anotherTunnelActive)
        await w.stopTunnel(a)
        let b2 = w.started(b1.token)
        await w.connect(b2, other: true)
        #expect(w.binds.list == [a.token, b1.token])
    }

    // MARK: M1: the cancel goes to the session's own provider

    // MARK: concurrent starts

    /// Two instances start at once with nothing running: exactly one gets the session, the other is refused.
    @Test func twoConcurrentStartsNeverBothRun() async {
        let w = World()
        await w.provision()
        let b = w.instance(), c = w.instance()
        let tb = w.start(b), tc = w.start(c, other: true)
        let adapter = await w.adapter(0)
        await w.finish(adapter)
        let codes = [w.code(await w.value(tb, "B")), w.code(await w.value(tc, "C"))]
        #expect(codes.filter { $0 == nil }.count == 1)
        #expect(codes.filter { $0 == .anotherTunnelActive }.count == 1)
        #expect(w.h.factory.adapters.count == 1)
        #expect(w.binds.list.count == 1)
        #expect(await w.h.phase == .connected)
    }

    /// Two instances race to replace a stale session (its owner stopped): the first tears it down, and the second, back
    /// from its own `await stop`, finds the first one's live session and is refused (never overwrites it).
    @Test func twoStartsRacingToReplaceAStaleSessionNeverBothRun() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance(), c = w.instance()
        let adapterA = await w.connect(a)
        w.providers.stopped(a.token)
        let tb = w.start(b), tc = w.start(c, other: true)
        let adapter = await w.adapter(1)
        await w.finish(adapter)
        let codes = [w.code(await w.value(tb, "B")), w.code(await w.value(tc, "C"))]
        #expect(codes.filter { $0 == nil }.count == 1)
        #expect(codes.filter { $0 == .anotherTunnelActive }.count == 1)
        #expect(adapterA.stopCount == 1)
        #expect(w.h.factory.adapters.count == 2)
        #expect(w.binds.list.count == 2)
        #expect(await w.h.phase == .connected)
    }

    // MARK: ProviderInstances and ProviderSeat (the Tunnel target's wiring, review M4)

    @Test func providerInstancesTrackLivenessAndGenerations() {
        let p = ProviderInstances()
        let a = p.makeToken(), b = p.makeToken()
        #expect(a != b)
        #expect(!p.isLive(a))
        let a1 = p.started(a)
        #expect(p.isLive(a) && !p.isLive(b) && p.isCurrent(a1))
        p.stopped(a)
        #expect(!p.isLive(a) && !p.isCurrent(a1))
        let a2 = p.started(a)                                               // NE reusing the instance
        #expect(p.isCurrent(a2) && !p.isCurrent(a1))
    }

    /// `stopTunnel` marks the instance stopped synchronously, before its Task reaches the controller; `released`
    /// (deinit) does too; the seat binds only an accepted start and reports a refusal through the completion.
    @Test func theSeatMarksSynchronouslyAndBindsOnlyAcceptedStarts() async {
        let w = World()
        await w.provision()
        let seatA = ProviderSeat(controller: w.h.controller), seatB = ProviderSeat(controller: w.h.controller)
        let bound = Binds()
        let resultA = Mutex<(done: Bool, code: LPErrorCode?)>((false, nil)), resultB = Mutex<(done: Bool, code: LPErrorCode?)>((false, nil))
        seatA.startTunnel(StartRequest(options: StartOptions(isManual: true), configuration: w.config(other: false, killSwitch: nil)),
                          bind: { _ in bound.record(seatA.token); return true }) { e in resultA.withLock { $0 = (true, e?.code) } }
        #expect(w.providers.isLive(seatA.token))                            // at once, before the Task
        let adapterA = await w.adapter(0)
        await w.finish(adapterA)
        #expect(await waitUntil { resultA.withLock { $0.done } })
        #expect(resultA.withLock { $0.code } == nil)

        seatB.startTunnel(StartRequest(options: StartOptions(isManual: false), configuration: w.config(other: true, killSwitch: nil)),
                          bind: { _ in bound.record(seatB.token); return true }) { e in resultB.withLock { $0 = (true, e?.code) } }
        #expect(await waitUntil { resultB.withLock { $0.done } })
        #expect(resultB.withLock { $0.code } == .anotherTunnelActive)
        #expect(bound.list == [seatA.token])

        let unbound = Mutex<ProviderLease?>(nil), completed = Mutex(false)
        let leaseA = seatA.currentLease
        seatA.stopTunnel(reason: .userInitiated, unbind: { l in unbound.withLock { $0 = l } }) { completed.withLock { $0 = true } }
        #expect(!w.providers.isLive(seatA.token))                           // at once, before the Task
        #expect(await waitUntil { completed.withLock { $0 } })
        #expect(unbound.withLock { $0 } == leaseA && leaseA != nil)       // L2: its own start's lease
        #expect(await w.h.phase == .idle)

        #expect(w.providers.isLive(seatB.token))
        seatB.released()                                                    // deinit
        #expect(!w.providers.isLive(seatB.token))
    }

    /// The seat's sleep/wake reach only its own session; an instance that never started drives nothing.
    @Test func theSeatsSleepIsOwnerScoped() async {
        let w = World()
        await w.provision()
        let a = w.instance()
        let adapterA = await w.connect(a)
        let idle = ProviderSeat(controller: w.h.controller)
        let done = Mutex(false)
        idle.sleep { done.withLock { $0 = true } }
        #expect(await waitUntil { done.withLock { $0 } })
        #expect(adapterA.s.withLock { $0.sleeps } == 0)
        #expect(await w.h.phase == .connected)
    }

    @Test func theErrorsBridgeWithTheirCodes() {
        let ns = LPTunnelError(.anotherTunnelActive) as NSError
        #expect(ns.domain == LPTunnelError.errorDomain && ns.code == 222)
        #expect((LPTunnelError(.supersededByKillSwitch) as NSError).code == 223)
    }
}
