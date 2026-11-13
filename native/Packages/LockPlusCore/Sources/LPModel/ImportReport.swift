import Foundation

// Typed import results (DESIGN §8.3, §3.1 `Profile.importReport`, UI-CONCEPT §6.8 and §6.15).
//
// Every item names a line and a directive/key, never an argument (arguments can be secrets). The one exception is
// the cipher or digest name in the outdated-crypto message, which UI-CONCEPT §6.15 requires and which is shown only
// when it is a plain algorithm name.
//
// NOTE for P2a: `ImportReport` is persisted in `Profile.importReport` (LPModel). Until LPModel defines it, this is
// the definition; move it there unchanged.

/// The groups of the import sheet (§8.3).
public enum ImportReportGroup: String, Codable, Sendable, Hashable, CaseIterable {
    /// "Will be ignored" (grey).
    case ignored
    /// "Not supported" (red). Any item here disables Import.
    case notSupported
    /// "Security warnings" (orange).
    case securityWarning
    /// Informational: what LockPlus changed (rewritten, appended, extracted, deduplicated).
    case note
}

public struct ImportReportItem: Codable, Sendable, Hashable {
    public var group: ImportReportGroup
    /// 1-based line in the imported file, when the item is about one line.
    public var line: Int?
    /// The directive (OpenVPN) or key (WireGuard) concerned. Never an argument.
    public var directive: String?
    public var reason: ImportReason

    public init(_ group: ImportReportGroup, line: Int? = nil, directive: String? = nil, _ reason: ImportReason) {
        self.group = group
        self.line = line
        self.directive = directive
        self.reason = reason
    }

    /// The user-facing English text (UI-CONCEPT copy). `profileName` is the display name used by the cipher message.
    public func message(profileName: String? = nil) -> String { reason.message(profileName: profileName) }

    /// An ignored line that changes nothing the user relies on (LockPlus handles it itself). Ignored lines that DO change
    /// behaviour (scripts never run, an unenforced `verify-hash`, web sign-in, WireGuard settings) are not harmless.
    public var isHarmlessIgnored: Bool { group == .ignored && reason.isHarmlessWhenIgnored }
    /// An ignored line the user should know about: its behaviour is not applied.
    public var isNotApplied: Bool { group == .ignored && !reason.isHarmlessWhenIgnored }
}

public struct ImportReport: Codable, Sendable, Hashable {
    public var items: [ImportReportItem]
    /// Directives (OVPN) or keys (WG) that are used as written ("✓ 41 directives supported").
    public var supportedCount: Int

    public init(items: [ImportReportItem] = [], supportedCount: Int = 0) {
        self.items = items
        self.supportedCount = supportedCount
    }

    public func items(in group: ImportReportGroup) -> [ImportReportItem] { items.filter { $0.group == group } }
    /// Any Not-supported item disables Import (§8.3).
    public var blocksImport: Bool { items.contains { $0.group == .notSupported } }
    public var hasWarnings: Bool { items.contains { $0.group == .securityWarning || $0.isNotApplied } }

    public mutating func add(_ group: ImportReportGroup, line: Int? = nil, directive: String? = nil, _ reason: ImportReason) {
        let item = ImportReportItem(group, line: line, directive: directive, reason)
        if !items.contains(item) { items.append(item) }
    }

    /// The plain-text report for "Copy report" (§8.3). Line, directive and reason only. Ignored lines are split into
    /// "Not applied" (behaviour not applied) and "Not needed" (harmless). `title` and `message` let the app localize.
    public func plainText(profileName: String? = nil,
                          title: (PlainTextSection) -> String = { $0.title },
                          message: ((ImportReportItem) -> String)? = nil) -> String {
        var out: [String] = []
        for section in PlainTextSection.allCases {
            let xs = items.filter { section.contains($0) }
            if xs.isEmpty { continue }
            out.append(title(section) + ":")
            for x in xs {
                var prefix = "  "
                if let l = x.line { prefix += "line \(l) " }
                if let d = x.directive { prefix += "`\(d)` — " }
                out.append(prefix + (message?(x) ?? x.message(profileName: profileName)))
            }
        }
        return out.joined(separator: "\n")
    }
}

/// The headings of the plain-text report: the ignored group split by whether the behaviour is applied.
public enum PlainTextSection: CaseIterable, Sendable {
    case notApplied, notNeeded, notSupported, securityWarning, note

