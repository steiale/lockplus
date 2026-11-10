import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

@Suite struct NetworkSettingsBuilderTests {
    let pid = UUID()

    func plan(full: Bool, v6: Bool = false, dns: DNSPlan? = DNSPlan(servers: ["10.8.0.1"]), mtu: Int? = nil) -> NetworkPlan {
        NetworkPlan(ipv4: [.init("10.8.0.2", 24)], ipv6: v6 ? [.init("fd00::2", 64)] : [],
                    includedRoutes4: [.init("10.20.0.0", 16)], redirectGateway: .init(v4: full, v6: full && v6),
                    dns: dns, mtu: mtu, remoteAddress: "198.51.100.7")
    }

    /// §10.5 table: the blackhole appears exactly when isFullTunnel && !hasIPv6 && (killSwitch || blockIPv6WithoutKillSwitch).
    @Test(arguments: [false, true], [false, true])
    func ipv6BlackholeTable(killSwitch: Bool, blockToggle: Bool) throws {
        for full in [false, true] {
            for v6 in [false, true] {
                var p = NetworkPolicy(killSwitch: killSwitch); p.blockIPv6WithoutKillSwitch = blockToggle
                let s = try NetworkSettingsBuilder.spec(for: plan(full: full, v6: v6), policy: p, profileID: pid)
                let expected = full && !v6 && (killSwitch || blockToggle)
                #expect(s.ipv6Blackhole == expected)
                if expected {
                    #expect(s.ipv6?.includedRoutes == [Route6("::", 0)])
                    #expect(s.ipv6?.prefixLengths == [128])
                    #expect(s.ipv6?.addresses.first?.hasPrefix("fd") == true)
                } else if !v6 {
                    #expect(s.ipv6 == nil)
                }
            }
        }
    }

    @Test func noExcludedRouteToTheServerAndRemoteIsCurrentServer() throws {
        let s = try NetworkSettingsBuilder.spec(for: plan(full: true), policy: .init(killSwitch: true), profileID: pid)
        #expect(s.tunnelRemoteAddress == "198.51.100.7")
        #expect(!(s.ipv4?.excludedRoutes.contains { $0.destination == "198.51.100.7" } ?? false))
        #expect(s.ipv4?.includedRoutes.first == Route4("0.0.0.0", 0))
    }

    /// E2E-1 (LP-macOS-27, ovpn-auth `topology subnet`): the tunnel subnet must be routed in a split tunnel, or the
    /// server's tunnel address and a DNS server on it are unreachable. Full tunnels are covered by the default route.
    @Test func splitTunnelRoutesItsOwnSubnet() throws {
        let split = try NetworkSettingsBuilder.spec(for: plan(full: false, v6: true), policy: .init(killSwitch: false), profileID: pid)
        #expect(split.ipv4?.includedRoutes == [Route4("10.20.0.0", 16), Route4("10.8.0.0", 24)])
        #expect(split.ipv6?.includedRoutes == [Route6("fd00::", 64)])
        let full = try NetworkSettingsBuilder.spec(for: plan(full: true), policy: .init(killSwitch: true), profileID: pid)
        #expect(full.ipv4?.includedRoutes == [Route4("0.0.0.0", 0), Route4("10.20.0.0", 16)])
        // /32 (WireGuard Address) adds nothing; a pushed route equal to the subnet isn't duplicated.
        let wg = NetworkPlan(ipv4: [.init("10.87.0.3", 32)], includedRoutes4: [.init("10.87.0.0", 24)], remoteAddress: "198.51.100.7")
        #expect(try NetworkSettingsBuilder.spec(for: wg, policy: .init(killSwitch: false), profileID: pid).ipv4?.includedRoutes == [Route4("10.87.0.0", 24)])
        let dup = NetworkPlan(ipv4: [.init("10.81.0.2", 24)], includedRoutes4: [.init("10.81.0.0", 24)], remoteAddress: "198.51.100.7")
        #expect(try NetworkSettingsBuilder.spec(for: dup, policy: .init(killSwitch: false), profileID: pid).ipv4?.includedRoutes == [Route4("10.81.0.0", 24)])
        #expect(IPAddress.network4("10.81.0.130", 25) == "10.81.0.128")
        #expect(IPAddress.network6("fd87:5:2::3", 64) == "fd87:5:2::")
    }

