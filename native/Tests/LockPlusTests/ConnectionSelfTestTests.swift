import Foundation
import LPModel
import LPRouteProbe
import LPWire
import Network
import Synchronization
import Testing
@testable import LockPlus

/// 2.0.2 item 5 / D-5: the connection self-test proves the path (tunnel interface, source address, IPv6, DNS) and never
/// claims the address websites see. Pure classification table, the single-host rule, the lifecycle, the wording.
@Suite("Connection self-test (2.0.2)")
struct ConnectionSelfTestTests {
    // MARK: Fixtures

    static let tunnelV4 = "10.8.0.2"
    static let tunnelV6 = "fd00::2"

    static func facts(full: Bool = true, v6: Bool = false, ks: Bool = true, block: Bool = false, dns: Bool = true,
                      known: Bool = true) -> SelfTestFacts {
        SelfTestFacts(profileID: UUID(), isFullTunnel: full, tunnelsIPv6: v6, killSwitch: ks, blockIPv6: block, dnsCatchAll: full,
                      expectedDNS: dns ? ["10.8.0.1"] : [], dnsApplicable: dns, tunnelInterface: known ? "utun4" : nil,
                      tunnelAddresses: known ? (v6 ? [tunnelV4, tunnelV6] : [tunnelV4]) : [], endpointHost: "198.51.100.7")
    }

    static func ok(from address: String, on interface: String) -> ProbeFetch {
        ProbeFetch(ready: true, status: 200, bodyOK: true, localAddress: address, interface: interface)
    }

    static let attemptedV6 = "2606:50c0:8000::153"
    static let failed = ProbeFetch(ready: false, error: "network is unreachable", failure: .unreachable, remoteAddress: attemptedV6)
    static let timedOut = ProbeFetch(ready: false, error: "timed out", timedOut: true)
    static func failing(_ f: ProbeFailure, _ error: String, local: String? = nil, on interface: String? = nil) -> ProbeFetch {
        ProbeFetch(ready: false, localAddress: local, interface: interface, error: error, failure: f)
    }

