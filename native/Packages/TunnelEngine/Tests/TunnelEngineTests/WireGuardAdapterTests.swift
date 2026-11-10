import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

final class FakeWGBackend: WireGuardBackend, @unchecked Sendable {
    struct S {
        var turnOn: [(uapi: String, fd: Int32)] = []
        var turnOnPF: [(fd: Int32, mtu: Int32)] = []
        var turnOff: [Int32] = []
        var setEndpoint: [String] = []
        var handshakes = 0
        var bumps = 0
        var lastHandshake: Date?
        var closed = false
        var tx: UInt64 = 0
        var fail = false
    }
    let s = Mutex(S())
    func turnOn(uapi: SecretBytes, tunFD: Int32) -> Int32 {
        s.withLock { st in st.turnOn.append((String(decoding: uapi.bytesForTest, as: UTF8.self), tunFD)); return st.fail ? -1 : 3 }
    }
    func turnOnPacketFlow(uapi: SecretBytes, socketFD: Int32, mtu: Int32) -> Int32 {
        s.withLock { st in st.turnOnPF.append((socketFD, mtu)); return 4 }      // Go owns socketFD; closed at turnOff
    }
    func turnOff(_ handle: Int32) {
        s.withLock { st in st.turnOff.append(handle); if handle == 4 { for p in st.turnOnPF { close(p.fd) } } }
    }
    func setEndpoint(_ handle: Int32, publicKeyHex: String, endpoint: String) -> Int32 { s.withLock { $0.setEndpoint.append(endpoint) }; return 0 }
    func sendHandshake(_ handle: Int32) -> (result: Int32, sentNs: Int64) { s.withLock { $0.handshakes += 1 }; return (1, 0) }
    func stats(_ handle: Int32) -> String? {
        s.withLock { st in
            let t = st.lastHandshake?.timeIntervalSince1970 ?? 0
            return "public_key=\(String(repeating: "ab", count: 32))\nendpoint=192.0.2.1:51820\nlast_handshake_time_sec=\(Int64(t))\nlast_handshake_time_nsec=\(Int64((t - floor(t)) * 1e9))\nrx_bytes=100\ntx_bytes=\(st.tx)\n"
        }
    }
    func isClosed(_ handle: Int32) -> Bool { s.withLock { $0.closed } }
    func bumpSockets(_ handle: Int32) { s.withLock { $0.bumps += 1 } }
}

struct FakeWGParser: WGConfigParser {
    var host = "vpn.example"
    func parse(_ payload: SecretBytes) throws(LPTunnelError) -> WGSessionConfig {
        WGSessionConfig(privateKey: SecretBytes(copying: [UInt8](repeating: 0x11, count: 32)), addresses: ["10.7.0.2/32"],
                        dnsServers: ["10.7.0.1"], peers: [.init(publicKey: Data(repeating: 0xAB, count: 32), endpointHost: host,
                                                                endpointPort: 51820, allowedIPs: ["0.0.0.0/0", "10.99.0.0/16"])])
    }
}

final class FakeResolver: EndpointResolver, @unchecked Sendable {
    let answers: [String]
    let hang: Bool
    let calls = Mutex(0)
    init(answers: [String], hang: Bool = false) { self.answers = answers; self.hang = hang }
    func resolve(host: String) async -> [String] {
        calls.withLock { $0 += 1 }
        if hang { try? await Task.sleep(for: .seconds(3600)) }     // a blocked resolver (S2 E10: 30 s under the flag)
        return answers
    }
    var callCount: Int { calls.withLock { $0 } }
}

/// Collects adapter events.
final class EventLog: @unchecked Sendable {
    final class Box: Sendable { let m = Mutex<[AdapterEvent]>([]) }
    let box = Box()
    let sink: AdapterEventSink
    init() {
        let (s, c) = AsyncStream.makeStream(of: AdapterEvent.self, bufferingPolicy: .unbounded)
        sink = c
        let b = box
        Task { for await e in s { b.m.withLock { $0.append(e) } } }
    }
    var settings: [(NetworkPlan, EstablishTicket)] {
        box.m.withLock { $0.compactMap { if case .networkSettings(let p, let t, _) = $0 { return (p, t) }; return nil } }
    }
    func count(_ match: (AdapterEvent) -> Bool) -> Int { box.m.withLock { $0.filter(match).count } }
}

