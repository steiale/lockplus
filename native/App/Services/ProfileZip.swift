import Foundation
import ZIPFoundation

// In-memory zip read and write (DESIGN §3.5, §14.2; review docs/native/reviews/2026-10-27-zipfoundation.md).
//
// Reading untrusted archives is two passes over the same bytes:
//   1. `ZipStructure.validate`: our own strict parser of the end record, the central directory and every local
//      header. It enforces the §3.5 caps and rejects everything ZIPFoundation 0.9.20 can't read safely (review F1–F7):
//      offsets or sizes outside the archive (a Swift trap in `MemoryFile`), ZIP64, encryption (silent truncation of
//      the iteration), multi-disk, overlapping entries, a central directory that isn't exactly followed by the end
//      record, local/central mismatches, unsupported methods.
//   2. ZIPFoundation iterates the same archive (count, names, sizes and CRCs must match pass 1) and inflates only the
//      profile entries, into memory, with a consumer that stops at the declared size (zip bombs) and a CRC check
//      (ZIPFoundation returns the CRC but never compares it).
// Nothing is ever extracted to disk; `extract(_:to:)` and `FileManager.unzipItem` are never called (lint).
// This file depends on Foundation and ZIPFoundation only, so the fuzz target (Tools/fuzz) compiles it as is.

/// §3.5 caps. `maxArchiveBytes` bounds the file read; the others bound what an archive may claim or inflate to.
struct ZipCaps: Sendable, Equatable {
    var maxArchiveBytes = 100 << 20
    /// Central-directory records of any kind (folders, `__MACOSX`, other files): a structural cap before any work.
    var maxRecords = 1000
    /// .ovpn/.conf entries.
    var maxProfileEntries = 500
    /// Decompressed bytes per entry (`LimitReader` semantics).
    var maxEntryBytes = 10 << 20
    /// Decompressed bytes over all profile entries.
    var maxTotalBytes = 100 << 20
    /// An entry larger than `ratioFloorBytes` may not inflate more than `maxRatio` times its compressed size.
    var maxRatio = 100
    var ratioFloorBytes = 64 << 10
    /// Name bytes per entry.
    var maxNameBytes = 1024
}

/// The whole archive is refused.
enum ZipArchiveError: Error, Equatable, Sendable {
    case tooLarge                  // the file exceeds `maxArchiveBytes`
    case notAZip                   // no end record in the last 64 KiB + 22 bytes
    case malformed(String)         // a structural defect (detail is for logs and tests, never shown)
    case zip64
    case encrypted
    case multiDisk
    case unsupportedMethod(UInt16)
    case tooManyEntries(Int)
    case totalTooLarge
    case duplicateName(String)
    case noProfiles
}

/// One entry is skipped; the rest of the archive is imported. Shown as an error row, never silently dropped.
enum ZipEntryIssue: Equatable, Sendable {
    case unsafePath(String)        // absolute, `..`, `.`, empty components, backslashes, control characters
    case symlink(String)
    case special(String)           // FIFO, device, socket
    case tooLarge(String)          // > maxEntryBytes
    case suspiciousRatio(String)   // compression ratio above maxRatio
    case corrupt(String)           // inflate error, size or CRC mismatch
}

/// One central-directory record after validation.
struct ZipRecord: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case file, directory, symlink, special }
    var rawName: [UInt8]
    /// The name exactly as ZIPFoundation decodes it (UTF-8 with flag bit 11, CP437 otherwise): used to match pass 2.
    var libraryName: String
    /// The name for display: UTF-8 whenever the bytes are valid UTF-8, CP437 otherwise.
    var name: String
    var kind: Kind
    var method: UInt16
    var crc32: UInt32
    var compressedSize: Int
    var uncompressedSize: Int
    var localHeaderOffset: Int
    var safePath: Bool

    /// The last path component (names are display-only; nested folders are flattened).
    var leafName: String { name.split(separator: "/").last.map(String.init) ?? "" }

    /// A profile candidate: a regular file named *.ovpn or *.conf, outside macOS metadata (`__MACOSX/`, `._*`).
    var isProfileCandidate: Bool {
        let leaf = leafName, lower = leaf.lowercased()
        guard lower.hasSuffix(".ovpn") || lower.hasSuffix(".conf") else { return false }
        return !leaf.hasPrefix("._") && !name.hasPrefix("__MACOSX/") && !name.contains("/__MACOSX/")
    }
}

