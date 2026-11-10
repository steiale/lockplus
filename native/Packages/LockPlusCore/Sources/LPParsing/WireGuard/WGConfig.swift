import Foundation
import LPModel

// WGConfig: the only WireGuard parser (DESIGN §9.1; port of internal/config parser.go + validator.go with the
// wg-quick rules of ref/wireguard §5). Errors and issues never echo a line's contents (a key could leak).

/// A key we keep but never apply, in file order (for export round trips).
public struct WGExtraKey: Sendable, Equatable, Hashable {
    public var key: String
    public var value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct WGInterface: Sendable, Equatable {
    public var privateKey: String = ""
    /// CIDRs; bare IPs got /32 or /128.
    public var addresses: [String] = []
    /// IPs (servers) and RFC 1035 names (search domains), in order.
    public var dns: [String] = []
    public var mtu: Int?
    public var listenPort: Int?
    /// Preserved, never applied.
    public var table: String?
    public var fwMark: String?
    public var saveConfig: String?
    /// Preserved unstripped (wg-quick `unstripped_value`), never executed.
    public var preUp: [String] = []
    public var postUp: [String] = []
    public var preDown: [String] = []
    public var postDown: [String] = []
    public var extraKeys: [WGExtraKey] = []
    public init() {}

    public var hasScripts: Bool { !(preUp.isEmpty && postUp.isEmpty && preDown.isEmpty && postDown.isEmpty) }
}

public struct WGPeer: Sendable, Equatable {
    public var publicKey: String = ""
    public var presharedKey: String?
    public var endpoint: String?
    /// CIDRs; bare IPs got /32 or /128.
    public var allowedIPs: [String] = []
    /// 0 = off.
    public var persistentKeepalive: Int?
    public var extraKeys: [WGExtraKey] = []
    public init() {}
}

public struct WGConfig: Sendable, Equatable {
    public var interface = WGInterface()
    public var peers: [WGPeer] = []
    public init() {}

    /// 0.0.0.0/0 or ::/0 in any peer's AllowedIPs.
    public var isFullTunnel: Bool {
        peers.contains { p in p.allowedIPs.contains { $0 == "0.0.0.0/0" || $0 == "::/0" } }
    }
}

/// A parse error. `message` names the line and the key, never the value.
public struct WGParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public var line: Int?
    public var description: String { message }
}

/// One validator finding (§9.1): the editor attaches it to `field` ("Interface.PrivateKey", "Peer[0].Endpoint").
public struct ValidationIssue: Sendable, Equatable, Hashable {
    public var field: String
    public var problem: WGProblem
    public init(field: String, problem: WGProblem) {
        self.field = field
        self.problem = problem
    }
    public var message: String { "\(field): \(problem.message)" }
}

public enum WGParser {
    public static let maxRawBytes = 64 * 1024

    /// Notes the parser produces for the import report (`;` lines, preserved keys, hooks).
    public struct Parsed: Sendable {
        public var config: WGConfig
        public var notes: [ImportReportItem]
    }

    enum Section { case none, interface, peer }

