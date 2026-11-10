import LPModel
// OVPNAllowlist: port of internal/ovpn/allowlist.go + the structural checks of inspectProfile (config.go).
// DESIGN §8.1 step [3], §8.2.
//
// An ALLOWLIST built from OpenVPN 2.7.8's add_option: client-side options that neither take a local path nor execute
// anything. Names match exactly (openvpn's own matching is case-sensitive). Messages name the directive, never its
// arguments, and are byte-identical to the Go messages (the shared vectors compare them).
//
// Native additions (DESIGN §8.2 decision): `client-cert-not-required` and `sni` (both inert locally).

public enum OVPNInlineMode: Sendable, Equatable {
    case never      // plain directive only
    case only       // only as <name>…</name>; the file-path form is refused
    case optional   // either (the argument is a value, not a path)
}

/// One allowlist violation. `message` is the Go text without the "invalid .ovpn: " prefix.
public struct OVPNAllowlistViolation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The directive is not on the allowlist (or is a strip-only directive in a forbidden place).
        case notAllowed
        /// On the allowlist, but this form (inline/path/arguments) is refused.
        case badForm
        /// A profile-level rule: no remote, not a client, privileged local port.
        case structural
    }
    public var kind: Kind
    public var line: Int?
    /// The directive name involved (never an argument).
    public var directive: String?
    public var message: String
    /// The directive's form is a TAP device (`dev tap`, `dev-type tap`): UI-CONCEPT §6.15 has dedicated copy.
    public var isTAP: Bool = false
}

public enum OVPNAllowlist {
    typealias Check = @Sendable (_ args: [String], _ isInline: Bool, _ line: Int) -> String?

    struct Rule: Sendable {
        var inline: OVPNInlineMode = .never
        var validate: Check? = nil
    }

    /// Directives accepted at top level but never passed on (Go: removed from the runtime config).
    static let stripOnly: Set<String> = ["user", "group"]

    /// Native additions to the Go key set (DESIGN §8.2).
    public static let nativeAdditions: Set<String> = ["client-cert-not-required", "sni"]

    static let safeSetenvNames: Set<String> = [
        "FORWARD_COMPATIBLE", "PUSH_PEER_INFO", "REMOTE_RANDOM_HOSTNAME", "SERVER_POLL_TIMEOUT", "CLIENT_CERT",
    ]

