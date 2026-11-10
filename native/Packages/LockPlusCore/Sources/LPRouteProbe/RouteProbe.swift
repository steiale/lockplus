import Darwin
import Foundation
import LPParsing
import os
import Synchronization

/// RouteProbe (DESIGN §9.3, D73-7): compares an endpoint's route interface with the default route's, via Darwin
/// PF_ROUTE `RTM_GET` (no new dependency). NE scopes the extension's own sockets to the PRIMARY interface, so a server
/// routed via another interface (bridge100, a second NIC, …) is unreachable from the tunnel.
///
/// Used by the app at import (a warning, never a rejection) and by the extension in `starting` (logged; maps a later
/// `.connectTimeout`/`.peerUnreachable` to `.endpointInterfaceUnusable`). Blocking calls (getaddrinfo, the routing
/// socket) run on a GCD utility queue, never on a cooperative-pool thread.
public struct RouteProbe: EndpointRouteProbing {
    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "routeprobe")
    /// Concurrent: one stuck `getaddrinfo` must not queue the other endpoints behind it.
    private static let queue = DispatchQueue(label: "io.github.steiale.lockplus.routeprobe", qos: .utility, attributes: .concurrent)
    /// Per-endpoint budget for resolution plus the route lookups; past it the endpoint is "unknown", never a finding.
    static let endpointDeadline: DispatchTimeInterval = .seconds(3)

    public init() {}

    public func nonPrimaryInterface(for endpoint: ImportEndpoint) async -> String? {
        let host = endpoint.host
        let port = endpoint.port
        return await Self.race(deadline: Self.endpointDeadline) { @Sendable in Self.probe(host: host, port: port) }
    }

    /// Runs `work` on the concurrent probe queue and returns its result, or nil once `deadline` passes or the calling
    /// task is canceled. A late `work` result is dropped (its thread frees itself when `getaddrinfo` returns).
    static func race(deadline: DispatchTimeInterval, _ work: @escaping @Sendable () -> String?) async -> String? {
        let gate = Gate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
                gate.attach(k)
                queue.async { @Sendable in gate.finish(work()) }
                queue.asyncAfter(deadline: .now() + deadline) { @Sendable in gate.finish(nil) }
            }
        } onCancel: { gate.finish(nil) }
    }

    /// Resumes its continuation exactly once; `finish` may run before `attach` (early cancellation).
    private final class Gate: Sendable {
        private enum State { case idle, pending(CheckedContinuation<String?, Never>), done }
        private let state = Mutex<State>(.idle)

        func attach(_ k: CheckedContinuation<String?, Never>) {
            let early = state.withLock { s -> Bool in
                if case .done = s { return true }
                s = .pending(k)
                return false
            }
            if early { k.resume(returning: nil) }
        }

        func finish(_ value: String?) {
            let k: CheckedContinuation<String?, Never>? = state.withLock { s in
                defer { s = .done }
                if case .pending(let k) = s { return k }
                return nil
            }
            k?.resume(returning: value)
        }
    }

    /// For the extension's start-time check (TunnelController, on its actor): IP literals only — no DNS, never
    /// blocks on the network; one short RTM_GET per address plus one per family for the default route.
    /// Returns the first non-primary interface (BSD name), or nil when every address uses the primary interface,
    /// is the Mac's own address (lo0), is not an IP literal, or no default route exists.
    public static func nonPrimaryInterface(forIPs ips: [String]) -> String? {
        firstNonPrimary(ips.flatMap { resolve(host: $0, port: "0", numericOnly: true) })
    }

    /// Synchronous core. nil = primary, or unknown (unresolvable, no default route): the topology may differ later.
    static func probe(host: String, port: String) -> String? {
        firstNonPrimary(resolve(host: host, port: port))
    }

    private static func firstNonPrimary(_ addrs: [sockaddr_storage]) -> String? {
        for addr in addrs {
            let family = Int32(addr.ss_family)
            guard let dst = interfaceIndex(to: addr), let def = defaultInterfaceIndex(family: family) else { continue }
            if dst == def { continue }
            let name = interfaceName(dst)
            if name == "lo0" { continue }                  // the Mac's own address: reachable, not a finding
            return name
        }
        return nil
    }

    // MARK: Resolution (all results, v4 first, deduplicated; §9.3)

    static func resolve(host: String, port: String, numericOnly: Bool = false) -> [sockaddr_storage] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = numericOnly ? (AI_NUMERICHOST | AI_NUMERICSERV) : AI_ADDRCONFIG
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var v4: [sockaddr_storage] = [], v6: [sockaddr_storage] = []
        var seen = Set<Data>()
        for p in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let sa = p.pointee.ai_addr else { continue }
            var ss = sockaddr_storage()
            withUnsafeMutableBytes(of: &ss) { $0.copyMemory(from: UnsafeRawBufferPointer(start: sa, count: Int(p.pointee.ai_addrlen))) }
            let key = withUnsafeBytes(of: &ss) { Data($0.prefix(Int(sa.pointee.sa_len))) }
            guard seen.insert(key).inserted else { continue }
            if sa.pointee.sa_family == sa_family_t(AF_INET) { v4.append(ss) } else if sa.pointee.sa_family == sa_family_t(AF_INET6) { v6.append(ss) }
        }
        return v4 + v6
    }

    // MARK: PF_ROUTE

    static func defaultInterfaceIndex(family: Int32) -> UInt16? {
        var ss = sockaddr_storage()
        if family == AF_INET {
            withUnsafeMutableBytes(of: &ss) { b in
                b.storeBytes(of: UInt8(MemoryLayout<sockaddr_in>.size), toByteOffset: 0, as: UInt8.self)
                b.storeBytes(of: UInt8(AF_INET), toByteOffset: 1, as: UInt8.self)
            }
        } else {
            withUnsafeMutableBytes(of: &ss) { b in
                b.storeBytes(of: UInt8(MemoryLayout<sockaddr_in6>.size), toByteOffset: 0, as: UInt8.self)
                b.storeBytes(of: UInt8(AF_INET6), toByteOffset: 1, as: UInt8.self)
            }
        }
        return interfaceIndex(to: ss)
    }

    /// `RTM_GET` for one destination; returns the outgoing interface index of the matched route.
    static func interfaceIndex(to dst: sockaddr_storage) -> UInt16? {
        let fd = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dstCopy = dst
        let saLen = Int(withUnsafeBytes(of: &dstCopy) { $0[0] })
        guard saLen > 0 else { return nil }
        let padded = (saLen + 3) & ~3                       // ROUNDUP to 4 bytes (32-bit long alignment in route msgs)
        let hdr = MemoryLayout<rt_msghdr>.size
        var buf = [UInt8](repeating: 0, count: 2048)
        let seq = Int32.random(in: 1..<Int32.max)
        let pid = getpid()
        var h = rt_msghdr()
        h.rtm_msglen = UInt16(hdr + padded)
        h.rtm_version = UInt8(RTM_VERSION)
        h.rtm_type = UInt8(RTM_GET)
        h.rtm_addrs = RTA_DST
        h.rtm_flags = RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC
        h.rtm_seq = seq
        h.rtm_pid = pid
        buf.withUnsafeMutableBytes { b in
            b.storeBytes(of: h, as: rt_msghdr.self)
            withUnsafeBytes(of: &dstCopy) { s in
                UnsafeMutableRawBufferPointer(rebasing: b[hdr..<(hdr + saLen)]).copyMemory(from: UnsafeRawBufferPointer(rebasing: s[0..<saLen]))
            }
        }
        let msgLen = hdr + padded
        guard write(fd, buf, msgLen) == msgLen else { return nil }
        for _ in 0..<16 {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n >= hdr else { return nil }
            let r = buf.withUnsafeBytes { $0.load(as: rt_msghdr.self) }
            guard r.rtm_seq == seq, r.rtm_pid == pid, r.rtm_type == UInt8(RTM_GET) else { continue }
            guard r.rtm_errno == 0 else { return nil }
            return r.rtm_index == 0 ? nil : r.rtm_index
        }
        return nil
    }

    static func interfaceName(_ index: UInt16) -> String {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return "if\(index)" }
        return String(cString: name)
    }
}
