import Foundation
import LPModel

/// DESIGN §9.3 (draft 9, S2 E10): openvpn3 resolves `remote` hostnames itself (asio → getaddrinfo), and under
/// `includeAllNetworks` a provider lookup blocks for 30 s and fails. Before the client sees the canonical profile,
/// every `remote "<hostname>" …` line (top level and inside `<connection>` blocks) is replaced by one line (or one
/// block) per IP the app resolved before the start (or the cache). IP-literal remotes stay as they are; openvpn3
/// resolves nothing for them (and `remote-random-hostname` skips IP literals).
///
/// PENDING-FOLD 51: the top-level `http-proxy "<hostname>" …` line is rewritten the same way, to the FIRST IP of the
/// map (openvpn3's `http-proxy` takes one host; the app's resolution is v4 first). Under the flag a proxy hostname
/// without IPs is reported in `proxyUnresolved` and the adapter fails the attempt with `.dnsResolutionFailed`
/// (held, with a clear detail), never letting openvpn3 resolve it (a 30 s hang that fails, S2 E10).
///
/// Works on the canonical bytes (§8.1: one directive per line, every argument double-quoted with only `\\` and `\"`
/// escapes, inline blocks as `<name>`…`</name>`); key material passes through as bytes and never becomes a `String`.
enum OVPNRemoteRewriter {
    struct Result {
        var content: SecretBytes
        /// Remote entries (lines or connection blocks) left in the profile.
        var remotes: Int
        /// Hostnames that had no IPs (dropped when `dropUnresolved`, kept for openvpn3 otherwise).
        var unresolved: [String]
        /// PF 51: the `http-proxy` hostname had no IPs (the line is left as it was; only fatal under the flag).
        var proxyUnresolved: String? = nil
    }

    /// `dropUnresolved`: under `includeAllNetworks` a hostname without IPs is removed (it could only hang the start).
    static func rewrite(_ payload: SecretBytes, endpoints: [String: [String]], dropUnresolved: Bool) -> Result {
        var buf = payload.copyBytes()
        var out = process(buf, endpoints: endpoints, dropUnresolved: dropUnresolved)
        // Every working copy of the profile (it holds keys) is zeroed; `process`'s slices are gone, so `buf` is unique.
        buf.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        let content = SecretBytes(copying: out.bytes)
        out.bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        return Result(content: content, remotes: out.remotes, unresolved: out.unresolved, proxyUnresolved: out.proxyUnresolved)
    }

    private static func process(_ buf: [UInt8], endpoints: [String: [String]], dropUnresolved: Bool)
        -> (bytes: [UInt8], remotes: Int, unresolved: [String], proxyUnresolved: String?) {
        var out: [UInt8] = []
        out.reserveCapacity(2 * buf.count + 256)
        var remotes = 0
        var unresolved: [String] = []
        var proxyUnresolved: String?
        let lines = buf.split(separator: 0x0A, omittingEmptySubsequences: false)
        func emit(_ line: some Collection<UInt8>) {
            // Never let Array growth free a buffer holding key bytes un-zeroed (review L3): grow by hand, zero the old.
            let need = out.count + line.count + 1
            if need > out.capacity {
                var bigger: [UInt8] = []
                bigger.reserveCapacity(max(2 * out.capacity, need))
                bigger.append(contentsOf: out)
                out.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
                out = bigger
            }
            out.append(contentsOf: line); out.append(0x0A)
        }
        /// The replacement lines for one `remote` line (nil = not a remote line).
        func expand(_ line: ArraySlice<UInt8>) -> [[UInt8]]? {
            guard let (host, rest) = firstArgument(line, of: "remote") else { return nil }
            if isLiteral(host) { return [Array(line)] }
            if let ips = endpoints[host.lowercased()], !ips.isEmpty {
                return ips.map { ip in Array("remote ".utf8) + Array(quote(ip).utf8) + Array(rest) }
            }
            if !unresolved.contains(host) { unresolved.append(host) }
            return dropUnresolved ? [] : [Array(line)]
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.elementsEqual("<connection>".utf8) {
                // Collect the block; emit it once per IP of its remote (or drop it).
                var body: [ArraySlice<UInt8>] = []
                var j = i + 1
                while j < lines.count, !lines[j].elementsEqual("</connection>".utf8) { body.append(lines[j]); j += 1 }
                if let ri = body.firstIndex(where: { firstArgument($0, of: "remote") != nil }) {
                    for v in expand(body[ri]) ?? [] {
                        emit(line)
                        for (k, l) in body.enumerated() { if k == ri { emit(v) } else { emit(l) } }
                        emit("</connection>".utf8)
                        remotes += 1
                    }
                } else {
                    emit(line); for l in body { emit(l) }; emit("</connection>".utf8)
                }
                i = j + 1
                continue
            }
            if let name = inlineTag(line) {
                // Any other inline block (<ca>, <cert>, <key>, <tls-crypt-v2>, …): copied verbatim, never parsed.
                emit(line)
                var j = i + 1
                let end = Array("</\(name)>".utf8)
                while j < lines.count, !lines[j].elementsEqual(end) { emit(lines[j]); j += 1 }
                if j < lines.count { emit(lines[j]) }
                i = j + 1
                continue
            }
            if let (host, rest) = firstArgument(line, of: "http-proxy") {
                // PF 51: one proxy host; an IP literal stays, a hostname becomes its first IP (if any).
                if isLiteral(host) {
                    emit(line)
                } else if let ip = endpoints[host.lowercased()]?.first {
                    emit(Array("http-proxy ".utf8) + Array(quote(ip).utf8) + Array(rest))
                } else {
                    proxyUnresolved = host
                    emit(line)
                }
                i += 1
                continue
            }
            if let v = expand(line) {
                for l in v { emit(l) }
                remotes += v.count
            } else if !(i == lines.count - 1 && line.isEmpty) {      // the final "\n" makes one empty tail
                emit(line)
            }
            i += 1
        }
        return (out, remotes, unresolved, proxyUnresolved)
    }