    func contains(_ i: ImportReportItem) -> Bool {
        switch self {
        case .notApplied: i.isNotApplied
        case .notNeeded: i.isHarmlessIgnored
        case .notSupported: i.group == .notSupported
        case .securityWarning: i.group == .securityWarning
        case .note: i.group == .note
        }
    }

    public var title: String {
        switch self {
        case .notApplied: "Not applied"
        case .notNeeded: "Not needed"
        case .notSupported: ImportReportGroup.notSupported.title
        case .securityWarning: ImportReportGroup.securityWarning.title
        case .note: ImportReportGroup.note.title
        }
    }
}

extension ImportReportGroup {
    public var title: String {
        switch self {
        case .ignored: "Will be ignored"
        case .notSupported: "Not supported"
        case .securityWarning: "Security warnings"
        case .note: "Changed by LockPlus"
        }
    }
}

/// Why an item is in the report. Stable, Codable; `message` gives the plain-language English text.
public enum ImportReason: Codable, Sendable, Hashable {
    // MARK: file-level
    case fileTooLarge(limitBytes: Int)
    case containsNULByte
    /// The tokenizer refused the file. `detail` is the tokenizer's text (line and rule, no argument).
    case syntax(detail: String)
    case invalidUTF8
    case controlCharacters
    case notAClientProfile
    case noRemote
    case limitExceeded(limit: ImportLimit)

    // MARK: OpenVPN, not supported / forbidden
    /// Not on the allowlist, or a refused form; `detail` is the allowlist text (directive name only).
    case forbidden(detail: String)
    case tapNotSupported
    case outdatedCipher(name: String?)
    case cipherNone
    case unknownCipher(name: String?)
    case weakDigest(name: String?)
    case unknownDigest(name: String?)
    case separateRemotePortNotSupported      // rport
    case protoForceNotSupported
    case socksProxyNotSupported
    case fragmentNotSupported
    case pkcs12NotSupported
    case engineRejects(category: String)     // any other `.unsupported` table entry
    case notSupportedInsideConnection
    case httpProxyNeedsTCPRemote
    case proxyOptionWithoutProxy
    case proxyAuthNeedsInlineCredentials
    case tlsClientNeedsPull
    case inlineBodyLineStartsWithCloseTag
    case inlineCredentialsMalformed
    case staticChallengeMalformed
    case privilegedLocalPort
    case parserDisagreement                  // [6]
    case engineValidationFailed(category: String)   // [7]
    /// 2.0.2: the validator service died twice checking this file (`LPErrorCode.profileCheckCrashed`). Not supported.
    case checkCrashed

    // MARK: OpenVPN, ignored / dropped
    case loggingManaged
    case reconnectManaged
    case persistenceNotNeeded
    case localBindingNotUsed
    case cipherNegotiationAutomatic
    case scriptsNeverRun
    case windowsOnly
    case unixAccountNotUsed
    case setByServer
    case serverOnlyOption
    case verifyHashNotSupported
    case dnsManagedByLockPlus
    case keepaliveTakesPrecedence
    case compressionPolicyManaged
    case legacyProvidersNeverLoaded
    case pingTimerRemNotNeeded
    /// Fallback for an engine-ignored option nobody reviewed: NOT harmless (fail safe).
    case engineIgnores
    case cipherListNotApplied                // data-ciphers / ncp-ciphers / data-ciphers-fallback
    case compressionNotEnforced              // allow-compression no (or bare)
    case rekeyReplayTuningNotApplied         // reneg-bytes / reneg-pkts / replay-window
    case routeGatewayManaged
    case mtuManaged
    case routingManaged
    case engineManagesItself
    case obsoleteOption
    case tlsVersionCapIgnored
    case webSignInNotSupported               // setenv IV_SSO stripped

    // MARK: OpenVPN, notes
    case duplicateKeptLast
    case devRewrittenToTun
    case remoteCertEKUAppended
    case keepaliveFloorAppended
    case mssfixFloorAppended
    case authNocacheAppended
    case credentialsExtracted
    case proxyCredentialsExtracted
    case routeGatewayRewritten
    case routeFormIgnoredByEngine
    case setenvOptClassifiedAsDirective

    // MARK: security warnings
    case serverIdentityNotPinned
    case legacyCBCEncryption
    case compressionEnabled
    case serverOnOtherNetwork(interface: String)
    /// PENDING-FOLD 51: the `http-proxy` is a hostname that didn't resolve at import.
    case proxyHostUnresolved

