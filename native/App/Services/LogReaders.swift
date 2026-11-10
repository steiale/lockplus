import Foundation
import OSLog

/// One log line, before redaction.
struct LogLine: Sendable, Equatable {
    var date: Date
    var level: LogEntry.Level
    var source: LogEntry.Source
    var category: String
    var message: String
}

/// Where log lines come from. Live: `OSLogStore` for the app, `/usr/bin/log show` for the extension; preview mode and
/// tests use fixtures.
protocol LogSources: Sendable {
    func appLines(since: Date) async -> [LogLine]
    /// `.failure(reason)` documents the gap in the bundle (e.g. a non-admin account can't read the unified log).
    func tunnelLines(since: Date) async -> Result<[LogLine], LogReadGap>
}

struct LogReadGap: Error, Sendable, Equatable { var reason: String }

enum LogSubsystem {
    static let app = "io.github.steiale.lockplus.mac"
    static let tunnel = "io.github.steiale.lockplus.mac.tunnel"
}

/// The extension's logs: owner-safe without any XPC surface (review M1). `recentLogs` is gone and the extension's
/// LogRing is not delivered anywhere. The extension's `Logger` output is read with `/usr/bin/log show`, run as the
/// user: macOS already redacts every `.private` value (`<private>`), the command shows only what this account may
/// read anyway (admins: the unified log; others get "not permitted", recorded as a gap), and the app's Redactor runs
/// over the result as for every other file.
struct LiveLogSources: LogSources {
    func appLines(since: Date) async -> [LogLine] {
        await Blocking.run { () -> [LogLine] in
            // §14.2: `.currentProcessIdentifier` (no entitlement); `.private` values are visible to the writer, so the
            // caller always passes these lines through the Redactor.
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
            let position = store.position(date: since)
            let predicate = NSPredicate(format: "subsystem == %@", LogSubsystem.app)
            guard let entries = try? store.getEntries(at: position, matching: predicate) else { return [] }
            var out: [LogLine] = []
            for case let e as OSLogEntryLog in entries where e.date >= since {
                out.append(LogLine(date: e.date, level: Self.level(e.level), source: .app, category: e.category, message: e.composedMessage))
                if out.count >= 20_000 { break }
            }
            return out
        }
    }

    static func level(_ l: OSLogEntryLog.Level) -> LogEntry.Level {
        switch l {
        case .debug: .debug
        case .info, .notice, .undefined: .info
        case .error: .warning
        case .fault: .error
        @unknown default: .info
        }
    }

    func tunnelLines(since: Date) async -> Result<[LogLine], LogReadGap> {
        let start = Self.logShowDate.string(from: since)
        guard let out = await ProcessRunner.run("/usr/bin/log", ["show", "--style", "ndjson", "--info", "--start", start,
                                                                "--predicate", "subsystem == \"\(LogSubsystem.tunnel)\""],
                                                timeout: .seconds(20), maxBytes: 16 << 20) else {
            return .failure(LogReadGap(reason: "`log show` failed: this account may not read the unified log (admin required)."))
        }
        return .success(Self.parseNDJSON(out))
    }

    static var logShowDate: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }

    /// `log show --style ndjson`: one JSON object per line (`timestamp`, `messageType`, `category`, `eventMessage`).
    static func parseNDJSON(_ text: String) -> [LogLine] {
        let ts = DateFormatter()
        ts.locale = Locale(identifier: "en_US_POSIX")
        ts.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        var out: [LogLine] = []
        for line in text.split(separator: "\n") where line.hasPrefix("{") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msg = obj["eventMessage"] as? String else { continue }
            let date = (obj["timestamp"] as? String).flatMap { ts.date(from: $0) } ?? Date.distantPast
            let level: LogEntry.Level = switch (obj["messageType"] as? String ?? "").lowercased() {
            case "debug": .debug
            case "error": .warning
            case "fault": .error
            default: .info
            }
            out.append(LogLine(date: date, level: level, source: .tunnel, category: obj["category"] as? String ?? "", message: msg))
        }
        return out
    }
}

/// Preview mode and tests.
struct FixtureLogSources: LogSources {
    var app: [LogLine] = []
    var tunnel: Result<[LogLine], LogReadGap> = .success([])
    func appLines(since: Date) async -> [LogLine] { app.filter { $0.date >= since } }
    func tunnelLines(since: Date) async -> Result<[LogLine], LogReadGap> { tunnel.map { $0.filter { $0.date >= since } } }

    static var preview: FixtureLogSources {
        let now = Date()
        func l(_ s: TimeInterval, _ lvl: LogEntry.Level, _ src: LogEntry.Source, _ cat: String, _ m: String) -> LogLine {
            LogLine(date: now.addingTimeInterval(-s), level: lvl, source: src, category: cat, message: m)
        }
        return FixtureLogSources(
            app: [l(300, .info, .app, "lifecycle", "extension ready 2.0.0 (preview)"),
                  l(240, .info, .app, "connection", "connect Work (manual)"),
                  l(120, .warning, .app, "diagnostics", "DNS unverified: a test query didn't complete")],
            tunnel: .success([l(239, .info, .tunnel, "controller", "session start phase=connecting"),
                              l(238, .info, .tunnel, "engine.wg", "handshake complete with peer vpn.example.com:51820"),
                              l(60, .warning, .tunnel, "watchdog", "no handshake for 180 s; reasserting")]))
    }
}
