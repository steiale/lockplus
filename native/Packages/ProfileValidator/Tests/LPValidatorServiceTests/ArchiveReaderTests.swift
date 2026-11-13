import Foundation
import LPModel
import Testing
import ZIPFoundation
@testable import LPValidatorService

@Suite("Archive reader (§3.5): crafted corpus, caps, ZIPFoundation review mitigations")
struct ArchiveReaderTests {
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

    @Test func aZIPFoundationArchiveReadsBack() throws {
        let files = (1...3).map { (path: "P\($0).conf", data: Data(Self.wg.utf8)) }
        let z = try TestZipWriter.archive(files)
        let r = try read(z)
        #expect(r.entries.map(\.name) == ["P1.conf", "P2.conf", "P3.conf"])
        #expect(r.entries.allSatisfy { $0.bytes == Array(Self.wg.utf8) })
        let rec = try ZipStructure.validate(z)
        #expect(rec.allSatisfy { $0.method == 8 && $0.kind == .file })
        #expect(u32(z, u32(z, z.count - 6) + 38) >> 16 == 0o100600)
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
        let zeros = Data(count: 900 << 10)                     // deflates ~1000:1; under the 1 MiB entry cap (round 1: shipped caps)
        let z = try TestZipWriter.archive([(path: "bomb.conf", data: zeros), (path: "ok.conf", data: Data(Self.wg.utf8))])
        let r = try read(z)
        #expect(r.issues == [.suspiciousRatio("bomb.conf")])
        #expect(r.entries.map(\.name) == ["ok.conf"])
    }

    @Test func aLyingSizeStopsInflationAtTheDeclaredSize() throws {
        // 1 MiB of zeros, headers patched to claim 100 bytes: the consumer stops at 100 and the entry is corrupt.
        var z = try TestZipWriter.archive([(path: "liar.conf", data: Data(count: 1 << 20))])
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
        // native/Tests/LockPlusTests/Fixtures/zip (Tools/fuzz/corpus/zip links there). A package test is not a hosted app,
        // so it reads the source tree directly.
        func load(_ n: String) throws -> Data {
            var u = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { u.deleteLastPathComponent() }        // …/native
            return try Data(contentsOf: u.appendingPathComponent("Tests/LockPlusTests/Fixtures/zip/\(n)"))
        }
        #expect(try read(load("stored-two.zip")).entries.map(\.name) == ["Work.conf", "Home.ovpn"])
        #expect(try read(load("deflate-nested.zip")).entries.map(\.name) == ["Work.conf", "Home.ovpn"])
        #expect(try read(load("descriptor.zip")).entries.map(\.name) == ["a.conf", "b.ovpn"])
        #expect(try read(load("macosx.zip")).entries.map(\.name) == ["Work.conf"])
        #expect(try read(load("symlink.zip")).issues == [.symlink("link.ovpn")])
        #expect(try read(load("traversal.zip")).issues.count == 2)
        // A 5 MiB bomb: over the shipped 1 MiB entry cap first; with a larger entry cap the ratio check catches it.
        #expect(try read(load("ratio.zip")).issues == [.tooLarge("bomb.conf")])
        var wide = ZipCaps(); wide.maxEntryBytes = 10 << 20; wide.maxTotalBytes = 100 << 20
        #expect(try read(load("ratio.zip"), caps: wide).issues == [.suspiciousRatio("bomb.conf")])
        #expect(archiveError(try load("zip64.zip")) == .zip64)
        #expect(archiveError(try load("cd-past-end.zip")) != nil)
        #expect(archiveError(try load("cd-offset-huge.zip")) != nil)
    }

    /// Finder's Compress (ditto): a folder with data descriptors and Unix modes.
    @Test func dittoArchive() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lp-ditto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "VPN")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.wg.utf8).write(to: folder.appending(path: "Work.conf"))
        try Data("client\nremote 192.0.2.1\n".utf8).write(to: folder.appending(path: "Home.ovpn"))
        let zip = dir.appending(path: "VPN.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path]
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
        let r = try read(try Data(contentsOf: zip))
        #expect(Set(r.entries.map(\.name)) == ["Work.conf", "Home.ovpn"])
        #expect(r.issues.isEmpty)
    }
}
