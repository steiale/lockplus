import LPModel
// OVPNNormalizer: DESIGN §8.1 steps [3]–[5] over a tokenized profile. Applies the allowlist, classifies each
// directive with EngineSupport, applies every §8.2 conditional rule, extracts inline credentials, and emits the
// canonical text and its directive stream.
//
// The canonical text is a fixpoint: normalizing it again yields the same text and no new notes. The extension relies
// on that, because it re-runs [1]–[6] on the canonical text before every start (§8.1).

/// Inputs that are not in the file.
public struct OVPNNormalizerOptions: Sendable, Equatable {
    /// The user chose "append one-time code to the password" (`AuthPolicy.appendOTP`).
    public var appendOTP: Bool
    /// The server has issued a CRV1 dynamic challenge for this profile before (the profile is OTP-class, §8.4).
    public var dynamicChallengeSeen: Bool

    public init(appendOTP: Bool = false, dynamicChallengeSeen: Bool = false) {
        self.appendOTP = appendOTP
        self.dynamicChallengeSeen = dynamicChallengeSeen
    }
}

/// The normalizer's output. `canonicalText`/`stream` are nil when the report blocks the import.
public struct OVPNNormalized: Sendable {
    public var report: ImportReport
    public var canonicalText: String?
    public var stream: [[String]]?
    public var summary: ProfileSummary
    public var auth: AuthPolicy
    public var credentials: ExtractedCredentials
    public var endpoints: [ImportEndpoint]
    /// §8.6: `enableNonPreferredDCAlgorithms` for this profile (non-AEAD 128-bit-block `cipher`).
    public var legacyCrypto: Bool
    /// §8.4: OTP-class (static challenge, appendOTP, CRV1): `auth-nocache` is in the canonical text.
    public var otpClass: Bool
    /// §8.4: `Config.disableClientCert = !(cert && key)`.
    public var disableClientCert: Bool
}

public enum OVPNNormalizer {
    private struct Candidate {
        var name: String
        var args: [String]
        var line: Int
        var isInline: Bool
        var bodyLines: [String]
        var children: [(name: String, args: [String])]
        var fromSetenvOpt: Bool
    }

    // MARK: reason tables

    /// Why an ignored/dropped directive is reported the way it is. The fallback is `.engineIgnores`, which is NOT harmless
    /// (fail safe: an option openvpn3 ignores that nobody has reviewed is reported as "not applied"). The engine table is
    /// regenerated per openvpn3 release, so every key it lists must be named here or it shows amber; the EngineSupport
    /// test asserts that no current key falls through. Harmless means: ignoring it cannot weaken security or change
    /// what the user relies on.
    static func ignoredReason(_ name: String, args: [String] = []) -> ImportReason {
        switch name {
        case "verb", "mute", "mute-replay-warnings": .loggingManaged
        // reconnects are LockPlus's; ping-exit (exit instead of restarting) is a client option that LockPlus's own
        // reconnect handling replaces, so ignoring it only means the tunnel reconnects instead of ending.
        case "resolv-retry", "connect-retry", "connect-retry-max", "connect-timeout", "explicit-exit-notify", "auth-retry",
             "ping-exit": .reconnectManaged
        case "persist-key", "persist-tun", "persist-remote-ip", "persist-local-ip": .persistenceNotNeeded
        case "nobind", "bind", "lport", "local", "sndbuf", "rcvbuf", "fast-io", "socket-flags": .localBindingNotUsed
        // The user's cipher allowlist is NOT enforced: the engine negotiates the cipher itself (CBC only with a CBC
        // `cipher`, which raises .legacyCBCEncryption).
        case "data-ciphers", "data-ciphers-fallback", "ncp-ciphers": .cipherListNotApplied
        // compat-mode only widens what older servers may negotiate; ecdh-curve is an engine-side default.
        case "compat-mode", "ecdh-curve": .cipherNegotiationAutomatic
        case "script-security", "setenv-safe": .scriptsNeverRun
        case "route-method", "ip-win32", "block-outside-dns", "register-dns", "dhcp-renew", "dhcp-release",
             "dhcp-pre-release", "tap-sleep": .windowsOnly
        case "user", "group": .unixAccountNotUsed
        case "topology", "route-ipv6-gateway": .setByServer
        // The gateway is always the tunnel's own (a route's literal gateway is rewritten to `vpn_gateway`).
        case "route-gateway": .routeGatewayManaged
        case "dh": .serverOnlyOption
        case "verify-hash": .verifyHashNotSupported
        case "dns-updown": .dnsManagedByLockPlus
        // LockPlus accepts compressed downlink only (`asym`). `yes`/`asym` are no stricter than that; anything else
        // (`no`, or a value 2.x would reject) fails safe to "not applied": refusal isn't enforced.
        case "allow-compression":
            switch args.first {
            case "yes", "asym": .compressionPolicyManaged
            default: .compressionNotEnforced
            }
        case "providers": .legacyProvidersNeverLoaded
        case "ping-timer-rem": .pingTimerRemNotNeeded
        // openvpn3 honours only reneg-sec and has a fixed replay window: these change behaviour (rekey cadence, replay
        // protection) and are not applied.
        case "reneg-bytes", "reneg-pkts", "replay-window": .rekeyReplayTuningNotApplied
        // Packet size: tuning only. The tunnel MTU comes from NetworkSettingsBuilder and openvpn3's default mssfix is
        // always active. Round 1 (Codex 8): link-mtu is not emitted, so it doesn't suppress the appended mssfix floor.
        case "link-mtu", "tun-mtu-extra", "mtu-disc": .mtuManaged
        // Routing niceties: delay between route adds, FQDN routes, routes to the server through the tunnel. Ignoring
        // each is the stricter or neutral behaviour.
        case "route-delay", "allow-pull-fqdn", "allow-recursive-routing": .routingManaged
        // OCC option-mismatch check and kernel DCO: the userspace engine neither has nor needs them.
        case "disable-occ", "disable-dco": .engineManagesItself
        // A no-op since 2.4: IPv6 on the tunnel follows the server's push.
        case "tun-ipv6": .obsoleteOption
        // Only caps the TLS version; without it the engine can only be stricter.
        case "tls-version-max": .tlsVersionCapIgnored
        default: .engineIgnores
        }
    }

