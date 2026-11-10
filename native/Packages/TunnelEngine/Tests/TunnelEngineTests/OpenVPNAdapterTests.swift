import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// A scripted openvpn3 client: `connect()` runs the actions the test pushes, on the adapter's connect thread.
final class FakeOVPNClient: OpenVPNClient, @unchecked Sendable {
    enum Action { case event(String, String, Bool), establish(OVPNTunPlan), log(String), end }
    let delegate: any OpenVPNClientDelegate
    let config: OVPNClientConfig
    struct S { var queue: [Action] = []; var creds: OVPNProvideCreds?; var stopped = 0; var reconnects = 0; var established: [Int32] = []
        var order: [String] = []; var running = false; var done = false; var paused = 0; var resumed = 0 }
    let s = Mutex(S())
    let sem = DispatchSemaphore(value: 0)
    let orderLog: Mutex<[String]>?
    init(_ config: OVPNClientConfig, _ d: any OpenVPNClientDelegate) { self.config = config; delegate = d; orderLog = nil }

    func push(_ a: Action) { s.withLock { $0.queue.append(a) }; sem.signal() }
    func provideCredentials(_ c: OVPNProvideCreds) -> Bool { s.withLock { $0.creds = c }; return true }
    func connect() -> OVPNConnectStatus {
        s.withLock { $0.running = true }
        defer { s.withLock { $0.done = true } }
        while true {
            sem.wait()
            guard let a = s.withLock({ st -> Action? in st.queue.isEmpty ? nil : st.queue.removeFirst() }) else { continue }
            switch a {
            case .event(let n, let i, let f): delegate.event(name: n, info: i, error: f, fatal: f)
            case .establish(let p):
                let fd = delegate.establish(p)
                s.withLock { $0.established.append(fd); $0.order.append("establish->\(fd >= 0 ? "fd" : "-1")") }
            case .log(let l): delegate.log(l)
            case .end:
                delegate.event(name: "DISCONNECTED", info: "", error: false, fatal: false)
                return OVPNConnectStatus(error: false)
            }
        }
    }
    let stopHook = Mutex<(@Sendable () -> String)?>(nil)
    func stop() {
        let note = stopHook.withLock { $0 }?() ?? ""
        s.withLock { $0.stopped += 1; $0.order.append("stop" + note) }; push(.end)
    }
    func reconnect(seconds: Int) { s.withLock { $0.reconnects += 1 } }
    func pause(reason: String) { s.withLock { $0.paused += 1 } }
    func resume() { s.withLock { $0.resumed += 1 } }
    func transportStats() -> OVPNTransportStats { OVPNTransportStats(bytesIn: 10, bytesOut: 20, lastPacketReceivedMs: 1000) }
    func connectionInfo() -> OVPNConnectionInfo? { OVPNConnectionInfo(serverIP: "198.51.100.7", vpnIPv4: "10.8.0.2", cipher: "AES-256-GCM") }

    var running: Bool { s.withLock { $0.running } }
    var creds: OVPNProvideCreds? { s.withLock { $0.creds } }
}

final class FakeOVPNFactory: OpenVPNClientFactory, @unchecked Sendable {
    let clients = Mutex<[FakeOVPNClient]>([])
    let failNext = Mutex<LPTunnelError?>(nil)
    func makeClient(config: OVPNClientConfig, delegate: any OpenVPNClientDelegate) throws(LPTunnelError) -> any OpenVPNClient {
        if let e = failNext.withLock({ f -> LPTunnelError? in defer { f = nil }; return f }) { throw e }
        let c = FakeOVPNClient(config, delegate); clients.withLock { $0.append(c) }; return c
    }
    func parseDynamicChallenge(_ cookie: SecretBytes) -> OVPNDynamicChallenge? {
        OVPNDynamicChallenge(challenge: "Enter code", echo: true, responseRequired: true, username: "alice")
    }
    func client(_ n: Int) async -> FakeOVPNClient {
        _ = await waitUntil { self.clients.withLock { $0.count > n && $0[n].running } }
        return clients.withLock { $0[n] }
    }
    var count: Int { clients.withLock { $0.count } }
}

