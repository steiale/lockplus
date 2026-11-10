import AppKit
import Foundation
import LPModel
import LPParsing
import LPRouteProbe
import LPWire

/// Zip import (§3.5 caps: 500 profile entries, 10 MiB per entry, 100 MiB total; in memory only). The live reader is
/// `ProfileZipReader` (ZIPFoundation behind our own structural validator, `ProfileZip.swift`); tests may inject another.
protocol ZipArchiveReading: Sendable {
    func read(_ data: Data) throws(ZipArchiveError) -> ZipProfiles
}

struct ProfileZipArchiveReader: ZipArchiveReading {
    func read(_ data: Data) throws(ZipArchiveError) -> ZipProfiles { try ProfileZipReader.read(data) }
}

extension ZipArchiveError {
    func message(archive: String) -> String {
        switch self {
        case .tooLarge: String(localized: "\(archive) is larger than 100 MB and can't be imported.", comment: "Zip import error")
        case .notAZip, .malformed, .multiDisk:
            String(localized: "\(archive) isn't a valid zip archive or is damaged.", comment: "Zip import error")
        case .zip64: String(localized: "\(archive) uses the ZIP64 format, which isn't supported. Unpack it and import the files.", comment: "Zip import error")
        case .encrypted: String(localized: "\(archive) is encrypted. Unpack it and import the files.", comment: "Zip import error")
        case .unsupportedMethod: String(localized: "\(archive) uses a compression method that isn't supported. Unpack it and import the files.", comment: "Zip import error")
        case .tooManyEntries: String(localized: "\(archive) has more than 500 profiles. Split it into smaller archives.", comment: "Zip import error (cap)")
        case .totalTooLarge: String(localized: "\(archive) unpacks to more than 100 MB and can't be imported.", comment: "Zip import error (cap)")
        case .duplicateName(let n): String(localized: "\(archive) contains “\(n)” twice and can't be imported.", comment: "Zip import error")
        case .noProfiles: String(localized: "\(archive) contains no .ovpn or .conf files.", comment: "Zip import error")
        }
    }
}

extension ZipEntryIssue {
    var message: String {
        switch self {
        case .unsafePath(let n): String(localized: "“\(n)” has an unsafe path and was skipped.", comment: "Zip entry error")
        case .symlink(let n): String(localized: "“\(n)” is a link, not a file, and was skipped.", comment: "Zip entry error")
        case .special(let n): String(localized: "“\(n)” isn't a regular file and was skipped.", comment: "Zip entry error")
        case .tooLarge(let n): String(localized: "“\(n)” is larger than 10 MB and was skipped.", comment: "Zip entry error (cap)")
        case .suspiciousRatio(let n): String(localized: "“\(n)” is compressed suspiciously well and was skipped.", comment: "Zip entry error (cap)")
        case .corrupt(let n): String(localized: "“\(n)” is damaged and was skipped.", comment: "Zip entry error")
        }
    }
}

/// One analysed file: the pipeline result the confirm step turns into a `ProfileDraft`.
struct AnalysedImport: Sendable {
    var fileName: String
    var displayName: String
    var kind: VPNProtocolKind
    var report: ImportReport
    var summary: ProfileSummary
    var auth: AuthPolicy?
    var canonical: String?
    var credentials: CredentialRecord?
    var engineVerified: Bool
    /// The zip it came from (`ProfileOrigin.zip`), nil for a loose file.
    var archive: String? = nil

    var verdict: ImportVerdict { canonical == nil ? .rejected : ImportVerdict(report: report) }
}

