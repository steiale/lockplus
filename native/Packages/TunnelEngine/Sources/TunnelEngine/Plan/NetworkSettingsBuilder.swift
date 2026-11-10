import Foundation
import LPModel
import NetworkExtension

/// The Sendable, comparable form of `NEPacketTunnelNetworkSettings` (DESIGN §7.1: every setting flows through
/// `NetworkSettingsBuilder`; `FakeHost` compares these with `==`). `RealProviderHost` turns it into NE objects.
/// It has no field for the settings-level `includeAllNetworks`/`excludeLocalNetworks`/`enforceRoutes`/`exclude*`
/// flags: §10.1 forbids setting them, so the builder cannot.
public struct TunnelSettingsSpec: Sendable, Equatable {
    public struct V4: Sendable, Equatable { public var addresses: [String]; public var subnetMasks: [String]
        public var includedRoutes: [Route4]; public var excludedRoutes: [Route4] }
    public struct V6: Sendable, Equatable { public var addresses: [String]; public var prefixLengths: [Int]
        public var includedRoutes: [Route6]; public var excludedRoutes: [Route6] }
    public struct DNS: Sendable, Equatable {
        public var servers: [String]; public var searchDomains: [String]?; public var matchDomains: [String]
        public var matchDomainsNoSearch: Bool
        public var allowFailover: Bool   // always false (§10.2)
    }
    public var tunnelRemoteAddress: String
    public var ipv4: V4?
    public var ipv6: V6?
    public var dns: DNS?
    public var mtu: Int
    /// The §10.5 `::/0` blackhole is in `ipv6` (diagnostics only).
    public var ipv6Blackhole: Bool
    /// `.split` with no domains fell back to `[""]` (the UI says so, §10.2).
    public var splitFellBackToAll: Bool
}

public enum NetworkSettingsBuilder {
    public static let defaultMTU = 1420

    /// E2E-1: the tunnel's own subnet (OpenVPN `topology subnet`/`net30`, a WireGuard `Address = 10.0.0.2/24`).
    /// NEIPv4Settings' subnet mask does not route it on macOS: without this, a split tunnel can't reach the server's
    /// tunnel address (10.81.0.1 from 10.81.0.2/24) or a DNS server on it, while wg-quick and the OpenVPN 2 client do.
    static func connected4(_ a: [IPv4Assignment], besides inc: [Route4]) -> [Route4] {
        var out: [Route4] = []
        for x in a where (1...31).contains(x.prefixLength) {
            guard let n = IPAddress.network4(x.address, x.prefixLength) else { continue }
            let r = Route4(n, x.prefixLength)
            if !inc.contains(r) && !out.contains(r) { out.append(r) }
        }
        return out
    }

    static func connected6(_ a: [IPv6Assignment], besides inc: [Route6]) -> [Route6] {
        var out: [Route6] = []
        for x in a where (1...127).contains(x.prefixLength) {
            guard let n = IPAddress.network6(x.address, x.prefixLength) else { continue }
            let r = Route6(n, x.prefixLength)
            if !inc.contains(r) && !out.contains(r) { out.append(r) }
        }
        return out
    }

