import Foundation
import Testing
@testable import LockPlus

/// A hand-built zip (stored entries) whose every field can be bent, for the crafted corpus (DESIGN §3.5, §15.4;
/// docs/native/reviews/2026-10-27-zipfoundation.md).
struct ZipFixture {
    struct Entry {
        var name: [UInt8]
        var data: [UInt8]
        var madeBy: UInt16 = 0x0315                 // Unix host, version 2.1
        var needed: UInt16 = 20
        var flags: UInt16 = 0x0800
        var method: UInt16 = 0
        var external: UInt32 = 0o100644 << 16
        var extra: [UInt8] = []
        var crc: UInt32?
        var compressedSize: UInt32?
        var uncompressedSize: UInt32?
        var localName: [UInt8]?
        var localOffset: UInt32?                     // overrides the real offset in the central record
        var descriptor = false

        init(_ name: String, _ text: String) { self.name = Array(name.utf8); data = Array(text.utf8) }
        init(name: [UInt8], data: [UInt8]) { self.name = name; self.data = data }
    }

    var entries: [Entry]
    var comment: [UInt8] = []
    var cdOffset: UInt32?
    var cdSize: UInt32?
    var count: UInt16?
    var disk: UInt16 = 0
    var zip64Locator = false

    init(_ entries: [Entry]) { self.entries = entries }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { le16(UInt16(v & 0xFFFF)) + le16(UInt16(v >> 16)) }

