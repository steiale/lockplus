import CryptoKit
import Foundation

/// DESIGN §14.2: ONE redaction policy for every file of the diagnostics bundle. Pure and unit-tested; the same salt
/// per bundle, so a host hashes identically across files (`host#3fa2`), and differently in the next bundle.
///
/// Removed outright: PEM blocks, WireGuard/base64 keys, `key = value` secrets (private keys, preshared keys,
/// passwords, passphrases, tokens), CRV1/SCRV1 challenge strings, Authorization headers.
/// Hashed: IP addresses and host names (except the `keep` list, e.g. DNS server IPs), the user's name and home path,
/// and every caller-supplied sensitive literal (SSIDs, profile names, user names).
struct Redactor: Sendable {
    let salt: Data
    /// Literals kept verbatim (DNS server IPs, the tunnel's routes, the default gateway).
    var keep: Set<String> = []
    /// Literals always hashed wherever they appear (SSIDs, profile names, saved user names). Longest first.
    var sensitive: [String] = []
    var userName: String = NSUserName()

    init(salt: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) }), keep: Set<String> = [], sensitive: [String] = []) {
        self.salt = salt
        self.keep = keep
        self.sensitive = sensitive.filter { $0.count >= 2 }.sorted { $0.count > $1.count }
    }

    /// `kind#xxxx`: 4 hex digits of HMAC-SHA256(salt, value).
    func hash(_ value: String, kind: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: salt))
        return kind + "#" + mac.prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    private static func regex(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)     // constant patterns, compiled by the tests
    }

    private static let pem = regex(#"-----BEGIN [A-Z0-9 ]+-----[\s\S]*?-----END [A-Z0-9 ]+-----"#)
    private static let pemOpen = regex(#"-----BEGIN [A-Z0-9 ]+-----[\s\S]*$"#)
    private static let inlineTag = regex(#"<(key|tls-auth|tls-crypt|tls-crypt-v2|secret|auth-user-pass|pkcs12)>[\s\S]*?</\1>"#, .caseInsensitive)
    private static let secretKV = regex(#"(?i)\b(private[_ -]?key|preshared[_ -]?key|password|passphrase|passwd|secret|auth[_-]?token|token|psk|cookie)\b(\s*[=:]\s*|\s+)("[^"]*"|\S+)"#)
    private static let authHeader = regex(#"(?i)\b(authorization|proxy-authorization)\s*:\s*\S+(\s+\S+)?"#)
    private static let challenge = regex(#"\bS?CRV1:[^\s"]+"#)
    private static let base64Key = regex(#"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{42,43}=(?![A-Za-z0-9+/=])"#)
    private static let longBase64 = regex(#"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{64,}={0,2}"#)
    private static let ipv4 = regex(#"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d])"#)
    /// Colon-separated hex groups (empty groups allowed, so `::` forms match); the closure keeps times like 21:35:00.
    private static let ipv6 = regex(#"(?<![0-9A-Za-z:.])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:%[A-Za-z0-9]+)?(?![0-9A-Za-z:])"#)
    private static let host = regex(#"(?<![A-Za-z0-9_.-])(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,62})\.)+[A-Za-z][A-Za-z0-9-]{1,23}(?![A-Za-z0-9_-])"#)

    /// Last labels that make a dotted token a file name or our own identifier, not a host.
    private static let notHostSuffix: Set<String> = ["json", "txt", "plist", "swift", "ips", "log", "conf", "ovpn", "app", "dylib",
                                                     "framework", "systemextension", "xpc", "zip", "dmg", "sealed", "lock", "png",
                                                     "m", "h", "c", "cpp", "mm", "go", "md", "xcconfig", "entitlements", "bundle"]
    private static let ownPrefixes = ["io.github.steiale.", "com.apple.", "NE", "NS"]

    func redact(_ input: String) -> String {
        var s = input
        // 1. secrets: removed, never hashed
        s = Self.replace(Self.pem, in: s) { _ in "<pem redacted>" }
        s = Self.replace(Self.pemOpen, in: s) { _ in "<pem redacted>" }
        s = Self.replace(Self.inlineTag, in: s) { _ in "<inline block redacted>" }
        s = Self.replace(Self.authHeader, in: s) { m in (m.components(separatedBy: ":").first ?? "authorization") + ": <redacted>" }
        s = Self.replace(Self.challenge, in: s) { _ in "<challenge redacted>" }
        s = Self.replace(Self.secretKV, in: s, group: 3) { _ in "<redacted>" }
        s = Self.replace(Self.base64Key, in: s) { _ in "<key redacted>" }
        s = Self.replace(Self.longBase64, in: s) { _ in "<blob redacted>" }
        // 2. caller-supplied literals (SSIDs, profile and user names)
        // Whole words only, so a profile called "Work" doesn't turn "Network" into "Net<…>".
        for lit in sensitive where s.contains(lit) {
            let re = Self.regex("(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: lit) + "(?![\\p{L}\\p{N}_])")
            s = Self.replace(re, in: s) { _ in hash(lit, kind: "name") }
        }
        // 3. the user
        if !userName.isEmpty {
            s = s.replacingOccurrences(of: "/Users/\(userName)", with: "/Users/<user>")
            s = Self.replace(Self.regex("(?<![A-Za-z0-9_.-])" + NSRegularExpression.escapedPattern(for: userName) + "(?![A-Za-z0-9_-])"), in: s) { _ in "<user>" }
        }
        // 4. addresses and host names
        s = Self.replace(Self.ipv6, in: s) { m in
            // Times ("21:35:00") aren't addresses: an IPv6 literal has "::" or at least 4 colons.
            let looksLikeV6 = m.contains("::") || m.filter { $0 == ":" }.count >= 4
            return keep.contains(m) || !looksLikeV6 ? m : hash(m.lowercased(), kind: "ip6")
        }
        s = Self.replace(Self.ipv4, in: s) { m in keep.contains(m) || Self.isUnspecific(m) ? m : hash(m, kind: "ip") }
        s = Self.replace(Self.host, in: s) { m in
            let last = m.split(separator: ".").last.map { String($0).lowercased() } ?? ""
            if keep.contains(m) || Self.notHostSuffix.contains(last) || Self.ownPrefixes.contains(where: { m.hasPrefix($0) }) { return m }
            if m.hasSuffix(".invalid") { return m }
            return hash(m.lowercased(), kind: "host")
        }
        return s
    }

    /// Masks and well-known non-identifying addresses stay readable.
    private static func isUnspecific(_ ip: String) -> Bool {
        ["0.0.0.0", "127.0.0.1", "255.255.255.255", "255.255.255.0", "255.255.0.0", "255.0.0.0"].contains(ip)
    }

    private static func replace(_ re: NSRegularExpression, in s: String, group: Int = 0, _ f: (String) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range(at: group)
            guard r.location != NSNotFound else { continue }
            out += ns.substring(with: NSRange(location: last, length: r.location - last))
            out += f(ns.substring(with: r))
            last = r.location + r.length
        }
        out += ns.substring(from: last)
        return out
    }
}
