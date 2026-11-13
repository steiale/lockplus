import AppKit
import Foundation
import LPModel
import LPParsing
import LPRouteProbe
import LPWire
import os
import Synchronization

/// The result of reading an archive: profile entries (in archive order) and per-entry issues.
struct ZipProfiles: Sendable {
    var entries: [(name: String, bytes: [UInt8])] = []
    var issues: [ZipEntryIssue] = []
}

/// Zip import (§3.5 caps: 500 profile entries, 1 MiB per entry, 64 MiB total; in memory only). 2.0.2: the live reader is
/// `ServiceZipArchiveReader`, the sandboxed validator service (`ServiceProfileValidator.swift`); tests inject another.
protocol ZipArchiveReading: Sendable {
    func read(_ data: Data) async throws(ZipArchiveError) -> ZipProfiles
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
        case .totalTooLarge: String(localized: "\(archive) unpacks to more than 64 MB and can't be imported.", comment: "Zip import error (cap)")
        case .duplicateName(let n): String(localized: "\(archive) contains “\(n)” twice and can't be imported.", comment: "Zip import error")
        case .noProfiles: String(localized: "\(archive) contains no .ovpn or .conf files.", comment: "Zip import error")
        case .checkUnavailable: String(localized: "\(archive) couldn't be checked safely and wasn't imported. Try again.", comment: "Zip import error (2.0.2: LockPlus's sandboxed file checker was unavailable or stopped on this archive)")
        }
    }
}

extension ZipEntryIssue {
    var message: String {
        switch self {
        case .unsafePath(let n): String(localized: "“\(n)” has an unsafe path and was skipped.", comment: "Zip entry error")
        case .symlink(let n): String(localized: "“\(n)” is a link, not a file, and was skipped.", comment: "Zip entry error")
        case .special(let n): String(localized: "“\(n)” isn't a regular file and was skipped.", comment: "Zip entry error")
        case .tooLarge(let n): String(localized: "“\(n)” is larger than 1 MB and was skipped.", comment: "Zip entry error (cap)")
        case .suspiciousRatio(let n): String(localized: "“\(n)” is compressed suspiciously well and was skipped.", comment: "Zip entry error (cap)")
        case .corrupt(let n): String(localized: "“\(n)” is damaged and was skipped.", comment: "Zip entry error")
        case .nameTooLong(let n): String(localized: "“\(n)” has a name longer than 255 bytes and was skipped.", comment: "Zip entry error (2.0.2 round 1)")
        case .moreSkipped(let n): String(localized: "\(n) more entries were skipped.", comment: "Zip import: the list of skipped entries was capped at 500; the argument is how many more")
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

/// The import flow (DESIGN §8.1, §9.1, §6.8 UI): bytes → LPParsing [1]–[5] → [6]/[7] in the sandboxed validator
/// service (`ServiceProfileValidator`; openvpn3's parser and `eval_config` never run in this process) → `RouteProbe` →
/// the preview sheet → `ProfilesStore.create`.
@MainActor final class ImportCoordinator {
    private let model: ImportUIModel
    private let profiles: ProfilesStore
    private let validator: any OpenVPN3ProfileValidating
    private let settings: SettingsStore
    private let probe: any EndpointRouteProbing
    var zipReader: any ZipArchiveReading
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

    init(model: ImportUIModel, profiles: ProfilesStore, validator: any OpenVPN3ProfileValidating,
         zipReader: any ZipArchiveReading, settings: SettingsStore, probe: any EndpointRouteProbing = RouteProbe()) {
        self.model = model
        self.profiles = profiles
        self.validator = validator
        self.zipReader = zipReader
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

    nonisolated static func analyse(fileName: String, bytes: [UInt8], validator: any OpenVPN3ProfileValidating,
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
                r = await OVPNImporter.validateWithEngine(r, validator: validator)
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

    /// What reading one chosen or opened path gave (round 1, Fable L3: read off the main actor, regular files only).
    enum ReadFile: Sendable, Equatable {
        case folder, image, unreadable, tooLarge
        case zip(Data)
        case profile(Data)
    }

    /// Off the main actor (a FIFO or a stalled network mount must never hang the UI): `open(O_NONBLOCK)` (a FIFO with no
    /// writer doesn't block the open), `fstat` on the descriptor must say S_IFREG (FIFOs, devices and sockets are
    /// refused), and the size cap is checked before a byte is read. Symlinks are followed (a user's own linked profile
    /// file is fine); `fstat` judges what was actually opened.
    nonisolated static func readChosen(_ url: URL) -> ReadFile {
        let lower = url.lastPathComponent.lowercased()
        if [".png", ".jpg", ".jpeg", ".heic"].contains(where: lower.hasSuffix) { return .image }
        let isZip = lower.hasSuffix(".zip")
        let cap = isZip ? ZipCaps().maxArchiveBytes : lower.hasSuffix(".conf") ? 64 * 1024 : OVPNImportLimits.maxRawBytes
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .unreadable }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return .folder
        case S_IFREG: break
        default: return .unreadable
        }
        guard st.st_size <= off_t(cap) else { return isZip ? .tooLarge : .unreadable }
        // Regular file: O_NONBLOCK has no effect on reads. Read to EOF, never past cap + 1 (a file growing meanwhile).
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count <= cap {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, cap + 1 - out.count)) }
            if n < 0 { if errno == EINTR { continue }; return .unreadable }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        guard out.count <= cap else { return isZip ? .tooLarge : .unreadable }
        return isZip ? .zip(out) : .profile(out)
    }

    /// Round 2 (Fable L7): a read that hasn't finished after this (a stalled network mount) is given up as unreadable;
    /// the detached read is left to finish or hang on its own. Tests shorten it.
    var readTimeout: Duration = .seconds(10)

    /// Round 3 (Fable L4): reads run on this private queue, never on Swift's cooperative pool: a read that hangs (a stalled
    /// network mount) blocks one of its threads, not a thread every task of the app shares. Reads given up while still
    /// running count in `hungReads`; at `maxHungReads` a new read is refused at once (until one of them returns), so hung
    /// reads can't pile up threads without bound.
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "import")
    nonisolated static let readQueue = DispatchQueue(label: "io.github.steiale.lockplus.import-read", qos: .userInitiated,
                                                     attributes: .concurrent)
    static let maxHungReads = 4
    /// Reads given up while still running (they decrement it themselves, from the queue, when they return).
    var hungReads: Int { hung.count.withLock { $0 } }
    private let hung = HungReads()
    private final class HungReads: Sendable { let count = Mutex(0) }

