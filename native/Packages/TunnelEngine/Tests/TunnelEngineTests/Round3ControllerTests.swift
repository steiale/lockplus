import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// 2.0.2 review round 3 (Codex r3 #1, #8; Fable N1–N3): the extension side.
@Suite(.timeLimit(.minutes(1))) struct Round3ControllerTests {
    /// Drives the start `t` to Connected on its adapter (`n`: the index of the adapter this start makes).
    func connected(_ h: Harness, _ t: Task<Result<Void, LPTunnelError>, Never>, adapter n: Int = 0) async {
        let a = await h.adapter(n)
        _ = await a.requestSettings(Harness.plan).value()
        a.finishStart()
        if case .failure(let e) = await t.value { Issue.record("start failed \(e.code)") }
        _ = await h.waitPhase(.connected)
    }

    static let revision2 = "client\nremote \"vpn.example\" \"1194\"\n# revision 2\n"

    // MARK: Codex r3 #1 (HIGH): background provisioning never fails an authorised kill-switch replay

    /// Connected kill-switch session → Save Only of an unverified revision (nothing provisioned) → NE restarts the session
    /// (a new process, its options replayed) → while that replay is connecting, the background check accepts revision 2 and
    /// the app provisions it → the replay's start completes with success, never an error.
    @Test func aBackgroundProvisionNeverFailsAKillSwitchReplayInFlight() async {
        let h = Harness(killSwitch: true, authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        let persisted = h.state.load()
        let h2 = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in persisted })
        await h2.provision()
        let replay = h2.start(nonce: nonce)
        let a = await h2.adapter()
        // The app's provision of the verified revision, through the real backend path (payload, then the profile change).
        let backend = EngineServiceBackend(controller: h2.controller, secrets: h2.secrets, validator: FakeValidator())
        _ = await backend.handle(.provisionProfile, request: try! LPWire.encode(ProvisionRequest(
            profileID: h2.pid, kind: h2.kind, revision: 2, payload: Data(Self.revision2.utf8), credentials: nil)),
            peer: PeerContext(uid: h2.owner, pid: 1))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(a.stopCount == 0)
        _ = await a.requestSettings(Harness.plan).value()
        a.finishStart()
        #expect(h2.code(await replay.value) == nil)
        #expect(await h2.waitPhase(.connected))
        #expect(h2.state.load().authorisedStarts[h2.key]?.nonce == nonce)
    }

    /// The same with the replay HELD (its first attempt failed): the hold stays, and its next attempt (new credentials of
    /// the same provision retry it at once) loads revision 2 under the configuration NE started with, and connects.
    @Test func aBackgroundProvisionKeepsAHeldKillSwitchReplayAndItsRetryUsesTheNewRevision() async {
        let h = Harness(killSwitch: true, onDemandRules: true, authorisation: true)
        await h.provision()
        await connected(h, h.start(manual: false))
        let persisted = h.state.load()
        let h2 = Harness(pid: h.pid, killSwitch: true, onDemandRules: false, authorisation: true, state: { _ in persisted })
        await h2.provision()
        let replay = h2.start(manual: false)                               // NE's restart after its rules went away
        (await h2.adapter()).finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await waitUntil { if case .held = await h2.phase { true } else { false } })
        await h2.provision(revision: 2, payload: Self.revision2)
        await h2.controller.profileProvisioned(h2.pid, ownerUID: h2.owner, revision: 2)
        if case .held = await h2.phase {} else { Issue.record("the hold ended") }
        await h2.controller.credentialsUpdated(h2.pid, ownerUID: h2.owner)
        let b = await h2.adapter(1)
        #expect(b.request?.payload.bytesForTest == Array(Self.revision2.utf8))
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        #expect(h2.code(await replay.value) == nil)
        #expect(await h2.waitPhase(.connected))
    }

    /// A route-protection (split, `enforceRoutes`) kill-switch start in flight is kept too.
    @Test func aRouteProtectedStartInFlightIsKept() async {
        let h = Harness(killSwitch: true, routeProtection: true)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(a.stopCount == 0)
        _ = await a.requestSettings(Harness.plan).value()
        a.finishStart()
        #expect(h.code(await t.value) == nil)
    }

    // MARK: Codex r3 #8: a keep set of more than one page

    /// 600 profiles keep consent (two pages of one batch) and one idle record without a kill switch must go: nothing is
    /// revoked after the first page alone, the union is applied once the batch is complete. A page of another batch
    /// starts over.
    @Test func aPaginatedKeepSetRevokesOnceComplete() async {
        var st = PersistedTunnelState()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let kept = (0..<600).map { _ in UUID() }
        let gone = UUID()
        let boot = BootSession.current()
        for id in kept.prefix(PersistedTunnelState.maxAuthorisedStarts - 1) {
            st.authorisedStarts[ProfileKey(ownerUID: 501, profileID: id)] = AuthorisedStart(nonce: nil, at: base, boot: boot, killSwitch: false)
        }
        st.authorisedStarts[ProfileKey(ownerUID: 501, profileID: gone)] = AuthorisedStart(nonce: nil, at: base, boot: boot, killSwitch: false)
        let h = Harness(authorisation: true, state: { _ in st })
        let pages = try! #require(RevokeUnattendedRequest.pages(keeping: Set(kept)))
        #expect(pages.count == 2 && pages.allSatisfy { $0.keepProfileIDs.count <= RevokeUnattendedRequest.maxProfiles })
        let backend = EngineServiceBackend(controller: h.controller, secrets: h.secrets, validator: FakeValidator())
        func send(_ r: RevokeUnattendedRequest) async {
            let d = try! LPWire.encode(r)
            #expect(d.count <= LPMethod.revokeUnattended.requestLimit)
            if case .failure(let e) = await backend.handle(.revokeUnattended, request: d, peer: PeerContext(uid: 501, pid: 1)) {
                Issue.record("page refused \(e.code)")
            }
        }
        await send(pages[0])
        #expect(h.state.load().authorisedStarts[ProfileKey(ownerUID: 501, profileID: gone)] != nil)
        let other = try! #require(RevokeUnattendedRequest.pages(keeping: Set(kept)))
        await send(other[0])                                               // a newer batch: the first one's page is dropped
        await send(pages[1])                                               // so the old batch's second page completes nothing
        #expect(h.state.load().authorisedStarts[ProfileKey(ownerUID: 501, profileID: gone)] != nil)
        await send(other[0])
        await send(other[1])
        let after = h.state.load().authorisedStarts
        #expect(after[ProfileKey(ownerUID: 501, profileID: gone)] == nil)
        #expect(kept.prefix(PersistedTunnelState.maxAuthorisedStarts - 1).allSatisfy { after[ProfileKey(ownerUID: 501, profileID: $0)] != nil })
    }

    // MARK: Fable N2, N3

    /// A fresh process that can't read `kern.bootsessionuuid` drops nothing (NE's restart of the running session needs
    /// its record).
    @Test func anUnreadableBootSessionDropsNoRecord() async {
        var st = PersistedTunnelState()
        let key = ProfileKey(ownerUID: 501, profileID: UUID())
        st.authorisedStarts[key] = AuthorisedStart(nonce: UUID(), at: Date(), boot: "some-boot", killSwitch: true)
        let h = Harness(authorisation: true, state: { _ in st }, bootSession: nil)
        _ = await h.phase
        #expect(h.state.load().authorisedStarts[key] != nil)
        let h2 = Harness(authorisation: true, state: { _ in st }, bootSession: "another-boot")
        _ = await h2.phase
        #expect(h2.state.load().authorisedStarts[key] == nil)
    }

    /// The running session's record says `killSwitch` as soon as its live flags do, saved at once (a crash before an
    /// orderly end keeps it unrevocable).
    @Test func theKillSwitchFlagIsRecordedWhenFirstSeen() async {
        let h = Harness(onDemandRules: true, authorisation: true)
        await h.provision()
        await connected(h, h.start(manual: false))
        #expect(h.state.load().authorisedStarts[h.key]?.killSwitch == false)
        h.host.setIncludeAllNetworks(true)
        await h.controller.recheckWaitingStarts()                          // what `ProviderSeat` does on a flag change
        let crashed = h.state.load()
        #expect(crashed.authorisedStarts[h.key]?.killSwitch == true)
        let h2 = Harness(pid: h.pid, authorisation: true, state: { _ in crashed })
        await h2.controller.revokeUnattended(keeping: [], ownerUID: h.owner)
        #expect(h2.state.load().authorisedStarts[h.key] != nil)
    }
}