/// The import flow (DESIGN §8.1, §9.1, §6.8 UI): bytes → LPParsing [1]–[5] → [7] `validateProfile` over XPC
/// (`XPCProfileValidator`; the extension's [7] re-runs [1]–[6] with openvpn3's own parser, so the app-side [6]
/// is left to it) → `RouteProbe` → the preview sheet → `ProfilesStore.create`.
@MainActor final class ImportCoordinator {
    private let model: ImportUIModel
    private let profiles: ProfilesStore
    private let service: any TunnelServicing
    private let settings: SettingsStore
    private let probe: any EndpointRouteProbing
    var zipReader: any ZipArchiveReading = ProfileZipArchiveReader()
    /// PF 51: looks up an `http-proxy` hostname at import (live: `StartEndpointResolver`, set by `AppEnvironment`);
    /// nil skips the check (previews, tests that don't care).
    var resolveEndpoints: (@Sendable ([String]) async -> [String: [String]])?
    var onImported: ((UUID) -> Void)?
    private var pending: [UUID: AnalysedImport] = [:]
    /// The latest import/confirm task; tests await it instead of polling against a timer. Test hook only, harmless in
    /// Release (one task reference): nothing in the app awaits it. Limits (pre-release
    /// review): only `importFiles` and `confirm(batch)` are tracked (not `importFromClipboard` or the single-file
    /// `confirm(preview)`), and a second `importFiles` replaces the first task without awaiting or cancelling it, so `idle()` waits
    /// for the latest one only. Main-actor, no continuation; the task's reference to self ends when it finishes.
    private var running: Task<Void, Never>?

    init(model: ImportUIModel, profiles: ProfilesStore, service: any TunnelServicing, settings: SettingsStore,
         probe: any EndpointRouteProbing = RouteProbe()) {
        self.model = model
        self.profiles = profiles
        self.service = service
        self.settings = settings
        self.probe = probe
    }

    // MARK: Pipeline (nonisolated, Sendable in and out)

