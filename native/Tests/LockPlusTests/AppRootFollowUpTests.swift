import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// The UI follow-ups wired by the app root: editor backend, password sheets, notYetVerified, reboot readiness and the
/// §4.4 step 7 uninstall choice. Fakes only.
@MainActor @Suite("App root: UI follow-ups", .serialized)
struct AppRootFollowUpTests {
    func settle(_ ms: Int = 80) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    @Test func editorNewWireGuardGetsAFreshKeyAndSaveCreates() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let doc = try await h.env.editorBackend.load(.new(.wireGuard))
        let keyLine = try #require(doc.text.split(separator: "\n").first { $0.hasPrefix("PrivateKey = ") })
        #expect(Data(base64Encoded: String(keyLine.dropFirst("PrivateKey = ".count)))?.count == 32)
        let text = Harness.wgConf
        let id = try await h.env.editorBackend.save(.new(.wireGuard), name: "Edited", text: text, mode: .saveOnly)
        #expect(h.env.profiles.profile(id)?.name == "Edited")
    }

    @Test func editorSaveReplacesThePayloadOfAnExistingProfile() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let doc = try await h.env.editorBackend.load(.existing(p.id))
        let edited = doc.text.replacingOccurrences(of: "PersistentKeepalive = 25", with: "PersistentKeepalive = 30")
        #expect(edited != doc.text)                                     // the edit is real (review: was vacuous)
        let id = try await h.env.editorBackend.save(.existing(p.id), name: p.name, text: edited, mode: .saveOnly)
        #expect(id == p.id)
        let after = try #require(h.env.profiles.profile(p.id))
        #expect(after.payloadRevision == p.payloadRevision + 1)
        let stored = try await h.env.profiles.payload(p.id).withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        #expect(stored.contains("PersistentKeepalive = 30"))
        #expect(after.payloadDigest != p.payloadDigest)
        #expect(after.policy == p.policy)
        await #expect(throws: AppEditorBackend.SaveError.self) {
            _ = try await h.env.editorBackend.save(.existing(p.id), name: p.name, text: "[Interface]\nPrivateKey = nope\n", mode: .saveOnly)
        }
    }

    @Test func editConfigPassesTheRevealGate() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.hooks.authenticateResult = false
        h.env.ui.actions.editConfig(p.id)
        try await settle()
        #expect(h.hooks.calls.contains("authenticate"))
    }

    @Test func passwordChangeAndReveal() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Office.ovpn", PreviewSeed.officeOvpn)
        h.env.ui.actions.changePassword(p.id)
        let req = try #require(h.env.ui.profiles.passwordChange)
        req.onSave("alex", "s3cret", true)
        try await settle()
        #expect(await h.env.profiles.credentialRecord(p.id)?.password == Data("s3cret".utf8))
        h.env.ui.actions.showPassword(p.id)
        try await settle()
        #expect(h.env.ui.profiles.passwordReveal?.password == "s3cret")
        req.onSave("alex", "other", false)                              // not saved: the password is removed
        try await settle()
        #expect(await h.env.profiles.credentialRecord(p.id)?.password == nil)
        #expect(await h.env.profiles.credentialRecord(p.id)?.username == Data("alex".utf8))
    }

    @Test func notYetVerifiedAndRebootReadiness() async throws {
        let h = Harness(validator: FakeProfileValidator(.fails(LPError(.extensionUnavailable))))   // the validator service is down
        defer { h.dir.cleanup() }
        let p = try await h.add("Office.ovpn", PreviewSeed.officeOvpn)
        let item = UIMapping.item(p, credentials: nil, autoProfileID: nil, snapshot: nil, history: [])
        #expect(item.notYetVerified)
        #expect(ExtensionMapping.readiness(.needsReboot, endedWithoutResult: false) == .rebootRequired)
    }

    @Test func uninstallHonoursTheDeleteChoice() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        try await h.add("Work.conf", Harness.wgConf)
        #expect(FileManager.default.fileExists(atPath: h.dir.data.profiles.path))
        h.env.ui.actions.uninstall(deletingProfilesAndHistory: true)
        #expect(await eventually { h.hooks.calls.contains("finishUninstall") && !FileManager.default.fileExists(atPath: h.dir.data.root.path) })
        #expect(h.hooks.calls.contains("finishUninstall"))
        #expect(!FileManager.default.fileExists(atPath: h.dir.data.root.path))
    }
}
