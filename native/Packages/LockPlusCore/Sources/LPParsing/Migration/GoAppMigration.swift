import Foundation
import LPModel

// The Go-app migration reader (DESIGN §13.1, L-MIG-1). Copy-only: nothing in the Go directories is ever written,
// moved or deleted. This module reads and maps; the app's `GoAppMigrator` creates profiles, stores credentials
// (§6.7), writes settings and the migration marker.
//
// Go formats (internal/storage, internal/history, internal/wifi):
//   ~/Library/Application Support/lockplus/            config.json, wifi_rules.json, history.json
//   ~/Library/Application Support/lockplus/tunnels/    <name>.conf (WG), <name>.ovpn (OVPN), <name>.meta.json
// `.ovpn` presence is authoritative for the protocol (Go `LoadMeta`).

// MARK: data source

/// One directory entry, from lstat (symlinks are never followed).
public struct GoAppEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case regular, symlink, directory, other }
    public var name: String
    public var kind: Kind
    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// Read-only access to a Go app data directory. Tests use an in-memory source; the app uses `GoAppDirectory`.
public protocol GoAppDataSource: Sendable {
    /// For the migration marker (`source: path`).
    var sourceDescription: String { get }
    func tunnelEntries() throws -> [GoAppEntry]
    /// At most `maxBytes + 1` bytes, so the caller can detect "too large".
    func readTunnelFile(_ name: String, maxBytes: Int) throws -> [UInt8]
    /// `config.json`, `wifi_rules.json`, `history.json`; nil when absent.
    func readDataFile(_ name: String, maxBytes: Int) throws -> [UInt8]?
    /// Lower wins when two tunnel files carry the same payload (migration matrix: LockPlus's directory before
    /// WireGuide+'s). Default 0.
    func tunnelPriority(_ name: String) -> Int
}

extension GoAppDataSource {
    public func tunnelPriority(_ name: String) -> Int { 0 }
}

/// Migration matrix (2026-11-09): LockPlus 1.0.57+ keeps its data in `…/lockplus`, WireGuide+ 1.0.1–1.0.56 in
/// `…/wireguide-plus`, and Go copied only the tunnels across (1.0.62+, and only when that version ran). The union of
/// both: tunnels by base name with `lockplus` winning a name clash (and on equal payloads, `tunnelPriority`), unless
/// `lockplus/tunnels/.legacy-migrated` says Go already copied them (then the user's later deletions in `lockplus`
/// count and `wireguide-plus` adds no tunnels). `config.json`, `wifi_rules.json` and `history.json` come from
/// `lockplus`, else from `wireguide-plus`. Upstream WireGuide's `…/wireguide` is never part of it.
public struct GoAppMergedSource: GoAppDataSource {
    public let primary: any GoAppDataSource
    public let secondary: (any GoAppDataSource)?
    public let secondaryTunnelsCopied: Bool

    public init(primary: any GoAppDataSource, secondary: (any GoAppDataSource)?, secondaryTunnelsCopied: Bool = false) {
        self.primary = primary
        self.secondary = secondary
        self.secondaryTunnelsCopied = secondaryTunnelsCopied
    }

    public var sourceDescription: String { primary.sourceDescription }

