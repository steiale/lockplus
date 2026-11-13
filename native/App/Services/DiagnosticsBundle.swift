import Foundation
import LPModel

/// Everything the bundle reads, gathered once (DESIGN §14.2). Plain values; `DiagnosticsBundle.files` is pure.
struct DiagnosticsInputs: Sendable {
    struct ProfileFacts: Sendable {
        var id: UUID
        var name: String
        var kind: String
        var endpoints: [String]
        var isFullTunnel: Bool
        var dnsServers: [String]
        var policy: NetworkPolicy
        var engineVerified: Bool
        var importReport: [String]
    }
    struct ManagerFacts: Sendable {
        var profileID: UUID
        var status: String
        var onDemandEnabled: Bool
        var flags: [String: Bool]
        var onDemandRules: [String]
        var probeHosts: [String]
    }

    var system: [String: String] = [:]
    var profiles: [ProfileFacts] = []
    var managers: [ManagerFacts] = []
    var appLog: [LogLine] = []
    var tunnelLog: Result<[LogLine], LogReadGap> = .success([])
    var scutilDNS: String?
    var routes: String?
    var history: [HistoryEntry] = []
    var crashReports: [(name: String, text: String)] = []
    /// §4.5 findings (JSON), when available.
    var legacy: String?
    /// 2.0.2: the last connection self-test (`SelfTestReport.bundleText()`), when the user ran one this session.
    var selfTest: String?
    /// SSIDs, profile names and saved user names: hashed wherever they appear.
    var sensitive: [String] = []
}

/// The §14.2 diagnostics bundle: one Redactor for every file, the same salt across files.
enum DiagnosticsBundle {
    struct File: Sendable, Equatable, Identifiable {
        var name: String
        var data: Data
        var id: String { name }
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    /// The Redactor for this bundle: DNS server IPs, tunnel routes, the default gateway and the probe hosts stay
    /// readable (§14.2 "what is kept"); everything sensitive is hashed with one salt.
    static func redactor(for i: DiagnosticsInputs, salt: Data? = nil) -> Redactor {
        var keep = Set<String>()
        if let dns = i.scutilDNS { for r in DNSVerifier.parse(dns) { r.nameservers.forEach { keep.insert(DNSVerifier.normalize($0)); keep.insert($0) } } }
        for p in i.profiles { p.dnsServers.forEach { keep.insert(DiagnosticsStore.stripPort($0)) } }
        if let routes = i.routes {
            for r in RouteTable.parse(routes) where r.viaTunnel || r.destination == "default" {
                keep.insert(r.destination)
                keep.insert(r.gateway)
            }
        }
        for m in i.managers { m.probeHosts.forEach { keep.insert($0) } }
        keep.formUnion(["www.apple.com"])
        return salt.map { Redactor(salt: $0, keep: keep, sensitive: i.sensitive) } ?? Redactor(keep: keep, sensitive: i.sensitive)
    }

