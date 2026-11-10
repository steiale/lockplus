import Foundation
import LPModel

/// The libwg-go bridge as TunnelEngine sees it (DESIGN §9.2 W3–W6, W10). The LockPlusTunnel target implements it over
/// WireGuardKitGo's C exports (libwg-go); this package never links Go. Every call is made from the adapter's serial `workQueue`
/// (§9.2 Go entry rules), never from the controller actor or the cooperative pool.
public protocol WireGuardBackend: Sendable {
    /// `wgTurnOn(uapi, tunFD)` (W3): Go `dup()`s the fd; returns a handle ≥ 0 or < 0 on error.
    func turnOn(uapi: SecretBytes, tunFD: Int32) -> Int32
    /// `wgTurnOnPF(uapi, socketFD, mtu)` (W10): a `tun.Device` over a socketpair end with utun framing. Go owns `socketFD`.
    func turnOnPacketFlow(uapi: SecretBytes, socketFD: Int32, mtu: Int32) -> Int32
    /// `wgTurnOff`: closes only Go's dup and its route socket.
    func turnOff(_ handle: Int32)
    /// `wgSetEndpoint(h, pubHex, "ip:port")` (W4): `update_only=true`, never `replace_peers`.
    func setEndpoint(_ handle: Int32, publicKeyHex: String, endpoint: String) -> Int32
    /// `wgSendHandshake` (W4): 1 sent, 0 rate-limited, < 0 error; `sentNs` wall clock.
    func sendHandshake(_ handle: Int32) -> (result: Int32, sentNs: Int64)
    /// `wgGetStats` (W5) text: per peer `public_key`, `endpoint`, `last_handshake_time_sec/nsec`, `rx_bytes`,
    /// `tx_bytes`; no keys. The implementation `free()`s Go's C string.
    func stats(_ handle: Int32) -> String?
    /// `wgIsClosed` (W6).
    func isClosed(_ handle: Int32) -> Bool
    /// `wgBumpSockets`.
    func bumpSockets(_ handle: Int32)
}

/// What the adapter needs from a parsed wg-quick profile. Produced by LPParsing's `WGConfig` (§9.1: the only parser),
/// injected by the Tunnel target; keys are raw 32-byte values in `SecretBytes` / `Data`.
public struct WGSessionConfig: Sendable {
    public struct Peer: Sendable {
        public var publicKey: Data                // 32 bytes
        public var presharedKey: SecretBytes?     // 32 bytes
        public var endpointHost: String?
        public var endpointPort: UInt16?
        public var allowedIPs: [String]           // CIDR, normalized
        public var persistentKeepalive: UInt16?
        public init(publicKey: Data, presharedKey: SecretBytes? = nil, endpointHost: String? = nil, endpointPort: UInt16? = nil,
                    allowedIPs: [String], persistentKeepalive: UInt16? = nil) {
            self.publicKey = publicKey; self.presharedKey = presharedKey; self.endpointHost = endpointHost
            self.endpointPort = endpointPort; self.allowedIPs = allowedIPs; self.persistentKeepalive = persistentKeepalive
        }
    }
    public var privateKey: SecretBytes
    public var listenPort: UInt16?
    public var addresses: [String]                // CIDR
    public var dnsServers: [String]
    public var searchDomains: [String]
    public var mtu: Int?
    public var peers: [Peer]
    public init(privateKey: SecretBytes, listenPort: UInt16? = nil, addresses: [String], dnsServers: [String] = [],
                searchDomains: [String] = [], mtu: Int? = nil, peers: [Peer]) {
        self.privateKey = privateKey; self.listenPort = listenPort; self.addresses = addresses; self.dnsServers = dnsServers
        self.searchDomains = searchDomains; self.mtu = mtu; self.peers = peers
    }
}

/// Parses the canonical payload into a session config (LPParsing in production).
public protocol WGConfigParser: Sendable {
    func parse(_ payload: SecretBytes) throws(LPTunnelError) -> WGSessionConfig
}

/// §9.3 resolution: `getaddrinfo(AF_UNSPEC, SOCK_DGRAM, AI_ADDRCONFIG)`, all results, v4 first, de-duplicated.
public protocol EndpointResolver: Sendable {
    func resolve(host: String) async -> [String]
}