enum ZipStructure {
    static let eocdSignature: UInt32 = 0x0605_4b50
    static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    static let zip64RecordSignature: UInt32 = 0x0606_4b50
    static let centralSignature: UInt32 = 0x0201_4b50
    static let localSignature: UInt32 = 0x0403_4b50
    static let descriptorSignature: UInt32 = 0x0807_4b50
    /// General-purpose flags we accept: 1, 2 (deflate options), 3 (data descriptor), 11 (UTF-8 names).
    static let allowedFlags: UInt16 = 0x0002 | 0x0004 | 0x0008 | 0x0800

    static let cp437: String.Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x400)))

    /// Pass 1 (see the file comment). Throws for anything that makes the whole archive unsafe to hand to ZIPFoundation.
    static func validate(_ data: Data, caps: ZipCaps = ZipCaps()) throws(ZipArchiveError) -> [ZipRecord] {
        guard data.count <= caps.maxArchiveBytes else { throw .tooLarge }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws(ZipArchiveError) -> [ZipRecord] in
            try validate(Reader(raw), caps: caps)
        }
    }

    private struct Reader {
        let b: UnsafeRawBufferPointer
        init(_ b: UnsafeRawBufferPointer) { self.b = b }
        var count: Int { b.count }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
        func bytes(_ o: Int, _ n: Int) -> [UInt8] { Array(b[o..<(o + n)]) }
        /// `o ..< o + n` lies inside `0 ..< limit` (no overflow: every operand is < 2^33).
        func fits(_ o: Int, _ n: Int, _ limit: Int) -> Bool { o >= 0 && n >= 0 && o + n <= limit }
    }

    private static func validate(_ r: Reader, caps: ZipCaps) throws(ZipArchiveError) -> [ZipRecord] {
        let len = r.count
        guard len >= 22 else { throw .notAZip }
        // End record: the highest offset ≤ len − 22 with the signature, the same rule ZIPFoundation uses, but only within
        // the spec window (comment ≤ 65535). ZIPFoundation scans the whole file byte by byte (review F3).
        var eocd = -1
        var o = len - 22
        while o >= max(0, len - 22 - 0xFFFF) {
            if r.u32(o) == eocdSignature { eocd = o; break }
            o -= 1
        }
        guard eocd >= 0 else { throw .notAZip }
        let disk = r.u16(eocd + 4), cdDisk = r.u16(eocd + 6)
        let entriesOnDisk = r.u16(eocd + 8), entries = r.u16(eocd + 10)
        let cdSize = r.u32(eocd + 12), cdOffset = r.u32(eocd + 16), commentLen = Int(r.u16(eocd + 20))
        guard eocd + 22 + commentLen == len else { throw .malformed("end record comment length") }
        if entries == 0xFFFF || entriesOnDisk == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw .zip64 }
        if eocd >= 20 && r.u32(eocd - 20) == zip64LocatorSignature { throw .zip64 }
        guard disk == 0, cdDisk == 0, entriesOnDisk == entries else { throw .multiDisk }
        guard Int(entries) <= caps.maxRecords else { throw .tooManyEntries(Int(entries)) }
        guard entries > 0 else { throw .noProfiles }
        let cdStart = Int(cdOffset), cdEnd = Int(cdOffset) + Int(cdSize)
        guard cdEnd == eocd else { throw .malformed("central directory does not end at the end record") }

        var records: [ZipRecord] = []
        var regions: [(start: Int, end: Int)] = []
        var seenRaw = Set<[UInt8]>(), seenNames = Set<String>()
        var p = cdStart
        for _ in 0..<Int(entries) {
            guard r.fits(p, 46, cdEnd), r.u32(p) == centralSignature else { throw .malformed("central record \(records.count)") }
            let madeBy = r.u16(p + 4), needed = r.u16(p + 6), flags = r.u16(p + 8), method = r.u16(p + 10)
            let crc = r.u32(p + 16), csize = r.u32(p + 20), usize = r.u32(p + 24)
            let nlen = Int(r.u16(p + 28)), elen = Int(r.u16(p + 30)), clen = Int(r.u16(p + 32))
            let diskStart = r.u16(p + 34), external = r.u32(p + 38), lho = r.u32(p + 42)
            guard r.fits(p + 46, nlen + elen + clen, cdEnd) else { throw .malformed("central record \(records.count) length") }
            let rawName = r.bytes(p + 46, nlen)
            if flags & 0x0001 != 0 || flags & 0x0040 != 0 || flags & 0x2000 != 0 { throw .encrypted }
            guard flags & ~allowedFlags == 0 else { throw .malformed("flags \(flags)") }
            // ZIPFoundation treats version-needed ≥ 4.5 (low byte) as ZIP64 and then reads 24-byte data descriptors.
            if UInt8(truncatingIfNeeded: needed) >= 45 { throw .zip64 }
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || lho == 0xFFFF_FFFF || diskStart == 0xFFFF { throw .zip64 }
            guard diskStart == 0 else { throw .multiDisk }
            guard method == 0 || method == 8 else { throw .unsupportedMethod(method) }
            try checkExtra(r, p + 46 + nlen, elen)
            guard nlen > 0, nlen <= caps.maxNameBytes else { throw .malformed("name length \(nlen)") }

            // Local header: inside the archive before the central directory, same name, method and flags.
            let lh = Int(lho)
            guard r.fits(lh, 30, cdStart), r.u32(lh) == localSignature else { throw .malformed("local header \(records.count)") }
            let lflags = r.u16(lh + 6), lmethod = r.u16(lh + 8)
            let lcrc = r.u32(lh + 14), lcsize = r.u32(lh + 18), lusize = r.u32(lh + 22)
            let lnlen = Int(r.u16(lh + 26)), lelen = Int(r.u16(lh + 28))
            guard r.fits(lh + 30, lnlen + lelen, cdStart) else { throw .malformed("local header \(records.count) length") }
            guard lmethod == method, lflags == flags, r.bytes(lh + 30, lnlen) == rawName else {
                throw .malformed("local header \(records.count) disagrees with the central directory")
            }
            if lcsize == 0xFFFF_FFFF || lusize == 0xFFFF_FFFF { throw .zip64 }
            try checkExtra(r, lh + 30 + lnlen, lelen)
            let dataStart = lh + 30 + lnlen + lelen
            guard r.fits(dataStart, Int(csize), cdStart) else { throw .malformed("entry \(records.count) data outside the archive") }
            var end = dataStart + Int(csize)
            if flags & 0x0008 != 0 {
                // Data descriptor: 12 bytes, or 16 with its optional signature. ZIPFoundation reads 16 bytes here and takes
                // the CRC from it, so it must exist and agree with the central directory.
                let signed = r.fits(end, 4, cdStart) && r.u32(end) == descriptorSignature
                let dlen = signed ? 16 : 12, base = signed ? end + 4 : end
                guard r.fits(end, dlen, cdStart), r.fits(end, 16, len) else { throw .malformed("entry \(records.count) descriptor") }
                guard r.u32(base) == crc, r.u32(base + 4) == csize, r.u32(base + 8) == usize else {
                    throw .malformed("entry \(records.count) descriptor disagrees with the central directory")
                }
                end += dlen
            } else {
                guard lcrc == crc, lcsize == csize, lusize == usize else {
                    throw .malformed("entry \(records.count) local sizes disagree with the central directory")
                }
            }
            if method == 0 && csize != usize { throw .malformed("stored entry \(records.count) sizes differ") }
            regions.append((lh, end))

            let utf8 = String(validating: rawName, as: UTF8.self)
            let libraryName = flags & 0x0800 != 0 ? (utf8 ?? "") : (String(data: Data(rawName), encoding: cp437) ?? "")
            guard flags & 0x0800 == 0 || utf8 != nil else { throw .malformed("entry \(records.count) name is not UTF-8") }
            let name = utf8 ?? libraryName
            guard seenRaw.insert(rawName).inserted, seenNames.insert(name.precomposedStringWithCanonicalMapping).inserted else {
                throw .duplicateName(name)
            }
            records.append(ZipRecord(rawName: rawName, libraryName: libraryName, name: name,
                                     kind: kind(madeBy: madeBy, external: external, name: rawName),
                                     method: method, crc32: crc, compressedSize: Int(csize), uncompressedSize: Int(usize),
                                     localHeaderOffset: lh, safePath: isSafePath(rawName)))
            p += 46 + nlen + elen + clen
        }
        guard p == cdEnd else { throw .malformed("central directory size") }
        // Overlapping entries are how non-recursive zip bombs reuse one compressed stream many times.
        regions.sort { $0.start < $1.start }
        for i in regions.indices.dropFirst() where regions[i].start < regions[i - 1].end { throw .malformed("overlapping entries") }

        let profiles = records.filter { $0.kind == .file && $0.safePath && $0.isProfileCandidate }
        guard profiles.count <= caps.maxProfileEntries else { throw .tooManyEntries(profiles.count) }
        let declared = profiles.reduce(0) { $0 + min($1.uncompressedSize, caps.maxEntryBytes + 1) }
        guard declared <= caps.maxTotalBytes else { throw .totalTooLarge }
        return records
    }

    /// Extra fields must be well-formed; a ZIP64 field (0x0001) is refused (review F5).
    private static func checkExtra(_ r: Reader, _ start: Int, _ len: Int) throws(ZipArchiveError) {
        var o = start
        let end = start + len
        while o < end {
            guard r.fits(o, 4, end) else { throw .malformed("extra field header") }
            let id = r.u16(o), size = Int(r.u16(o + 2))
            guard r.fits(o + 4, size, end) else { throw .malformed("extra field length") }
            if id == 0x0001 { throw .zip64 }
            o += 4 + size
        }
    }

    /// The same classification as ZIPFoundation's `Entry.type`, plus `.special` for FIFOs, devices and sockets.
    static func kind(madeBy: UInt16, external: UInt32, name: [UInt8]) -> ZipRecord.Kind {
        let slash = name.last == UInt8(ascii: "/")
        let host = madeBy >> 8
        if host == 3 || host == 19 {
            switch UInt16(truncatingIfNeeded: external >> 16) & 0o170000 {
            case 0o100000: return .file
            case 0o040000: return .directory
            case 0o120000: return .symlink
            case 0: return slash ? .directory : .file
            default: return .special
            }
        }
        return slash || (host == 0 && external >> 4 == 0x01) ? .directory : .file
    }

    /// Names are display-only, but a name that would be dangerous anywhere is refused anyway: absolute paths, drive
    /// letters, backslashes, `.`/`..`/empty components and control characters (CVE-2023-39138 class, review F8).
    static func isSafePath(_ raw: [UInt8]) -> Bool {
        guard !raw.isEmpty, raw.first != UInt8(ascii: "/") else { return false }
        if raw.contains(where: { $0 < 0x20 || $0 == 0x7F || $0 == UInt8(ascii: "\\") }) { return false }
        if raw.count >= 2, raw[1] == UInt8(ascii: ":"), (0x41...0x5A).contains(raw[0] & 0xDF) { return false }   // C:
        var parts = raw.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }          // a directory's trailing slash
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && !$0.elementsEqual(".".utf8) && !$0.elementsEqual("..".utf8) }
    }
}