    static func unsupportedReason(_ name: String, _ category: String) -> ImportReason {
        switch name {
        case "rport": .separateRemotePortNotSupported
        case "proto-force": .protoForceNotSupported
        case "socks-proxy": .socksProxyNotSupported
        case "fragment": .fragmentNotSupported
        case "pkcs12": .pkcs12NotSupported
        default: .engineRejects(category: category)
        }
    }

    static func hasControlCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }
    }

    static func isIPLiteral(_ s: String) -> Bool { IPAddress.parse(s) != nil }

    // MARK: normalize

    public static func normalize(_ ds: [OVPNDirective], options: OVPNNormalizerOptions = .init()) -> OVPNNormalized {
        var report = ImportReport()
        var creds = ExtractedCredentials()

        // [3] allowlist (every violation, Go order)
        var badLines = Set<Int>()
        for v in OVPNAllowlist.inspect(ds) {
            if let l = v.line { badLines.insert(l) }
            switch v.kind {
            case .structural:
                switch v.directive {
                case "remote": report.add(.notSupported, directive: "remote", .noRemote)
                case "client": report.add(.notSupported, directive: "client", .notAClientProfile)
                default: report.add(.notSupported, line: v.line, directive: v.directive, .privilegedLocalPort)
                }
            default:
                if v.isTAP {
                    report.add(.notSupported, line: v.line, directive: v.directive, .tapNotSupported)
                } else {
                    let detail = v.message.split(separator: ": ", maxSplits: 1).last.map(String.init) ?? v.message
                    report.add(.notSupported, line: v.line, directive: v.directive, .forbidden(detail: detail))
                }
            }
        }

        // effective directives (setenv opt X → X), with every top-level name the profile mentions
        var cands: [Candidate] = []
        var present = Set<String>()     // effective names in the profile (any class)
        for d in ds where !badLines.contains(d.line) {
            if d.hasInvalidUTF8 {
                report.add(.notSupported, line: d.line, directive: d.name, .invalidUTF8)
                continue
            }
            let (name, args) = OVPNAllowlist.innermost(d)
            let opt = name != d.name || (d.name == "setenv" && d.args.first == "opt")
            present.insert(name)
            cands.append(Candidate(name: name, args: args, line: d.line, isInline: d.isInline,
                                   bodyLines: d.isInline ? OVPNCanonical.bodyLines(d.body) : [],
                                   children: d.children.map { ($0.name, $0.args) }, fromSetenvOpt: opt))
            if d.name == "connection" {
                for c in d.children where !badLines.contains(c.line) {
                    if c.hasInvalidUTF8 {
                        report.add(.notSupported, line: c.line, directive: c.name, .invalidUTF8)
                    } else if !["remote", "port", "proto"].contains(c.name) || c.isInline {
                        report.add(.notSupported, line: c.line, directive: c.name, .notSupportedInsideConnection)
                    }
                }
            }
        }
        let hasKeepalive = present.contains("keepalive")
        let hasClient = present.contains("client")
        let hasHTTPProxy = present.contains("http-proxy")
        let endpoints = collectRemotes(ds)
        var proxy: ImportEndpoint?          // PF 51: the accepted http-proxy (the last one, like every mapped directive)

        // [4] classify + conditional rules
        var emit: [Candidate] = []
        var supported = 0
        var legacyCrypto = false
        var staticChallenge: StaticChallenge?
        var needsUserPass = false
        var needsKeyPassphrase = false
        var hasCert = false, hasKey = false
        var compression = false
        var devNote: Int?
        var devEmitted = false
        for var c in cands {
            let n = c.name
            if n == "setenv", c.args.first == "IV_SSO" {
                report.add(.ignored, line: c.line, directive: "setenv IV_SSO", .webSignInNotSupported)
                continue
            }
            guard let cls = OVPNEngineSupport.classify(n) else {
                report.add(.notSupported, line: c.line, directive: n, .forbidden(detail: "directive \"\(n)\" is not allowed"))
                continue
            }
            switch cls {
            case .ignoredWarn, .ignoredSilent, .dropped:
                report.add(.ignored, line: c.line, directive: n, ignoredReason(n, args: c.args))
                continue
            case .unsupported(let cat):
                report.add(.notSupported, line: c.line, directive: n, unsupportedReason(n, cat))
                continue
            case .mapped:
                break
            }
            // per-directive rules for mapped directives
            // `<connection>` children are emitted verbatim (see `children` below), so their args get the same check.
            if c.args.contains(where: hasControlCharacters) || c.children.contains(where: { $0.args.contains(where: hasControlCharacters) }) {
                report.add(.notSupported, line: c.line, directive: n, .controlCharacters)
                continue
            }
            if n.utf8.count > OVPNImportLimits.maxDirectiveNameBytes {
                report.add(.notSupported, line: c.line, directive: nil, .limitExceeded(limit: .directiveNameLength))
                continue
            }
            if c.isInline {
                if c.bodyLines.contains(where: { $0.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{0B}" || $0 == "\u{0C}" }).hasPrefix("</") }) {
                    report.add(.notSupported, line: c.line, directive: n, .inlineBodyLineStartsWithCloseTag)
                    continue
                }
                if c.bodyLines.contains(where: hasControlCharacters) {
                    report.add(.notSupported, line: c.line, directive: n, .controlCharacters)
                    continue
                }
            }
            if c.fromSetenvOpt { report.add(.note, line: c.line, directive: "setenv opt \(n)", .setenvOptClassifiedAsDirective) }
            switch n {
            case "dev", "dev-type":
                if !(n == "dev" && c.args == ["tun"]) { devNote = devNote ?? c.line }
                if devEmitted { continue }
                devEmitted = true
                c = Candidate(name: "dev", args: ["tun"], line: c.line, isInline: false, bodyLines: [], children: [], fromSetenvOpt: false)
            case "ping", "ping-restart":
                if hasKeepalive {
                    report.add(.ignored, line: c.line, directive: n, .keepaliveTakesPrecedence)
                    continue
                }
            case "tls-client", "pull":
                if !hasClient && !(present.contains("tls-client") && present.contains("pull")) {
                    report.add(.notSupported, line: c.line, directive: n, .tlsClientNeedsPull)
                    continue
                }
            case "auth-user-pass":
                if c.isInline {
                    let lines = c.bodyLines
                    guard let user = lines.first, !user.isEmpty, user.utf8.count <= 512,
                          lines.count < 2 || lines[1].utf8.count <= 1024 else {
                        report.add(.notSupported, line: c.line, directive: n, .inlineCredentialsMalformed)
                        continue
                    }
                    creds.username = SecretBytes(copying: Array(user.utf8))
                    if lines.count >= 2, !lines[1].isEmpty {
                        creds.password = SecretBytes(copying: Array(lines[1].utf8))
                    } else {
                        needsUserPass = true
                    }
                    report.add(.note, line: c.line, directive: n, .credentialsExtracted)
                    c = Candidate(name: n, args: [], line: c.line, isInline: false, bodyLines: [], children: [], fromSetenvOpt: false)
                } else {
                    needsUserPass = true
                }
            case "http-proxy-user-pass":
                guard hasHTTPProxy else {
                    report.add(.notSupported, line: c.line, directive: n, .proxyOptionWithoutProxy)
                    continue
                }
                let lines = c.bodyLines
                guard lines.count >= 2, !lines[0].isEmpty, lines[0].utf8.count <= 512, lines[1].utf8.count <= 1024 else {
                    report.add(.notSupported, line: c.line, directive: n, .inlineCredentialsMalformed)
                    continue
                }
                creds.proxyUsername = SecretBytes(copying: Array(lines[0].utf8))
                creds.proxyPassword = SecretBytes(copying: Array(lines[1].utf8))
                report.add(.note, line: c.line, directive: n, .proxyCredentialsExtracted)
                continue
            case "http-proxy-option":
                if !hasHTTPProxy {
                    report.add(.notSupported, line: c.line, directive: n, .proxyOptionWithoutProxy)
                    continue
                }
            case "http-proxy":
                if !endpoints.contains(where: { $0.transport == "tcp" }) {
                    report.add(.notSupported, line: c.line, directive: n, .httpProxyNeedsTCPRemote)
                    continue
                }
                if c.args.count > 2 && !present.contains("http-proxy-user-pass") {
                    report.add(.notSupported, line: c.line, directive: n, .proxyAuthNeedsInlineCredentials)
                    continue
                }
                if c.args.count >= 2, !c.args[0].isEmpty {
                    var host = c.args[0]
                    if host.hasPrefix("[") && host.hasSuffix("]") && host.count >= 2 { host = String(host.dropFirst().dropLast()) }
                    proxy = ImportEndpoint(host: host, port: c.args[1], transport: "tcp")
                }
            case "cipher":
                let name = c.args.first ?? ""
                let shown = OVPNCrypto.isDisplayableAlgorithmName(name) ? name : nil
                switch OVPNCrypto.classifyCipher(name) {
                case .aead: break
                case .cbc: legacyCrypto = true
                case .legacy64BitBlock:
                    report.add(.notSupported, line: c.line, directive: n, .outdatedCipher(name: shown))
                    continue
                case .none:
                    report.add(.notSupported, line: c.line, directive: n, .cipherNone)
                    continue
                case .unknown:
                    report.add(.notSupported, line: c.line, directive: n, .unknownCipher(name: shown))
                    continue
                }
            case "auth":
                let name = c.args.first ?? ""
                let shown = OVPNCrypto.isDisplayableAlgorithmName(name) ? name : nil
                switch OVPNCrypto.classifyDigest(name) {
                case .ok, .none: break
                case .weak:
                    report.add(.notSupported, line: c.line, directive: n, .weakDigest(name: shown))
                    continue
                case .unknown:
                    report.add(.notSupported, line: c.line, directive: n, .unknownDigest(name: shown))
                    continue
                }
            case "static-challenge":
                guard c.args.count >= 2, c.args.count <= 3, !c.args[0].isEmpty, c.args[0].utf8.count <= 256 else {
                    report.add(.notSupported, line: c.line, directive: n, .staticChallengeMalformed)
                    continue
                }
                staticChallenge = StaticChallenge(text: c.args[0], echo: c.args[1] == "1", concat: c.args.count == 3 && c.args[2] == "concat")
            case "route":
                if let net = c.args.first, net.contains("/") {
                    report.add(.note, line: c.line, directive: n, .routeFormIgnoredByEngine)
                }
                if c.args.count >= 3, isIPLiteral(c.args[2]) {
                    c.args[2] = "vpn_gateway"
                    report.add(.note, line: c.line, directive: n, .routeGatewayRewritten)
                }
            case "key":
                if c.isInline {
                    let body = c.bodyLines.joined(separator: "\n")
                    if body.contains("Proc-Type: 4,ENCRYPTED") || body.contains("BEGIN ENCRYPTED PRIVATE KEY") {
                        needsKeyPassphrase = true
                    }
                    hasKey = true
                }
            case "cert":
                hasCert = c.isInline
            case "comp-lzo":
                if c.args.first != "no" { compression = true }
            case "compress":
                if let a = c.args.first, !a.hasPrefix("stub") { compression = true }
            default:
                break
            }
            emit.append(c)
        }
        if let l = devNote { report.add(.note, line: l, directive: "dev", .devRewrittenToTun) }

        // [5] singletons: keep the last occurrence
        var lastIndex: [String: Int] = [:]
        for (i, c) in emit.enumerated() where !OVPNEngineSupport.repeatable.contains(c.name) {
            lastIndex[c.name] = i
        }
        var deduped: [Candidate] = []
        for (i, c) in emit.enumerated() {
            if let li = lastIndex[c.name], li != i {
                report.add(.note, line: c.line, directive: c.name, .duplicateKeptLast)
                continue
            }
            deduped.append(c)
        }
        supported = deduped.count

        // appended floors and rules
        let otpClass = staticChallenge != nil || options.appendOTP || options.dynamicChallengeSeen
        var appended: [(String, [String], ImportReason)] = []
        let names = Set(deduped.map(\.name))
        if let rct = deduped.last(where: { $0.name == "remote-cert-tls" }), rct.args.first == "server", !names.contains("remote-cert-eku") {
            appended.append(("remote-cert-eku", ["TLS Web Server Authentication"], .remoteCertEKUAppended))
        }
        // Round 1 (Codex 8): floors are decided by what is EMITTED, so normalising the canonical text again appends
        // nothing (a fixed point). `link-mtu` is dropped (mtuManaged), so it no longer suppresses the mssfix floor.
        if !names.contains("keepalive") && !names.contains("ping") && !names.contains("ping-restart") {
            appended.append(("ping", ["10"], .keepaliveFloorAppended))
            appended.append(("ping-restart", ["60"], .keepaliveFloorAppended))
        }
        if !names.contains("mssfix") && !names.contains("tun-mtu") {
            appended.append(("mssfix", ["1300"], .mssfixFloorAppended))
        }
        if otpClass && !names.contains("auth-nocache") {
            appended.append(("auth-nocache", [], .authNocacheAppended))
        }
        for (n, _, r) in appended { report.add(.note, directive: n, r) }

        // security warnings (§8.3)
        if !present.contains("remote-cert-tls") && !present.contains("verify-x509-name") && !present.contains("peer-fingerprint") {
            report.add(.securityWarning, .serverIdentityNotPinned)
        }
        if legacyCrypto { report.add(.securityWarning, directive: "cipher", .legacyCBCEncryption) }
        if compression { report.add(.securityWarning, .compressionEnabled) }

        let auth = AuthPolicy(needsUserPass: needsUserPass, appendOTP: options.appendOTP,
                              saveCredentials: !present.contains("auth-nocache"),
                              staticChallenge: staticChallenge, needsKeyPassphrase: needsKeyPassphrase)
        let summary = ProfileSummary(endpoints: endpoints.map(\.display), transport: endpoints.first?.transport ?? "udp",
                                     addresses: [], isFullTunnel: present.contains("redirect-gateway"),
                                     dnsServers: profileDNSServers(cands), usesLegacyCrypto: legacyCrypto,
                                     proxyEndpoint: proxy?.display)
        var result = OVPNNormalized(report: report, canonicalText: nil, stream: nil, summary: summary, auth: auth,
                                    credentials: creds, endpoints: endpoints, legacyCrypto: legacyCrypto,
                                    otpClass: otpClass, disableClientCert: !(hasCert && hasKey))
        if result.report.blocksImport {
            result.credentials = ExtractedCredentials()
            return result
        }

        // emit canonical text + stream, enforcing the caps on the OUTPUT
        var lines: [String] = []
        var stream: [[String]] = []
        func cap(_ limit: ImportLimit, _ line: Int?, _ dir: String?) {
            result.report.add(.notSupported, line: line, directive: dir, .limitExceeded(limit: limit))
        }
        for c in deduped {
            if c.isInline {
                lines.append(OVPNCanonical.inlineBlock(c.name, c.bodyLines))
                stream.append([c.name, OVPNCanonical.streamBody(c.bodyLines)])
                if c.bodyLines.contains(where: { $0.utf8.count > OVPNImportLimits.maxPhysicalLineBytes }) {
                    cap(.lineLength, c.line, c.name)
                }
            } else if c.name == "connection" {
                // unreachable: <connection> is inline-only
            } else {
                let l = OVPNCanonical.line(c.name, c.args)
                if l.utf8.count > OVPNImportLimits.maxCanonicalDirectiveLineBytes { cap(.directiveLineLength, c.line, c.name) }
                lines.append(l)
                stream.append([c.name] + c.args)
            }
            if c.name == "connection" {
                let child = c.children.map { OVPNCanonical.line($0.name, $0.args) }
                lines[lines.count - 1] = OVPNCanonical.inlineBlock("connection", child)
                stream[stream.count - 1] = ["connection", OVPNCanonical.streamBody(child)]
                if child.contains(where: { $0.utf8.count > OVPNImportLimits.maxCanonicalDirectiveLineBytes }) {
                    cap(.directiveLineLength, c.line, "connection")
                }
                if OVPNCanonical.streamBody(child).utf8.count > OVPNImportLimits.maxConnectionBlockBytes {
                    cap(.connectionBlockSize, c.line, "connection")
                }
            }
        }
        for (n, a, _) in appended {
            lines.append(OVPNCanonical.line(n, a))
            stream.append([n] + a)
        }
        let text = lines.joined(separator: "\n") + "\n"
        if OVPNCanonical.accounting(text: text, stream: stream) >= OVPNImportLimits.maxProfileAccounting {
            cap(.profileSize, nil, nil)
        }
        result.report.supportedCount = supported
        if result.report.blocksImport {
            result.credentials = ExtractedCredentials()
            return result
        }
        result.canonicalText = text
        result.stream = stream
        return result
    }

    // MARK: remotes and DNS (ports of config.go collectRemotes / dnsConfig)

    /// Every remote in file order; a <connection> block inherits the top-level proto/port and may override them.
    public static func collectRemotes(_ ds: [OVPNDirective]) -> [ImportEndpoint] {
        func transport(_ p: String) -> String { p.lowercased().hasPrefix("tcp") ? "tcp" : "udp" }
        struct Defaults { var proto = "udp", port = "1194" }
        func apply(_ d: OVPNDirective, _ def: inout Defaults) {
            let (n, a) = OVPNAllowlist.innermost(d)
            guard !d.isInline, let v = a.first else { return }
            if n == "proto" { def.proto = v } else if n == "port" || n == "rport" { def.port = v }
        }
        var global = Defaults()
        for d in ds { apply(d, &global) }
        var out: [ImportEndpoint] = []
        func add(_ d: OVPNDirective, _ def: Defaults) {
            let (_, a) = OVPNAllowlist.innermost(d)
            guard !d.isInline, let h = a.first, !h.isEmpty else { return }
            var host = h
            if host.hasPrefix("[") && host.hasSuffix("]") && host.count >= 2 { host = String(host.dropFirst().dropLast()) }
            var e = ImportEndpoint(host: host, port: def.port, transport: transport(def.proto))
            if a.count >= 2, !a[1].isEmpty { e.port = a[1] }
            if a.count >= 3, !a[2].isEmpty { e.transport = transport(a[2]) }
            out.append(e)
        }
        for d in ds {
            if OVPNAllowlist.innermost(d).name == "remote" { add(d, global) }
            guard !d.children.isEmpty else { continue }
            var local = global
            for c in d.children { apply(c, &local) }
            for c in d.children where c.name == "remote" { add(c, local) }
        }
        return out
    }

    /// DNS servers the profile itself names (2.7 semantics: `dns server` wins over `dhcp-option DNS`).
    private static func profileDNSServers(_ cands: [Candidate]) -> [String] {
        var servers: [(Int, String)] = []
        var dhcp: [String] = []
        for c in cands {
            if c.name == "dhcp-option", c.args.count >= 2, c.args[0] == "DNS" || c.args[0] == "DNS6" {
                dhcp.append(c.args[1])
            } else if c.name == "dns", c.args.count >= 4, c.args[0] == "server", c.args[2] == "address",
                      let prio = OVPNAllowlist.atoi(c.args[1]) {
                for a in c.args.dropFirst(3) { if let ip = stripDNSPort(a) { servers.append((prio, ip)) } }
            }
        }
        var out: [String] = []
        let ordered = servers.isEmpty ? dhcp : servers.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
        for s in ordered where !out.contains(s) { out.append(s) }
        return out
    }

    /// "1.2.3.4", "1.2.3.4:53", "fd00::1" or "[fd00::1]:53" → the bare IP; nil otherwise (Go stripDNSPort).
    public static func stripDNSPort(_ s: String) -> String? {
        if IPAddress.parse(s) != nil { return s }
        if let (host, _) = HostPort.split(s), IPAddress.parse(host) != nil { return host }
        return nil
    }
}
