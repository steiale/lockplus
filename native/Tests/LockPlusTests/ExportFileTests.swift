import Foundation
import Testing
@testable import LockPlus

/// Fable M2 and review L1: user-chosen folders keep their permissions; exports never replace files silently and
/// never write hidden names.
@MainActor @Suite("Export files (FA-M2, AR-L1)", .serialized)
struct ExportFileTests {
    @Test func theUsersFolderKeepsItsPermissions() throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        chmod(dir.url.path, 0o755)
        let url = dir.url.appending(path: "a.conf")
        try AtomicFile.writeUserFile(Data("x".utf8), to: url)
        let dirPerm = try FileManager.default.attributesOfItem(atPath: dir.url.path)[.posixPermissions] as? Int
        let filePerm = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(dirPerm == 0o755)
        #expect(filePerm == 0o600)
        #expect(throws: (any Error).self) { try AtomicFile.writeUserFile(Data("x".utf8), to: dir.url.appending(path: "missing/b.conf")) }
    }

    @Test func namesAreUniqueAndNeverHidden() throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        #expect(AppActions.exportFileName("..hidden/evil:name") == "hidden-evil-name")
        #expect(AppActions.exportFileName("...") == "Profile")
        try Data().write(to: dir.url.appending(path: "Work.conf"))
        #expect(AtomicFile.unusedURL(in: dir.url, name: "Work", ext: "conf").lastPathComponent == "Work 2.conf")
        #expect(AtomicFile.unusedURL(in: dir.url, name: "Home", ext: "conf").lastPathComponent == "Home.conf")
    }
}