    /// Tests: what the private queue runs for a path (the real read by default).
    var readFile: @Sendable (URL) -> ReadFile = { ImportCoordinator.readChosen($0) }

    /// One path, read on `readQueue` within `readTimeout`. A read that times out is `.unreadable` now; its thread is
    /// counted in `hungReads` until it returns.
    private func read(_ url: URL) async -> ReadFile {
        guard hungReads < Self.maxHungReads else {
            log.error("import read refused: \(self.hungReads, privacy: .public) earlier reads still hang")
            return .unreadable
        }
        let state = Mutex<(done: Bool, gaveUp: Bool)>((false, false))
        let readFile = readFile, hung = hung
        let result = await withDeadline(readTimeout, onTimeout: ReadFile?.none) {
            await withCheckedContinuation { (k: CheckedContinuation<ReadFile?, Never>) in
                Self.readQueue.async { @Sendable in
                    let r = readFile(url)
                    // The decrement and the increment below are ordered by `state`: a read that returns after it was given
                    // up is counted exactly once, either way round.
                    state.withLock { s in
                        s.done = true
                        if s.gaveUp { hung.count.withLock { $0 -= 1 } }
                    }
                    k.resume(returning: r)
                }
            }
        }
        if let result { return result }
        state.withLock { s in
            guard !s.done else { return }
            s.gaveUp = true
            hung.count.withLock { $0 += 1 }
        }
        return .unreadable
    }

    func importFiles(_ urls: [URL]) {
        analysing += 1                        // round 3 (Codex r3 #7): the slot is taken before the task exists
        running = Task { @MainActor in await importChosen(urls, opened: false) }
    }