    /// Kind by CONTENT first (review M11: OpenVPN configs are often `*.conf`, as on Linux): an `[Interface]` section
    /// line is WireGuard; OpenVPN directives (`client`, `remote`, `dev`, `proto`, `<ca>`…) are OpenVPN; only an
    /// undecidable file falls back to the extension.
    nonisolated static func kind(fileName: String, bytes: [UInt8]) -> VPNProtocolKind {
        let lines = String(decoding: bytes.prefix(64 << 10), as: UTF8.self)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(";") }
        if lines.contains(where: { $0 == "[interface]" || $0 == "[peer]" }) { return .wireGuard }
        let ovpn: Set<String> = ["client", "remote", "dev", "proto", "auth-user-pass", "cipher", "data-ciphers", "tls-client",
                                 "pull", "nobind", "remote-cert-tls", "<ca>", "<cert>", "<key>", "<tls-auth>", "<tls-crypt>"]
        if lines.contains(where: { ovpn.contains(String($0.split(separator: " ").first ?? "")) }) { return .openVPN }
        return fileName.lowercased().hasSuffix(".ovpn") ? .openVPN : .wireGuard
    }

    nonisolated static func analyse(fileName: String, bytes: [UInt8], service: any TunnelServicing,
                                    probe: any EndpointRouteProbing,
                                    resolve: (@Sendable ([String]) async -> [String: [String]])? = nil) async -> AnalysedImport {
        let display = ProfileNameSanitizer.displayName(forFileName: fileName)
        switch kind(fileName: fileName, bytes: bytes) {
        case .wireGuard:
            var r = WGImporter.importProfile(bytes)
            if r.verdict != .rejected { r = await WGImporter.probeRoutes(r, probe: probe) }
            return AnalysedImport(fileName: fileName, displayName: display, kind: .wireGuard, report: r.report, summary: r.summary,
                                  auth: nil, canonical: r.canonicalText, credentials: nil, engineVerified: true)
        case .openVPN:
            var r = OVPNImporter.importProfile(bytes)
            if r.verdict != .rejected {
                r = await OVPNImporter.validateWithEngine(r, validator: XPCProfileValidator(service: service))
            }
            if r.verdict != .rejected { r = await OVPNImporter.probeRoutes(r, probe: probe) }
            if r.verdict != .rejected, let resolve {
                r.report = await proxyCheck(r.report, summary: r.summary, resolve: resolve)
                r.verdict = ImportVerdict(report: r.report)
            }
            let c = r.credentials
            let rec: CredentialRecord? = c.isEmpty ? nil : CredentialRecord(
                username: c.username.map { Data($0.copyBytes()) }, password: c.password.map { Data($0.copyBytes()) },
                proxyUsername: c.proxyUsername.map { Data($0.copyBytes()) }, proxyPassword: c.proxyPassword.map { Data($0.copyBytes()) })
            return AnalysedImport(fileName: fileName, displayName: display, kind: .openVPN, report: r.report, summary: r.summary,
                                  auth: r.auth, canonical: r.canonicalText, credentials: rec,
                                  engineVerified: r.engineValidation == .passed)
        }
    }

    /// PF 51: under the kill switch neither the provider nor openvpn3 may resolve the proxy (S2 E10), so the app
    /// resolves it before each start, as it does for the remotes. A proxy hostname that doesn't resolve now gets an
    /// import warning (never a rejection: the name may resolve on another network). IP literals need nothing.
    nonisolated static func proxyCheck(_ report: ImportReport, summary: ProfileSummary,
                                       resolve: @Sendable ([String]) async -> [String: [String]]) async -> ImportReport {
        guard let proxy = summary.proxyEndpoint, let host = StartEndpointResolver.hostnames([proxy]).first else { return report }
        guard (await resolve([proxy]))[host]?.isEmpty ?? true else { return report }
        var r = report
        r.add(.securityWarning, directive: "http-proxy", .proxyHostUnresolved)
        return r
    }

    // MARK: Intents

    func importFiles(_ urls: [URL]) {
        running = Task { @MainActor in
            var files: [(String, [UInt8], String?)] = []
            var capErrors: [String] = []
            var archiveName: String?
            for url in urls {
                let name = url.lastPathComponent
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    model.errorMessage = String(localized: "\(name) is a folder. Choose the profile files inside it.", comment: "Import error")
                    return
                }
                let lower = name.lowercased()
                if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".heic") {
                    model.errorMessage = String(localized: "QR code images can't be imported yet.", comment: "Import error (QR seam)")
                    return
                }
                if lower.hasSuffix(".zip") {
                    let caps = ZipCaps()
                    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > caps.maxArchiveBytes {
                        model.errorMessage = ZipArchiveError.tooLarge.message(archive: name)
                        return
                    }
                    guard let data = AtomicFile.read(url, maxBytes: caps.maxArchiveBytes + 1) else {
                        model.errorMessage = String(localized: "\(name) can't be read.", comment: "Import error")
                        return
                    }
                    let reader = zipReader
                    // Off the main actor: validating and inflating up to 100 MB is not UI work.
                    let result = await Blocking.run { () -> Result<ZipProfiles, ZipArchiveError> in
                        do throws(ZipArchiveError) { return .success(try reader.read(data)) } catch { return .failure(error) }
                    }
                    switch result {
                    case .success(let r):
                        files += r.entries.map { ($0.name, $0.bytes, name) }
                        capErrors += r.issues.map(\.message)
                        archiveName = name
                    case .failure(let e):
                        model.errorMessage = e.message(archive: name)
                        return
                    }
                    continue
                }
                let cap = lower.hasSuffix(".conf") ? 64 * 1024 : OVPNImportLimits.maxRawBytes
                guard let d = AtomicFile.read(url, maxBytes: cap + 1) else {
                    model.errorMessage = String(localized: "\(name) can't be read.", comment: "Import error")
                    return
                }
                files.append((name, Array(d), nil))
            }
            await analyseAndPresent(files, archiveName: archiveName, capErrors: capErrors)
        }
    }

    /// Returns once the latest `importFiles` / `confirm(batch)` has finished.
    func idle() async { await running?.value }

    /// ⇧⌘V: reads the pasteboard only on this explicit user action (F-8), never in the background.
    func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            model.errorMessage = String(localized: "The clipboard doesn't contain a profile.", comment: "Import error")
            return
        }
        let bytes = Array(text.utf8)
        let name = Self.kind(fileName: "", bytes: bytes) == .wireGuard ? "Clipboard.conf" : "Clipboard.ovpn"
        Task { @MainActor in await analyseAndPresent([(name, bytes, nil)], archiveName: nil, capErrors: []) }
    }

    func analyseAndPresent(_ files: [(String, [UInt8], String?)], archiveName: String?, capErrors: [String]) async {
        guard !files.isEmpty else {
            // A zip whose every profile entry was skipped: say why, never nothing (§3.5 "errors, not silent truncation").
            if !capErrors.isEmpty { model.errorMessage = capErrors.joined(separator: "\n") }
            return
        }
        var results: [AnalysedImport] = []
        for (name, bytes, archive) in files {
            var r = await Self.analyse(fileName: name, bytes: bytes, service: service, probe: probe, resolve: resolveEndpoints)
            r.archive = archive
            results.append(r)
        }
        let defaults = settings.value.newProfileDefaults
        if results.count == 1, archiveName == nil, let r = results.first {
            let id = UUID()
            pending = [id: r]
            model.preview = ImportPreview(id: id, fileName: r.fileName, name: r.displayName, kind: r.kind, summary: r.summary,
                                          report: r.report, killSwitch: r.summary.isFullTunnel && defaults.killSwitch,
                                          allowLocalNetwork: defaults.allowLAN)
        } else {
            pending = [:]
            var items: [BatchImportItem] = []
            for r in results {
                let id = UUID()
                pending[id] = r
                items.append(BatchImportItem(id: id, fileName: r.fileName, selected: r.verdict != .rejected, report: r.report))
            }
            model.batch = BatchImport(id: UUID(), archiveName: archiveName ?? String(localized: "\(results.count) files", comment: "Batch import title"),
                                      items: items, capErrors: capErrors)
        }
    }

    func draft(_ r: AnalysedImport, name: String, killSwitch: Bool, allowLAN: Bool) -> ProfileDraft? {
        guard let text = r.canonical else { return nil }
        var policy = settings.value.newProfileDefaults
        policy.killSwitch = killSwitch
        policy.allowLAN = allowLAN
        return ProfileDraft(name: name, kind: r.kind, payload: SecretBytes(copying: Array(text.utf8)), summary: r.summary,
                            auth: r.auth, report: r.report, policy: policy, credentials: r.credentials,
                            engineVerified: r.engineVerified, origin: r.archive.map { .zip($0) } ?? .file(r.fileName))
    }

    func confirm(_ preview: ImportPreview) {
        guard let r = pending[preview.id], let d = draft(r, name: preview.name, killSwitch: preview.killSwitch,
                                                          allowLAN: preview.allowLocalNetwork) else { return }
        Task { @MainActor in
            do throws(LPError) {
                let p = try await profiles.create(d)
                model.preview = nil
                pending = [:]
                onImported?(p.id)
            } catch {
                model.errorMessage = error.code.message(detail: error.detail)
            }
        }
    }

    func confirm(_ batch: BatchImport) {
        running = Task { @MainActor in
            var b = batch
            var last: UUID?
            for i in b.items.indices where b.items[i].selected && b.items[i].isImportable {
                guard let r = pending[b.items[i].id] else { continue }
                let defaults = settings.value.newProfileDefaults
                guard let d = draft(r, name: r.displayName, killSwitch: r.summary.isFullTunnel && defaults.killSwitch,
                                    allowLAN: defaults.allowLAN) else { b.items[i].state = .skipped; continue }
                do throws(LPError) {
                    let p = try await profiles.create(d)
                    b.items[i].state = .imported
                    last = p.id
                } catch {
                    b.items[i].state = .skipped
                }
            }
            b.finished = true
            model.batch = b
            pending = [:]
            if let last { onImported?(last) }
        }
    }

    func cancel() {
        model.preview = nil
        model.batch = nil
        pending = [:]
    }
}
