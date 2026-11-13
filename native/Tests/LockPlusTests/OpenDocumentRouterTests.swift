import Foundation
import SwiftUI
import Testing
@testable import LockPlus

@MainActor @Suite struct OpenDocumentRouterTests {
    @MainActor private final class Recorder {
        var events: [String] = []
        var imported: [[URL]] = []
        var errors: [String] = []
        var sink: OpenDocumentRouter.Sink {
            OpenDocumentRouter.Sink(openMainWindow: { self.events.append("window") },
                                    importFiles: { self.events.append("import"); self.imported.append($0) },
                                    showError: { self.events.append("error"); self.errors.append($0) })
        }
    }

    private func files(_ n: Int) -> [URL] { (0..<n).map { URL(fileURLWithPath: "/Users/x/f\($0).ovpn") } }

    @Test func queuesUntilEnvironmentReady() {
        let r = OpenDocumentRouter(), rec = Recorder()
        r.enqueue(files(1))
        r.enqueue([URL(fileURLWithPath: "/Users/x/home.conf")])
        #expect(rec.events.isEmpty)
        r.environmentReady(rec.sink)
        #expect(rec.imported.count == 1)
        #expect(rec.imported[0].map(\.lastPathComponent) == ["f0.ovpn", "home.conf"])
        // Afterwards events run at once.
        r.enqueue(files(1))
        #expect(rec.imported.count == 2)
    }

    @Test func flushOpensMainWindowThenImports() {
        let r = OpenDocumentRouter(), rec = Recorder()
        r.environmentReady(rec.sink)
        r.enqueue(files(2))
        #expect(rec.events == ["window", "import"])
    }

    @Test func moreThan20IsRefused() {
        let r = OpenDocumentRouter(), rec = Recorder()
        r.environmentReady(rec.sink)
        r.enqueue(files(21))
        #expect(rec.imported.isEmpty)
        #expect(rec.errors == ["Open at most 20 files at a time."])
        r.enqueue(files(20))
        #expect(rec.imported.count == 1)
        #expect(OpenDocumentRouter.plan(files(21)) == .tooMany(21))
        #expect(OpenDocumentRouter.plan(files(20)) == .importFiles(files(20)))
    }

    @Test func coldLaunchEventsCountTogether() {
        let r = OpenDocumentRouter(), rec = Recorder()
        r.enqueue(files(12))
        r.enqueue((12..<24).map { URL(fileURLWithPath: "/Users/y/g\($0).ovpn") })
        r.environmentReady(rec.sink)
        #expect(rec.imported.isEmpty)
        #expect(rec.errors.count == 1)
    }

    @Test func nonFileURLsDropped() {
        let web = URL(string: "https://example.com/a.ovpn")!
        let custom = URL(string: "lockplus://import?x=1")!
        #expect(OpenDocumentRouter.plan([web, custom]) == .nothing)
        let f = URL(fileURLWithPath: "/Users/x/a.ovpn")
        #expect(OpenDocumentRouter.plan([web, f, custom]) == .importFiles([f]))
        let r = OpenDocumentRouter(), rec = Recorder()
        r.environmentReady(rec.sink)
        r.enqueue([web, custom])
        #expect(rec.events.isEmpty)                  // nothing: not even a window
    }

    @Test func duplicatesCollapse() {
        let f = URL(fileURLWithPath: "/Users/x/a.ovpn")
        #expect(OpenDocumentRouter.plan([f, f, URL(fileURLWithPath: "/Users/x/./a.ovpn")]) == .importFiles([f]))
    }

    @Test func directoryGoesToTheImporterFolderMessage() {
        // The router does not stat: a directory is passed on and ImportCoordinator answers "… is a folder".
        let dir = URL(fileURLWithPath: "/Users/x/Profiles", isDirectory: true)
        #expect(OpenDocumentRouter.plan([dir]) == .importFiles([dir]))
    }

    /// Sonnet L10: 50 × 100 DISTINCT paths; the queue never holds more than `maxQueuedURLs`, and the flush refuses them.
    @Test func queueIsBounded() {
        let r = OpenDocumentRouter(), rec = Recorder()
        for i in 0..<50 {
            r.enqueue((0..<100).map { URL(fileURLWithPath: "/Users/x/h\(i)-\($0).ovpn") })
            #expect(r.queuedCount <= OpenDocumentRouter.maxQueuedURLs)
        }
        #expect(r.queuedCount == OpenDocumentRouter.maxQueuedURLs)
        r.environmentReady(rec.sink)
        #expect(rec.errors.count == 1 && rec.imported.isEmpty && r.queuedCount == 0)
    }
}