    /// The caller has already counted this import in `analysing` (synchronously, Codex r3 #7); it is released here.
    private func importChosen(_ urls: [URL], opened: Bool) async {
        // Round 2 (Fable L7): every import counts as analysing, from its first read to its sheet, so an open event never
        // runs beside one the user started.
        defer {
            analysing -= 1
            analysingChanged()
        }
        var files: [(String, [UInt8], String?)] = []
        var capErrors: [String] = []
        var archiveName: String?
        for url in urls {
            let name = url.lastPathComponent
            // Round 3 (Fable L4): the first read that fails or times out ends this import (the remaining files of the
            // event are not read: on a stalled mount each would hang a thread too).
            let read = await read(url)
            switch read {
            case .folder:
                model.errorMessage = String(localized: "\(name) is a folder. Choose the profile files inside it.", comment: "Import error")
                return
            case .image:
                model.errorMessage = String(localized: "Images aren't supported.", comment: "Import error: dropped image")
                return
            case .tooLarge:
                model.errorMessage = ZipArchiveError.tooLarge.message(archive: name)
                return
            case .unreadable:
                model.errorMessage = String(localized: "\(name) can't be read.", comment: "Import error")
                return
            case .zip(let data):
                // In the validator service (sandboxed, its own process): validating and inflating up to 64 MB is not
                // the app's work, and a hostile archive can only hurt the service.
                let result: Result<ZipProfiles, ZipArchiveError>
                do throws(ZipArchiveError) { result = .success(try await zipReader.read(data)) } catch { result = .failure(error) }
                switch result {
                case .success(let r):
                    files += r.entries.map { ($0.name, $0.bytes, name) }
                    capErrors += r.issues.map(\.message)
                    archiveName = name
                case .failure(let e):
                    model.errorMessage = e.message(archive: name)
                    return
                }
            case .profile(let d):
                files.append((name, Array(d), nil))
            }
        }
        await analyseAndPresent(files, archiveName: archiveName, capErrors: capErrors,
                                openedFrom: opened ? Self.sourceDescription(urls) : nil)
    }

    // MARK: Open events (2.0.2 item 4; round 1, Fable L2)

    /// Open events (Finder, Open With, a Dock drop, `open -a LockPlus f.ovpn`) waiting for the shown sheet or the running
    /// analysis: one event at a time, never replacing what the user is looking at.
    private var openQueue: [[URL]] = []
    /// Round 2 (Fable L7): imports between their first read and their sheet, of every kind (chosen, dropped, pasted,
    /// opened). An open event starts only when this is zero and no sheet is up.
    private(set) var analysing = 0
    private var watchingSheets = false
    /// Round 2 (Fable L7): open events waiting at most; one more is refused with one message until the queue drains.
    static let maxQueuedOpenEvents = 5
    private var refusedOpenEvents = false
    /// Sheet-free waiters of opened analyses that finished while a sheet was up.
    private var sheetWaiters: [CheckedContinuation<Void, Never>] = []

    /// The import of an open event. Its sheet names where the files came from and has no default button (a stray
    /// Return can't confirm what another process just opened); while a preview or batch is shown or an analysis runs,
    /// the event waits its turn.
    func importOpened(_ urls: [URL]) {
        guard openQueue.count < Self.maxQueuedOpenEvents else {
            if !refusedOpenEvents {
                refusedOpenEvents = true
                model.errorMessage = String(localized: "Too many files were opened at once. Import the rest with File › Import… once these are done.",
                                            comment: "Import error (2.0.2 round 2): more than 5 open events were waiting")
            }
            return
        }
        openQueue.append(urls)
        drainOpenQueue()
    }

    var queuedOpenEvents: Int { openQueue.count }

    private var sheetShown: Bool { model.preview != nil || model.batch != nil }
    private var isBusy: Bool { sheetShown || analysing > 0 }

    private func drainOpenQueue() {
        guard !openQueue.isEmpty else { refusedOpenEvents = false; return }
        guard !isBusy else { if sheetShown { watchSheets() }; return }
        let urls = openQueue.removeFirst()
        // Round 3 (Codex r3 #7): busy from here, synchronously: an open event arriving before this task runs queues
        // (and counts against the cap) instead of starting beside it.
        analysing += 1
        running = Task { @MainActor in await importChosen(urls, opened: true) }
    }

    /// An import finished (its sheet is up or it failed): opened analyses waiting for the user's own wake up and re-check;
    /// at zero the next open event may start.
    private func analysingChanged() {
        wakeSheetWaiters()
        if analysing == 0 { drainOpenQueue() }
    }

