import os
import CryptoKit
import Foundation
import LPModel

/// Supplies the 256-bit file key of the fallback store (§6.3 fallback).
public protocol FileKeyProvider: Sendable {
    /// `files` is the store's checked file I/O in the secrets directory.
    func fileKey(_ files: SecretFiles) throws(LPError) -> SymmetricKey
    /// Deletes the key material at rest (§6.4: the last uid's wipe). The next `fileKey` creates a fresh key.
    func destroyKey(_ files: SecretFiles)
}

extension FileKeyProvider {
    /// Every file any provider writes: the SE key blob and wrapped file key, and the raw file key.
    public func destroyKey(_ files: SecretFiles) {
        for name in ContainerSecretStore.keyFiles { files.remove(name) }
    }
}

/// `secrets/se.key` + `secrets/filekey.wrapped` (HPKE `.P256_SHA256_AES_GCM_256`, info "lockplus.filekey.v1",
/// format `0x01 ‖ encapsulatedKey (65 B) ‖ seal(fileKey) (48 B)`), as verified by S4 in the sysex.
/// Before the first login after boot both creating and using the SE key fail with -25308 → `.secretStoreUnavailable`
/// (`lockedBeforeLogin`), which the controller turns into a `.backoff` latch.
public struct SecureEnclaveFileKeyProvider: FileKeyProvider {
    static let info = Data("lockplus.filekey.v1".utf8)
    public init() {}
    public func fileKey(_ files: SecretFiles) throws(LPError) -> SymmetricKey {
        do {
            if files.exists("se.key") && files.exists("filekey.wrapped") {
                let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: try files.read("se.key"))
                let w = try files.read("filekey.wrapped")
                guard w.count == 1 + 65 + 48, w.first == 0x01 else { throw LPError(.secretStoreUnavailable, detail: "filekey format") }
                var rec = try HPKE.Recipient(privateKey: se, ciphersuite: .P256_SHA256_AES_GCM_256, info: Self.info,
                                             encapsulatedKey: w.subdata(in: 1..<66))
                var raw = try rec.open(w.subdata(in: 66..<w.count))
                defer { raw.resetBytes(in: 0..<raw.count) }
                return SymmetricKey(data: raw)
            }
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            let key = SymmetricKey(size: .bits256)
            var sender = try HPKE.Sender(recipientKey: se.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: Self.info)
            let ct = try key.withUnsafeBytes { try sender.seal(Data($0)) }
            var w = Data([0x01]); w.append(sender.encapsulatedKey); w.append(ct)
            try files.writeAtomic("se.key", se.dataRepresentation)
            try files.writeAtomic("filekey.wrapped", w)
            return key
        } catch let e as LPError {
            throw e
        } catch {
            let code = (error as NSError).code
            throw LPError(.secretStoreUnavailable, detail: code == Int(errSecInteractionNotAllowed) ? SecretStoreDetail.lockedBeforeLogin : "se \(code)")
        }
    }
}

/// `secrets/filekey.raw` (32 bytes, 0600) when the Secure Enclave is unavailable (VMs).
public struct RawFileKeyProvider: FileKeyProvider {
    public init() {}
    public func fileKey(_ files: SecretFiles) throws(LPError) -> SymmetricKey {
        if files.exists("filekey.raw") {
            var d = try files.read("filekey.raw")
            defer { d.resetBytes(in: 0..<d.count) }
            guard d.count == 32 else { throw LPError(.secretStoreUnavailable, detail: "filekey.raw size") }
            return SymmetricKey(data: d)
        }
        let k = SymmetricKey(size: .bits256)
        var raw = k.withUnsafeBytes { Data($0) }
        defer { raw.resetBytes(in: 0..<raw.count) }
        try files.writeAtomic("filekey.raw", raw)
        return k
    }
}

/// §6.3 fallback key choice (draft 9, S4 on the 26/27 VMs: `SecureEnclave.isAvailable` is TRUE in a VM, but creating
/// the key fails with -25308 / AKS -536870174). The availability flag is therefore not trusted:
/// - `filekey.raw` exists → the raw key (a store that fell back once stays on the raw key);
/// - an SE key exists → it is used; -25308 is the transient pre-login lock (`lockedBeforeLogin`, the files stay sealed
///   under it); any OTHER SE/HPKE error means this SE key is unusable: it is discarded and the raw key takes over (the
///   files sealed under the old key no longer open; the index reports them without a digest, reconcile re-provisions);
/// - no key yet → the SE is tried; ANY SE error creating it, -25308 included, means "no SE" and the raw key is created.
/// File-I/O errors from `SecretFiles` are never read as "no SE" (`meansNoSecureEnclave`).
public struct AutomaticFileKeyProvider: FileKeyProvider {
    private let secureEnclave: any FileKeyProvider
    private let isAvailable: @Sendable () -> Bool
    public init() { self.init(secureEnclave: SecureEnclaveFileKeyProvider(), isAvailable: { SecureEnclave.isAvailable }) }
    /// Tests inject a failing SE provider.
    init(secureEnclave: any FileKeyProvider, isAvailable: @escaping @Sendable () -> Bool) {
        self.secureEnclave = secureEnclave; self.isAvailable = isAvailable
    }

