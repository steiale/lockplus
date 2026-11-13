import Foundation
import LPModel
import LPRouteProbe
import LPWire
import Network
import Synchronization

// MARK: - The connection self-test (2.0.2 item 5, D-5)
//
// Proves the PATH: that IPv4, IPv6 and DNS from this Mac use the tunnel interface / tunnel source address, and names the
// VPN server. It does NOT check the address websites see (no echo service, D-5): a result never claims it.
//
// Privacy: runs only when the user presses the button; contacts only the one existing probe host (F8,
// `OnDemandPlan.ownProbeURL`, a static file) and, implicitly, the VPN server through the tunnel. Never a third-party
// "what is my IP" service. Runs in the app (user context): app sockets go through the tunnel; the provider's would not.

enum IPFamily: Sendable, Equatable { case v4, v6 }

/// What one family's probe proved. Never "green" unless the request provably left through the tunnel.
enum PathVerdict: Sendable, Equatable {
    /// The request left by the tunnel interface (and its source address is the tunnel's).
    case throughTunnel(interface: String, source: String)
    /// Full tunnel, but the request left by another interface.
    case outsideTunnel(interface: String)
    /// Split tunnel: the probe host is not part of the tunnel's routes (v6: the test is skipped, "not part of this tunnel").
    case outsideExpected
    /// IPv6 under a full tunnel that blackholes it: the attempt failed at once, nothing left the Mac.
    case blocked
    /// No IPv6 default route on a physical interface and none in the tunnel.
    case noIPv6Here
    /// No answer, or an answer that isn't ours (a captive portal's 200). Inconclusive, never green.
    case unreachable(String)
}

enum SelfTestOverall: Sendable, Equatable {
    case ok, warning, problem
    /// Something couldn't be verified. Drawn as "?", never as safe.
    case inconclusive
}

/// What the test needs to know about the profile and the session, as plain values.
struct SelfTestFacts: Sendable, Equatable {
    var profileID: UUID
    var isFullTunnel: Bool
    var tunnelsIPv6: Bool
    var killSwitch: Bool
    var blockIPv6: Bool
    var dnsCatchAll: Bool
    /// Round 2 (Codex r2 #7): the profile's own DNS servers (no port). For a split-DNS profile these are what the DNS row
    /// route-checks; nil/empty when pushed by the server and unknown to the app.
    var expectedDNS: [String] = []
    /// False for a profile that sets no DNS at all (2.0.1 F4): the DNS row then says so and is neutral.
    var dnsApplicable: Bool = true
    /// The session's utun (found by its addresses when the snapshot has none). Only ever a utun.
    var tunnelInterface: String?
    var tunnelAddresses: [String]
    /// "host" of the VPN server (no port); nil when unknown.
    var endpointHost: String?
    /// Round 1 (Fable M3): a tunnel address is also carried by another interface (a LAN that hands out the tunnel's
    /// inner address, or two utuns). Which interface a connection used can then not be told from its addresses: no
    /// "through the tunnel" and no "outside" verdict, only inconclusive.
    var tunnelAddressCollision = false

    /// `includeAllNetworks` (full tunnel + kill switch): NECP scopes everything, so a route-table answer of en0 is no proof.
    var includeAllNetworks: Bool { isFullTunnel && killSwitch }
}

struct SelfTestReport: Sendable, Equatable {
    var profileID: UUID
    var at: Date
    var endpoint: String?
    var ipv4: PathVerdict
    var ipv6: PathVerdict
    var dns: DNSCheckResult
    var dnsApplicable: Bool
    /// nameserver -> interface the kernel routes it by (the default resolver's servers; catch-all profiles only).
    var dnsServerRoutes: [String: String]
    var dnsServers: [String]
    var tunnelInterface: String?
    var overall: SelfTestOverall
    /// Round 2 (Codex r2 #7): split DNS: only the profile's own servers were checked (other names use the network's DNS).
    var dnsSplit = false
}

/// Why a probe fetch failed, as far as it tells where packets went (round 1, Fable M2 / Sonnet M3).
enum ProbeFailure: Sendable, Equatable {
    /// The name didn't resolve: proves nothing about the path.
    case dns
    /// The path stayed unsatisfied: no usable interface for the family on this Mac (a local refusal).
    case noPath
    /// ENETUNREACH / EHOSTUNREACH / ENETDOWN / EADDRNOTAVAIL: local only if the route lookup agrees (EHOSTUNREACH can
    /// also be an ICMP answer from the LAN's router).
    case unreachable
    /// ECONNREFUSED / ECONNRESET / a TLS failure: something answered, so packets left the Mac.
    case answered
    case other
}

/// One HTTPS GET of the probe file over one IP family.
struct ProbeFetch: Sendable, Equatable {
    var ready = false
    var status: Int?
    var bodyOK = false
    /// The local address of the connection (the source address of the request).
    var localAddress: String?
    /// The interface the connection's path used (`NWPath`), never a lookup by address (round 1, Fable M3).
    var interface: String?
    var error: String?
    var timedOut = false
    var failure: ProbeFailure?
    /// Round 2 (Codex r2 #6): the remote address the connection attempted (from its path), for the route check of an
    /// unreachable failure. nil: unknown, and then no failure is a proven local refusal.
    var remoteAddress: String?
    /// Round 3 (Codex r3 #5): the connection got past waiting (an attempt was under way: `.preparing` after `.waiting`,
    /// or on a usable path). Packets may have left, so its timeout or failure is never a local refusal, and never "no
    /// IPv6 here".
    var attempted = false
}