    // MARK: WireGuard
    case wgHookNeverRun
    case wgSettingNotApplied                 // Table, FwMark, SaveConfig
    case wgUnknownKeyPreserved
    case wgSemicolonLineSkipped
    case wgHostBitsNormalized
    case wgMTUAbove9000
    case wgKeepaliveSuggested
    case wgInvalid(field: String, problem: WGProblem)
    case wgSyntax(detail: String)

    // MARK: migration
    case migrationAutoReconnectReplaced
    case migrationPerNetworkProfilesNotSupported
    case migrationDNSAlwaysTunnelled
    case migrationSavedPasswordInSystemKeychain

    /// Reasons that are harmless as an ignored line: LockPlus manages logging, reconnects, DNS, routes and packet size itself,
    /// and local binding, Windows and server options never applied on a Mac client. Everything else ignored changes
    /// behaviour, including the `.engineIgnores` fallback (an unreviewed option is "not applied", never "not needed").
    public var isHarmlessWhenIgnored: Bool {
        switch self {
        case .loggingManaged, .reconnectManaged, .persistenceNotNeeded, .localBindingNotUsed, .cipherNegotiationAutomatic,
             .windowsOnly, .unixAccountNotUsed, .setByServer, .serverOnlyOption, .dnsManagedByLockPlus, .keepaliveTakesPrecedence,
             .compressionPolicyManaged, .legacyProvidersNeverLoaded, .pingTimerRemNotNeeded, .routeGatewayManaged, .mtuManaged, .routingManaged, .engineManagesItself, .obsoleteOption,
             .tlsVersionCapIgnored:
            true
        default: false
        }
    }

