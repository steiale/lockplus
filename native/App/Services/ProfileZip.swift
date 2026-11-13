import Foundation
import LPModel
import ZIPFoundation

// In-memory zip WRITE (DESIGN §3.5, §14.2). 2.0.2: reading an untrusted archive moved into the sandboxed validator
// service (`Packages/ProfileValidator`, `ArchiveReader.swift`; PLAN-2.0.2 §1.2): the app only builds archives (profile
// export, diagnostics bundle) from its own bytes. Nothing is ever extracted to disk.

enum ProfileZipWriter {
    /// A deflated archive, built in memory. Entries are regular files with mode 0600. The result is read back with
    /// ZIPFoundation (every entry present, in order, same size, CRC matching the input), so a writer defect can't
    /// produce an export that doesn't round-trip. (The strict structural check of untrusted archives lives in the
    /// service's reader, whose tests build archives with this same ZIPFoundation call.)
    static func archive(_ files: [(path: String, data: Data)], modificationDate: Date = Date()) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for f in files {
            try archive.addEntry(with: f.path, type: .file, uncompressedSize: Int64(f.data.count),
                                 modificationDate: modificationDate, permissions: 0o600,
                                 compressionMethod: .deflate) { (position: Int64, size: Int) -> Data in
                f.data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        guard let data = archive.data else { throw CocoaError(.fileWriteUnknown) }
        let back = try Archive(data: data, accessMode: .read)
        let entries = Array(back)
        guard entries.count == files.count else { throw CocoaError(.fileWriteUnknown) }
        for (e, f) in zip(entries, files) {
            guard e.path == f.path, e.type == .file, e.uncompressedSize == UInt64(f.data.count) else { throw CocoaError(.fileWriteUnknown) }
            var crc: UInt32 = 0
            if f.data.count > 0 {
                crc = try back.extract(e, skipCRC32: false) { _ in }
            }
            guard crc == e.checksum else { throw CocoaError(.fileWriteUnknown) }
        }
        return data
    }
}

extension ProfileZipWriter {
    /// Entry names of an archive the app itself wrote (tests, round-trip checks). Not for untrusted archives.
    static func entryNames(_ data: Data) throws -> [String] {
        try Array(Archive(data: data, accessMode: .read)).map(\.path)
    }
}
