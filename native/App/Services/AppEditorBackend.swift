import CryptoKit
import Foundation
import LPModel
import LPParsing
import os

/// The editor's app side (DESIGN §11.4, §8.1; `ProfileEditorBackend` in App/UI/Editor). Load decrypts the sealed
/// payload (the caller already passed RevealGate for an existing profile); Save re-runs the import pipeline on the
/// edited text, so the editor can never store what an import would reject.
@MainActor final class AppEditorBackend: ProfileEditorBackend {
    struct SaveError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private weak var env: AppEnvironment?
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "profiles")

    init(env: AppEnvironment) { self.env = env }

    func load(_ target: EditorTarget) async throws -> EditorDocument {
        guard let env else { throw SaveError(message: String(localized: "LockPlus is quitting.", comment: "Editor error: the app is quitting (pre-release review)")) }
        if let id = target.profileID {
            guard let p = env.profiles.profile(id) else { throw SaveError(message: String(localized: "This profile no longer exists.", comment: "Editor error")) }
            let payload = try await env.profiles.payload(id)
            return EditorDocument(name: p.name, kind: p.kind, text: payload.withUnsafeBytes { String(decoding: $0, as: UTF8.self) })
        }
        let kind = target.newKind ?? .wireGuard
        var text = EditorTemplates.text(for: kind)
        if kind == .wireGuard {
            // A fresh X25519 private key (wireguard-go clamps it); it exists only in this window until Save.
            let key = Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString()
            text = text.replacingOccurrences(of: "PrivateKey =\n", with: "PrivateKey = \(key)\n")
        }
        let name = kind == .wireGuard ? String(localized: "New WireGuard Profile", comment: "Editor default name")
                                      : String(localized: "New OpenVPN Profile", comment: "Editor default name")
        return EditorDocument(name: name, kind: kind, text: text)
    }

    func save(_ target: EditorTarget, name: String, text: String, mode: EditorSaveMode) async throws -> UUID {
        guard let env else { throw SaveError(message: String(localized: "LockPlus is quitting.", comment: "Editor error: the app is quitting (pre-release review)")) }
        let existing = target.profileID.flatMap { env.profiles.profile($0) }
        let kind = existing?.kind ?? target.newKind ?? .wireGuard
        let fileName = name + (kind == .wireGuard ? ".conf" : ".ovpn")
        let a = await ImportCoordinator.analyse(fileName: fileName, bytes: Array(text.utf8), service: env.service, probe: NoRouteProbe())
        guard a.kind == kind else { throw SaveError(message: String(localized: "The text is not a \(kind == .wireGuard ? "WireGuard" : "OpenVPN") configuration.", comment: "Editor error")) }
        let policy = existing?.policy ?? env.settings.value.newProfileDefaults
        guard var draft = env.importer.draft(a, name: name, killSwitch: existing?.policy.killSwitch ?? a.summary.isFullTunnel,
                                             allowLAN: policy.allowLAN) else {
            throw SaveError(message: Self.rejection(a.report))
        }
        if let existing {
            draft.policy = existing.policy
            draft.notes = existing.notes
            do throws(LPError) {
                let p = try await env.profiles.replacePayload(existing.id, with: draft)
                if let c = draft.credentials { try? await env.profiles.saveCredentials(p.id, c) }
                if mode == .saveAndReconnect, env.connection.statuses[p.id]?.isActive == true { await reconnect(p.id, env) }
                return p.id
            } catch {
                throw SaveError(message: error.code.message(detail: error.detail))
            }
        }
        draft.origin = .file(fileName)
        do throws(LPError) {
            let p = try await env.profiles.create(draft)
            env.ui.profiles.selection = p.id
            return p.id
        } catch {
            throw SaveError(message: error.code.message(detail: error.detail))
        }
    }

    var openVPNValidator: (any OpenVPN3ProfileValidating)? {
        guard let env, case .ready = env.extensionStore.state else { return nil }
        return XPCProfileValidator(service: env.service)
    }

    /// "Save and Reconnect": stop, wait for `.disconnected` (≤ 10 s), start again.
    private func reconnect(_ id: UUID, _ env: AppEnvironment) async {
        env.connection.disconnect()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, env.managers.status(id) != .disconnected, env.managers.status(id) != .invalid {
            try? await Task.sleep(for: .milliseconds(200))
        }
        env.ui.actions.connect(id)
        await env.connection.restoreOnDemand([id])  // our own stop isn't a user pause of auto-connect (H2)
    }

    static func rejection(_ r: ImportReport) -> String {
        if let i = r.items.first(where: { $0.group == .notSupported }) {
            let line = i.line.map { String(localized: "line \($0): ", comment: "Editor error prefix") } ?? ""
            return String(localized: "This configuration can't be saved (\(line)\(i.directive ?? "")).", comment: "Editor error")
        }
        return String(localized: "This configuration can't be saved. Check the highlighted lines.", comment: "Editor error")
    }
}