/// Round 2 (Codex r2 #5): what one probe connection has shown so far (pure, tested). Readiness wins: once the connection
/// was ready on an interface, an earlier `.waiting` (no path) is no longer evidence, and a timeout afterwards still
/// reports the readiness and its interface (packets left by it).
struct ProbeEvidence: Sendable, Equatable {
    var local: String?
    var pathInterface: String?
    var wasReady = false
    var waiting: ProbeFailure?
    var waitingError: String?
    var remote: String?
    /// Round 3 (Codex r3 #5): see `ProbeFetch.attempted`.
    var attempted = false

    /// Round 3 (Codex r3 #5): `.preparing`. After a `.waiting`, or on a usable path, an attempt is under way: earlier
    /// waiting evidence is obsolete, and no later wait or timeout of this connection counts as a local refusal.
    mutating func preparing(pathUsable: Bool, remote: String?) {
        guard !wasReady, waiting != nil || pathUsable else { return }
        attempted = true
        waiting = nil
        if let remote { self.remote = remote }
    }

    mutating func becameReady(local: String?, interface: String?) {
        self.local = local
        pathInterface = interface
        wasReady = true
        waiting = nil
        waitingError = nil
    }

    mutating func waited(_ f: ProbeFailure, error: String, remote: String?) {
        guard !wasReady else { return }
        waitingError = error
        if let remote { self.remote = remote }
        if !attempted { waiting = f }
    }

    func timedOut() -> ProbeFetch {
        if wasReady { return ProbeFetch(ready: true, localAddress: local, interface: pathInterface, error: "timed out", timedOut: true) }
        if attempted {
            return ProbeFetch(error: waitingError.map { "timed out after a connection attempt (\($0))" } ?? "timed out after a connection attempt",
                              timedOut: true, failure: nil, remoteAddress: remote, attempted: true)
        }
        return ProbeFetch(error: waitingError.map { "timed out (\($0))" } ?? "timed out", timedOut: true, failure: waiting, remoteAddress: remote)
    }

    /// Round 3 (Codex r3 #5): a failure before readiness. After an attempt, "no path" is no local refusal any more.
    func failedBeforeReady(_ f: ProbeFailure) -> ProbeFailure { attempted && f == .noPath ? .other : f }
}

protocol SelfTestNetworking: Sendable {
    /// One GET of `url` (must be the probe URL) forced to one IP family. Never throws; failures are in the result.
    func fetchProbe(_ family: IPFamily, url: URL, timeout: Duration) async -> ProbeFetch
    /// The interface the kernel routes an IP literal by (`RTM_GET`); nil for anything else.
    func interface(forIP ip: String) -> String?
    /// Round 2 (Codex r2 #6): the same lookup, telling "no route" apart from a failed lookup.
    func routeLookup(forIP ip: String) -> RouteProbe.RouteLookup
    /// Every interface that owns the address (`getifaddrs`).
    func interfaces(owningAddress ip: String) -> [String]
    /// A default route of the family on a physical (non-utun) interface.
    func hasDefaultRoute(_ family: IPFamily, excludingTunnels: Bool) -> Bool
    /// Round 3 (Codex r3 #6): the default route's lookup, telling "none" apart from a failed lookup.
    func defaultRouteLookup(_ family: IPFamily) -> RouteProbe.RouteLookup
}

extension SelfTestNetworking {
    /// Fakes that only model `hasDefaultRoute`: a physical default or none (never a failed lookup).
    func defaultRouteLookup(_ family: IPFamily) -> RouteProbe.RouteLookup {
        hasDefaultRoute(family, excludingTunnels: true) ? .via("en0") : .noRoute
    }
}

enum ConnectionSelfTest {
    /// The one host the test may contact (F8). Nothing else, ever.
    static let probeURL = OnDemandPlan.ownProbeURL
    static let timeout: Duration = .seconds(6)

    // MARK: Classification (pure)

