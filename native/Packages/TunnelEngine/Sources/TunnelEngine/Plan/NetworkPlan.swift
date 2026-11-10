import Foundation
import LPModel

/// DESIGN §8.5: the Sendable description of what an engine wants applied. Both engines produce one; the
/// controller turns it into a `TunnelSettingsSpec` with `NetworkSettingsBuilder` (§10).
public struct IPv4Assignment: Sendable, Equatable, Hashable { public var address: String; public var prefixLength: Int
    public init(_ address: String, _ prefixLength: Int) { self.address = address; self.prefixLength = prefixLength } }
public struct IPv6Assignment: Sendable, Equatable, Hashable { public var address: String; public var prefixLength: Int
    public init(_ address: String, _ prefixLength: Int) { self.address = address; self.prefixLength = prefixLength } }
public struct Route4: Sendable, Equatable, Hashable { public var destination: String; public var prefixLength: Int
    public init(_ destination: String, _ prefixLength: Int) { self.destination = destination; self.prefixLength = prefixLength } }
public struct Route6: Sendable, Equatable, Hashable { public var destination: String; public var prefixLength: Int
    public init(_ destination: String, _ prefixLength: Int) { self.destination = destination; self.prefixLength = prefixLength } }

/// Which families openvpn3's `redirect-gateway` reroutes. Its flags (block-local, bypass-dhcp, …) are deliberately
/// not carried: LAN access and the server route are the §10 policy's and NE's (review M4).
public struct RedirectGateway: Sendable, Equatable {
    public var v4: Bool
    public var v6: Bool
    public init(v4: Bool = false, v6: Bool = false) { self.v4 = v4; self.v6 = v6 }
}

public struct DNSPlan: Sendable, Equatable {
    public var servers: [String]
    public var searchDomains: [String]
    public var splitDomains: [String]
    public init(servers: [String], searchDomains: [String] = [], splitDomains: [String] = []) {
        self.servers = servers; self.searchDomains = searchDomains; self.splitDomains = splitDomains
    }
}

public struct NetworkPlan: Sendable, Equatable {
    public var ipv4: [IPv4Assignment]
    public var ipv6: [IPv6Assignment]
    public var includedRoutes4: [Route4]
    public var excludedRoutes4: [Route4]
    public var includedRoutes6: [Route6]
    public var excludedRoutes6: [Route6]
    public var redirectGateway: RedirectGateway
    public var allowIPv4: Bool
    public var allowIPv6: Bool
    public var dns: DNSPlan?
    public var mtu: Int?
    public var remoteAddress: String

    public init(ipv4: [IPv4Assignment] = [], ipv6: [IPv6Assignment] = [], includedRoutes4: [Route4] = [],
                excludedRoutes4: [Route4] = [], includedRoutes6: [Route6] = [], excludedRoutes6: [Route6] = [],
                redirectGateway: RedirectGateway = .init(), allowIPv4: Bool = true, allowIPv6: Bool = true,
                dns: DNSPlan? = nil, mtu: Int? = nil, remoteAddress: String) {
        self.ipv4 = ipv4; self.ipv6 = ipv6; self.includedRoutes4 = includedRoutes4; self.excludedRoutes4 = excludedRoutes4
        self.includedRoutes6 = includedRoutes6; self.excludedRoutes6 = excludedRoutes6; self.redirectGateway = redirectGateway
        self.allowIPv4 = allowIPv4; self.allowIPv6 = allowIPv6; self.dns = dns; self.mtu = mtu; self.remoteAddress = remoteAddress
    }

    public var isFullTunnel: Bool { redirectGateway.v4 || redirectGateway.v6 }
    public var hasIPv6: Bool { !ipv6.isEmpty }
    /// The address the §7.3 fd rule matches (`getifaddrs`): the first IPv4, else the first IPv6 (T17: IPv6-only plans).
    public var primaryAddress: String? { ipv4.first?.address ?? ipv6.first?.address }

    /// All routes, any origin. Pushed excluded routes on a full tunnel have their own, much lower cap
    /// (`ExcludedRouteGuard.maxUndeclaredPushed`, NEW-2).
    public static let maxRoutes = 1024