    /// `Home.conf`, `Home.ovpn`, `Home.meta.json` → `Home`; anything else is its own base.
    static func base(_ name: String) -> String {
        for suffix in [".meta.json", ".conf", ".ovpn"] where name.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    private var primaryEntries: [GoAppEntry] { (try? primary.tunnelEntries()) ?? [] }
    private var secondaryEntries: [GoAppEntry] {
        guard let secondary, !secondaryTunnelsCopied else { return [] }
        return (try? secondary.tunnelEntries()) ?? []
    }

    public func tunnelEntries() throws -> [GoAppEntry] {
        let first = primaryEntries
        let taken = Set(first.map { Self.base($0.name) })
        let second = secondaryEntries.filter { !taken.contains(Self.base($0.name)) }
        if first.isEmpty && second.isEmpty, (try? primary.tunnelEntries()) == nil, (try? secondary?.tunnelEntries()) == nil {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return (first + second).sorted { $0.name < $1.name }
    }

    private func owner(_ name: String) -> (any GoAppDataSource)? {
        let b = Self.base(name)
        if primaryEntries.contains(where: { Self.base($0.name) == b }) { return primary }
        if secondaryEntries.contains(where: { Self.base($0.name) == b }) { return secondary }
        return nil
    }

    public func readTunnelFile(_ name: String, maxBytes: Int) throws -> [UInt8] {
        guard let src = owner(name) else { throw CocoaError(.fileNoSuchFile) }
        return try src.readTunnelFile(name, maxBytes: maxBytes)
    }

    public func readDataFile(_ name: String, maxBytes: Int) throws -> [UInt8]? {
        if let b = try primary.readDataFile(name, maxBytes: maxBytes) { return b }
        return try secondary?.readDataFile(name, maxBytes: maxBytes)
    }

    public func tunnelPriority(_ name: String) -> Int {
        primaryEntries.contains { Self.base($0.name) == Self.base(name) } ? 0 : 1
    }
}

/// The real Go data directory. Reads with O_NOFOLLOW and refuses anything but regular files.
public struct GoAppDirectory: GoAppDataSource {
    public let root: URL
    public var sourceDescription: String { root.path }
    var tunnelsDir: URL { root.appending(path: "tunnels", directoryHint: .isDirectory) }

    public init(root: URL) { self.root = root }

    /// §13.1 step 1 (migration matrix): the union of `lockplus` and `wireguide-plus` (`GoAppMergedSource`), or nil when
    /// neither has a tunnel. Upstream WireGuide's `wireguide` is never read here (`upstreamWireGuideHasTunnels`).
    public static func locate(applicationSupport: URL) -> GoAppMergedSource? {
        let lp = GoAppDirectory(root: applicationSupport.appending(path: "lockplus", directoryHint: .isDirectory))
        let wgp = GoAppDirectory(root: applicationSupport.appending(path: "wireguide-plus", directoryHint: .isDirectory))
        guard lp.hasTunnels || wgp.hasTunnels else { return nil }
        var st = stat()
        let copied = lstat(lp.tunnelsDir.appending(path: ".legacy-migrated").path, &st) == 0
        return GoAppMergedSource(primary: lp, secondary: wgp, secondaryTunnelsCopied: copied)
    }

    /// Upstream WireGuide (and WireGuide+ 1.0.0, which used its names) keeps tunnels in `…/wireguide/tunnels`: never
    /// imported automatically; the migration report says how to import them by hand.
    public static func upstreamWireGuideHasTunnels(applicationSupport: URL) -> Bool {
        GoAppDirectory(root: applicationSupport.appending(path: "wireguide", directoryHint: .isDirectory)).hasTunnels
    }

    var hasTunnels: Bool {
        ((try? tunnelEntries()) ?? []).contains { GoMigrationReader.tunnelKind(of: $0.name) != nil }
    }

    public func tunnelEntries() throws -> [GoAppEntry] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: tunnelsDir.path)
        return names.sorted().map { n in
            var st = stat()
            let p = tunnelsDir.appending(path: n).path
            guard lstat(p, &st) == 0 else { return GoAppEntry(name: n, kind: .other) }
            switch st.st_mode & S_IFMT {
            case S_IFREG: return GoAppEntry(name: n, kind: .regular)
            case S_IFLNK: return GoAppEntry(name: n, kind: .symlink)
            case S_IFDIR: return GoAppEntry(name: n, kind: .directory)
            default: return GoAppEntry(name: n, kind: .other)
            }
        }
    }

    public func readTunnelFile(_ name: String, maxBytes: Int) throws -> [UInt8] {
        guard let b = try Self.read(tunnelsDir, name, maxBytes) else { throw CocoaError(.fileNoSuchFile) }
        return b
    }

    public func readDataFile(_ name: String, maxBytes: Int) throws -> [UInt8]? {
        try Self.read(root, name, maxBytes)
    }