    /// `v6RouteRefuses`: for an `.unreachable` failure, whether the kernel's route for the address the connection
    /// attempted is a local refusal (no route, a reject route on lo0, or the session's own tunnel; round 2, Codex r2 #6).
    static func classify(_ fetch: ProbeFetch, family: IPFamily, facts: SelfTestFacts, hasPhysicalDefault: Bool,
                         v6RouteRefuses: Bool = false) -> PathVerdict {
        let tunnel = facts.tunnelInterface.flatMap { $0.hasPrefix("utun") ? $0 : nil }
        if fetch.ready {
            // A captive portal answers 200 with its own page: only the exact probe answer counts for "through the
            // tunnel". Round 1 (Codex 6): a connection that was established (then failed, or answered wrongly) on another
            // interface under a full tunnel still proves packets left outside it.
            guard fetch.status == 200, fetch.bodyOK else {
                if facts.isFullTunnel, !facts.tunnelAddressCollision, let tunnel, let iface = fetch.interface, iface != tunnel {
                    return .outsideTunnel(interface: iface)
                }
                return .unreachable(fetch.error ?? (fetch.status.map { "unexpected answer (HTTP \($0))" } ?? "unexpected answer"))
            }
            // Round 1 (Fable M3): the proof is the interface the connection's path used, and it must be the session's
            // utun. A source address equal to the tunnel's is supporting evidence only (a LAN can hand it out too).
            if facts.tunnelAddressCollision { return .unreachable("the tunnel's address is also used by another interface") }
            if let tunnel, fetch.interface == tunnel {
                return .throughTunnel(interface: tunnel, source: fetch.localAddress.map(stripScope) ?? "?")
            }
            if !facts.isFullTunnel { return .outsideExpected }
            // Full tunnel and the request did not leave by it. Without the tunnel's identity this proves nothing.
            guard tunnel != nil else { return .unreachable("the tunnel's interface isn't known yet") }
            guard let iface = fetch.interface else { return .unreachable("the connection's interface isn't known") }
            return .outsideTunnel(interface: iface)
        }
        // Something answered (refused, reset, TLS): packets left. Outside the tunnel when the path says so.
        if fetch.failure == .answered, facts.isFullTunnel, !facts.tunnelAddressCollision, let tunnel,
           let iface = fetch.interface, iface != tunnel {
            return .outsideTunnel(interface: iface)
        }
        switch family {
        case .v4:
            return .unreachable(failureText(fetch))
        case .v6:
            if !facts.tunnelsIPv6 && !hasPhysicalDefault && !fetch.attempted { return .noIPv6Here }
            // Round 1 (Fable M2, Sonnet M3): "blocked" is claimed only for a proven local refusal: no usable IPv6 path
            // on this Mac, or an unreachable error the route table confirms is local. A DNS failure, a TLS failure,
            // a refused or reset connection and a timeout prove nothing (or that packets left).
            let blockExpected = facts.isFullTunnel && !facts.tunnelsIPv6 && (facts.killSwitch || facts.blockIPv6)
            let localRefusal = !fetch.attempted && (fetch.failure == .noPath || (fetch.failure == .unreachable && v6RouteRefuses))
            if blockExpected, localRefusal { return .blocked }
            return .unreachable(failureText(fetch))
        }
    }

    private static func failureText(_ f: ProbeFetch) -> String { f.timedOut ? "timed out" : (f.error ?? "no answer") }

    /// What an `NWError` (and whether the path stayed unsatisfied with no interface) says about where packets went.
    static func failure(_ e: NWError, pathUnsatisfied: Bool) -> ProbeFailure {
        if pathUnsatisfied { return .noPath }
        switch e {
        case .dns: return .dns
        case .tls: return .answered
        case .posix(let c):
            switch c {
            case .ECONNREFUSED, .ECONNRESET: return .answered
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EADDRNOTAVAIL: return .unreachable
            default: return .other
            }
        default: return .other
        }
    }

    /// What a route lookup's answer for the attempted address means: no route, lo0 (a reject route) or the session's own
    /// tunnel are local refusals; any other interface is not, and a lookup that failed proves nothing (round 2, Codex r2 #6).
    static func routeRefuses(_ lookup: RouteProbe.RouteLookup, tunnel: String?) -> Bool {
        switch lookup {
        case .noRoute: true
        case .failed: false
        case .via(let via): via == "lo0" || (tunnel != nil && via == tunnel)
        }
    }

    static func stripScope(_ s: String) -> String { String(s.split(separator: "%", maxSplits: 1).first ?? Substring(s)) }

    /// The DNS row: the existing verifier's answer plus, for catch-all profiles, a route check of each name server.
    /// Round 2 (Codex r2 #7): for split DNS, agreement of the configured servers is no proof of the path: the profile's
    /// own servers are route-checked too, and the row says only that those go through the tunnel.
    static func combineDNS(_ base: DNSCheckResult, resolvers: [DNSResolver], routes: [String: String], facts: SelfTestFacts) -> DNSCheckResult {
        guard case .ok = base else { return base }
        guard let tunnel = facts.tunnelInterface else { return .unknown("the tunnel interface isn't known") }
        let servers = dnsServersToCheck(resolvers: resolvers, facts: facts)
        if !facts.dnsCatchAll, servers.isEmpty { return .unknown("the profile's DNS servers aren't known to LockPlus") }
        if servers.isEmpty { return .unknown("the default resolver lists no servers") }
        for s in servers {
            guard let via = routes[s] else { return .unknown("no route found for \(s)") }
            if via == tunnel { continue }
            // §10.2: under includeAllNetworks the route table is not the truth (NECP scopes), so never "leak" from it.
            if facts.includeAllNetworks { return .unknown("\(s) routes via \(via) in the route table; not conclusive with the kill switch on") }
            return .mismatch("\(s) is reached via \(via), not the tunnel (\(tunnel))")
        }
        return .ok
    }

