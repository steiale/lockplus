import Foundation
import LPModel
import LPWire

/// Turns an archive into the wire's fixed-shape `ReadArchiveReply` (PLAN-2.0.2 §1.2, §1.3): the reader's output made to
/// satisfy `ReadArchiveReply.isWireValid`, so the app never receives a reply it has to refuse as a whole.
enum ArchiveReplyBuilder {
    /// The reader's caps in the service, tied to the reply's (an entry over 1 MiB is an issue, ≤ 500 entries, the entry
    /// bytes total ≤ 64 MiB), so the reader's output fits the reply by construction.
    static let caps = ZipCaps(maxProfileEntries: ReadArchiveReply.maxEntries, maxEntryBytes: ReadArchiveReply.maxEntryBytes,
                              maxTotalBytes: ReadArchiveReply.maxTotalBytes)

    static func reply(for archive: Data) -> ReadArchiveReply {
        let profiles: ZipProfiles
        do { profiles = try ProfileZipReader.read(archive, caps: caps) } catch {
            return ReadArchiveReply(archiveError: error)
        }
        var out = ReadArchiveReply()
        for (name, bytes) in profiles.entries {
            let raw = Array(name.utf8)
            // (Entry count and size can't exceed the reply's: `caps` are the reply's caps.)
            guard raw.count <= ReadArchiveReply.maxNameBytes else { out.issues.append(.nameTooLong(clipped(name))); continue }
            guard ZipNames.isLeafName(raw) else { out.issues.append(.unsafePath(clipped(name))); continue }
            out.entries.append(ArchiveEntry(name: name, bytes: Data(bytes)))
        }
        out.issues.append(contentsOf: profiles.issues.map(clip))
        // Round 1 (Sonnet L3): never a silent truncation: the last slot says how many more were skipped.
        if out.issues.count > ReadArchiveReply.maxIssues {
            let more = out.issues.count - (ReadArchiveReply.maxIssues - 1)
            out.issues.removeSubrange((ReadArchiveReply.maxIssues - 1)...)
            out.issues.append(.moreSkipped(more))
        }
        return out
    }

    /// Names in issues are display text; keep them within the name cap so a reply can't outgrow its framing allowance.
    private static func clip(_ i: ZipEntryIssue) -> ZipEntryIssue {
        switch i {
        case .unsafePath(let n): .unsafePath(clipped(n))
        case .symlink(let n): .symlink(clipped(n))
        case .special(let n): .special(clipped(n))
        case .tooLarge(let n): .tooLarge(clipped(n))
        case .suspiciousRatio(let n): .suspiciousRatio(clipped(n))
        case .corrupt(let n): .corrupt(clipped(n))
        case .nameTooLong(let n): .nameTooLong(clipped(n))
        case .moreSkipped(let n): .moreSkipped(n)
        }
    }

    private static func clipped(_ name: String) -> String {
        var out = ""
        var n = 0
        for ch in name {
            let c = String(ch).utf8.count
            if n + c > ReadArchiveReply.maxNameBytes { break }
            out.append(ch); n += c
        }
        return out
    }
}
