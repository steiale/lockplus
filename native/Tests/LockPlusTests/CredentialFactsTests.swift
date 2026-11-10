import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// Fable L3 and review L10: facts come from a non-secret file; a failed keychain read never overwrites credentials.
@MainActor @Suite("Credential facts (FA-L3, AR-L10)", .serialized)
struct CredentialFactsTests {
    @Test func loadReadsTheFactsFileNotTheSecrets() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Office.ovpn", PreviewSeed.officeOvpn)
        try await h.env.profiles.saveCredentials(p.id, CredentialRecord(username: Data("alex".utf8), password: Data("pw".utf8)))
        #expect(FileManager.default.fileExists(atPath: h.dir.data.credentialFacts.path))
        let text = try String(contentsOf: h.dir.data.credentialFacts, encoding: .utf8)
        #expect(text.contains("alex") && !text.contains("\"pw\""))
        h.keychain.failure.withLock { $0 = errSecInteractionNotAllowed }  // the keychain is unreadable now
        await h.env.profiles.load()
        #expect(h.env.profiles.credentials[p.id] == CredentialFacts(username: "alex", passwordSaved: true, passphraseSaved: false))
        h.keychain.failure.withLock { $0 = nil }
    }

    @Test func aFailedReadDoesNotWipeOtherCredentials() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Office.ovpn", PreviewSeed.officeOvpn)
        try await h.env.profiles.saveCredentials(p.id, CredentialRecord(username: Data("alex".utf8), password: Data("pw".utf8),
                                                                       keyPassphrase: Data("kp".utf8), proxyPassword: Data("px".utf8)))
        h.keychain.failure.withLock { $0 = errSecInteractionNotAllowed }
        await h.env.profiles.forgetPassword(p.id)
        h.keychain.failure.withLock { $0 = nil }
        let rec = try #require(await h.env.profiles.credentialRecord(p.id))
        #expect(rec.keyPassphrase == Data("kp".utf8) && rec.proxyPassword == Data("px".utf8) && rec.password == Data("pw".utf8))
        #expect(h.env.profiles.problems.contains { $0.message.contains("not forgotten") })
    }
}