    /// The servers the DNS row route-checks: the default resolver's for a catch-all profile, the profile's own otherwise.
    static func dnsServersToCheck(resolvers: [DNSResolver], facts: SelfTestFacts) -> [String] {
        facts.dnsCatchAll ? resolvers.first(where: { $0.domain == nil })?.nameservers ?? [] : facts.expectedDNS
    }

    /// `.inconclusive` is never `.ok`.
    static func overall(ipv4: PathVerdict, ipv6: PathVerdict, dns: DNSCheckResult, facts: SelfTestFacts) -> SelfTestOverall {
        var problem = false, warning = false, inconclusive = false
        switch ipv4 {
        case .outsideTunnel: problem = true
        case .unreachable: inconclusive = true
        case .blocked, .noIPv6Here: inconclusive = true            // not a v4 outcome; never reads as a pass
        case .throughTunnel, .outsideExpected: break
        }
        switch ipv6 {
        case .outsideTunnel: if facts.killSwitch || facts.blockIPv6 { problem = true } else { warning = true }
        case .unreachable: inconclusive = true
        case .throughTunnel, .outsideExpected, .blocked, .noIPv6Here: break
        }
        if facts.dnsApplicable {
            switch dns {
            case .mismatch: problem = true
            case .unknown: inconclusive = true
            case .ok: break
            }
        }
        return problem ? .problem : warning ? .warning : inconclusive ? .inconclusive : .ok
    }

    // MARK: Run

    /// Two probe fetches at most (v4, v6; v6 is skipped for a split profile that doesn't tunnel it), both to `probeURL`.
    static func run(facts inFacts: SelfTestFacts, dns: (DNSCheckResult, [DNSResolver]), net: any SelfTestNetworking,
                    now: Date = Date()) async -> SelfTestReport {
        var facts = inFacts
        // Round 1 (Fable M3): who owns the tunnel's addresses. One utun only, else no tunnel identity; any other owner
        // (or a second utun) is a collision and every path verdict is inconclusive.
        let owners = facts.tunnelAddresses.map { net.interfaces(owningAddress: $0) }
        let utuns = Set(owners.joined().filter { $0.hasPrefix("utun") })
        if owners.contains(where: { $0.contains { !$0.hasPrefix("utun") } }) || utuns.count > 1 { facts.tunnelAddressCollision = true }
        if facts.tunnelInterface == nil, utuns.count == 1 { facts.tunnelInterface = utuns.first }
        let f = facts
        async let v4 = path(.v4, facts: f, net: net)
        async let v6 = path(.v6, facts: f, net: net)
        let (ipv4, ipv6) = await (v4, v6)

        var routes: [String: String] = [:]
        let servers = dnsServersToCheck(resolvers: dns.1, facts: facts)
        for s in servers { if let i = net.interface(forIP: s) { routes[s] = i } }
        let dnsResult = combineDNS(dns.0, resolvers: dns.1, routes: routes, facts: facts)
        return SelfTestReport(profileID: facts.profileID, at: now, endpoint: facts.endpointHost, ipv4: ipv4, ipv6: ipv6, dns: dnsResult,
                              dnsApplicable: facts.dnsApplicable, dnsServerRoutes: routes, dnsServers: servers,
                              tunnelInterface: facts.tunnelInterface,
                              overall: overall(ipv4: ipv4, ipv6: ipv6, dns: dnsResult, facts: facts), dnsSplit: !facts.dnsCatchAll)
    }

    private static func path(_ family: IPFamily, facts: SelfTestFacts, net: any SelfTestNetworking) async -> PathVerdict {
        // A split profile that doesn't tunnel IPv6: the attempt would go out on the LAN to GitHub. Skip it (§5.5).
        if family == .v6, !facts.isFullTunnel, !facts.tunnelsIPv6 { return .outsideExpected }
        let fetch = await net.fetchProbe(family, url: probeURL, timeout: timeout)
        if Task.isCancelled { return .unreachable("canceled") }
        let physical = family == .v6 && !fetch.ready ? mayHavePhysicalV6(fetch, net: net, tunnel: facts.tunnelInterface) : true
        // Round 2 (Codex r2 #6): the address the connection attempted, never a fixed one; unknown: no proof.
        let refuses = family == .v6 && fetch.failure == .unreachable
            ? fetch.remoteAddress.map { routeRefuses(net.routeLookup(forIP: $0), tunnel: facts.tunnelInterface) } ?? false : false
        return classify(fetch, family: family, facts: facts, hasPhysicalDefault: physical, v6RouteRefuses: refuses)
    }

    /// Round 3 (Codex r3 #6): "no IPv6 on this Mac" only when the default route proves it (none, or one into a tunnel or
    /// lo0: a Block IPv6 blackhole may point the default at the utun while more specific physical routes carry IPv6) AND
    /// nothing destination-specific contradicts it: the attempted address routed out a physical interface, or a lookup
    /// that failed (uncertainty), means IPv6 may be usable, so the verdict can't be "no IPv6 here".
    static func mayHavePhysicalV6(_ fetch: ProbeFetch, net: any SelfTestNetworking, tunnel: String?) -> Bool {
        func local(_ i: String) -> Bool { i.hasPrefix("utun") || i == "lo0" }
        let defaultAbsent: Bool
        switch net.defaultRouteLookup(.v6) {
        case .noRoute: defaultAbsent = true
        case .failed: defaultAbsent = false
        case .via(let i): defaultAbsent = local(i)
        }
        guard defaultAbsent else { return true }
        if let remote = fetch.remoteAddress {
            switch net.routeLookup(forIP: remote) {
            case .failed: return true
            case .via(let i): if !local(i) { return true }
            case .noRoute: break
            }
        }
        return false
    }

