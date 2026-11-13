import CryptoKit
import Foundation
import LPModel
import os
import Security

/// The app's profile files (DESIGN §3.3, §3.4): `profiles/<uuid>.json` = `{"profile": <canonical JSON text>, "mac":
/// hex HMAC-SHA256}` and `profiles/<uuid>.sealed` = `AES.GCM.SealedBox.combined` of the canonical payload.
/// Keys: a 32-byte master key in the data-protection keychain, never used directly; `payloadKey` and `macKey` are
/// HKDF-derived (key separation). Files are 0600 in a 0700 directory and written atomically.
actor ProfileRepository {
    struct LoadResult: Sendable {
        var profiles: [Profile]
        /// HMAC mismatch or unreadable metadata: moved to `*.tampered.<UTC>`, shown as "Settings were changed outside
        /// LockPlus", never re-saved to NE and never provisioned (§3.4 A1).
        var tampered: [UUID]
    }

    private let dir: URL
    private let keys: any SecretItemStore
    private var cachedKeys: Keys?
    /// One key load at a time: actor reentrancy could otherwise create two master keys (review L2).
    private var keyLoad: Task<Result<Keys, LPError>, Never>?

    /// Every key is HKDF-derived from the master key with its own info string (key separation, round 2 N3).
    struct Keys: Sendable {
        var payload: SymmetricKey
        var mac: SymmetricKey
        var records: [SettingsRecord: SymmetricKey]
    }

    /// §6.8: sealed files or metadata exist but the master key is missing (a restore to another Mac, a deleted
    /// item). Never "fixed" by creating a new key: the profiles stay locked until the user removes them.
    static let lockedDetail = "locked: master key missing"
    static func isLocked(_ e: LPError) -> Bool { e.code == .secretStoreUnavailable && e.detail == lockedDetail }
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "profiles")

    init(directory: URL, keys: any SecretItemStore) {
        dir = directory
        self.keys = keys
    }

    // MARK: Keys

    private func loadKeys() async throws(LPError) -> Keys {
        if let cachedKeys { return cachedKeys }
        let task = keyLoad ?? Task { await self.loadKeysOnce() }
        keyLoad = task
        switch await task.value {
        case .success(let k):
            cachedKeys = k
            return k
        case .failure(let e):
            keyLoad = nil                       // a later call may succeed (e.g. after "Remove locked profiles")
            throw e
        }
    }

    private func loadKeysOnce() async -> Result<Keys, LPError> {
        let master: SecretBytes
        do throws(KeychainError) {
            if let m = try await keys.load(service: KeychainServices.payloadKey, account: "v1") {
                // A wrong-size key is never replaced: that would orphan every sealed file (Fable H1).
                guard m.count == 32 else { return .failure(LPError(.secretStoreUnavailable, detail: "master key has the wrong size")) }
                master = m
            } else {
                // errSecItemNotFound: a new key only when no profile file exists (§6.8, Fable H1).
                if hasProfileFiles() { return .failure(LPError(.secretStoreUnavailable, detail: Self.lockedDetail)) }
                let fresh = SecretBytes(count: 32) { b in _ = SecRandomCopyBytes(kSecRandomDefault, 32, b.baseAddress!) }
                try await keys.save(service: KeychainServices.payloadKey, account: "v1", fresh)
                master = fresh
            }
        } catch {
            return .failure(error.lpError)
        }
        let ikm = master.withUnsafeBytes { SymmetricKey(data: $0) }
        let p = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, info: Data("lockplus.payload-seal.v1".utf8), outputByteCount: 32)
        let m = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, info: Data("lockplus.metadata-mac.v1".utf8), outputByteCount: 32)
        var records: [SettingsRecord: SymmetricKey] = [:]
        for r in SettingsRecord.allCases {
            records[r] = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, info: Data("lockplus.record-mac.\(r.rawValue).v1".utf8), outputByteCount: 32)
        }
        return .success(Keys(payload: p, mac: m, records: records))
    }

    private func hasProfileFiles() -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { !$0.hasPrefix(".") && ($0.hasSuffix(".sealed") || $0.hasSuffix(".json")) }
    }

    /// §6.8 locked state: profile names from UNVERIFIED metadata (no key, so no HMAC). Display only: never written to
    /// NE preferences or provisioned.
    func lockedNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { n in
            guard let data = AtomicFile.read(dir.appending(path: n), maxBytes: 1 << 20),
                  let f = try? JSONDecoder().decode(MetaFile.self, from: data),
                  let p = try? Self.profileDecoder().decode(Profile.self, from: Data(f.profile.utf8)) else { return nil }
            return String(p.name.prefix(64))
        }.sorted()
    }

    /// "Start over" (§6.8, user-confirmed): moves every locked profile file into `<profiles>-locked-<UTC>/` next to
    /// the profiles directory (kept, never deleted; a later restore of the old key can still open them) and lets the
    /// next save create a fresh key. Returns the folder.
    func moveAllFilesAside() throws(LPError) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dest = dir.deletingLastPathComponent().appending(path: dir.lastPathComponent + "-locked-" + stamp, directoryHint: .isDirectory)
        do {
            try AtomicFile.ensureDirectory(dest)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for n in names where !n.hasPrefix(".") {
                try FileManager.default.moveItem(at: dir.appending(path: n), to: dest.appending(path: n))
            }
        } catch {
            throw LPError(.profileInvalid, detail: "move aside: \(error.localizedDescription)")
        }
        cachedKeys = nil
        keyLoad = nil
        return dest
    }

    /// Drops the in-memory keys, as a relaunch does (tests; and the next `list()` re-reads the keychain).
    func resetKeyCache() {
        cachedKeys = nil
        keyLoad = nil
    }

    /// "Remove locked profiles" (§6.8): deletes every profile file; the next save creates a fresh key.
    func removeAllFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names where !n.hasPrefix(".") { try? FileManager.default.removeItem(at: dir.appending(path: n)) }
        cachedKeys = nil
        keyLoad = nil
    }

    // MARK: Paths

    private func metaURL(_ id: UUID) -> URL { dir.appending(path: "\(id.uuidString).json") }
    /// `<uuid>.<revision>.sealed` (review M4): a new revision never overwrites the file the committed metadata still
    /// points to; `pruneSealed` removes older revisions after the metadata commit. `<uuid>.sealed` is the
    /// pre-M4 name, still read.
    private func sealedURL(_ id: UUID, _ revision: UInt64) -> URL { dir.appending(path: "\(id.uuidString).\(revision).sealed") }
    private func legacySealedURL(_ id: UUID) -> URL { dir.appending(path: "\(id.uuidString).sealed") }

    private func sealedFiles(_ id: UUID) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(id.uuidString + ".") && $0.hasSuffix(".sealed") }.map { dir.appending(path: $0) }
    }

    /// After the metadata for `revision` is committed: drop every other sealed revision of the profile.
    func pruneSealed(_ id: UUID, keep revision: UInt64) {
        let keep = sealedURL(id, revision).lastPathComponent
        for u in sealedFiles(id) where u.lastPathComponent != keep { unlink(u.path) }
    }

    /// AAD = "lp.v1" ‖ kind(0x01 payload) ‖ uuid(16 raw bytes) ‖ revision(UInt64 big-endian) (§3.3).
    static func aad(_ id: UUID, revision: UInt64) -> Data {
        var d = Data("lp.v1".utf8)
        d.append(0x01)
        withUnsafeBytes(of: id.uuid) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: revision.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    private struct MetaFile: Codable {
        var profile: String
        var mac: String
    }

    private static func profileEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static func profileDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    // MARK: API

    func list() async throws(LPError) -> LoadResult {
        let k = try await loadKeys()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out = LoadResult(profiles: [], tampered: [])
        for n in names where n.hasSuffix(".json") && !n.hasPrefix(".") {
            guard let id = UUID(uuidString: String(n.dropLast(5))) else { continue }
            let url = metaURL(id)
            guard let data = AtomicFile.read(url, maxBytes: 1 << 20),
                  let f = try? JSONDecoder().decode(MetaFile.self, from: data),
                  let mac = Data(hex: f.mac),
                  HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(f.profile.utf8), using: k.mac),
                  let p = try? Self.profileDecoder().decode(Profile.self, from: Data(f.profile.utf8)), p.id == id
            else {
                AtomicFile.quarantine(url, suffix: "tampered")
                out.tampered.append(id)
                continue
            }
            out.profiles.append(p)
        }
        // Round 3 (Fable L3): a quarantine is durable. A profile moved aside (`<id>.json.tampered.<stamp>`) with no
        // `<id>.json` beside it is still reported, at every load: until the user deletes it, it keeps its extension copy
        // (payload, credentials, a running session's start authorisation) and its VPN configuration.
        for n in names where !n.hasPrefix(".") && n.count > 36 && n.dropFirst(36).hasPrefix(".json.tampered.") {
            guard let id = UUID(uuidString: String(n.prefix(36))), id.uuidString == String(n.prefix(36)),
                  !names.contains("\(id.uuidString).json"), !out.tampered.contains(id) else { continue }
            out.tampered.append(id)
        }
        return out
    }

    // MARK: Authenticated settings records (round 1 Codex 3; round 2 M1, L5, N3)

    /// settings.json is writable by any process of this user. A record in it that makes LockPlus start a profile, or
    /// give one unattended-start consent, carries a tag: HMAC-SHA256 with the record kind's own key (HKDF from the
    /// keychain-held master key) over a one-time value and the record's message. The one-time value is a keychain item
    /// of this app's access group, replaced at every seal: an older record of the kind (a copy kept by other code) stops
    /// verifying, and `consumeRecord` deletes it once the record was acted on (one shot). Same-user code can neither
    /// forge nor replay a record; it can only remove one (which makes LockPlus do less, never more).
    func sealRecord(_ kind: SettingsRecord, _ message: Data) async throws(LPError) -> String {
        let k = try await loadKeys()
        let nonce = SecretBytes(count: 32) { b in _ = SecRandomCopyBytes(kSecRandomDefault, 32, b.baseAddress!) }
        do throws(KeychainError) {
            try await keys.save(service: KeychainServices.recordNonce, account: kind.rawValue, nonce)
        } catch {
            throw error.lpError
        }
        return Self.recordTag(k.records[kind]!, nonce: nonce, message: message).hex
    }

    /// `.unavailable`: the key or the one-time value couldn't be read now (retry later; never "changed outside").
    /// `.neverSealed`: no record of this kind was ever sealed here (a value written by a build before 2.0.2).
    func checkRecord(_ kind: SettingsRecord, tag: String?, _ message: Data) async -> RecordCheck {
        let k: Keys
        do throws(LPError) { k = try await loadKeys() } catch {
            return Self.isLocked(error) ? .invalid : .unavailable
        }
        let nonce: SecretBytes?
        do throws(KeychainError) { nonce = try await keys.load(service: KeychainServices.recordNonce, account: kind.rawValue) } catch {
            return .unavailable
        }
        guard let nonce else { return .neverSealed }
        guard let tag, let mac = Data(hex: tag), mac.count == SHA256.byteCount else { return .invalid }
        let expected = Self.recordTag(k.records[kind]!, nonce: nonce, message: message)
        return Self.constantTimeEqual(expected, mac) ? .valid : .invalid
    }

    /// The record was acted on: its one-time value goes, so no copy of it verifies again. False: not deleted (logged;
    /// the next seal of the kind replaces it).
    @discardableResult
    func consumeRecord(_ kind: SettingsRecord) async -> Bool {
        do throws(KeychainError) {
            try await keys.delete(service: KeychainServices.recordNonce, account: kind.rawValue)
            return true
        } catch {
            log.error("one-time value of the \(kind.rawValue, privacy: .public) record not deleted: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func recordTag(_ key: SymmetricKey, nonce: SecretBytes, message: Data) -> Data {
        var h = HMAC<SHA256>(key: key)
        nonce.withUnsafeBytes { h.update(data: $0) }
        h.update(data: message)
        return Data(h.finalize())
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var d: UInt8 = 0
        for (x, y) in zip(a, b) { d |= x ^ y }
        return d == 0
    }

    /// Writes the metadata (HMAC recomputed).
    func saveMetadata(_ p: Profile) async throws(LPError) {
        let k = try await loadKeys()
        do {
            let text = String(decoding: try Self.profileEncoder().encode(p), as: UTF8.self)
            let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: k.mac))
            try AtomicFile.write(try JSONEncoder().encode(MetaFile(profile: text, mac: mac.hex)), to: metaURL(p.id))
        } catch {
            throw LPError(.profileInvalid, detail: "metadata write: \(error.localizedDescription)")
        }
    }

    /// Seals the payload for `profile.payloadRevision`.
    func savePayload(_ payload: SecretBytes, for p: Profile) async throws(LPError) {
        let k = try await loadKeys()
        do {
            let box = try payload.withUnsafeBytes { try AES.GCM.seal($0, using: k.payload, authenticating: Self.aad(p.id, revision: p.payloadRevision)) }
            guard let combined = box.combined else { throw LPError(.profileInvalid, detail: "seal") }
            try AtomicFile.write(combined, to: sealedURL(p.id, p.payloadRevision))
        } catch let e as LPError {
            throw e
        } catch {
            throw LPError(.profileInvalid, detail: "payload write: \(error.localizedDescription)")
        }
    }

    /// Unseals. The caller converts nothing: the plaintext goes straight into `SecretBytes` (§6.5).
    func payload(for p: Profile) async throws(LPError) -> SecretBytes {
        let k = try await loadKeys()
        guard let d = AtomicFile.read(sealedURL(p.id, p.payloadRevision), maxBytes: 2 << 20)
                ?? AtomicFile.read(legacySealedURL(p.id), maxBytes: 2 << 20) else {
            throw LPError(.profileNotProvisioned, detail: "sealed payload missing")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: d)
            var plain = try AES.GCM.open(box, using: k.payload, authenticating: Self.aad(p.id, revision: p.payloadRevision))
            defer { plain.withUnsafeMutableBytes { if let b = $0.baseAddress { _ = memset_s(b, $0.count, 0, $0.count) } } }   // FA nit
            return SecretBytes(copying: plain)
        } catch {
            throw LPError(.profileInvalid, detail: "payload does not authenticate")
        }
    }

    func delete(_ id: UUID) {
        unlink(metaURL(id).path)
        for u in sealedFiles(id) { unlink(u.path) }
        // Round 3 (Fable L3): the quarantined copies go with the profile (else `list()` would report it again).
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names where n.hasPrefix(id.uuidString + ".json.tampered.") { unlink(dir.appending(path: n).path) }
    }

    /// Replay (§3.4 N6): moves a profile aside like an HMAC mismatch.
    func quarantine(_ id: UUID) {
        AtomicFile.quarantine(metaURL(id), suffix: "tampered")
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var it = hex.utf8.makeIterator()
        func nib(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x61...0x66: c - 0x61 + 10
            case 0x41...0x46: c - 0x41 + 10
            default: nil
            }
        }
        while let a = it.next(), let b = it.next() {
            guard let h = nib(a), let l = nib(b) else { return nil }
            out.append(h << 4 | l)
        }
        self = out
    }
}
