import Darwin
import Foundation
import LPModel

/// The process facts the §7.3 fd rule reads (injectable for tests).
public protocol UtunSystem: Sendable {
    /// Every open fd whose peer is the utun kernel control (`com.apple.net.utun_control`).
    func utunControlFDs() -> [Int32]
    /// `UTUN_OPT_IFNAME` of a utun control socket.
    func interfaceName(of fd: Int32) -> String?
    /// Whether interface `name` carries `address`, IPv4 or IPv6 (`getifaddrs`).
    func interface(_ name: String, hasAddress address: String) -> Bool
}

/// DESIGN §7.3: one selection rule for both engines. Collect ALL utun control fds; if more than one, pick the one whose
/// interface carries the address just applied (IPv4, or IPv6 for an IPv6-only plan), and require that interface to be
/// unique. Upstream's "first match"
/// would pick a lingering dup on a dead interface (S7 `s7fdrule`).
public enum UtunSelector {
    public struct Selection: Sendable, Equatable { public var fd: Int32; public var interface: String; public var candidates: Int }

    public static func select(matching address: String?, system: some UtunSystem) throws(LPTunnelError) -> Selection {
        let fds = system.utunControlFDs()
        guard !fds.isEmpty else { throw .of(.tunDeviceFailed, "no utun fd") }
        let named = fds.map { ($0, system.interfaceName(of: $0) ?? "") }
        if named.count == 1 { return Selection(fd: named[0].0, interface: named[0].1, candidates: 1) }
        guard let address else { throw .of(.tunDeviceFailed, "ambiguous utun (no address)") }
        let matching = named.filter { !$0.1.isEmpty && system.interface($0.1, hasAddress: address) }
        let ifs = Set(matching.map(\.1))
        guard ifs.count == 1, let first = matching.min(by: { $0.0 < $1.0 }) else {
            throw .of(.tunDeviceFailed, "ambiguous utun (\(ifs.count) interfaces)")
        }
        // Several fds on the same interface (NE's plus a live dup) are the same utun device; any of them works, the
        // lowest is taken only for determinism (fd numbers say nothing about which one is NE's).
        return Selection(fd: first.0, interface: first.1, candidates: named.count)
    }
}

/// The real implementation (port of the spike's `lp_utun_fds` / `lp_utun_ifname` / `lp_if_has_ipv4`).
public struct DarwinUtunSystem: UtunSystem {
    public init() {}

    /// `CTLIOCGINFO` = `_IOWR('N', 3, struct ctl_info)`; the macro is not imported into Swift.
    static let CTLIOCGINFO: UInt = 0xC064_4E03
    static let UTUN_OPT_IFNAME: Int32 = 2

    static let controlID: UInt32 = {
        let s = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard s >= 0 else { return 0 }
        defer { close(s) }
        var info = ctl_info()
        withUnsafeMutableBytes(of: &info.ctl_name) { p in
            let name = Array("com.apple.net.utun_control".utf8)
            p.copyBytes(from: name.prefix(p.count - 1))
        }
        return ioctl(s, CTLIOCGINFO, &info) == 0 ? info.ctl_id : 0
    }()

    public func utunControlFDs() -> [Int32] {
        let ctl = Self.controlID
        guard ctl != 0 else { return [] }
        var out: [Int32] = []
        for fd in Int32(0)...1024 where fcntl(fd, F_GETFD) != -1 {
            var addr = sockaddr_ctl()
            var len = socklen_t(MemoryLayout<sockaddr_ctl>.size)
            let ok = withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) == 0 }
            }
            if ok && addr.sc_family == UInt8(AF_SYSTEM) && addr.sc_id == ctl { out.append(fd) }
        }
        return out
    }

    public func interfaceName(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
        var len = socklen_t(buf.count)
        guard getsockopt(fd, SYSPROTO_CONTROL, Self.UTUN_OPT_IFNAME, &buf, &len) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func interface(_ name: String, hasAddress address: String) -> Bool {
        var want4 = in_addr(), want6 = in6_addr()
        let isV4 = inet_pton(AF_INET, address, &want4) == 1
        guard isV4 || inet_pton(AF_INET6, address, &want6) == 1 else { return false }
        let want6Bytes = withUnsafeBytes(of: want6) { Array($0) }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let i = cur {
            defer { cur = i.pointee.ifa_next }
            guard let sa = i.pointee.ifa_addr, String(validatingCString: i.pointee.ifa_name) == name else { continue }
            if isV4, sa.pointee.sa_family == UInt8(AF_INET) {
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                if a == want4.s_addr { return true }
            } else if !isV4, sa.pointee.sa_family == UInt8(AF_INET6) {
                let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) } }
                if a == want6Bytes { return true }
            }
        }
        return false
    }
}