    static func crc32(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in b {
            c ^= UInt32(x)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }

    /// The local header, data and descriptor of one entry.
    static func local(_ e: Entry) -> [UInt8] {
        let crc = e.crc ?? crc32(e.data)
        let cs = e.compressedSize ?? UInt32(e.data.count), us = e.uncompressedSize ?? UInt32(e.data.count)
        let lname = e.localName ?? e.name
        var out = le32(0x0403_4b50) + le16(e.needed) + le16(e.flags) + le16(e.method) + le16(0) + le16(0)
        out += e.descriptor ? le32(0) + le32(0) + le32(0) : le32(crc) + le32(cs) + le32(us)
        out += le16(UInt16(lname.count)) + le16(UInt16(e.extra.count)) + lname + e.extra + e.data
        if e.descriptor { out += le32(0x0807_4b50) + le32(crc) + le32(cs) + le32(us) }
        return out
    }

    var data: Data {
        var out: [UInt8] = [], cd: [UInt8] = []
        for e in entries {
            let off = UInt32(out.count)
            let crc = e.crc ?? Self.crc32(e.data)
            let cs = e.compressedSize ?? UInt32(e.data.count), us = e.uncompressedSize ?? UInt32(e.data.count)
            out += Self.local(e)
            cd += Self.le32(0x0201_4b50) + Self.le16(e.madeBy) + Self.le16(e.needed) + Self.le16(e.flags) + Self.le16(e.method)
            cd += Self.le16(0) + Self.le16(0) + Self.le32(crc) + Self.le32(cs) + Self.le32(us)
            cd += Self.le16(UInt16(e.name.count)) + Self.le16(UInt16(e.extra.count)) + Self.le16(0) + Self.le16(0) + Self.le16(0)
            cd += Self.le32(e.external) + Self.le32(e.localOffset ?? off) + e.name + e.extra
        }
        let start = UInt32(out.count)
        out += cd
        if zip64Locator { out += Self.le32(0x0706_4b50) + Self.le32(0) + Self.le32(0) + Self.le32(0) + Self.le32(1) }
        let n = count ?? UInt16(entries.count)
        out += Self.le32(0x0605_4b50) + Self.le16(disk) + Self.le16(disk) + Self.le16(n) + Self.le16(n)
        out += Self.le32(cdSize ?? UInt32(cd.count)) + Self.le32(cdOffset ?? start) + Self.le16(UInt16(comment.count)) + comment
        return Data(out)
    }
}

/// Anchors `Bundle(for:)` to the test bundle.
private final class ZipFixtureBundle {}

/// Patches a little-endian UInt32 in an archive.
func patch32(_ d: inout Data, at o: Int, _ v: UInt32) {
    for i in 0..<4 { d[d.startIndex + o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
}

func u32(_ d: Data, _ o: Int) -> Int {
    (0..<4).reduce(0) { $0 | Int(d[d.startIndex + o + $1]) << (8 * $1) }
}

@Suite("Zip import (§3.5): crafted corpus, caps, ZIPFoundation review mitigations")
struct ZipImportTests {
    static let wg = "[Interface]\nPrivateKey = aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gd28=\nAddress = 10.0.0.2/32\n"

    func read(_ d: Data, caps: ZipCaps = ZipCaps()) throws(ZipArchiveError) -> ZipProfiles { try ProfileZipReader.read(d, caps: caps) }

    func archiveError(_ d: Data, caps: ZipCaps = ZipCaps()) -> ZipArchiveError? {
        do throws(ZipArchiveError) { _ = try read(d, caps: caps); return nil } catch { return error }
    }

    // MARK: Accepted input

    @Test func storedNestedAndMetadataEntries() throws {
        var dir = ZipFixture.Entry("configs/", "")
        dir.external = 0o040755 << 16
        let z = ZipFixture([dir, .init("configs/Work.conf", Self.wg), .init("configs/Home.ovpn", "client\nremote 192.0.2.1\n"),
                            .init("README.txt", "hi"), .init("__MACOSX/configs/._Work.conf", "junk"), .init("configs/._Home.ovpn", "junk")])
        let r = try read(z.data)
        #expect(r.entries.map(\.name) == ["Work.conf", "Home.ovpn"])
        #expect(r.entries[0].bytes == Array(Self.wg.utf8))
        #expect(r.issues.isEmpty)
    }

    @Test func dataDescriptorsAreAccepted() throws {
        var e = ZipFixture.Entry("Work.conf", Self.wg)
        e.flags |= 0x0008
        e.descriptor = true
        let r = try read(ZipFixture([e, .init("b.conf", Self.wg)]).data)
        #expect(r.entries.map(\.name) == ["Work.conf", "b.conf"])
    }

    @Test func exportRoundTripsThroughImport() throws {
        let files = (1...3).map { (path: "P\($0).conf", data: Data(Self.wg.utf8)) }
        let z = try ProfileZipWriter.archive(files)
        let r = try read(z)
        #expect(r.entries.map(\.name) == ["P1.conf", "P2.conf", "P3.conf"])
        #expect(r.entries.allSatisfy { $0.bytes == Array(Self.wg.utf8) })
        // Entries are written 0600, deflated, UTF-8 named.
        let rec = try ZipStructure.validate(z)
        #expect(rec.allSatisfy { $0.method == 8 && $0.kind == .file })
        #expect(u32(z, u32(z, z.count - 6) + 38) >> 16 == 0o100600)
    }

    @MainActor @Test func uniqueExportNames() {
        #expect(AppActions.uniqueEntryName("Work", ext: "conf", taken: ["work.conf", "Work 2.conf"]) == "Work 3.conf")
        #expect(AppActions.uniqueEntryName("Home", ext: "ovpn", taken: []) == "Home.ovpn")
        #expect(AppActions.exportFileName("a\\..\\b") == "a-..-b")
    }

    // MARK: Paths

    @Test(arguments: ["../evil.conf", "/etc/evil.conf", "a/../../evil.conf", "./evil.conf", "a//evil.conf", "C:evil.conf",
                      "a\\..\\evil.conf", "evil\u{1}.conf", "a/./evil.conf"])
    func traversalIsSkippedWithAnError(_ name: String) throws {
        let r = try read(ZipFixture([.init(name, Self.wg), .init("ok.conf", Self.wg)]).data)
        #expect(r.entries.map(\.name) == ["ok.conf"])
        #expect(r.issues.count == 1)
        if case .unsafePath = r.issues.first {} else { Issue.record("expected unsafePath, got \(r.issues)") }
    }

    @Test func symlinksAndSpecialFilesAreSkipped() throws {
        var link = ZipFixture.Entry("link.ovpn", "/etc/passwd")
        link.external = 0o120777 << 16
        var fifo = ZipFixture.Entry("fifo.conf", "")
        fifo.external = 0o010644 << 16
        var otherLink = ZipFixture.Entry("lib", "/usr/lib")
        otherLink.external = 0o120777 << 16
        let r = try read(ZipFixture([link, fifo, otherLink, .init("ok.conf", Self.wg)]).data)
        #expect(r.entries.map(\.name) == ["ok.conf"])
        #expect(r.issues == [.symlink("link.ovpn"), .special("fifo.conf")])
    }

    @Test func duplicateNamesRejectTheArchive() {
        let z = ZipFixture([.init("a.conf", Self.wg), .init("a.conf", "[Interface]\n")])
        #expect(archiveError(z.data) == .duplicateName("a.conf"))
        // NFC-equal spellings count as the same name.
        let nfd = ZipFixture([.init("Bu\u{308}ro.conf", Self.wg), .init("B\u{FC}ro.conf", Self.wg)])
        if case .duplicateName = archiveError(nfd.data) {} else { Issue.record("NFC duplicate accepted") }
    }

    // MARK: Bombs and caps

    @Test func tooManyEntries() {
        let many = ZipFixture((0..<501).map { .init("p\($0).conf", "x") })
        #expect(archiveError(many.data) == .tooManyEntries(501))
        let records = ZipFixture((0..<1001).map { .init("f\($0).txt", "") })
        #expect(archiveError(records.data) == .tooManyEntries(1001))
    }

    @Test func entryAndTotalCaps() throws {
        var caps = ZipCaps()
        caps.maxEntryBytes = 100
        caps.maxTotalBytes = 150
        let big = String(repeating: "#", count: 101)
        let r = try read(ZipFixture([.init("big.conf", big), .init("ok.conf", "[Interface]\n")]).data, caps: caps)
        #expect(r.issues == [.tooLarge("big.conf")])
        #expect(r.entries.map(\.name) == ["ok.conf"])
        let total = ZipFixture([.init("a.conf", String(repeating: "#", count: 80)), .init("b.conf", String(repeating: "#", count: 80))])
        #expect(archiveError(total.data, caps: caps) == .totalTooLarge)
        caps.maxArchiveBytes = 10
        #expect(archiveError(total.data, caps: caps) == .tooLarge)
    }

    @Test func highRatioIsRefused() throws {
        let zeros = Data(count: 5 << 20)                       // deflates ~1000:1
        let z = try ProfileZipWriter.archive([(path: "bomb.conf", data: zeros), (path: "ok.conf", data: Data(Self.wg.utf8))])
        let r = try read(z)
        #expect(r.issues == [.suspiciousRatio("bomb.conf")])
        #expect(r.entries.map(\.name) == ["ok.conf"])
    }

    @Test func aLyingSizeStopsInflationAtTheDeclaredSize() throws {
        // 1 MiB of zeros, headers patched to claim 100 bytes: the consumer stops at 100 and the entry is corrupt.
        var z = try ProfileZipWriter.archive([(path: "liar.conf", data: Data(count: 1 << 20))])
        let cd = u32(z, z.count - 6)
        patch32(&z, at: 22, 100)
        patch32(&z, at: cd + 24, 100)
        let r = try read(z)
        #expect(r.entries.isEmpty)
        #expect(r.issues == [.corrupt("liar.conf")])
    }

    @Test func overlappingEntriesAreRefused() {
        // b.conf's central record points at a complete local header hidden inside a.conf's data.
        var second = ZipFixture.Entry("b.conf", Self.wg)
        second.localOffset = 30 + 6
        let first = ZipFixture.Entry(name: Array("a.conf".utf8), data: ZipFixture.local(second))
        let z = ZipFixture([first, second])
        if case .malformed = archiveError(z.data) {} else { Issue.record("overlap accepted") }
    }

    // MARK: Malformed structure (each of these traps or misleads ZIPFoundation 0.9.20 without pass 1)

    @Test func centralDirectoryOutsideTheArchive() {
        var z = ZipFixture([.init("a.conf", Self.wg)])
        z.cdOffset = 100_000                                 // review F1: MemoryFile range trap
        if case .malformed = archiveError(z.data) {} else { Issue.record("accepted") }
        var lfh = ZipFixture.Entry("a.conf", Self.wg)
        lfh.localOffset = 0xFFFF_FFF0
        if case .malformed = archiveError(ZipFixture([lfh]).data) {} else { Issue.record("accepted") }
        var size = ZipFixture.Entry("a.conf", Self.wg)
        size.compressedSize = 1 << 30
        size.uncompressedSize = 1 << 30
        if case .malformed = archiveError(ZipFixture([size]).data) {} else { Issue.record("accepted") }
    }

    @Test func malformedCentralDirectory() {
        var count = ZipFixture([.init("a.conf", Self.wg)])
        count.count = 2
        if case .malformed = archiveError(count.data) {} else { Issue.record("entry count accepted") }
        var size = ZipFixture([.init("a.conf", Self.wg)])
        size.cdSize = 10
        if case .malformed = archiveError(size.data) {} else { Issue.record("cd size accepted") }
        var mismatch = ZipFixture.Entry("a.conf", Self.wg)
        mismatch.localName = Array("b.conf".utf8)
        if case .malformed = archiveError(ZipFixture([mismatch]).data) {} else { Issue.record("name mismatch accepted") }
        var crc = ZipFixture.Entry("a.conf", Self.wg)
        crc.crc = 1
        let r = try? read(ZipFixture([crc]).data)
        #expect(r?.issues == [.corrupt("a.conf")])
        var trailing = ZipFixture([.init("a.conf", Self.wg)])
        trailing.comment = Array("note".utf8)
        var d = trailing.data
        d.append(contentsOf: [0, 0])                        // comment length no longer reaches the end
        if case .malformed = archiveError(d) {} else { Issue.record("trailing bytes accepted") }
        #expect(archiveError(Data("PK".utf8)) == .notAZip)
        #expect(archiveError(Data(count: 70_000)) == .notAZip)
        var truncated = ZipFixture([.init("a.conf", Self.wg)]).data
        truncated.removeFirst(10)
        #expect(archiveError(truncated) != nil)
    }

    @Test func zip64EncryptionMethodsAndDisksAreRefused() {
        var needed = ZipFixture.Entry("a.conf", Self.wg)
        needed.needed = 45
        #expect(archiveError(ZipFixture([needed]).data) == .zip64)
        var extra = ZipFixture.Entry("a.conf", Self.wg)
        extra.extra = ZipFixture.le16(1) + ZipFixture.le16(8) + ZipFixture.le32(0) + ZipFixture.le32(0)
        #expect(archiveError(ZipFixture([extra]).data) == .zip64)
        var locator = ZipFixture([.init("a.conf", Self.wg)])
        locator.zip64Locator = true
        #expect(archiveError(locator.data) != nil)
        var count = ZipFixture([.init("a.conf", Self.wg)])
        count.count = 0xFFFF
        #expect(archiveError(count.data) == .zip64)
        var enc = ZipFixture.Entry("a.conf", Self.wg)
        enc.flags |= 1                                       // review F4: ZIPFoundation stops iterating silently
        #expect(archiveError(ZipFixture([enc, .init("b.conf", Self.wg)]).data) == .encrypted)
        var lzma = ZipFixture.Entry("a.conf", Self.wg)
        lzma.method = 14
        #expect(archiveError(ZipFixture([lzma]).data) == .unsupportedMethod(14))
        var disk = ZipFixture([.init("a.conf", Self.wg)])
        disk.disk = 1
        #expect(archiveError(disk.data) == .multiDisk)
        var badExtra = ZipFixture.Entry("a.conf", Self.wg)
        badExtra.extra = [0x55, 0x54, 0xFF, 0x00]
        if case .malformed = archiveError(ZipFixture([badExtra]).data) {} else { Issue.record("bad extra accepted") }
    }

    @Test func noProfiles() {
        #expect(archiveError(ZipFixture([.init("README.txt", "x")]).data) == .noProfiles)
    }

    // MARK: Archives from real tools

    /// Seeds of fuzz_zip_import, written by Python's zipfile (stored, deflated, streamed with data descriptors, ZIP64).
    @Test func fuzzSeedCorpus() throws {
        // From the test bundle's resources (Tests/LockPlusTests/Fixtures/zip; Tools/fuzz/corpus/zip links there), never the
        // source tree: the hosted app has no TCC grant for the removable volume the repo lives on, and open() blocks on it.
        func load(_ n: String) throws -> Data {
            let name = n as NSString
            let url = try #require(Bundle(for: ZipFixtureBundle.self).url(forResource: name.deletingPathExtension, withExtension: name.pathExtension))
            return try Data(contentsOf: url)
        }
        #expect(try read(load("stored-two.zip")).entries.map(\.name) == ["Work.conf", "Home.ovpn"])
        #expect(try read(load("deflate-nested.zip")).entries.map(\.name) == ["Work.conf", "Home.ovpn"])
        #expect(try read(load("descriptor.zip")).entries.map(\.name) == ["a.conf", "b.ovpn"])
        #expect(try read(load("macosx.zip")).entries.map(\.name) == ["Work.conf"])
        #expect(try read(load("symlink.zip")).issues == [.symlink("link.ovpn")])
        #expect(try read(load("traversal.zip")).issues.count == 2)
        #expect(try read(load("ratio.zip")).issues == [.suspiciousRatio("bomb.conf")])
        #expect(archiveError(try load("zip64.zip")) == .zip64)
        #expect(archiveError(try load("cd-past-end.zip")) != nil)
        #expect(archiveError(try load("cd-offset-huge.zip")) != nil)
    }

    /// Finder's Compress (ditto): a folder with data descriptors and Unix modes.
    @Test func dittoArchive() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let folder = dir.url.appending(path: "VPN")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.wg.utf8).write(to: folder.appending(path: "Work.conf"))
        try Data("client\nremote 192.0.2.1\n".utf8).write(to: folder.appending(path: "Home.ovpn"))
        let zip = dir.url.appending(path: "VPN.zip")
        _ = await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path], timeout: .seconds(20))
        let r = try read(try Data(contentsOf: zip))
        #expect(Set(r.entries.map(\.name)) == ["Work.conf", "Home.ovpn"])
        #expect(r.issues.isEmpty)
    }

    @Test func errorsHaveMessages() {
        #expect(ZipArchiveError.zip64.message(archive: "x.zip").contains("x.zip"))
        #expect(ZipEntryIssue.symlink("a.ovpn").message.contains("a.ovpn"))
    }
}