    static func read(_ dir: URL, _ name: String, _ maxBytes: Int) throws -> [UInt8]? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let fd = open(dir.appending(path: name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count <= maxBytes {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            out += buf[0..<min(n, maxBytes + 1 - out.count)]
        }
        return out
    }
}

// MARK: Go JSON shapes

struct GoSettingsJSON: Decodable {
    var language: String?
    var theme: String?
    var tray_icon_style: String?
    var auto_start: Bool?
    var kill_switch: Bool?
    var dns_protection: Bool?
    var log_level: String?
    var onboarding_complete: Bool?
    var kofi_dismissed: Bool?
}

struct GoWifiRulesJSON: Decodable {
    var enabled: Bool?
    var default_tunnel: String?
    var auto_connect_untrusted: Bool?
    var trusted_ssids: [String]?
    var ssid_tunnel_map: [String: String]?
}

struct GoSessionJSON: Decodable {
    var id: String?
    var tunnel_name: String?
    var start_time: String?
    var end_time: String?
    var rx_bytes: Int64?
    var tx_bytes: Int64?
    var disconnect_reason: String?
}

struct GoTunnelMetaJSON: Decodable {
    var auto_reconnect: Bool?
    var notes: String?
    var `protocol`: String?
}

// MARK: plan

public enum MigratedLanguage: String, Sendable, Equatable { case system, en, de, ko, ja }
/// Go `theme`; anything else is `.system`.
public enum MigratedAppearance: String, Sendable, Equatable { case system, light, dark }
public enum MigratedLogLevel: String, Sendable, Equatable { case debug, info, warn, error }
public enum MigratedMenuBarIconStyle: String, Sendable, Equatable { case monochrome, color }

/// §13.1 step 6.
public struct MigratedSettings: Sendable, Equatable {
    public var language: MigratedLanguage = .system
    public var appearance: MigratedAppearance = .system
    public var logLevel: MigratedLogLevel = .info
    public var menuBarIconStyle: MigratedMenuBarIconStyle = .color
    public var onboardingComplete = true
    /// Go `auto_start`: offer "Launch at login?" (never auto-register, NR §4 pitfall 14).
    public var offerLaunchAtLogin = false
    public var supportNoteShown = false
    /// Go `kill_switch` / `dns_protection`, used for the per-profile policy.
    public var killSwitch = false
    public var dnsProtection = false
}

/// §13.1 step 7.
public struct MigratedWifiRules: Sendable, Equatable {
    public var enabled = false
    /// ≤ 64 entries, each ≤ 32 bytes UTF-8 (§3.2); longer ones are dropped.
    public var trustedSSIDs: [String] = []
    /// The Go `default_tunnel`, when `auto_connect_untrusted` is on: the app maps it to a UUID by name.
    public var autoProfileName: String?
    /// The per-SSID map existed (not migrated, §21).
    public var hadPerNetworkProfiles = false
    /// E2E-5 F6: the map itself, for the migration report (network → old tunnel name), sorted by network; entries
    /// whose SSID or tunnel name is empty or too long (32 / 255 bytes) are left out; at most 64.
    public var perNetworkProfiles: [MigratedNetworkChoice] = []
}

/// One `ssid_tunnel_map` entry of the Go app (reported, not migrated).
public struct MigratedNetworkChoice: Sendable, Equatable {
    public var ssid: String
    public var tunnelName: String
    public init(ssid: String, tunnelName: String) {
        self.ssid = ssid
        self.tunnelName = tunnelName
    }
}

/// How a Go session ended. The app maps it to `SessionEndReason` (§3.2): user/appQuit → .user, replaced → .replaced.
public enum GoSessionEndReason: Sendable, Equatable {
    case user, appQuit, replaced, other(String)

    init(_ s: String?) {
        switch s {
        case "user": self = .user
        case "app_quit": self = .appQuit
        case "reconnect", "health_check": self = .replaced
        case let x: self = .other(String((x ?? "").prefix(32)))
        }
    }
}

/// §13.1 step 8. `profileID` is resolved by the app by name match (nil if none).
public struct MigratedSession: Sendable, Equatable {
    public var tunnelName: String
    public var start: Date
    public var end: Date?
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var endReason: GoSessionEndReason
}

public enum MigratedTunnelResult: Sendable {
    case openVPN(OVPNImportResult)
    case wireGuard(WGImportResult)
}

public struct MigratedTunnel: Sendable {
    /// The Go file base name; it becomes the display name (§13.1 step 3).
    public var oldName: String
    public var displayName: String
    public var kind: VPNProtocolKind
    public var result: MigratedTunnelResult
    /// Per-tunnel notes from the migration (auto-reconnect replaced, …), in addition to the import report.
    public var migrationNotes: [ImportReportItem]
    /// Go `.meta.json` notes, ≤ 4 KiB.
    public var notes: String
    /// §13.1 step 4: Go `kill_switch` → `killSwitch` (includeAllNetworks for full tunnels, route protection for split
    /// ones); `dnsMode = .tunnelOnly`; `stayConnected = false` (the extension always reconnects); rest at §3.1 defaults.
    public var policy: NetworkPolicy
    /// A previous migration already imported this payload (manual re-run dedupe by digest, §13.1 step 9).
    public var alreadyImported: Bool

