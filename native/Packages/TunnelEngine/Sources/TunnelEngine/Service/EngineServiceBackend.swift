import Foundation
import LPModel
import LPWire

/// The engine's `TunnelServiceBackend` (P2a's XPC seam): decodes with the method's cap and serves `peer.uid`'s
/// namespace only (review H1): every store call and every controller query is addressed by (peer.uid, profileID), so
/// another uid's profile with the same UUID is simply not there (`.profileNotProvisioned`). `.notOwner` remains for
/// auth prompts, whose promptIDs are global.
/// `measureLatency` answers `.extensionBusy`: S2 E5 showed a provider-originated connection works but leaves en0
/// OUTSIDE the tunnel, so the extension opens no connection besides the engines' own transport (§10.1.1 E5).
/// Logs are not on the XPC surface (review M1): see `DiagnosticsHook`.
public struct EngineServiceBackend<C: Clock>: TunnelServiceBackend where C.Duration == Duration {
    public let controller: TunnelController<C>
    public let secrets: any ExtensionSecretStore
    public let validator: (any PayloadValidator)?
    public let capabilities: Set<Capability>

    public init(controller: TunnelController<C>, secrets: any ExtensionSecretStore, validator: (any PayloadValidator)?,
                capabilities: Set<Capability> = [.openVPN, .wireGuard, .keyPassphrase]) {
        self.controller = controller; self.secrets = secrets; self.validator = validator; self.capabilities = capabilities
    }