/// The import flow end to end: a .zip opens the batch sheet, its profiles record `.zip(<archive>)`, and an archive whose
/// every profile entry was skipped says why.
@MainActor @Suite("Zip import flow (§3.5, UI-CONCEPT §6.15)", .serialized)
struct ZipImportFlowTests {
    @Test func aZipOpensTheBatchSheetAndImports() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let url = h.dir.url.appending(path: "VPN.zip")
        var link = ZipFixture.Entry("link.ovpn", "/etc/passwd")
        link.external = 0o120777 << 16
        let zipped = try ProfileZipWriter.archive([(path: "Work.conf", data: Data(Harness.wgConf.utf8)),
                                                   (path: "sub/Home.conf", data: Data(Harness.wgConf.utf8))])
        try zipped.write(to: url)
        h.env.importer.importFiles([url])
        await h.env.importer.idle()
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
        try ZipFixture([link]).data.write(to: bad)
        h.env.ui.importer.batch = nil
        h.env.importer.importFiles([bad])
        await h.env.importer.idle()
        #expect(h.env.ui.importer.errorMessage == ZipEntryIssue.symlink("link.ovpn").message)
        #expect(h.env.ui.importer.batch == nil)

        // An archive-level refusal names the archive.
        h.env.ui.importer.errorMessage = nil
        let enc = h.dir.url.appending(path: "Locked.zip")
        var e = ZipFixture.Entry("a.conf", Harness.wgConf)
        e.flags |= 1
        try ZipFixture([e]).data.write(to: enc)
        h.env.importer.importFiles([enc])
        await h.env.importer.idle()
        #expect(h.env.ui.importer.errorMessage == ZipArchiveError.encrypted.message(archive: "Locked.zip"))
    }
}