    @Test func mtuDefaultsTo1420AndOverrideWins() throws {
        #expect(try NetworkSettingsBuilder.spec(for: plan(full: false), policy: .init(killSwitch: false), profileID: pid).mtu == 1420)
        #expect(try NetworkSettingsBuilder.spec(for: plan(full: false, mtu: 1380), policy: .init(killSwitch: false), profileID: pid).mtu == 1380)
        var p = NetworkPolicy(killSwitch: false); p.mtuOverride = 1280
        #expect(try NetworkSettingsBuilder.spec(for: plan(full: false, mtu: 1380), policy: p, profileID: pid).mtu == 1280)
    }

    /// §10.2 rows.
    @Test func dnsRows() throws {
        let d = DNSPlan(servers: ["10.8.0.1", "10.8.0.2"], searchDomains: ["corp.example"], splitDomains: ["int.example"])
        // full tunnel, any mode: [""]
        var p = NetworkPolicy(killSwitch: false); p.dnsMode = .split
        var s = try NetworkSettingsBuilder.spec(for: plan(full: true, dns: d), policy: p, profileID: pid)
        #expect(s.dns?.matchDomains == [""] && s.dns?.servers == d.servers && s.dns?.allowFailover == false)
        // split, tunnelOnly: [""]
        p.dnsMode = .tunnelOnly
        s = try NetworkSettingsBuilder.spec(for: plan(full: false, dns: d), policy: p, profileID: pid)
        #expect(s.dns?.matchDomains == [""])
        // split, .split: union, search domains kept, noSearch false when both kinds exist
        p.dnsMode = .split
        s = try NetworkSettingsBuilder.spec(for: plan(full: false, dns: d), policy: p, profileID: pid)
        #expect(s.dns?.matchDomains == ["int.example", "corp.example"])
        #expect(s.dns?.searchDomains == ["corp.example"])
        #expect(s.dns?.matchDomainsNoSearch == false)
        // only split domains → noSearch true
        s = try NetworkSettingsBuilder.spec(for: plan(full: false, dns: DNSPlan(servers: ["1.1.1.1"], splitDomains: ["a.example"])), policy: p, profileID: pid)
        #expect(s.dns?.matchDomainsNoSearch == true)
        // empty union → [""] with the fallback flag
        s = try NetworkSettingsBuilder.spec(for: plan(full: false, dns: DNSPlan(servers: ["1.1.1.1"])), policy: p, profileID: pid)
        #expect(s.dns?.matchDomains == [""] && s.splitFellBackToAll)
    }

    @Test func noDNS() throws {
        // non-kill-switch full tunnel: system DNS
        #expect(try NetworkSettingsBuilder.spec(for: plan(full: true, dns: nil), policy: .init(killSwitch: false), profileID: pid).dns == nil)
        // kill-switch split tunnel: nil too
        #expect(try NetworkSettingsBuilder.spec(for: plan(full: false, dns: nil), policy: .init(killSwitch: true), profileID: pid).dns == nil)
        // kill-switch full tunnel: .dnsPlanMissing
        #expect(throws: LPTunnelError.self) {
            try NetworkSettingsBuilder.spec(for: plan(full: true, dns: nil), policy: .init(killSwitch: true), profileID: pid)
        }
        do { _ = try NetworkSettingsBuilder.spec(for: plan(full: true, dns: DNSPlan(servers: [])), policy: .init(killSwitch: true), profileID: pid) }
        catch { #expect(error.code == .dnsPlanMissing) }
    }

    @Test func routeCapAndPrefixChecks() {
        var p = plan(full: false)
        p.includedRoutes4 = (0..<1025).map { Route4("10.\($0 / 256).\($0 % 256).0", 24) }
        #expect(throws: LPTunnelError.self) { try NetworkSettingsBuilder.spec(for: p, policy: .init(killSwitch: false), profileID: pid) }
        p = plan(full: false); p.includedRoutes4 = [Route4("10.0.0.0", 33)]
        #expect(throws: LPTunnelError.self) { try NetworkSettingsBuilder.spec(for: p, policy: .init(killSwitch: false), profileID: pid) }
        p = plan(full: false); p.includedRoutes4 = [Route4("0.0.0.0", 0)]   // only via redirect-gateway
        #expect(throws: LPTunnelError.self) { try NetworkSettingsBuilder.spec(for: p, policy: .init(killSwitch: false), profileID: pid) }
    }

