import Foundation
import LPModel
import Synchronization

/// DESIGN §9 / §7.3 / §9.3: the WireGuard engine over `WireGuardBackend` (libwg-go via the Tunnel target).
/// - Settings are applied first (via the controller), then the chosen fd goes to `wgTurnOn` (utun) or a socketpair end
///   to `wgTurnOnPF` (packetFlow, W10).
/// - Data plane up = the first handshake newer than the start (forced with W4, retried every 5.5 s, next endpoint IP
///   after 2 failures, each switch re-applying settings with the new `tunnelRemoteAddress` first).
/// - `wgIsClosed` polled at 1 Hz (W6) → `.fatal(.engineDied)`.
/// - Endpoints (draft 9): from `AdapterStart.endpoints`; a lookup only when `providerDNS` (kill switch off), ≤ 2 s.
// SAFETY: mutable state is in `m`; Go is entered only on `workQueue` (§9.2).
public final class WireGuardAdapter<C: Clock>: TunnelAdapter, @unchecked Sendable where C.Duration == Duration {
    public let kind: VPNProtocolKind = .wireGuard

    static var handshakePoll: Duration { .milliseconds(250) }
    static var handshakeRetry: Duration { .milliseconds(5500) }
    static var reconnectWindow: Duration { .seconds(15) }
    static var rejectAfter: TimeInterval { 180 }
    /// Draft 9 (S2 E10): a provider-side lookup (kill switch off only) never takes longer than this.
    static var resolveDeadline: Duration { .seconds(2) }

    private let backend: any WireGuardBackend
    private let parser: any WGConfigParser
    private let resolver: any EndpointResolver
    private let clock: C
    private let wallClock: @Sendable () -> Date
    private let workQueue = DispatchQueue(label: "lockplus.wg.work")

    private struct S {
        var handle: Int32 = -1
        var stopping = false
        var ticket: EstablishTicket?
        var config: WGSessionConfig?
        var ips: [String] = []          // peer 0's endpoint IPs (v4 first), cached for the session
        var ipIndex = 0
        var events: AdapterEventSink?
        var epoch: UInt64 = 0
        var pump: PacketFlowPump?
        var pumpEnd: Int32 = -1          // the pump fd THIS adapter attached (stop retires only that one)
        var lastTx: UInt64?
        var staleProbeAt: Date?
        var tasks: [Task<Void, Never>] = []
        var lastPlan: NetworkPlan?
        /// hostname → IPs this adapter resolved itself (kill switch off only); reported for the §9.3 cache.
        var resolved: [String: [String]] = [:]
    }
    private let m = Mutex(S())

    public init(backend: any WireGuardBackend, parser: any WGConfigParser, resolver: any EndpointResolver = GetAddrInfoResolver(),
                clock: C, wallClock: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend; self.parser = parser; self.resolver = resolver; self.clock = clock; self.wallClock = wallClock
    }

