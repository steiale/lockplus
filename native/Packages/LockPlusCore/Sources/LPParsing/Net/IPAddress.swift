import Foundation
import LPModel

/// An IP address literal, parsed without the Network framework (LockPlusCore is Foundation-only, §2.2).
/// IPv4 follows Go `net.ParseIP` (dotted quad, no leading zeros); IPv6 uses `inet_pton`, so zones (`%en0`) and
/// trailing garbage are rejected.
public enum IPAddress: Sendable, Equatable, Hashable {
    case v4([UInt8])
    case v6([UInt8])

    public var bitCount: Int {
        switch self {
        case .v4: 32
        case .v6: 128
        }
    }

    public var bytes: [UInt8] {
        switch self {
        case .v4(let b), .v6(let b): b
        }
    }

    public static func parse(_ s: String) -> IPAddress? {
        if let v4 = parseV4(s) { return .v4(v4) }
        guard s.contains(":"), !s.contains("%"), s.utf8.count <= 45 else { return nil }
        var addr = in6_addr()
        let ok = s.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
        guard ok else { return nil }
        return .v6(withUnsafeBytes(of: &addr) { Array($0) })
    }

    static func parseV4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.utf8.count <= 3, p.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            if p.utf8.count > 1 && p.hasPrefix("0") { return nil }
            guard let v = UInt16(p), v <= 255 else { return nil }
            out.append(UInt8(v))
        }
        return out
    }

    /// Canonical text form (inet_ntop).
    public var text: String {
        switch self {
        case .v4(let b):
            return b.map(String.init).joined(separator: ".")
        case .v6(let b):
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: b) }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}

/// An IP prefix ("10.0.0.0/8"). Prefix lengths above 32/128 are rejected, never clamped (§9.1).
public struct IPPrefix: Sendable, Equatable, Hashable {
    public var address: IPAddress
    public var length: Int

    public enum ParseError: Error, Equatable { case invalid, prefixTooLong }

    public static func parse(_ s: String) throws(ParseError) -> IPPrefix {
        let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let ip = IPAddress.parse(String(parts[0])) else { throw .invalid }
        let lp = parts[1]
        guard !lp.isEmpty, lp.utf8.count <= 3, lp.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(lp) else {
            throw .invalid
        }
        guard n <= ip.bitCount else { throw .prefixTooLong }
        return IPPrefix(address: ip, length: n)
    }

    /// The network address (host bits cleared).
    public var masked: IPPrefix {
        var b = address.bytes
        for i in 0..<b.count {
            let bitStart = i * 8
            if bitStart >= length {
                b[i] = 0
            } else if bitStart + 8 > length {
                let keep = length - bitStart
                b[i] &= UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
            }
        }
        let a: IPAddress = (address.bitCount == 32) ? .v4(b) : .v6(b)
        return IPPrefix(address: a, length: length)
    }

    public var hasHostBits: Bool { masked.address != address }
    public var text: String { "\(address.text)/\(length)" }
}

/// Go `net.SplitHostPort`: "host:port" or "[v6]:port"; a bare host with several colons is refused.
public enum HostPort {
    public static func split(_ s: String) -> (host: String, port: String)? {
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            let port = String(rest.dropFirst())
            guard !port.contains(":"), !port.contains("["), !port.contains("]"), !host.contains("[") else { return nil }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon])
        let port = String(s[s.index(after: colon)...])
        if host.contains(":") || host.contains("[") || host.contains("]") || port.contains("[") || port.contains("]") { return nil }
        return (host, port)
    }
}

/// RFC 1035 hostname (single label or FQDN), the Go `hostnameRegex`:
/// `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$`
public enum Hostname {
    public static func isValid(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for label in s.split(separator: ".", omittingEmptySubsequences: false) {
            let b = Array(label.utf8)
            guard (1...63).contains(b.count) else { return false }
            func alnum(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
            guard alnum(b[0]), alnum(b[b.count - 1]), b.allSatisfy({ alnum($0) || $0 == 0x2D }) else { return false }
        }
        return true
    }
}