    public func fileKey(_ files: SecretFiles) throws(LPError) -> SymmetricKey {
        if files.exists("filekey.raw") { return try RawFileKeyProvider().fileKey(files) }
        let hasSEKey = files.exists("se.key") && files.exists("filekey.wrapped")
        guard hasSEKey || isAvailable() else { return try RawFileKeyProvider().fileKey(files) }
        do throws(LPError) {
            return try secureEnclave.fileKey(files)
        } catch {
            guard Self.meansNoSecureEnclave(error, hasSEKey: hasSEKey) else { throw error }
            engineLog.error("secure enclave unusable (\(error.detail ?? "", privacy: .public)): using the raw file key")
            files.remove("se.key"); files.remove("filekey.wrapped")
            return try RawFileKeyProvider().fileKey(files)
        }
    }

    /// Only a failure of the SE/HPKE operation itself (`se <code>`, a malformed `filekey.wrapped`, or -25308 while
    /// creating) selects the raw key. Checked file-I/O errors (`open <errno>` on EMFILE/EINTR, `owner/mode`,
    /// `short read`, a failed write) are transient or tampering: they propagate and never discard a usable SE key.
    static func meansNoSecureEnclave(_ error: LPError, hasSEKey: Bool) -> Bool {
        guard let d = error.detail else { return false }
        if d == SecretStoreDetail.lockedBeforeLogin { return !hasSEKey }
        return d.hasPrefix("se ") || d == "filekey format"
    }
}

/// Checked file I/O in the secrets directory: dir 0700 owned by `owner`, not a symlink; files
/// `O_CREAT|O_EXCL|O_NOFOLLOW` 0600 to a temp name, `F_FULLFSYNC`, `rename`; reads `O_NOFOLLOW` + `fstat` owner/mode.
public struct SecretFiles: Sendable {
    public let directory: URL
    public let owner: uid_t

    public func ensureDirectory() throws(LPError) {
        let p = directory.path
        if mkdir(p, 0o700) != 0 && errno != EEXIST {
            try? FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard mkdir(p, 0o700) == 0 || errno == EEXIST else { throw LPError(.secretStoreUnavailable, detail: "mkdir \(errno)") }
        }
        var st = stat()
        guard lstat(p, &st) == 0 else { throw LPError(.secretStoreUnavailable, detail: "lstat \(errno)") }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == owner, st.st_mode & 0o777 == 0o700 else {
            throw LPError(.secretStoreUnavailable, detail: "secrets dir check")
        }
    }

    func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    public func exists(_ name: String) -> Bool { access(path(name), F_OK) == 0 }

    public func writeAtomic(_ name: String, _ data: Data) throws(LPError) {
        let dst = path(name), tmp = dst + ".tmp"
        unlink(tmp)
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LPError(.secretStoreUnavailable, detail: "open \(errno)") }
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let synced = fcntl(fd, F_FULLFSYNC) != -1
        close(fd)
        guard n == data.count, synced else { unlink(tmp); throw LPError(.secretStoreUnavailable, detail: "write \(errno)") }
        guard rename(tmp, dst) == 0 else { unlink(tmp); throw LPError(.secretStoreUnavailable, detail: "rename \(errno)") }
    }

    public func read(_ name: String) throws(LPError) -> Data {
        let fd = open(path(name), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LPError(.secretStoreUnavailable, detail: "open \(errno)") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == owner, st.st_mode & 0o777 == 0o600, (st.st_mode & S_IFMT) == S_IFREG else {
            throw LPError(.secretStoreUnavailable, detail: "owner/mode")
        }
        var d = Data(count: Int(st.st_size))
        let n = d.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n == Int(st.st_size) else { throw LPError(.secretStoreUnavailable, detail: "short read") }
        return d
    }

    public func remove(_ name: String) { unlink(path(name)) }

    func list() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] }
}

