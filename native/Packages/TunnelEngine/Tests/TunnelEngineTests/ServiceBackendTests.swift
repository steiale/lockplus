import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// The XPC-facing backend: decode caps, uid ownership (§5.4 `.notOwner`), provisioning hooks (§6.4, §7.2 rules).
@Suite struct ServiceBackendTests {
    let h = Harness()
    var backend: EngineServiceBackend<ManualClock> {
        EngineServiceBackend(controller: h.controller, secrets: h.secrets, validator: FakeValidator())
    }
    let alice = PeerContext(uid: 501, pid: 1)
    let mallory = PeerContext(uid: 502, pid: 2)

    func call<T: Encodable>(_ m: LPMethod, _ body: T, as peer: PeerContext) async -> Result<Data?, LPError> {
        await backend.handle(m, request: try! LPWire.encode(body), peer: peer)
    }

    func provision(rev: UInt64 = 1, creds: CredentialRecord? = nil, as peer: PeerContext? = nil) async -> Result<Data?, LPError> {
        await call(.provisionProfile, ProvisionRequest(profileID: h.pid, kind: .openVPN, revision: rev, payload: Data("client\n".utf8),
                                                       credentials: creds), as: peer ?? alice)
    }

    func err(_ r: Result<Data?, LPError>) -> LPErrorCode? { if case .failure(let e) = r { return e.code }; return nil }