    public func handle(_ method: LPMethod, request: Data, peer: PeerContext) async -> Result<Data?, LPError> {
        do throws(LPError) {
            switch method {
            case .provisionProfile:
                try await provision(try LPWire.decode(ProvisionRequest.self, request, max: method.requestLimit), peer)
                return .success(nil)
            case .removeProfile:
                let r = try LPWire.decode(ProfileRequest.self, request, max: method.requestLimit)
                try await secrets.delete(.payload, r.profileID, ownerUID: peer.uid)
                try await secrets.delete(.credential, r.profileID, ownerUID: peer.uid)
                await controller.profileRemoved(r.profileID, ownerUID: peer.uid)
                return .success(nil)
            case .wipeAllSecrets:
                try await secrets.deleteAll(ownerUID: peer.uid)
                await controller.secretsWiped(ownerUID: peer.uid)
                return .success(nil)
            case .updateCredentials:
                let r = try LPWire.decode(UpdateCredentialsRequest.self, request, max: method.requestLimit)
                guard r.credentials.isWithinLimits else { throw LPError(.malformedRequest, detail: "credentials") }
                let rev = try await requireProvisioned(r.profileID, peer)
                let c = CredentialSecrets(username: SecretBytes.fromData(r.credentials.username),
                                          password: SecretBytes.fromData(r.credentials.password),
                                          keyPassphrase: SecretBytes.fromData(r.credentials.keyPassphrase),
                                          proxyUsername: SecretBytes.fromData(r.credentials.proxyUsername),
                                          proxyPassword: SecretBytes.fromData(r.credentials.proxyPassword))
                if c.username == nil && c.password == nil && c.keyPassphrase == nil && c.proxyUsername == nil && c.proxyPassword == nil {
                    try await secrets.delete(.credential, r.profileID, ownerUID: peer.uid)          // "Forget password" (§6.6)
                } else {
                    try await secrets.put(.credential, r.profileID, ownerUID: peer.uid, revision: rev, CredentialCodec.encode(c))
                }
                await controller.credentialsUpdated(r.profileID, ownerUID: peer.uid)
                return .success(nil)
            case .listProvisioned:
                let idx = try await secrets.index(ownerUID: peer.uid)
                let entries = idx.filter { $0.kind == .payload && $0.ownerUID == peer.uid }.prefix(ListProvisionedReply.maxEntries)
                    .map { ProvisionedEntry(id: $0.id, revision: $0.revision, digest: $0.digest ?? "") }   // "" → reconcile re-provisions
                return .success(try LPWire.encode(ListProvisionedReply(entries: Array(entries))))
            case .validateProfile:
                // The full §8.1 [7a] verdict comes from the validator itself (review simplification 5: no router).
                let r = try LPWire.decode(ValidateProfileRequest.self, request, max: method.requestLimit)
                let payload = SecretBytes(copying: r.payload)
                let reply = validator?.evaluate(kind: r.kind, payload: payload, disableClientCert: r.kind == .openVPN ? r.disableClientCert : nil)
                    ?? ValidateProfileReply(error: nil)
                return .success(try LPWire.encode(reply))
            case .cancelAuth:
                let r = try LPWire.decode(CancelAuthRequest.self, request, max: method.requestLimit)
                try await controller.cancelAuth(promptID: r.promptID, callerUID: peer.uid)
                return .success(nil)
            case .statistics:
                let r = try LPWire.decode(ProfileRequest.self, request, max: method.requestLimit)
                try await requireProvisioned(r.profileID, peer)
                return .success(try LPWire.encode(await controller.statisticsReport(profileID: r.profileID, ownerUID: peer.uid)))
            case .sessionSummaries:
                let r = try LPWire.decode(SessionSummariesRequest.self, request, max: method.requestLimit)
                return .success(try LPWire.encode(SessionSummariesReply(sessions: await controller.sessionSummaries(ownerUID: peer.uid, after: r.after))))
            case .tunnelSnapshot:
                let r = try LPWire.decode(ProfileRequest.self, request, max: method.requestLimit)
                try await requireProvisioned(r.profileID, peer)
                return .success(try LPWire.encode(await controller.snapshot(profileID: r.profileID, ownerUID: peer.uid)))
            case .pendingAuthPrompt:
                let r = try LPWire.decode(ProfileRequest.self, request, max: method.requestLimit)
                try await requireProvisioned(r.profileID, peer)
                return .success(try LPWire.encode(PendingAuthPromptReply(prompt: await controller.pendingAuthPrompt(profileID: r.profileID,
                                                                                                                      ownerUID: peer.uid))))
            case .prepareStartAuth:
                let r = try LPWire.decode(PrepareStartAuth.self, request, max: method.requestLimit)
                try await requireProvisioned(r.profileID, peer)
                guard [.userPass, .staticChallenge, .keyPassphrase].contains(r.kind) else { throw LPError(.malformedRequest) }
                // T15: prefill the stored username (userPass/staticChallenge prompts only).
                var saved: String?
                if r.kind != .keyPassphrase, let c = try? await secrets.get(.credential, r.profileID, ownerUID: peer.uid),
                   let u = CredentialCodec.decode(c)?.username {
                    saved = u.withUnsafeBytes { String(validating: $0, as: UTF8.self) }
                }
                return .success(try LPWire.encode(await controller.prepareStartAuth(profileID: r.profileID, ownerUID: peer.uid, kind: r.kind,
                                                                                     savedUsername: saved)))
            case .answerAuth:
                let a = try LPWire.decode(AuthAnswer.self, request, max: method.requestLimit)
                let rec = CredentialRecord(username: a.username, password: a.password)
                guard rec.isWithinLimits, (a.response?.count ?? 0) <= CredentialRecord.maxSecret else { throw LPError(.malformedRequest) }
                let s = AuthAnswerSecrets(username: SecretBytes.fromData(a.username), password: SecretBytes.fromData(a.password),
                                          response: SecretBytes.fromData(a.response), save: a.save)
                try await controller.answerAuth(promptID: a.promptID, answer: s, callerUID: peer.uid)
                return .success(nil)
            case .pushEndpoints:
                // PF 50: only into the caller's own held start (uid namespace + the session's key), literals only
                // (`PushEndpointsRequest.isWireValid` already rejected anything else at decode).
                let r = try LPWire.decode(PushEndpointsRequest.self, request, max: method.requestLimit)
                try await requireProvisioned(r.profileID, peer)
                let outcome = await controller.pushEndpoints(profileID: r.profileID, ownerUID: peer.uid, endpoints: r.endpoints)
                return .success(try LPWire.encode(PushEndpointsReply(outcome: outcome)))
            case .hello, .measureLatency:
                return .failure(LPError(.extensionBusy, detail: "\(method.rawValue) not available in this build"))
            }
        } catch {
            return .failure(error)
        }
    }

