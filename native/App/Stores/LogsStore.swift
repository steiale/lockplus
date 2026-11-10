import Foundation
import Observation

/// `LogsStore` (DESIGN §11.2, UI-CONCEPT §6.12): the merged app + tunnel log the Logs section reads. Every line passes
/// the bundle's `Redactor` before it reaches the UI, so Copy/Save never carry a secret, a host or an SSID. Refreshes
/// while a consumer (the main window) is visible; "Clear" sets a floor so cleared lines don't come back.
@MainActor final class LogsStore {
    static let cap = 5000
    static let refreshInterval: Duration = .seconds(5)

    private let sources: any LogSources
    private let model: LogsUIModel
    /// A fresh Redactor (with the current sensitive literals) per refresh.
    var redactorFactory: () -> Redactor
    private(set) var floor: Date
    private(set) var tunnelGap: LogReadGap?
    private var nextID = 0
    private var lastAppDate: Date
    private var lastTunnelDate: Date
    private var pollTask: Task<Void, Never>?
    private var refreshing = false
    /// `log show` is a process spawn: at most every 30 s (review M10).
    static let tunnelInterval: TimeInterval = 30
    private var lastTunnelRead: Date?

    init(sources: any LogSources, model: LogsUIModel, redactor: @escaping () -> Redactor, now: Date = Date()) {
        self.sources = sources
        self.model = model
        redactorFactory = redactor
        floor = now.addingTimeInterval(-24 * 3600)
        lastAppDate = floor
        lastTunnelDate = floor
    }

    /// Reads what's new since the last refresh, redacts, merges by date and caps.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let started = Date()
        let app = await sources.appLines(since: lastAppDate)
        var tunnel: [LogLine] = []
        if lastTunnelRead.map({ started.timeIntervalSince($0) >= Self.tunnelInterval }) ?? true {
            lastTunnelRead = started
            switch await sources.tunnelLines(since: lastTunnelDate) {
            case .success(let l): tunnel = l; tunnelGap = nil
            case .failure(let g): tunnelGap = g
            }
        }
        if model.tunnelLogsGap != tunnelGap?.reason { model.tunnelLogsGap = tunnelGap?.reason }
        let fresh = (app + tunnel).filter { $0.date >= floor && $0.date > (($0.source == .app) ? lastAppDate : lastTunnelDate) }
        if let d = app.map(\.date).max() { lastAppDate = max(lastAppDate, d) }
        if let d = tunnel.map(\.date).max() { lastTunnelDate = max(lastTunnelDate, d) }
        // M10: never rescan 24 h again: the next read starts near this one even when nothing was logged.
        lastAppDate = max(lastAppDate, started.addingTimeInterval(-2))
        if lastTunnelRead == started { lastTunnelDate = max(lastTunnelDate, started.addingTimeInterval(-2)) }
        guard !fresh.isEmpty else { return }
        let r = redactorFactory()
        var added: [LogEntry] = []
        for l in fresh.sorted(by: { $0.date < $1.date }) {
            nextID += 1
            let text = l.category.isEmpty ? l.message : "[\(l.category)] \(l.message)"
            added.append(LogEntry(id: nextID, date: l.date, level: l.level, source: l.source, message: r.redact(text)))
        }
        var all = model.entries + added
        all.sort { ($0.date, $0.id) < ($1.date, $1.id) }
        model.entries = Array(all.suffix(Self.cap))
    }

    func clear() {
        floor = Date()
        lastAppDate = floor
        lastTunnelDate = floor
        model.entries = []
    }

    /// The main window is visible: poll; hidden: stop (§11.2 "polling stops while no consumer").
    func setVisible(_ visible: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard visible else { return }
        let interval = Self.refreshInterval
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval, tolerance: .seconds(1))
            }
        }
    }

    isolated deinit { pollTask?.cancel() }
}
