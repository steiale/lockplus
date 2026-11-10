import Foundation
import LPModel
import LPWire
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// PENDING-FOLD 50 (fixes §20 risk 25): the app pushes fresh endpoint IPs into a start held before Connected, so an
/// on-demand start whose cached IPs went stale recovers without the user.
@Suite struct ControllerPushEndpointsTests {
    /// An on-demand start against a stale cache: the IPs don't answer, the start is held (blocked) and retries the
    /// same IPs. The app's push replaces them, the hold retries at once with the new IPs, and they are cached.
    @Test func pushIntoAStaleCacheHoldRetriesNowAndCachesOnSuccess() async {
        let h = Harness(killSwitch: true, onDemandRules: true, state: { pid in
            var st = PersistedTunnelState()
            st.endpointHosts[ProfileKey(ownerUID: 501, profileID: pid)] = ["vpn.example": ["192.0.2.1"]]
            return st
        })
        await h.provision()
        let t = h.start(manual: false)                              // on-demand: no app hints, the cache alone
        let a = await h.adapter()
        #expect(a.request?.endpoints == ["vpn.example": ["192.0.2.1"]])
        a.finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        let out = await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner,
                                                   endpoints: ["VPN.example": ["198.51.100.9", "2001:db8::9"]])
        #expect(out == .retrying)
        let b = await h.adapter(1)                                   // at once, not after the backoff
        #expect(b.request?.endpoints == ["vpn.example": ["198.51.100.9", "2001:db8::9"]])
        #expect(h.interfaceCheck.checked.last == ["198.51.100.9", "2001:db8::9"])
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        #expect(h.code(await t.value) == nil)
        #expect(h.state.load().endpointHosts[h.key] == ["vpn.example": ["198.51.100.9", "2001:db8::9"]])
        #expect(h.latch == nil)
    }

    /// A retryable hold spends most of its time in a retry attempt on the old IPs (connect deadline 45/50 s): the push
    /// replaces that attempt at once; its late failure can't fail the new one (epoch).
    @Test func pushReplacesARetryInFlight() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start(endpoints: ["vpn.example": ["192.0.2.1"]])
        let a = await h.adapter()
        a.finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        await h.advance(h.clock, by: .seconds(2))                    // the backoff retry: still the old IPs
        let b = await h.adapter(1)
        #expect(await h.phase == .connecting && b.request?.endpoints == ["vpn.example": ["192.0.2.1"]])
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ["vpn.example": ["198.51.100.9"]]) == .retrying)
        let c = await h.adapter(2)
        #expect(c.request?.endpoints == ["vpn.example": ["198.51.100.9"]])
        #expect(await waitUntil { b.stopCount == 1 })
        b.finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))   // the replaced attempt's late failure
        _ = await c.requestSettings(Harness.plan).value()
        c.finishStart()
        #expect(h.code(await t.value) == nil)
        #expect(await h.waitPhase(.connected))
    }

    /// `.dnsResolutionFailed` waits for the user (nothing inside the hold can add IPs, D9-20) — except the app's push.
    @Test func pushRecoversADNSResolutionHold() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.dnsResolutionFailed, detail: "no endpoint IPs"))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.dnsResolutionFailed))))
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ["vpn.example": ["198.51.100.9"]]) == .retrying)
        let b = await h.adapter(1)
        #expect(b.request?.endpoints == ["vpn.example": ["198.51.100.9"]])
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// The same IPs (any order) change nothing: a repeated push can't loop the start.
    @Test func samePushIsUnchangedAndStartsNothing() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start(endpoints: ["vpn.example": ["192.0.2.1", "192.0.2.2"]])
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.peerUnreachable))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.peerUnreachable))))
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ["vpn.example": ["192.0.2.2", "192.0.2.1"]]) == .unchanged)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.count == 1)
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .peerUnreachable)
    }

    /// Only the caller's own profile: another uid (same UUID) or another profile of the same uid changes nothing.
    @Test func onlyTheHeldStartsOwnerAndProfile() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        let ips = ["vpn.example": ["198.51.100.9"]]
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: 502, endpoints: ips) == .notHeld)
        #expect(await h.controller.pushEndpoints(profileID: UUID(), ownerUID: h.owner, endpoints: ips) == .notHeld)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.count == 1)
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// Not a held start before Connected with a pushable reason → `.notHeld`: idle, connected, an after-Connected
    /// hold (holdBlocked waits for the user by design), a C16 non-retryable hold, an auth or TLS failure, and the
    /// kill switch off (a failed start is over).
    @Test func refusedOutsideAPushableHold() async {
        let ips = ["vpn.example": ["198.51.100.9"]]
        let idle = Harness(killSwitch: true)
        #expect(await idle.controller.pushEndpoints(profileID: idle.pid, ownerUID: idle.owner, endpoints: ips) == .notHeld)

        let up = Harness(killSwitch: true)
        await up.provision()
        let a = await up.connect()
        #expect(await up.controller.pushEndpoints(profileID: up.pid, ownerUID: up.owner, endpoints: ips) == .notHeld)
        a.emit { .fatal(LPTunnelError(.engineDied), epoch: $0) }
        #expect(await up.waitPhase(.held(.blockedAfterFailure(.engineDied))))
        #expect(await up.controller.pushEndpoints(profileID: up.pid, ownerUID: up.owner, endpoints: ips) == .notHeld)

        let tls = Harness(killSwitch: true)
        await tls.provision()
        _ = tls.start()
        (await tls.adapter()).finishStart(.failure(.failed(LPTunnelError(.serverIdentityMismatch))))
        #expect(await tls.waitPhase(.held(.blockedAfterFailure(.serverIdentityMismatch))))
        #expect(await tls.controller.pushEndpoints(profileID: tls.pid, ownerUID: tls.owner, endpoints: ips) == .notHeld)

        let c16 = Harness(killSwitch: true, onDemandRules: true)
        await c16.provision()
        _ = c16.start(manual: false)
        (await c16.adapter()).finishStart(.failure(.failed(LPTunnelError(.authFailed))))
        #expect(await c16.waitPhase(.held(.nonRetryable(.authFailed))))
        #expect(await c16.controller.pushEndpoints(profileID: c16.pid, ownerUID: c16.owner, endpoints: ips) == .notHeld)
        #expect(c16.factory.adapters.count == 1)
    }

    /// Defence in depth behind the wire check: malformed entries are dropped; nothing usable → `.notHeld`.
    @Test func controllerKeepsOnlyHostnamesAndLiterals() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ["192.0.2.5": ["192.0.2.6"], "x.example": ["nope"]]) == .notHeld)
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ["x.example": ["nope", "198.51.100.3"]]) == .retrying)
        #expect(await h.adapter(1).request?.endpoints == ["x.example": ["198.51.100.3"]])
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// E2E-2 (both VMs): a WireGuard retry applies its settings before the first handshake, so on dead IPs it waits
    /// out the connect deadline in `.establishing`; the push must replace it there. OpenVPN's `.establishing` (the
    /// server answered) is never replaced.
    @Test(arguments: [VPNProtocolKind.wireGuard, .openVPN])
    func pushIntoARetryWaitingInEstablishing(kind: VPNProtocolKind) async {
        let h = Harness(kind: kind, killSwitch: true)
        await h.provision()
        let t = h.start(endpoints: ["vpn.example": ["192.0.2.1"]])
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        await h.advance(h.clock, by: .seconds(2))
        let b = await h.adapter(1)
        _ = await b.requestSettings(Harness.plan).value()              // settings up, the handshake never comes
        #expect(await h.phase == .establishing)
        let out = await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ["vpn.example": ["198.51.100.9"]])
        if kind == .wireGuard {
            #expect(out == .retrying)
            #expect(await h.adapter(2).request?.endpoints == ["vpn.example": ["198.51.100.9"]])
            #expect(await waitUntil { b.stopCount == 1 })
        } else {
            #expect(out == .notHeld)
            try? await Task.sleep(for: .milliseconds(20))
            #expect(h.factory.adapters.count == 2 && b.stopCount == 0)
        }
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    // MARK: review PF-R2 … R4

    /// PF-R2: a retry of the hold that ends in a prompt is no longer a pushable hold (the prompt, then the attempt
    /// carrying the answer, an OTP, must never be replaced: the answer would be lost and a rejection would count).
    @Test func promptAndAnsweredAttemptAreNeverReplaced() async throws {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        await h.advance(h.clock, by: .seconds(2))
        (await h.adapter(1)).finishStart(.failure(.auth(.crv1())))          // the retry asks for a code
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let ips = ["vpn.example": ["198.51.100.9"]]
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ips) == .notHeld)
        #expect(await h.controller.snapshot().holdReason == nil)
        let p = try #require(await waitUntil { h.sink.prompts.count == 1 } ? h.sink.prompts[0] : nil)
        try await h.controller.answerAuth(promptID: p.promptID, answer: AuthAnswerSecrets(response: .text("123456")), callerUID: h.owner)
        let c = await h.adapter(2)
        #expect(c.request?.stash?.promptID == p.promptID)
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ips) == .notHeld)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.count == 3 && c.stopCount == 0)
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// PF-R3: a `.backoff` latch holds an on-demand start until `notBefore`; a push of the IPs it would use anyway (the
    /// cache) is `.unchanged` and starts nothing early. Different IPs still retry now.
    @Test func backoffLatchHoldsAgainstAPushOfTheCachedIPs() async {
        let notBefore = MutableWallClock().now.addingTimeInterval(3600)
        let h = Harness(killSwitch: true, onDemandRules: true, state: { pid in
            var st = ControllerStartTests.latched(.backoff, .connectTimeout, notBefore: notBefore)(pid)
            st.endpointHosts[ProfileKey(ownerUID: 501, profileID: pid)] = ["vpn.example": ["192.0.2.1"]]
            return st
        })
        await h.provision()
        let t = h.start(manual: false)
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ["vpn.example": ["192.0.2.1"]]) == .unchanged)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.isEmpty)
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ["vpn.example": ["198.51.100.9"]]) == .retrying)
        #expect(await h.adapter().request?.endpoints == ["vpn.example": ["198.51.100.9"]])
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// PF-R4: at most `maxPushesPerSession` pushes per session are accepted; then `.unchanged`.
    @Test func maxPushesPerSessionPerSession() async {
        let h = Harness(killSwitch: true, configure: { $0.maxPushesPerSession = 2 })
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.dnsResolutionFailed))))
        for i in 1...2 {
            #expect(await h.waitPhase(.held(.blockedAfterFailure(.dnsResolutionFailed))))
            #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ["vpn.example": ["198.51.100.\(i)"]]) == .retrying)
            (await h.adapter(i)).finishStart(.failure(.failed(LPTunnelError(.dnsResolutionFailed))))
        }
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.dnsResolutionFailed))))
        #expect(await h.controller.pushEndpoints(profileID: h.pid, ownerUID: h.owner, endpoints: ["vpn.example": ["198.51.100.3"]]) == .unchanged)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.count == 3)
        #expect(ControllerConfig().maxPushesPerSession == 10)
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// PF-R4: the cache keeps only hostnames the profile references (the app may name others), at most 8.
    @Test func cacheKeepsOnlyReferencedHostsAndAtMostEight() async {
        let h = Harness()
        await h.provision()
        let t = h.start(endpoints: ["vpn.example": ["198.51.100.1"], "elsewhere.example": ["198.51.100.2"]])
        let a = await h.adapter()
        #expect(a.request?.endpoints["elsewhere.example"] == ["198.51.100.2"])     // used for the attempt
        _ = await a.requestSettings(Harness.plan).value()
        a.finishStart()
        _ = await t.value
        #expect(h.state.load().endpointHosts[h.key] == ["vpn.example": ["198.51.100.1"]])

        let many = Harness()
        let names = (0..<10).map { "h\($0).example" }
        await many.provision(payload: "client\n" + names.map { "remote \"\($0)\" \"1194\"\n" }.joined() + "remote \"192.0.2.9\"\n")
        let t2 = many.start(endpoints: Dictionary(uniqueKeysWithValues: names.map { ($0, ["198.51.100.1"]) }))
        let b = await many.adapter()
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        _ = await t2.value
        #expect(many.state.load().endpointHosts[many.key].map { Set($0.keys) } == Set(names.sorted().prefix(8)))
    }

    @Test func referencedHostnamesPerKind() {
        let ovpn = "client\nremote \"VPN.example\" \"1194\"\nremote \"192.0.2.1\"\nremote \"[2001:db8::1]\"\n<ca>\nremote \"in.ca.example\"\n</ca>\n"
            + "<connection>\nremote \"c.example\" \"443\"\n</connection>\nhttp-proxy \"Proxy.example\" \"8080\"\n"
        #expect(EndpointHostnames.referenced(kind: .openVPN, payload: .text(ovpn)) == ["vpn.example", "c.example", "proxy.example"])
        let wg = "[Interface]\nPrivateKey = endpoint=x\n[Peer]\n  endpoint = WG.example:51820\n[Peer]\nEndpoint=[2001:db8::1]:51820\n[Peer]\nEndpoint = 192.0.2.1:1\n"
        #expect(EndpointHostnames.referenced(kind: .wireGuard, payload: .text(wg)) == ["wg.example"])
    }
}