    public func message(profileName: String? = nil) -> String {
        let file = profileName.map { "\($0) uses" } ?? "This profile uses"
        switch self {
        case .fileTooLarge(let n): return "The file is larger than \(n / 1024) KB."
        case .containsNULByte: return "The file contains a NUL byte, so it isn't a text profile."
        case .syntax(let d): return "The file can't be read: \(d)."
        case .invalidUTF8: return "This line contains text that isn't valid UTF-8."
        case .controlCharacters: return "This line contains control characters."
        case .notAClientProfile: return "This looks like a server configuration, not a client profile."
        case .noRemote: return "The profile names no server (`remote`)."
        case .limitExceeded(let l): return l.message
        case .forbidden(let d): return "Not allowed in imported profiles: \(d)."
        case .tapNotSupported: return "It needs a TAP adapter, which macOS doesn't support."
        case .outdatedCipher(let n):
            return "\(file) \(n ?? "a 64-bit block cipher"), an outdated cipher LockPlus doesn't support. Ask the server's operator to enable AES-GCM."
        case .cipherNone: return "\(file) no encryption (`cipher none`). LockPlus doesn't support unencrypted tunnels."
        case .unknownCipher(let n): return "\(file) the cipher \(n ?? "named here"), which LockPlus doesn't support. Ask the server's operator to enable AES-GCM."
        case .weakDigest(let n): return "\(file) \(n ?? "a digest under 160 bits"), an outdated message digest LockPlus doesn't support."
        case .unknownDigest(let n): return "\(file) the digest \(n ?? "named here"), which LockPlus doesn't support."
        case .separateRemotePortNotSupported: return "A separate remote port isn't supported; put the port on the `remote` line."
        case .protoForceNotSupported: return "Forcing a protocol isn't supported; set `proto` instead."
        case .socksProxyNotSupported: return "SOCKS proxies aren't supported."
        case .fragmentNotSupported: return "The server requires fragmentation, which LockPlus doesn't support."
        case .pkcs12NotSupported: return "PKCS#12 bundles aren't supported; embed <cert> and <key> instead."
        case .engineRejects(let c): return "LockPlus's OpenVPN engine doesn't support this option (\(c))."
        case .notSupportedInsideConnection: return "Not supported inside <connection>: only remote, port and proto are."
        case .httpProxyNeedsTCPRemote: return "An HTTP proxy needs a TCP server, but every `remote` here uses UDP."
        case .proxyOptionWithoutProxy: return "Proxy settings without an `http-proxy` line."
        case .proxyAuthNeedsInlineCredentials: return "The proxy needs a username and password; embed them as <http-proxy-user-pass>."
        case .tlsClientNeedsPull: return "`tls-client` needs `pull` (or use `client`)."
        case .inlineBodyLineStartsWithCloseTag: return "An embedded block has a line starting with \"</\"."
        case .inlineCredentialsMalformed: return "The embedded username and password are not on two lines, or are too long."
        case .staticChallengeMalformed: return "The one-time-code prompt (`static-challenge`) is malformed."
        case .privilegedLocalPort: return "Binding a local port below 1024 isn't allowed; use `remote host port` for the server port."
        case .parserDisagreement: return "The profile parses differently in LockPlus's OpenVPN engine (parser disagreement)."
        case .engineValidationFailed(let c): return "LockPlus's OpenVPN engine rejected the profile (\(c))."
        case .checkCrashed: return "LockPlus couldn't check this file safely."
        case .loggingManaged: return "logging is managed by LockPlus"
        case .reconnectManaged: return "LockPlus handles reconnecting"
        case .persistenceNotNeeded: return "not needed; LockPlus keeps the tunnel up itself"
        case .localBindingNotUsed: return "local port binding isn't used"
        case .cipherNegotiationAutomatic: return "ciphers are negotiated automatically"
        case .scriptsNeverRun: return "scripts never run in LockPlus"
        case .windowsOnly: return "Windows-only option"
        case .unixAccountNotUsed: return "not used on macOS"
        case .setByServer: return "set by the server"
        case .serverOnlyOption: return "a server option; not needed by a client"
        case .verifyHashNotSupported: return "not supported; the certificate chain is still verified, use peer-fingerprint to pin the server"
        case .dnsManagedByLockPlus: return "DNS is managed by LockPlus"
        case .keepaliveTakesPrecedence: return "keepalive is set, which takes precedence"
        case .compressionPolicyManaged: return "LockPlus decides compression itself"
        case .legacyProvidersNeverLoaded: return "outdated algorithms are never enabled"
        case .pingTimerRemNotNeeded: return "only matters for point-to-point setups"
        case .engineIgnores: return "not used by LockPlus's OpenVPN engine"
        case .cipherListNotApplied: return "your cipher list isn't applied; LockPlus's engine negotiates the cipher itself"
        case .compressionNotEnforced: return "LockPlus accepts compressed data from the server (asym); “no” isn't enforced"
        case .rekeyReplayTuningNotApplied: return "rekey/replay tuning isn't applied; LockPlus uses the engine's defaults"
        case .routeGatewayManaged: return "LockPlus routes via the tunnel gateway"
        case .mtuManaged: return "packet size is managed by LockPlus"
        case .routingManaged: return "routes are managed by LockPlus"
        case .engineManagesItself: return "the OpenVPN engine handles this itself"
        case .obsoleteOption: return "obsolete; the server decides about IPv6"
        case .tlsVersionCapIgnored: return "only caps the TLS version; the engine's own limits apply"
        case .webSignInNotSupported: return "web sign-in isn't supported; the setting is removed"
        case .duplicateKeptLast: return "repeated; the last occurrence is used"
        case .devRewrittenToTun: return "set to `dev tun`"
        case .remoteCertEKUAppended: return "added `remote-cert-eku \"TLS Web Server Authentication\"` to enforce the server role"
        case .keepaliveFloorAppended: return "added `ping 10` / `ping-restart 60` so a dead connection is noticed"
        case .mssfixFloorAppended: return "added `mssfix 1300` so large packets get through"
        case .authNocacheAppended: return "added `auth-nocache`, so one-time codes are never re-sent"
        case .credentialsExtracted: return "the embedded username and password are stored in the keychain, not in the profile"
        case .proxyCredentialsExtracted: return "the embedded proxy credentials are stored in the keychain, not in the profile"
        case .routeGatewayRewritten: return "the route's gateway is replaced by the VPN gateway"
        case .routeFormIgnoredByEngine: return "this route form is ignored by the OpenVPN engine"
        case .setenvOptClassifiedAsDirective: return "`setenv opt` is treated as the option it names"
        case .serverIdentityNotPinned:
            return "Server identity not pinned: any certificate from this profile's CA would be accepted (no `remote-cert-tls` or `verify-x509-name`)."
        case .legacyCBCEncryption: return "Legacy encryption: this profile uses CBC instead of AES-GCM."
        case .compressionEnabled: return "Compression is enabled; LockPlus only decompresses (VORACLE)."
        case .serverOnOtherNetwork(let i):
            return "This server is reached through \(i). LockPlus's tunnel can only use your main network (Wi-Fi or Ethernet), so it may not connect."
        case .proxyHostUnresolved:
            return "The proxy is given by name, and that name couldn't be looked up. LockPlus looks it up before each connect; with the kill switch on, it can't connect while the lookup fails. Use the proxy's IP address to avoid this."
        case .wgHookNeverRun: return "scripts never run in LockPlus"
        case .wgSettingNotApplied: return "not applied on macOS"
        case .wgUnknownKeyPreserved: return "unknown key; kept for export, not applied"
        case .wgSemicolonLineSkipped: return "lines starting with ';' are skipped"
        case .wgHostBitsNormalized: return "an address with host bits set is used as its network address"
        case .wgMTUAbove9000: return "the MTU is above 9000"
        case .wgKeepaliveSuggested: return "consider PersistentKeepalive = 25 so the kill switch notices a dead connection"
        case .wgInvalid(let f, let p): return "\(f): \(p.message)"
        case .wgSyntax(let d): return "The file can't be read: \(d)."
        case .migrationAutoReconnectReplaced: return "Auto-reconnect is now built in; \"Stay connected\" is off."
        case .migrationPerNetworkProfilesNotSupported: return "Per-network profile choices aren't supported yet."
        case .migrationDNSAlwaysTunnelled: return "DNS now always goes through the tunnel."
        case .migrationSavedPasswordInSystemKeychain:
            return "A saved password from an older version can't be imported; enter it again on first connect."
        }
    }
}

