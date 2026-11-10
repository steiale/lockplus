import CryptoKit
import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// Never touches a real keychain: the System-keychain store runs on `FakeKeychainBackend`, the container store on a
/// directory under $LP_BUILD_ROOT/test-scratch (never /tmp) with the raw file-key provider.
@Suite struct SystemKeychainSecretStoreTests {
    let id = UUID()

    @Test func roundTripAndUpdate() async throws {
        let store = SystemKeychainSecretStore(backend: FakeKeychainBackend(), servicePrefix: SystemKeychainSecretStore.devPrefix)
        try await store.put(.payload, id, ownerUID: 501, revision: 1, .text("one"))
        #expect(try await store.get(.payload, id, ownerUID: 501)?.bytesForTest == Array("one".utf8))
        try await store.put(.payload, id, ownerUID: 501, revision: 2, .text("two"))
        #expect(try await store.get(.payload, id, ownerUID: 501)?.bytesForTest == Array("two".utf8))
        #expect(try await store.entry(.payload, id, ownerUID: 501)?.revision == 2)
        #expect(try await store.get(.credential, id, ownerUID: 501) == nil)
        try await store.delete(.payload, id, ownerUID: 501)
        try await store.delete(.payload, id, ownerUID: 501)                // not-found is success
        #expect(try await store.get(.payload, id, ownerUID: 501) == nil)
    }

    /// H1: the same UUID under two uids is two independent items; neither uid can read, overwrite or delete the other.
    @Test func namespacesAreIndependent() async throws {
        let store = SystemKeychainSecretStore(backend: FakeKeychainBackend())
        try await store.put(.payload, id, ownerUID: 502, revision: 9, .text("mallory"))
        try await store.put(.payload, id, ownerUID: 501, revision: 1, .text("alice"))
        #expect(try await store.get(.payload, id, ownerUID: 501)?.bytesForTest == Array("alice".utf8))
        #expect(try await store.get(.payload, id, ownerUID: 502)?.bytesForTest == Array("mallory".utf8))
        #expect(try await store.get(.payload, id, ownerUID: 503) == nil)
        try await store.deleteAll(ownerUID: 502)
        #expect(try await store.get(.payload, id, ownerUID: 501) != nil)
        #expect(try await store.index(ownerUID: 502).isEmpty)
    }

    /// L4: nothing a non-root user can list (service, account, label) reveals a profile UUID, a uid, a revision or a
    /// digest; accounts are opaque HMACs. The metadata is inside the value.
    @Test func attributesRevealNothing() async throws {
        let be = FakeKeychainBackend()
        let store = SystemKeychainSecretStore(backend: be)
        try await store.put(.payload, id, ownerUID: 501, revision: 7, .text("p"))
        try await store.put(.credential, id, ownerUID: 501, revision: 7, .text("c"))
        let digest = SecretDigest.hex(.text("p"))
        let uuid = id.uuidString.lowercased()
        for addr in be.addresses {
            let a = addr.lowercased()
            #expect(!a.contains(uuid))
            #expect(!a.contains(digest))
        }
        #expect(be.s.withLock { $0.labels } == [SystemKeychainSecretStore.label])
        let accounts: [String] = be.addresses.filter { !$0.hasSuffix("|" + SystemKeychainSecretStore.keyAccount) }
            .map { String($0.split(separator: "|")[1]) }
        #expect(accounts.count == 2)
        #expect(accounts.allSatisfy { $0.count == 64 })
    }

    /// S4: account enumeration returns every item twice; index() de-duplicates and reports the caller's rows only.
    @Test func indexDeduplicatesAndIsPerUid() async throws {
        let be = FakeKeychainBackend()
        let store = SystemKeychainSecretStore(backend: be)
        let other = UUID()
        try await store.put(.payload, id, ownerUID: 501, revision: 3, .text("p"))
        try await store.put(.credential, id, ownerUID: 501, revision: 3, .text("c"))
        try await store.put(.payload, other, ownerUID: 502, revision: 1, .text("q"))
        let idx = try await store.index(ownerUID: 501)
        #expect(idx.count == 2)
        let e = try #require(idx.first { $0.id == id && $0.kind == .payload })
        #expect(e.revision == 3 && e.ownerUID == 501)
        #expect(e.digest == SecretDigest.hex(.text("p")))
        let others = try await store.index(ownerUID: 502).map(\.id)
        #expect(others == [other])
    }

