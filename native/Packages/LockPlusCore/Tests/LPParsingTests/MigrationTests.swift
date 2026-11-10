import Foundation
import Testing
@testable import LPParsing
import LPModel

/// An in-memory Go data directory (fixtures only; the real `~/Library/Application Support/lockplus` is never read).
struct MemorySource: GoAppDataSource {
    var sourceDescription = "memory"
    var tunnels: [String: (GoAppEntry.Kind, String)] = [:]
    var data: [String: String] = [:]
    func tunnelEntries() throws -> [GoAppEntry] { tunnels.keys.sorted().map { GoAppEntry(name: $0, kind: tunnels[$0]!.0) } }
    func readTunnelFile(_ name: String, maxBytes: Int) throws -> [UInt8] {
        guard let t = tunnels[name], t.0 == .regular else { throw CocoaError(.fileNoSuchFile) }
        return Array(Array(t.1.utf8).prefix(maxBytes + 1))
    }
    func readDataFile(_ name: String, maxBytes: Int) throws -> [UInt8]? { data[name].map { Array($0.utf8) } }
}

@Suite("Go-app migration reader (§13.1)")
struct MigrationTests {
    static let wg = WGConfigTests.validConf
    static let ovpn = OVPNFixtures.base("cipher AES-256-CBC\nauth-user-pass\n")