    public var verdict: ImportVerdict {
        switch result {
        case .openVPN(let r): r.verdict
        case .wireGuard(let r): r.verdict
        }
    }

    public var canonicalPayload: String? {
        switch result {
        case .openVPN(let r): r.canonicalText
        case .wireGuard(let r): r.canonicalText
        }
    }

    public var report: ImportReport {
        switch result {
        case .openVPN(let r): r.report
        case .wireGuard(let r): r.report
        }
    }
}

public struct GoMigrationPlan: Sendable {
    public var source: String
    public var tunnels: [MigratedTunnel]
    /// Entries skipped by rule (dotfiles, *.tmp, *.corrupt.*, symlinks, directories, unreadable).
    public var skipped: [String]
    public var settings: MigratedSettings
    public var wifi: MigratedWifiRules
    public var history: [MigratedSession]
    /// Global migration-report lines (appearance, per-network map, DNS).
    public var notes: [ImportReportItem]
}

public enum GoMigrationReader {
    public static let maxHistory = 500
    public static let maxNotesBytes = 4096
    static let maxDataFileBytes = 16 << 20

    /// `.conf` → WireGuard, `.ovpn` → OpenVPN, anything else → nil.
    static func tunnelKind(of name: String) -> VPNProtocolKind? {
        if name.hasSuffix(".ovpn") && name.count > 5 { return .openVPN }
        if name.hasSuffix(".conf") && name.count > 5 { return .wireGuard }
        return nil
    }

    static func skippedByRule(_ e: GoAppEntry) -> Bool {
        e.name.hasPrefix(".") || e.name.hasSuffix(".tmp") || e.name.contains(".corrupt.") || e.kind != .regular
    }