    /// §6.4 provision into `peer.uid`'s namespace: revision rule, re-validation, store payload and credentials.
    private func provision(_ r: ProvisionRequest, _ peer: PeerContext) async throws(LPError) {
        var higher = true
        // T7: an item that can't be read back (corrupt, or not matching its address) is treated as absent and
        // overwritten, so provisioning never wedges on it. Any other store error (locked before login, …) propagates.
        let existing: ProvisionIndexEntry?
        do throws(LPError) { existing = try await secrets.entry(.payload, r.profileID, ownerUID: peer.uid) } catch {
            guard error.detail == SecretStoreDetail.unreadableItem else { throw error }
            existing = nil
        }
        if let e = existing {
            guard r.revision >= e.revision else { throw LPError(.profileRevisionStale) }
            higher = r.revision > e.revision
        }
        if let c = r.credentials, !c.isWithinLimits { throw LPError(.malformedRequest, detail: "credentials") }
        let payload = SecretBytes(copying: r.payload)
        do throws(LPTunnelError) { try validator?.validate(kind: r.kind, payload: payload) } catch {
            throw LPError(.profileInvalid, detail: error.detail)
        }
        try await secrets.put(.payload, r.profileID, ownerUID: peer.uid, revision: r.revision, payload)
        if let c = r.credentials {
            let secrets = CredentialSecrets(username: SecretBytes.fromData(c.username), password: SecretBytes.fromData(c.password),
                                            keyPassphrase: SecretBytes.fromData(c.keyPassphrase),
                                            proxyUsername: SecretBytes.fromData(c.proxyUsername), proxyPassword: SecretBytes.fromData(c.proxyPassword))
            try await self.secrets.put(.credential, r.profileID, ownerUID: peer.uid, revision: r.revision, CredentialCodec.encode(secrets))
        }
        // Profile change FIRST: a higher revision ends a waiting start of the old configuration; only then may new
        // credentials retry a hold (which, after a profile change, is gone). Review L2.
        if higher { await controller.profileProvisioned(r.profileID, ownerUID: peer.uid, revision: r.revision) }
        if r.credentials != nil { await controller.credentialsUpdated(r.profileID, ownerUID: peer.uid) }
    }

    /// The payload revision of `peer.uid`'s profile; `.profileNotProvisioned` when that uid has none.
    @discardableResult
    private func requireProvisioned(_ id: UUID, _ peer: PeerContext) async throws(LPError) -> UInt64 {
        guard let e = try await secrets.entry(.payload, id, ownerUID: peer.uid), e.ownerUID == peer.uid else {
            throw LPError(.profileNotProvisioned)
        }
        return e.revision
    }
}

/// Review M1: engine log lines (openvpn3/wireguard-go, already redacted) are no longer served over XPC — any uid could
/// read another's lines there. They stay in the extension's `LogRing` until the diagnostics bundle exports them.
/// TODO(M1, design fold-in §14.1): deliver `LogRing` lines (tagged with the session's ownerUID) only into the OWNER's
/// diagnostics bundle; the log level becomes a build/defaults setting, not an XPC call.
public enum DiagnosticsHook {
    /// The ring's lines for the owner's diagnostics bundle. Not wired to any transport yet (see TODO above).
    public static func ownerDiagnosticsLines(max: Int = 1000) -> [String] { LogRing.shared.lines(since: 0, max: max).lines }

    /// NEW-5: the extension's secret store was reset (unusable/missing account key, or no uid had any entry under it):
    /// `unmatchedItems` unaddressable items were deleted; reconcile re-provisions from each app.
    /// TODO(M1, §14.1): surface this in the diagnostics bundle (not per owner: the items' owners are unknowable). Stub:
    /// the store has already logged it at `.fault`; nothing is delivered yet.
    public static func secretStoreReset(unmatchedItems: Int, reason: String) {}
}

/// Controller events → `TunnelEvent`s through P2a's `ConnectionRegistry` (uid-filtered, §5.2).
public struct RegistryEventSink: TunnelEventSink {
    public let registry: ConnectionRegistry
    public init(registry: ConnectionRegistry) { self.registry = registry }
    public func authRequired(_ prompt: AuthPrompt, ownerUID: uid_t) {
        registry.publish(TunnelEvent(kind: .authRequired, profileID: prompt.profileID, prompt: prompt), ownerUID: ownerUID)
    }
    public func sessionEnded(profileID: UUID, error: LPError, ownerUID: uid_t) {
        registry.publish(TunnelEvent(kind: .sessionEnded, profileID: profileID), ownerUID: ownerUID)
    }
    public func snapshotChanged(_ snapshot: TunnelSnapshot, ownerUID: uid_t?) {
        registry.publish(TunnelEvent(kind: .snapshotChanged, profileID: snapshot.profileID, snapshot: snapshot), ownerUID: ownerUID)
    }
    public func promptResolved(promptID: UUID, profileID: UUID, ownerUID: uid_t) {
        registry.publish(TunnelEvent(kind: .promptResolved, profileID: profileID, promptID: promptID), ownerUID: ownerUID)
    }
}
