import os
import CryptoKit
import Foundation
import LPModel
import Security

/// The `SecItem` calls the System-keychain store makes, as a seam: unit tests inject a fake and never touch a real
/// keychain. Each item is a generic password keyed by (service, account); nothing but the value is ever written.
public protocol GenericPasswordBackend: Sendable {
    func copyData(service: String, account: String) -> (OSStatus, Data?)
    func update(service: String, account: String, data: Data) -> OSStatus
    func add(service: String, account: String, data: Data, label: String) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
    /// Account names only (never data), `kSecMatchLimitAll`. May return an account more than once (S4 on 27).
    func enumerate(service: String) -> (OSStatus, [String])
}

/// The real backend: plain `SecItem` in the system context (root's default keychain = System.keychain, TN3137).
/// No `kSecUseDataProtectionKeychain`, no `kSecAttrAccessible`, no `kSecUseAuthenticationUI` (§6.3).
public struct SecItemBackend: GenericPasswordBackend {
    public init() {}
    private func base(_ service: String, _ account: String?) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        if let account { q[kSecAttrAccount] = account }
        return q
    }
    public func copyData(service: String, account: String) -> (OSStatus, Data?) {
        var q = base(service, account); q[kSecReturnData] = true; q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        return (s, out as? Data)
    }
    public func update(service: String, account: String, data: Data) -> OSStatus {
        SecItemUpdate(base(service, account) as CFDictionary, [kSecValueData: data] as CFDictionary)
    }
    public func add(service: String, account: String, data: Data, label: String) -> OSStatus {
        var q = base(service, account); q[kSecValueData] = data; q[kSecAttrLabel] = label
        return SecItemAdd(q as CFDictionary, nil)
    }
    public func delete(service: String, account: String) -> OSStatus { SecItemDelete(base(service, account) as CFDictionary) }
    public func enumerate(service: String) -> (OSStatus, [String]) {
        var q = base(service, nil); q[kSecReturnAttributes] = true; q[kSecMatchLimit] = kSecMatchLimitAll
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        let items = (out as? [[String: Any]]) ?? []
        return (s, items.compactMap { $0[kSecAttrAccount as String] as? String })
    }
}