    static let rules: [String: Rule] = {
        var r: [String: Rule] = [:]
        func plain(_ names: String...) { for n in names { r[n] = Rule() } }
        // Role / transport / remote selection.
        plain("client", "tls-client", "pull", "proto", "proto-force", "remote", "remote-random", "remote-random-hostname",
              "resolv-retry", "nobind", "bind", "port", "rport", "float", "connect-retry", "connect-retry-max",
              "connect-timeout", "server-poll-timeout", "explicit-exit-notify", "sndbuf", "rcvbuf", "socket-flags",
              "fast-io", "http-proxy-option", "allow-pull-fqdn")
        plain("persist-key", "persist-tun", "persist-remote-ip", "persist-local-ip")
        plain("remote-cert-tls", "remote-cert-ku", "remote-cert-eku", "ns-cert-type", "verify-x509-name", "auth", "cipher",
              "data-ciphers", "data-ciphers-fallback", "ncp-ciphers", "tls-version-min", "tls-version-max", "tls-cipher",
              "tls-ciphersuites", "tls-groups", "ecdh-curve", "tls-cert-profile", "key-direction", "hand-window",
              "tran-window", "tls-timeout", "reneg-sec", "reneg-bytes", "reneg-pkts", "replay-window", "compat-mode")
        plain("comp-lzo", "compress", "allow-compression")
        plain("verb", "mute", "mute-replay-warnings")
        plain("auth-nocache", "auth-retry", "static-challenge", "push-peer-info")
        plain("pull-filter", "route", "route-ipv6", "route-nopull", "route-gateway", "route-ipv6-gateway", "route-metric",
              "route-delay", "redirect-gateway", "redirect-private", "block-ipv6", "allow-recursive-routing",
              "dhcp-option", "dns", "topology")
        plain("tun-mtu", "tun-mtu-extra", "tun-mtu-max", "mssfix", "fragment", "link-mtu", "mtu-disc")
        plain("keepalive", "ping", "ping-restart", "ping-exit", "ping-timer-rem", "inactive")
        plain("tun-ipv6", "disable-occ", "disable-dco", "ignore-unknown-option")
        plain("script-security")
        plain("route-method", "block-outside-dns", "register-dns", "ip-win32", "dhcp-renew", "dhcp-release",
              "dhcp-pre-release", "tap-sleep")
        // Native additions (DESIGN §8.2).
        plain("client-cert-not-required", "sni")
        // Key material: inline blocks only.
        for n in ["ca", "cert", "key", "extra-certs", "pkcs12", "crl-verify", "dh", "tls-auth", "tls-crypt", "tls-crypt-v2",
                  "http-proxy-user-pass", "connection"] {
            r[n] = Rule(inline: .only)
        }
        r["peer-fingerprint"] = Rule(inline: .optional)
        r["verify-hash"] = Rule(inline: .optional)
        r["auth-user-pass"] = Rule(inline: .optional) { args, isInline, _ in
            if !isInline && !args.isEmpty {
                return "a credentials file is not allowed; use bare 'auth-user-pass' or an inline <auth-user-pass> block"
            }
            return nil
        }
        r["dev"] = Rule { args, _, _ in
            if args.count != 1 || !isDevName(args[0]) { return "only tun devices are supported" }
            return nil
        }
        r["dev-type"] = Rule { args, _, _ in
            if args.count != 1 || args[0] != "tun" { return "only dev-type tun is supported" }
            return nil
        }
        r["dns-updown"] = Rule { args, _, _ in
            if args.count != 1 || args[0] != "disable" { return "only 'dns-updown disable' is allowed" }
            return nil
        }
        r["http-proxy"] = Rule { args, _, _ in
            if args.count <= 2 { return nil }
            switch args[2] {
            case "auto", "auto-nct": return args.count > 3 ? "too many arguments" : nil
            case "stdin": return args.count > 4 ? "too many arguments" : nil
            default: return "a proxy credentials file is not allowed; use an inline <http-proxy-user-pass> block"
            }
        }
        r["socks-proxy"] = Rule { args, _, _ in
            if args.count > 2 && args[2] != "stdin" { return "a proxy credentials file is not allowed" }
            return args.count > 3 ? "too many arguments" : nil
        }
        r["lport"] = Rule { args, _, _ in
            if args.count != 1 || !unprivilegedPort(args[0]) { return "local port must be 0 or 1024-65535" }
            return nil
        }
        r["local"] = Rule { args, _, _ in
            if args.count >= 2 && !unprivilegedPort(args[1]) { return "local port must be 0 or 1024-65535" }
            return nil
        }
        r["providers"] = Rule { args, _, _ in
            for a in args where a != "legacy" && a != "default" && a != "base" {
                return "only the legacy, default and base providers are allowed"
            }
            return nil
        }
        plain("user", "group")
        r["setenv"] = Rule { args, _, line in validateSetenv(args, line: line) }
        r["setenv-safe"] = Rule { args, _, _ in
            if args.count < 1 || args.count > 2 || !isEnvName(args[0]) { return "invalid variable" }
            return nil
        }
        return r
    }()

    /// The allowlist key set (Go keys + native additions). EngineSupport covers exactly this set (§8.2 test).
    public static var keys: Set<String> { Set(rules.keys) }

    /// The Go key set only.
    public static var goKeys: Set<String> { keys.subtracting(nativeAdditions) }

    public static func inlineMode(_ name: String) -> OVPNInlineMode? { rules[name]?.inline }

    // MARK: helpers (regexes of the Go code, written out)

    /// `^u?tun[0-9]{0,3}$`
    static func isDevName(_ s: String) -> Bool {
        var u = Substring(s)
        if u.hasPrefix("u") { u = u.dropFirst() }
        guard u.hasPrefix("tun") else { return false }
        let digits = u.dropFirst(3)
        return digits.count <= 3 && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// `^[A-Za-z0-9_]{1,64}$`
    static func isEnvName(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...64).contains(b.count) else { return false }
        return b.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
    }

