import LPModel
// The WireGuard import pipeline (DESIGN §9.1, §3.5): size cap → parse → validate → normalize → canonical `.conf`.
// The private key and preshared keys stay in the payload, which the app seals (§6.1); nothing is split off.

public struct WGImportResult: Sendable {
    public var verdict: ImportVerdict
    public var report: ImportReport
    /// Validator findings, per field, for the editor (§9.1). Every issue is also a Not-supported report item.
    public var issues: [ValidationIssue]
    public var config: WGConfig?
    /// The canonical payload (nil when rejected).
    public var canonicalText: String?
    public var summary: ProfileSummary
    public var endpoints: [ImportEndpoint]
}

public enum WGImporter {
    public static func importProfile(_ bytes: some Collection<UInt8>) -> WGImportResult {
        var report = ImportReport()
        func rejected(_ issues: [ValidationIssue] = []) -> WGImportResult {
            WGImportResult(verdict: .rejected, report: report, issues: issues, config: nil, canonicalText: nil,
                           summary: ProfileSummary(), endpoints: [])
        }
        if bytes.count > WGParser.maxRawBytes {
            report.add(.notSupported, .fileTooLarge(limitBytes: WGParser.maxRawBytes))
            return rejected()
        }
        let parsed: WGParser.Parsed
        switch WGParser.parse(bytes) {
        case .success(let p): parsed = p
        case .failure(let e):
            report.add(.notSupported, line: e.line, .wgSyntax(detail: e.message))
            return rejected()
        }
        var cfg = parsed.config
        for n in parsed.notes { report.add(n.group, line: n.line, directive: n.directive, n.reason) }
        let issues = WGValidator.validate(cfg)
        for i in issues { report.add(.notSupported, directive: i.field, .wgInvalid(field: i.field, problem: i.problem)) }
        if !issues.isEmpty { return rejected(issues) }

        // normalize: AllowedIPs with host bits → network address, with a warning (§9.1)
        for p in cfg.peers.indices {
            cfg.peers[p].allowedIPs = cfg.peers[p].allowedIPs.map { s in
                guard let pre = try? IPPrefix.parse(s), pre.hasHostBits else { return s }
                report.add(.note, directive: "Peer[\(p)].AllowedIPs", .wgHostBitsNormalized)
                return pre.masked.text
            }
        }
        if let m = cfg.interface.mtu, m > 9000 { report.add(.securityWarning, directive: "MTU", .wgMTUAbove9000) }
        if cfg.isFullTunnel && cfg.peers.contains(where: { ($0.persistentKeepalive ?? 0) == 0 }) {
            report.add(.note, directive: "PersistentKeepalive", .wgKeepaliveSuggested)
        }
        report.supportedCount = supportedKeys(cfg)
        let endpoints: [ImportEndpoint] = cfg.peers.compactMap { p in
            guard let e = p.endpoint, let (h, port) = HostPort.split(e) else { return nil }
            return ImportEndpoint(host: h, port: port, transport: "udp")
        }
        let summary = ProfileSummary(endpoints: endpoints.map(\.display), transport: "udp", addresses: cfg.interface.addresses,
                                     isFullTunnel: cfg.isFullTunnel,
                                     dnsServers: cfg.interface.dns.filter { IPAddress.parse($0) != nil }, usesLegacyCrypto: false)
        return WGImportResult(verdict: ImportVerdict(report: report), report: report, issues: [], config: cfg,
                              canonicalText: WGSerializer.serialize(cfg), summary: summary, endpoints: endpoints)
    }

    /// Adds the §9.3 warning for literal or resolvable endpoints routed through a non-primary interface.
    public static func probeRoutes(_ result: WGImportResult, probe: any EndpointRouteProbing) async -> WGImportResult {
        var r = result
        var seen = Set<ImportEndpoint>()
        let unique = result.endpoints.filter { seen.insert($0).inserted }
        // Concurrent (a slow resolver costs one deadline, not one per endpoint); warnings are added in endpoint order.
        let found = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, e) in unique.enumerated() {
                group.addTask { @Sendable in (i, await probe.nonPrimaryInterface(for: e)) }
            }
            var out: [Int: String] = [:]
            for await (i, iface) in group { if let iface { out[i] = iface } }
            return out
        }
        for i in found.keys.sorted() {
            r.report.add(.securityWarning, directive: "Endpoint", .serverOnOtherNetwork(interface: found[i]!))
        }
        if r.verdict != .rejected { r.verdict = ImportVerdict(report: r.report) }
        return r
    }

    static func supportedKeys(_ c: WGConfig) -> Int {
        let i = c.interface
        var n = 1 + (i.addresses.isEmpty ? 0 : 1) + (i.dns.isEmpty ? 0 : 1) + (i.mtu == nil ? 0 : 1) + (i.listenPort == nil ? 0 : 1)
        for p in c.peers {
            n += 1 + (p.presharedKey == nil ? 0 : 1) + (p.endpoint == nil ? 0 : 1) + (p.allowedIPs.isEmpty ? 0 : 1)
                + (p.persistentKeepalive == nil ? 0 : 1)
        }
        return n
    }
}