    /// Reads and maps everything. `existingDigests` + `digest` implement the manual re-run dedupe (the digest is the
    /// app's SHA-256 of the canonical payload; LockPlusCore has no CryptoKit, §2.2).
    public static func read(_ src: some GoAppDataSource, existingDigests: Set<String> = [],
                            digest: (@Sendable (String) -> String)? = nil) throws -> GoMigrationPlan {
        var notes: [ImportReportItem] = []
        let settings = readSettings(src, notes: &notes)
        let wifi = readWifi(src, notes: &notes)
        let history = readHistory(src)

        var skipped: [String] = []
        var seenDigests: [String: (priority: Int, index: Int)] = [:]
        var byBase: [String: [VPNProtocolKind: String]] = [:]
        var metas: Set<String> = []
        for e in try src.tunnelEntries() {
            if skippedByRule(e) {
                skipped.append(e.name)
                continue
            }
            if e.name.hasSuffix(".meta.json") {
                metas.insert(e.name)
            } else if let k = tunnelKind(of: e.name) {
                byBase[String(e.name.dropLast(5)), default: [:]][k] = e.name
            }
        }
        var tunnels: [MigratedTunnel] = []
        for base in byBase.keys.sorted() {
            let files = byBase[base]!
            let kind: VPNProtocolKind = files[.openVPN] != nil ? .openVPN : .wireGuard   // .ovpn is authoritative
            let file = files[kind]!
            var meta = GoTunnelMetaJSON()
            if metas.contains(base + ".meta.json"), let b = try? src.readTunnelFile(base + ".meta.json", maxBytes: 64 * 1024),
               b.count <= 64 * 1024, let m = try? JSONDecoder().decode(GoTunnelMetaJSON.self, from: Data(b)) {
                meta = m
            }
            let limit = kind == .openVPN ? OVPNImportLimits.maxRawBytes : WGParser.maxRawBytes
            let bytes: [UInt8]
            do {
                bytes = try src.readTunnelFile(file, maxBytes: limit)
            } catch {
                skipped.append(file)
                continue
            }
            let result: MigratedTunnelResult = kind == .openVPN
                ? .openVPN(OVPNImporter.importProfile(bytes)) : .wireGuard(WGImporter.importProfile(bytes))
            var tnotes: [ImportReportItem] = []
            if meta.auto_reconnect == true { tnotes.append(ImportReportItem(.note, .migrationAutoReconnectReplaced)) }
            var t = MigratedTunnel(oldName: base, displayName: ProfileNameSanitizer.sanitize(base), kind: kind, result: result,
                                   migrationNotes: tnotes, notes: truncateUTF8(meta.notes ?? "", maxNotesBytes),
                                   policy: NetworkPolicy(killSwitch: settings.killSwitch, dnsMode: .tunnelOnly, stayConnected: false),
                                   alreadyImported: false)
            if let digest, let payload = t.canonicalPayload {
                let d = digest(payload)
                if existingDigests.contains(d) { t.alreadyImported = true }
                // Migration matrix: the same payload in both directories (Go copied it, or the user did) is one tunnel;
                // the higher-priority directory's file wins. Within one directory nothing changes.
                let priority = src.tunnelPriority(file)
                if let earlier = seenDigests[d], earlier.priority != priority {   // two names in one directory stay two
                    if priority < earlier.priority {
                        skipped.append(byBase[tunnels[earlier.index].oldName]?.values.first ?? tunnels[earlier.index].oldName)
                        tunnels[earlier.index] = t
                        seenDigests[d] = (priority, earlier.index)
                    } else {
                        skipped.append(file)
                    }
                    continue
                }
                if seenDigests[d] == nil { seenDigests[d] = (priority, tunnels.count) }
            }
            tunnels.append(t)
        }
        return GoMigrationPlan(source: src.sourceDescription, tunnels: tunnels, skipped: skipped, settings: settings,
                               wifi: wifi, history: history, notes: notes)
    }

    /// Adds the §13.1 / §9.3 interface warning to every migrated tunnel whose endpoint is behind a non-primary
    /// interface.
    public static func probeRoutes(_ plan: GoMigrationPlan, probe: any EndpointRouteProbing) async -> GoMigrationPlan {
        var p = plan
        for i in p.tunnels.indices {
            switch p.tunnels[i].result {
            case .openVPN(let r): p.tunnels[i].result = .openVPN(await OVPNImporter.probeRoutes(r, probe: probe))
            case .wireGuard(let r): p.tunnels[i].result = .wireGuard(await WGImporter.probeRoutes(r, probe: probe))
            }
        }
        return p
    }

    // MARK: pieces

    static func readSettings(_ src: some GoAppDataSource, notes: inout [ImportReportItem]) -> MigratedSettings {
        var s = MigratedSettings()
        // Go DefaultSettings: language auto, tray color, log info.
        guard let b = try? src.readDataFile("config.json", maxBytes: maxDataFileBytes), b.count <= maxDataFileBytes,
              let g = try? JSONDecoder().decode(GoSettingsJSON.self, from: Data(b)) else { return s }
        s.language = switch g.language {
        case "en": .en
        case "de": .de
        case "ko": .ko
        case "ja": .ja
        default: .system
        }
        s.appearance = MigratedAppearance(rawValue: g.theme ?? "") ?? .system
        s.logLevel = MigratedLogLevel(rawValue: g.log_level ?? "info") ?? .info
        s.menuBarIconStyle = (g.tray_icon_style ?? "color") == "color" ? .color : .monochrome
        s.offerLaunchAtLogin = g.auto_start ?? false
        s.supportNoteShown = g.kofi_dismissed ?? false
        s.killSwitch = g.kill_switch ?? false
        s.dnsProtection = g.dns_protection ?? false
        if !s.dnsProtection { notes.append(ImportReportItem(.note, .migrationDNSAlwaysTunnelled)) }
        return s
    }