    /// Go strconv.Atoi: optional sign, ASCII digits, no whitespace.
    static func atoi(_ s: String) -> Int? {
        var b = Substring(s)
        var neg = false
        if b.hasPrefix("+") || b.hasPrefix("-") {
            neg = b.hasPrefix("-")
            b = b.dropFirst()
        }
        guard !b.isEmpty, b.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), b.utf8.count <= 18 else { return nil }
        guard let v = Int(b) else { return nil }
        return neg ? -v : v
    }

    /// A numeric port that is 0 (ephemeral) or 1024–65535. Service names are refused.
    static func unprivilegedPort(_ s: String) -> Bool {
        guard let n = atoi(s) else { return false }
        return n == 0 || (n >= 1024 && n <= 65535)
    }

    /// Both setenv forms. "setenv opt X …" is the directive X (openvpn shifts p by two), so X must pass the allowlist.
    static func validateSetenv(_ args: [String], line: Int) -> String? {
        if args.count >= 1 && args[0] == "opt" {
            if args.count < 2 { return "'setenv opt' needs a directive" }
            let inner = args[1]
            if stripOnly.contains(inner) { return "setenv opt: directive \(goQuote(inner)) is not allowed" }
            if let msg = checkMessage(name: inner, args: Array(args.dropFirst(2)), isInline: false, line: line) {
                return "setenv opt: \(msg)"
            }
            return nil
        }
        if args.count < 1 || args.count > 2 { return "invalid arguments" }
        let name = args[0]
        if !isEnvName(name) { return "invalid variable name" }
        if safeSetenvNames.contains(name) || name.hasPrefix("UV_") || name.hasPrefix("IV_") { return nil }
        return "variable \(goQuote(name)) is not allowed"
    }

    /// checkDirective: nil if allowed, else the Go message.
    static func checkMessage(name: String, args: [String], isInline: Bool, line: Int) -> String? {
        guard let rule = rules[name] else { return "directive \(goQuote(name)) is not allowed" }
        if isInline && rule.inline == .never {
            return "directive \(goQuote(name)) cannot be an inline <\(name)> block"
        }
        if !isInline && rule.inline == .only {
            return "directive \(goQuote(name)): file paths are not allowed; embed the content inline as <\(name)>...</\(name)>"
        }
        if let v = rule.validate, let msg = v(args, isInline, line) {
            return "directive \(goQuote(name)): \(msg)"
        }
        return nil
    }

    /// Checks one directive (and, for `setenv opt`, its payload).
    public static func check(_ d: OVPNDirective) -> OVPNAllowlistViolation? {
        guard let msg = checkMessage(name: d.name, args: d.args, isInline: d.isInline, line: d.line) else { return nil }
        let eff = effective(d).name
        let known = rules[d.name] != nil && (d.name != "setenv" || eff == "setenv" || (rules[eff] != nil && !stripOnly.contains(eff)))
        let tap = (d.name == "dev" || d.name == "dev-type") && d.args.first.map { $0.hasPrefix("tap") } == true
        return OVPNAllowlistViolation(kind: known ? .badForm : .notAllowed, line: d.line,
                                      directive: d.name, message: msg, isTAP: tap)
    }

    /// The allowlist pass over a whole profile, collecting every violation in Go's visit order (each top-level
    /// directive, then its <connection> children), then the profile-level rules. The first element is exactly
    /// the error Go's `ValidateOVPN` returns (see `goValidate`).
    public static func inspect(_ ds: [OVPNDirective]) -> [OVPNAllowlistViolation] {
        var out: [OVPNAllowlistViolation] = []
        var hasRemote = false, hasClient = false, pull = false, bind = false
        var lowPort: [Int] = []
        func visit(_ d: OVPNDirective, topLevel: Bool) {
            if let v = check(d) {
                out.append(v)
                return
            }
            if stripOnly.contains(d.name) {
                if !topLevel {
                    out.append(OVPNAllowlistViolation(kind: .notAllowed, line: d.line, directive: d.name,
                                                      message: "directive \(goQuote(d.name)) is not allowed inside <connection>"))
                }
                return
            }
            if d.isInline { return }
            let (name, args) = effective(d)
            switch name {
            case "remote": hasRemote = true
            case "client": hasClient = true; pull = true
            case "tls-client": hasClient = true
            case "pull": pull = true
            case "bind": bind = true
            case "local": if args.count < 2 { bind = true }
            case "port": if args.count == 1 && !unprivilegedPort(args[0]) { lowPort.append(d.line) }
            default: break
            }
        }
        for d in ds {
            visit(d, topLevel: true)
            for c in d.children { visit(c, topLevel: false) }
        }
        out = out.map { v in
            var v = v
            if let l = v.line { v.message = "line \(l): \(v.message)" }
            return v
        }
        if !hasRemote {
            out.append(OVPNAllowlistViolation(kind: .structural, line: nil, directive: "remote",
                                              message: "no 'remote' directive found"))
        }
        if !hasClient {
            out.append(OVPNAllowlistViolation(kind: .structural, line: nil, directive: "client",
                                              message: "missing 'client' or 'tls-client' directive (is this a server config?)"))
        }
        if let l = lowPort.first, bind || !pull {
            out.append(OVPNAllowlistViolation(kind: .structural, line: l, directive: "port",
                                              message: "line \(l): directive \"port\": binding a local port below 1024 is not allowed; use 'rport' for the server port"))
        }
        return out
    }

    /// "setenv opt X args" resolves to the directive openvpn applies.
    public static func effective(_ d: OVPNDirective) -> (name: String, args: [String]) {
        if d.name == "setenv" && d.args.count >= 2 && d.args[0] == "opt" {
            return (d.args[1], Array(d.args.dropFirst(2)))
        }
        return (d.name, d.args)
    }

    /// `effective`, repeated: `setenv opt setenv opt X` is X. The normalizer classifies by the innermost directive, so
    /// a nested wrapper can't carry X past the EngineSupport table (found by fuzz_ovpn_import).
    public static func innermost(_ d: OVPNDirective) -> (name: String, args: [String]) {
        var (n, a) = (d.name, d.args)
        while n == "setenv" && a.count >= 2 && a[0] == "opt" {
            n = a[1]
            a = Array(a.dropFirst(2))
        }
        return (n, a)
    }

    /// Exactly Go's `ValidateOVPN(data)` result: nil on accept, else the error text. Used by the differential tests;
    /// the native import pipeline uses `inspect` (all violations) instead.
    public static func goValidate(_ data: some Collection<UInt8>) -> String? {
        if data.count > OVPNImportLimits.maxRawBytes {
            return "invalid .ovpn: file is larger than \(OVPNImportLimits.maxRawBytes) bytes"
        }
        switch OVPNTokenizer.parse(data) {
        case .failure(let e): return "invalid .ovpn: \(e.message)"
        case .success(let ds):
            // Differs from Go only for the native additions (`client-cert-not-required`, `sni`), which Go rejects.
            return inspect(ds).first.map { "invalid .ovpn: \($0.message)" }
        }
    }

    /// Go's %q for the names we print (ASCII-safe names; anything else is escaped like strconv.Quote).
    static func goQuote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{07}": out += "\\a"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{0B}": out += "\\v"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    out += "\\x" + String(format2(u.value))
                } else if u == "\u{FFFD}" {
                    out += "\u{FFFD}"
                } else if u.properties.generalCategory == .control || u.properties.generalCategory == .format
                            || u.properties.generalCategory == .unassigned || u.properties.generalCategory == .lineSeparator
                            || u.properties.generalCategory == .paragraphSeparator || u.properties.generalCategory == .privateUse
                            || u.properties.generalCategory == .surrogate {
                    if u.value <= 0xFFFF {
                        out += "\\u" + hex(u.value, width: 4)
                    } else {
                        out += "\\U" + hex(u.value, width: 8)
                    }
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    static func format2(_ v: UInt32) -> String { hex(v, width: 2) }

    static func hex(_ v: UInt32, width: Int) -> String {
        let digits = Array("0123456789abcdef")
        var s = ""
        var x = v
        for _ in 0..<width {
            s = String(digits[Int(x & 0xF)]) + s
            x >>= 4
        }
        return s
    }
}