    /// The NE object mirrors the spec and never sets a settings-level kill-switch flag (§10.1: the spec has no field).
    @Test func makesNESettings() throws {
        let s = try NetworkSettingsBuilder.spec(for: plan(full: true), policy: .init(killSwitch: true), profileID: pid)
        let ns = NetworkSettingsBuilder.makeSettings(s)
        #expect(ns.tunnelRemoteAddress == "198.51.100.7")
        #expect(ns.mtu?.intValue == 1420)
        #expect(ns.ipv4Settings?.addresses == ["10.8.0.2"])
        #expect(ns.ipv4Settings?.subnetMasks == ["255.255.255.0"])
        #expect(ns.ipv4Settings?.includedRoutes?.count == 2)
        #expect(ns.dnsSettings?.matchDomains == [""])
        #expect(ns.dnsSettings?.allowFailover == false)
        #expect(ns.ipv6Settings?.includedRoutes?.count == 1)
    }

    @Test func ulaIsStablePerProfile() {
        #expect(NetworkSettingsBuilder.ula(for: pid) == NetworkSettingsBuilder.ula(for: pid))
        #expect(IPAddress.isV6(NetworkSettingsBuilder.ula(for: pid)))
    }

    // MARK: OpenVPN TunBuilder → NetworkPlan (§8.5)

    @Test func ovpnPlanMapping() {
        var t = OVPNTunPlan()
        t.addresses = [.init("10.8.0.6", 24, ipv6: false)]
        t.routes = [.init("10.20.0.0", 16, ipv6: false), .init("fd10::", 64, ipv6: true)]
        t.excludedRoutes = [.init("192.168.0.0", 16, ipv6: false)]
        t.rerouteIPv4 = true
        t.dnsServers = [.init(priority: 5, addresses: ["10.8.0.53:5353"], resolveDomains: ["b.example"]),
                        .init(priority: -1, addresses: ["10.8.0.1"], resolveDomains: ["a.example"])]
        t.searchDomains = ["corp.example"]
        t.allowIPv6 = false
        t.remoteAddress = "203.0.113.9"
        t.mtu = 1400
        let p = OVPNPlanMapper.networkPlan(t)
        #expect(p.dns?.servers == ["10.8.0.1", "10.8.0.53"])     // ascending priority, port stripped
        #expect(p.dns?.splitDomains == ["a.example", "b.example"])
        #expect(p.dns?.searchDomains == ["corp.example"])
        #expect(p.redirectGateway.v4 && !p.redirectGateway.v6)
        #expect(p.includedRoutes4 == [Route4("10.20.0.0", 16)] && p.includedRoutes6 == [Route6("fd10::", 64)])
        #expect(p.excludedRoutes4 == [Route4("192.168.0.0", 16)])
        #expect(!p.allowIPv6 && p.remoteAddress == "203.0.113.9" && p.mtu == 1400)
        // v4-only full tunnel with block-ipv6 → blackhole under the kill switch
        #expect((try? NetworkSettingsBuilder.spec(for: p, policy: .init(killSwitch: true), profileID: pid))?.ipv6Blackhole == true)
    }

    @Test func ovpnNoDNSCallbackMeansNoPlan() {
        var t = OVPNTunPlan(); t.addresses = [.init("10.8.0.6", 24, ipv6: false)]; t.remoteAddress = "203.0.113.9"
        #expect(OVPNPlanMapper.networkPlan(t).dns == nil)
    }
}

/// M4 rule table (§8.5).
@Suite struct ExcludedRouteGuardTests {
    static func plan(full: Bool, ex4: [Route4] = [], ex6: [Route6] = []) -> NetworkPlan {
        NetworkPlan(ipv4: [.init("10.8.0.2", 24)], excludedRoutes4: ex4, excludedRoutes6: ex6,
                    redirectGateway: .init(v4: full), remoteAddress: "198.51.100.7")
    }

    @Test func rules() {
        let none = DeclaredBypassRoutes()
        #expect(throws: LPTunnelError.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex4: [.init("0.0.0.0", 1)]), declared: none) }
        #expect(throws: LPTunnelError.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex4: [.init("10.0.0.0", 8)]), declared: none) }
        #expect(throws: LPTunnelError.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex6: [.init("::", 1)]), declared: none) }
        // /16 and longer pass, as do split tunnels
        #expect(throws: Never.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex4: [.init("192.168.0.0", 16), .init("198.51.100.7", 32)]), declared: none) }
        #expect(throws: Never.self) { try ExcludedRouteGuard.check(Self.plan(full: false, ex4: [.init("0.0.0.0", 1)]), declared: none) }
    }

