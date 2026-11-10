import CryptoKit
import Foundation
import LPModel
import LPWire

public enum SecretKind: String, Sendable, Codable, CaseIterable {
    case payload, credential
    var aadByte: UInt8 { self == .payload ? 0x01 : 0x02 }
}

/// One provision-index row (§6.3/§6.4). `digest` is hex SHA-256 of the stored bytes; nil when the store can't vouch
/// for it, so `reconcile()` re-provisions instead of trusting it.
public struct ProvisionIndexEntry: Sendable, Equatable, Codable {
    public var id: UUID
    public var kind: SecretKind
    public var revision: UInt64
    public var ownerUID: uid_t
    public var digest: String?
    public init(id: UUID, kind: SecretKind, revision: UInt64, ownerUID: uid_t, digest: String?) {
        self.id = id; self.kind = kind; self.revision = revision; self.ownerUID = ownerUID; self.digest = digest
    }
}

/// DESIGN §6.3: both backends behind one protocol. Every error is an `LPError`; a store that cannot run says
/// `.secretStoreUnavailable` (detail `SecretStoreDetail.lockedBeforeLogin` for the pre-login lock).
///
/// Per-uid namespaces (review H1): every item is addressed by (ownerUID, kind, profile UUID). Two uids provisioning the
/// same UUID get two independent items; one uid can never read, replace, delete or squat another uid's item, and there
/// is no cross-uid listing. The caller passes the uid it has verified (the XPC peer's EUID, or the start's
/// `providerConfiguration` owner, which the controller then checks against the entry).
public protocol ExtensionSecretStore: Sendable {
    func put(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t, revision: UInt64, _ bytes: SecretBytes) async throws(LPError)
    func get(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) async throws(LPError) -> SecretBytes?
    /// The index row of one item (metadata only), nil when absent.
    func entry(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) async throws(LPError) -> ProvisionIndexEntry?
    func delete(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) async throws(LPError)
    func deleteAll(ownerUID: uid_t) async throws(LPError)
    /// `ownerUID`'s rows only.
    func index(ownerUID: uid_t) async throws(LPError) -> [ProvisionIndexEntry]
}

enum SecretDigest {
    static func hex(_ s: SecretBytes) -> String {
        s.withUnsafeBytes { SHA256.hash(data: $0) }.map { String(format: "%02x", $0) }.joined()
    }
}

/// Per-item metadata `{id, kind, ownerUID, revision, digest}` as a binary plist. Kept INSIDE the protected value
/// (keychain `kSecValueData`, the sealed file's header in the root-only container), never in attributes another user
/// can read (review L4).
struct SecretMeta: Codable, Equatable {
    var id: UUID
    var kind: SecretKind
    var ownerUID: UInt32
    var revision: UInt64
    var digest: String
    func encoded() -> Data { (try? PropertyListEncoder.binary.encode(self)) ?? Data() }
    static func decode(_ d: Data) -> SecretMeta? { try? PropertyListDecoder().decode(SecretMeta.self, from: d) }
    var entry: ProvisionIndexEntry { ProvisionIndexEntry(id: id, kind: kind, revision: revision, ownerUID: ownerUID, digest: digest) }
}

/// `magic ‖ UInt32 BE metaLength ‖ SecretMeta plist ‖ body` — the framing shared by both stores.
enum SecretEnvelope {
    static func frame(_ magic: Data, _ meta: SecretMeta, _ body: (inout Data) -> Void) -> Data {
        let m = meta.encoded()
        var out = magic
        withUnsafeBytes(of: UInt32(m.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(m)
        body(&out)
        return out
    }

    /// Splits a framed blob; nil when malformed. `bodyRange` indexes into `d`.
    static func split(_ magic: Data, _ d: Data) -> (meta: SecretMeta, bodyRange: Range<Data.Index>)? {
        let h = magic.count + 4
        guard d.count >= h, d.prefix(magic.count) == magic else { return nil }
        let s = d.startIndex + magic.count
        let len = Int(d[s]) << 24 | Int(d[s + 1]) << 16 | Int(d[s + 2]) << 8 | Int(d[s + 3])
        guard len <= d.count - h, let meta = SecretMeta.decode(d.subdata(in: (d.startIndex + h)..<(d.startIndex + h + len))) else {
            return nil
        }
        return (meta, (d.startIndex + h + len)..<d.endIndex)
    }
}

extension PropertyListEncoder {
    static var binary: PropertyListEncoder { let e = PropertyListEncoder(); e.outputFormat = .binary; return e }
}

/// `CredentialRecord` (binary plist) ↔ engine secrets. The `Data` copies are scoped to these two functions (§6.5).
public enum CredentialCodec {
    public static func encode(_ c: CredentialSecrets) -> SecretBytes {
        let rec = CredentialRecord(username: c.username.map { Data($0.copyBytes()) }, password: c.password.map { Data($0.copyBytes()) },
                                   keyPassphrase: c.keyPassphrase.map { Data($0.copyBytes()) },
                                   proxyUsername: c.proxyUsername.map { Data($0.copyBytes()) },
                                   proxyPassword: c.proxyPassword.map { Data($0.copyBytes()) })
        return SecretBytes(copying: (try? PropertyListEncoder.binary.encode(rec)) ?? Data())
    }
    public static func decode(_ s: SecretBytes) -> CredentialSecrets? {
        guard let rec = s.withUnsafeBytes({ try? PropertyListDecoder().decode(CredentialRecord.self, from: Data($0)) }) else { return nil }
        return CredentialSecrets(username: SecretBytes.fromData(rec.username), password: SecretBytes.fromData(rec.password),
                                 keyPassphrase: SecretBytes.fromData(rec.keyPassphrase),
                                 proxyUsername: SecretBytes.fromData(rec.proxyUsername), proxyPassword: SecretBytes.fromData(rec.proxyPassword))
    }
}