    static func source() -> MemorySource {
        var s = MemorySource()
        s.tunnels = [
            "Home.conf": (.regular, wg),
            "Home.meta.json": (.regular, #"{"auto_reconnect": true, "notes": "nas", "protocol": "wireguard"}"#),
            "work.vpn.ovpn": (.regular, ovpn),
            "Both.conf": (.regular, wg),
            "Both.ovpn": (.regular, ovpn),
            "Broken.ovpn": (.regular, "client\nremote h 1\nup /x\n"),
            ".hidden.conf": (.regular, wg),
            "x.conf.tmp": (.regular, wg),
            "y.conf.corrupt.20260101": (.regular, wg),
            "Link.conf": (.symlink, wg),
            "Dir.conf": (.directory, ""),
        ]
        s.data = [
            "config.json": #"{"language":"ko","theme":"dark","tray_icon_style":"mono","auto_start":true,"kill_switch":true,"dns_protection":false,"log_level":"debug","onboarding_complete":true,"kofi_dismissed":true}"#,
            "wifi_rules.json": #"{"enabled":true,"default_tunnel":"Home","auto_connect_untrusted":true,"trusted_ssids":["Office","Office","\#(String(repeating: "x", count: 33))"],"ssid_tunnel_map":{"Cafe":"work.vpn"}}"#,
            "history.json": #"[{"id":"a","tunnel_name":"Home","start_time":"2026-10-25T10:00:00.123456789+02:00","end_time":"2026-10-25T11:00:00Z","duration_sec":3600,"rx_bytes":10,"tx_bytes":20,"disconnect_reason":"user"},{"id":"b","tunnel_name":"work.vpn","start_time":"2026-10-24T09:00:00Z","rx_bytes":-1,"disconnect_reason":"health_check"},{"id":"c","tunnel_name":"x","start_time":"garbage"}]"#,
        ]
        return s
    }

    @Test func tunnelsEnumeratedAndImported() throws {
        let plan = try GoMigrationReader.read(Self.source())
        #expect(plan.tunnels.map(\.oldName) == ["Both", "Broken", "Home", "work.vpn"])
        #expect(Set(plan.skipped) == [".hidden.conf", "x.conf.tmp", "y.conf.corrupt.20260101", "Link.conf", "Dir.conf"])
        let both = plan.tunnels[0]
        #expect(both.kind == .openVPN)   // .ovpn is authoritative
        #expect(plan.tunnels[1].verdict == .rejected)
        let home = plan.tunnels[2]
        #expect(home.kind == .wireGuard && home.verdict != .rejected)
        #expect(home.notes == "nas")
        #expect(home.migrationNotes.map(\.reason) == [.migrationAutoReconnectReplaced])
        #expect(home.policy == NetworkPolicy(killSwitch: true, dnsMode: .tunnelOnly, stayConnected: false))
        #expect(plan.tunnels[3].displayName == "work.vpn")
        #expect(plan.tunnels[3].report.items.contains { $0.reason == .legacyCBCEncryption })
    }

    @Test func settingsMapped() throws {
        let s = try GoMigrationReader.read(Self.source()).settings
        #expect(s.appearance == .dark)
        #expect(s.language == .ko && s.logLevel == .debug && s.menuBarIconStyle == .monochrome)
        #expect(s.onboardingComplete && s.offerLaunchAtLogin && s.supportNoteShown && s.killSwitch)
        let notes = try GoMigrationReader.read(Self.source()).notes.map(\.reason)
        #expect(notes.contains(.migrationDNSAlwaysTunnelled))
        #expect(!notes.contains { "\($0)".contains("Appearance") })            // the choice carries over; no note
        #expect(notes.contains(.migrationPerNetworkProfilesNotSupported))
    }

    @Test func themeParsed() throws {
        for (theme, want) in [("light", MigratedAppearance.light), ("dark", .dark), ("system", .system), ("garbage", .system)] {
            var src = Self.source()
            src.data["config.json"] = #"{"theme":"\#(theme)"}"#
            let p = try GoMigrationReader.read(src)
            #expect(p.settings.appearance == want)
            // The migrated appearance is the Go theme (anything unknown: system), not just "no note about it".
            #expect(p.settings.appearance.rawValue == (["light", "dark"].contains(theme) ? theme : "system"))
        }
    }

    @Test func defaultsWithoutConfig() throws {
        var src = Self.source()
        src.data = [:]
        let p = try GoMigrationReader.read(src)
        #expect(p.settings.language == .system && p.settings.appearance == .system && p.settings.menuBarIconStyle == .color && !p.settings.killSwitch)
        #expect(p.history.isEmpty && !p.wifi.enabled)
    }

    @Test func wifiMapped() throws {
        let w = try GoMigrationReader.read(Self.source()).wifi
        #expect(w.enabled && w.trustedSSIDs == ["Office"] && w.autoProfileName == "Home" && w.hadPerNetworkProfiles)
        #expect(w.perNetworkProfiles == [MigratedNetworkChoice(ssid: "Cafe", tunnelName: "work.vpn")])   // E2E-5 F6: reported
    }

    @Test func historyMapped() throws {
        let h = try GoMigrationReader.read(Self.source()).history
        #expect(h.count == 2)
        #expect(h[0].tunnelName == "work.vpn" && h[0].endReason == .replaced && h[0].rxBytes == 0 && h[0].end == nil)
        #expect(h[1].endReason == .user && h[1].rxBytes == 10)
        // 10:00:00.123456789+02:00 → 08:00:00.123Z; end 11:00Z
        let d = h[1].end!.timeIntervalSince(h[1].start)
        #expect(d > 10799.87 && d < 10799.88)
    }

    @Test func historyCapped() throws {
        var src = Self.source()
        let items = (0..<600).map { #"{"tunnel_name":"t","start_time":"2026-01-01T00:\#(String(format: "%02d", $0 / 60)):\#(String(format: "%02d", $0 % 60))Z"}"# }
        src.data["history.json"] = "[" + items.joined(separator: ",") + "]"
        let h = try GoMigrationReader.read(src).history
        #expect(h.count == 500)
        #expect(h.first!.start < h.last!.start)
    }

    @Test func rerunDedupesByDigest() throws {
        let first = try GoMigrationReader.read(Self.source())
        let digests = Set(first.tunnels.compactMap(\.canonicalPayload).map { String($0.utf8.count) + String($0.hashValue) })
        let again = try GoMigrationReader.read(Self.source(), existingDigests: digests) { String($0.utf8.count) + String($0.hashValue) }
        #expect(again.tunnels.filter(\.alreadyImported).count == first.tunnels.filter { $0.canonicalPayload != nil }.count)
    }

    @Test func routeProbeAddsNote() async throws {
        struct Probe: EndpointRouteProbing {
            func nonPrimaryInterface(for e: ImportEndpoint) async -> String? { e.host == "vpn.example.com" ? "bridge100" : nil }
        }
        let p = await GoMigrationReader.probeRoutes(try GoMigrationReader.read(Self.source()), probe: Probe())
        let home = p.tunnels.first { $0.oldName == "Home" }!
        #expect(home.report.items.contains { $0.reason == .serverOnOtherNetwork(interface: "bridge100") })
    }

    @Test func rfc3339() {
        #expect(RFC3339.parse("2026-10-25T10:00:00Z")?.timeIntervalSince1970 == 1_792_922_400)
        #expect(RFC3339.parse("2026-10-25T12:00:00+02:00")?.timeIntervalSince1970 == 1_792_922_400)
        #expect(RFC3339.parse("2026-10-25T10:00:00.5Z")?.timeIntervalSince1970 == 1_792_922_400.5)
        for bad in ["", "2026-10-25", "2026-10-25T10:00:00", "2026-13-25T10:00:00Z", "2026-10-25T10:00:00.Z", "2026-10-25T10:00:00Zx"] {
            #expect(RFC3339.parse(bad) == nil, "\(bad)")
        }
    }

    /// The FileManager-backed reader on a fixture directory under $LP_BUILD_ROOT (default ~/Code/lockplus-build; never /tmp, never the
    /// owner's real data).
    @Test func directoryReaderOnFixtureTree() throws {
        let buildRoot = ProcessInfo.processInfo.environment["LP_BUILD_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Code/lockplus-build")
        let root = buildRoot.appending(path: "test-scratch/lpparsing-fixtures/\(UUID().uuidString)/lockplus")
        let tunnels = root.appending(path: "tunnels")
        try FileManager.default.createDirectory(at: tunnels, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.wg.write(to: tunnels.appending(path: "Home.conf"), atomically: true, encoding: .utf8)
        try Self.wg.write(to: root.appending(path: "outside.conf"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: tunnels.appending(path: "Evil.conf"), withDestinationURL: root.appending(path: "outside.conf"))
        try #"{"language":"de"}"#.write(to: root.appending(path: "config.json"), atomically: true, encoding: .utf8)
        let found = try #require(GoAppDirectory.locate(applicationSupport: root.deletingLastPathComponent()))
        #expect(found.sourceDescription.hasSuffix("/lockplus"))
        let plan = try GoMigrationReader.read(found)
        #expect(plan.tunnels.map(\.oldName) == ["Home"])
        #expect(plan.skipped == ["Evil.conf"])
        #expect(plan.settings.language == .de)
        #expect(throws: (any Error).self) { try found.readTunnelFile("Evil.conf", maxBytes: 100) }
        #expect(throws: (any Error).self) { try found.readTunnelFile("../outside.conf", maxBytes: 100) }
    }
}

/// Migration matrix (2026-11-09): the on-disk layouts of every 1.x group, as fixture trees under $LP_BUILD_ROOT.
@Suite("Go data directories by version group (migration matrix)")
struct MigrationLayoutTests {
    static let wg = WGConfigTests.validConf
    static let wg2 = WGConfigTests.validConf.replacingOccurrences(of: "Address = ", with: "Address = 10.99.0.9/32, ")

    /// A fresh Application Support fixture with the given directories: [dir: [file: content]] (a file name with
    /// "tunnels/" goes into the tunnels folder).
    static func tree(_ dirs: [String: [String: String]]) throws -> URL {
        let buildRoot = ProcessInfo.processInfo.environment["LP_BUILD_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Code/lockplus-build")
        let base = buildRoot.appending(path: "test-scratch/lpparsing-layouts/\(UUID().uuidString)", directoryHint: .isDirectory)
        for (dir, files) in dirs {
            let d = base.appending(path: dir, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: d.appending(path: "tunnels"), withIntermediateDirectories: true)
            for (name, text) in files { try text.write(to: d.appending(path: name), atomically: true, encoding: .utf8) }
        }
        return base
    }

    @Test("WireGuide+ only (1.0.1–1.0.56): its tunnels and data files are read")
    func wireGuidePlusOnly() throws {
        let base = try Self.tree(["wireguide-plus": ["tunnels/Home.conf": Self.wg, "config.json": #"{"language":"de"}"#,
                                                     "wifi_rules.json": #"{"enabled":true,"trusted_ssids":["Net"]}"#]])
        defer { try? FileManager.default.removeItem(at: base) }
        let src = try #require(GoAppDirectory.locate(applicationSupport: base))
        let plan = try GoMigrationReader.read(src)
        #expect(plan.tunnels.map(\.oldName) == ["Home"])
        #expect(plan.settings.language == .de && plan.wifi.trustedSSIDs == ["Net"])
    }

    @Test("LockPlus only (1.0.57+ fresh): its directory alone")
    func lockPlusOnly() throws {
        let base = try Self.tree(["lockplus": ["tunnels/Work.conf": Self.wg]])
        defer { try? FileManager.default.removeItem(at: base) }
        let plan = try GoMigrationReader.read(try #require(GoAppDirectory.locate(applicationSupport: base)))
        #expect(plan.tunnels.map(\.oldName) == ["Work"])
    }

    @Test("Both (1.0.56 → 1.0.57/1.0.61, Go never copied): the union; lockplus wins a name clash; wifi rules and history fall back")
    func bothDirectoriesAreMerged() throws {
        let base = try Self.tree([
            "lockplus": ["tunnels/Home.conf": Self.wg2, "tunnels/Work.conf": Self.wg, "config.json": #"{"language":"en"}"#],
            "wireguide-plus": ["tunnels/Home.conf": Self.wg, "tunnels/Old.conf": Self.wg2.replacingOccurrences(of: "10.99.0.9", with: "10.98.0.9"),
                               "config.json": #"{"language":"de"}"#,
                               "wifi_rules.json": #"{"enabled":true,"trusted_ssids":["OldNet"]}"#,
                               "history.json": #"[{"tunnel_name":"Old","start_time":"2026-01-01T10:00:00Z","rx_bytes":1,"tx_bytes":2,"disconnect_reason":"user"}]"#],
        ])
        defer { try? FileManager.default.removeItem(at: base) }
        let src = try #require(GoAppDirectory.locate(applicationSupport: base))
        let plan = try GoMigrationReader.read(src) { String($0.utf8.count) + "-" + String($0.hashValue) }
        #expect(plan.tunnels.map(\.oldName).sorted() == ["Home", "Old", "Work"])
        let home = try #require(plan.tunnels.first { $0.oldName == "Home" })
        #expect(home.canonicalPayload?.contains("10.99.0.9") == true)             // lockplus's Home, not wireguide-plus's
        #expect(plan.settings.language == .en)                                      // lockplus's config.json
        #expect(plan.wifi.trustedSSIDs == ["OldNet"])                               // fallback: lockplus has none
        #expect(plan.history.map(\.tunnelName) == ["Old"])
        #expect(src.tunnelPriority("Work.conf") == 0 && src.tunnelPriority("Old.conf") == 1)
    }

    @Test("Both, after Go copied the tunnels (.legacy-migrated): wireguide-plus adds none (deletions in lockplus stay)")
    func copiedTunnelsAreNotResurrected() throws {
        let base = try Self.tree([
            "lockplus": ["tunnels/Work.conf": Self.wg, "tunnels/.legacy-migrated": ""],
            "wireguide-plus": ["tunnels/Deleted.conf": Self.wg2, "history.json": "[]"],
        ])
        defer { try? FileManager.default.removeItem(at: base) }
        let plan = try GoMigrationReader.read(try #require(GoAppDirectory.locate(applicationSupport: base)))
        #expect(plan.tunnels.map(\.oldName) == ["Work"])
    }

    @Test("The same payload under two names in both directories is one tunnel, lockplus's")
    func equalPayloadsAreDeduped() throws {
        let base = try Self.tree(["lockplus": ["tunnels/Office.conf": Self.wg], "wireguide-plus": ["tunnels/A-office.conf": Self.wg]])
        defer { try? FileManager.default.removeItem(at: base) }
        let plan = try GoMigrationReader.read(try #require(GoAppDirectory.locate(applicationSupport: base))) { String($0.hashValue) }
        #expect(plan.tunnels.map(\.oldName) == ["Office"])
        #expect(plan.skipped.contains("A-office.conf"))
    }

    @Test("Upstream WireGuide's directory is never read automatically; it is only detected")
    func upstreamWireGuideIsNotImported() throws {
        let base = try Self.tree(["wireguide": ["tunnels/Upstream.conf": Self.wg]])
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(GoAppDirectory.locate(applicationSupport: base) == nil)
        #expect(GoAppDirectory.upstreamWireGuideHasTunnels(applicationSupport: base))
        let both = try Self.tree(["wireguide": ["tunnels/Upstream.conf": Self.wg], "lockplus": ["tunnels/Work.conf": Self.wg2]])
        defer { try? FileManager.default.removeItem(at: both) }
        let plan = try GoMigrationReader.read(try #require(GoAppDirectory.locate(applicationSupport: both)))
        #expect(plan.tunnels.map(\.oldName) == ["Work"])
    }
}

@Suite("Legacy keychain decode (§6.7) and display names (§3.5)")
struct LegacySecretTests {
    func strs(_ d: LegacyKeychainDecoder.Decoded) -> (String, String?) {
        (String(decoding: d.username.copyBytes(), as: UTF8.self), d.basePassword.map { String(decoding: $0.copyBytes(), as: UTF8.self) })
    }

    @Test func b64Format() throws {
        let raw = "b64:" + Data("alice\ns3cret\npassword\twith odd bytes".utf8).base64EncodedString()
        let d = try LegacyKeychainDecoder.decode(Array(raw.utf8)).get()
        #expect(strs(d) == ("alice", "s3cret\npassword\twith odd bytes"))
    }

    @Test func hexFormat() throws {
        let hex = Array("bob\npw".utf8).map { String(format: "%02x", $0) }.joined()
        #expect(strs(try LegacyKeychainDecoder.decode(Array(hex.utf8)).get()) == ("bob", "pw"))
        #expect(strs(try LegacyKeychainDecoder.decode(Array(hex.uppercased().utf8)).get()) == ("bob", "pw"))
    }

    @Test func plainFallback() throws {
        #expect(strs(try LegacyKeychainDecoder.decode(Array("carol\nplain pw".utf8)).get()) == ("carol", "plain pw"))
        #expect(strs(try LegacyKeychainDecoder.decode(Array("onlyuser".utf8)).get()) == ("onlyuser", nil))
        #expect(strs(try LegacyKeychainDecoder.decode(Array("abc".utf8)).get()) == ("abc", nil))   // odd-length hex → plain
    }

    @Test func invalidB64IsAnError() {
        #expect(throws: LegacyKeychainDecoder.DecodeError.invalidBase64) { try LegacyKeychainDecoder.decode(Array("b64:!!".utf8)).get() }
    }

    @Test func secretsRedacted() throws {
        let d = try LegacyKeychainDecoder.decode(Array("u\np".utf8)).get()
        #expect("\(d.username)" == "<redacted>")
    }

    @Test(arguments: [("work.vpn", "work.vpn"), ("  Büro\u{0}\tVPN  ", "Büro VPN"), ("", "Profile"), ("\u{202E}x", "x"),
                      (String(repeating: "a", count: 80), String(repeating: "a", count: 64))])
    func sanitize(_ c: (String, String)) {
        #expect(ProfileNameSanitizer.sanitize(c.0) == c.1)
    }

    @Test func displayNameStripsExtension() {
        #expect(ProfileNameSanitizer.displayName(forFileName: "/x/office.ovpn") == "office")
        #expect(ProfileNameSanitizer.displayName(forFileName: "home.CONF") == "home")
        #expect(ProfileNameSanitizer.displayName(forFileName: ".ovpn") == ".ovpn")
    }
}
