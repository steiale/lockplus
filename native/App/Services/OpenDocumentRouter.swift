import Foundation
import os

/// Item 4 (2.0.2): documents opened from Finder, Open With or a Dock drop (`application(_:open:)`) reach the same import
/// flow as a drop into the window. Nothing is read, saved or provisioned here: the importer shows its preview/batch sheet
/// and only the user's confirm click saves (round 1, Fable L2: `ImportCoordinator.importOpened` queues behind a shown sheet,
/// names the source and offers no default button). A cold launch delivers the open event before the environment is ready, so
/// events queue until `environmentReady`.
@MainActor final class OpenDocumentRouter {
    /// More files than this in one open is refused outright (a Dock drop of a whole folder tree must not become a batch).
    nonisolated static let maxFilesPerOpen = 20
    /// Memory bound for the pre-launch queue: counted, never stored beyond this many URLs.
    static let maxQueuedURLs = 1000
    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "open-documents")

    enum Plan: Equatable {
        case importFiles([URL])
        case tooMany(Int)
        case nothing
    }

    /// The three effects of a flush, injectable for tests.
    struct Sink {
        var openMainWindow: @MainActor () -> Void
        var importFiles: @MainActor ([URL]) -> Void
        var showError: @MainActor (String) -> Void
    }

    private var pending: [URL] = []
    private var sink: Sink?
    /// Tests: how many URLs wait for `environmentReady`.
    var queuedCount: Int { pending.count }

    /// Pure: file URLs only (everything else is dropped), at most `maxFilesPerOpen`, duplicates removed in order.
    /// Directories pass through: the importer answers them with its folder message.
    nonisolated static func plan(_ urls: [URL]) -> Plan {
        var seen = Set<String>()
        let files = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
        if files.isEmpty { return .nothing }
        if files.count > maxFilesPerOpen { return .tooMany(files.count) }
        return .importFiles(files)
    }

    static let tooManyMessage = String(localized: "Open at most 20 files at a time.", comment: "Open documents: more than 20 files in one open")

    /// `application(_:open:)`. Runs now when the environment is ready, else queues.
    func enqueue(_ urls: [URL]) {
        let dropped = urls.count - urls.filter(\.isFileURL).count
        if dropped > 0 { Self.log.notice("dropped \(dropped, privacy: .public) non-file URL(s) from an open event") }
        let room = max(0, Self.maxQueuedURLs - pending.count)
        pending += urls.filter(\.isFileURL).prefix(room)
        if sink != nil { flush() }
    }

    /// Called once `env.start()` returned: flushes what arrived during launch, and from now on flushes at once.
    func environmentReady(_ env: AppEnvironment) {
        environmentReady(Sink(openMainWindow: { env.ui.actions.openMainWindow() },
                              importFiles: { env.importer.importOpened($0) },
                              showError: { env.ui.importer.errorMessage = $0 }))
    }

    func environmentReady(_ sink: Sink) {
        self.sink = sink
        flush()
    }

    private func flush() {
        guard let sink, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        // The main window first (switches .accessory → .regular and activates), then the import, so the sheet has a window.
        switch Self.plan(urls) {
        case .nothing: break
        case .importFiles(let files):
            sink.openMainWindow()
            sink.importFiles(files)
        case .tooMany(let n):
            Self.log.notice("open event refused: \(n, privacy: .public) files")
            sink.openMainWindow()
            sink.showError(Self.tooManyMessage)
        }
    }
}
