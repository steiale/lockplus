import Foundation
import LPModel

/// The `net_gateway` routes a profile itself declares (`route NET [MASK] net_gateway …`,
/// `route-ipv6 NET/LEN net_gateway …`): the only excluded routes a full tunnel accepts at any size (review M4, §8.5).
/// Parsed from the canonical payload without materialising it: only directive lines that start with `route` are
/// decoded, and inline blocks (`<tag>` … `</tag>`, which hold keys) are skipped.
public struct DeclaredBypassRoutes: Sendable, Equatable {
    struct Net4: Hashable { var network: UInt32; var prefix: Int }
    struct Net6: Hashable { var network: [UInt8]; var prefix: Int }
    var v4: Set<Net4> = []
    var v6: Set<Net6> = []
    public init() {}

    public static func parse(_ payload: SecretBytes) -> DeclaredBypassRoutes {
        var out = DeclaredBypassRoutes()
        payload.withUnsafeBytes { b in
            var inBlock: String?
            var start = 0
            for i in 0...b.count where i == b.count || b[i] == 0x0A {
                defer { start = i + 1 }
                guard i > start else { continue }
                let line = UnsafeRawBufferPointer(rebasing: b[start..<i])
                if let tag = inBlock {
                    // Only the closing tag is decoded inside a block.
                    if line.count <= 64, String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces) == "</\(tag)>" {
                        inBlock = nil
                    }
                    continue
                }
                if line.first == UInt8(ascii: "<") {
                    let t = String(decoding: line.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.hasSuffix(">"), !t.hasPrefix("</") { inBlock = String(t.dropFirst().dropLast()) }
                    continue
                }
                guard line.count <= 512, line.starts(with: Array("route".utf8)) else { continue }
                out.add(String(decoding: line, as: UTF8.self))
            }
        }
        return out
    }

    /// Canonical text quotes arguments (`route "0.0.0.0" "128.0.0.0" "net_gateway"`); plain text works too.
    mutating func add(_ line: String) {
        let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        guard let d = t.first else { return }
        switch d {
        case "route":
            // route NET [MASK] [GATEWAY] [METRIC]
            guard t.count >= 4, t[3] == "net_gateway", let net = Self.v4(t[1]), let mask = Self.v4(t[2]),
                  let prefix = Self.prefix(mask) else { return }
            v4.insert(Net4(network: net & mask, prefix: prefix))
        case "route-ipv6":
            // route-ipv6 NET/LEN [GATEWAY] [METRIC]
            guard t.count >= 3, t[2] == "net_gateway" else { return }
            let parts = t[1].split(separator: "/")
            guard parts.count == 2, let len = Int(parts[1]), (0...128).contains(len), let net = Self.v6(String(parts[0])) else { return }
            v6.insert(Net6(network: Self.mask6(net, len), prefix: len))
        default:
            return
        }
    }

    func contains(_ r: Route4) -> Bool {
        guard let a = Self.v4(r.destination) else { return false }
        let m = Self.mask4(r.prefixLength)
        return v4.contains(Net4(network: a & m, prefix: r.prefixLength))
    }

    func contains(_ r: Route6) -> Bool {
        guard let a = Self.v6(r.destination) else { return false }
        return v6.contains(Net6(network: Self.mask6(a, r.prefixLength), prefix: r.prefixLength))
    }

    static func v4(_ s: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    static func v6(_ s: String) -> [UInt8]? {
        var a = in6_addr()
        guard inet_pton(AF_INET6, s, &a) == 1 else { return nil }
        return withUnsafeBytes(of: a) { Array($0) }
    }

    static func mask4(_ prefix: Int) -> UInt32 { prefix <= 0 ? 0 : (prefix >= 32 ? ~0 : ~UInt32(0) << UInt32(32 - prefix)) }

    /// A contiguous netmask → its prefix length; nil for a non-contiguous mask.
    static func prefix(_ mask: UInt32) -> Int? {
        let p = mask.leadingZeroBitCount == 0 ? (~mask).leadingZeroBitCount : 0
        return mask4(p) == mask ? p : nil
    }

    static func mask6(_ a: [UInt8], _ prefix: Int) -> [UInt8] {
        a.enumerated().map { i, byte in
            let bits = max(0, min(8, prefix - i * 8))
            return bits == 8 ? byte : byte & UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
        }
    }
}

/// Review M4 (§8.5): a server-pushed excluded route sends that traffic outside the tunnel, so `route 0.0.0.0 128.0.0.0
/// net_gateway` + `128.0.0.0/1` would bypass a "Protected" full tunnel entirely (kill switch off). Rule:
/// - an excluded route the profile itself declares as `net_gateway` is accepted at any size and is not counted;
/// - otherwise, on a full tunnel, an excluded route shorter than /16 (IPv4) or /48 (IPv6) is rejected with
///   `.pushedOptionRejected` (detail "route"/"route-ipv6"); longer ones (a LAN, the server's host route) pass;
/// - and at most `maxUndeclaredPushed` (16) such undeclared excluded routes, IPv4 and IPv6 together, are accepted on a
///   full tunnel: many small exclusions add up to a bypass too (NEW-2, decision (a)); more → `.pushedOptionRejected`
///   (detail "route count");
/// - split tunnels are unaffected (an exclusion only narrows what the profile already routes).
public enum ExcludedRouteGuard {
    public static let minPushedPrefix4 = 16
    public static let minPushedPrefix6 = 48
    public static let maxUndeclaredPushed = 16

    public static func check(_ plan: NetworkPlan, declared: DeclaredBypassRoutes) throws(LPTunnelError) {
        guard plan.isFullTunnel else { return }
        var undeclared = 0
        for r in plan.excludedRoutes4 where !declared.contains(r) {
            if r.prefixLength < minPushedPrefix4 { throw .of(.pushedOptionRejected, "route") }
            undeclared += 1
        }
        for r in plan.excludedRoutes6 where !declared.contains(r) {
            if r.prefixLength < minPushedPrefix6 { throw .of(.pushedOptionRejected, "route-ipv6") }
            undeclared += 1
        }
        if undeclared > maxUndeclaredPushed { throw .of(.pushedOptionRejected, "route count") }
    }
}
