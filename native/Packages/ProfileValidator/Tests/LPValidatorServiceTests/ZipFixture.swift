import Foundation
import ZIPFoundation

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

/// Patches a little-endian UInt32 in an archive.
func patch32(_ d: inout Data, at o: Int, _ v: UInt32) {
    for i in 0..<4 { d[d.startIndex + o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
}

func u32(_ d: Data, _ o: Int) -> Int {
    (0..<4).reduce(0) { $0 | Int(d[d.startIndex + o + $1]) << (8 * $1) }
}

/// A deflated archive of regular files (0600), built in memory with ZIPFoundation, WITHOUT the reader's validation:
/// the tests need archives the reader may refuse (bombs, lying sizes).
enum TestZipWriter {
    static func archive(_ files: [(path: String, data: Data)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for f in files {
            try archive.addEntry(with: f.path, type: .file, uncompressedSize: Int64(f.data.count),
                                 modificationDate: Date(), permissions: 0o600, compressionMethod: .deflate) { (position: Int64, size: Int) -> Data in
                f.data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return try unwrap(archive.data)
    }
}

private func unwrap<T>(_ v: T?) throws -> T {
    guard let v else { throw CocoaError(.fileWriteUnknown) }
    return v
}