/// DESIGN §6.3 fallback: sealed files in the extension's container (root-only, 0700).
/// File `<ownerUID>.<UUID>.<payload|cred>`: `"LPS2" ‖ UInt32 BE metaLength ‖ SecretMeta plist ‖ AES.GCM.SealedBox.combined`,
/// AAD = `"lp.v2" ‖ kind (0x01 payload, 0x02 cred) ‖ ownerUID (UInt32 BE) ‖ uuid (16) ‖ revision (UInt64 BE)`: a file
/// swapped between uids, profiles, kinds or revisions fails authentication (review H1 namespacing).
public actor ContainerSecretStore: ExtensionSecretStore {
    static let magic = Data("LPS2".utf8)
    static let keyFiles = ["se.key", "filekey.wrapped", "filekey.raw"]
    private let files: SecretFiles
    private let keys: any FileKeyProvider
    private var key: SymmetricKey?

    /// `directory` defaults to the container's `Application Support/secrets`; `owner` is 0 in the extension.
    public init(directory: URL, owner: uid_t = 0, keyProvider: any FileKeyProvider = AutomaticFileKeyProvider()) {
        files = SecretFiles(directory: directory, owner: owner); keys = keyProvider
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("secrets", isDirectory: true)
    }

    static func aad(_ kind: SecretKind, _ id: UUID, _ uid: uid_t, _ revision: UInt64) -> Data {
        var d = Data("lp.v2".utf8); d.append(kind.aadByte)
        withUnsafeBytes(of: uid.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: id.uuid) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: revision.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    static func fileName(_ kind: SecretKind, _ id: UUID, _ uid: uid_t) -> String {
        "\(uid).\(id.uuidString).\(kind == .payload ? "payload" : "cred")"
    }

    private func fileKey() throws(LPError) -> SymmetricKey {
        if let key { return key }
        try files.ensureDirectory()
        let k = try keys.fileKey(files)
        key = k
        return k
    }

    public func put(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t, revision: UInt64, _ bytes: SecretBytes) throws(LPError) {
        let k = try fileKey()
        let meta = SecretMeta(id: id, kind: kind, ownerUID: ownerUID, revision: revision, digest: SecretDigest.hex(bytes))
        let box: AES.GCM.SealedBox
        do { box = try bytes.withUnsafeBytes { try AES.GCM.seal($0, using: k, authenticating: Self.aad(kind, id, ownerUID, revision)) } }
        catch { throw LPError(.secretStoreUnavailable, detail: "seal") }
        let out = SecretEnvelope.frame(Self.magic, meta) { $0.append(box.combined!) }
        try files.writeAtomic(Self.fileName(kind, id, ownerUID), out)
    }

    private func readFile(_ kind: SecretKind, _ id: UUID, _ uid: uid_t) throws(LPError) -> (meta: SecretMeta, sealed: Data)? {
        let name = Self.fileName(kind, id, uid)
        guard files.exists(name) else { return nil }
        let d = try files.read(name)
        guard let sp = SecretEnvelope.split(Self.magic, d), sp.meta.id == id, sp.meta.kind == kind, sp.meta.ownerUID == uid else {
            throw LPError(.secretStoreUnavailable, detail: SecretStoreDetail.unreadableItem)
        }
        return (sp.meta, d.subdata(in: sp.bodyRange))
    }

    public func get(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) throws(LPError) -> SecretBytes? {
        let k = try fileKey()
        guard let f = try readFile(kind, id, ownerUID) else { return nil }
        do {
            var plain = try AES.GCM.open(AES.GCM.SealedBox(combined: f.sealed), using: k,
                                         authenticating: Self.aad(kind, id, ownerUID, f.meta.revision))
            defer { plain.resetBytes(in: 0..<plain.count) }
            return SecretBytes(copying: plain)
        } catch {
            engineLog.fault("sealed secret failed authentication")
            throw LPError(.secretStoreUnavailable, detail: "auth")
        }
    }

    public func entry(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) throws(LPError) -> ProvisionIndexEntry? {
        try files.ensureDirectory()
        return try readFile(kind, id, ownerUID)?.meta.entry
    }

    public func delete(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) throws(LPError) {
        try files.ensureDirectory()
        files.remove(Self.fileName(kind, id, ownerUID))
    }

    /// §6.4: when no uid has a sealed file left afterwards, the file key goes too (SE key blob, wrapped key, raw key).
    public func deleteAll(ownerUID: uid_t) throws(LPError) {
        for e in try index(ownerUID: ownerUID) { try delete(e.kind, e.id, ownerUID: ownerUID) }
        guard !files.list().contains(where: { Self.parseName($0) != nil }) else { return }
        keys.destroyKey(files)
        key = nil
        engineLog.info("secret store: last uid wiped, file key deleted")
    }

    /// `<uid>.<UUID>.<payload|cred>` → its parts; nil for any other name.
    static func parseName(_ name: String) -> (uid: uid_t, id: UUID, kind: SecretKind)? {
        let parts = name.split(separator: ".")
        guard parts.count == 3, let uid = UInt32(parts[0]), let id = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[2] {
        case "payload": return (uid, id, .payload)
        case "cred": return (uid, id, .credential)
        default: return nil
        }
    }

    /// Unreadable files of this uid are reported without a digest (reconcile re-provisions them).
    public func index(ownerUID: uid_t) throws(LPError) -> [ProvisionIndexEntry] {
        try files.ensureDirectory()
        var out: [ProvisionIndexEntry] = []
        for name in files.list().sorted() {
            guard let (uid, id, kind) = Self.parseName(name), uid == ownerUID else { continue }
            guard let f = try? readFile(kind, id, ownerUID) else {
                out.append(ProvisionIndexEntry(id: id, kind: kind, revision: 0, ownerUID: ownerUID, digest: nil)); continue
            }
            out.append(f.meta.entry)
        }
        return out
    }
}