@Suite struct WireGuardAdapterTests {
    let clock = ManualClock()
    let wall = MutableWallClock()
    let backend = FakeWGBackend()

    func adapter(resolver: FakeResolver = FakeResolver(answers: ["192.0.2.1", "192.0.2.2"])) -> WireGuardAdapter<ManualClock> {
        WireGuardAdapter(backend: backend, parser: FakeWGParser(), resolver: resolver, clock: clock, wallClock: wall.function)
    }

    /// Default: a kill-switch start whose endpoint the app resolved (`providerDNS == false`, draft 9).
    func request(plane: DataPlane = .utunFD, pump: PacketFlowPump? = nil,
                 endpoints: [String: [String]] = ["vpn.example": ["192.0.2.1", "192.0.2.2"]], providerDNS: Bool = false) -> AdapterStart {
        AdapterStart(profileID: UUID(), payload: .text("[Interface]"), credentials: nil, stash: nil, policy: .init(killSwitch: !providerDNS),
                     connectTimeout: .seconds(45), endpoints: endpoints, providerDNS: providerDNS, dataPlane: plane, pump: pump)
    }

    @Test func settingsFirstThenTurnOnThenFirstHandshake() async throws {
        let a = adapter(), log = EventLog()
        let t = Task { () -> AdapterStartError? in do throws(AdapterStartError) { try await a.start(request(), events: log.sink, epoch: 3); return nil } catch { return error } }
        #expect(await waitUntil { log.settings.count == 1 })
        let (plan, ticket) = log.settings[0]
        #expect(plan.remoteAddress == "192.0.2.1" && plan.redirectGateway.v4 && plan.includedRoutes4 == [Route4("10.99.0.0", 16)])
        #expect(plan.ipv4 == [IPv4Assignment("10.7.0.2", 32)] && plan.dns?.servers == ["10.7.0.1"])
        #expect(backend.s.withLock { $0.turnOn.isEmpty })                 // nothing before settings are applied
        ticket.answer(.fd(9))
        #expect(await waitUntil { self.backend.s.withLock { $0.turnOn.count } == 1 })
        let on = backend.s.withLock { $0.turnOn[0] }
        #expect(on.fd == 9 && on.uapi.contains("private_key=" + String(repeating: "11", count: 32)))
        #expect(on.uapi.contains("endpoint=192.0.2.1:51820") && on.uapi.contains("allowed_ip=0.0.0.0/0") && on.uapi.contains("replace_peers=true"))
        #expect(await waitUntil { self.backend.s.withLock { $0.handshakes } >= 1 })   // forced handshake (W4)
        wall.advance(1)
        backend.s.withLock { $0.lastHandshake = wall.now }
        await clock.waitForSleepers(1); clock.advance(by: .milliseconds(250))
        #expect(await t.value == nil)
        let st = await a.statistics()
        #expect(st.rxBytes == 100 && st.endpoint == "192.0.2.1" && st.lastHandshake != nil)
        #expect(st.resolvedEndpoints.isEmpty)                             // the app resolved it; nothing new to cache
        await a.stop()
        #expect(backend.s.withLock { $0.turnOff } == [3])
    }

    @Test func retriesEvery5_5sAndRotatesAfterTwoFailures() async throws {
        let a = adapter(), log = EventLog()
        Task { try? await a.start(request(), events: log.sink, epoch: 1) }
        #expect(await waitUntil { log.settings.count == 1 })
        log.settings[0].1.answer(.fd(9))
        #expect(await waitUntil { self.backend.s.withLock { $0.handshakes } == 1 })
        for _ in 0..<44 {                                                 // 11 s in 250 ms polls
            await clock.waitForSleepers(1); clock.advance(by: .milliseconds(250))
            _ = await waitUntil(timeout: .milliseconds(20)) { log.settings.count == 2 }
            if log.settings.count == 2 { break }
        }
        #expect(log.settings.count == 2)
        #expect(log.settings[1].0.remoteAddress == "192.0.2.2")          // settings re-applied with the new remote FIRST
        log.settings[1].1.answer(.fd(9))
        #expect(await waitUntil { self.backend.s.withLock { $0.setEndpoint } == ["192.0.2.2:51820"] })
        await a.stop()
    }