    static func files(_ i: DiagnosticsInputs, redactor r: Redactor) -> [File] {
        var out: [File] = []
        // FA-L6: the "kept" literals (DNS server IPs, tunnel routes, the gateway) stay readable only in dns.txt and
        // routes.txt; every other file hashes them like any address.
        var base = r
        base.keep = []
        func add(_ name: String, _ text: String, keeping: Bool = false) {
            out.append(File(name: name, data: Data((keeping ? r : base).redact(text).utf8)))
        }
        func json(_ v: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }

        add("system.json", json(i.system))
        add("profiles.json", json(i.profiles.map { p -> [String: Any] in
            [
                "id": p.id.uuidString,
                "name": r.hash(p.name, kind: "name"),
                "kind": p.kind,
                "endpoints": p.endpoints.map { endpoint($0, base) },
                "fullTunnel": p.isFullTunnel,
                "dnsServers": p.dnsServers.map { base.redact($0) },
                "engineVerified": p.engineVerified,
                "policy": [
                    "killSwitch": p.policy.killSwitch, "allowLAN": p.policy.allowLAN, "dnsMode": p.policy.dnsMode.rawValue,
                    "blockIPv6WithoutKillSwitch": p.policy.blockIPv6WithoutKillSwitch, "stayConnected": p.policy.stayConnected,
                    "mtuOverride": p.policy.mtuOverride.map { $0 as Any } ?? NSNull(),
                ] as [String: Any],
                "importReport": p.importReport,
            ]
        }))
        add("ne-configs.json", json(i.managers.map { m -> [String: Any] in
            ["profileID": m.profileID.uuidString, "status": m.status, "onDemandEnabled": m.onDemandEnabled, "flags": m.flags,
             "onDemandRules": m.onDemandRules, "probeHosts": m.probeHosts]
        }))
        add("logs-app.txt", i.appLog.map(line).joined(separator: "\n"))
        switch i.tunnelLog {
        case .success(let l):
            add("logs-tunnel.txt", l.map(line).joined(separator: "\n"))
        case .failure(let g):
            add("logs-tunnel.txt", "Tunnel logs are not included: \(g.reason)\n"
                + "To add them yourself (macOS hides private values): log show --last 24h --predicate 'subsystem == \"\(LogSubsystem.tunnel)\"'")
        }
        add("dns.txt", i.scutilDNS ?? "scutil --dns did not run", keeping: true)
        add("routes.txt", i.routes ?? "netstat -rn did not run", keeping: true)
        add("history-summary.json", json(historySummary(i.history)))
        for c in i.crashReports { add("crash/" + c.name, c.text) }
        if let legacy = i.legacy { add("legacy.json", legacy) }
        if let selfTest = i.selfTest { add("selftest.txt", selfTest) }
        return out
    }

    /// `host#hash:port` (§14.2); IP literals are hashed by the Redactor's address rule unless kept.
    static func endpoint(_ e: String, _ r: Redactor) -> String {
        let (host, port): (String, String?) = {
            if e.hasPrefix("["), let close = e.firstIndex(of: "]") {
                let h = String(e[e.index(after: e.startIndex)..<close])
                let rest = e[e.index(after: close)...]
                return (h, rest.hasPrefix(":") ? String(rest.dropFirst()) : nil)
            }
            if e.filter({ $0 == ":" }).count == 1, let c = e.lastIndex(of: ":") { return (String(e[..<c]), String(e[e.index(after: c)...])) }
            return (e, nil)
        }()
        let isIP = host.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
        let h = r.keep.contains(host) ? host : r.hash(host.lowercased(), kind: isIP ? (host.contains(":") ? "ip6" : "ip") : "host")
        return port.map { "\(h):\($0)" } ?? h
    }

    static func line(_ l: LogLine) -> String {
        let lvl = switch l.level { case .debug: "D"; case .info: "I"; case .warning: "W"; case .error: "E" }
        return "\(l.date.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true))) \(lvl) [\(l.category)] \(l.message)"
    }

    /// Counts only (§14.2).
    static func historySummary(_ h: [HistoryEntry]) -> [String: Any] {
        var reasons: [String: Int] = [:]
        for e in h {
            let k = switch e.endReason {
            case .user: "user"
            case .error: "error"
            case .sleep: "sleep"
            case .onDemand: "onDemand"
            case .replaced: "replaced"
            case .other: "other"
            }
            reasons[k, default: 0] += 1
        }
        return ["sessions": h.count, "endReasons": reasons, "open": h.filter { $0.end == nil }.count]
    }
}

/// `netstat -rn` (read-only, as the user) for routes.txt and the Diagnostics routes table.
enum RouteTable {
    static func parse(_ text: String) -> [RouteRow] {
        var out: [RouteRow] = []
        var inTable = false
        for raw in text.split(separator: "\n") {
            let cols = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if cols.first == "Destination" { inTable = true; continue }
            if raw.hasPrefix("Internet") || raw.hasPrefix("Routing") { inTable = false; continue }
            guard inTable, cols.count >= 4 else { continue }
            let netif = cols[3]
            out.append(RouteRow(destination: cols[0], gateway: cols[1], interface: netif, viaTunnel: netif.hasPrefix("utun")))
        }
        return out
    }

    /// Interfaces other than ours that carry a default route ("Other VPNs", UI-CONCEPT §6.11).
    static func otherDefaultTunnels(_ rows: [RouteRow]) -> Set<String> {
        Set(rows.filter { $0.viaTunnel && ($0.destination == "default" || $0.destination == "0/1" || $0.destination == "128.0/1") }.map(\.interface))
    }
}
