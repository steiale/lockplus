import Foundation

// Zip import model (DESIGN §3.5, §14.2). 2.0.2 (PLAN-2.0.2 §1.2, §1.3): moved here from App/Services/ProfileZip.swift
// so the app, the validator service and the wire (`ReadArchiveReply`) share one definition. Codable: archive caps,
// archive errors and per-entry issues cross the validator's XPC boundary. Foundation only (the fuzz target compiles
// this file next to the zip reader).

/// §3.5 caps. `maxArchiveBytes` bounds the file read; the others bound what an archive may claim or inflate to.
public struct ZipCaps: Codable, Sendable, Equatable {
    public var maxArchiveBytes: Int
    /// Central-directory records of any kind (folders, `__MACOSX`, other files): a structural cap before any work.
    public var maxRecords: Int
    /// .ovpn/.conf entries.
    public var maxProfileEntries: Int
    /// Decompressed bytes per entry (`LimitReader` semantics).
    public var maxEntryBytes: Int
    /// Decompressed bytes over all profile entries.
    public var maxTotalBytes: Int
    /// An entry larger than `ratioFloorBytes` may not inflate more than `maxRatio` times its compressed size.
    public var maxRatio: Int
    public var ratioFloorBytes: Int
    /// Name bytes per entry.
    public var maxNameBytes: Int

    /// Round 1 (Sonnet L4): the defaults are the shipped caps (1 MiB per entry = the import's raw cap, 64 MiB in total),
    /// so every `ZipCaps()` (tests, the fuzz target, the request cap) checks what ships. Names: 1024 bytes structurally;
    /// the reply allows 255 and reports longer ones as `.nameTooLong`.
    public init(maxArchiveBytes: Int = 100 << 20, maxRecords: Int = 1000, maxProfileEntries: Int = 500,
                maxEntryBytes: Int = OVPNImportLimits.maxRawBytes, maxTotalBytes: Int = 64 << 20, maxRatio: Int = 100,
                ratioFloorBytes: Int = 64 << 10, maxNameBytes: Int = 1024) {
        self.maxArchiveBytes = maxArchiveBytes; self.maxRecords = maxRecords; self.maxProfileEntries = maxProfileEntries
        self.maxEntryBytes = maxEntryBytes; self.maxTotalBytes = maxTotalBytes; self.maxRatio = maxRatio
        self.ratioFloorBytes = ratioFloorBytes; self.maxNameBytes = maxNameBytes
    }
}

/// The whole archive is refused.
public enum ZipArchiveError: Error, Codable, Equatable, Sendable {
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
    /// 2.0.2: the archive couldn't be read safely (the validator service is unavailable or died on it). App-side.
    case checkUnavailable
}

/// One entry is skipped; the rest of the archive is imported. Shown as an error row, never silently dropped.
public enum ZipEntryIssue: Codable, Equatable, Sendable {
    case unsafePath(String)        // absolute, `..`, `.`, empty components, backslashes, control characters
    case symlink(String)
    case special(String)           // FIFO, device, socket
    case tooLarge(String)          // > maxEntryBytes
    case suspiciousRatio(String)   // compression ratio above maxRatio
    case corrupt(String)           // inflate error, size or CRC mismatch
    /// Round 1 (Sonnet L3): a name longer than the wire's 255 bytes (the reader allows 1024 structurally).
    case nameTooLong(String)
    /// Round 1 (Sonnet L3): the issue list was capped; this many more entries were skipped (never silent truncation).
    case moreSkipped(Int)
}

/// Entry-name rules shared by the reader (`ZipStructure.isSafePath`) and the wire (`ReadArchiveReply.isWireValid`).
public enum ZipNames {
    /// Names are display-only, but a name that would be dangerous anywhere is refused anyway: absolute paths, drive
    /// letters, backslashes, `.`/`..`/empty components and control characters (CVE-2023-39138 class, review F8).
    public static func isSafePath(_ raw: [UInt8]) -> Bool {
        guard !raw.isEmpty, raw.first != UInt8(ascii: "/") else { return false }
        if raw.contains(where: { $0 < 0x20 || $0 == 0x7F || $0 == UInt8(ascii: "\\") }) { return false }
        if raw.count >= 2, raw[1] == UInt8(ascii: ":"), (0x41...0x5A).contains(raw[0] & 0xDF) { return false }   // C:
        var parts = raw.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }          // a directory's trailing slash
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && !$0.elementsEqual(".".utf8) && !$0.elementsEqual("..".utf8) }
    }

    /// Round 1 (Fable N1): what the service may send as an entry name: a safe path with no `/` at all (the reader
    /// flattens folders to the leaf name).
    public static func isLeafName(_ raw: [UInt8]) -> Bool { isSafePath(raw) && !raw.contains(UInt8(ascii: "/")) }
}