    /// An item copied to another account (another uid's address) is rejected on read and skipped by index.
    @Test func movedItemIsRejected() async throws {
        let be = FakeKeychainBackend()
        let store = SystemKeychainSecretStore(backend: be)
        try await store.put(.payload, id, ownerUID: 502, revision: 1, .text("evil"))
        let before = Set(be.addresses)
        try await store.put(.payload, id, ownerUID: 501, revision: 1, .text("good"))
        let good = try #require(Set(be.addresses).subtracting(before).first)
        let svc = await store.service(.payload)
        let evil = try #require(before.first { $0.hasPrefix(svc + "|") })
        be.s.withLock { $0.items[good] = $0.items[evil] }                  // mallory's value at alice's address
        await #expect(throws: LPError.self) { try await store.get(.payload, id, ownerUID: 501) }
        #expect(try await store.index(ownerUID: 501).isEmpty)
    }

    @Test(arguments: [(errSecInteractionNotAllowed, SecretStoreDetail.lockedBeforeLogin), (OSStatus(-67674), nil), (OSStatus(100001), nil)])
    func unavailableCodes(status: OSStatus, detail: String?) async throws {
        let be = FakeKeychainBackend()
        be.s.withLock { $0.failStatus = status }
        let store = SystemKeychainSecretStore(backend: be)
        do throws(LPError) { _ = try await store.get(.payload, id, ownerUID: 501); Issue.record("no throw") } catch {
            #expect(error.code == .secretStoreUnavailable)
            if let detail { #expect(error.detail == detail) }
        }
    }

    // MARK: store lifecycle (NEW-5)

    final class Resets: Sendable {
        let s = Mutex<[(Int, String)]>([])
        var all: [(Int, String)] { s.withLock { $0 } }
        var hook: @Sendable (Int, String) -> Void { { n, r in self.s.withLock { $0.append((n, r)) } } }
    }

    func keyAddress(_ be: FakeKeychainBackend) -> String? { be.addresses.first { $0.hasSuffix("key|" + SystemKeychainSecretStore.keyAccount) } }
    func itemCount(_ be: FakeKeychainBackend) -> Int { be.addresses.filter { !$0.hasSuffix("|" + SystemKeychainSecretStore.keyAccount) }.count }

    /// A missing account key with items present: a new store instance deletes the orphans, reports their count and
    /// recreates the key; the uid's profile is simply absent (reconcile re-provisions it).
    @Test func missingKeyResetsTheStore() async throws {
        let be = FakeKeychainBackend()
        try await SystemKeychainSecretStore(backend: be).put(.payload, id, ownerUID: 501, revision: 1, .text("p"))
        try await SystemKeychainSecretStore(backend: be).put(.credential, id, ownerUID: 502, revision: 1, .text("c"))
        be.s.withLock { st in st.items = st.items.filter { !$0.key.hasSuffix("|" + SystemKeychainSecretStore.keyAccount) } }
        let resets = Resets()
        let store = SystemKeychainSecretStore(backend: be, onReset: resets.hook)
        #expect(try await store.get(.payload, id, ownerUID: 501) == nil)
        #expect(resets.all.map(\.0) == [2] && resets.all.first?.1 == "account key missing")
        #expect(itemCount(be) == 0 && keyAddress(be) == nil)         // no key created by a read
        try await store.put(.payload, id, ownerUID: 501, revision: 2, .text("new"))
        #expect(keyAddress(be) != nil)
        #expect(try await store.get(.payload, id, ownerUID: 501)?.bytesForTest == Array("new".utf8))
        #expect(resets.all.count == 1)
    }

    /// A wrong-size key: reset (items and key deleted, count reported), then a fresh 32-byte key.
    @Test func wrongSizeKeyResetsTheStore() async throws {
        let be = FakeKeychainBackend()
        try await SystemKeychainSecretStore(backend: be).put(.payload, id, ownerUID: 501, revision: 1, .text("p"))
        let ka = try #require(keyAddress(be))
        be.s.withLock { $0.items[ka] = Data(repeating: 7, count: 16) }
        let resets = Resets()
        let store = SystemKeychainSecretStore(backend: be, onReset: resets.hook)
        try await store.put(.payload, id, ownerUID: 501, revision: 2, .text("q"))
        #expect(resets.all.map(\.0) == [1] && resets.all.first?.1 == "account key size")
        #expect(be.s.withLock { $0.items[ka]?.count } == 32)
        #expect(itemCount(be) == 1)
        #expect(try await store.entry(.payload, id, ownerUID: 501)?.revision == 2)
    }

    /// A valid key under which no item matches (the key was replaced): no uid has any entry → reset.
    @Test func replacedKeyWithNoMatchesResetsTheStore() async throws {
        let be = FakeKeychainBackend()
        try await SystemKeychainSecretStore(backend: be).put(.payload, id, ownerUID: 501, revision: 1, .text("p"))
        try await SystemKeychainSecretStore(backend: be).put(.payload, UUID(), ownerUID: 503, revision: 1, .text("r"))
        let ka = try #require(keyAddress(be))
        be.s.withLock { $0.items[ka] = Data(repeating: 1, count: 32) }
        let resets = Resets()
        let store = SystemKeychainSecretStore(backend: be, onReset: resets.hook)
        #expect(try await store.index(ownerUID: 501).isEmpty)
        #expect(resets.all.map(\.0) == [2] && resets.all.first?.1 == "no matching entries")
        #expect(itemCount(be) == 0 && keyAddress(be) == nil)
    }

    /// Items that still match keep the store: one stray item does not trigger a reset.
    @Test func partialMatchDoesNotReset() async throws {
        let be = FakeKeychainBackend()
        try await SystemKeychainSecretStore(backend: be).put(.payload, id, ownerUID: 501, revision: 1, .text("p"))
        let svc = await SystemKeychainSecretStore(backend: be).service(.payload)
        be.s.withLock { $0.items[svc + "|" + String(repeating: "0", count: 64)] = Data("junk".utf8) }
        let resets = Resets()
        let store = SystemKeychainSecretStore(backend: be, onReset: resets.hook)
        #expect(try await store.get(.payload, id, ownerUID: 501) != nil)
        #expect(resets.all.isEmpty && itemCount(be) == 2)
    }

    /// §6.4: wiping the last uid deletes the HMAC key too; while another uid has items, the key stays.
    @Test func lastUIDWipeDeletesTheKey() async throws {
        let be = FakeKeychainBackend()
        let resets = Resets()
        let store = SystemKeychainSecretStore(backend: be, onReset: resets.hook)
        try await store.put(.payload, id, ownerUID: 501, revision: 1, .text("a"))
        try await store.put(.credential, id, ownerUID: 501, revision: 1, .text("c"))
        try await store.put(.payload, id, ownerUID: 502, revision: 1, .text("b"))
        try await store.deleteAll(ownerUID: 501)
        #expect(keyAddress(be) != nil)
        #expect(try await store.get(.payload, id, ownerUID: 502) != nil)
        try await store.deleteAll(ownerUID: 502)
        #expect(keyAddress(be) == nil && itemCount(be) == 0)
        #expect(resets.all.isEmpty)                                  // a clean wipe is not a reset
        // the store keeps working with a fresh key
        try await store.put(.payload, id, ownerUID: 501, revision: 3, .text("z"))
        #expect(keyAddress(be) != nil)
        #expect(try await store.get(.payload, id, ownerUID: 501)?.bytesForTest == Array("z".utf8))
    }

    @Test func credentialCodecRoundTrip() throws {
        let c = CredentialSecrets(username: .text("alice"), password: .text("pw"), keyPassphrase: nil)
        let back = try #require(CredentialCodec.decode(CredentialCodec.encode(c)))
        #expect(back.username?.bytesForTest == Array("alice".utf8) && back.password?.bytesForTest == Array("pw".utf8) && back.keyPassphrase == nil)
    }

    @Test func credentialCodecRoundTripsProxyCredentials() throws {
        let c = CredentialSecrets(username: .text("alice"), proxyUsername: .text("proxyuser"), proxyPassword: .text("proxypw"))
        let back = try #require(CredentialCodec.decode(CredentialCodec.encode(c)))
        #expect(back.proxyUsername?.bytesForTest == Array("proxyuser".utf8) && back.proxyPassword?.bytesForTest == Array("proxypw".utf8))
        #expect(back.username?.bytesForTest == Array("alice".utf8) && back.password == nil)
        let none = try #require(CredentialCodec.decode(CredentialCodec.encode(CredentialSecrets(password: .text("pw")))))
        #expect(none.proxyUsername == nil && none.proxyPassword == nil)
    }

    @Test func secretBytesIsRedacted() {
        let s = SecretBytes.text("hunter2")
        #expect("\(s)" == "<redacted>" && String(reflecting: s) == "<redacted>")
        #expect(Mirror(reflecting: s).children.isEmpty)
    }
}

@Suite(.serialized) struct ContainerSecretStoreTests {
    static let root: URL = {
        // $LP_BUILD_ROOT (default ~/Code/lockplus-build) / test-scratch: internal disk, outside the backup
        let buildRoot = ProcessInfo.processInfo.environment["LP_BUILD_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code/lockplus-build")
        return buildRoot.appendingPathComponent("test-scratch", isDirectory: true)
    }()