/// The XPC half: decode caps and strict literals, uid namespace, reply shape.
@Suite struct PushEndpointsBackendTests {
    let alice = PeerContext(uid: 501, pid: 1)
    let mallory = PeerContext(uid: 502, pid: 2)

    func push(_ b: EngineServiceBackend<ManualClock>, _ id: UUID, _ m: [String: [String]], as peer: PeerContext) async -> Result<Data?, LPError> {
        await b.handle(.pushEndpoints, request: try! LPWire.encode(PushEndpointsRequest(profileID: id, endpoints: m)), peer: peer)
    }

    func outcome(_ r: Result<Data?, LPError>) -> PushEndpointsReply.Outcome? {
        guard case .success(let d?) = r else { return nil }
        return try? LPWire.decode(PushEndpointsReply.self, d, max: LPMethod.pushEndpoints.replyLimit).outcome
    }

    @Test func ownerPushRetriesOthersAreRefused() async {
        let h = Harness(killSwitch: true)
        let b = EngineServiceBackend(controller: h.controller, secrets: h.secrets, validator: FakeValidator())
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.dnsResolutionFailed))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.dnsResolutionFailed))))
        // Another uid: alice's profile isn't in its namespace.
        let r1 = await push(b, h.pid, ["vpn.example": ["198.51.100.9"]], as: mallory)
        if case .failure(let e) = r1 { #expect(e.code == .profileNotProvisioned) } else { Issue.record("mallory accepted") }
        // Not a literal: rejected at decode, before the controller sees it.
        let r2 = await push(b, h.pid, ["vpn.example": ["evil.example"]], as: alice)
        if case .failure(let e) = r2 { #expect(e.code == .malformedRequest) } else { Issue.record("hostname accepted as an IP") }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.count == 1)
        #expect(outcome(await push(b, h.pid, ["vpn.example": ["198.51.100.9"]], as: alice)) == .retrying)
        _ = await h.adapter(1)
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    @Test func oversizedRequestIsRejectedBeforeDecoding() async {
        let h = Harness(killSwitch: true)
        let b = EngineServiceBackend(controller: h.controller, secrets: h.secrets, validator: FakeValidator())
        let r = await b.handle(.pushEndpoints, request: Data(count: LPMethod.pushEndpoints.requestLimit + 1), peer: alice)
        if case .failure(let e) = r { #expect(e.code == .payloadTooLarge) } else { Issue.record("accepted") }
    }
}
