import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// 2.0.2 review round 6 (Codex r6 #1, #2 = Fable r6 N1; Fable r6 L2, N2): answers, saves and commits against the
/// payload revision, extension side.
@Suite(.timeLimit(.minutes(1))) struct Round6ControllerTests {
    static let revision2 = Round3ControllerTests.revision2
    static func credential(_ h: Harness) async -> (username: [UInt8]?, password: [UInt8]?, revision: UInt64?) {
        let c = (try? await h.secrets.get(.credential, h.pid, ownerUID: h.owner))?.flatMap(CredentialCodec.decode)
        let rev = await h.secrets.items["\(h.owner)/\(SecretKind.credential.rawValue)/\(h.pid.uuidString)"]?.revision
        return (c?.username?.bytesForTest, c?.password?.bytesForTest, rev)
    }

    func answer(_ h: Harness, _ p: AuthPrompt, _ a: AuthAnswerSecrets) -> Task<LPError?, Never> {
        let c = h.controller, owner = h.owner
        return Task {
            do throws(LPError) { try await c.answerAuth(promptID: p.promptID, answer: a, callerUID: owner); return nil } catch { return error }
        }
    }

    // MARK: Codex r6 #1: a stashed answer belongs to its prompt's revision

    /// Revision 1's server prompts (CRV1); revision 2's payload is stored but its commit has not run yet; the answer is
    /// stashed and the retry loads revision 2 (its credential read held); the commit of revision 2 arrives (2 is not
    /// above the loaded 2). Revision 1's answer (response, cookie, carried credentials) never reaches revision 2's attempt.
    /// Kills: dropping the `answerRevision` comparison at the hand-over to the attempt.
    @Test func anAnswerOfRevisionOneIsNeverUsedByAnAttemptThatLoadedRevisionTwo() async throws {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        await h.adapter().finishStart(.failure(.auth(.crv1())))
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let p = try #require(h.sink.prompts.first)
        await h.provision(revision: 2, payload: Self.revision2)                 // stored; the commit comes later
        await h.secrets.holdCredentialReads(true)
        #expect(await answer(h, p, AuthAnswerSecrets(response: .text("1"))).value == nil)
        #expect(await waitUntil { await h.secrets.heldReadCount == 1 })       // the retry loaded revision 2
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        await h.secrets.holdCredentialReads(false)
        let b = await h.adapter(1)
        #expect(b.request?.payload.bytesForTest == Array(Self.revision2.utf8))
        #expect(b.request?.stash == nil)
        #expect(h.factory.adapters.count == 2)
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        #expect(h.code(await t.value) == nil)
    }

    /// The control: an answer to a prompt of the revision the retry loads is still used.
    @Test func anAnswerOfTheLoadedRevisionIsUsed() async throws {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        await h.adapter().finishStart(.failure(.auth(.crv1())))
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let p = try #require(h.sink.prompts.first)
        #expect(await answer(h, p, AuthAnswerSecrets(response: .text("1"))).value == nil)
        let b = await h.adapter(1)
        #expect(b.request?.stash != nil)
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        #expect(h.code(await t.value) == nil)
    }

    // MARK: Codex r6 #2 = Fable r6 N1: the save's revision check and its write are one store operation

    /// A before-Connected answer with Save has read revision 1's state and is about to write; revision 2 is provisioned
    /// (payload and credentials) right then; the write runs: revision 2's credentials survive.
    /// Kills: an unconditional `secrets.put` in `saveAnswer`, and a store `putCredential` that ignores the revision.
    @Test func aProvisionBetweenTheSavesLastReadAndItsWriteKeepsItsCredentials() async throws {
        let h = Harness(killSwitch: true)
        await h.provision()
        _ = h.start()
        await h.adapter().finishStart(.failure(.auth(.crv1())))
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let p = try #require(h.sink.prompts.first)
        await h.secrets.holdNextCredentialWrite()
        let pending = answer(h, p, AuthAnswerSecrets(username: .text("mallory"), password: .text("old"), response: .text("1"), save: true))
        #expect(await waitUntil { await h.secrets.credentialWriteHeld })
        await h.provision(revision: 2, password: "new", payload: Self.revision2)
        await h.secrets.releaseCredentialWrite()
        _ = await pending.value
        let c = await Self.credential(h)
        #expect(c.username == Array("alice".utf8) && c.password == Array("new".utf8) && c.revision == 2)
    }

    /// The control: with nothing provisioned meanwhile, the save writes (bound to the prompt's revision).
    @Test func aSaveOfTheCurrentRevisionIsWritten() async throws {
        let h = Harness(killSwitch: true)
        await h.provision()
        _ = h.start()
        await h.adapter().finishStart(.failure(.auth(.crv1())))
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let p = try #require(h.sink.prompts.first)
        #expect(await answer(h, p, AuthAnswerSecrets(username: .text("bob"), password: .text("pw2"), response: .text("1"), save: true)).value == nil)
        let c = await Self.credential(h)
        #expect(c.username == Array("bob".utf8) && c.password == Array("pw2".utf8) && c.revision == 1)
    }

    /// Both real stores: the conditional write checks the stored payload revision; `load` returns the bytes with their
    /// own revision. Kills: a `putCredential` that writes without the check (either store).
    @Test func bothStoresWriteACredentialOnlyAtThePayloadsRevision() async throws {
        let dir = ContainerSecretStoreTests.root.appendingPathComponent("r6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ContainerSecretStoreTests.root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stores: [any ExtensionSecretStore] = [
            SystemKeychainSecretStore(backend: FakeKeychainBackend(), servicePrefix: SystemKeychainSecretStore.devPrefix),
            ContainerSecretStore(directory: dir, owner: getuid(), keyProvider: RawFileKeyProvider()),
        ]
        for store in stores {
            let id = UUID()
            #expect(try await store.putCredential(id, ownerUID: 501, ifPayloadRevision: 1, .text("x")) == false)   // no payload
            try await store.put(.payload, id, ownerUID: 501, revision: 2, .text("p2"))
            try await store.put(.credential, id, ownerUID: 501, revision: 2, .text("c2"))
            #expect(try await store.putCredential(id, ownerUID: 501, ifPayloadRevision: 1, .text("c1")) == false)
            #expect(try await store.get(.credential, id, ownerUID: 501)?.bytesForTest == Array("c2".utf8))
            #expect(try await store.putCredential(id, ownerUID: 502, ifPayloadRevision: 2, .text("other")) == false)   // other uid
            #expect(try await store.putCredential(id, ownerUID: 501, ifPayloadRevision: 2, .text("c2b")) == true)
            #expect(try await store.get(.credential, id, ownerUID: 501)?.bytesForTest == Array("c2b".utf8))
            #expect(try await store.entry(.credential, id, ownerUID: 501)?.revision == 2)
            let l = try #require(try await store.load(.payload, id, ownerUID: 501))
            #expect(l.entry.revision == 2 && l.bytes.bytesForTest == Array("p2".utf8) && l.entry.id == id && l.entry.ownerUID == 501)
            #expect(try await store.load(.payload, id, ownerUID: 502) == nil)
        }
    }

    // MARK: Fable r6 L2: a start without a kill switch still ends on a same-revision commit

    /// Fable's probe: NE configuration revision 1; payload revision 2 is stored (its credential write failed, so the
    /// stored credentials are revision 1's); a start without a kill switch loads payload 2; the app's retry commits
    /// revision 2 again: the start ends (it would send the old credentials to the new revision's server).
    /// Kills: comparing a start without a kill switch with `loadedRevision` (8d233e25's comparison for every start).
    @Test func aSameRevisionRetryEndsASplitStartThatLoadedTheNewPayload() async {
        let h = Harness()
        await h.provision()
        try? await h.secrets.put(.payload, h.pid, ownerUID: h.owner, revision: 2, .text(Self.revision2))
        let t = h.start()
        let a = await h.adapter()
        #expect(a.request?.payload.bytesForTest == Array(Self.revision2.utf8))
        #expect(await h.phase == .connecting)
        await h.controller.payloadCommitted(h.pid, ownerUID: h.owner, revision: 2)
        guard await h.waitPhase(.idle) else { Issue.record("the start went on"); return }
        #expect(h.code(await t.value) == .startCancelled)
    }

    // MARK: Fable r6 N2: the answerInFlight checks and the first revision check of the save

    /// M1: an answer with Save to revision 1's CRV1 prompt is being written when revision 2 commits; the fresh attempt
    /// loads revision 2 and its server prompts again (same phase, same session) before the write returns. The old answer
    /// is stale and the new prompt stays live. Kills: dropping `answerInFlight == promptID` in the restart-engine path.
    @Test func anAnswerFinishingAfterTheFreshAttemptPromptedAgainIsStale() async throws {
        let h = Harness(killSwitch: true)
        await h.provision()
        _ = h.start()
        await h.adapter().finishStart(.failure(.auth(.crv1())))
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let p1 = try #require(h.sink.prompts.first)
        await h.secrets.holdNextCredentialWrite()
        let pending = answer(h, p1, AuthAnswerSecrets(username: .text("alice"), password: .text("pw"), response: .text("1"), save: true))
        #expect(await waitUntil { await h.secrets.credentialWriteHeld })
        await h.provision(revision: 2, payload: Self.revision2)
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        await h.adapter(1).finishStart(.failure(.auth(.crv1("CRV1:R,E:bmV3:YWxpY2U=:Enter code"))))
        #expect(await waitUntil { h.sink.prompts.count == 2 })
        #expect(await h.phase == .awaitingAuth(beforeConnected: true))
        let p2 = h.sink.prompts[1]
        await h.secrets.releaseCredentialWrite()
        #expect(await pending.value?.code == .staleAnswer)
        #expect(!h.sink.resolved.contains(p2.promptID))
        #expect(await h.phase == .awaitingAuth(beforeConnected: true))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.factory.adapters.count == 2)
    }

    /// M9: the same in the provide-auth path (an AUTH_PENDING prompt inside the running attempt), with an engine whose
    /// adapter object is reused by the fresh attempt: the answer finishing after the commit's fresh attempt started is
    /// stale and never reaches that attempt. Kills: dropping the `answerInFlight` check in the provide-auth path.
    @Test func aPendingApprovalAnswerFinishingAfterAFreshAttemptNeverReachesIt() async throws {
        let h = Harness(killSwitch: true)
        await h.provision()
        _ = h.start()
        let a = await h.adapter()
        a.emit { .authRequired(AuthChallenge(kind: .userPass, reason: .initial), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let p = try #require(h.sink.prompts.first)
        await h.secrets.holdNextCredentialWrite()
        let pending = answer(h, p, AuthAnswerSecrets(username: .text("alice"), password: .text("pw"), save: true))
        #expect(await waitUntil { await h.secrets.credentialWriteHeld })
        await h.provision(revision: 2, payload: Self.revision2)
        h.factory.reuseLastAdapter(true)
        await h.secrets.holdCredentialReads(true)
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        #expect(await waitUntil { await h.secrets.heldReadCount == 1 })        // the fresh attempt is loading
        #expect(await waitUntil { a.stopCount == 1 })                          // the old attempt's engine stopped
        await h.secrets.holdCredentialReads(false)
        #expect(await waitUntil { a.s.withLock { $0.startCalls } == 2 })       // the same object runs the fresh attempt
        #expect(a.request?.payload.bytesForTest == Array(Self.revision2.utf8))
        await h.secrets.releaseCredentialWrite()
        #expect(await pending.value?.code == .staleAnswer)
        #expect(a.s.withLock { $0.provided.isEmpty })
        #expect(await h.phase == .connecting)
    }

    /// M3: a connected session of revision 1; a Save Only of revision 2 is installed (payload and credentials; the
    /// session goes on); an after-Connected prompt of the session (revision 1's server) is answered with Save: the
    /// answer goes to the engine, and revision 2's credentials are left alone. Kills: dropping the first revision check
    /// of `saveAnswer`.
    @Test func anAfterConnectedSaveNeverWritesARevisionInstalledDuringTheSession() async throws {
        let h = Harness()
        await h.provision()
        let a = await h.connect()
        await h.provision(revision: 2, password: "new", payload: Self.revision2)
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        #expect(await h.phase == .connected)
        a.emit { .authRequired(AuthChallenge(kind: .userPass, reason: .initial), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: false)))
        let p = try #require(h.sink.prompts.first)
        #expect(await answer(h, p, AuthAnswerSecrets(username: .text("mallory"), password: .text("old"), save: true)).value == nil)
        #expect(await waitUntil { a.s.withLock { $0.provided.count } == 1 })
        let c = await Self.credential(h)
        #expect(c.username == Array("alice".utf8) && c.password == Array("new".utf8) && c.revision == 2)
    }

    /// Round 7 (Fable r7 N4): the control of the test above: nothing provisioned during the session, so an after-Connected
    /// Save of the session's own (current) revision is written. Kills: an after-Connected prompt built without its
    /// attempt's `revision:` (mutation H3; the Save would be dropped silently).
    @Test func anAfterConnectedSaveOfTheCurrentRevisionIsWritten() async throws {
        let h = Harness()
        await h.provision()
        let a = await h.connect()
        a.emit { .authRequired(AuthChallenge(kind: .userPass, reason: .initial), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: false)))
        let p = try #require(h.sink.prompts.first)
        #expect(await answer(h, p, AuthAnswerSecrets(username: .text("bob"), password: .text("pw2"), save: true)).value == nil)
        #expect(await waitUntil { a.s.withLock { $0.provided.count } == 1 })
        #expect(await waitUntil { await Self.credential(h).username == Array("bob".utf8) })
        let c = await Self.credential(h)
        #expect(c.username == Array("bob".utf8) && c.password == Array("pw2".utf8) && c.revision == 1)
    }
}