    // MARK: Facts

    static func facts(profile p: Profile, snapshot: TunnelSnapshot?) -> SelfTestFacts {
        let live = snapshot?.profileID == p.id ? snapshot : nil
        var addresses = (live?.localAddresses ?? []) + p.summary.addresses
        addresses = addresses.map { String($0.split(separator: "/", maxSplits: 1).first ?? "") }.filter { !$0.isEmpty }
        var seen = Set<String>()
        addresses = addresses.filter { seen.insert(DNSVerifier.normalize($0)).inserted }
        let expectedDNS = p.summary.dnsServers.map(DiagnosticsStore.stripPort)
        let endpoint = (live?.endpoint ?? p.summary.endpoints.first).map(hostOnly)
        return SelfTestFacts(
            profileID: p.id, isFullTunnel: p.summary.isFullTunnel, tunnelsIPv6: addresses.contains { $0.contains(":") },
            killSwitch: p.policy.killSwitch, blockIPv6: p.policy.blockIPv6WithoutKillSwitch,
            dnsCatchAll: p.summary.isFullTunnel || p.policy.dnsMode == .tunnelOnly, expectedDNS: expectedDNS,
            dnsApplicable: !DiagnosticsStore.setsNoDNS(kind: p.kind, dnsServers: expectedDNS, isFullTunnel: p.summary.isFullTunnel),
            tunnelInterface: nil, tunnelAddresses: addresses, endpointHost: endpoint)
    }

    /// "host:port" / "[v6]:port" / "host" -> "host".
    static func hostOnly(_ s: String) -> String { DiagnosticsStore.stripPort(s) }
}

// MARK: - Live networking

struct LiveSelfTestNetworking: SelfTestNetworking {
    func fetchProbe(_ family: IPFamily, url: URL, timeout: Duration) async -> ProbeFetch {
        // The only host this type may ever talk to.
        guard url == ConnectionSelfTest.probeURL, let host = url.host(), !host.isEmpty else {
            return ProbeFetch(error: "refused: not the probe URL")
        }
        let session = ProbeSession(host: host, path: url.path(), family: family)
        return await withTaskCancellationHandler { await session.run(timeout: timeout) } onCancel: { session.cancel() }
    }

    func interface(forIP ip: String) -> String? { RouteProbe.interface(forIP: ip) }
    func routeLookup(forIP ip: String) -> RouteProbe.RouteLookup { RouteProbe.routeLookup(forIP: ip) }
    func interfaces(owningAddress ip: String) -> [String] { RouteProbe.interfaces(owningAddress: ip) }
    func hasDefaultRoute(_ family: IPFamily, excludingTunnels: Bool) -> Bool {
        guard let name = RouteProbe.defaultInterface(ipv6: family == .v6) else { return false }
        return !(excludingTunnels && name.hasPrefix("utun"))
    }
    func defaultRouteLookup(_ family: IPFamily) -> RouteProbe.RouteLookup { RouteProbe.defaultRouteLookup(ipv6: family == .v6) }
}

