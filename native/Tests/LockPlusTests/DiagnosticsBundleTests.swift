import Foundation
import LPModel
import Testing
@testable import LockPlus

/// §14.2: one Redactor for every file; a full bundle of a fixture system with planted secrets leaks none of them.
@MainActor @Suite("Diagnostics bundle and logs (§14)", .serialized)
struct DiagnosticsBundleTests {
    static let salt = Data(repeating: 1, count: 16)

    // Planted secrets: none of these may appear in any file.
    static let wgKey = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
    static let password = "Hunter2-very-secret"
    static let crv1 = "CRV1:R,E:Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l:dXNlcg==:Enter Code"
    static let pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\n-----END PRIVATE KEY-----"
    static let ssid = "Smith Family WiFi"
    static let host = "vpn.secret-corp.example"
    static let endpointIP = "203.0.113.77"
    static let profileName = "Acme Prod"
    static let token = "eyJhbGciOiJIUzI1NiJ9.payload.sig-abcdefghijklmnop"

    @Test func redactorCorpus() {
        let r = Redactor(salt: Self.salt, keep: ["10.8.0.1"], sensitive: [Self.ssid, Self.profileName])
        let text = """
            PrivateKey = \(Self.wgKey)
            password: \(Self.password)
            auth-token \(Self.token)
            challenge \(Self.crv1)
            \(Self.pem)
            <tls-crypt>
            abcdef0123
            </tls-crypt>
            joined \(Self.ssid) with \(Self.profileName)
            connect \(Self.host):1194 via \(Self.endpointIP) dns 10.8.0.1 at 21:35:00.179
            peer 2001:db8:85a3::8a2e:370:7334 file settings.json subsystem io.github.steiale.lockplus.mac
            Authorization: Basic dXNlcjpwYXNz
            """
        let out = r.redact(text)
        for secret in [Self.wgKey, Self.password, Self.token, "Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l", "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7",
                       "abcdef0123", Self.ssid, Self.profileName, Self.host, Self.endpointIP, "2001:db8:85a3", "dXNlcjpwYXNz"] {
            #expect(!out.contains(secret), "leaked \(secret)")
        }
        #expect(out.contains("10.8.0.1"))                        // kept: DNS server
        #expect(out.contains("21:35:00.179"))                    // times aren't addresses
        #expect(out.contains("settings.json"))                   // file names aren't hosts
        #expect(out.contains("io.github.steiale.lockplus.mac"))  // our identifiers stay
        #expect(out.contains(r.hash(Self.host, kind: "host")))   // hashed, stable within a bundle
        #expect(r.redact(Self.host) == r.redact(Self.host))
        #expect(Redactor(salt: Data(repeating: 2, count: 16)).hash(Self.host, kind: "host") != r.hash(Self.host, kind: "host"))
    }

    @Test func userNameAndHomeAreHashed() {
        var r = Redactor(salt: Self.salt)
        r.userName = "alexander"
        let out = r.redact("/Users/alexander/Library/Logs crashed for alexander")
        #expect(!out.contains("alexander"))
        #expect(out.contains("/Users/<user>/Library/Logs"))
        let w = Redactor(salt: Self.salt, sensitive: ["Work"]).redact("Network: Work connected")
        #expect(w.hasPrefix("Network: name#") && !w.contains(" Work "))
    }