/// DESIGN §6.3 primary store, with the review H1/L4 layout:
/// - Item value (`kSecValueData`, readable by root only) = `"LPK1" ‖ UInt32 BE metaLength ‖ SecretMeta ‖ secret`.
///   Profile UUID, ownerUID, revision and digest live there; attributes carry nothing but the constant label.
/// - Account = hex HMAC-SHA256(accountKey, `"lp.acct.v1" ‖ kind ‖ ownerUID (BE) ‖ uuid`): per-uid namespace, and not
///   guessable or linkable to a profile UUID by anyone who can list attributes. The 256-bit account key is itself an
///   item (`<prefix>key` / `account-hmac`), created on first use.
/// - Every read re-checks the value's metadata against the (kind, uuid, uid) it was addressed by.
/// - Store lifecycle (NEW-5): items whose account is not the HMAC of their own metadata under the current key are
///   unreachable. On the first key load of this store instance, a missing or wrong-size key with items present, or a
///   valid key under which no item matches (no uid has any entry), resets the store: every `<prefix>payload|cred` item
///   and the key are deleted, the key is recreated on demand, and the number of unmatched items is reported through
///   `onReset` (`DiagnosticsHook.secretStoreReset`). reconcile() then re-provisions from the app (§6.4). Wiping the last
///   uid's items (`deleteAll`) deletes the key too (§6.4).
public actor SystemKeychainSecretStore: ExtensionSecretStore {
    public static let releasePrefix = "io.github.steiale.lockplus.mac.tunnel."
    public static let devPrefix = "io.github.steiale.lockplus.mac.tunnel.dev."
    static let label = "LockPlus tunnel secret"
    static let magic = Data("LPK1".utf8)
    static let keyAccount = "account-hmac"

    private let backend: any GenericPasswordBackend
    private let prefix: String
    private let onReset: @Sendable (_ unmatchedItems: Int, _ reason: String) -> Void
    private var accountKey: SymmetricKey?
    /// The one-time key/item consistency check of this instance has run (NEW-5).
    private var keyChecked = false

    /// `servicePrefix`: Release `…tunnel.`, Debug builds `…tunnel.dev.` (§6.3; chosen by the Tunnel target, since
    /// package code can't see target conditions, §2.2).
    public init(backend: any GenericPasswordBackend = SecItemBackend(), servicePrefix: String = releasePrefix,
                onReset: @escaping @Sendable (_ unmatchedItems: Int, _ reason: String) -> Void = DiagnosticsHook.secretStoreReset) {
        self.backend = backend; prefix = servicePrefix; self.onReset = onReset
    }

    func service(_ k: SecretKind) -> String { prefix + (k == .payload ? "payload" : "cred") }
    var keyService: String { prefix + "key" }

    /// errSecItemNotFound = absent; -67674 / EPERM (100001) / -25308 → `.secretStoreUnavailable` at `.fault` (§6.3).
    static func map(_ s: OSStatus, _ op: String) -> LPError {
        switch s {
        case errSecInteractionNotAllowed:
            engineLog.fault("secret store \(op, privacy: .public): \(s)")
            return LPError(.secretStoreUnavailable, detail: SecretStoreDetail.lockedBeforeLogin)
        case -67674, 100001:
            engineLog.fault("secret store \(op, privacy: .public): \(s)")
            return LPError(.secretStoreUnavailable, detail: "\(op) \(s)")
        default:
            engineLog.error("secret store \(op, privacy: .public): \(s)")
            return LPError(.secretStoreUnavailable, detail: "\(op) \(s)")
        }
    }

    // MARK: account names

    private func key(create: Bool) throws(LPError) -> SymmetricKey? {
        if let accountKey { return accountKey }
        for _ in 0..<3 {
            let (s, d) = backend.copyData(service: keyService, account: Self.keyAccount)
            if s == errSecSuccess, var d {
                defer { d.resetBytes(in: 0..<d.count) }
                guard d.count == 32 else {
                    // NEW-5: an unusable key orphans every item. Reset, then recreate (next iteration).
                    try reset(try scan(nil), reason: "account key size")
                    continue
                }
                let k = SymmetricKey(data: d)
                if !keyChecked {
                    let sc = try scan(k)
                    if sc.matched == 0 && !sc.items.isEmpty {
                        // A replaced key: no uid has any entry under it.
                        try reset(sc, reason: "no matching entries")
                        continue
                    }
                    if sc.unmatched > 0 { engineLog.error("secret store: \(sc.unmatched, privacy: .public) item(s) not addressable under the account key") }
                    keyChecked = true
                }
                accountKey = k
                return k
            }
            guard s == errSecItemNotFound else { throw Self.map(s, "key") }
            if !keyChecked {
                // NEW-5: a missing key with items present orphans them all.
                let sc = try scan(nil)
                if !sc.items.isEmpty { try reset(sc, reason: "account key missing") }
                keyChecked = true
            }
            guard create else { return nil }
            let k = SymmetricKey(size: .bits256)
            var raw = k.withUnsafeBytes { Data($0) }
            defer { raw.resetBytes(in: 0..<raw.count) }
            let a = backend.add(service: keyService, account: Self.keyAccount, data: raw, label: Self.label)
            if a == errSecSuccess { accountKey = k; return k }
            guard a == errSecDuplicateItem else { throw Self.map(a, "key") }
            // Lost a race with another writer: read theirs.
        }
        throw LPError(.secretStoreUnavailable, detail: "account key")
    }

    /// Every payload/cred item (de-duplicated), and how many are addressable under `key` (nil: none are).
    private func scan(_ key: SymmetricKey?) throws(LPError) -> (items: [(service: String, account: String)], matched: Int, unmatched: Int) {
        var items: [(service: String, account: String)] = []
        var matched = 0
        for kind in SecretKind.allCases {
            let svc = service(kind)
            let (s, accounts) = backend.enumerate(service: svc)
            if s == errSecItemNotFound { continue }
            guard s == errSecSuccess else { throw Self.map(s, "scan") }
            var seen = Set<String>()
            for acct in accounts where seen.insert(acct).inserted {
                items.append((svc, acct))
                guard let key else { continue }
                let (cs, d) = backend.copyData(service: svc, account: acct)
                if cs == errSecItemNotFound { items.removeLast(); continue }
                guard cs == errSecSuccess, var d else { throw Self.map(cs, "scan") }
                let meta = SecretEnvelope.split(Self.magic, d)?.meta
                d.resetBytes(in: 0..<d.count)
                if let meta, meta.kind == kind, Self.account(key, kind, meta.id, meta.ownerUID) == acct { matched += 1 }
            }
        }
        return (items, matched, items.count - matched)
    }

    /// Deletes every scanned item and the account key; the key is recreated on the next `put`. Reports the
    /// unmatched count (all items when there was no usable key).
    private func reset(_ sc: (items: [(service: String, account: String)], matched: Int, unmatched: Int), reason: String) throws(LPError) {
        for it in sc.items {
            let s = backend.delete(service: it.service, account: it.account)
            guard s == errSecSuccess || s == errSecItemNotFound else { throw Self.map(s, "reset") }
        }
        let s = backend.delete(service: keyService, account: Self.keyAccount)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw Self.map(s, "reset") }
        accountKey = nil
        keyChecked = true
        if reason == Self.lastUIDWiped && sc.unmatched == 0 {
            engineLog.info("secret store: last uid wiped, account key deleted")
            return
        }
        engineLog.fault("secret store reset (\(reason, privacy: .public)): \(sc.unmatched, privacy: .public) unmatched item(s) deleted")
        onReset(sc.unmatched, reason)
    }

    static let lastUIDWiped = "last uid wiped"

    static func account(_ key: SymmetricKey, _ kind: SecretKind, _ id: UUID, _ uid: uid_t) -> String {
        var m = Data("lp.acct.v1".utf8)
        m.append(kind.aadByte)
        withUnsafeBytes(of: uid.bigEndian) { m.append(contentsOf: $0) }
        withUnsafeBytes(of: id.uuid) { m.append(contentsOf: $0) }
        return HMAC<SHA256>.authenticationCode(for: m, using: key).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: items

    /// The item's value, split and checked against its address; nil when absent.
    private func read(_ kind: SecretKind, _ id: UUID, _ uid: uid_t, account: String) throws(LPError) -> (meta: SecretMeta, data: Data, body: Range<Data.Index>)? {
        let (s, d) = backend.copyData(service: service(kind), account: account)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess, var d else { throw Self.map(s, "get") }
        guard let sp = SecretEnvelope.split(Self.magic, d), sp.meta.id == id, sp.meta.kind == kind, sp.meta.ownerUID == uid else {
            d.resetBytes(in: 0..<d.count)
            engineLog.fault("keychain item does not match its address")
            throw LPError(.secretStoreUnavailable, detail: SecretStoreDetail.unreadableItem)
        }
        return (sp.meta, d, sp.bodyRange)
    }

    public func put(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t, revision: UInt64, _ bytes: SecretBytes) throws(LPError) {
        guard let k = try key(create: true) else { throw LPError(.secretStoreUnavailable, detail: "account key") }
        let meta = SecretMeta(id: id, kind: kind, ownerUID: ownerUID, revision: revision, digest: SecretDigest.hex(bytes))
        // `Data` copy is unavoidable at the SecItem boundary; scoped to this call and zeroed (§6.5).
        var data = SecretEnvelope.frame(Self.magic, meta) { out in bytes.withUnsafeBytes { out.append(contentsOf: $0) } }
        defer { data.resetBytes(in: 0..<data.count) }
        let svc = service(kind), acct = Self.account(k, kind, id, ownerUID)
        var s = backend.update(service: svc, account: acct, data: data)
        if s == errSecItemNotFound {
            s = backend.add(service: svc, account: acct, data: data, label: Self.label)
            if s == errSecDuplicateItem { s = backend.update(service: svc, account: acct, data: data) }
        }
        guard s == errSecSuccess else { throw Self.map(s, "put") }
    }

    public func get(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) throws(LPError) -> SecretBytes? {
        guard let k = try key(create: false), var r = try read(kind, id, ownerUID, account: Self.account(k, kind, id, ownerUID)) else {
            return nil
        }
        defer { r.data.resetBytes(in: 0..<r.data.count) }
        return SecretBytes(copying: r.data[r.body])
    }

    public func entry(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) throws(LPError) -> ProvisionIndexEntry? {
        guard let k = try key(create: false), var r = try read(kind, id, ownerUID, account: Self.account(k, kind, id, ownerUID)) else {
            return nil
        }
        r.data.resetBytes(in: 0..<r.data.count)
        return r.meta.entry
    }

    public func delete(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) throws(LPError) {
        guard let k = try key(create: false) else { return }
        let s = backend.delete(service: service(kind), account: Self.account(k, kind, id, ownerUID))
        guard s == errSecSuccess || s == errSecItemNotFound else { throw Self.map(s, "delete") }
    }

    /// §6.4: when no uid has an entry left afterwards, the account key goes too (with any unmatched leftovers).
    public func deleteAll(ownerUID: uid_t) throws(LPError) {
        for e in try index(ownerUID: ownerUID) { try delete(e.kind, e.id, ownerUID: ownerUID) }
        guard let k = try key(create: false) else { return }
        let sc = try scan(k)
        if sc.matched == 0 { try reset(sc, reason: Self.lastUIDWiped) }
    }

    /// Reads every item's metadata (accounts are opaque) and keeps `ownerUID`'s. De-duplicates accounts (S4: the
    /// attribute-only `kSecMatchLimitAll` returns every item twice on 27). An item whose account isn't the HMAC of its
    /// own metadata is foreign or moved: skipped, never reported.
    public func index(ownerUID: uid_t) throws(LPError) -> [ProvisionIndexEntry] {
        guard let k = try key(create: false) else { return [] }
        var out: [ProvisionIndexEntry] = []
        for kind in SecretKind.allCases {
            let (s, accounts) = backend.enumerate(service: service(kind))
            if s == errSecItemNotFound { continue }
            guard s == errSecSuccess else { throw Self.map(s, "index") }
            var seen = Set<String>()
            for acct in accounts where seen.insert(acct).inserted {
                let (cs, d) = backend.copyData(service: service(kind), account: acct)
                if cs == errSecItemNotFound { continue }
                guard cs == errSecSuccess, var d else { throw Self.map(cs, "index") }
                let meta = SecretEnvelope.split(Self.magic, d)?.meta
                d.resetBytes(in: 0..<d.count)
                guard let meta, meta.kind == kind, meta.ownerUID == ownerUID,
                      Self.account(k, kind, meta.id, meta.ownerUID) == acct else { continue }
                out.append(meta.entry)
            }
        }
        return out
    }
}