/// A named import cap (§3.5, §8.1 [5]): "over ⇒ reject with the limit named".
public enum ImportLimit: Codable, Sendable, Hashable {
    case profileSize          // openvpn3 MAX_PROFILE_SIZE accounting
    case lineLength           // openvpn3 MAX_LINE_SIZE (512)
    case directiveLineLength  // canonical directive line (254, the 2.x tokenizer)
    case directiveNameLength  // 64
    case connectionBlockSize  // 4096
    case rawFileSize          // 1 MiB (.ovpn) / 64 KiB (.conf)

    public var message: String {
        switch self {
        case .profileSize: "The profile is too large for the OpenVPN engine (\(OVPNImportLimits.maxProfileAccounting) bytes, counted the engine's way)."
        case .lineLength: "A line is longer than \(OVPNImportLimits.maxPhysicalLineBytes) bytes."
        case .directiveLineLength: "An option line is longer than \(OVPNImportLimits.maxCanonicalDirectiveLineBytes) bytes."
        case .directiveNameLength: "An option name is longer than \(OVPNImportLimits.maxDirectiveNameBytes) characters."
        case .connectionBlockSize: "A <connection> block is larger than \(OVPNImportLimits.maxConnectionBlockBytes) bytes."
        case .rawFileSize: "The file is too large."
        }
    }
}

/// WireGuard validator problems (port of validator.go), without values.
public enum WGProblem: String, Codable, Sendable, Hashable {
    case required, invalidKey, invalidCIDR, prefixTooLong, invalidDNSEntry, invalidEndpoint, invalidEndpointHost,
         invalidEndpointPort, mtuOutOfRange, listenPortOutOfRange, keepaliveOutOfRange, invalidTable, invalidFwMark,
         containsNewline, noPeers, duplicatePeer, notANumber

    public var message: String {
        switch self {
        case .required: "required"
        case .invalidKey: "invalid key format (must be Base64-encoded 32 bytes)"
        case .invalidCIDR: "invalid CIDR format"
        case .prefixTooLong: "prefix length too long (max 32 for IPv4, 128 for IPv6)"
        case .invalidDNSEntry: "invalid DNS entry (not an IP or hostname)"
        case .invalidEndpoint: "invalid endpoint format (expected host:port)"
        case .invalidEndpointHost: "invalid endpoint host (not an IP or hostname)"
        case .invalidEndpointPort: "invalid endpoint port"
        case .mtuOutOfRange: "MTU must be between 576 and 65535"
        case .listenPortOutOfRange: "ListenPort must be between 1 and 65535"
        case .keepaliveOutOfRange: "must be between 0 and 65535, or off"
        case .invalidTable: "must be \"off\", \"auto\", or a table number"
        case .invalidFwMark: "must be \"off\" or a decimal/hex number"
        case .containsNewline: "contains a newline"
        case .noPeers: "at least one [Peer] section is required"
        case .duplicatePeer: "the same public key appears in two [Peer] sections"
        case .notANumber: "not a number"
        }
    }
}

/// The ✔/⚠/✖ verdict of one import (single file, zip entry or migrated tunnel).
public enum ImportVerdict: String, Codable, Sendable, Hashable {
    case imported
    case importedWithWarnings
    case rejected

    public init(report: ImportReport) {
        if report.blocksImport { self = .rejected } else if report.items.contains(where: { $0.group == .securityWarning || $0.isNotApplied }) {
            self = .importedWithWarnings
        } else {
            self = .imported
        }
    }
}