@Suite struct OpenVPNAdapterTests {
    let factory = FakeOVPNFactory()
    let clock = ManualClock()

    func adapter() -> OpenVPNAdapter<ManualClock> { OpenVPNAdapter(factory: factory, clock: clock, log: LogRing(capacity: 100)) }

    /// Default: kill switch off, so openvpn3 may still resolve "vpn" itself (`providerDNS`).
    func req(creds: CredentialSecrets? = CredentialSecrets(username: .text("alice"), password: .text("pw")), stash: StashBinding? = nil,
             plane: DataPlane = .utunFD, pump: PacketFlowPump? = nil, payload: String = "client\nremote \"vpn\"\n",
             endpoints: [String: [String]] = [:], providerDNS: Bool = true) -> AdapterStart {
        AdapterStart(profileID: UUID(), payload: .text(payload), credentials: creds, stash: stash, policy: .init(killSwitch: !providerDNS),
                     connectTimeout: .seconds(50), endpoints: endpoints, providerDNS: providerDNS, dataPlane: plane, pump: pump)
    }

    // MARK: §9.3 remotes (draft 9, S2 E10)

    @Test func clientGetsIPLiteralRemotesFromTheStart() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(payload: "client\nremote \"VPN.example\" \"1194\" \"udp\"\nremote \"192.0.2.9\" \"443\" \"tcp\"\n",
                           endpoints: ["vpn.example": ["198.51.100.1", "2001:db8::1"]], providerDNS: false), log)
        let c = await factory.client(0)
        #expect(String(decoding: c.config.content.bytesForTest, as: UTF8.self) ==
                "client\nremote \"198.51.100.1\" \"1194\" \"udp\"\nremote \"2001:db8::1\" \"1194\" \"udp\"\nremote \"192.0.2.9\" \"443\" \"tcp\"\n")
        await a.stop(); _ = await t.value
    }

    @Test func underTheFlagAHostnameWithoutIPsFailsWithoutAClient() async {
        let a = adapter()
        let r = await run(a, req(endpoints: [:], providerDNS: false), EventLog()).value
        guard case .failure(.failed(let e)) = r else { Issue.record("started"); return }
        #expect(e.code == .dnsResolutionFailed && factory.count == 0)
    }

    /// PF 51: under the flag the proxy hostname becomes the app's IP; without one the attempt fails with a clear detail
    /// and no client is made (openvpn3 would hang 30 s resolving it, S2 E10).
    @Test func underTheFlagTheProxyHostIsAnIPOrTheAttemptFails() async {
        let text = "client\nremote \"192.0.2.9\" \"443\" \"tcp\"\nhttp-proxy \"proxy.example\" \"8080\" \"auto\"\n"
        let a = adapter(), log = EventLog()
        let t = run(a, req(payload: text, endpoints: ["proxy.example": ["198.51.100.8", "2001:db8::8"]], providerDNS: false), log)
        let c = await factory.client(0)
        #expect(String(decoding: c.config.content.bytesForTest, as: UTF8.self) ==
                "client\nremote \"192.0.2.9\" \"443\" \"tcp\"\nhttp-proxy \"198.51.100.8\" \"8080\" \"auto\"\n")
        await a.stop(); _ = await t.value

        let b = adapter()
        let r = await run(b, req(payload: text, endpoints: [:], providerDNS: false), EventLog()).value
        guard case .failure(.failed(let e)) = r else { Issue.record("started"); return }
        #expect(e.code == .dnsResolutionFailed && e.detail == "proxy host not resolved")
        #expect(factory.count == 1)                                   // no second client
    }

    func run(_ a: OpenVPNAdapter<ManualClock>, _ r: AdapterStart, _ log: EventLog) -> Task<Result<Void, AdapterStartError>, Never> {
        Task { do throws(AdapterStartError) { try await a.start(r, events: log.sink, epoch: 2); return .success(()) } catch { return .failure(error) } }
    }

    static let tun: OVPNTunPlan = {
        var t = OVPNTunPlan(); t.addresses = [.init("10.8.0.2", 24, ipv6: false)]; t.remoteAddress = "198.51.100.7"
        t.dnsServers = [.init(priority: 0, addresses: ["10.8.0.1"])]; return t
    }()

    @Test func fixedConfigNeverAdvertisesSSOAndNoLegacyAlgorithms() {
        let f = OVPNFixedConfig()
        #expect(f.ssoMethods == "" && !f.retryOnAuthFailed && !f.tunPersist && !f.dhcpSearchDomainsAsSplitDomains)
        #expect(f.compressionMode == "asym" && f.connTimeout == 0 && f.info && !f.echo && !f.googleDnsFallback)
        #expect(!Mirror(reflecting: f).children.contains { $0.label?.lowercased().contains("legacy") == true })
    }

    @Test func profileFacts() {
        let facts = CanonicalProfileFacts()
        #expect(!facts.hasCertAndKey(.text("client\n<ca>\nx\n</ca>\n")))
        #expect(facts.hasCertAndKey(.text("client\n<cert>\nx\n</cert>\n<key>\ny\n</key>\n")))
        #expect(facts.needsNonPreferredDC(.text("cipher \"AES-256-CBC\"\n")))
        #expect(!facts.needsNonPreferredDC(.text("cipher \"AES-256-GCM\"\n")))
    }

    @Test func proxyCredentialsReachTheFactoryConfig() async {
        let a = adapter(), log = EventLog()
        let creds = CredentialSecrets(username: .text("alice"), password: .text("pw"), proxyUsername: .text("pu"), proxyPassword: .text("pp"))
        let t = run(a, req(creds: creds), log)
        let c = await factory.client(0)
        #expect(c.config.proxyUsername?.bytesForTest == Array("pu".utf8) && c.config.proxyPassword?.bytesForTest == Array("pp".utf8))
        await a.stop()
        _ = await t.value
    }

    /// §7.3 / §15.1 shim fd ownership: establish returns a dup, never the provider's fd; closing it leaves NE's fd valid.
    @Test func connectsOnADupOfTheProviderFD() async throws {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        let c = await factory.client(0)
        #expect(c.config.disableClientCert)                               // no cert+key in the profile
        #expect(c.creds?.username?.bytesForTest == Array("alice".utf8) && c.creds?.password?.bytesForTest == Array("pw".utf8))
        let pair = try SocketPair.make()                                  // stands in for NE's utun fd
        defer { close(pair.engineEnd); close(pair.pumpEnd) }
        c.push(.establish(Self.tun))
        #expect(await waitUntil { log.settings.count == 1 })
        #expect(log.settings[0].0.dns?.servers == ["10.8.0.1"])
        log.settings[0].1.answer(.fd(pair.pumpEnd))
        #expect(await waitUntil { c.s.withLock { $0.established.count } == 1 })
        let dupd = c.s.withLock { $0.established[0] }
        #expect(dupd >= 0 && dupd != pair.pumpEnd)
        close(dupd)                                                        // openvpn3 closes exactly its dup
        #expect(fcntl(pair.pumpEnd, F_GETFD) != -1)
        c.push(.event("CONNECTED", "", false))
        if case .failure = await t.value { Issue.record("start failed") }
        let st = await a.statistics()
        #expect(st.rxBytes == 10 && st.txBytes == 20 && st.cipher == "AES-256-GCM")
        await a.stop()
        #expect(c.s.withLock { $0.stopped } == 1)
    }

    /// M4: a server pushing `route 0.0.0.0 128.0.0.0 net_gateway` + `128.0.0.0/1` on a full tunnel (the whole
    /// address space outside the tunnel) is rejected before any settings are applied.
    @Test func pushedSlashOneBypassIsRejected() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        let c = await factory.client(0)
        var tp = Self.tun
        tp.rerouteIPv4 = true
        tp.excludedRoutes = [.init("0.0.0.0", 1, ipv6: false), .init("128.0.0.0", 1, ipv6: false)]
        c.push(.establish(tp))
        guard case .failure(.failed(let e)) = await t.value else { Issue.record("not rejected"); return }
        #expect(e.code == .pushedOptionRejected && e.detail == "route")
        #expect(log.settings.isEmpty)
        #expect(c.s.withLock { $0.established } == [-1])
    }

    /// M4: the same routes are accepted when the profile itself declares them as net_gateway routes.
    @Test func declaredNetGatewayRoutesAreAccepted() async throws {
        let a = adapter(), log = EventLog()
        let payload = "client\nremote \"vpn\"\nroute \"0.0.0.0\" \"128.0.0.0\" \"net_gateway\"\nroute 128.0.0.0 128.0.0.0 net_gateway\n"
        let t = run(a, req(payload: payload), log)
        let c = await factory.client(0)
        var tp = Self.tun
        tp.rerouteIPv4 = true
        tp.excludedRoutes = [.init("0.0.0.0", 1, ipv6: false), .init("128.0.0.0", 1, ipv6: false), .init("192.168.1.0", 24, ipv6: false)]
        c.push(.establish(tp))
        #expect(await waitUntil { log.settings.count == 1 })
        #expect(log.settings[0].0.excludedRoutes4.count == 3)
        let pair = try SocketPair.make()
        defer { close(pair.engineEnd); close(pair.pumpEnd) }
        log.settings[0].1.answer(.fd(pair.pumpEnd))
        #expect(await waitUntil { c.s.withLock { $0.established.count } == 1 })
        close(c.s.withLock { $0.established[0] })
        c.push(.event("CONNECTED", "", false))
        if case .failure = await t.value { Issue.record("start failed") }
        await a.stop()
    }

    @Test func dynamicChallengeIsAnAuthOutcome() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        let c = await factory.client(0)
        c.push(.event("DYNAMIC_CHALLENGE", "CRV1:R,E:c3RhdGU=:YWxpY2U=:Enter code", true))
        guard case .failure(.auth(let ch)) = await t.value else { Issue.record("no auth"); return }
        #expect(ch.kind == .dynamicChallenge && ch.reason == .initial && ch.lockedUsername == "alice" && ch.cookie != nil)
        #expect(ch.carriedPassword == nil)                                 // stored creds: the store keeps its own copy
    }

    /// Draft 7: AUTH_FAILED after a CRV1 response runs exactly one fresh first connect (no cookie) inside the start.
    @Test func authFailedAfterCRV1ResponseFetchesANewChallenge() async {
        let a = adapter(), log = EventLog()
        let b = StashBinding(promptID: UUID(), answer: AuthAnswerSecrets(response: .text("123456")),
                             carriedUsername: .text("alice"), carriedPassword: .text("base"), cookie: .text("CRV1:R,E:old:YWxpY2U=:x"))
        let t = run(a, req(creds: nil, stash: b), log)
        let c1 = await factory.client(0)
        #expect(b.isConsumed)                                              // consumed at provide_creds
        #expect(c1.creds?.response?.bytesForTest == Array("123456".utf8) && c1.creds?.dynamicChallengeCookie != nil)
        #expect(c1.creds?.password?.bytesForTest == Array("base".utf8))  // non-empty base password
        c1.push(.event("AUTH_FAILED", "", true))
        let c2 = await factory.client(1)
        #expect(c2.creds?.dynamicChallengeCookie == nil && c2.creds?.response == nil)
        #expect(c2.creds?.password?.bytesForTest == Array("base".utf8))
        c2.push(.event("DYNAMIC_CHALLENGE", "CRV1:R,E:new:YWxpY2U=:Enter code", true))
        guard case .failure(.auth(let ch)) = await t.value else { Issue.record("no auth"); return }
        #expect(ch.kind == .dynamicChallenge && ch.reason == .rejected && ch.carriedPassword?.bytesForTest == Array("base".utf8))
        #expect(factory.count == 2)
    }

    @Test func secondAuthFailedAfterTheRefetchIsARejection() async {
        let a = adapter(), log = EventLog()
        let b = StashBinding(promptID: UUID(), answer: AuthAnswerSecrets(response: .text("1")), carriedUsername: .text("alice"),
                             carriedPassword: .text("base"), cookie: .text("CRV1:x"))
        let t = run(a, req(creds: nil, stash: b), log)
        await factory.client(0).push(.event("AUTH_FAILED", "", true))
        await factory.client(1).push(.event("AUTH_FAILED", "bad", true))
        guard case .failure(.auth(let ch)) = await t.value else { Issue.record("no auth"); return }
        #expect(ch.kind == .userPass && ch.reason == .rejected && factory.count == 2)
    }

    @Test func authFailedWithStoredCredentials() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        await factory.client(0).push(.event("AUTH_FAILED", "user locked\u{7}", true))
        guard case .failure(.auth(let ch)) = await t.value else { Issue.record("no auth"); return }
        #expect(ch.reason == .rejected && ch.rejectedStoredCredentials && ch.challengeText == "user locked")
    }

    @Test(arguments: [("NEED_CREDS", AuthReason.initial), ("SESSION_EXPIRED", .sessionExpired)])
    func promptEvents(name: String, reason: AuthReason) async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(creds: nil), log)
        await factory.client(0).push(.event(name, "", true))
        guard case .failure(.auth(let ch)) = await t.value else { Issue.record("no auth"); return }
        #expect(ch.reason == reason && ch.kind == .userPass)
    }

    @Test func webAuthIsRefusedEvenDuringAuthPending() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        let c = await factory.client(0)
        c.push(.event("AUTH_PENDING", "timeout 60", false))
        #expect(await waitUntil { log.count { if case .authRequired(let ch, _) = $0 { return ch.kind == .pendingApproval }; return false } == 1 })
        c.push(.event("INFO", "WEB_AUTH::https://sso.example", false))
        guard case .failure(.failed(let e)) = await t.value else { Issue.record("not failed"); return }
        #expect(e.code == .webAuthUnsupported)
        #expect(await waitUntil { c.s.withLock { $0.stopped } >= 1 })
    }

    @Test func pushedOptionRejectIsFatalWithTheNameOnly() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        await factory.client(0).push(.event("CLIENT_RESTART", "rejected pushed option: route-gateway 10.0.0.1 secret", false))
        guard case .failure(.failed(let e)) = await t.value else { Issue.record("not failed"); return }
        #expect(e.code == .pushedOptionRejected && e.detail == "route-gateway")
    }

    @Test func bfCBCFallbackIsLegacyCryptoUnavailable() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        await factory.client(0).push(.log("openssl_cipher_error: BF-CBC: not usable"))
        guard case .failure(.failed(let e)) = await t.value else { Issue.record("not failed"); return }
        #expect(e.code == .legacyCryptoUnavailable)
    }

    @Test func certVerifyFailIsServerIdentityMismatch() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        await factory.client(0).push(.event("CERT_VERIFY_FAIL", "", true))
        guard case .failure(.failed(let e)) = await t.value else { Issue.record("not failed"); return }
        #expect(e.code == .serverIdentityMismatch)
    }

    /// §7.3: every stop path answers a pending EstablishTicket with -1 BEFORE client.stop().
    @Test func stopDuringEstablishAnswersMinusOneFirst() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        let c = await factory.client(0)
        c.push(.establish(Self.tun))
        #expect(await waitUntil { log.settings.count == 1 })
        let ticket = log.settings[0].1
        c.stopHook.withLock { $0 = { ticket.answered == .failed(.startCancelled) ? "(ticket answered)" : "(ticket pending)" } }
        await a.stop()
        #expect(c.s.withLock { $0.order }.contains("stop(ticket answered)"))
        #expect(c.s.withLock { $0.established } == [-1])
        if case .success = await t.value { Issue.record("started") }
    }

    @Test func stashIsNotConsumedWhenTheClientCannotBeCreated() async {
        let a = adapter(), log = EventLog()
        factory.failNext.withLock { $0 = LPTunnelError(.profileInvalid) }
        let b = StashBinding(promptID: UUID(), answer: AuthAnswerSecrets(password: .text("x")), carriedUsername: nil, carriedPassword: nil, cookie: nil)
        _ = await run(a, req(stash: b), log).value
        #expect(!b.isConsumed)
    }

    @Test func afterConnectedEventsAndReconnectAuth() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        let c = await factory.client(0)
        c.push(.event("CONNECTED", "", false))
        _ = await t.value
        c.push(.event("RECONNECTING", "", false))
        #expect(await waitUntil { log.count { if case .reconnecting = $0 { return true }; return false } == 1 })
        c.push(.event("CONNECTED", "", false))
        #expect(await waitUntil { log.count { if case .reconnected = $0 { return true }; return false } == 1 })
        c.push(.event("NEED_CREDS", "", true))
        #expect(await waitUntil { log.count { if case .authRequired(let ch, _) = $0 { return ch.reason == .reconnect }; return false } == 1 })
        c.push(.end)
        try? await a.provideAuth(AuthAnswerSecrets(password: .text("otp2")))
        let c2 = await factory.client(1)
        #expect(c2.creds?.username?.bytesForTest == Array("alice".utf8))  // the username again
        #expect(c2.creds?.password?.bytesForTest == Array("otp2".utf8))
        c2.push(.event("CONNECTED", "", false))
        #expect(await waitUntil { log.count { if case .reconnected = $0 { return true }; return false } == 2 })
        await a.stop()
    }

    /// T2: a CRV1 challenge after Connected: the answer goes back with the cookie and the session's base credentials.
    @Test func crv1AfterConnectedCarriesCookieAndBaseCredentials() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        let c = await factory.client(0)
        c.push(.event("CONNECTED", "", false))
        _ = await t.value
        c.push(.event("DYNAMIC_CHALLENGE", "CRV1:R,E:c3RhdGU=:YWxpY2U=:Enter code", true))
        #expect(await waitUntil { log.count { if case .authRequired(let ch, _) = $0 { return ch.kind == .dynamicChallenge }; return false } == 1 })
        c.push(.end)
        try? await a.provideAuth(AuthAnswerSecrets(response: .text("424242")))
        let c2 = await factory.client(1)
        #expect(c2.creds?.dynamicChallengeCookie?.bytesForTest == Array("CRV1:R,E:c3RhdGU=:YWxpY2U=:Enter code".utf8))
        #expect(c2.creds?.response?.bytesForTest == Array("424242".utf8))
        #expect(c2.creds?.username?.bytesForTest == Array("alice".utf8) && c2.creds?.password?.bytesForTest == Array("pw".utf8))
        c2.push(.event("CONNECTED", "", false))
        #expect(await waitUntil { log.count { if case .reconnected = $0 { return true }; return false } == 1 })
        await a.stop()
    }

    /// T3: AUTH_FAILED after Connected on the STORED password says so (the controller clears it, arms the guard).
    @Test func authFailedAfterConnectedFlagsStoredCredentials() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        let c = await factory.client(0)
        c.push(.event("CONNECTED", "", false))
        _ = await t.value
        c.push(.event("AUTH_FAILED", "", true))
        #expect(await waitUntil {
            log.count { if case .authRequired(let ch, _) = $0 { return ch.reason == .rejected && ch.rejectedStoredCredentials }; return false } == 1
        })
        await a.stop()
    }

    @Test func connectReturningBeforeConnectedIsEngineFatal() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        await factory.client(0).push(.end)
        guard case .failure(.failed(let e)) = await t.value else { Issue.record("not failed"); return }
        #expect(e.code == .engineFatal)
    }

    @Test func sleepPausesWakeResumesThenReconnectsAfter5s() async {
        let a = adapter(), log = EventLog()
        let t = run(a, req(), log)
        let c = await factory.client(0)
        c.push(.event("CONNECTED", "", false))
        _ = await t.value
        await a.sleep()
        #expect(c.s.withLock { $0.paused } == 1)
        await a.wake()
        #expect(c.s.withLock { $0.resumed } == 1)
        await clock.waitForSleepers(1); clock.advance(by: .seconds(5))
        #expect(await waitUntil { c.s.withLock { $0.reconnects } == 1 })
        await a.stop()
    }

    @Test func logRedaction() {
        #expect(OVPNLogRedactor.redact("Sending CRV1::abc::123") == nil)
        #expect(OVPNLogRedactor.redact("PUSH_REPLY,route 10.0.0.0,auth-token SECRET,ping 10") == "ovpn push: route,auth-token,ping")
        #expect(OVPNLogRedactor.redact("Connected") == "ovpn: Connected")
    }
}