    public static func parse(_ input: some Collection<UInt8>) -> Result<Parsed, WGParseError> {
        var bytes = Array(input)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        if let i = bytes.firstIndex(of: 0) {
            let ln = bytes[..<i].count(where: { $0 == 0x0A }) + 1
            return .failure(WGParseError(message: "line \(ln): NUL byte in config", line: ln))
        }
        var cfg = WGConfig()
        var notes: [ImportReportItem] = []
        var section = Section.none
        var sawInterface = false
        var seenInterfaceKeys = Set<String>()
        var seenPeerKeys = Set<String>()
        var lineNum = 0
        // bufio.ScanLines: split on "\n", drop one trailing "\r"; a final line without "\n" counts.
        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        for raw in lines {
            lineNum += 1
            var lineBytes = Array(raw)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            guard let line = String(validating: lineBytes, as: UTF8.self) else {
                return .failure(WGParseError(message: "line \(lineNum): not valid UTF-8", line: lineNum))
            }
            // wg-quick strips everything from the first '#' (${line%%\#*}).
            let stripped = line.firstIndex(of: "#").map { String(line[..<$0]) } ?? line
            let trimmed = trim(stripped)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix(";") {
                notes.append(ImportReportItem(.note, line: lineNum, .wgSemicolonLineSkipped))
                continue
            }
            switch trimmed.lowercased() {
            case "[interface]":
                if sawInterface {
                    return .failure(WGParseError(message: "line \(lineNum): more than one [Interface] section", line: lineNum))
                }
                sawInterface = true
                section = .interface
                continue
            case "[peer]":
                section = .peer
                cfg.peers.append(WGPeer())
                seenPeerKeys = []
                continue
            default:
                break
            }
            guard let eq = trimmed.firstIndex(of: "=") else {
                return .failure(WGParseError(message: "line \(lineNum): expected \"key = value\" syntax", line: lineNum))
            }
            let key = trim(String(trimmed[..<eq]))
            let value = trim(String(trimmed[trimmed.index(after: eq)...]))
            let lk = key.lowercased()
            func dup(_ seen: inout Set<String>) -> WGParseError? {
                if seen.contains(lk) { return WGParseError(message: "line \(lineNum): duplicate key \(safeKey(key))", line: lineNum) }
                seen.insert(lk)
                return nil
            }
            func number(_ name: String) -> Result<Int, WGParseError> {
                if let n = atoi(value) { return .success(n) }
                return .failure(WGParseError(message: "line \(lineNum): invalid \(name) value", line: lineNum))
            }
            switch section {
            case .none:
                return .failure(WGParseError(message: "line \(lineNum): key \(safeKey(key)) outside of any section", line: lineNum))
            case .interface:
                switch lk {
                case "privatekey", "mtu", "listenport", "table", "fwmark", "saveconfig":
                    if let e = dup(&seenInterfaceKeys) { return .failure(e) }
                default: break
                }
                switch lk {
                case "privatekey": cfg.interface.privateKey = value
                case "address": cfg.interface.addresses += splitPrefixes(value)
                case "dns": cfg.interface.dns += splitAndTrim(value)
                case "mtu":
                    switch number("MTU") { case .success(let n): cfg.interface.mtu = n; case .failure(let e): return .failure(e) }
                case "listenport":
                    switch number("ListenPort") {
                    case .success(let n): cfg.interface.listenPort = n == 0 ? nil : n
                    case .failure(let e): return .failure(e)
                    }
                case "table":
                    cfg.interface.table = value
                    notes.append(ImportReportItem(.ignored, line: lineNum, directive: key, .wgSettingNotApplied))
                case "fwmark":
                    cfg.interface.fwMark = value
                    notes.append(ImportReportItem(.ignored, line: lineNum, directive: key, .wgSettingNotApplied))
                case "saveconfig":
                    cfg.interface.saveConfig = value
                    notes.append(ImportReportItem(.ignored, line: lineNum, directive: key, .wgSettingNotApplied))
                case "preup", "postup", "predown", "postdown":
                    // wg-quick keeps the unstripped value for hooks, so a '#' inside a hook survives export.
                    let rawEq = line.firstIndex(of: "=")!
                    let hook = trim(String(line[line.index(after: rawEq)...]))
                    switch lk {
                    case "preup": cfg.interface.preUp.append(hook)
                    case "postup": cfg.interface.postUp.append(hook)
                    case "predown": cfg.interface.preDown.append(hook)
                    default: cfg.interface.postDown.append(hook)
                    }
                    notes.append(ImportReportItem(.ignored, line: lineNum, directive: key, .wgHookNeverRun))
                default:
                    cfg.interface.extraKeys.append(WGExtraKey(key: key, value: value))
                    notes.append(ImportReportItem(.ignored, line: lineNum, directive: safeKeyName(key), .wgUnknownKeyPreserved))
                }
            case .peer:
                switch lk {
                case "publickey", "presharedkey", "endpoint", "persistentkeepalive":
                    if let e = dup(&seenPeerKeys) { return .failure(e) }
                default: break
                }
                let i = cfg.peers.count - 1
                switch lk {
                case "publickey": cfg.peers[i].publicKey = value
                case "presharedkey": cfg.peers[i].presharedKey = value
                case "endpoint": cfg.peers[i].endpoint = value
                case "allowedips": cfg.peers[i].allowedIPs += splitPrefixes(value)
                case "persistentkeepalive":
                    if value.lowercased() == "off" {
                        cfg.peers[i].persistentKeepalive = 0
                    } else {
                        switch number("PersistentKeepalive") {
                        case .success(let n): cfg.peers[i].persistentKeepalive = n
                        case .failure(let e): return .failure(e)
                        }
                    }
                default:
                    cfg.peers[i].extraKeys.append(WGExtraKey(key: key, value: value))
                    notes.append(ImportReportItem(.ignored, line: lineNum, directive: safeKeyName(key), .wgUnknownKeyPreserved))
                }
            }
        }
        if cfg.interface.privateKey.isEmpty {
            return .failure(WGParseError(message: "config has no [Interface] section or missing PrivateKey", line: nil))
        }
        return .success(Parsed(config: cfg, notes: notes))
    }