    // MARK: classify (one row per behaviour)

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var fetch: ProbeFetch
        var family: IPFamily
        var facts: SelfTestFacts
        var physicalDefault = true
        var routeRefuses = false
        var expect: PathVerdict
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        .init(name: "full+v6 tunnel, v4 through utun", fetch: ok(from: tunnelV4, on: "utun4"), family: .v4, facts: facts(v6: true),
              expect: .throughTunnel(interface: "utun4", source: tunnelV4)),
        .init(name: "full+v6 tunnel, v6 through utun", fetch: ok(from: tunnelV6, on: "utun4"), family: .v6, facts: facts(v6: true),
              expect: .throughTunnel(interface: "utun4", source: tunnelV6)),
        .init(name: "full v4-only + KS, v6 unreachable and the route is local -> blocked", fetch: failed, family: .v6, facts: facts(),
              routeRefuses: true, expect: .blocked),
        .init(name: "full v4-only + Block IPv6, v6 unreachable and the route is local -> blocked", fetch: failed, family: .v6,
              facts: facts(ks: false, block: true), routeRefuses: true, expect: .blocked),
        // Round 1 (Fable M2, Sonnet M3): one row per failure class; only a proven local refusal is "blocked".
        .init(name: "v6 unreachable but the route goes out on en0 (an ICMP answer from the LAN) -> unreachable", fetch: failed,
              family: .v6, facts: facts(), routeRefuses: false, expect: .unreachable("network is unreachable")),
        .init(name: "v6 path unsatisfied, no interface -> blocked", fetch: failing(.noPath, "no path"), family: .v6, facts: facts(),
              expect: .blocked),
        .init(name: "v6 path stayed unsatisfied until the timer -> blocked", fetch: ProbeFetch(error: "timed out (no path)", timedOut: true,
              failure: .noPath), family: .v6, facts: facts(), expect: .blocked),
        .init(name: "v6 DNS failure proves nothing -> unreachable", fetch: failing(.dns, "dns"), family: .v6, facts: facts(),
              routeRefuses: true, expect: .unreachable("dns")),
        .init(name: "v6 TLS failure on en0 -> outside the tunnel", fetch: failing(.answered, "tls", local: "2001:db8::5", on: "en0"),
              family: .v6, facts: facts(), expect: .outsideTunnel(interface: "en0")),
        .init(name: "v6 connection refused on en0 -> outside the tunnel", fetch: failing(.answered, "refused", on: "en0"), family: .v6,
              facts: facts(block: true), expect: .outsideTunnel(interface: "en0")),
        .init(name: "v6 reset with no interface known -> unreachable, never blocked", fetch: failing(.answered, "reset"), family: .v6,
              facts: facts(), routeRefuses: true, expect: .unreachable("reset")),
        .init(name: "v6 other error -> unreachable", fetch: failing(.other, "x"), family: .v6, facts: facts(), routeRefuses: true,
              expect: .unreachable("x")),
        .init(name: "v4 refused on en0 under a full tunnel -> outside", fetch: failing(.answered, "refused", on: "en0"), family: .v4,
              facts: facts(), expect: .outsideTunnel(interface: "en0")),
        .init(name: "v4 refused through the tunnel -> unreachable", fetch: failing(.answered, "refused", on: "utun4"), family: .v4,
              facts: facts(), expect: .unreachable("refused")),
        .init(name: "v6 timeout under KS proves nothing", fetch: timedOut, family: .v6, facts: facts(),
              expect: .unreachable("timed out")),
        .init(name: "full v4-only, no KS, no block, v6 ready on en0 -> outside", fetch: ok(from: "2001:db8::5", on: "en0"), family: .v6,
              facts: facts(ks: false), expect: .outsideTunnel(interface: "en0")),
        .init(name: "v6 refused, no physical v6 default -> no IPv6 here", fetch: failed, family: .v6, facts: facts(),
              physicalDefault: false, expect: .noIPv6Here),
        .init(name: "v6 refused, no KS, no block, physical v6 exists -> unreachable", fetch: failed, family: .v6, facts: facts(ks: false),
              expect: .unreachable("network is unreachable")),
        .init(name: "split, v4 ready on en0 -> outside, expected", fetch: ok(from: "192.168.1.20", on: "en0"), family: .v4,
              facts: facts(full: false, ks: false), expect: .outsideExpected),
        .init(name: "v4 ready on en0 under a full tunnel -> outside", fetch: ok(from: "192.168.1.20", on: "en0"), family: .v4,
              facts: facts(), expect: .outsideTunnel(interface: "en0")),
        .init(name: "full tunnel, request left by another VPN's utun", fetch: ok(from: "10.99.0.2", on: "utun7"), family: .v4,
              facts: facts(), expect: .outsideTunnel(interface: "utun7")),
        .init(name: "HTTP 200, body is not ok (a portal) -> unreachable", fetch: ProbeFetch(ready: true, status: 200, bodyOK: false,
              localAddress: tunnelV4, interface: "utun4"), family: .v4, facts: facts(), expect: .unreachable("unexpected answer (HTTP 200)")),
        .init(name: "portal answer cannot be through the tunnel even from the tunnel address", fetch: ProbeFetch(ready: true, status: 302,
              bodyOK: false, localAddress: tunnelV4, interface: "utun4"), family: .v4, facts: facts(), expect: .unreachable("unexpected answer (HTTP 302)")),
        .init(name: "a portal's page on en0 under a full tunnel is still a leak (Codex 6)", fetch: ProbeFetch(ready: true, status: 200,
              bodyOK: false, localAddress: "192.168.1.20", interface: "en0"), family: .v4, facts: facts(), expect: .outsideTunnel(interface: "en0")),
        .init(name: "a failure after ready on en0 -> outside (Codex 6)", fetch: ProbeFetch(ready: true, localAddress: "192.168.1.20",
              interface: "en0", error: "reset", failure: .answered), family: .v6, facts: facts(), routeRefuses: true, expect: .outsideTunnel(interface: "en0")),
        .init(name: "a failure after ready through the tunnel -> unreachable", fetch: ProbeFetch(ready: true, localAddress: tunnelV4,
              interface: "utun4", error: "reset", failure: .answered), family: .v4, facts: facts(), expect: .unreachable("reset")),
        .init(name: "v4 timeout -> unreachable", fetch: timedOut, family: .v4, facts: facts(), expect: .unreachable("timed out")),
        .init(name: "v4 connect failure -> unreachable", fetch: failed, family: .v4, facts: facts(), expect: .unreachable("network is unreachable")),
        .init(name: "full tunnel, tunnel identity unknown -> unreachable, never a false leak", fetch: ok(from: "192.168.1.20", on: "en0"),
              family: .v4, facts: facts(known: false), expect: .unreachable("the tunnel's interface isn't known yet")),
        // Round 1 (Fable M3): the interface the connection used decides; a matching source address alone never does.
        .init(name: "the tunnel's source address on en0 (a LAN handing out 10.8.0.2) -> outside", fetch: ok(from: tunnelV4, on: "en0"),
              family: .v4, facts: facts(), expect: .outsideTunnel(interface: "en0")),
        .init(name: "a matching source address without the path's interface is not proof", fetch: ProbeFetch(ready: true, status: 200,
              bodyOK: true, localAddress: tunnelV4, interface: nil), family: .v4, facts: facts(), expect: .unreachable("the connection's interface isn't known")),
        .init(name: "a tunnel address also owned by another interface -> inconclusive", fetch: ok(from: tunnelV4, on: "utun4"), family: .v4,
              facts: { var f = facts(); f.tunnelAddressCollision = true; return f }(),
              expect: .unreachable("the tunnel's address is also used by another interface")),
        .init(name: "a non-utun 'tunnel interface' never counts", fetch: ok(from: tunnelV4, on: "en0"), family: .v4,
              facts: { var f = facts(); f.tunnelInterface = "en0"; return f }(), expect: .unreachable("the tunnel's interface isn't known yet")),
    ]

    @Test(arguments: cases) func classify(_ c: Case) {
        #expect(ConnectionSelfTest.classify(c.fetch, family: c.family, facts: c.facts, hasPhysicalDefault: c.physicalDefault,
                                            v6RouteRefuses: c.routeRefuses) == c.expect)
    }

    /// Round 1 (Fable M2): each error class of a failed probe connection.
    @Test func failureClasses() {
        typealias T = ConnectionSelfTest
        #expect(T.failure(.posix(.ENETUNREACH), pathUnsatisfied: true) == .noPath)
        #expect(T.failure(.dns(-65554), pathUnsatisfied: false) == .dns)
        #expect(T.failure(.tls(-9806), pathUnsatisfied: false) == .answered)
        #expect(T.failure(.posix(.ECONNREFUSED), pathUnsatisfied: false) == .answered)
        #expect(T.failure(.posix(.ECONNRESET), pathUnsatisfied: false) == .answered)
        for c in [POSIXErrorCode.ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EADDRNOTAVAIL] {
            #expect(T.failure(.posix(c), pathUnsatisfied: false) == .unreachable)
        }
        #expect(T.failure(.posix(.ETIMEDOUT), pathUnsatisfied: false) == .other)
        #expect(T.routeRefuses(.noRoute, tunnel: "utun4") && T.routeRefuses(.via("lo0"), tunnel: "utun4") && T.routeRefuses(.via("utun4"), tunnel: "utun4"))
        #expect(!T.routeRefuses(.via("en0"), tunnel: "utun4") && !T.routeRefuses(.via("utun7"), tunnel: "utun4") && !T.routeRefuses(.via("utun4"), tunnel: nil))
        #expect(!T.routeRefuses(.failed, tunnel: "utun4"))                       // round 2 (Codex r2 #6): a failed lookup proves nothing
    }

    // MARK: overall

    @Test func overallInconclusiveIsNeverOK() {
        let f = Self.facts()
        let through = PathVerdict.throughTunnel(interface: "utun4", source: Self.tunnelV4)
        let all: [PathVerdict] = [through, .outsideTunnel(interface: "en0"), .outsideExpected, .blocked, .noIPv6Here, .unreachable("x")]
        let dnsAll: [DNSCheckResult] = [.ok, .mismatch("m"), .unknown("u")]
        for v4 in all { for v6 in all { for d in dnsAll {
            let o = ConnectionSelfTest.overall(ipv4: v4, ipv6: v6, dns: d, facts: f)
            let anyUnknown = [v4, v6].contains { if case .unreachable = $0 { true } else { false } } || d == .unknown("u")
            if anyUnknown { #expect(o != .ok, "\(v4) \(v6) \(d)") }
            if case .outsideTunnel = v4 { #expect(o == .problem) }
            if case .mismatch = d { #expect(o == .problem) }
        } } }
        #expect(ConnectionSelfTest.overall(ipv4: through, ipv6: .blocked, dns: .ok, facts: f) == .ok)
        #expect(ConnectionSelfTest.overall(ipv4: through, ipv6: .noIPv6Here, dns: .ok, facts: f) == .ok)
    }

    @Test func overallIPv6LeakIsAWarningOnlyWithoutProtection() {
        let through = PathVerdict.throughTunnel(interface: "utun4", source: Self.tunnelV4)
        let out = PathVerdict.outsideTunnel(interface: "en0")
        #expect(ConnectionSelfTest.overall(ipv4: through, ipv6: out, dns: .ok, facts: Self.facts(ks: false)) == .warning)
        #expect(ConnectionSelfTest.overall(ipv4: through, ipv6: out, dns: .ok, facts: Self.facts(ks: true)) == .problem)
        #expect(ConnectionSelfTest.overall(ipv4: through, ipv6: out, dns: .ok, facts: Self.facts(ks: false, block: true)) == .problem)
    }

    @Test func aProfileThatSetsNoDNSDoesNotMakeTheTestInconclusive() {
        let f = Self.facts(full: false, ks: false, dns: false)
        #expect(ConnectionSelfTest.overall(ipv4: .outsideExpected, ipv6: .outsideExpected, dns: .ok, facts: f) == .ok)
    }

    // MARK: DNS route check

    static let resolvers = [DNSResolver(index: 1, domain: nil, nameservers: ["10.8.0.1"], interface: "utun4")]

    @Test func dnsRouteThroughTheTunnelIsOK() {
        #expect(ConnectionSelfTest.combineDNS(.ok, resolvers: Self.resolvers, routes: ["10.8.0.1": "utun4"], facts: Self.facts(ks: false)) == .ok)
    }

    @Test func dnsRouteViaEn0IsAMismatchWithoutIncludeAllNetworks() {
        let r = ConnectionSelfTest.combineDNS(.ok, resolvers: Self.resolvers, routes: ["10.8.0.1": "en0"], facts: Self.facts(ks: false))
        guard case .mismatch = r else { Issue.record("expected mismatch, got \(r)"); return }
    }

    @Test func dnsRouteEn0UnderIncludeAllNetworksIsInconclusive() {
        let r = ConnectionSelfTest.combineDNS(.ok, resolvers: Self.resolvers, routes: ["10.8.0.1": "en0"], facts: Self.facts(ks: true))
        guard case .unknown = r else { Issue.record("expected unknown, got \(r)"); return }
    }

    @Test func dnsWithoutARouteAnswerIsInconclusive() {
        guard case .unknown = ConnectionSelfTest.combineDNS(.ok, resolvers: Self.resolvers, routes: [:], facts: Self.facts()) else {
            Issue.record("expected unknown"); return
        }
        guard case .unknown = ConnectionSelfTest.combineDNS(.ok, resolvers: [], routes: [:], facts: Self.facts()) else {
            Issue.record("expected unknown"); return
        }
    }

    @Test func dnsBaseFailuresPassThroughAndSplitIsNotRouteChecked() {
        #expect(ConnectionSelfTest.combineDNS(.mismatch("x"), resolvers: Self.resolvers, routes: [:], facts: Self.facts()) == .mismatch("x"))
        #expect(ConnectionSelfTest.combineDNS(.unknown("x"), resolvers: Self.resolvers, routes: [:], facts: Self.facts()) == .unknown("x"))
        // Round 2 (Codex r2 #7): split DNS is route-checked by the profile's own servers, never passed on agreement.
        guard case .mismatch = ConnectionSelfTest.combineDNS(.ok, resolvers: Self.resolvers, routes: ["10.8.0.1": "en0"], facts: Self.facts(full: false, ks: false)) else {
            Issue.record("expected mismatch"); return
        }
        #expect(ConnectionSelfTest.combineDNS(.ok, resolvers: Self.resolvers, routes: ["10.8.0.1": "utun4"], facts: Self.facts(full: false, ks: false)) == .ok)
        var unknownServers = Self.facts(full: false, ks: false)
        unknownServers.expectedDNS = []
        guard case .unknown = ConnectionSelfTest.combineDNS(.ok, resolvers: Self.resolvers, routes: [:], facts: unknownServers) else {
            Issue.record("expected unknown"); return
        }
    }

    // MARK: Round 2 (Codex r2 #5, #6, #7)

    /// #5: waiting (no path) → ready on en0 → the GET stalls → timeout. The readiness and its interface survive; the
    /// stale "no path" doesn't, so an IPv4-only full tunnel's IPv6 row is "outside the tunnel", never "blocked".
    @Test func readinessSurvivesATimeoutAndClearsAStaleWaiting() {
        var e = ProbeEvidence()
        e.waited(.noPath, error: "no path", remote: nil)
        e.becameReady(local: "2001:db8::5", interface: "en0")
        e.waited(.noPath, error: "late", remote: nil)                         // ignored after readiness
        let f = e.timedOut()
        #expect(f.ready && f.interface == "en0" && f.failure == nil && f.timedOut)
        #expect(ConnectionSelfTest.classify(f, family: .v6, facts: Self.facts(), hasPhysicalDefault: true) == .outsideTunnel(interface: "en0"))
        var w = ProbeEvidence()
        w.waited(.noPath, error: "no path", remote: nil)
        #expect(w.timedOut().failure == .noPath && !w.timedOut().ready)
    }

    /// #6: the route check uses the address the connection attempted, and a failed lookup is no proof.
    @Test func theV6RouteCheckUsesTheAttemptedAddress() async {
        let net = Recorder()
        net.v6 = ProbeFetch(ready: false, error: "unreachable", failure: .unreachable, remoteAddress: "2001:db8::77")
        net.routes = ["10.8.0.1": "utun4", Self.attemptedV6: "utun4", "2001:db8::77": "en0"]
        #expect(await ConnectionSelfTest.run(facts: Self.facts(), dns: (.ok, Self.resolvers), net: net).ipv6 == .unreachable("unreachable"))
        net.routes = ["10.8.0.1": "utun4"]
        net.lookupDefault = .failed
        #expect(await ConnectionSelfTest.run(facts: Self.facts(), dns: (.ok, Self.resolvers), net: net).ipv6 == .unreachable("unreachable"))
        net.lookupDefault = .noRoute
        #expect(await ConnectionSelfTest.run(facts: Self.facts(), dns: (.ok, Self.resolvers), net: net).ipv6 == .blocked)
        net.v6.remoteAddress = nil                                              // unknown destination: no proof
        #expect(await ConnectionSelfTest.run(facts: Self.facts(), dns: (.ok, Self.resolvers), net: net).ipv6 == .unreachable("unreachable"))
    }

    /// #7: the split-DNS row says what was shown, not "Through the tunnel".
    @Test func splitDNSIsPresentedAsSplit() async {
        let net = Recorder()
        net.v4 = Self.ok(from: "192.168.1.20", on: "en0")
        let report = await ConnectionSelfTest.run(facts: Self.facts(full: false, ks: false), dns: (.ok, Self.resolvers), net: net)
        #expect(report.dns == .ok && report.dnsSplit && report.dnsServers == ["10.8.0.1"])
        let row = report.rows(includeEndpoint: false).first { $0.id == .dns }
        #expect(row?.text.contains("other names use your network's DNS") == true)
    }

    // MARK: Contact rules

    final class Recorder: SelfTestNetworking, @unchecked Sendable {
        private let log = Mutex<[(IPFamily, URL)]>([])
        var v4 = ConnectionSelfTestTests.ok(from: ConnectionSelfTestTests.tunnelV4, on: "utun4")
        var v6 = ConnectionSelfTestTests.failed
        var routes: [String: String] = ["10.8.0.1": "utun4"]
        var fetches: [(IPFamily, URL)] { log.withLock { $0 } }
        func record(_ family: IPFamily, _ url: URL) { log.withLock { $0.append((family, url)) } }
        func fetchProbe(_ family: IPFamily, url: URL, timeout: Duration) async -> ProbeFetch {
            record(family, url)
            return family == .v4 ? v4 : v6
        }
        func interface(forIP ip: String) -> String? { routes[ip] }
        var lookupDefault: RouteProbe.RouteLookup = .noRoute
        func routeLookup(forIP ip: String) -> RouteProbe.RouteLookup { routes[ip].map { .via($0) } ?? lookupDefault }
        var owners: [String: [String]] = [ConnectionSelfTestTests.tunnelV4: ["utun4"]]
        func interfaces(owningAddress ip: String) -> [String] { owners[ip] ?? [] }
        func hasDefaultRoute(_ family: IPFamily, excludingTunnels: Bool) -> Bool { true }
    }

    @Test func onlyTheProbeHostIsContacted() async {
        let net = Recorder()
        let report = await ConnectionSelfTest.run(facts: Self.facts(), dns: (.ok, Self.resolvers), net: net)
        #expect(net.fetches.count == 2)
        #expect(net.fetches.allSatisfy { $0.1 == OnDemandPlan.ownProbeURL && $0.1.host() == "steiale.github.io" })
        #expect(Set(net.fetches.map { $0.0 == .v4 }) == [true, false])
        #expect(report.ipv4 == .throughTunnel(interface: "utun4", source: Self.tunnelV4))
        #expect(report.ipv6 == .blocked)
        #expect(report.dns == .ok)
        #expect(report.overall == .ok)
        #expect(report.tunnelInterface == "utun4")
    }

    @Test func aSplitProfileWithoutIPv6SkipsTheIPv6Attempt() async {
        let net = Recorder()
        net.v4 = Self.ok(from: "192.168.1.20", on: "en0")
        let report = await ConnectionSelfTest.run(facts: Self.facts(full: false, ks: false), dns: (.ok, Self.resolvers), net: net)
        #expect(net.fetches.map { $0.0 } == [.v4])                  // nothing is sent out on the LAN for IPv6
        #expect(report.ipv4 == .outsideExpected)
        #expect(report.ipv6 == .outsideExpected)
        #expect(report.overall == .ok)
    }

    @Test func theTunnelInterfaceIsLookedUpByItsAddress() async {
        var f = Self.facts()
        f.tunnelInterface = nil
        let report = await ConnectionSelfTest.run(facts: f, dns: (.ok, Self.resolvers), net: Recorder())
        #expect(report.tunnelInterface == "utun4")
    }

    /// Round 1 (Fable M3): en0 and the utun both own 10.8.0.2. No path verdict may be green (or red) from that.
    @Test func anAddressCollisionMakesTheRunInconclusive() async {
        var f = Self.facts()
        f.tunnelInterface = nil
        let net = Recorder()
        net.owners = [Self.tunnelV4: ["en0", "utun4"]]
        net.v4 = Self.ok(from: Self.tunnelV4, on: "en0")
        let report = await ConnectionSelfTest.run(facts: f, dns: (.ok, Self.resolvers), net: net)
        #expect(report.ipv4 == .unreachable("the tunnel's address is also used by another interface"))
        #expect(report.overall == .inconclusive)
        // Two utuns with the address: no tunnel identity either.
        net.owners = [Self.tunnelV4: ["utun4", "utun7"]]
        let r2 = await ConnectionSelfTest.run(facts: f, dns: (.ok, Self.resolvers), net: net)
        #expect(r2.tunnelInterface == nil && r2.overall != .ok)
    }

    @Test func theLiveNetworkingRefusesAnyOtherURL() async {
        for u in ["https://api.ipify.org/", "https://steiale.github.io/other.txt", "https://example.com/lockplus-updates/probe.txt", "http://steiale.github.io/lockplus-updates/probe.txt"] {
            let r = await LiveSelfTestNetworking().fetchProbe(.v4, url: URL(string: u)!, timeout: .seconds(1))
            #expect(!r.ready && r.error?.hasPrefix("refused") == true, "\(u)")
        }
        #expect(ConnectionSelfTest.probeURL == OnDemandPlan.ownProbeURL)
    }

    /// Opt-in (TEST_RUNNER_LP_LIVE_SELFTEST=1): one real GET per family to the probe host, never part of the Unit run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LP_LIVE_SELFTEST"] == "1", "opt-in: LP_LIVE_SELFTEST=1"))
    func liveProbeFetch() async {
        for family in [IPFamily.v4, .v6] {
            let r = await LiveSelfTestNetworking().fetchProbe(family, url: ConnectionSelfTest.probeURL, timeout: .seconds(8))
            print("LIVE-SELFTEST \(family): \(r)")
            if family == .v4 { #expect(r.ready && r.status == 200 && r.bodyOK && r.localAddress != nil && r.interface != nil) }
        }
    }

    // MARK: HTTP parsing

    @Test func httpParser() {
        func p(_ s: String) -> (status: Int?, bodyOK: Bool, complete: Bool) { ProbeHTTP.parse(Data(s.utf8)) }
        #expect(p("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nok\n") == (200, true, true))
        #expect(p("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nok") == (200, true, false))       // body still arriving
        #expect(p("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nok\n\r\n0\r\n\r\n") == (200, true, true))
        #expect(p("HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n<html>sign in</html>") == (200, false, true))
        #expect(p("HTTP/1.1 302 Found\r\nLocation: http://portal\r\nContent-Length: 0\r\n\r\n") == (302, false, true))
        #expect(p("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nokay").bodyOK == false)
        #expect(p("HTTP/1.1 200 OK\r\nContent-Le").status == nil)
        #expect(p("garbage\r\n\r\n").status == nil)
        #expect(p("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nok\r\n").bodyOK == false)
    }

    // MARK: Wording (D-5)

    static func report(_ overall: SelfTestOverall = .ok) -> SelfTestReport {
        SelfTestReport(profileID: UUID(), at: Date(timeIntervalSince1970: 1_800_000_000), endpoint: "198.51.100.7",
                       ipv4: .throughTunnel(interface: "utun4", source: tunnelV4), ipv6: .blocked, dns: .ok, dnsApplicable: true,
                       dnsServerRoutes: ["10.8.0.1": "utun4"], dnsServers: ["10.8.0.1"], tunnelInterface: "utun4", overall: overall)
    }

    @Test func theExitRowSaysPlainlyThatTheAddressIsNotChecked() throws {
        let rows = Self.report().rows()
        #expect(rows.map(\.id) == [.ipv4, .ipv6, .dns, .exit])
        let exit = try #require(rows.last)
        #expect(exit.result == nil)                                  // informational, no green tick
        #expect(exit.text.contains("isn't checked"))
        #expect(exit.text.contains("198.51.100.7"))
        #expect(exit.text.contains("third-party"))
    }

    @Test func copyResultsLeaveTheServerAddressOut() {
        let text = Self.report().copyText()
        #expect(!text.contains("198.51.100.7"))
        #expect(text.contains("isn't checked"))
        #expect(text.contains("utun4"))
    }

    /// Round 1 (Codex 10): the server is also the DNS server, and a detail names addresses: none of them is copied.
    @Test func copyResultsRedactEveryRowAndDetail() {
        var r = Self.report(.inconclusive)
        r.dns = .mismatch("198.51.100.7 is reached via en0, not the tunnel (utun4)")
        r.ipv4 = .throughTunnel(interface: "utun4", source: Self.tunnelV4)
        r.ipv6 = .unreachable("connect to 2001:db8::9 failed")
        let text = r.copyText()
        #expect(!text.contains("198.51.100.7") && !text.contains(Self.tunnelV4) && !text.contains("2001:db8::9"))
        #expect(text.contains("utun4"))
    }

    /// Round 1 (Codex 9): the headline claims only what the rows proved.
    @Test func theHeadlineFollowsTheRows() {
        var r = Self.report(.ok)
        r.ipv6 = .throughTunnel(interface: "utun4", source: Self.tunnelV6)
        #expect(r.headline == "IPv4, IPv6 and DNS use the tunnel")
        for v6 in [PathVerdict.blocked, .noIPv6Here, .outsideExpected] {
            r.ipv6 = v6
            #expect(r.headline == "Everything this profile sends through the VPN uses the tunnel", "\(v6)")
        }
        var split = Self.report(.ok)
        split.ipv4 = .outsideExpected; split.ipv6 = .outsideExpected; split.dnsApplicable = false
        #expect(split.headline == "Everything this profile sends through the VPN uses the tunnel")
    }

    @Test func inconclusiveIsNeverDrawnAsPass() {
        #expect(Self.report(.inconclusive).overallGlyph == .unknown)
        #expect(Self.report(.ok).overallGlyph == .pass)
        var r = Self.report(.inconclusive)
        r.ipv4 = .unreachable("timed out")
        r.dns = .unknown("a test query didn't complete")
        let rows = r.rows()
        #expect(rows.first { $0.id == .ipv4 }?.result == .unknown)
        #expect(rows.first { $0.id == .dns }?.result == .unknown)
        #expect(rows.first { $0.id == .ipv4 }?.text == "Couldn't reach the test host")
    }

    @Test func theBundleTextNamesTheOutcomeAndNoExitAddress() {
        let text = Self.report().bundleText()
        #expect(text.contains("ipv4: throughTunnel interface=utun4"))
        #expect(text.contains("exit address: not checked"))
        #expect(!text.contains("198.51.100.7"))
    }
}

/// The store's lifecycle: only while connected, one at a time, stale after any status change.
@MainActor @Suite("Connection self-test, store", .serialized, .timeLimit(.minutes(1)))
struct ConnectionSelfTestStoreTests {
    final class Gate: SelfTestNetworking, @unchecked Sendable {
        let inner = ConnectionSelfTestTests.Recorder()
        private struct Hold { var released = false; var k: CheckedContinuation<Void, Never>? }
        private let hold = Mutex(Hold())
        private let blocking: Bool
        init(blocking: Bool = false) { self.blocking = blocking }
        func release() {
            let k = hold.withLock { h -> CheckedContinuation<Void, Never>? in h.released = true; let k = h.k; h.k = nil; return k }
            k?.resume()
        }
        func fetchProbe(_ family: IPFamily, url: URL, timeout: Duration) async -> ProbeFetch {
            inner.record(family, url)
            if blocking, family == .v4 {
                await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                    let now = hold.withLock { h -> Bool in if h.released { return true }; h.k = k; return false }
                    if now { k.resume() }
                }
            }
            return family == .v4 ? inner.v4 : inner.v6
        }
        func interface(forIP ip: String) -> String? { inner.interface(forIP: ip) }
        func routeLookup(forIP ip: String) -> RouteProbe.RouteLookup { inner.routeLookup(forIP: ip) }
        func interfaces(owningAddress ip: String) -> [String] { inner.interfaces(owningAddress: ip) }
        func hasDefaultRoute(_ family: IPFamily, excludingTunnels: Bool) -> Bool { true }
    }

    static let dns = FixtureDNSSystem(scutil: """
        DNS configuration

        resolver #1
          nameserver[0] : 10.8.0.1
          if_index : 23 (utun4)

        DNS configuration (for scoped queries)
        """, global: ["10.8.0.1"])

    @Test func notRunWhileDisconnected() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let net = Gate()
        let store = DiagnosticsStore(system: Self.dns, profiles: h.env.profiles, delay: .seconds(3600), selfTest: net)
        await store.runSelfTest(p.id)
        #expect(store.selfTest == nil && !store.selfTestRunning)
        #expect(net.inner.fetches.isEmpty)                        // nothing was contacted
        store.statusChanged(p.id, .connecting)
        await store.runSelfTest()
        #expect(net.inner.fetches.isEmpty)
        store.statusChanged(p.id, .connected)
        store.statusChanged(p.id, .disconnected)
        await store.runSelfTest(p.id)
        #expect(net.inner.fetches.isEmpty && store.connectedProfileID == nil)
    }

    @Test func nothingRunsOnItsOwnAfterConnected() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let net = Gate()
        let store = DiagnosticsStore(system: Self.dns, profiles: h.env.profiles, delay: .milliseconds(10), selfTest: net)
        store.statusChanged(p.id, .connected)
        try await Task.sleep(for: .milliseconds(200))              // the DNS verifier ran; the self-test must not have
        #expect(net.inner.fetches.isEmpty && store.selfTest == nil)
    }

    /// PLAN-2.0.2 §5.3: "Run All" (⌘R) and the hero's "Run Diagnostics" (both `AppEnvironment.runDiagnostics`, a
    /// button press) run the self-test too; disconnected they contact nothing. The app root wires the bundle.
    @Test func runDiagnosticsRunsTheSelfTestAndTheBundleCarriesIt() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        await h.env.runDiagnostics()
        #expect(h.selfTestNet.fetches.isEmpty && h.env.diagnostics.selfTest == nil)      // disconnected: nothing contacted
        try await h.env.managers.save(ManagerConfiguration(profile: p, onDemand: nil))
        h.env.connection.start()
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        #expect(await eventually { h.env.diagnostics.connectedProfileID == p.id })
        #expect(h.selfTestNet.fetches.isEmpty)                                            // never on its own
        await h.env.runDiagnostics()
        #expect(!h.selfTestNet.fetches.isEmpty && h.selfTestNet.fetches.allSatisfy { $0.1 == OnDemandPlan.ownProbeURL })
        let report = try #require(h.env.diagnostics.selfTest)
        #expect(report.profileID == p.id)
        #expect(await h.env.gatherDiagnostics().selfTest == report.bundleText())
    }

    @Test func runsWhenConnectedAndIsClearedByAnyStatusChange() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let net = Gate()
        let store = DiagnosticsStore(system: Self.dns, profiles: h.env.profiles, delay: .seconds(3600), selfTest: net)
        store.snapshotProvider = { TunnelSnapshot(profileID: p.id, phase: .connected, endpoint: "198.51.100.7:51820", localAddresses: ["10.8.0.2"]) }
        store.statusChanged(p.id, .connected)
        await store.runSelfTest()
        let report = try #require(store.selfTest)
        #expect(report.profileID == p.id)
        #expect(report.endpoint == "198.51.100.7")                 // host only, no port
        #expect(report.ipv4 == .throughTunnel(interface: "utun4", source: "10.8.0.2"))
        #expect(net.inner.fetches.count == 2 && net.inner.fetches.allSatisfy { $0.1 == OnDemandPlan.ownProbeURL })
        store.statusChanged(p.id, .reasserting)
        #expect(store.selfTest == nil && store.connectedProfileID == nil)
        store.statusChanged(p.id, .connected)
        #expect(store.selfTest == nil)
    }

    @Test func oneAtATimeAndCancelledByAStatusChange() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let net = Gate(blocking: true)
        let store = DiagnosticsStore(system: Self.dns, profiles: h.env.profiles, delay: .seconds(3600), selfTest: net)
        store.statusChanged(p.id, .connected)
        let first = Task { await store.runSelfTest() }
        #expect(await eventually { store.selfTestRunning && net.inner.fetches.count >= 1 })
        await store.runSelfTest()                                   // a second press while one runs: ignored, returns at once
        #expect(net.inner.fetches.filter { $0.0 == .v4 }.count == 1)
        store.statusChanged(p.id, .disconnected)                    // the connection changed under the test
        #expect(!store.selfTestRunning)
        net.release()
        await first.value
        #expect(store.selfTest == nil)                              // the late answer is dropped
    }

    @Test func theBundleCarriesTheLastReportOnlyWhenThereIsOne() throws {
        var i = DiagnosticsInputs()
        #expect(!DiagnosticsBundle.files(i, redactor: DiagnosticsBundle.redactor(for: i)).contains { $0.name == "selftest.txt" })
        i.selfTest = ConnectionSelfTestTests.report().bundleText()
        let file = try #require(DiagnosticsBundle.files(i, redactor: DiagnosticsBundle.redactor(for: i)).first { $0.name == "selftest.txt" })
        #expect(file.text.contains("throughTunnel"))
        #expect(!file.text.contains("10.8.0.2"))                    // addresses are hashed like every network fact
    }
}
