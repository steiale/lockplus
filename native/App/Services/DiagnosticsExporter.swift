import AppKit
import Foundation
import LPModel
import os
import UniformTypeIdentifiers

/// Host facts for the bundle beyond DNS: routes, system facts, our crash reports. Live reads run system tools as the
/// user (absolute paths, timeouts, no shell); preview mode and tests use fixtures.
protocol HostDiagnosticsReading: Sendable {
    func routes() async -> String?
    func systemFacts() async -> [String: String]
    func crashReports() async -> [(name: String, text: String)]
}

struct LiveHostDiagnostics: HostDiagnosticsReading {
    func routes() async -> String? { await ProcessRunner.run("/usr/sbin/netstat", ["-rn"], timeout: .seconds(5)) }

    func systemFacts() async -> [String: String] {
        var f: [String: String] = [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        f["macOS"] = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        f["macOSBuild"] = ProcessInfo.processInfo.operatingSystemVersionString
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buf, &size, nil, 0)
            f["model"] = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        f["sip"] = await ProcessRunner.run("/usr/bin/csrutil", ["status"], timeout: .seconds(3))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return f
    }

    /// Our own crash reports (≤ 5, last 30 days): the app's from the user's DiagnosticReports and, if readable, the
    /// extension's from /Library/Logs/DiagnosticReports. Never a third party's.
    func crashReports() async -> [(name: String, text: String)] {
        await Blocking.run { () -> [(name: String, text: String)] in
            let fm = FileManager.default
            let dirs = [fm.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports"),
                        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            var found: [(URL, Date)] = []
            for d in dirs {
                for u in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey])) ?? [] {
                    let n = u.lastPathComponent
                    guard n.hasSuffix(".ips"), n.hasPrefix("LockPlus") || n.hasPrefix("io.github.steiale.lockplus.mac.tunnel") else { continue }
                    let rv = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
                    guard rv?.isSymbolicLink != true, let m = rv?.contentModificationDate, m >= cutoff else { continue }
                    found.append((u, m))
                }
            }
            return found.sorted { $0.1 > $1.1 }.prefix(5).compactMap { u, _ in
                AtomicFile.readNoFollow(u, maxBytes: 2 << 20).map { (u.lastPathComponent, String(decoding: $0, as: UTF8.self)) }
            }
        }
    }
}