    private func wakeSheetWaiters() {
        let w = sheetWaiters
        sheetWaiters = []
        for k in w { k.resume() }
    }

    /// Re-checks the queue (and wakes opened analyses waiting to present) once the shown sheet is gone (however it went:
    /// Import, Cancel, Done, Escape).
    private func watchSheets() {
        guard !watchingSheets else { return }
        watchingSheets = true
        withObservationTracking { _ = model.preview; _ = model.batch } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watchingSheets = false
                if !self.sheetShown {
                    self.wakeSheetWaiters()
                } else {
                    self.watchSheets()
                }
                self.drainOpenQueue()
            }
        }
    }

    /// Round 2 (Fable L7): an opened import is presented only when no sheet is up (one the user started meanwhile stays).
    /// Round 3 (Fable N5): nor while another import (the user's own, begun after this one) is still being analysed: that
    /// one presents first. The sheet watch is re-armed on every pass (a sheet that appeared between the wake-up and the
    /// re-check would otherwise never wake this waiter).
    private func waitForNoSheet() async {
        while sheetShown || analysing > 1 {
            if sheetShown { watchSheets() }
            await withCheckedContinuation { sheetWaiters.append($0) }
        }
    }

    /// "~/Downloads/work.ovpn"; for several files in one folder that folder; else the folders, comma-separated.
    /// Round 2 (Fable N4): the path is chosen by whoever opened the file. Only the real home folder becomes "~"; a folder
    /// whose own name starts with "~" is shown in quotes, so "/tmp/~/Downloads" can't read as the home folder. The sheet
    /// shows the whole description (no truncation).
    nonisolated static func sourceDescription(_ urls: [URL]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func quoted(_ p: Substring) -> String {
            p.split(separator: "/", omittingEmptySubsequences: false).map { $0.hasPrefix("~") ? "“\($0)”" : String($0) }.joined(separator: "/")
        }
        func tilde(_ p: String) -> String { p.hasPrefix(home + "/") ? "~" + quoted(p.dropFirst(home.count)) : quoted(Substring(p)) }
        if urls.count == 1, let u = urls.first { return tilde(u.standardizedFileURL.path) }
        var dirs: [String] = []
        for u in urls {
            let d = tilde(u.standardizedFileURL.deletingLastPathComponent().path)
            if !dirs.contains(d) { dirs.append(d) }
        }
        return dirs.joined(separator: ", ")
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
        analysing += 1
        Task { @MainActor in
            await analyseAndPresent([(name, bytes, nil)], archiveName: nil, capErrors: [])
            analysing -= 1
            analysingChanged()
        }
    }

    func analyseAndPresent(_ files: [(String, [UInt8], String?)], archiveName: String?, capErrors: [String],
                           openedFrom: String? = nil) async {
        guard !files.isEmpty else {
            // A zip whose every profile entry was skipped: say why, never nothing (§3.5 "errors, not silent truncation").
            if !capErrors.isEmpty { model.errorMessage = capErrors.joined(separator: "\n") }
            return
        }
        var results: [AnalysedImport] = []
        for (name, bytes, archive) in files {
            var r = await Self.analyse(fileName: name, bytes: bytes, validator: validator, probe: probe, resolve: resolveEndpoints)
            r.archive = archive
            results.append(r)
        }
        if openedFrom != nil { await waitForNoSheet() }
        let defaults = settings.value.newProfileDefaults
        if results.count == 1, archiveName == nil, let r = results.first {
            let id = UUID()
            pending = [id: r]
            model.preview = ImportPreview(id: id, fileName: r.fileName, name: r.displayName, kind: r.kind, summary: r.summary,
                                          report: r.report, killSwitch: r.summary.isFullTunnel && defaults.killSwitch,
                                          allowLocalNetwork: defaults.allowLAN, openedFrom: openedFrom)
        } else {
            pending = [:]
            var items: [BatchImportItem] = []
            for r in results {
                let id = UUID()
                pending[id] = r
                items.append(BatchImportItem(id: id, fileName: r.fileName, selected: r.verdict != .rejected, report: r.report))
            }
            model.batch = BatchImport(id: UUID(), archiveName: archiveName ?? String(localized: "\(results.count) files", comment: "Batch import title"),
                                      items: items, capErrors: capErrors, openedFrom: openedFrom)
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
