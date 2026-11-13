import Foundation
import LPModel
import LPWire
import Testing
@testable import LPValidatorService

@Suite("readArchive replies (PLAN-2.0.2 §1.2, §1.3)")
struct ArchiveReplyTests {
    static let wg = "[Interface]\nPrivateKey = aGVsbG8gd29ybGQgaGVsbG8gd29ybGQgaGVsbG8gd28=\nAddress = 10.0.0.2/32\n"

    private func reply(_ z: Data) throws -> ReadArchiveReply {
        let h = ValidatorServiceHandler(build: "1")
        let r = Replies()
        h.readArchive(try LPWire.encode(ReadArchiveRequest(archive: z)), reply: r.block())
        var waited = 0
        while r.count == 0 && waited < 2000 { Thread.sleep(forTimeInterval: 0.005); waited += 5 }
        return try LPWire.decodeReply(ReadArchiveReply.self, result: r.all[0].0, error: r.all[0].1,
                                      max: LPValidatorMethod.readArchive.replyLimit)
    }

    @Test func entryOver1MiBBecomesIssueWithoutBytes() throws {
        let big = String(repeating: "#", count: (1 << 20) + 1)
        let z = ZipFixture([.init("big.conf", big), .init("ok.conf", Self.wg)]).data
        let r = try reply(z)
        #expect(r.issues == [.tooLarge("big.conf")])
        #expect(r.entries.map(\.name) == ["ok.conf"])
        #expect(r.archiveError == nil)
    }

    @Test func replyNeverExceeds64MiB() throws {
        // Incompressible 1 MiB entries (no ratio finding): 65 of them declare 65 MiB, over the 64 MiB reply total.
        var one = Data(count: 1 << 20)
        one.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        func archive(_ n: Int) throws -> Data { try TestZipWriter.archive((0..<n).map { (path: "p\($0).conf", data: one) }) }
        let over = try archive(65)
        #expect(over.count < ZipCaps().maxArchiveBytes)
        let r = try reply(over)
        #expect(r.archiveError == .totalTooLarge)
        #expect(r.entries.isEmpty)
        // Just under the cap: delivered whole, within the reply limit and the wire rules.
        let ok = try reply(try archive(60))
        #expect(ok.entries.count == 60)
        #expect(ok.entries.reduce(0) { $0 + $1.bytes.count } <= ReadArchiveReply.maxTotalBytes)
        #expect(ok.isWireValid)
    }

    @Test func archiveLevelRefusalTravelsAsArchiveError() throws {
        var e = ZipFixture.Entry("a.conf", Self.wg)
        e.flags |= 1
        #expect(try reply(ZipFixture([e]).data).archiveError == .encrypted)
        #expect(try reply(Data("not a zip".utf8)).archiveError == .notAZip)
    }

    @Test func issuesAreClippedToTheWireLimits() throws {
        // 600 symlinks named *.ovpn with 300-byte names: more issues than the wire allows, names over 255 bytes.
        let long = String(repeating: "n", count: 295)
        let entries: [ZipFixture.Entry] = (0..<600).map { i in
            var e = ZipFixture.Entry("\(long)\(i).ovpn", "x")
            e.external = 0o120777 << 16
            return e
        }
        let z = ZipFixture(entries + [.init("ok.conf", Self.wg)])
        let r = try reply(z.data)
        #expect(r.issues.count == ReadArchiveReply.maxIssues)
        #expect(r.issues.last == .moreSkipped(600 - (ReadArchiveReply.maxIssues - 1)))   // round 1 (Sonnet L3): said, not dropped
        #expect(r.isWireValid)
        #expect(r.entries.map(\.name) == ["ok.conf"])
    }

    @Test func longLeafNameBecomesAnIssueNotAnInvalidReply() throws {
        let name = String(repeating: "a", count: 300) + ".conf"
        let r = try reply(ZipFixture([.init(name, Self.wg), .init("ok.conf", Self.wg)]).data)
        #expect(r.entries.map(\.name) == ["ok.conf"])
        #expect(r.issues.count == 1)
        #expect(r.issues.first.map { if case .nameTooLong = $0 { true } else { false } } == true)    // round 1 (Sonnet L3)
        #expect(r.isWireValid)
    }

    /// Round 1 (Sonnet L4): `ZipCaps()` are the shipped caps, and the service's reader caps are the reply's.
    @Test func defaultCapsAreTheShippedOnes() {
        let c = ZipCaps()
        #expect(c.maxEntryBytes == ReadArchiveReply.maxEntryBytes && c.maxTotalBytes == ReadArchiveReply.maxTotalBytes)
        #expect(ArchiveReplyBuilder.caps.maxProfileEntries == ReadArchiveReply.maxEntries)
        #expect(ArchiveReplyBuilder.caps.maxEntryBytes == ReadArchiveReply.maxEntryBytes)
    }
}

@Suite("ReadArchiveReply wire rules")
struct ReadArchiveReplyWireTests {
    @Test func rejectsUnsafeNamesAndOversizeEntries() {
        func ok(_ e: [ArchiveEntry]) -> Bool { ReadArchiveReply(entries: e).isWireValid }
        #expect(ok([ArchiveEntry(name: "a.conf", bytes: Data(count: 10))]))
        #expect(!ok([ArchiveEntry(name: "../a.conf", bytes: Data())]))
        #expect(!ok([ArchiveEntry(name: "/a.conf", bytes: Data())]))
        #expect(!ok([ArchiveEntry(name: "a\\b.conf", bytes: Data())]))
        #expect(!ok([ArchiveEntry(name: "", bytes: Data())]))
        #expect(!ok([ArchiveEntry(name: "a/b.ovpn", bytes: Data())]))            // round 1 (Fable N1): leaf names only
        #expect(!ok([ArchiveEntry(name: String(repeating: "a", count: 256), bytes: Data())]))
        #expect(!ok([ArchiveEntry(name: "a.conf", bytes: Data(count: (1 << 20) + 1))]))
        #expect(!ReadArchiveReply(entries: Array(repeating: ArchiveEntry(name: "a.conf", bytes: Data()), count: 501)).isWireValid)
        #expect(!ReadArchiveReply(issues: Array(repeating: .corrupt("a"), count: 501)).isWireValid)
        #expect(!ReadArchiveReply(entries: [ArchiveEntry(name: "a.conf", bytes: Data())], archiveError: .encrypted).isWireValid)
        // 65 entries of 1 MiB exceed the 64 MiB total.
        #expect(!ReadArchiveReply(entries: (0..<65).map { ArchiveEntry(name: "p\($0).conf", bytes: Data(count: 1 << 20)) }).isWireValid)
    }
}