/// HTTP/1.1 response parsing for the probe (pure; tested).
enum ProbeHTTP {
    /// status and whether the body is exactly "ok" (surrounding whitespace allowed). nil status = no complete header yet.
    static func parse(_ data: Data) -> (status: Int?, bodyOK: Bool, complete: Bool) {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = data.range(of: sep) else { return (nil, false, false) }
        let head = String(decoding: data[data.startIndex..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return (nil, false, true) }
        var length: Int?
        var chunked = false
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            if kv[0].lowercased() == "content-length" { length = Int(kv[1]) }
            if kv[0].lowercased() == "transfer-encoding", kv[1].lowercased().contains("chunked") { chunked = true }
        }
        var body = Data(data[r.upperBound...])
        var complete = false
        if chunked {
            let (decoded, done) = dechunk(body)
            body = decoded; complete = done
        } else if let length {
            complete = body.count >= length
            if body.count > length { body = body.prefix(length) }
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (status, text == "ok", complete)
    }

    private static func dechunk(_ data: Data) -> (Data, Bool) {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let eol = data.range(of: crlf, in: i..<data.endIndex) else { return (out, false) }
            let sizeText = String(decoding: data[i..<eol.lowerBound], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0, size < 65_536 else { return (out, false) }
            if size == 0 { return (out, true) }
            let start = eol.upperBound
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { return (out, false) }
            out.append(data[start..<data.index(start, offsetBy: size)])
            i = data.index(start, offsetBy: size + 2)
        }
    }
}

/// One NWConnection: TLS to the probe host, forced to one IP family, system proxies off, one GET, then closed.
/// Every path (ready, failed, waiting, timeout, task cancellation) ends in `finish`, which cancels the connection and
/// drops the handlers (no cycle, no leak) and resumes the caller exactly once.
// SAFETY: every mutable field lives in `state` (a Mutex); `host`/`path`/`family` are immutable; NWConnection is only touched on `queue`.
private final class ProbeSession: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<ProbeFetch, Never>?
        var done = false
        var connection: NWConnection?
        var buffer = Data()
        /// Round 1 (Sonnet L9, M3): a `.waiting` connection is not finished at once (a path still settling right
        /// after Connected recovers by itself); the timer ends it with what it has shown (round 2: `ProbeEvidence`).
        var evidence = ProbeEvidence()
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "io.github.steiale.lockplus.selftest")
    private let host: String, path: String, family: IPFamily
    private static let maxResponse = 16 * 1024

    init(host: String, path: String, family: IPFamily) { self.host = host; self.path = path; self.family = family }

    func run(timeout: Duration) async -> ProbeFetch {
        await withCheckedContinuation { (k: CheckedContinuation<ProbeFetch, Never>) in
            let early = state.withLock { s -> Bool in
                if s.done { return true }
                s.continuation = k
                return false
            }
            if early { k.resume(returning: ProbeFetch(error: "canceled")); return }
            start(timeout: timeout)
        }
    }

    func cancel() { finish(ProbeFetch(error: "canceled")) }

    private func start(timeout: Duration) {
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = family == .v4 ? .v4 : .v6 }
        params.preferNoProxies = true                       // the test is about the path; a proxy would hide it
        guard let port = NWEndpoint.Port(rawValue: 443) else { return finish(ProbeFetch(error: "bad port")) }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        let installed = state.withLock { s -> Bool in
            guard !s.done else { return false }
            s.connection = conn
            return true
        }
        guard installed else { conn.cancel(); return }
        conn.stateUpdateHandler = { [weak self] st in self?.handle(st, conn) }
        conn.start(queue: queue)
        let ms = max(1, Int(timeout / .milliseconds(1)))
        queue.asyncAfter(deadline: .now() + .milliseconds(ms)) { @Sendable [weak self] in
            guard let self else { return }
            finish(state.withLock { $0.evidence.timedOut() })
        }
    }

    private func handle(_ st: NWConnection.State, _ conn: NWConnection) {
        switch st {
        case .ready:
            let local = Self.localAddress(conn.currentPath)
            let iface = Self.pathInterface(conn.currentPath)
            state.withLock { $0.evidence.becameReady(local: local, interface: iface) }
            let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: LockPlus\r\nAccept: text/plain\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] err in
                if let err { self?.finish(ProbeFetch(ready: true, localAddress: local, interface: iface, error: "send failed: \(err)")) }
            })
            receive(conn)
        case .failed(let e):
            // Round 1 (Codex 6): a failure after `.ready` keeps the readiness and the path it had.
            let path = conn.currentPath
            let was = state.withLock { $0.evidence }
            if was.wasReady {
                finish(ProbeFetch(ready: true, localAddress: was.local, interface: was.pathInterface, error: "\(e)", failure: Self.failure(e, path)))
            } else {
                finish(ProbeFetch(localAddress: Self.localAddress(path), interface: Self.pathInterface(path), error: "\(e)",
                                  failure: was.failedBeforeReady(Self.failure(e, path)), remoteAddress: Self.remoteAddress(path) ?? was.remote,
                                  attempted: was.attempted))
            }
        case .waiting(let e):
            // No usable path for this family right now: remembered, and the timer decides (it may still recover).
            let f = Self.failure(e, conn.currentPath), remote = Self.remoteAddress(conn.currentPath)
            state.withLock { $0.evidence.waited(f, error: "\(e)", remote: remote) }
        case .preparing:
            // Round 3 (Codex r3 #5): an attempt resumed after waiting, or under way on a usable path.
            let path = conn.currentPath
            let usable = path.map { $0.status == .satisfied && !$0.availableInterfaces.isEmpty } ?? false
            let remote = Self.remoteAddress(path)
            state.withLock { $0.evidence.preparing(pathUsable: usable, remote: remote) }
        case .cancelled:
            finish(ProbeFetch(error: "canceled"))
        default:
            break
        }
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let (snapshot, local, iface) = state.withLock { s -> (Data, String?, String?) in
                if let data { s.buffer.append(data) }
                return (s.buffer, s.evidence.local, s.evidence.pathInterface)
            }
            let parsed = ProbeHTTP.parse(snapshot)
            if error != nil || isComplete || parsed.complete || snapshot.count > Self.maxResponse {
                if parsed.status == nil, let error {
                    finish(ProbeFetch(ready: true, localAddress: local, interface: iface, error: "\(error)"))
                } else {
                    finish(ProbeFetch(ready: true, status: parsed.status, bodyOK: parsed.bodyOK, localAddress: local, interface: iface))
                }
            } else {
                receive(conn)
            }
        }
    }

    private func finish(_ result: ProbeFetch) {
        let (k, conn) = state.withLock { s -> (CheckedContinuation<ProbeFetch, Never>?, NWConnection?) in
            guard !s.done else { return (nil, nil) }
            s.done = true
            let out = (s.continuation, s.connection)
            s.continuation = nil
            s.connection = nil
            return out
        }
        if let conn { conn.stateUpdateHandler = nil; conn.cancel() }
        k?.resume(returning: result)
    }

    /// The interface the connection's path uses (for a connected TCP path, the first available interface).
    private static func pathInterface(_ path: NWPath?) -> String? {
        path?.availableInterfaces.first?.name
    }

    static func failure(_ e: NWError, _ path: NWPath?) -> ProbeFailure {
        ConnectionSelfTest.failure(e, pathUnsatisfied: path.map { $0.status == .unsatisfied && $0.availableInterfaces.isEmpty } ?? false)
    }

    private static func remoteAddress(_ path: NWPath?) -> String? { address(path?.remoteEndpoint) }

    private static func localAddress(_ path: NWPath?) -> String? { address(path?.localEndpoint) }

    private static func address(_ endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return ConnectionSelfTest.stripScope(a.debugDescription)
        case .ipv6(let a): return ConnectionSelfTest.stripScope(a.debugDescription)
        default: return nil
        }
    }
}

