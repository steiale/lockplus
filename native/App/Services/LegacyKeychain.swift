import Foundation
import os
import Security

/// The Go app's OpenVPN credential items (DESIGN §6.7, `internal/ovpn/keychain_darwin.go`): generic passwords in the
/// LOGIN (file-based) keychain, `service` one of `serviceNames`, `account` = the tunnel name.
enum LegacyKeychain {
    static let serviceNames = ["io.github.steiale.lockplus.ovpn", "io.github.steiale.wireguide-plus.ovpn"]
}

struct LegacyKeychainItem: Sendable, Equatable, Hashable {
    var service: String
    var account: String
}

/// Attributes only (no prompt). `systemKeychainItems` = items in /Library/Keychains/System.keychain, which need
/// administrator authorization and are skipped ("enter it again on first connect"). Migration matrix: WireGuide+
/// 1.0.50–1.0.56 (`…wireguide-plus.ovpn`) and LockPlus 1.0.57–1.0.65 (`…lockplus.ovpn`) wrote there through their root
/// helper; 1.0.66 and later write the login keychain. Both service names are looked up in both keychains.
struct LegacyKeychainListing: Sendable, Equatable {
    var items: [LegacyKeychainItem] = []
    var systemKeychainItems = 0
    /// The System keychain items' accounts (the tunnel names), so the report names the profiles to re-enter.
    var systemAccounts: [String] = []
}

enum LegacyKeychainReadError: Error, Sendable, Equatable {
    /// The user clicked Deny (or cancelled the keychain-password dialog).
    case denied
    case notFound
    case other(Int32)
}

/// What the migrator needs. Never writes or deletes a legacy item (§6.7).
protocol LegacyKeychainReading: Sendable {
    func list() async -> LegacyKeychainListing
    /// One data read: may show "LockPlus wants to use your confidential information" (or ask for the login keychain
    /// password for CLI-era items) and block until the user answers.
    func read(_ item: LegacyKeychainItem) async -> Result<[UInt8], LegacyKeychainReadError>
}

/// The live reader (ref/security §3.3, C13). Uses the login keychain explicitly (`kSecMatchSearchList`), with
/// `kSecUseDataProtectionKeychain` omitted. Each data read blocks its thread until the user answers, possibly for
/// minutes, so every call runs on a dedicated serial queue, never on an actor or the cooperative pool (SC12).
struct LoginKeychainReader: LegacyKeychainReading {
    private static let queue = DispatchQueue(label: "lockplus.legacy-keychain")

    func list() async -> LegacyKeychainListing {
        await withCheckedContinuation { (k: CheckedContinuation<LegacyKeychainListing, Never>) in
            Self.queue.async { @Sendable in k.resume(returning: Self.listNow()) }
        }
    }

    func read(_ item: LegacyKeychainItem) async -> Result<[UInt8], LegacyKeychainReadError> {
        await withCheckedContinuation { (k: CheckedContinuation<Result<[UInt8], LegacyKeychainReadError>, Never>) in
            Self.queue.async { @Sendable in k.resume(returning: Self.readNow(item)) }
        }
    }

    private static func listNow() -> LegacyKeychainListing {
        var out = LegacyKeychainListing()
        let refs = DeprecatedKeychainAPI.shared
        if let login = refs.loginKeychain() {
            for service in LegacyKeychain.serviceNames {
                for account in accounts(service: service, in: login) { out.items.append(LegacyKeychainItem(service: service, account: account)) }
            }
        }
        if let system = refs.systemKeychain() {
            out.systemAccounts = LegacyKeychain.serviceNames.flatMap { accounts(service: $0, in: system) }
            out.systemKeychainItems = out.systemAccounts.count
        }
        return out
    }

    /// Attributes only: no prompt.
    private static func accounts(service: String, in keychain: AnyObject) -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecMatchSearchList as String: [keychain], kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func readNow(_ item: LegacyKeychainItem) -> Result<[UInt8], LegacyKeychainReadError> {
        guard let login = DeprecatedKeychainAPI.shared.loginKeychain() else { return .failure(.notFound) }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: item.service,
                                kSecAttrAccount as String: item.account, kSecMatchSearchList as String: [login],
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard var data = result as? Data else { return .failure(.notFound) }
            defer { data.withUnsafeMutableBytes { if let p = $0.baseAddress { _ = memset_s(p, $0.count, 0, $0.count) } } }
            return .success(Array(data))
        case errSecItemNotFound: return .failure(.notFound)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed: return .failure(.denied)
        default: return .failure(.other(status))
        }
    }
}

/// `SecKeychainCopyDefault`/`SecKeychainOpen` are deprecated since 10.10 and there is no replacement for addressing
/// the file-based login keychain explicitly (§6.7 step 1). The calls live in a deprecated context and are reached
/// through a protocol witness, so the deprecation stays confined here (DESIGN suggests an ObjC file; this is the
/// Swift equivalent without a bridging header).
private protocol KeychainRefs: Sendable {
    func loginKeychain() -> AnyObject?
    func systemKeychain() -> AnyObject?
}

private struct DeprecatedKeychainAPI: KeychainRefs {
    static let shared: any KeychainRefs = DeprecatedKeychainAPI()

    @available(macOS, deprecated: 10.10)
    func loginKeychain() -> AnyObject? {
        var kc: SecKeychain?
        guard SecKeychainCopyDefault(&kc) == errSecSuccess else { return nil }
        return kc
    }

    @available(macOS, deprecated: 10.10)
    func systemKeychain() -> AnyObject? {
        var kc: SecKeychain?
        guard SecKeychainOpen("/Library/Keychains/System.keychain", &kc) == errSecSuccess else { return nil }
        return kc
    }
}

/// Tests and preview mode: never the host keychain.
struct FixtureLegacyKeychain: LegacyKeychainReading {
    var listing = LegacyKeychainListing()
    var values: [LegacyKeychainItem: Result<[UInt8], LegacyKeychainReadError>] = [:]

    func list() async -> LegacyKeychainListing { listing }
    func read(_ item: LegacyKeychainItem) async -> Result<[UInt8], LegacyKeychainReadError> { values[item] ?? .failure(.notFound) }
}
