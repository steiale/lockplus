import Foundation
import LPModel
import LPWire
import Security
import Synchronization

// App-side secrets in the data-protection keychain (DESIGN §6.2, §3.3; ref/security §2.2). One query builder, every
// call goes through it. Calls run on an actor, never on the main thread. Tests and preview mode use `InMemoryKeychain`.

enum KeychainError: Error, Sendable, Equatable {
    /// -25308, -25315, -25320, -25291: retry after unlock/login; never "missing", never regenerate keys.
    case temporarilyUnavailable(OSStatus)
    /// -34018 errSecMissingEntitlement: a signing/profile bug (e.g. an unsigned dev build).
    case misconfigured(OSStatus)
    case other(OSStatus)

    init(_ s: OSStatus) {
        switch s {
        case -25308, -25315, -25320, -25291: self = .temporarilyUnavailable(s)
        case -34018: self = .misconfigured(s)
        default: self = .other(s)
        }
    }

    var lpError: LPError {
        switch self {
        case .temporarilyUnavailable(let s): LPError(.secretStoreUnavailable, detail: "keychain \(s)")
        case .misconfigured(let s): LPError(.secretStoreUnavailable, detail: "keychain entitlement \(s)")
        case .other(let s): LPError(.secretStoreUnavailable, detail: "keychain \(s)")
        }
    }
}

/// Generic-password items keyed by (service, account). Values are raw bytes; there is no text encoding at all.
protocol SecretItemStore: Sendable {
    /// nil ONLY for errSecItemNotFound.
    func load(service: String, account: String) async throws(KeychainError) -> SecretBytes?
    func save(service: String, account: String, _ value: SecretBytes) async throws(KeychainError)
    /// Not-found is success.
    func delete(service: String, account: String) async throws(KeychainError)
    /// Accounts only (attributes query, never data).
    func accounts(service: String) async throws(KeychainError) -> [String]
}

enum KeychainServices {
    static let accessGroup = "M53GHX9FAY.io.github.steiale.lockplus.mac"
    static let payloadKey = "io.github.steiale.lockplus.mac.payload-key"
    static let credentials = "io.github.steiale.lockplus.mac.credentials"
}

/// The real store (§6.2). `kSecUseDataProtectionKeychain`, our access group, not synchronizable,
/// `AfterFirstUnlockThisDeviceOnly` on add.
actor DataProtectionKeychain: SecretItemStore {
    private func base(_ service: String, _ account: String?) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecUseDataProtectionKeychain: true,
                                  kSecAttrAccessGroup: KeychainServices.accessGroup, kSecAttrService: service,
                                  kSecAttrSynchronizable: false]
        if let account { q[kSecAttrAccount] = account }
        return q
    }

    func load(service: String, account: String) throws(KeychainError) -> SecretBytes? {
        var q = base(service, account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess, let d = out as? Data else { throw KeychainError(s) }
        return SecretBytes(copying: d)       // the Data copy dies with this scope (§6.5)
    }

    func save(service: String, account: String, _ value: SecretBytes) throws(KeychainError) {
        let data = value.withUnsafeBytes { Data($0) }
        let q = base(service, account)
        var s = SecItemUpdate(q as CFDictionary, [kSecValueData: data] as CFDictionary)
        if s == errSecItemNotFound {
            var add = q
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel] = "LockPlus"
            s = SecItemAdd(add as CFDictionary, nil)
            if s == errSecDuplicateItem { s = SecItemUpdate(q as CFDictionary, [kSecValueData: data] as CFDictionary) }
        }
        guard s == errSecSuccess else { throw KeychainError(s) }
    }

    func delete(service: String, account: String) throws(KeychainError) {
        let s = SecItemDelete(base(service, account) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw KeychainError(s) }
    }

    func accounts(service: String) throws(KeychainError) -> [String] {
        var q = base(service, nil)
        q[kSecReturnAttributes] = true
        q[kSecMatchLimit] = kSecMatchLimitAll
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return [] }
        guard s == errSecSuccess, let items = out as? [[String: Any]] else { throw KeychainError(s) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Test and preview stand-in. Never touches a host keychain.
final class InMemoryKeychain: SecretItemStore {
    private let items = Mutex<[String: [UInt8]]>([:])
    /// Tests: make every call fail with this status.
    let failure = Mutex<OSStatus?>(nil)

    init() {}

    private func key(_ s: String, _ a: String) -> String { s + "\u{0}" + a }
    private func check() throws(KeychainError) { if let f = failure.withLock({ $0 }) { throw KeychainError(f) } }

    func load(service: String, account: String) async throws(KeychainError) -> SecretBytes? {
        try check()
        return items.withLock { $0[key(service, account)] }.map { SecretBytes(copying: $0) }
    }

    func save(service: String, account: String, _ value: SecretBytes) async throws(KeychainError) {
        try check()
        let bytes = value.copyBytes()
        items.withLock { $0[key(service, account)] = bytes }
    }

    func delete(service: String, account: String) async throws(KeychainError) {
        try check()
        _ = items.withLock { $0.removeValue(forKey: key(service, account)) }
    }

    func accounts(service: String) async throws(KeychainError) -> [String] {
        try check()
        let prefix = service + "\u{0}"
        return items.withLock { $0.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
    }
}

/// OpenVPN credentials, app copy (§6.1, §6.2): a `CredentialRecord` binary plist per profile UUID.
struct CredentialStore: Sendable {
    let items: any SecretItemStore

    func load(_ id: UUID) async throws(KeychainError) -> CredentialRecord? {
        guard let s = try await items.load(service: KeychainServices.credentials, account: id.uuidString) else { return nil }
        return s.withUnsafeBytes { try? PropertyListDecoder().decode(CredentialRecord.self, from: Data($0)) }
    }

    func save(_ id: UUID, _ rec: CredentialRecord) async throws(KeychainError) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let d = try? enc.encode(rec) else { throw KeychainError.other(errSecParam) }
        try await items.save(service: KeychainServices.credentials, account: id.uuidString, SecretBytes(copying: d))
    }

    func delete(_ id: UUID) async throws(KeychainError) {
        try await items.delete(service: KeychainServices.credentials, account: id.uuidString)
    }

    func ids() async throws(KeychainError) -> [UUID] {
        try await items.accounts(service: KeychainServices.credentials).compactMap(UUID.init(uuidString:))
    }
}