    static func readWifi(_ src: some GoAppDataSource, notes: inout [ImportReportItem]) -> MigratedWifiRules {
        var w = MigratedWifiRules()
        guard let b = try? src.readDataFile("wifi_rules.json", maxBytes: maxDataFileBytes), b.count <= maxDataFileBytes,
              let g = try? JSONDecoder().decode(GoWifiRulesJSON.self, from: Data(b)) else { return w }
        w.enabled = g.enabled ?? false
        var ssids: [String] = []
        for s in g.trusted_ssids ?? [] where !s.isEmpty && s.utf8.count <= 32 && !ssids.contains(s) && ssids.count < 64 {
            ssids.append(s)
        }
        w.trustedSSIDs = ssids
        if g.auto_connect_untrusted == true, let t = g.default_tunnel, !t.isEmpty { w.autoProfileName = t }
        if let map = g.ssid_tunnel_map, !map.isEmpty {
            w.hadPerNetworkProfiles = true
            w.perNetworkProfiles = map.filter { !$0.key.isEmpty && $0.key.utf8.count <= 32 && !$0.value.isEmpty && $0.value.utf8.count <= 255 }
                .sorted { $0.key < $1.key }.prefix(64).map { MigratedNetworkChoice(ssid: $0.key, tunnelName: $0.value) }
            notes.append(ImportReportItem(.note, .migrationPerNetworkProfilesNotSupported))
        }
        return w
    }

    static func readHistory(_ src: some GoAppDataSource) -> [MigratedSession] {
        guard let b = try? src.readDataFile("history.json", maxBytes: maxDataFileBytes), b.count <= maxDataFileBytes,
              let g = try? JSONDecoder().decode([GoSessionJSON].self, from: Data(b)) else { return [] }
        let out: [MigratedSession] = g.compactMap { s in
            guard let name = s.tunnel_name, let st = s.start_time.flatMap(RFC3339.parse) else { return nil }
            return MigratedSession(tunnelName: name, start: st, end: s.end_time.flatMap(RFC3339.parse),
                                   rxBytes: UInt64(max(0, s.rx_bytes ?? 0)), txBytes: UInt64(max(0, s.tx_bytes ?? 0)),
                                   endReason: GoSessionEndReason(s.disconnect_reason))
        }
        return Array(out.sorted { $0.start < $1.start }.suffix(maxHistory))
    }

    static func truncateUTF8(_ s: String, _ max: Int) -> String {
        if s.utf8.count <= max { return s }
        var out = ""
        for c in s {
            if out.utf8.count + String(c).utf8.count > max { break }
            out.append(c)
        }
        return out
    }
}

/// Go `time.Time` JSON (RFC 3339 with optional fraction): YYYY-MM-DDTHH:MM:SS[.f…](Z|±HH:MM).
enum RFC3339 {
    static func parse(_ s: String) -> Date? {
        let b = Array(s.utf8)
        func num(_ r: Range<Int>) -> Int? {
            guard r.upperBound <= b.count else { return nil }
            var v = 0
            for i in r {
                guard b[i] >= 0x30 && b[i] <= 0x39 else { return nil }
                v = v * 10 + Int(b[i] - 0x30)
            }
            return v
        }
        guard b.count >= 20, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x74, b[13] == 0x3A, b[16] == 0x3A,
              let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10), let h = num(11..<13), let mi = num(14..<16),
              let sec = num(17..<19) else { return nil }
        var i = 19
        var frac = 0.0
        if i < b.count && b[i] == 0x2E {
            i += 1
            var scale = 0.1
            let start = i
            while i < b.count, b[i] >= 0x30 && b[i] <= 0x39 {
                frac += Double(b[i] - 0x30) * scale
                scale /= 10
                i += 1
            }
            if i == start { return nil }
        }
        guard i < b.count else { return nil }
        var offset = 0
        if b[i] == 0x5A || b[i] == 0x7A {
            i += 1
        } else if b[i] == 0x2B || b[i] == 0x2D, let oh = num((i + 1)..<(i + 3)), i + 3 < b.count, b[i + 3] == 0x3A,
                  let om = num((i + 4)..<(i + 6)) {
            offset = (oh * 3600 + om * 60) * (b[i] == 0x2D ? -1 : 1)
            i += 6
        } else {
            return nil
        }
        guard i == b.count, (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: sec)) else { return nil }
        return base.addingTimeInterval(frac - Double(offset))
    }
}