    func freshDir() throws -> URL {
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let d = Self.root.appendingPathComponent("secrets-\(UUID().uuidString)", isDirectory: true)
        return d
    }

    @Test func sealedRoundTripAndIndex() async throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ContainerSecretStore(directory: dir, owner: getuid(), keyProvider: RawFileKeyProvider())
        let id = UUID()
        try await store.put(.payload, id, ownerUID: 501, revision: 9, .text("[Interface]"))
        #expect(try await store.get(.payload, id, ownerUID: 501)?.bytesForTest == Array("[Interface]".utf8))
        #expect(try await store.get(.payload, id, ownerUID: 502) == nil)
        let idx = try await store.index(ownerUID: 501)
        #expect(idx == [ProvisionIndexEntry(id: id, kind: .payload, revision: 9, ownerUID: 501, digest: SecretDigest.hex(.text("[Interface]")))])
        // dir 0700, files 0600, raw key 32 bytes
        var st = stat()
        #expect(lstat(dir.path, &st) == 0 && st.st_mode & 0o777 == 0o700)
        #expect(stat(dir.appendingPathComponent("501.\(id.uuidString).payload").path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(stat(dir.appendingPathComponent("filekey.raw").path, &st) == 0 && st.st_size == 32)
        // a second store instance (a replaced extension) reads it with the same key file
        let again = ContainerSecretStore(directory: dir, owner: getuid(), keyProvider: RawFileKeyProvider())
        #expect(try await again.get(.payload, id, ownerUID: 501) != nil)
        try await store.deleteAll(ownerUID: 501)
        #expect(try await store.index(ownerUID: 501).isEmpty)
    }