    // MARK: helpers

    static func trim(_ s: String) -> String {
        // Go strings.TrimSpace (Unicode White_Space); here ASCII whitespace + NBSP family via isWhitespace.
        var sub = Substring(s)
        while let f = sub.unicodeScalars.first, f.properties.isWhitespace { sub = Substring(sub.unicodeScalars.dropFirst()) }
        while let l = sub.unicodeScalars.last, l.properties.isWhitespace { sub = Substring(sub.unicodeScalars.dropLast()) }
        return String(sub)
    }

    static func atoi(_ s: String) -> Int? { OVPNAllowlist.atoi(s) }

    /// A key name safe to show: printable ASCII only, ≤ 32 chars (a malformed line's "key" could be key material).
    static func safeKeyName(_ k: String) -> String {
        let ok = k.utf8.count <= 32 && k.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
        return ok ? k : "(unnamed key)"
    }

    static func safeKey(_ k: String) -> String { "\"" + safeKeyName(k) + "\"" }

    static func splitAndTrim(_ s: String) -> [String] {
        s.split(separator: ",", omittingEmptySubsequences: false).map { trim(String($0)) }.filter { !$0.isEmpty }
    }

    /// Bare IPs get /32 or /128 (required: wireguard-go's UAPI uses netip.ParsePrefix, which rejects bare IPs).
    static func splitPrefixes(_ s: String) -> [String] {
        splitAndTrim(s).map { v in
            if v.contains("/") { return v }
            switch IPAddress.parse(v) {
            case .v4: return v + "/32"
            case .v6: return v + "/128"
            case nil: return v
            }
        }
    }
}

public enum WGValidator {
    /// Port of validator.go plus the §9.1 additions. Returns every issue.
    public static func validate(_ cfg: WGConfig) -> [ValidationIssue] {
        var out: [ValidationIssue] = []
        func add(_ f: String, _ p: WGProblem) {
            let i = ValidationIssue(field: f, problem: p)
            if !out.contains(i) { out.append(i) }
        }
        let i = cfg.interface
        if i.privateKey.isEmpty { add("Interface.PrivateKey", .required) } else if !isKey(i.privateKey) { add("Interface.PrivateKey", .invalidKey) }
        if i.addresses.isEmpty { add("Interface.Address", .required) }
        for a in i.addresses { if let p = cidrProblem(a) { add("Interface.Address", p) } }
        for d in i.dns where IPAddress.parse(d) == nil && !Hostname.isValid(d) { add("Interface.DNS", .invalidDNSEntry) }
        if let m = i.mtu, m < 576 || m > 65535 { add("Interface.MTU", .mtuOutOfRange) }
        if let p = i.listenPort, p < 1 || p > 65535 { add("Interface.ListenPort", .listenPortOutOfRange) }
        if let t = i.table, t.lowercased() != "off", t.lowercased() != "auto", OVPNAllowlist.atoi(t) == nil { add("Interface.Table", .invalidTable) }
        if let fw = i.fwMark, fw.lowercased() != "off", !isDecimalOrHex(fw) { add("Interface.FwMark", .invalidFwMark) }
        // No CR/LF in any value (an export to wg-quick must not gain a line), extra keys and hooks included.
        let ivals = [i.privateKey, i.table ?? "", i.fwMark ?? "", i.saveConfig ?? ""] + i.addresses + i.dns + i.preUp + i.postUp
            + i.preDown + i.postDown + i.extraKeys.flatMap { [$0.key, $0.value] }
        if ivals.contains(where: hasNewline) { add("Interface.ExtraKeys", .containsNewline) }
        if cfg.peers.isEmpty { add("Peer", .noPeers) }
        var keys: [String: Int] = [:]
        for (n, p) in cfg.peers.enumerated() {
            let f = "Peer[\(n)]"
            if p.publicKey.isEmpty { add(f + ".PublicKey", .required) } else if !isKey(p.publicKey) { add(f + ".PublicKey", .invalidKey) }
            if !p.publicKey.isEmpty {
                if keys[p.publicKey] != nil { add(f + ".PublicKey", .duplicatePeer) }
                keys[p.publicKey] = n
            }
            if let psk = p.presharedKey, !psk.isEmpty, !isKey(psk) { add(f + ".PresharedKey", .invalidKey) }
            if let e = p.endpoint, !e.isEmpty, let prob = endpointProblem(e) { add(f + ".Endpoint", prob) }
            if p.allowedIPs.isEmpty { add(f + ".AllowedIPs", .required) }
            for a in p.allowedIPs { if let pr = cidrProblem(a) { add(f + ".AllowedIPs", pr) } }
            if let k = p.persistentKeepalive, k < 0 || k > 65535 { add(f + ".PersistentKeepalive", .keepaliveOutOfRange) }
            let pvals = [p.publicKey, p.presharedKey ?? "", p.endpoint ?? ""] + p.allowedIPs + p.extraKeys.flatMap { [$0.key, $0.value] }
            if pvals.contains(where: hasNewline) { add(f + ".ExtraKeys", .containsNewline) }
        }
        return out
    }

