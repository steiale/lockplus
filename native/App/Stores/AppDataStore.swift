import Foundation
import os
import Synchronization

/// The app data directory (DESIGN §3.3): `~/Library/Application Support/<bundle ID>/`, 0700, never `lockplus`.
/// Preview mode and tests pass their own root.
struct AppDataDirectory: Sendable {
    let root: URL

    var profiles: URL { root.appending(path: "profiles", directoryHint: .isDirectory) }
    var settings: URL { root.appending(path: "settings.json") }
    var history: URL { root.appending(path: "history.json") }
    var migration: URL { root.appending(path: "migration.json") }
    /// §10.4: held by every GUI instance; the headless resume agent takes it non-blocking.
    var instanceLock: URL { root.appending(path: "instance.lock") }
    /// Non-secret credential facts (user names, "password saved" flags), Fable L3.
    var credentialFacts: URL { root.appending(path: "credential-facts.json") }

    static func standard(bundleID: String = Bundle.main.bundleIdentifier ?? "io.github.steiale.lockplus.mac") -> AppDataDirectory {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppDataDirectory(root: base.appending(path: bundleID, directoryHint: .isDirectory))
    }
}

/// Atomic file I/O for the app's JSON and sealed files (§3.4): temp file in the same directory, `F_FULLFSYNC`,
/// `rename`; 0600 files in 0700 directories. Corrupt JSON is moved aside (`*.corrupt.<UTC>`) and logged, never fatal.
enum AtomicFile {
    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "files")

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(url.path, 0o700)
    }

    static func write(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(tmp.path) }
        }
        try data.withUnsafeBytes { b in
            var off = 0
            while off < b.count {
                let n = Darwin.write(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                off += n
            }
        }
        _ = fcntl(fd, F_FULLFSYNC)
        guard rename(tmp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        ok = true
    }

    /// A file in a USER-chosen place (exports, logs, diagnostics; Fable M2): the directory is never created or
    /// chmod-ed; the temp file is `O_CREAT|O_EXCL|O_NOFOLLOW` 0600 next to the target, then renamed over it (the save
    /// panel already confirmed a replace).
    static func writeUserFile(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(tmp.path) }
        }
        try data.withUnsafeBytes { b in
            var off = 0
            while off < b.count {
                let n = Darwin.write(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                off += n
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard rename(tmp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        ok = true
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext`… so an export never replaces a file it didn't ask about (L1).
    static func unusedURL(in dir: URL, name: String, ext: String) -> URL {
        var url = dir.appending(path: "\(name).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true {
            url = dir.appending(path: "\(name) \(i).\(ext)")
            i += 1
        }
        return url
    }

    /// FA-L7: a file we didn't create (crash reports): `open(O_NOFOLLOW)`, then `fstat` on the descriptor (regular
    /// file only), so a symlink swapped in between a check and the read can't redirect it.
    static func readNoFollow(_ url: URL, maxBytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= off_t(maxBytes) else { return nil }
        var out = Data(count: Int(st.st_size))
        let n = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n >= 0 else { return nil }
        return out.prefix(n)
    }

    static func read(_ url: URL, maxBytes: Int = 16 << 20) -> Data? {
        if case .success(let d) = readResult(url, maxBytes: maxBytes) { return d }
        return nil
    }

    /// Why a read failed: the file isn't there (a first launch), or it exists and couldn't be read (`errno`, or a
    /// size over the cap). Settings tell the two apart (E2E-4: a failed read must never become silent defaults).
    enum ReadFailure: Error, Equatable {
        case missing
        case unreadable(String)
    }

    static func readResult(_ url: URL, maxBytes: Int = 16 << 20) -> Result<Data, ReadFailure> {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            let e = errno
            return .failure(e == ENOENT ? .missing : .unreadable(String(cString: strerror(e))))
        }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            let d = try h.read(upToCount: maxBytes + 1) ?? Data()
            guard d.count <= maxBytes else { return .failure(.unreadable("larger than \(maxBytes) bytes")) }
            return .success(d)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    /// Moves a damaged file aside: `<name>.<suffix>.<UTC>`.
    static func quarantine(_ url: URL, suffix: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dest = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).\(suffix).\(stamp)")
        do { try FileManager.default.moveItem(at: url, to: dest) } catch {
            log.error("could not move \(url.lastPathComponent, privacy: .public) aside: \(error.localizedDescription, privacy: .public)")
        }
        log.error("moved \(url.lastPathComponent, privacy: .public) aside as \(suffix, privacy: .public)")
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Loads JSON; a file that fails to decode is quarantined as `corrupt` and `nil` is returned.
    static func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let d = read(url) else { return nil }
        do { return try decoder().decode(T.self, from: d) } catch {
            quarantine(url, suffix: "corrupt")
            return nil
        }
    }

    static func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try write(try encoder().encode(value), to: url)
    }

    /// 2.0.2 RC review (Fable N5): `write`'s temp files (`.<name>.<UUID>.tmp`) that a process ended mid-write left behind
    /// (the headless agent's hard deadline `_exit`s at any instruction). Same content class as the file they were for,
    /// so they go. Only regular files of exactly that shape, older than `minimumAge` (a write in flight in this process
    /// is never touched). Returns how many were removed.
    @discardableResult
    static func sweepOrphanTempFiles(in dir: URL, minimumAge: TimeInterval = 60, now: Date = Date()) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for name in names where isTempFileName(name) {
            let path = dir.appending(path: name).path
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) >= minimumAge else { continue }
            if unlink(path) == 0 { removed += 1 }
        }
        if removed > 0 { log.notice("removed \(removed, privacy: .public) leftover temporary file(s) in \(dir.lastPathComponent, privacy: .public)") }
        return removed
    }

    /// `.<name>.<UUID>.tmp`, as `write` and `writeUserFile` name them.
    static func isTempFileName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        let parts = name.dropFirst().dropLast(4).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let last = parts.last, !parts.dropLast().joined(separator: ".").isEmpty else { return false }
        return UUID(uuidString: String(last)) != nil
    }
}

/// settings.json, history.json and migration.json, off the main actor (§3.4: all I/O is off the main actor).
actor SettingsFileStore {
    let dir: AppDataDirectory
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "settings")
    /// Review N4: the sequence number (`SettingsStore`) of the newest settings.json on disk. A write is made under this
    /// lock and only if it is newer, so a value read before a later write can never land after it, whichever path
    /// (the queue, the quit path) each took.
    private let lastWritten = Mutex<UInt64>(0)

    init(dir: AppDataDirectory) { self.dir = dir }

    /// Fable N5: at GUI launch, under the instance lock (no headless run is writing), the temp files a process ended
    /// mid-write left in the data directory and its profiles directory.
    func sweepOrphanTempFiles() {
        AtomicFile.sweepOrphanTempFiles(in: dir.root)
        AtomicFile.sweepOrphanTempFiles(in: dir.profiles)
    }

    /// What `loadSettingsChecked` found (E2E-4). `movedAside`: the file existed but couldn't be read or decoded; it was
    /// renamed (kept, never overwritten) and defaults are used. Diagnostics says so.
    struct SettingsLoad: Sendable {
        var settings: AppSettings
        var movedAside: URL?
        var problem: String?
        /// E2E-4 review L6: the file that was dropped may have held Auto-Connect (or a pause of it); it is off now. True
        /// when the old file mentions it, and when it couldn't be read at all (unknown).
        var mayHaveHeldAutoConnect = false
    }

    /// A missing file → defaults (a first launch). A read error is retried once after `retryDelay` (a transient
    /// failure, e.g. the volume or a rename in progress); still unreadable, or undecodable → the file is moved aside as
    /// `settings.unreadable-<UTC>.json` and defaults are used, with the reason. Never silently defaults over a file.
    func loadSettingsChecked(retryDelay: Duration = .milliseconds(200)) async -> SettingsLoad {
        let url = dir.settings
        var r = AtomicFile.readResult(url, maxBytes: 1 << 20)
        if case .failure(.unreadable) = r {
            try? await Task.sleep(for: retryDelay)
            r = AtomicFile.readResult(url, maxBytes: 1 << 20)
        }
        let reason: String
        var mayHaveHeldAutoConnect = true
        switch r {
        case .failure(.missing):
            return SettingsLoad(settings: AppSettings())
        case .failure(.unreadable(let why)):
            reason = why
        case .success(let data):
            do { return SettingsLoad(settings: try AtomicFile.decoder().decode(AppSettings.self, from: data)) } catch {
                reason = "not valid settings JSON"
                let text = String(decoding: data, as: UTF8.self)
                mayHaveHeldAutoConnect = ["\"autoConnect\"", "\"pausedUntil\"", "\"pausedState\"", "\"onDemandPausedByStart\""].contains { text.contains($0) }
            }
        }
        let moved = Self.moveAside(url)
        log.error("settings.json unreadable (\(reason, privacy: .public)); moved aside: \(moved?.lastPathComponent ?? "failed", privacy: .public)")
        return SettingsLoad(settings: AppSettings(), movedAside: moved, problem: reason, mayHaveHeldAutoConnect: mayHaveHeldAutoConnect)
    }

    /// `settings.unreadable-<UTC>.json` next to it; nil if the rename failed (the next write then replaces the file,
    /// which is logged above).
    nonisolated static func moveAside(_ url: URL, now: Date = Date()) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let base = url.deletingPathExtension().lastPathComponent
        var dest = url.deletingLastPathComponent().appending(path: "\(base).unreadable-\(stamp).json")
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = url.deletingLastPathComponent().appending(path: "\(base).unreadable-\(stamp)-\(i).json")
            i += 1
        }
        do { try FileManager.default.moveItem(at: url, to: dest) } catch { return nil }
        return dest
    }

    /// The ordered queue's write (`SettingsStore.persist`).
    func save(_ s: AppSettings, seq: UInt64) { write(s, seq: seq) }

    /// The quit path only (the process exits right after): on the calling thread.
    nonisolated func saveNow(_ s: AppSettings, seq: UInt64) { write(s, seq: seq) }

    private nonisolated func write(_ s: AppSettings, seq: UInt64) {
        lastWritten.withLock { last in
            guard seq > last else { return }                  // a newer value is already on disk
            do {
                try AtomicFile.saveJSON(s, to: dir.settings)
                last = seq
            } catch {
                log.error("settings.json write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func loadHistory() -> [HistoryEntry] { AtomicFile.loadJSON([HistoryEntry].self, from: dir.history) ?? [] }

    func save(history: [HistoryEntry]) {
        do { try AtomicFile.saveJSON(Array(history.suffix(HistoryEntry.cap)), to: dir.history) } catch {
            log.error("history.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadMigrationMarker() -> MigrationMarker? { AtomicFile.loadJSON(MigrationMarker.self, from: dir.migration) }

    func save(marker: MigrationMarker) {
        do { try AtomicFile.saveJSON(marker, to: dir.migration) } catch {
            log.error("migration.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