    @Test func provisionListAndOwnership() async throws {
        #expect(err(await provision(creds: CredentialRecord(username: Data("a".utf8), password: Data("p".utf8)))) == nil)
        let list = try LPWire.decode(ListProvisionedReply.self, try #require(try await call(.listProvisioned, EmptyRequest(), as: alice).get()), max: 1 << 16)
        #expect(list.entries.map(\.id) == [h.pid] && list.entries[0].revision == 1)
        let other = try LPWire.decode(ListProvisionedReply.self, try #require(try await call(.listProvisioned, EmptyRequest(), as: mallory).get()), max: 1 << 16)
        #expect(other.entries.isEmpty)
        // Another uid's namespace has no such profile: nothing of alice's is reachable, nothing to "own".
        #expect(err(await call(.tunnelSnapshot, ProfileRequest(profileID: h.pid), as: mallory)) == .profileNotProvisioned)
        #expect(err(await call(.statistics, ProfileRequest(profileID: h.pid), as: mallory)) == .profileNotProvisioned)
        #expect(err(await call(.pendingAuthPrompt, ProfileRequest(profileID: h.pid), as: mallory)) == .profileNotProvisioned)
        #expect(err(await call(.prepareStartAuth, PrepareStartAuth(profileID: h.pid, kind: .userPass), as: mallory)) == .profileNotProvisioned)
        #expect(err(await call(.removeProfile, ProfileRequest(profileID: h.pid), as: mallory)) == nil)   // a no-op on alice's
        #expect(await h.secrets.bytes(.payload, h.pid) != nil)
        #expect(err(await provision(rev: 0)) == .profileRevisionStale)
    }

    @Test func credentialLimitsAreEnforced() async {
        let long = Data(repeating: 0x41, count: CredentialRecord.maxUsername + 1)
        #expect(err(await provision(creds: CredentialRecord(username: long))) == .malformedRequest)
        #expect(err(await provision(creds: CredentialRecord(username: Data("a\nb".utf8)))) == .malformedRequest)
    }

    @Test func higherRevisionProvisionAndUpdateCredentialsClearTheLatch() async {
        _ = await provision()
        var st = h.state.load()
        st.latches[h.key] = .init(latch: StartLatch(code: .authFailed, kind: .hard, notBefore: nil, revision: 1), interval: nil)
        h.state.save(st)
        let c2 = Harness(pid: h.pid, state: { _ in st })
        let b2 = EngineServiceBackend(controller: c2.controller, secrets: h.secrets, validator: FakeValidator())
        _ = await b2.handle(.updateCredentials, request: try! LPWire.encode(UpdateCredentialsRequest(profileID: h.pid,
                            credentials: CredentialRecord(password: Data("new".utf8)))), peer: alice)
        #expect(c2.latch == nil)
        let c3 = Harness(pid: h.pid, state: { _ in st })
        let b3 = EngineServiceBackend(controller: c3.controller, secrets: h.secrets, validator: FakeValidator())
        _ = await b3.handle(.provisionProfile, request: try! LPWire.encode(ProvisionRequest(profileID: h.pid, kind: .openVPN, revision: 2,
                            payload: Data("client\n".utf8), credentials: nil)), peer: alice)
        #expect(c3.latch == nil)
    }

    func storedCredentials() async -> CredentialSecrets? {
        await h.secrets.bytes(.credential, h.pid).flatMap { CredentialCodec.decode(SecretBytes(copying: $0)) }
    }

    @Test func provisionStoresProxyCredentials() async {
        #expect(err(await provision(creds: CredentialRecord(username: Data("a".utf8), proxyUsername: Data("pu".utf8),
                                                            proxyPassword: Data("pp".utf8)))) == nil)
        let c = await storedCredentials()
        #expect(c?.proxyUsername?.bytesForTest == Array("pu".utf8) && c?.proxyPassword?.bytesForTest == Array("pp".utf8))
    }

    @Test func updateCredentialsStoresProxyOnlyCredentials() async {
        _ = await provision()
        #expect(err(await call(.updateCredentials, UpdateCredentialsRequest(profileID: h.pid,
                    credentials: CredentialRecord(proxyUsername: Data("pu".utf8), proxyPassword: Data("pp".utf8))), as: alice)) == nil)
        let c = await storedCredentials()
        #expect(c?.proxyUsername?.bytesForTest == Array("pu".utf8) && c?.proxyPassword?.bytesForTest == Array("pp".utf8))
        #expect(c?.username == nil && c?.password == nil)
    }

    @Test func removeAndWipe() async {
        _ = await provision(creds: CredentialRecord(password: Data("p".utf8)))
        #expect(err(await call(.removeProfile, ProfileRequest(profileID: h.pid), as: alice)) == nil)
        #expect(await h.secrets.items.isEmpty)
        _ = await provision()
        #expect(err(await call(.wipeAllSecrets, EmptyRequest(), as: mallory)) == nil)
        #expect(await h.secrets.items.count == 1)                          // another uid wipes only its own
        _ = await call(.wipeAllSecrets, EmptyRequest(), as: alice)
        #expect(await h.secrets.items.isEmpty)
    }

    @Test func authRoundTripOverTheWire() async throws {
        _ = await provision()
        let pr = try LPWire.decode(AuthPrompt.self, try #require(try await call(.prepareStartAuth, PrepareStartAuth(profileID: h.pid, kind: .userPass), as: alice).get()), max: 1 << 14)
        let pending = try LPWire.decode(PendingAuthPromptReply.self, try #require(try await call(.pendingAuthPrompt, ProfileRequest(profileID: h.pid), as: alice).get()), max: 1 << 14)
        #expect(pending.prompt == pr)
        #expect(err(await call(.answerAuth, AuthAnswer(promptID: pr.promptID, username: nil, password: Data("x".utf8), response: nil, save: false), as: mallory)) == .notOwner)
        #expect(err(await call(.answerAuth, AuthAnswer(promptID: UUID(), username: nil, password: nil, response: nil, save: false), as: alice)) == .staleAnswer)
        #expect(err(await call(.answerAuth, AuthAnswer(promptID: pr.promptID, username: nil, password: Data("x".utf8), response: nil, save: false), as: alice)) == nil)
        #expect(err(await call(.cancelAuth, CancelAuthRequest(promptID: pr.promptID), as: alice)) == nil)
        let none = try LPWire.decode(PendingAuthPromptReply.self, try #require(try await call(.pendingAuthPrompt, ProfileRequest(profileID: h.pid), as: alice).get()), max: 1 << 14)
        #expect(none.prompt == nil)
    }

    @Test func snapshotStatisticsLogsSessions() async throws {
        _ = await provision()
        let snap = try LPWire.decode(TunnelSnapshot.self, try #require(try await call(.tunnelSnapshot, ProfileRequest(profileID: h.pid), as: alice).get()), max: 1 << 14)
        #expect(snap.phase == .idle && snap.profileID == h.pid)
        let stats = try LPWire.decode(TunnelStatistics.self, try #require(try await call(.statistics, ProfileRequest(profileID: h.pid), as: alice).get()), max: 1 << 14)
        #expect(stats.rxBytes == 0 && stats.sessionID == nil)
        let sess = try LPWire.decode(SessionSummariesReply.self, try #require(try await call(.sessionSummaries, SessionSummariesRequest(after: nil), as: alice).get()), max: 1 << 16)
        #expect(sess.sessions.isEmpty)
    }

    /// M1: the log methods are gone from the XPC surface (method table, protocol, backend).
    @Test func logMethodsAreNotOnTheWire() {
        #expect(!LPMethod.allCases.map(\.rawValue).contains { $0 == "recentLogs" || $0 == "setLogLevel" })
        #expect(!NSStringFromProtocol(LPTunnelServiceXPC.self).isEmpty)
        let sel = [NSSelectorFromString("recentLogs:reply:"), NSSelectorFromString("setLogLevel:reply:")]
        #expect(sel.allSatisfy { protocol_getMethodDescription(LPTunnelServiceXPC.self, $0, true, true).name == nil })
    }

    /// H1: mallory provisions alice's profile UUID FIRST. Alice can still provision, her start loads HER payload,
    /// mallory's item is untouched and invisible to her, and neither can delete or list the other's.
    @Test func malloryProvisionsAlicesUUIDFirst() async throws {
        #expect(err(await call(.provisionProfile, ProvisionRequest(profileID: h.pid, kind: .openVPN, revision: 5,
                                                                   payload: Data("client\nremote \"evil\"\n".utf8), credentials: nil), as: mallory)) == nil)
        #expect(err(await provision(rev: 1, creds: CredentialRecord(username: Data("alice".utf8), password: Data("pw".utf8)))) == nil)
        #expect(await h.secrets.bytes(.payload, h.pid, ownerUID: 501) == Array("client\n".utf8))
        #expect(await h.secrets.bytes(.payload, h.pid, ownerUID: 502) == Array("client\nremote \"evil\"\n".utf8))
        // Alice's NE configuration (ownerUID 501) starts with her own payload, not mallory's (higher revision) one.
        let t = h.start()
        let a = await h.adapter()
        #expect(a.request?.payload.bytesForTest == Array("client\n".utf8))
        #expect(a.request?.credentials?.username?.bytesForTest == Array("alice".utf8))
        a.finishStart(.failure(.failed(.of(.connectTimeout))))
        _ = await t.value
        // Lists and wipes are per uid.
        let mine = try LPWire.decode(ListProvisionedReply.self, try #require(try await call(.listProvisioned, EmptyRequest(), as: alice).get()), max: 1 << 16)
        #expect(mine.entries.map(\.revision) == [1])
        _ = await call(.wipeAllSecrets, EmptyRequest(), as: mallory)
        #expect(await h.secrets.bytes(.payload, h.pid, ownerUID: 501) != nil)
    }

    /// H1: a start whose NE configuration names a uid without that profile fails `.profileNotProvisioned`, even when
    /// another uid has the UUID provisioned.
    @Test func startNeverUsesAnotherUidsPayload() async {
        _ = await call(.provisionProfile, ProvisionRequest(profileID: h.pid, kind: .openVPN, revision: 1,
                                                           payload: Data("client\n".utf8), credentials: nil), as: mallory)
        let r = await h.start().value                     // config ownerUID = 501 (alice)
        #expect(h.code(r) == .profileNotProvisioned)
        #expect(h.factory.adapters.isEmpty)
    }

    /// T7: an item that can't be read back as what its address says doesn't wedge provisioning: it is overwritten.
    @Test func provisionOverwritesAnUnreadableItem() async throws {
        let be = FakeKeychainBackend()
        let store = SystemKeychainSecretStore(backend: be)
        let b = EngineServiceBackend(controller: h.controller, secrets: store, validator: FakeValidator())
        let req = ProvisionRequest(profileID: h.pid, kind: .openVPN, revision: 1, payload: Data("client\n".utf8), credentials: nil)
        _ = await b.handle(.provisionProfile, request: try LPWire.encode(req), peer: alice)
        let svc = await store.service(.payload)
        let addr = try #require(be.addresses.first { $0.hasPrefix(svc + "|") })
        be.s.withLock { $0.items[addr] = Data("garbage".utf8) }
        await #expect(throws: LPError.self) { try await store.get(.payload, h.pid, ownerUID: 501) }
        var r2 = req; r2.revision = 2
        if case .failure(let e) = await b.handle(.provisionProfile, request: try LPWire.encode(r2), peer: alice) { Issue.record("\(e)") }
        #expect(try await store.get(.payload, h.pid, ownerUID: 501)?.bytesForTest == Array("client\n".utf8))
    }

    /// T15: prepareStartAuth offers the stored username.
    @Test func prepareStartAuthPrefillsTheStoredUsername() async throws {
        _ = await provision(creds: CredentialRecord(username: Data("alice".utf8), password: Data("p".utf8)))
        let p = try LPWire.decode(AuthPrompt.self, try #require(try await call(.prepareStartAuth, PrepareStartAuth(profileID: h.pid, kind: .userPass), as: alice).get()), max: 1 << 14)
        #expect(p.savedUsername == "alice")
    }

    /// M2: a profile that is not the running session gets its own latch/lastError and `.idle`, never the session's
    /// phase detail or endpoint — even for the same UUID in another uid's namespace.
    @Test func snapshotOfAnotherProfileDisclosesNothing() async throws {
        await h.provision()
        _ = await call(.provisionProfile, ProvisionRequest(profileID: h.pid, kind: .openVPN, revision: 1,
                                                           payload: Data("client\n".utf8), credentials: nil), as: mallory)
        let other = UUID()
        _ = await call(.provisionProfile, ProvisionRequest(profileID: other, kind: .openVPN, revision: 1,
                                                           payload: Data("client\n".utf8), credentials: nil), as: alice)
        let a = await h.connect()
        a.s.withLock { $0.stats = AdapterStats(endpoint: "198.51.100.7:1194", localAddresses: ["10.8.0.2"]) }
        _ = await h.controller.statistics()
        let own = try LPWire.decode(TunnelSnapshot.self, try #require(try await call(.tunnelSnapshot, ProfileRequest(profileID: h.pid), as: alice).get()), max: 1 << 14)
        #expect(own.phase == .connected && own.endpoint == "198.51.100.7:1194")
        for (id, peer) in [(h.pid, mallory), (other, alice)] {
            let s = try LPWire.decode(TunnelSnapshot.self, try #require(try await call(.tunnelSnapshot, ProfileRequest(profileID: id), as: peer).get()), max: 1 << 14)
            #expect(s.profileID == id && s.phase == .idle && s.endpoint == nil && s.localAddresses.isEmpty && s.cipher == nil)
            #expect(s.attempt == 0 && s.nextRetryAt == nil && s.holdReason == nil)
            let st = try LPWire.decode(TunnelStatistics.self, try #require(try await call(.statistics, ProfileRequest(profileID: id), as: peer).get()), max: 1 << 14)
            #expect(st.sessionID == nil && st.rxBytes == 0)
        }
    }

    /// L1: wipeAllSecrets clears only the caller's latches; another uid's latch survives.
    @Test func wipeClearsOnlyTheCallersLatches() async {
        var st = PersistedTunnelState()
        let malloryKey = ProfileKey(ownerUID: 502, profileID: UUID())
        st.latches[h.key] = .init(latch: StartLatch(code: .authFailed, kind: .hard, notBefore: nil, revision: 1), interval: nil)
        st.latches[malloryKey] = .init(latch: StartLatch(code: .authFailed, kind: .hard, notBefore: nil, revision: 1), interval: nil)
        let c = Harness(pid: h.pid, state: { _ in st })
        let b = EngineServiceBackend(controller: c.controller, secrets: c.secrets, validator: FakeValidator())
        _ = await b.handle(.wipeAllSecrets, request: try! LPWire.encode(EmptyRequest()), peer: mallory)
        #expect(c.latch != nil)
        #expect(c.state.load().latches[malloryKey] == nil)
    }

    @Test func validateProfileReportsTheEngineCheck() async throws {
        let bad = EngineServiceBackend(controller: h.controller, secrets: h.secrets, validator: FakeValidator(reject: true))
        let r = try LPWire.decode(ValidateProfileReply.self, try #require(try await bad.handle(.validateProfile,
                    request: LPWire.encode(ValidateProfileRequest(kind: .wireGuard, payload: Data("x".utf8))), peer: alice).get()), max: 1 << 14)
        #expect(!r.isValid && r.error?.code == .profileInvalid)
    }

    @Test func oversizedRequestIsNeverDecoded() async {
        let big = Data(count: LPMethod.answerAuth.requestLimit + 1)
        #expect(err(await backend.handle(.answerAuth, request: big, peer: alice)) == .payloadTooLarge)
    }
}