    static func hasNewline(_ s: String) -> Bool { s.utf8.contains(0x0A) || s.utf8.contains(0x0D) }

    /// Base64 (standard, padded) of exactly 32 bytes.
    public static func isKey(_ s: String) -> Bool {
        guard s.utf8.count == 44, let d = Data(base64Encoded: s) else { return false }
        return d.count == 32
    }

    static func cidrProblem(_ s: String) -> WGProblem? {
        do throws(IPPrefix.ParseError) {
            _ = try IPPrefix.parse(s)
            return nil
        } catch {
            return error == .prefixTooLong ? .prefixTooLong : .invalidCIDR
        }
    }

    static func isDecimalOrHex(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.hasPrefix("0x") {
            let h = lower.dropFirst(2)
            return !h.isEmpty && h.count <= 16 && h.allSatisfy { $0.isHexDigit }
        }
        return OVPNAllowlist.atoi(s) != nil
    }

    /// host:port, IPv6 in [], host an IP or RFC 1035 name, port 1–65535.
    static func endpointProblem(_ e: String) -> WGProblem? {
        guard let (host, portStr) = HostPort.split(e) else { return .invalidEndpoint }
        if host.isEmpty { return .invalidEndpointHost }
        if IPAddress.parse(host) == nil && !Hostname.isValid(host) { return .invalidEndpointHost }
        guard let port = OVPNAllowlist.atoi(portStr), (1...65535).contains(port) else { return .invalidEndpointPort }
        return nil
    }
}

public enum WGSerializer {
    /// Canonical `.conf` text (Go `Serialize` layout): hooks one per line in order, extra keys sorted by name
    /// (stable), keepalive 0/off omitted.
    public static func serialize(_ cfg: WGConfig) -> String {
        var b = "[Interface]\nPrivateKey = \(cfg.interface.privateKey)\n"
        let i = cfg.interface
        if !i.addresses.isEmpty { b += "Address = \(i.addresses.joined(separator: ", "))\n" }
        if !i.dns.isEmpty { b += "DNS = \(i.dns.joined(separator: ", "))\n" }
        if let m = i.mtu { b += "MTU = \(m)\n" }
        if let p = i.listenPort { b += "ListenPort = \(p)\n" }
        if let t = i.table { b += "Table = \(t)\n" }
        if let f = i.fwMark { b += "FwMark = \(f)\n" }
        if let s = i.saveConfig { b += "SaveConfig = \(s)\n" }
        for h in i.preUp { b += "PreUp = \(h)\n" }
        for h in i.postUp { b += "PostUp = \(h)\n" }
        for h in i.preDown { b += "PreDown = \(h)\n" }
        for h in i.postDown { b += "PostDown = \(h)\n" }
        b += extra(i.extraKeys)
        for p in cfg.peers {
            b += "\n[Peer]\nPublicKey = \(p.publicKey)\n"
            if let k = p.presharedKey, !k.isEmpty { b += "PresharedKey = \(k)\n" }
            if let e = p.endpoint, !e.isEmpty { b += "Endpoint = \(e)\n" }
            if !p.allowedIPs.isEmpty { b += "AllowedIPs = \(p.allowedIPs.joined(separator: ", "))\n" }
            if let k = p.persistentKeepalive, k > 0 { b += "PersistentKeepalive = \(k)\n" }
            b += extra(p.extraKeys)
        }
        return b
    }

    static func extra(_ keys: [WGExtraKey]) -> String {
        keys.enumerated().sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }
            .map { "\($0.element.key) = \($0.element.value)\n" }.joined()
    }
}