/// Round 1 (Fable L2, L3; Codex 11): what the importer does with an opened file.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct OpenedImportTests {
    func write(_ h: Harness, _ name: String, _ text: String) throws -> URL {
        let u = h.dir.url.appending(path: name)
        try Data(text.utf8).write(to: u)
        return u
    }

    @Test func readsOnlyRegularFilesAndNeverBlocks() throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let fifo = h.dir.url.appending(path: "x.ovpn")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(ImportCoordinator.readChosen(fifo) == .unreadable)              // returns at once: no writer, no hang
        let link = h.dir.url.appending(path: "link.ovpn")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        #expect(ImportCoordinator.readChosen(link) == .unreadable)              // a link to a FIFO: fstat judges the target
        let good = try write(h, "good.conf", Harness.wgConf)
        let goodLink = h.dir.url.appending(path: "goodlink.conf")
        try FileManager.default.createSymbolicLink(at: goodLink, withDestinationURL: good)
        #expect(ImportCoordinator.readChosen(good) == .profile(Data(Harness.wgConf.utf8)))
        #expect(ImportCoordinator.readChosen(goodLink) == .profile(Data(Harness.wgConf.utf8)))   // a user's own link is fine
        #expect(ImportCoordinator.readChosen(h.dir.url) == .folder)
        #expect(ImportCoordinator.readChosen(h.dir.url.appending(path: "missing.ovpn")) == .unreadable)
        #expect(ImportCoordinator.readChosen(URL(fileURLWithPath: "/dev/null")) == .unreadable)          // a device
        let big = try write(h, "big.conf", String(repeating: "#", count: 64 * 1024 + 1))
        #expect(ImportCoordinator.readChosen(big) == .unreadable)              // over the cap: not read at all
        #expect(ImportCoordinator.readChosen(URL(fileURLWithPath: "/x/qr.png")) == .image)
    }

    @Test func aFIFOOpenedFromFinderDoesNotHangTheImporter() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let fifo = h.dir.url.appending(path: "x.ovpn")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        h.env.importer.importOpened([fifo])
        await h.env.importer.idle()
        #expect(h.env.ui.importer.errorMessage == "x.ovpn can't be read.")
    }

    @Test func anOpenedFileNamesItsSourceAndAnOwnImportDoesNot() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let u = try write(h, "Work.conf", Harness.wgConf)
        h.env.importer.importOpened([u])
        await h.env.importer.idle()
        let p = try #require(h.env.ui.importer.preview)
        #expect(p.openedFrom == ImportCoordinator.sourceDescription([u]) && p.openedFrom?.hasSuffix("/Work.conf") == true)
        #expect(OpenedImportGuard.shortcut(openedFrom: p.openedFrom) == nil)    // no default button
        h.env.importer.cancel()
        h.env.importer.importFiles([u])
        await h.env.importer.idle()
        #expect(h.env.ui.importer.preview?.openedFrom == nil)
        #expect(OpenedImportGuard.shortcut(openedFrom: nil) == .defaultAction)
    }

    /// A second open event while a preview is shown waits; it never replaces the sheet the user is looking at.
    @Test func aSecondOpenEventQueuesBehindTheShownSheet() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let mine = try write(h, "Mine.conf", Harness.wgConf)
        let theirs = try write(h, "Theirs.conf", Harness.splitConf)
        h.env.importer.importOpened([mine])
        await h.env.importer.idle()
        let first = try #require(h.env.ui.importer.preview)
        h.env.importer.importOpened([theirs])
        await h.env.importer.idle()
        #expect(h.env.ui.importer.preview == first)
        #expect(h.env.importer.queuedOpenEvents == 1)
        h.env.importer.cancel()                                                  // the user closes the first sheet
        #expect(await eventually { h.env.ui.importer.preview?.fileName == "Theirs.conf" })
        #expect(h.env.importer.queuedOpenEvents == 0)
        // The same when the sheet goes some other way (Escape: the presentation clears the model).
        h.env.importer.importOpened([mine])
        h.env.ui.importer.preview = nil
        #expect(await eventually { h.env.ui.importer.preview?.fileName == "Mine.conf" })
    }

    @Test func sourceDescription() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ImportCoordinator.sourceDescription([URL(fileURLWithPath: home + "/Downloads/w.ovpn")]) == "~/Downloads/w.ovpn")
        #expect(ImportCoordinator.sourceDescription([URL(fileURLWithPath: "/tmp/a/x.conf"), URL(fileURLWithPath: "/tmp/a/y.conf"),
                                                     URL(fileURLWithPath: "/srv/z.conf")]) == "/tmp/a, /srv")
    }
}