    /// §8.5 caps and re-checks: ≤ 1024 routes, prefix lengths in range, addresses parse, remote is an IP literal.
    public func validated() throws(LPTunnelError) -> NetworkPlan {
        let routeCount = includedRoutes4.count + excludedRoutes4.count + includedRoutes6.count + excludedRoutes6.count
        guard routeCount <= Self.maxRoutes else { throw .of(.networkSettingsFailed, "route cap") }
        guard IPAddress.isV4(remoteAddress) || IPAddress.isV6(remoteAddress) else { throw .of(.networkSettingsFailed, "remote") }
        for a in ipv4 where !IPAddress.isV4(a.address) || !(1...32).contains(a.prefixLength) { throw .of(.networkSettingsFailed, "ipv4") }
        for a in ipv6 where !IPAddress.isV6(a.address) || !(1...128).contains(a.prefixLength) { throw .of(.networkSettingsFailed, "ipv6") }
        // Prefix length < 1 is only honoured via redirect-gateway (§8.5).
        for r in includedRoutes4 + excludedRoutes4 where !IPAddress.isV4(r.destination) || !(1...32).contains(r.prefixLength) {
            throw .of(.networkSettingsFailed, "route4")
        }
        for r in includedRoutes6 + excludedRoutes6 where !IPAddress.isV6(r.destination) || !(1...128).contains(r.prefixLength) {
            throw .of(.networkSettingsFailed, "route6")
        }
        if let m = mtu, !(576...65535).contains(m) { throw .of(.networkSettingsFailed, "mtu") }
        return self
    }
}

enum IPAddress {
    static func isV4(_ s: String) -> Bool { var a = in_addr(); return inet_pton(AF_INET, s, &a) == 1 }
    static func isV6(_ s: String) -> Bool { var a = in6_addr(); return inet_pton(AF_INET6, s, &a) == 1 }

    /// The network of `address/prefix` ("10.81.0.2", 24 → "10.81.0.0"); nil for a malformed address.
    static func network4(_ address: String, _ prefix: Int) -> String? {
        var a = in_addr()
        guard inet_pton(AF_INET, address, &a) == 1 else { return nil }
        let h = UInt32(bigEndian: a.s_addr)
        let m: UInt32 = prefix <= 0 ? 0 : (prefix >= 32 ? ~0 : ~UInt32(0) << UInt32(32 - prefix))
        let n = h & m
        return "\(n >> 24 & 255).\(n >> 16 & 255).\(n >> 8 & 255).\(n & 255)"
    }

    /// The network of `address/prefix` for IPv6, in canonical text form; nil for a malformed address.
    static func network6(_ address: String, _ prefix: Int) -> String? {
        var a = in6_addr()
        guard inet_pton(AF_INET6, address, &a) == 1 else { return nil }
        var bytes = withUnsafeBytes(of: &a) { Array($0) }
        for i in 0..<16 {
            let keep = max(0, min(8, prefix - i * 8))
            bytes[i] &= keep == 8 ? 0xFF : UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
        }
        var out = in6_addr()
        withUnsafeMutableBytes(of: &out) { $0.copyBytes(from: bytes) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &out, &buf, socklen_t(buf.count)) != nil else { return nil }
        return String(cString: buf)
    }

    static func mask4(_ prefix: Int) -> String {
        let m: UInt32 = prefix <= 0 ? 0 : (prefix >= 32 ? ~0 : ~UInt32(0) << UInt32(32 - prefix))
        return "\(m >> 24 & 255).\(m >> 16 & 255).\(m >> 8 & 255).\(m & 255)"
    }

    /// "host:port", "[v6]:port" → (host, port); nil when malformed.
    static func splitHostPort(_ s: String) -> (host: String, port: UInt16)? {
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()), p > 0 else { return nil }
            return (host, p)
        }
        guard let c = s.lastIndex(of: ":"), let p = UInt16(s[s.index(after: c)...]), p > 0 else { return nil }
        let host = String(s[..<c])
        guard !host.isEmpty, !host.contains(":") else { return nil }
        return (host, p)
    }

    static func joinHostPort(_ host: String, _ port: UInt16) -> String {
        isV6(host) ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
