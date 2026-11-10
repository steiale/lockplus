// libFuzzer target: zip import (DESIGN §3.5, §15.4). Pass 1 (ZipStructure.validate) on arbitrary bytes, the full
// ProfileZipReader, and, for every archive pass 1 accepts, ZIPFoundation's own iteration and inflation of every
// regular entry (review F1–F7: anything pass 1 accepts must be safe for ZIPFoundation to read).
import Foundation
import ZIPFoundation

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    let d = Data(bytes: data, count: size)
    var caps = ZipCaps()
    caps.maxEntryBytes = 1 << 20
    caps.maxTotalBytes = 4 << 20
    _ = try? ProfileZipReader.read(d, caps: caps)
    guard let records = try? ZipStructure.validate(d, caps: caps) else { return 0 }
    let archive: Archive
    do { archive = try Archive(data: d, accessMode: .read) } catch { return 0 }
    var n = 0
    for e in archive {
        n += 1
        guard e.type == .file, n <= records.count, records[n - 1].uncompressedSize <= caps.maxEntryBytes else { continue }
        var got = 0
        let limit = records[n - 1].uncompressedSize
        _ = try? archive.extract(e, bufferSize: 16 << 10, skipCRC32: false) { chunk in
            got += chunk.count
            if got > limit { throw CocoaError(.fileReadCorruptFile) }
        }
    }
    if n != records.count { fatalError("ZIPFoundation iterated \(n) of \(records.count) validated entries") }
    return 0
}