    /// NEW-2: the IPv6 threshold is /48 (a /47 is rejected); IPv4 stays at /16.
    @Test func ipv6ThresholdIs48() {
        let none = DeclaredBypassRoutes()
        #expect(ExcludedRouteGuard.minPushedPrefix6 == 48 && ExcludedRouteGuard.minPushedPrefix4 == 16)
        #expect(throws: Never.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex6: [.init("2001:db8::", 48)]), declared: none) }
        #expect(throws: Never.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex6: [.init("2001:db8:1:2::", 64)]), declared: none) }
        do throws(LPTunnelError) {
            try ExcludedRouteGuard.check(Self.plan(full: true, ex6: [.init("2001:db8::", 47)]), declared: none)
            Issue.record("/47 accepted")
        } catch {
            #expect(error.code == .pushedOptionRejected && error.detail == "route-ipv6")
        }
        #expect(throws: LPTunnelError.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex6: [.init("2001:db8::", 32)]), declared: none) }
        #expect(throws: LPTunnelError.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex4: [.init("10.0.0.0", 15)]), declared: none) }
        #expect(throws: Never.self) { try ExcludedRouteGuard.check(Self.plan(full: false, ex6: [.init("::", 1)]), declared: none) }
    }

    static func hosts4(_ n: Int) -> [Route4] { (0..<n).map { .init("192.0.2.\($0 + 1)", 32) } }
    static func hosts6(_ n: Int) -> [Route6] { (0..<n).map { .init("2001:db8::\(String($0 + 1, radix: 16))", 128) } }

    /// NEW-2: at most 16 undeclared pushed excluded routes across both families on a full tunnel; the 17th rejects.
    @Test func undeclaredCountCap() {
        let none = DeclaredBypassRoutes()
        #expect(ExcludedRouteGuard.maxUndeclaredPushed == 16)
        #expect(throws: Never.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex4: Self.hosts4(16)), declared: none) }
        #expect(throws: Never.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex4: Self.hosts4(10), ex6: Self.hosts6(6)), declared: none) }
        for (n4, n6) in [(17, 0), (0, 17), (9, 8)] {
            do throws(LPTunnelError) {
                try ExcludedRouteGuard.check(Self.plan(full: true, ex4: Self.hosts4(n4), ex6: Self.hosts6(n6)), declared: none)
                Issue.record("\(n4)+\(n6) undeclared routes accepted")
            } catch {
                #expect(error.code == .pushedOptionRejected && error.detail == "route count")
            }
        }
        // split tunnels are not capped
        #expect(throws: Never.self) { try ExcludedRouteGuard.check(Self.plan(full: false, ex4: Self.hosts4(40)), declared: none) }
    }

    /// NEW-2: declared `net_gateway` routes are exempt from both the size rule and the count cap.
    @Test func declaredRoutesDoNotCount() {
        var text = "client\n"
        for i in 0..<20 { text += "route 198.51.\(i).0 255.255.255.0 net_gateway\n" }
        text += "route-ipv6 2001:db8:ff::/40 net_gateway\n"
        let d = DeclaredBypassRoutes.parse(.text(text))
        let declared4 = (0..<20).map { Route4("198.51.\($0).0", 24) }
        let declared6 = [Route6("2001:db8:ff::", 40)]
        // 20 declared v4 + 1 declared short v6 + 16 undeclared: accepted
        #expect(throws: Never.self) {
            try ExcludedRouteGuard.check(Self.plan(full: true, ex4: declared4 + Self.hosts4(10), ex6: declared6 + Self.hosts6(6)), declared: d)
        }
        // one more undeclared: rejected
        #expect(throws: LPTunnelError.self) {
            try ExcludedRouteGuard.check(Self.plan(full: true, ex4: declared4 + Self.hosts4(11), ex6: declared6 + Self.hosts6(6)), declared: d)
        }
    }

    @Test func declaredRoutesParseAndMatch() throws {
        let p = SecretBytes.text("""
            client
            <key>
            route 0.0.0.0 0.0.0.0 net_gateway
            </key>
            route "10.0.0.0" "255.0.0.0" "net_gateway"
            route 172.16.0.0 255.240.0.0 vpn_gateway
            route-ipv6 "2000::/3" "net_gateway"

            """)
        let d = DeclaredBypassRoutes.parse(p)
        let ok = Self.plan(full: true, ex4: [.init("10.0.0.0", 8)], ex6: [.init("2000::", 3)])
        #expect(throws: Never.self) { try ExcludedRouteGuard.check(ok, declared: d) }
        // inside an inline block (key material) nothing is a declaration; vpn_gateway is not a bypass
        #expect(throws: LPTunnelError.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex4: [.init("0.0.0.0", 1)]), declared: d) }
        #expect(throws: LPTunnelError.self) { try ExcludedRouteGuard.check(Self.plan(full: true, ex4: [.init("172.16.0.0", 12)]), declared: d) }
    }
}