struct FixtureHostDiagnostics: HostDiagnosticsReading {
    var routesText: String? = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            192.168.1.1        UGScg                 en0
        0/1                10.8.0.1           UGScg               utun4
        10.8.0/24          10.8.0.1           UGSc                utun4
        128.0/1            10.8.0.1           UGSc                utun4
        192.168.1          link#6             UCS                   en0      !
        """
    var facts: [String: String] = ["macOS": "27.0.0", "model": "Mac16,1", "sip": "System Integrity Protection status: enabled."]
    var crashes: [(name: String, text: String)] = []

    func routes() async -> String? { routesText }
    func systemFacts() async -> [String: String] { facts }
    func crashReports() async -> [(name: String, text: String)] { crashes }
}

extension AppEnvironment {
    /// SSIDs, profile names and saved user names: hashed wherever they appear (logs and bundle).
    func sensitiveLiterals() -> [String] {
        var s = profiles.profiles.map(\.name) + settings.value.autoConnect.trustedSSIDs
        s += profiles.credentials.values.compactMap(\.username)
        return s
    }

    /// One Redactor per bundle/session; a fresh salt each time it's created.
    func makeRedactor() -> Redactor { Redactor(sensitive: sensitiveLiterals()) }

    func gatherDiagnostics() async -> DiagnosticsInputs {
        var i = DiagnosticsInputs()
        var sys = await host.systemFacts()
        sys["appVersion"] = ui.settings.version
        sys["appBuild"] = ui.settings.build
        sys["extensionState"] = String(describing: extensionStore.state)
        sys["extensionLink"] = String(describing: extensionStore.link.link).components(separatedBy: "(").first ?? ""
        sys["mode"] = mode == .preview ? "preview" : "live"
        i.system = sys
        i.profiles = profiles.ordered.map { p in
            .init(id: p.id, name: p.name, kind: p.kind.rawValue, endpoints: p.summary.endpoints, isFullTunnel: p.summary.isFullTunnel,
                  dnsServers: p.summary.dnsServers, policy: p.policy, engineVerified: p.engineVerified,
                  importReport: (p.importReport?.items ?? []).map { "\($0.group) \($0.directive ?? "") \($0.reason)" })
        }
        i.managers = managers.managers.map { m in
            let plan = profiles.profile(m.profileID).flatMap { profiles.onDemandPlan(for: $0) }
            var flags: [String: Bool] = [:]
            if let f = m.flags {
                flags = ["includeAllNetworks": f.includeAllNetworks, "enforceRoutes": f.enforceRoutes,
                         "excludeLocalNetworks": f.excludeLocalNetworks, "excludeAPNs": f.excludeAPNs,
                         "excludeCellularServices": f.excludeCellularServices, "excludeDeviceCommunication": f.excludeDeviceCommunication]
            }
            return .init(profileID: m.profileID, status: "\(m.status)", onDemandEnabled: m.onDemandEnabled, flags: flags,
                         onDemandRules: (plan?.rules ?? []).map { "\($0.action) \($0.interface) ssids=\($0.ssids?.count ?? 0)" },
                         probeHosts: (plan?.rules ?? []).compactMap { $0.probeURL?.host() }
                             .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
        }
        let since = Date().addingTimeInterval(-24 * 3600)
        i.appLog = await logSources.appLines(since: since)
        i.tunnelLog = await logSources.tunnelLines(since: since)
        i.scutilDNS = await dnsSystem.scutilDNS()
        i.routes = await host.routes()
        i.history = history
        i.crashReports = await host.crashReports()
        i.legacy = await legacyFindingsJSON()
        i.sensitive = sensitiveLiterals()
        return i
    }

    /// The redacted files, for the "What's inside" preview and the export (§14.2).
    func prepareDiagnostics() async -> [DiagnosticsBundle.File] {
        let i = await gatherDiagnostics()
        return DiagnosticsBundle.files(i, redactor: DiagnosticsBundle.redactor(for: i))
    }

    /// Settings › Advanced / Help › "Export Diagnostics…": a zip (0600, O_NOFOLLOW) of the redacted files.
    func exportDiagnostics() {
        Task { @MainActor in
            let files = await prepareDiagnostics()
            let panel = NSSavePanel()
            let stamp = Date().ISO8601Format(.iso8601.year().month().day()).replacingOccurrences(of: "-", with: "")
            panel.nameFieldStringValue = "LockPlus Diagnostics \(stamp).zip"
            panel.allowedContentTypes = [.zip]
            AppActivation.becomeRegular()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try await DiagnosticsArchive.write(files, to: url) } catch {
                ui.importer.errorMessage = String(localized: "The diagnostics file couldn't be saved.", comment: "Diagnostics export error")
            }
        }
    }

    /// "Reload" in Diagnostics › Routes.
    func reloadRoutes() async {
        guard let text = await host.routes() else { return }
        ui.diagnostics.routes = RouteTable.parse(text)
    }
}

/// Builds the zip in memory with ZIPFoundation (`ProfileZipWriter`; no scratch files), every file under a top-level
/// "LockPlus Diagnostics/" folder, then writes it atomically with 0600 / O_NOFOLLOW (`AtomicFile.writeUserFile`).
enum DiagnosticsArchive {
    static let folder = "LockPlus Diagnostics"

    static func data(_ files: [DiagnosticsBundle.File]) async throws -> Data {
        let entries = files.map { (path: "\(folder)/\($0.name)", data: $0.data) }
        return try await Blocking.run { () -> Result<Data, CocoaError> in
            do { return .success(try ProfileZipWriter.archive(entries)) } catch { return .failure(CocoaError(.fileWriteUnknown)) }
        }.get()
    }

    static func write(_ files: [DiagnosticsBundle.File], to url: URL) async throws {
        try AtomicFile.writeUserFile(try await data(files), to: url)          // Fable M2: never chmod the user's folder
    }
}

extension AppEnvironment {
    /// §4.5 findings for legacy.json.
    func legacyFindingsJSON() async -> String? {
        await legacy.refresh()
        return legacy.findingsJSON
    }
}