    // MARK: §9.3 endpoints (draft 9, S2 E10)

    /// Under includeAllNetworks the adapter never resolves: the map's IPs are used, the resolver is never called.
    @Test func killSwitchUsesTheStartsIPsAndNeverResolves() async {
        let r = FakeResolver(answers: ["198.51.100.9"])
        let a = adapter(resolver: r), log = EventLog()
        Task { try? await a.start(request(endpoints: ["vpn.example": ["203.0.113.5"]]), events: log.sink, epoch: 1) }
        #expect(await waitUntil { log.settings.count == 1 })
        #expect(log.settings[0].0.remoteAddress == "203.0.113.5")
        #expect(r.callCount == 0)
        await a.stop()
    }

    @Test func killSwitchWithoutIPsFailsAtOnceWithoutResolving() async {
        let r = FakeResolver(answers: ["198.51.100.9"])
        let a = adapter(resolver: r)
        do throws(AdapterStartError) { try await a.start(request(endpoints: [:]), events: EventLog().sink, epoch: 1); Issue.record("started") }
        catch { if case .failed(let e) = error { #expect(e.code == .dnsResolutionFailed && e.detail == "no endpoint IPs") } else { Issue.record("auth?") } }
        #expect(r.callCount == 0)
    }

    /// Kill switch off: a hostname missing from the map is resolved here and reported for the cache.
    @Test func withoutTheFlagAMissingHostIsResolvedAndCached() async {
        let a = adapter(resolver: FakeResolver(answers: ["198.51.100.9"])), log = EventLog()
        Task { try? await a.start(request(endpoints: [:], providerDNS: true), events: log.sink, epoch: 1) }
        #expect(await waitUntil { log.settings.count == 1 })
        #expect(log.settings[0].0.remoteAddress == "198.51.100.9")
        #expect(await a.statistics().resolvedEndpoints == ["vpn.example": ["198.51.100.9"]])
        await a.stop()
    }

    /// A blocked resolver costs at most the 2 s deadline (on the adapter's clock), then `.dnsResolutionFailed`.
    @Test func providerLookupHasA2sDeadline() async {
        let a = adapter(resolver: FakeResolver(answers: ["198.51.100.9"], hang: true))
        let t = Task { () -> LPErrorCode? in
            do throws(AdapterStartError) { try await a.start(request(endpoints: [:], providerDNS: true), events: EventLog().sink, epoch: 1); return nil }
            catch { if case .failed(let e) = error { return e.code }; return nil }
        }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(2))
        #expect(await t.value == .dnsResolutionFailed)
    }

    @Test func ipLiteralEndpointNeedsNoMap() async {
        let r = FakeResolver(answers: [])
        let a = WireGuardAdapter(backend: backend, parser: FakeWGParser(host: "203.0.113.7"), resolver: r, clock: clock, wallClock: wall.function)
        let log = EventLog()
        Task { try? await a.start(request(endpoints: [:]), events: log.sink, epoch: 1) }
        #expect(await waitUntil { log.settings.count == 1 })
        #expect(log.settings[0].0.remoteAddress == "203.0.113.7" && r.callCount == 0)
        await a.stop()
    }

    @Test func packetFlowUsesTheSessionPump() async throws {
        let flow = FakeFlow()
        let pump = PacketFlowPump(flow: flow)
        let a = adapter(), log = EventLog()
        Task { try? await a.start(request(plane: .packetFlow, pump: pump), events: log.sink, epoch: 1) }
        #expect(await waitUntil { log.settings.count == 1 })
        log.settings[0].1.answer(.applied)
        #expect(await waitUntil { self.backend.s.withLock { $0.turnOnPF.count } == 1 })
        #expect(backend.s.withLock { $0.turnOnPF[0].mtu } == 1420 && flow.outstanding == 1 && pump.stats.readers == 1)
        await a.stop()
        #expect(await waitUntil { pump.stats.readers == 0 })
        pump.endSession()
    }

    @Test func stopDuringSettingsAnswersTheTicket() async {
        let a = adapter(), log = EventLog()
        let t = Task { () -> Bool in do throws(AdapterStartError) { try await a.start(request(), events: log.sink, epoch: 1); return true } catch { return false } }
        #expect(await waitUntil { log.settings.count == 1 })
        await a.stop()
        #expect(log.settings[0].1.answered == .failed(.startCancelled))
        #expect(await t.value == false)
        #expect(backend.s.withLock { $0.turnOn.isEmpty })
    }

    @Test func closedDeviceIsEngineDied() async {
        let a = adapter(), log = EventLog()
        Task { try? await a.start(request(), events: log.sink, epoch: 5) }
        #expect(await waitUntil { log.settings.count == 1 })
        log.settings[0].1.answer(.fd(9))
        #expect(await waitUntil { self.backend.s.withLock { $0.turnOn.count } == 1 })
        backend.s.withLock { $0.closed = true }
        for _ in 0..<8 { clock.advance(by: .seconds(1)); try? await Task.sleep(for: .milliseconds(2)) }
        #expect(await waitUntil { log.count { if case .fatal(let e, 5) = $0 { return e.code == .engineDied }; return false } == 1 })
        #expect(await a.liveness() == .dead)
        await a.stop()
    }

    @Test func livenessStaleOnlyAfterAgeTxGrowthAndAForcedHandshake() async {
        let a = adapter(), log = EventLog()
        let t = Task { try? await a.start(request(), events: log.sink, epoch: 1) }
        #expect(await waitUntil { log.settings.count == 1 })
        log.settings[0].1.answer(.fd(9))
        #expect(await waitUntil { self.backend.s.withLock { $0.handshakes } == 1 })
        backend.s.withLock { $0.lastHandshake = wall.now.addingTimeInterval(1) }
        wall.advance(1)
        await clock.waitForSleepers(1); clock.advance(by: .milliseconds(250))
        _ = await t.value
        #expect(await a.liveness() == .healthy)
        wall.advance(200)                                                 // age > 180 s
        #expect(await a.liveness() == .healthy)                           // tx did not grow
        backend.s.withLock { $0.tx += 500 }
        let before = backend.s.withLock { $0.handshakes }
        #expect(await a.liveness() == .healthy)                           // forces a handshake, gives it 3 × 5.5 s
        #expect(backend.s.withLock { $0.handshakes } == before + 1)
        wall.advance(17)
        if case .stale = await a.liveness() {} else { Issue.record("not stale") }
        await a.stop()
    }

    @Test func statsParserIgnoresUnknownKeys() {
        let p = WGPeerStats.parse("public_key=aa\nprivate_key=zz\nrx_bytes=5\ntx_bytes=6\nlast_handshake_time_sec=-3\npublic_key=bb\nrx_bytes=1\n")
        #expect(p.count == 2 && p[0].rxBytes == 5 && p[0].txBytes == 6 && p[0].lastHandshake == nil && p[1].rxBytes == 1)
    }

    @Test func uapiCarriesPresharedKeyAndKeepalive() {
        var c = try! FakeWGParser().parse(.text(""))
        c.peers[0].presharedKey = SecretBytes(copying: [UInt8](repeating: 0x22, count: 32))
        c.peers[0].persistentKeepalive = 25
        c.listenPort = 51000
        let u = String(decoding: WGUAPI.build(c, endpoints: [0: "192.0.2.1:51820"]).bytesForTest, as: UTF8.self)
        #expect(u.hasPrefix("private_key="))
        #expect(u.contains("listen_port=51000\n") && u.contains("preshared_key=" + String(repeating: "22", count: 32)))
        #expect(u.contains("persistent_keepalive_interval=25\n") && u.contains("public_key=" + String(repeating: "ab", count: 32)))
    }
}
