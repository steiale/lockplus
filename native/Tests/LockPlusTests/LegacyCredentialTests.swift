import Foundation
import LPModel
import LPParsing
import LPWire
import Testing
@testable import LockPlus

/// §6.7 legacy keychain credential migration, FIXTURES ONLY: an in-memory Go directory and an in-memory legacy
/// keychain. Never the owner's keychain or the Go app's real data.
@MainActor @Suite("Legacy credential migration (§6.7)", .serialized)
struct LegacyCredentialTests {
    struct GoOVPNFixture: GoAppDataSource {
        var sourceDescription: String { "test fixture" }
        func tunnelEntries() throws -> [GoAppEntry] {
            ["vpn-a.ovpn", "vpn-b.ovpn", "vpn-c.ovpn", "lab.conf"].map { GoAppEntry(name: $0, kind: .regular) }
        }
        func readTunnelFile(_ name: String, maxBytes: Int) throws -> [UInt8] {
            name.hasSuffix(".conf") ? Array(PreviewSeed.nasConf.utf8)
                : Array(PreviewSeed.officeOvpn.replacingOccurrences(of: "remote ", with: "remote \(name.prefix(5)).").utf8)
        }
        func readDataFile(_ name: String, maxBytes: Int) throws -> [UInt8]? { nil }
    }

    static let current = LegacyKeychain.serviceNames[0], older = LegacyKeychain.serviceNames[1]

    static func keychain() -> FixtureLegacyKeychain {
        let a = LegacyKeychainItem(service: current, account: "vpn-a")
        let b = LegacyKeychainItem(service: older, account: "vpn-b")
        let c = LegacyKeychainItem(service: current, account: "vpn-c")
        let unrelated = LegacyKeychainItem(service: current, account: "gone-profile")
        var k = FixtureLegacyKeychain(listing: LegacyKeychainListing(items: [a, b, c, unrelated], systemKeychainItems: 1))
        k.values[a] = .success(Array(("b64:" + Data("alice\npw-a".utf8).base64EncodedString()).utf8))
        k.values[b] = .success(Array("626f620a70772d62".utf8))           // hex of "bob\npw-b" (pre-1.0.50)
        k.values[c] = .failure(.denied)
        return k
    }

    @Test func theOfferCountsMatchingItemsWithoutReadingData() async throws {
        let h = Harness(goSource: { GoOVPNFixture() }, legacyKeychain: Self.keychain())
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        #expect(offer.savedPasswords == 3)                                // vpn-a, vpn-b, vpn-c; not "gone-profile"
    }

    @Test func optInImportsDecodesAndReportsDenials() async throws {
        let h = Harness(goSource: { GoOVPNFixture() }, legacyKeychain: Self.keychain())
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        let report = await h.env.migrator.run(selected: Set(offer.profileNames), includeSavedPasswords: true)
        func rec(_ name: String) async -> CredentialRecord? {
            guard let p = h.env.profiles.profiles.first(where: { $0.name == name }) else { return nil }
            return await h.env.profiles.credentialRecord(p.id)
        }
        #expect(await rec("vpn-a")?.username == Data("alice".utf8))
        #expect(await rec("vpn-a")?.password == Data("pw-a".utf8))
        #expect(await rec("vpn-b")?.password == Data("pw-b".utf8))      // older service name, hex format
        #expect(await rec("vpn-c")?.password == nil)                     // denied
        #expect(report.needsAttention.contains { $0.contains("vpn-c") && $0.contains("denied") })
        #expect(report.notMigrated.contains { $0.contains("older version") })   // the System keychain item
        #expect(report.notMigrated.contains { $0.hasPrefix("1 saved password ") })   // inflected, no raw markup
        #expect(!report.notMigrated.contains { $0.contains("^[") || $0.contains("inflect") })
        #expect(h.service.calls(.updateCredentials) == 2)                // handed to the extension (§6.4)
    }

    @Test func withoutOptInNothingIsRead() async throws {
        let h = Harness(goSource: { GoOVPNFixture() }, legacyKeychain: Self.keychain())
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        _ = await h.env.migrator.run(selected: Set(offer.profileNames))
        for p in h.env.profiles.profiles { #expect(await h.env.profiles.credentialRecord(p.id)?.password == nil) }
        #expect(h.service.calls(.updateCredentials) == 0)
    }
}
