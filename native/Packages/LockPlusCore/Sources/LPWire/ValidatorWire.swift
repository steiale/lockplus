import Foundation
import LPModel

// The validator service's wire (PLAN-2.0.2 §1.3): the app ↔ `LockPlusValidator.xpc` (sandboxed, network-less, runs as
// the user). Same rules as the extension's wire (`XPCProtocol.swift`): Data-only parameters, binary plists through
// `LPWire`, caps checked before decoding, post-decode limits (`LPWireValidating`), every reply sent exactly once.
// `ValidateProfileRequest`/`ValidateProfileReply` are reused unchanged for `evaluateProfile`.

/// Bumps only on an incompatible change of this wire (independent of `LPWireVersion`). The service and the app also
/// compare their builds in `hello` (same bundle → same build).
public let LPValidatorWireVersion: UInt16 = 1

/// Exported by the validator service; called by the app over `NSXPCConnection(serviceName:)`.
@objc public protocol LPValidatorXPC: NSObjectProtocol {
    /// ValidatorHello → ValidatorHello. Always the first call on a connection.
    func hello(_ req: Data, reply: @escaping LPReply2)
    /// ValidateProfileRequest → ValidateProfileReply: §8.1 [1]–[7] on canonical text.
    func evaluateProfile(_ req: Data, reply: @escaping LPReply2)
    /// ReadArchiveRequest → ReadArchiveReply: the zip read (§3.5), in memory.
    func readArchive(_ req: Data, reply: @escaping LPReply2)
}

public extension NSXPCInterface {
    static var lpValidator: NSXPCInterface { NSXPCInterface(with: LPValidatorXPC.self) }
}

public struct ValidatorHello: Codable, Sendable, Equatable {
    public var wire: UInt16
    /// The sender's `CFBundleVersion`.
    public var build: String
    public init(wire: UInt16 = LPValidatorWireVersion, build: String) { self.wire = wire; self.build = build }
}

/// The archive bytes, at most `ZipCaps.maxArchiveBytes + 1` (one byte over the cap, so the service can answer
/// `.tooLarge` itself rather than the transport answering `.payloadTooLarge`).
public struct ReadArchiveRequest: Codable, Sendable {
    public static let maxArchiveBytes = ZipCaps().maxArchiveBytes + 1
    public var archive: Data
    public init(archive: Data) { self.archive = archive }
}

/// One profile entry the service read: its leaf name (display only) and its bytes.
public struct ArchiveEntry: Codable, Sendable, Equatable {
    public var name: String
    public var bytes: Data
    public init(name: String, bytes: Data) { self.name = name; self.bytes = bytes }
}

/// The entries in archive order and the per-entry issues, or the archive-level refusal (`archiveError`, then no
/// entries). Transport and cap failures stay in the reply's `LPError` half.
public struct ReadArchiveReply: Codable, Sendable {
    public static let maxEntries = 500
    public static let maxIssues = 500
    public static let maxNameBytes = 255
    /// Per entry: the service returns a larger entry as `ZipEntryIssue.tooLarge` without bytes (§1.2).
    public static let maxEntryBytes = OVPNImportLimits.maxRawBytes
    public static let maxTotalBytes = 64 << 20
    public var entries: [ArchiveEntry]
    public var issues: [ZipEntryIssue]
    /// nil = the archive was read. Otherwise why the whole archive is refused (`ZipStructure` / caps).
    public var archiveError: ZipArchiveError?
    public init(entries: [ArchiveEntry] = [], issues: [ZipEntryIssue] = [], archiveError: ZipArchiveError? = nil) {
        self.entries = entries; self.issues = issues; self.archiveError = archiveError
    }
}

/// Every validator method, with its request cap, reply cap and client timeout (§1.3).
public enum LPValidatorMethod: String, Sendable, CaseIterable {
    case hello, evaluateProfile, readArchive

    /// Request size cap, checked before decoding (an encoded request carries a few bytes of plist framing on top).
    public var requestLimit: Int {
        switch self {
        case .hello: 4 * LPWire.KiB
        case .evaluateProfile: 300 * LPWire.KiB
        case .readArchive: (100 << 20) + LPWire.KiB      // ReadArchiveRequest.maxArchiveBytes + framing
        }
    }

    /// Reply size cap, checked by the client before decoding.
    public var replyLimit: Int {
        switch self {
        case .hello: 4 * LPWire.KiB
        case .evaluateProfile: 64 * LPWire.KiB
        case .readArchive: (64 << 20) + 256 * LPWire.KiB  // ReadArchiveReply.maxTotalBytes + names, issues, framing
        }
    }

    /// The service's watchdog for a request of this method (round 1, Fable M1 / Sonnet L5): a request still running
    /// after this long is answered `.timeout` and the service exits. nil: answered inline, never on the worker.
    public var watchdog: Duration? {
        switch self {
        case .hello: nil
        case .evaluateProfile: .seconds(10)
        case .readArchive: .seconds(25)
        }
    }

    /// Client-side timeout: longer than the service's watchdog, so a slow request ends with the service's own answer
    /// (`.timeout`, then its exit) rather than with the client giving up while the service is still busy with it.
    /// `hello` includes the launch of the service process (cold, it loads openvpn3 and OpenSSL).
    public var timeout: Duration {
        switch self {
        case .hello: .seconds(5)
        case .evaluateProfile: .seconds(12)          // watchdog + 2 s (LPWireTests checks the relation)
        case .readArchive: .seconds(27)
        }
    }

    /// Sends this method on `proxy`.
    public func invoke(_ proxy: any LPValidatorXPC, _ req: Data, _ reply: @escaping LPReply2) {
        switch self {
        case .hello: proxy.hello(req, reply: reply)
        case .evaluateProfile: proxy.evaluateProfile(req, reply: reply)
        case .readArchive: proxy.readArchive(req, reply: reply)
        }
    }
}

extension ValidatorHello: LPWireValidating {
    public var isWireValid: Bool { build.utf8.count <= 64 }
}

extension ReadArchiveRequest: LPWireValidating {
    public var isWireValid: Bool { archive.count <= Self.maxArchiveBytes }
}

extension ReadArchiveReply: LPWireValidating {
    /// ≤ 500 entries of ≤ 1 MiB each with safe leaf names (no `/`, round 1 Fable N1) ≤ 255 UTF-8 bytes, ≤ 64 MiB in total, ≤ 500 issues; no entries
    /// beside an archive error.
    public var isWireValid: Bool {
        guard entries.count <= Self.maxEntries, issues.count <= Self.maxIssues else { return false }
        if archiveError != nil, !entries.isEmpty { return false }
        var total = 0
        for e in entries {
            let name = Array(e.name.utf8)
            guard name.count <= Self.maxNameBytes, ZipNames.isLeafName(name), e.bytes.count <= Self.maxEntryBytes else { return false }
            total += e.bytes.count
        }
        return total <= Self.maxTotalBytes
    }
}