// MARK: - Presentation (pure)

struct SelfTestRow: Identifiable, Equatable {
    enum ID: String, Sendable { case ipv4, ipv6, dns, exit }
    var id: ID
    var title: String
    /// nil = informational (no pass/fail glyph).
    var result: DiagnosticCheck.Result?
    var text: String
    var detail: String = ""
}

extension SelfTestReport {
    /// `includeEndpoint: false` for text that leaves the app by the user's hand ("Copy Results"): the server's address stays out.
    func rows(includeEndpoint: Bool = true) -> [SelfTestRow] {
        [
            SelfTestRow(id: .ipv4, title: String(localized: "IPv4", comment: "Self-test row"), result: Self.glyph(ipv4, v6: false),
                        text: Self.text(ipv4, v6: false), detail: Self.detail(ipv4)),
            SelfTestRow(id: .ipv6, title: String(localized: "IPv6", comment: "Self-test row"), result: Self.glyph(ipv6, v6: true),
                        text: Self.text(ipv6, v6: true), detail: Self.detail(ipv6)),
            dnsRow,
            exitRow(includeEndpoint: includeEndpoint),
        ]
    }

    var headline: String {
        switch overall {
        // Round 1 (Codex 9): "IPv4, IPv6 and DNS" only when all three were proven through the tunnel; a split profile, a
        // blocked or absent IPv6, or a profile without DNS settings gets the headline that claims no more than was shown.
        case .ok where Self.allThroughTunnel(ipv4: ipv4, ipv6: ipv6, dns: dns, dnsApplicable: dnsApplicable):
            String(localized: "IPv4, IPv6 and DNS use the tunnel", comment: "Self-test result headline")
        case .ok: String(localized: "Everything this profile sends through the VPN uses the tunnel",
                         comment: "Self-test result headline: passed, but not every row is 'through the tunnel' (split profile, IPv6 blocked or absent, no DNS settings)")
        case .warning: String(localized: "Part of your traffic may bypass the VPN", comment: "Self-test result headline")
        case .problem: String(localized: "Some of your traffic doesn't use the VPN", comment: "Self-test result headline")
        case .inconclusive: String(localized: "The connection couldn't be fully verified", comment: "Self-test result headline (never shown as safe)")
        }
    }

    static func allThroughTunnel(ipv4: PathVerdict, ipv6: PathVerdict, dns: DNSCheckResult, dnsApplicable: Bool) -> Bool {
        func through(_ v: PathVerdict) -> Bool { if case .throughTunnel = v { true } else { false } }
        return through(ipv4) && through(ipv6) && dnsApplicable && dns == .ok
    }

    var overallGlyph: DiagnosticCheck.Result {
        switch overall {
        case .ok: .pass
        case .warning: .warning
        case .problem: .fail
        case .inconclusive: .unknown
        }
    }

    private static func glyph(_ v: PathVerdict, v6: Bool) -> DiagnosticCheck.Result {
        switch v {
        case .throughTunnel, .blocked, .outsideExpected, .noIPv6Here: .pass
        case .outsideTunnel: v6 ? .warning : .fail
        case .unreachable: .unknown
        }
    }

    private static func text(_ v: PathVerdict, v6: Bool) -> String {
        switch v {
        case .throughTunnel(let i, let s):
            String(localized: "Through the tunnel (\(i), from \(s))", comment: "Self-test row: the request left by the tunnel interface")
        case .outsideTunnel(let i):
            v6 ? String(localized: "Bypasses the VPN (\(i))", comment: "Self-test IPv6 row: the request left outside the tunnel")
               : String(localized: "Outside the tunnel (\(i))", comment: "Self-test IPv4 row: the request left outside the tunnel")
        case .outsideExpected:
            v6 ? String(localized: "Not part of this tunnel", comment: "Self-test IPv6 row, split profile (the test is skipped)")
               : String(localized: "Outside the tunnel, as expected for this profile", comment: "Self-test IPv4 row, split profile")
        case .blocked:
            String(localized: "Blocked, nothing goes around the tunnel", comment: "Self-test IPv6 row: IPv6 is blocked under a full tunnel (a local refusal was proven)")
        case .noIPv6Here:
            String(localized: "No IPv6 on this network", comment: "Self-test IPv6 row")
        case .unreachable:
            String(localized: "Couldn't reach the test host", comment: "Self-test row (never shown as safe)")
        }
    }