    /// §10.2/§10.5/§9.3/§8.5. Throws `.dnsPlanMissing` for a kill-switch full tunnel without DNS.
    public static func spec(for plan: NetworkPlan, policy: NetworkPolicy, profileID: UUID) throws(LPTunnelError) -> TunnelSettingsSpec {
        let plan = try plan.validated()
        let full = plan.isFullTunnel

        // IPv4
        var v4: TunnelSettingsSpec.V4?
        if !plan.ipv4.isEmpty {
            var inc = plan.includedRoutes4
            if plan.redirectGateway.v4 { inc.insert(Route4("0.0.0.0", 0), at: 0) } else { inc += connected4(plan.ipv4, besides: inc) }
            v4 = .init(addresses: plan.ipv4.map(\.address), subnetMasks: plan.ipv4.map { IPAddress.mask4($0.prefixLength) },
                       includedRoutes: inc, excludedRoutes: plan.excludedRoutes4)
        }   // no v4 address (incl. block-ipv4): no v4 settings, nothing to route

        // IPv6, or the §10.5 blackhole: exactly when isFullTunnel && !hasIPv6 && (killSwitch || blockIPv6WithoutKillSwitch).
        let usableV6 = plan.hasIPv6 && plan.allowIPv6
        let blackhole = full && !usableV6 && (policy.killSwitch || policy.blockIPv6WithoutKillSwitch)
        var v6: TunnelSettingsSpec.V6?
        if usableV6 {
            var inc = plan.includedRoutes6
            if plan.redirectGateway.v6 { inc.insert(Route6("::", 0), at: 0) } else { inc += connected6(plan.ipv6, besides: inc) }
            v6 = .init(addresses: plan.ipv6.map(\.address), prefixLengths: plan.ipv6.map(\.prefixLength),
                       includedRoutes: inc, excludedRoutes: plan.excludedRoutes6)
        } else if blackhole {
            v6 = .init(addresses: [ula(for: profileID)], prefixLengths: [128], includedRoutes: [Route6("::", 0)], excludedRoutes: [])
        }

        // DNS (§10.2)
        var dns: TunnelSettingsSpec.DNS?
        var fellBack = false
        if let d = plan.dns, !d.servers.isEmpty {
            let match: [String]
            var noSearch = false
            if full || policy.dnsMode == .tunnelOnly {
                match = [""]
            } else {
                var seen = Set<String>(); var u: [String] = []
                for x in d.splitDomains + d.searchDomains where seen.insert(x.lowercased()).inserted { u.append(x) }
                if u.isEmpty { match = [""]; fellBack = true } else { match = u }
                noSearch = d.searchDomains.isEmpty && !d.splitDomains.isEmpty
            }
            dns = .init(servers: d.servers, searchDomains: d.searchDomains.isEmpty ? nil : d.searchDomains,
                        matchDomains: match, matchDomainsNoSearch: noSearch, allowFailover: false)
        } else if full && policy.killSwitch {
            throw .of(.dnsPlanMissing)
        }

        return TunnelSettingsSpec(tunnelRemoteAddress: plan.remoteAddress, ipv4: v4, ipv6: v6, dns: dns,
                                  mtu: policy.mtuOverride ?? plan.mtu ?? defaultMTU,
                                  ipv6Blackhole: blackhole && !usableV6, splitFellBackToAll: fellBack)
    }

    /// `fdXX:XXXX:XXXX::1` from the profile UUID (stable per profile, unique local, RFC 4193 shape).
    static func ula(for id: UUID) -> String {
        let u = id.uuid
        return String(format: "fd%02x:%02x%02x:%02x%02x::1", u.0, u.1, u.2, u.3, u.4)
    }

    /// Builds the NE object. Called on the host side only; the result never crosses an actor.
    public static func makeSettings(_ s: TunnelSettingsSpec) -> NEPacketTunnelNetworkSettings {
        let ns = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: s.tunnelRemoteAddress)
        if let v = s.ipv4 {
            let v4 = NEIPv4Settings(addresses: v.addresses, subnetMasks: v.subnetMasks)
            v4.includedRoutes = v.includedRoutes.map { r in
                r.prefixLength == 0 ? NEIPv4Route.default() : NEIPv4Route(destinationAddress: r.destination, subnetMask: IPAddress.mask4(r.prefixLength))
            }
            v4.excludedRoutes = v.excludedRoutes.map { NEIPv4Route(destinationAddress: $0.destination, subnetMask: IPAddress.mask4($0.prefixLength)) }
            ns.ipv4Settings = v4
        }
        if let v = s.ipv6 {
            let v6 = NEIPv6Settings(addresses: v.addresses, networkPrefixLengths: v.prefixLengths.map { NSNumber(value: $0) })
            v6.includedRoutes = v.includedRoutes.map { r in
                r.prefixLength == 0 ? NEIPv6Route.default() : NEIPv6Route(destinationAddress: r.destination, networkPrefixLength: NSNumber(value: r.prefixLength))
            }
            v6.excludedRoutes = v.excludedRoutes.map { NEIPv6Route(destinationAddress: $0.destination, networkPrefixLength: NSNumber(value: $0.prefixLength)) }
            ns.ipv6Settings = v6
        }
        if let d = s.dns {
            let dn = NEDNSSettings(servers: d.servers)
            dn.searchDomains = d.searchDomains
            dn.matchDomains = d.matchDomains
            dn.matchDomainsNoSearch = d.matchDomainsNoSearch
            dn.allowFailover = false
            ns.dnsSettings = dn
        }
        ns.mtu = NSNumber(value: s.mtu)
        return ns
    }
}