    /// A file swapped between profiles fails AES-GCM authentication (AAD binds kind, UUID, revision).
    @Test func swappedFileIsRejected() async throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ContainerSecretStore(directory: dir, owner: getuid(), keyProvider: RawFileKeyProvider())
        let a = UUID(), b = UUID()
        try await store.put(.payload, a, ownerUID: 501, revision: 1, .text("A"))
        try await store.put(.payload, b, ownerUID: 501, revision: 1, .text("B"))
        let pa = dir.appendingPathComponent("501.\(a.uuidString).payload").path, pb = dir.appendingPathComponent("501.\(b.uuidString).payload").path
        #expect(rename(pa, pb) == 0)
        await #expect(throws: LPError.self) { try await store.get(.payload, b, ownerUID: 501) }
        try await store.put(.payload, a, ownerUID: 502, revision: 1, .text("M"))
        let pm = dir.appendingPathComponent("502.\(a.uuidString).payload").path
        #expect(rename(pm, dir.appendingPathComponent("501.\(a.uuidString).payload").path) == 0)
        await #expect(throws: LPError.self) { try await store.get(.payload, a, ownerUID: 501) }
    }

    /// §6.4: wiping the last uid deletes the fallback's file key; while another uid has files, the key stays.
    @Test func lastUIDWipeDeletesTheFileKey() async throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ContainerSecretStore(directory: dir, owner: getuid(), keyProvider: RawFileKeyProvider())
        let id = UUID()
        try await store.put(.payload, id, ownerUID: 501, revision: 1, .text("a"))
        try await store.put(.payload, id, ownerUID: 502, revision: 1, .text("b"))
        let raw = dir.appendingPathComponent("filekey.raw").path
        try await store.deleteAll(ownerUID: 501)
        #expect(FileManager.default.fileExists(atPath: raw))
        #expect(try await store.get(.payload, id, ownerUID: 502) != nil)
        try await store.deleteAll(ownerUID: 502)
        #expect(!FileManager.default.fileExists(atPath: raw))
        // the SE blobs go too (written here as stand-ins; the default destroyKey removes every key file)
        for n in ["se.key", "filekey.wrapped"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data([1])) }
        try await store.deleteAll(ownerUID: 503)
        for n in ContainerSecretStore.keyFiles { #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path)) }
        // the next put creates a fresh key, and new items round-trip under it
        try await store.put(.payload, id, ownerUID: 501, revision: 2, .text("c"))
        #expect(FileManager.default.fileExists(atPath: raw))
        #expect(try await store.get(.payload, id, ownerUID: 501)?.bytesForTest == Array("c".utf8))
    }

    @Test func refusesWrongOwnerOrMode() async throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ContainerSecretStore(directory: dir, owner: getuid() + 1, keyProvider: RawFileKeyProvider())
        await #expect(throws: LPError.self) { try await store.index(ownerUID: 501) }
        let ok = ContainerSecretStore(directory: dir, owner: getuid(), keyProvider: RawFileKeyProvider())
        chmod(dir.path, 0o755)
        await #expect(throws: LPError.self) { try await ok.index(ownerUID: 501) }
    }

    @Test func symlinkedFileIsRefused() async throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ContainerSecretStore(directory: dir, owner: getuid(), keyProvider: RawFileKeyProvider())
        let id = UUID()
        try await store.put(.payload, id, ownerUID: 501, revision: 1, .text("x"))
        let p = dir.appendingPathComponent("501.\(id.uuidString).payload").path
        rename(p, p + ".real")
        symlink(p + ".real", p)
        await #expect(throws: LPError.self) { try await store.get(.payload, id, ownerUID: 501) }
    }

    // MARK: S4 (draft 9): any Secure Enclave error is "no SE"

    /// A fake SE provider that fails with a fixed `.secretStoreUnavailable` detail (or succeeds with a fixed key).
    struct FakeSE: FileKeyProvider {
        var detail: String?
        func fileKey(_ files: SecretFiles) throws(LPError) -> SymmetricKey {
            if let detail { throw LPError(.secretStoreUnavailable, detail: detail) }
            try files.writeAtomic("se.key", Data([1])); try files.writeAtomic("filekey.wrapped", Data([2]))
            return SymmetricKey(data: Data(repeating: 7, count: 32))
        }
    }

    /// The VM case: `isAvailable` is true, creating the key fails with -25308 (or anything else) → the raw key.
    @Test(arguments: [SecretStoreDetail.lockedBeforeLogin, "se -536870174", "se -25293"])
    func seCreateErrorFallsBackToTheRawKey(detail: String) async throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = AutomaticFileKeyProvider(secureEnclave: FakeSE(detail: detail), isAvailable: { true })
        let store = ContainerSecretStore(directory: dir, owner: getuid(), keyProvider: keys)
        let id = UUID()
        try await store.put(.payload, id, ownerUID: 501, revision: 1, .text("x"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("filekey.raw").path))
        // a later store instance stays on the raw key even if the SE now works
        let later = ContainerSecretStore(directory: dir, owner: getuid(),
                                         keyProvider: AutomaticFileKeyProvider(secureEnclave: FakeSE(detail: nil), isAvailable: { true }))
        #expect(try await later.get(.payload, id, ownerUID: 501)?.bytesForTest == Array("x".utf8))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("se.key").path))
    }

    /// An existing SE key: -25308 is the pre-login lock (transient, files stay sealed under it); any other error
    /// discards the SE key and switches to the raw key.
    @Test func existingSEKeyKeepsThePreLoginLockButDropsAnUnusableKey() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = SecretFiles(directory: dir, owner: getuid())
        try files.ensureDirectory()
        try files.writeAtomic("se.key", Data([1])); try files.writeAtomic("filekey.wrapped", Data([2]))
        let locked = AutomaticFileKeyProvider(secureEnclave: FakeSE(detail: SecretStoreDetail.lockedBeforeLogin), isAvailable: { true })
        #expect(throws: LPError(.secretStoreUnavailable, detail: SecretStoreDetail.lockedBeforeLogin)) { try locked.fileKey(files) }
        #expect(files.exists("se.key") && !files.exists("filekey.raw"))
        let broken = AutomaticFileKeyProvider(secureEnclave: FakeSE(detail: "se -25300"), isAvailable: { true })
        _ = try broken.fileKey(files)
        #expect(!files.exists("se.key") && !files.exists("filekey.wrapped") && files.exists("filekey.raw"))
    }

    /// Review M1: a transient file-I/O error reading or writing the key files propagates; the SE key survives and no
    /// raw key is created (otherwise every sealed item would become unreadable after one EMFILE).
    @Test(arguments: ["open 24", "open 4", "owner/mode", "short read", "write 28", "rename 28"])
    func fileIOErrorsNeverDiscardTheSEKey(detail: String) throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = SecretFiles(directory: dir, owner: getuid())
        try files.ensureDirectory()
        let flaky = AutomaticFileKeyProvider(secureEnclave: FakeSE(detail: detail), isAvailable: { true })
        #expect(throws: LPError(.secretStoreUnavailable, detail: detail)) { try flaky.fileKey(files) }   // creating
        #expect(!files.exists("filekey.raw"))
        try files.writeAtomic("se.key", Data([1])); try files.writeAtomic("filekey.wrapped", Data([2]))
        #expect(throws: LPError(.secretStoreUnavailable, detail: detail)) { try flaky.fileKey(files) }   // existing
        #expect(files.exists("se.key") && files.exists("filekey.wrapped") && !files.exists("filekey.raw"))
    }

    @Test func malformedWrappedKeyCountsAsUnusableSE() {
        #expect(AutomaticFileKeyProvider.meansNoSecureEnclave(LPError(.secretStoreUnavailable, detail: "filekey format"), hasSEKey: true))
        #expect(!AutomaticFileKeyProvider.meansNoSecureEnclave(LPError(.secretStoreUnavailable), hasSEKey: false))
    }

    @Test func noSEAvailableUsesTheRawKey() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = SecretFiles(directory: dir, owner: getuid())
        try files.ensureDirectory()
        _ = try AutomaticFileKeyProvider(secureEnclave: FakeSE(detail: nil), isAvailable: { false }).fileKey(files)
        #expect(files.exists("filekey.raw") && !files.exists("se.key"))
    }
}