    private static func detail(_ v: PathVerdict) -> String {
        if case .unreachable(let why) = v { return why }
        return ""
    }

    private var dnsRow: SelfTestRow {
        let title = String(localized: "DNS", comment: "Self-test row")
        guard dnsApplicable else {
            return SelfTestRow(id: .dns, title: title, result: nil,
                               text: String(localized: "The profile sets no DNS server: DNS stays as it is", comment: "Self-test DNS row"))
        }
        let servers = dnsServers.joined(separator: ", ")
        switch dns {
        case .ok where dnsSplit:
            // Round 2 (Codex r2 #7): split DNS: only the profile's own servers were shown to use the tunnel.
            return SelfTestRow(id: .dns, title: title, result: .pass,
                               text: String(localized: "The profile's DNS servers are reached through the tunnel (\(servers)); other names use your network's DNS",
                                            comment: "Self-test DNS row, split DNS (2.0.2 round 2)"))
        case .ok:
            let text = servers.isEmpty ? String(localized: "Through the tunnel", comment: "Self-test DNS row")
                                       : String(localized: "Through the tunnel (\(servers))", comment: "Self-test DNS row")
            return SelfTestRow(id: .dns, title: title, result: .pass, text: text)
        case .mismatch(let d):
            return SelfTestRow(id: .dns, title: title, result: .fail,
                               text: String(localized: "Mismatch: another resolver or route handles DNS", comment: "Self-test DNS row"), detail: d)
        case .unknown(let r):
            return SelfTestRow(id: .dns, title: title, result: .unknown,
                               text: String(localized: "Couldn't verify DNS", comment: "Self-test DNS row (never shown as safe)"), detail: r)
        }
    }

    private func exitRow(includeEndpoint: Bool) -> SelfTestRow {
        let title = String(localized: "Exit address", comment: "Self-test row")
        let text: String
        if includeEndpoint, let endpoint, !endpoint.isEmpty {
            text = String(localized: "The address websites see isn't checked. Websites usually see the address of your VPN server (\(endpoint)). LockPlus doesn't ask third-party services to confirm it.",
                          comment: "Self-test exit-address row (D-5: no echo service)")
        } else {
            text = String(localized: "The address websites see isn't checked. Websites usually see the address of your VPN server. LockPlus doesn't ask third-party services to confirm it.",
                          comment: "Self-test exit-address row (D-5: no echo service), server address left out")
        }
        return SelfTestRow(id: .exit, title: title, result: nil, text: text)
    }

    /// "Copy Results": rows only, no server address, no profile name.
    /// Round 1 (Codex 10): the whole copied text goes through the diagnostics Redactor (addresses and host names
    /// hashed, details included), and the server's address is replaced first wherever it appears (a DNS row or an
    /// error detail can name it too). Only the probe host stays readable.
    func copyText() -> String {
        var text = ([headline] + rows(includeEndpoint: false).map { "\($0.title): \($0.text)" + ($0.detail.isEmpty ? "" : " [\($0.detail)]") })
            .joined(separator: "\n")
        if let e = endpoint, !e.isEmpty { text = text.replacingOccurrences(of: e, with: "<server>") }
        return Redactor(keep: [ConnectionSelfTest.probeURL.host() ?? ""]).redact(text)
    }

    /// The diagnostics bundle's `selftest.txt`: English, machine-friendly; the bundle's Redactor hashes addresses.
    func bundleText() -> String {
        func v(_ p: PathVerdict) -> String {
            switch p {
            case .throughTunnel(let i, let s): "throughTunnel interface=\(i) source=\(s)"
            case .outsideTunnel(let i): "outsideTunnel interface=\(i)"
            case .outsideExpected: "outsideExpected"
            case .blocked: "blocked"
            case .noIPv6Here: "noIPv6Here"
            case .unreachable(let w): "unreachable (\(w))"
            }
        }
        let dnsText: String = switch dns {
        case .ok: dnsApplicable ? "ok" : "not applicable (profile sets no DNS)"
        case .mismatch(let d): "mismatch (\(d))"
        case .unknown(let r): "unknown (\(r))"
        }
        let routes = dnsServerRoutes.sorted { $0.key < $1.key }.map { "\($0.key) via \($0.value)" }.joined(separator: "; ")
        return """
            Connection self-test, \(at.ISO8601Format())
            overall: \(overall)
            tunnel interface: \(tunnelInterface ?? "unknown")
            ipv4: \(v(ipv4))
            ipv6: \(v(ipv6))
            dns: \(dnsText)
            dns server routes: \(routes.isEmpty ? "none" : routes)
            exit address: not checked (no third-party service is asked)
            """
    }
}