/// Draft 9 (S2 E10): the canonical profile's hostname remotes become IP literals before openvpn3 sees them.
@Suite struct OVPNRemoteRewriterTests {
    func rewrite(_ text: String, _ map: [String: [String]], drop: Bool) -> (String, Int, [String]) {
        let r = OVPNRemoteRewriter.rewrite(.text(text), endpoints: map, dropUnresolved: drop)
        return (String(decoding: r.content.bytesForTest, as: UTF8.self), r.remotes, r.unresolved)
    }

    @Test func expandsEachHostnameKeepsLiteralsAndOtherLines() {
        let (t, n, u) = rewrite("client\nremote \"a.example\" \"1194\"\n<ca>\nremote \"not a directive\"\n</ca>\nremote \"10.0.0.1\"\n",
                                ["a.example": ["192.0.2.1", "192.0.2.2"]], drop: true)
        // inline bodies (keys, certificates) are copied verbatim and never parsed
        #expect(t == "client\nremote \"192.0.2.1\" \"1194\"\nremote \"192.0.2.2\" \"1194\"\n<ca>\nremote \"not a directive\"\n</ca>\nremote \"10.0.0.1\"\n")
        #expect(n == 3 && u.isEmpty)
    }

    /// PF 51: the proxy line (one host) takes the map's first IP; a literal stays; an unknown hostname stays and is
    /// reported (the adapter decides: fatal under the flag, openvpn3 resolves it without).
    @Test func httpProxyHostnameBecomesItsFirstIP() {
        let text = "client\nremote \"192.0.2.9\" \"443\" \"tcp\"\nhttp-proxy \"Proxy.example\" \"8080\"\n"
        let r = OVPNRemoteRewriter.rewrite(.text(text), endpoints: ["proxy.example": ["198.51.100.8", "198.51.100.9"]], dropUnresolved: true)
        #expect(String(decoding: r.content.bytesForTest, as: UTF8.self) ==
                "client\nremote \"192.0.2.9\" \"443\" \"tcp\"\nhttp-proxy \"198.51.100.8\" \"8080\"\n")
        #expect(r.proxyUnresolved == nil && r.remotes == 1)
        let lit = OVPNRemoteRewriter.rewrite(.text("http-proxy \"2001:db8::8\" \"8080\"\nremote \"192.0.2.9\"\n"), endpoints: [:], dropUnresolved: true)
        #expect(String(decoding: lit.content.bytesForTest, as: UTF8.self) == "http-proxy \"2001:db8::8\" \"8080\"\nremote \"192.0.2.9\"\n")
        #expect(lit.proxyUnresolved == nil)
        let gone = OVPNRemoteRewriter.rewrite(.text(text), endpoints: [:], dropUnresolved: false)
        #expect(String(decoding: gone.content.bytesForTest, as: UTF8.self) == text && gone.proxyUnresolved == "Proxy.example")
        // `http-proxy-option` is a different directive, never rewritten
        let opt = OVPNRemoteRewriter.rewrite(.text("http-proxy-option \"VERSION\" \"1.1\"\n"), endpoints: ["version": ["192.0.2.1"]], dropUnresolved: true)
        #expect(String(decoding: opt.content.bytesForTest, as: UTF8.self) == "http-proxy-option \"VERSION\" \"1.1\"\n")
    }

    @Test func unresolvedHostIsDroppedUnderTheFlagAndKeptWithout() {
        let text = "client\nremote \"gone.example\" \"1194\"\nremote \"ok.example\"\n"
        let (t1, n1, u1) = rewrite(text, ["ok.example": ["192.0.2.5"]], drop: true)
        #expect(t1 == "client\nremote \"192.0.2.5\"\n" && n1 == 1 && u1 == ["gone.example"])
        let (t2, n2, _) = rewrite(text, ["ok.example": ["192.0.2.5"]], drop: false)
        #expect(t2 == "client\nremote \"gone.example\" \"1194\"\nremote \"192.0.2.5\"\n" && n2 == 2)
        let (_, n3, _) = rewrite("client\nremote \"gone.example\"\n", [:], drop: true)
        #expect(n3 == 0)
    }

    @Test func connectionBlocksAreRepeatedPerIP() {
        let text = "client\n<connection>\nremote \"c.example\" \"443\" \"tcp\"\n</connection>\n"
        let (t, n, _) = rewrite(text, ["c.example": ["192.0.2.7", "192.0.2.8"]], drop: true)
        #expect(t == "client\n<connection>\nremote \"192.0.2.7\" \"443\" \"tcp\"\n</connection>\n<connection>\nremote \"192.0.2.8\" \"443\" \"tcp\"\n</connection>\n")
        #expect(n == 2)
        let (dropped, n0, _) = rewrite(text, [:], drop: true)
        #expect(dropped == "client\n" && n0 == 0)
    }

    @Test func hostLookupIsCaseInsensitiveAndEscapesAreDecoded() {
        let (t, _, _) = rewrite("remote \"Mixed.Example\"\n", ["mixed.example": ["192.0.2.3"]], drop: true)
        #expect(t == "remote \"192.0.2.3\"\n")
        #expect(OVPNRemoteRewriter.firstArgument(ArraySlice("remote \"a\\\"b\" \"1\"".utf8), of: "remote")?.0 == "a\"b")
        #expect(OVPNRemoteRewriter.firstArgument(ArraySlice("remote-random".utf8), of: "remote") == nil)
    }

    /// Review nit: a bracketed IPv6 literal is a literal, kept even under the flag (never dropped as "unresolved").
    @Test func bracketedIPv6RemoteIsALiteral() {
        let (t, n, u) = rewrite("remote \"[2001:db8::1]\" \"1194\"\n", [:], drop: true)
        #expect(t == "remote \"[2001:db8::1]\" \"1194\"\n" && n == 1 && u.isEmpty)
    }

    /// Review L3: expansions far beyond the initial reservation (8 IPs × a block with a 4 KiB inline key) take the
    /// hand-grown, zero-the-old-buffer path and still produce the exact output.
    @Test func largeExpansionGrowsTheBufferCorrectly() {
        let key = String(repeating: "k", count: 4096)
        let block = "<connection>\nremote \"big.example\" \"443\"\n<key>\n\(key)\n</key>\n</connection>\n"
        let ips = (1...8).map { "192.0.2.\($0)" }
        let (t, n, _) = rewrite("client\n" + block, ["big.example": ips], drop: true)
        let expected = "client\n" + ips.map { "<connection>\nremote \"\($0)\" \"443\"\n<key>\n\(key)\n</key>\n</connection>\n" }.joined()
        #expect(t == expected && n == 8)
    }
}
