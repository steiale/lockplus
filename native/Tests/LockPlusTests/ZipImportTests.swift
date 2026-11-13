import Foundation
import LPModel
import LPParsing
import Testing
@testable import LockPlus

/// 2.0.2: reading untrusted archives moved into the validator service (Packages/ProfileValidator, `ArchiveReaderTests`);
/// the app builds archives (export, diagnostics) and passes imported ones to the service.
@Suite("Zip export (§3.5, §14.2) and import messages")
struct ZipExportTests {
    static let wg = "[Interface]\nPrivateKey = aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gd28=\nAddress = 10.0.0.2/32\n"

    @Test func exportRoundTripsThroughZIPFoundation() throws {
        let files = (1...3).map { (path: "P\($0).conf", data: Data(Self.wg.utf8)) }
        let z = try ProfileZipWriter.archive(files)
        #expect(try ProfileZipWriter.entryNames(z) == ["P1.conf", "P2.conf", "P3.conf"])
        // Entries are written 0600 (central record external attributes, high 16 bits).
        func u32(_ o: Int) -> Int { (0..<4).reduce(0) { $0 | Int(z[z.startIndex + o + $1]) << (8 * $1) } }
        #expect(u32(u32(z.count - 6) + 38) >> 16 == 0o100600)
    }

    @Test func emptyFilesAndNestedPathsRoundTrip() throws {
        let z = try ProfileZipWriter.archive([(path: "a/b/empty.conf", data: Data()), (path: "c.ovpn", data: Data("x".utf8))])
        #expect(try ProfileZipWriter.entryNames(z) == ["a/b/empty.conf", "c.ovpn"])
    }

    @MainActor @Test func uniqueExportNames() {
        #expect(AppActions.uniqueEntryName("Work", ext: "conf", taken: ["work.conf", "Work 2.conf"]) == "Work 3.conf")
        #expect(AppActions.uniqueEntryName("Home", ext: "ovpn", taken: []) == "Home.ovpn")
        #expect(AppActions.exportFileName("a\\..\\b") == "a-..-b")
    }

    @Test func errorsHaveMessages() {
        #expect(ZipArchiveError.zip64.message(archive: "x.zip").contains("x.zip"))
        #expect(ZipArchiveError.checkUnavailable.message(archive: "x.zip").contains("x.zip"))
        #expect(ZipEntryIssue.symlink("a.ovpn").message.contains("a.ovpn"))
    }
}

/// The import flow end to end with a scripted archive reader (the service's `readArchive`): a .zip opens the batch sheet,
/// its profiles record `.zip(<archive>)`, and an archive whose every profile entry was skipped says why.
@MainActor @Suite("Zip import flow (§3.5, UI-CONCEPT §6.15)", .serialized)
struct ZipImportFlowTests {
    @Test func aZipOpensTheBatchSheetAndImports() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let url = h.dir.url.appending(path: "VPN.zip")
        try Data("PK".utf8).write(to: url)        // the fake reader never looks at the bytes
        let wg = Array(Harness.wgConf.utf8)
        let reader = FakeZipArchiveReader(.success(ZipProfiles(entries: [("Work.conf", wg), ("Home.conf", wg)], issues: [])))
        h.env.importer.zipReader = reader
        h.env.importer.importFiles([url])
        await h.env.importer.idle()
        #expect(reader.reads == 1)
        let batch = try #require(h.env.ui.importer.batch)
        #expect(batch.archiveName == "VPN.zip")
        #expect(batch.items.map(\.fileName) == ["Work.conf", "Home.conf"])
        #expect(batch.capErrors.isEmpty)
        h.env.importer.confirm(batch)
        await h.env.importer.idle()
        #expect(h.env.ui.importer.batch?.finished == true)
        #expect(h.env.profiles.profiles.count == 2)
        #expect(h.env.profiles.profiles.allSatisfy { $0.origin == .zip("VPN.zip") })

        // Every profile entry skipped: an alert with the reason, no empty sheet.
        let bad = h.dir.url.appending(path: "Links.zip")
        try Data("PK".utf8).write(to: bad)
        h.env.importer.zipReader = FakeZipArchiveReader(.success(ZipProfiles(entries: [], issues: [.symlink("link.ovpn")])))
        h.env.ui.importer.batch = nil
        h.env.importer.importFiles([bad])
        await h.env.importer.idle()
        #expect(h.env.ui.importer.errorMessage == ZipEntryIssue.symlink("link.ovpn").message)
        #expect(h.env.ui.importer.batch == nil)

        // An archive-level refusal names the archive.
        h.env.ui.importer.errorMessage = nil
        let enc = h.dir.url.appending(path: "Locked.zip")
        try Data("PK".utf8).write(to: enc)
        h.env.importer.zipReader = FakeZipArchiveReader(.failure(.encrypted))
        h.env.importer.importFiles([enc])
        await h.env.importer.idle()
        #expect(h.env.ui.importer.errorMessage == ZipArchiveError.encrypted.message(archive: "Locked.zip"))
    }
}