    func fixtureInputs() -> DiagnosticsInputs {
        var i = DiagnosticsInputs()
        i.system = ["macOS": "27.0.0", "hostName": Self.host]
        i.profiles = [.init(id: UUID(), name: Self.profileName, kind: "wg", endpoints: ["\(Self.endpointIP):51820", "\(Self.host):1194"],
                            isFullTunnel: true, dnsServers: ["10.8.0.1"], policy: NetworkPolicy(killSwitch: true), engineVerified: true,
                            importReport: ["ignored PostUp"])]
        i.managers = [.init(profileID: UUID(), status: "connected", onDemandEnabled: true, flags: ["includeAllNetworks": true],
                            onDemandRules: ["disconnect wiFi ssids=1"], probeHosts: ["www.apple.com"])]
        let now = Date()
        i.appLog = [LogLine(date: now, level: .info, source: .app, category: "connection", message: "connect \(Self.profileName) on \(Self.ssid)"),
                    LogLine(date: now, level: .error, source: .app, category: "auth", message: "answer \(Self.crv1) password=\(Self.password)")]
        i.tunnelLog = .success([LogLine(date: now, level: .info, source: .tunnel, category: "engine.wg",
                                        message: "handshake with \(Self.endpointIP):51820 key \(Self.wgKey)")])
        i.scutilDNS = FixtureDNSSystem.preview.scutil! + "\nresolver #9\n  search domain[0] : \(Self.host)\n"
        i.routes = FixtureHostDiagnostics().routesText! + "\n\(Self.endpointIP)      192.168.1.1        UGHS                  en0\n"
        i.history = [HistoryEntry(id: UUID(), profileID: nil, profileName: Self.profileName, start: now, end: now, rxBytes: 1, txBytes: 2, endReason: .user)]
        i.crashReports = [("LockPlus-2026-10-26.ips", "{\"procPath\":\"/Users/\(NSUserName())/Applications/LockPlus.app\", \"key\":\"\(Self.wgKey)\"}")]
        i.legacy = "{\"helperInstalled\": true}"
        i.sensitive = [Self.profileName, Self.ssid]
        return i
    }

