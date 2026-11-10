import CryptoKit
import Foundation

/// Hex SHA-256 of a canonical payload (`Profile.payloadDigest`, §3.1), the digest the Go migration's manual re-run
/// dedupes by (§13.1 step 9). LockPlusCore has no CryptoKit (§2.2), so the app injects this closure into
/// `GoAppMigration.read(_:existingDigests:digest:)`.
enum PayloadDigest {
    static let sha256Hex: @Sendable (String) -> String = { text in
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The same digest over the raw buffer (FA nit: no String copy of a secret payload). Canonical payloads are
    /// valid UTF-8, so both forms agree.
    static func sha256Hex(bytes: UnsafeRawBufferPointer) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