    /// An IP literal, also bracketed "[v6]" (OVPNNormalizer); openvpn3 resolves nothing for one.
    static func isLiteral(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return IPAddress.isV4(bare) || IPAddress.isV6(bare)
    }

    /// Review PF-R4: the hostnames (lowercased) the profile's `remote` lines (also inside `<connection>` blocks) and
    /// `http-proxy` line name; literals excluded. Other inline blocks (keys, certificates) are skipped unread.
    static func referencedHosts(_ payload: SecretBytes) -> Set<String> {
        var buf = payload.copyBytes()
        let hosts = scanHosts(buf)
        // The working copy holds keys: zeroed (`scanHosts`'s slices are gone, so `buf` is unique).
        buf.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
        return hosts
    }

    private static func scanHosts(_ buf: [UInt8]) -> Set<String> {
        var hosts: Set<String> = []
        var skipUntil: [UInt8]?
        for line in buf.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if let end = skipUntil {
                if line.elementsEqual(end) { skipUntil = nil }
                continue
            }
            if let name = inlineTag(line), name != "connection" { skipUntil = Array("</\(name)>".utf8); continue }
            if let (host, _) = firstArgument(line, of: "remote") ?? firstArgument(line, of: "http-proxy"), !isLiteral(host) {
                hosts.insert(host.lowercased())
            }
        }
        return hosts
    }

    /// `<directive> "<arg>" <rest…>` → (arg, the bytes after it), for a canonical line of that directive.
    static func firstArgument(_ line: ArraySlice<UInt8>, of directive: String) -> (String, ArraySlice<UInt8>)? {
        let prefix = Array("\(directive) \"".utf8)
        guard line.count > prefix.count, line.prefix(prefix.count).elementsEqual(prefix) else { return nil }
        var host: [UInt8] = []
        var k = line.startIndex + prefix.count
        while k < line.endIndex {
            let c = line[k]
            if c == 0x5C, k + 1 < line.endIndex { host.append(line[k + 1]); k += 2; continue }   // \\ or \"
            if c == 0x22 { break }
            host.append(c); k += 1
        }
        guard k < line.endIndex, line[k] == 0x22, !host.isEmpty, host.count <= 253 else { return nil }
        return (String(decoding: host, as: UTF8.self), line[(k + 1)...])
    }

    /// `<name>` opening an inline block (canonical: alone on its line), else nil.
    static func inlineTag(_ line: ArraySlice<UInt8>) -> String? {
        guard line.count > 2, line.first == 0x3C, line.last == 0x3E, line[line.startIndex + 1] != 0x2F else { return nil }
        return String(decoding: line.dropFirst().dropLast(), as: UTF8.self)
    }

    static func quote(_ s: String) -> String { "\"" + s + "\"" }      // IP literals need no escaping
}