    @Test func aFullBundleOfAPlantedFixtureLeaksNothing() {
        let i = fixtureInputs()
        let files = DiagnosticsBundle.files(i, redactor: DiagnosticsBundle.redactor(for: i, salt: Self.salt))
        #expect(Set(files.map(\.name)) == ["system.json", "profiles.json", "ne-configs.json", "logs-app.txt", "logs-tunnel.txt", "dns.txt",
                                           "routes.txt", "history-summary.json", "crash/LockPlus-2026-10-26.ips", "legacy.json"])
        for f in files {
            for secret in [Self.wgKey, Self.password, "Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l", Self.ssid, Self.host, Self.endpointIP, Self.profileName] {
                #expect(!f.text.contains(secret), "\(f.name) leaked \(secret)")
            }
            if !NSUserName().isEmpty { #expect(!f.text.contains("/Users/\(NSUserName())/"), "\(f.name) leaked the home path") }
        }
        let dns = files.first { $0.name == "dns.txt" }!.text
        #expect(dns.contains("10.8.0.1"))                       // DNS server IPs are kept (§14.2)
        let routes = files.first { $0.name == "routes.txt" }!.text
        #expect(routes.contains("0/1") && routes.contains("utun4"))
        let r = DiagnosticsBundle.redactor(for: i, salt: Self.salt)
        let hostHash = r.hash(Self.host, kind: "host")
        #expect(files.first { $0.name == "profiles.json" }!.text.contains(hostHash))   // same hash across files
        #expect(dns.contains(hostHash))
        let summary = files.first { $0.name == "history-summary.json" }!.text
        #expect(summary.contains("\"sessions\" : 1"))
    }

    @Test func aMissingTunnelLogIsDocumented() {
        var i = fixtureInputs()
        i.tunnelLog = .failure(LogReadGap(reason: "not permitted"))
        let f = DiagnosticsBundle.files(i, redactor: Redactor(salt: Self.salt)).first { $0.name == "logs-tunnel.txt" }!
        #expect(f.text.contains("not included"))
        #expect(f.text.contains("log show"))
    }

    @Test func routeTable() {
        let rows = RouteTable.parse(FixtureHostDiagnostics().routesText!)
        #expect(rows.count == 5)
        #expect(rows.first == RouteRow(destination: "default", gateway: "192.168.1.1", interface: "en0", viaTunnel: false))
        #expect(RouteTable.otherDefaultTunnels(rows) == ["utun4"])
    }

    @Test func logShowNDJSON() {
        let text = """
            {"timestamp":"2026-10-26 21:35:00.179000+0100","messageType":"Error","category":"watchdog","eventMessage":"no handshake"}
            not json
            {"timestamp":"2026-10-26 21:35:01.000000+0100","messageType":"Default","category":"controller","eventMessage":"phase connected"}
            """
        let l = LiveLogSources.parseNDJSON(text)
        #expect(l.map(\.message) == ["no handshake", "phase connected"])
        #expect(l.map(\.level) == [.warning, .info])
        #expect(l.allSatisfy { $0.source == .tunnel && $0.date > Date.distantPast })
    }

    @Test func logsStoreRedactsMergesAndClears() async throws {
        let model = LogsUIModel()
        let now = Date()
        var src = FixtureLogSources()
        src.app = [LogLine(date: now.addingTimeInterval(-2), level: .info, source: .app, category: "connection", message: "connect \(Self.profileName)")]
        src.tunnel = .success([LogLine(date: now.addingTimeInterval(-1), level: .warning, source: .tunnel, category: "engine",
                                       message: "peer \(Self.endpointIP) key \(Self.wgKey)")])
        let store = LogsStore(sources: src, model: model, redactor: { Redactor(salt: Self.salt, sensitive: [Self.profileName]) })
        await store.refresh()
        #expect(model.entries.map(\.source) == [.app, .tunnel])
        #expect(model.entries.allSatisfy { !$0.message.contains(Self.profileName) && !$0.message.contains(Self.endpointIP) && !$0.message.contains(Self.wgKey) })
        await store.refresh()                                    // nothing new: no duplicates
        #expect(model.entries.count == 2)
        store.clear()
        await store.refresh()                                    // cleared lines don't come back
        #expect(model.entries.isEmpty)
    }

    @Test func theArchiveIsAZipWith0600() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let url = dir.url.appending(path: "bundle.zip")
        try await DiagnosticsArchive.write([.init(name: "system.json", data: Data("{}".utf8)), .init(name: "crash/a.ips", data: Data("x".utf8))], to: url)
        let data = try Data(contentsOf: url)
        #expect(data.prefix(2) == Data("PK".utf8))
        let names = try ZipStructure.validate(data, caps: ZipCaps(maxProfileEntries: .max)).map(\.name)
        #expect(names == ["LockPlus Diagnostics/system.json", "LockPlus Diagnostics/crash/a.ips"])
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func previewFilesAndTheTunnelGapReachTheUI() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let files = await h.env.ui.actions.prepareDiagnosticsPreview()
        #expect(files.map(\.name).contains("logs-tunnel.txt"))
        let model = LogsUIModel()
        let store = LogsStore(sources: FixtureLogSources(tunnel: .failure(LogReadGap(reason: "admin required"))), model: model,
                              redactor: { Redactor(salt: Self.salt) })
        await store.refresh()
        #expect(model.tunnelLogsGap == "admin required")
    }

    @Test func resumeApprovalReachesTheUI() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let agent = InertResumeAgent()
        agent.registerResult = .requiresApproval
        h.env.connection.resumeAgent = agent
        UIBinder.bind(h.env)
        await h.env.connection.pause(minutes: 5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.env.ui.connection.resumeAgentNeedsApproval)
    }

    @Test func environmentPreparesTheBundleFromPreviewFixtures() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        try await h.add("Work.conf", Harness.wgConf)
        let files = await h.env.prepareDiagnostics()
        #expect(files.contains { $0.name == "profiles.json" && !$0.text.contains("\"Work\"") })
        #expect(files.contains { $0.name == "logs-tunnel.txt" && !$0.text.isEmpty })
        await h.env.runDiagnostics()
        #expect(h.env.ui.diagnostics.checks.map(\.kind) == [.tunnel, .dns, .ipv6, .otherVPNs, .oldHelper])
        #expect(!h.env.ui.diagnostics.routes.isEmpty)
    }
}