    private func onWork<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (k: CheckedContinuation<T, Never>) in workQueue.async { @Sendable in k.resume(returning: body()) } }
    }

    private var stopping: Bool { m.withLock { $0.stopping } || Task.isCancelled }

    // MARK: start

    public func start(_ req: AdapterStart, events: AdapterEventSink, epoch: UInt64) async throws(AdapterStartError) {
        let cfg: WGSessionConfig
        do throws(LPTunnelError) { cfg = try parser.parse(req.payload) } catch { throw .failed(.of(.profileInvalid, error.detail)) }
        guard let p0 = cfg.peers.first else { throw .failed(.of(.profileInvalid, "no peer")) }

        // §9.3 (draft 9, S2 E10): the IPs come with the start (the app resolved them; the cache fills gaps). Under
        // includeAllNetworks (`providerDNS == false`) nothing is resolved here: provider getaddrinfo blocks for 30 s and
        // fails. Without the flag a hostname missing from the map is resolved with a 2 s deadline.
        var endpoints: [Int: String] = [:]
        var ips: [String] = []
        var resolved: [String: [String]] = [:]
        for (i, p) in cfg.peers.enumerated() {
            guard let host = p.endpointHost, let port = p.endpointPort else { continue }
            var r: [String]
            if IPAddress.isV4(host) || IPAddress.isV6(host) {
                r = [host]
            } else if let known = req.endpoints[host.lowercased()], !known.isEmpty {
                r = known
            } else if req.providerDNS {
                let resolver = resolver, clock = clock
                r = await withDeadline(Self.resolveDeadline, onTimeout: [], sleep: { try await clock.sleep(for: $0) }) {
                    await resolver.resolve(host: host)
                }
                if !r.isEmpty { resolved[host.lowercased()] = r }
            } else {
                r = []
            }
            guard let first = r.first else {
                if i == 0 { throw .failed(.of(.dnsResolutionFailed, req.providerDNS ? nil : "no endpoint IPs")) } else { continue }
            }
            if i == 0 { ips = r }
            endpoints[i] = IPAddress.joinHostPort(first, port)
        }
        guard !ips.isEmpty || p0.endpointHost == nil else { throw .failed(.of(.dnsResolutionFailed)) }
        m.withLock { s in
            s.config = cfg; s.ips = ips; s.ipIndex = 0; s.events = events; s.epoch = epoch; s.pump = req.pump; s.resolved = resolved
        }
        if stopping { throw .failed(.of(.startCancelled)) }

        let remote = ips.first ?? "0.0.0.0"
        let plan = Self.plan(cfg, remote: remote)
        let answer = await requestSettings(plan)
        if stopping { throw .failed(.of(.startCancelled)) }
        let uapi = WGUAPI.build(cfg, endpoints: endpoints)
        let startWall = wallClock()       // T12: before turnOn, so a handshake completing during turnOn counts
        let h: Int32
        switch answer {
        case .fd(let fd):
            h = await onWork { [backend] in backend.turnOn(uapi: uapi, tunFD: fd) }
        case .applied:
            let pair: (engineEnd: Int32, pumpEnd: Int32)
            do throws(LPTunnelError) { pair = try SocketPair.make() } catch { throw .failed(error) }
            guard let pump = req.pump else { close(pair.engineEnd); close(pair.pumpEnd); throw .failed(.of(.tunDeviceFailed, "no pump")) }
            m.withLock { $0.pumpEnd = pair.pumpEnd }
            pump.attach(pair.pumpEnd)
            let mtu = Int32(req.policy.mtuOverride ?? cfg.mtu ?? NetworkSettingsBuilder.defaultMTU)
            h = await onWork { [backend] in backend.turnOnPacketFlow(uapi: uapi, socketFD: pair.engineEnd, mtu: mtu) }   // Go owns engineEnd
        case .failed(let code):
            throw .failed(.of(code))
        }
        guard h >= 0 else { throw .failed(.of(.tunDeviceFailed, "wgTurnOn")) }
        let stoppedMeanwhile = m.withLock { s -> Bool in s.handle = h; return s.stopping }
        if stoppedMeanwhile { await onWork { [backend] in backend.turnOff(h) }; m.withLock { $0.handle = -1 }; throw .failed(.of(.startCancelled)) }
        startClosedPoll(h)
        try await waitForFirstHandshake(h, since: startWall)
    }

    /// Posts `.networkSettings` and waits for the controller's answer.
    private func requestSettings(_ plan: NetworkPlan) async -> EstablishAnswer {
        let t = EstablishTicket()
        let (ev, ep, stop) = m.withLock { s -> (AdapterEventSink?, UInt64, Bool) in
            if !s.stopping { s.ticket = t; s.lastPlan = plan }
            return (s.events, s.epoch, s.stopping)
        }
        if stop { return .failed(.startCancelled) }
        ev?.yield(.networkSettings(plan, t, epoch: ep))
        let a = await t.value()
        m.withLock { s in if s.ticket === t { s.ticket = nil } }
        return a
    }

    private func waitForFirstHandshake(_ h: Int32, since startWall: Date) async throws(AdapterStartError) {
        var failures = 0
        _ = await onWork { [backend] in backend.sendHandshake(h) }
        var lastSend = clock.now
        while true {
            if stopping { throw .failed(.of(.startCancelled)) }
            do { try await clock.sleep(for: Self.handshakePoll) } catch { throw .failed(.of(.startCancelled)) }
            if stopping { throw .failed(.of(.startCancelled)) }
            let text = await onWork { [backend] in backend.stats(h) }
            let peers = WGPeerStats.parse(text ?? "")
            if peers.contains(where: { ($0.lastHandshake ?? .distantPast) >= startWall }) {
                m.withLock { $0.lastTx = peers.reduce(0) { $0 + $1.txBytes } }
                return
            }
            if lastSend.duration(to: clock.now) >= Self.handshakeRetry {
                failures += 1
                if failures % 2 == 0 { await rotateEndpoint(h) }
                _ = await onWork { [backend] in backend.sendHandshake(h) }
                lastSend = clock.now
            }
        }
    }

    /// Next cached endpoint IP for peer 0: re-apply settings with the new `tunnelRemoteAddress` FIRST (§8.5, C14),
    /// then `wgSetEndpoint` (update_only, W4).
    private func rotateEndpoint(_ h: Int32) async {
        let next: (cfg: WGSessionConfig, ip: String)? = m.withLock { s in
            guard let c = s.config, s.ips.count > 1 else { return nil }
            s.ipIndex = (s.ipIndex + 1) % s.ips.count
            return (c, s.ips[s.ipIndex])
        }
        guard let next, let p0 = next.cfg.peers.first, let port = p0.endpointPort else { return }
        let answer = await requestSettings(Self.plan(next.cfg, remote: next.ip))
        if case .failed = answer { return }
        let pub = WGUAPI.hex(p0.publicKey), ep = IPAddress.joinHostPort(next.ip, port)
        _ = await onWork { [backend] in backend.setEndpoint(h, publicKeyHex: pub, endpoint: ep) }
    }

    private func startClosedPoll(_ h: Int32) {
        let clock = clock, backend = backend
        let t = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.stopping else { return }
                let closed = await self.onWork { backend.isClosed(h) }
                if closed {
                    let (ev, ep) = self.m.withLock { ($0.events, $0.epoch) }
                    ev?.yield(.fatal(.of(.engineDied), epoch: ep))
                    return
                }
            }
        }
        m.withLock { $0.tasks.append(t) }
    }

    static func plan(_ c: WGSessionConfig, remote: String) -> NetworkPlan {
        var p = NetworkPlan(remoteAddress: remote)
        for a in c.addresses {
            let parts = a.split(separator: "/"); guard let addr = parts.first.map(String.init) else { continue }
            if IPAddress.isV4(addr) { p.ipv4.append(.init(addr, parts.count > 1 ? Int(parts[1]) ?? 32 : 32)) }
            else if IPAddress.isV6(addr) { p.ipv6.append(.init(addr, parts.count > 1 ? Int(parts[1]) ?? 128 : 128)) }
        }
        var seen4 = Set<Route4>(), seen6 = Set<Route6>()
        for peer in c.peers {
            for cidr in peer.allowedIPs {
                let parts = cidr.split(separator: "/"); guard let addr = parts.first.map(String.init) else { continue }
                if IPAddress.isV4(addr) {
                    let len = parts.count > 1 ? Int(parts[1]) ?? 32 : 32
                    if len == 0 { p.redirectGateway.v4 = true } else if seen4.insert(.init(addr, len)).inserted { p.includedRoutes4.append(.init(addr, len)) }
                } else if IPAddress.isV6(addr) {
                    let len = parts.count > 1 ? Int(parts[1]) ?? 128 : 128
                    if len == 0 { p.redirectGateway.v6 = true } else if seen6.insert(.init(addr, len)).inserted { p.includedRoutes6.append(.init(addr, len)) }
                }
            }
        }
        if !c.dnsServers.isEmpty { p.dns = DNSPlan(servers: c.dnsServers, searchDomains: c.searchDomains) }
        p.mtu = c.mtu
        return p
    }

    // MARK: lifecycle

    public func stop() async {
        let (h, ticket, pump, pumpEnd, tasks) = m.withLock { s -> (Int32, EstablishTicket?, PacketFlowPump?, Int32, [Task<Void, Never>]) in
            s.stopping = true
            defer { s.handle = -1; s.ticket = nil; s.tasks = []; s.events = nil; s.pumpEnd = -1 }
            return (s.handle, s.ticket, s.pump, s.pumpEnd, s.tasks)
        }
        ticket?.answer(.failed(.startCancelled))
        for t in tasks { t.cancel() }
        if h >= 0 { await onWork { [backend] in backend.turnOff(h) } }
        if pumpEnd >= 0 { pump?.detach(pumpEnd) }
    }

    /// Path change / dead peer / wake: `wgBumpSockets` + a forced handshake (mandatory after wake: a bump sends
    /// nothing for a keypair older than 180 s). Dead peer rotates to the next cached IP (never re-resolves, §7.5).
    /// Emits `.reconnected` when a handshake newer than this call lands within 15 s.
    public func reconnect(reason: ReconnectReason) async {
        let h = m.withLock { $0.handle }
        guard h >= 0, !stopping else { return }
        if reason == .deadPeer { await rotateEndpoint(h) }
        let since = wallClock()
        await onWork { [backend] in backend.bumpSockets(h); _ = backend.sendHandshake(h) }
        let clock = clock, backend = backend
        let t = Task { [weak self] in
            var waited: Duration = .zero
            var sinceSend: Duration = .zero
            while waited < Self.reconnectWindow {
                do { try await clock.sleep(for: Self.handshakePoll) } catch { return }
                waited += Self.handshakePoll; sinceSend += Self.handshakePoll
                guard let self, !self.stopping else { return }
                let peers = WGPeerStats.parse(await self.onWork { backend.stats(h) } ?? "")
                if peers.contains(where: { ($0.lastHandshake ?? .distantPast) >= since }) {
                    let (ev, ep) = self.m.withLock { s in s.staleProbeAt = nil; return (s.events, s.epoch) }
                    ev?.yield(.reconnected(epoch: ep))
                    return
                }
                if sinceSend >= Self.handshakeRetry { _ = await self.onWork { backend.sendHandshake(h) }; sinceSend = .zero }
            }
        }
        m.withLock { $0.tasks.append(t) }
    }

    public func sleep() async {}       // WG keeps running; the controller stops the watchdog (§7.4)

    public func wake() async { await reconnect(reason: .wake) }

    public func provideAuth(_ answer: AuthAnswerSecrets) async throws(LPTunnelError) {
        throw .of(.engineFatal, "wireguard has no interactive auth")
    }

    public func statistics() async -> AdapterStats {
        let (h, cfg, ips, idx, resolved) = m.withLock { ($0.handle, $0.config, $0.ips, $0.ipIndex, $0.resolved) }
        var st = AdapterStats(localAddresses: cfg?.addresses ?? [], resolvedEndpoints: resolved)
        if !ips.isEmpty { st.endpoint = ips[idx % ips.count] }
        guard h >= 0 else { return st }
        let peers = WGPeerStats.parse(await onWork { [backend] in backend.stats(h) } ?? "")
        st.rxBytes = peers.reduce(0) { $0 + $1.rxBytes }
        st.txBytes = peers.reduce(0) { $0 + $1.txBytes }
        st.lastHandshake = peers.compactMap(\.lastHandshake).max()
        return st
    }

    /// §7.5: age > 180 s (RejectAfterTime) AND tx grew since the last tick → force a handshake and give it 3 × 5.5 s;
    /// still old → `.stale`. A closed device → `.dead`.
    public func liveness() async -> Liveness {
        let h = m.withLock { $0.handle }
        guard h >= 0 else { return .dead }
        let (closed, text) = await onWork { [backend] in (backend.isClosed(h), backend.stats(h)) }
        if closed { return .dead }
        let peers = WGPeerStats.parse(text ?? "")
        let tx = peers.reduce(0) { $0 + $1.txBytes }
        let now = wallClock()
        let age = now.timeIntervalSince(peers.compactMap(\.lastHandshake).max() ?? .distantPast)
        let (grew, probe) = m.withLock { s -> (Bool, Date?) in
            defer { s.lastTx = tx }
            return (s.lastTx.map { tx > $0 } ?? false, s.staleProbeAt)
        }
        guard age > Self.rejectAfter else { m.withLock { $0.staleProbeAt = nil }; return .healthy }
        if let probe {
            if now.timeIntervalSince(probe) >= 3 * 5.5 { return .stale(.seconds(age)) }
            return .healthy
        }
        guard grew else { return .healthy }
        m.withLock { $0.staleProbeAt = now }
        _ = await onWork { [backend] in backend.sendHandshake(h) }
        return .healthy
    }
}
