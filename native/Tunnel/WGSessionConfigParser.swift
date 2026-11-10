import Foundation
import LPModel
import LPParsing
import TunnelEngine

/// `WGConfigParser` over LPParsing's WGConfig (DESIGN §9.1: the only WireGuard parser). The canonical payload is
/// re-parsed and re-validated; keys become raw 32-byte values (`SecretBytes` for the private and preshared keys).
///
/// Residual: LPParsing keeps the base64 keys in `String`s (`WGInterface.privateKey`, `WGPeer.presharedKey`), which
/// can't be zeroed; the copies live only for the duration of `parse` (§6.5 "scoped to the smallest block").
struct LPWGConfigParser: WGConfigParser {
    func parse(_ payload: SecretBytes) throws(LPTunnelError) -> WGSessionConfig {
        let parsed: WGParser.Parsed
        let result = payload.withUnsafeBytes { WGParser.parse($0) }
        switch result {
        case .success(let p): parsed = p
        case .failure(let e): throw LPTunnelError(.profileInvalid, detail: e.message)      // names line + key, never a value
        }
        var cfg = parsed.config
        if let issue = WGValidator.validate(cfg).first { throw LPTunnelError(.profileInvalid, detail: issue.field) }
        // §9.1 normalization (as at import): AllowedIPs with host bits → the network address.
        for p in cfg.peers.indices {
            cfg.peers[p].allowedIPs = cfg.peers[p].allowedIPs.map { s in
                guard let pre = try? IPPrefix.parse(s), pre.hasHostBits else { return s }
                return pre.masked.text
            }
        }
        return try Self.session(cfg)
    }

    static func session(_ cfg: WGConfig) throws(LPTunnelError) -> WGSessionConfig {
        guard let priv = secretKey(cfg.interface.privateKey) else { throw LPTunnelError(.profileInvalid, detail: "Interface.PrivateKey") }
        var peers: [WGSessionConfig.Peer] = []
        for (i, p) in cfg.peers.enumerated() {
            guard let pub = publicKey(p.publicKey) else { throw LPTunnelError(.profileInvalid, detail: "Peer[\(i)].PublicKey") }
            var psk: SecretBytes?
            if let s = p.presharedKey, !s.isEmpty {
                guard let k = secretKey(s) else { throw LPTunnelError(.profileInvalid, detail: "Peer[\(i)].PresharedKey") }
                psk = k
            }
            var host: String?, port: UInt16?
            if let e = p.endpoint, !e.isEmpty {
                guard let hp = HostPort.split(e), let n = UInt16(hp.port), n > 0 else { throw LPTunnelError(.profileInvalid, detail: "Peer[\(i)].Endpoint") }
                host = hp.host; port = n
            }
            let keepalive = p.persistentKeepalive.flatMap { $0 > 0 && $0 <= 65535 ? UInt16($0) : nil }
            peers.append(.init(publicKey: pub, presharedKey: psk, endpointHost: host, endpointPort: port,
                               allowedIPs: p.allowedIPs, persistentKeepalive: keepalive))
        }
        // DNS: an IP is a server, an RFC 1035 name a search domain (§9.1).
        let servers = cfg.interface.dns.filter { IPAddress.parse($0) != nil }
        let search = cfg.interface.dns.filter { IPAddress.parse($0) == nil && Hostname.isValid($0) }
        let listen = cfg.interface.listenPort.flatMap { $0 > 0 && $0 <= 65535 ? UInt16($0) : nil }
        return WGSessionConfig(privateKey: priv, listenPort: listen, addresses: cfg.interface.addresses, dnsServers: servers,
                               searchDomains: search, mtu: cfg.interface.mtu, peers: peers)
    }

    /// base64 → 32 raw bytes in `SecretBytes`; the intermediate `Data` is zeroed.
    static func secretKey(_ b64: String) -> SecretBytes? {
        guard var d = Data(base64Encoded: b64) else { return nil }
        defer { d.resetBytes(in: 0..<d.count) }
        guard d.count == 32 else { return nil }
        return SecretBytes(copying: d)
    }

    static func publicKey(_ b64: String) -> Data? {
        guard let d = Data(base64Encoded: b64), d.count == 32 else { return nil }
        return d
    }
}