public struct GetAddrInfoResolver: EndpointResolver {
    public init() {}
    public func resolve(host: String) async -> [String] {
        if IPAddress.isV4(host) || IPAddress.isV6(host) { return [host] }
        return await withCheckedContinuation { (k: CheckedContinuation<[String], Never>) in
            DispatchQueue(label: "lockplus.resolve").async { @Sendable in k.resume(returning: Self.lookup(host)) }
        }
    }
    static func lookup(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }
        var v4: [String] = [], v6: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let a = cur {
            defer { cur = a.pointee.ai_next }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard let sa = a.pointee.ai_addr,
                  getnameinfo(sa, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let s = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if a.pointee.ai_family == AF_INET { if !v4.contains(s) { v4.append(s) } } else if !v6.contains(s) { v6.append(s) }
        }
        return v4 + v6
    }
}

/// UAPI text (wireguard-go `IpcSet`) built straight into `SecretBytes`: the hex private/preshared keys never live in a
/// `String` or a growable buffer. Two passes over the same emitter: the first counts, the second writes into the
/// exactly-sized `SecretBytes` (review nit: no reallocation leaving unzeroed copies of the hex keys behind).
enum WGUAPI {
    static func build(_ c: WGSessionConfig, endpoints: [Int: String]) -> SecretBytes {
        func emit(_ put: (UInt8) -> Void) {
            func line(_ s: String) { for x in s.utf8 { put(x) }; put(0x0A) }
            func hexLine(_ key: String, _ secret: SecretBytes) {
                for x in key.utf8 { put(x) }
                put(UInt8(ascii: "="))
                secret.withUnsafeBytes { b in for x in b { put(hexDigit(x >> 4)); put(hexDigit(x & 0xF)) } }
                put(0x0A)
            }
            hexLine("private_key", c.privateKey)
            if let p = c.listenPort { line("listen_port=\(p)") }
            line("replace_peers=true")
            for (i, p) in c.peers.enumerated() {
                line("public_key=\(hex(p.publicKey))")
                if let psk = p.presharedKey { hexLine("preshared_key", psk) }
                if let ep = endpoints[i] { line("endpoint=\(ep)") }
                if let k = p.persistentKeepalive { line("persistent_keepalive_interval=\(k)") }
                line("replace_allowed_ips=true")
                for a in p.allowedIPs { line("allowed_ip=\(a)") }
            }
        }
        var n = 0
        emit { _ in n += 1 }
        return SecretBytes(count: n) { dst in
            var i = 0
            emit { x in dst[i] = x; i += 1 }
        }
    }
    static func hexDigit(_ v: UInt8) -> UInt8 { v < 10 ? 0x30 + v : 0x61 + v - 10 }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

/// Parsed `wgGetStats` (W5).
struct WGPeerStats: Equatable {
    var publicKeyHex = ""
    var endpoint: String?
    var lastHandshakeSec: Int64 = 0
    var lastHandshakeNsec: Int64 = 0
    var rxBytes: UInt64 = 0
    var txBytes: UInt64 = 0
    var lastHandshake: Date? {
        lastHandshakeSec > 0 ? Date(timeIntervalSince1970: TimeInterval(lastHandshakeSec) + TimeInterval(lastHandshakeNsec) / 1e9) : nil
    }

    static func parse(_ text: String) -> [WGPeerStats] {
        var out: [WGPeerStats] = []
        for raw in text.split(separator: "\n") {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let k = raw[..<eq], v = String(raw[raw.index(after: eq)...])
            if k == "public_key" { out.append(WGPeerStats(publicKeyHex: v)); continue }
            guard !out.isEmpty else { continue }
            switch k {
            case "endpoint": out[out.count - 1].endpoint = v
            case "last_handshake_time_sec": out[out.count - 1].lastHandshakeSec = max(0, Int64(v) ?? 0)
            case "last_handshake_time_nsec": out[out.count - 1].lastHandshakeNsec = max(0, Int64(v) ?? 0)
            case "rx_bytes": out[out.count - 1].rxBytes = UInt64(v) ?? 0
            case "tx_bytes": out[out.count - 1].txBytes = UInt64(v) ?? 0
            default: break        // anything else (and any key material, which W5 never emits) is ignored
            }
        }
        return out
    }
}