/// The result of reading an archive: profile entries (in archive order) and per-entry issues.
struct ZipProfiles: Sendable {
    var entries: [(name: String, bytes: [UInt8])] = []
    var issues: [ZipEntryIssue] = []
}

enum ProfileZipReader {
    /// Pass 1 + pass 2 over an in-memory archive. Archive-level problems throw `ZipArchiveError`.
    static func read(_ data: Data, caps: ZipCaps = ZipCaps()) throws(ZipArchiveError) -> ZipProfiles {
        let records = try ZipStructure.validate(data, caps: caps)
        var out = ZipProfiles()
        var wanted: [Int] = []
        for (i, r) in records.enumerated() {
            let looksLikeProfile = r.isProfileCandidate
            if !r.safePath { out.issues.append(.unsafePath(r.name)); continue }
            switch r.kind {
            case .directory: continue
            case .symlink: if looksLikeProfile { out.issues.append(.symlink(r.leafName)) }; continue
            case .special: if looksLikeProfile { out.issues.append(.special(r.leafName)) }; continue
            case .file: break
            }
            guard looksLikeProfile else { continue }
            if r.uncompressedSize > caps.maxEntryBytes { out.issues.append(.tooLarge(r.leafName)); continue }
            if r.uncompressedSize > caps.ratioFloorBytes && r.uncompressedSize > caps.maxRatio * max(r.compressedSize, 1) {
                out.issues.append(.suspiciousRatio(r.leafName)); continue
            }
            wanted.append(i)
        }
        guard !wanted.isEmpty || !out.issues.isEmpty else { throw .noProfiles }
        if wanted.isEmpty { return out }

        // Pass 2. ZIPFoundation must see exactly the records pass 1 validated, in the same order.
        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) } catch { throw .malformed("ZIPFoundation: \(error)") }
        let entries = Array(archive)
        guard entries.count == records.count else { throw .malformed("ZIPFoundation saw \(entries.count) of \(records.count) entries") }
        for (e, r) in zip(entries, records) where e.path != r.libraryName || e.uncompressedSize != UInt64(r.uncompressedSize)
            || e.compressedSize != UInt64(r.compressedSize) {
            throw .malformed("ZIPFoundation disagrees on entry \(r.name)")
        }
        var total = 0
        for i in wanted {
            let r = records[i], e = entries[i]
            guard e.type == .file, e.checksum == r.crc32 else { out.issues.append(.corrupt(r.leafName)); continue }
            var buf: [UInt8] = []
            buf.reserveCapacity(r.uncompressedSize)
            let limit = r.uncompressedSize
            do {
                let crc = try archive.extract(e, bufferSize: 16 << 10, skipCRC32: false) { chunk in
                    guard buf.count + chunk.count <= limit else { throw ZipArchiveError.malformed("inflates past its size") }
                    buf.append(contentsOf: chunk)
                }
                guard crc == r.crc32, buf.count == limit else { throw ZipArchiveError.malformed("CRC or size") }
            } catch {
                for j in buf.indices { buf[j] = 0 }
                out.issues.append(.corrupt(r.leafName))
                continue
            }
            total += buf.count
            guard total <= caps.maxTotalBytes else { throw .totalTooLarge }
            out.entries.append((r.leafName, buf))
        }
        return out
    }
}

enum ProfileZipWriter {
    /// A deflated archive, built in memory. Entries are regular files with mode 0600. The result is read back through
    /// `ZipStructure.validate`, so we never write an archive our own import would refuse.
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
        var caps = ZipCaps()
        caps.maxArchiveBytes = .max
        caps.maxRecords = max(caps.maxRecords, files.count)
        caps.maxProfileEntries = .max
        caps.maxTotalBytes = .max
        do { _ = try ZipStructure.validate(data, caps: caps) } catch { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
