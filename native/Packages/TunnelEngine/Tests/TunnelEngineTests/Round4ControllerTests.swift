import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// 2.0.2 review round 4 (Fable L1, N2, N3 = Codex r4 #1; the refusal paths of FIX3 item 2): the extension side.
@Suite(.timeLimit(.minutes(1))) struct Round4ControllerTests {
    typealias World = ControllerProviderGuardTests.World
    static let revision2 = Round3ControllerTests.revision2

    func connected(_ h: Harness, _ t: Task<Result<Void, LPTunnelError>, Never>, adapter n: Int = 0) async {
        await Round3ControllerTests().connected(h, t, adapter: n)
    }

    // MARK: Fable L1 = Codex r4 #1: a commit never ends a kill-switch start in the guard

    /// Fable probe 1, inverted: a kill-switch start of profile B waits on profile A's teardown after A's fatal error
    /// (`.stopping`, no protecting session of B); B is provisioned at revision 2 meanwhile. B's start proceeds, loads
    /// revision 2 and connects.
    @Test func aKillSwitchStartWaitingOnAStoppingSessionIsKeptAcrossACommit() async {
        let w = World()
        await w.provision()
        let a = w.instance(), b = w.instance()
        let adapterA = await w.connect(a)                                       // A, split
        adapterA.s.withLock { $0.hangStop = true }
        adapterA.emit { .fatal(LPTunnelError(.engineFatal), epoch: $0) }
        #expect(await waitUntil { adapterA.stopCount == 1 })                    // A's teardown hangs
        let n = w.h.factory.adapters.count
        let tb = w.start(b, other: true, killSwitch: true)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))   // B waits
        try? await w.h.secrets.put(.payload, w.otherPID, ownerUID: w.h.owner, revision: 2, .text(Self.revision2))
        try? await w.h.secrets.put(.credential, w.otherPID, ownerUID: w.h.owner, revision: 2,
                                   CredentialCodec.encode(CredentialSecrets(username: .text("bob"), password: .text("pw"))))
        await w.h.controller.profileProvisioned(w.otherPID, ownerUID: w.h.owner, revision: 2)
        adapterA.releaseStop()
        let next = await w.adapter(n)
        #expect(next.request?.payload.bytesForTest == Array(Self.revision2.utf8))
        await w.finish(next)
        #expect(w.code(await w.value(tb, "B")) == nil)
        #expect(await w.h.waitPhase(.connected))
    }

    /// Fable probe 2 = Codex r4 #1's regression, inverted: an armed kill-switch session is connected at revision 1; NE
    /// stops its instance (a restart) and the replay with the persisted nonce arrives on a new instance, tearing the stale
    /// session down on a deliberately slow adapter stop; the app provisions revision 2 meanwhile; the stop is released;
    /// the replay is admitted on revision 2, connects, and its record stays.
    @Test func aReplayInAStaleTeardownSurvivesACommit() async {
        let w = World(killSwitch: true, authorisation: true)
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let nonce = UUID()
        _ = await w.h.controller.armStart(profileID: w.h.pid, ownerUID: w.h.owner, nonce: nonce)
        let t1 = w.start(a1, nonce: nonce)
        let first = await w.adapter(0)
        await w.finish(first)
        #expect(w.code(await w.value(t1, "A1")) == nil)
        first.s.withLock { $0.hangStop = true }
        w.providers.stopped(a1.token)                                          // NE stopped the old instance
        let replay = w.start(a2, nonce: nonce)
        #expect(await waitUntil { first.stopCount == 1 })                      // the replay waits in the stale teardown
        let backend = EngineServiceBackend(controller: w.h.controller, secrets: w.h.secrets, validator: FakeValidator())
        let r = await backend.handle(.provisionProfile, request: try! LPWire.encode(ProvisionRequest(
            profileID: w.h.pid, kind: w.h.kind, revision: 2, payload: Data(Self.revision2.utf8), credentials: nil)),
            peer: PeerContext(uid: w.h.owner, pid: 1))
        if case .failure(let e) = r { Issue.record("provision: \(e.code)") }
        first.releaseStop()
        let next = await w.adapter(1)
        #expect(next.request?.payload.bytesForTest == Array(Self.revision2.utf8))
        await w.finish(next)
        #expect(w.code(await w.value(replay, "replay")) == nil)
        #expect(await w.h.waitPhase(.connected))
        #expect(w.h.state.load().authorisedStarts[w.h.key]?.nonce == nonce)
        #expect(w.binds.list == [a1.token, a2.token])
    }

    /// A start WITHOUT a kill switch in the same stale teardown still ends on the commit (the app starts the new
    /// revision; a failed split start is not open).
    @Test func aSplitStartInAStaleTeardownStillEndsOnACommit() async {
        let w = World()
        await w.provision()
        let a1 = w.instance(), a2 = w.instance()
        let first = await w.connect(a1)
        first.s.withLock { $0.hangStop = true }
        w.providers.stopped(a1.token)
        let t2 = w.start(a2)
        #expect(await waitUntil { first.stopCount == 1 })
        await w.h.controller.profileProvisioned(w.h.pid, ownerUID: w.h.owner, revision: 2)
        first.releaseStop()
        #expect(w.code(await w.value(t2, "A2")) == .startCancelled)
        #expect(w.binds.list == [a1.token])
    }

    // MARK: Fable N2: a kept kill-switch start at a live prompt

    /// A kill-switch start at a live CRV1 prompt (revision 1's server) is kept across a commit: the prompt is resolved,
    /// nothing of it (carried credentials, the challenge cookie) goes to the next attempt, which runs on revision 2.
    @Test func aKeptKillSwitchStartAtALivePromptStartsAFreshAttempt() async throws {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.finishStart(.failure(.auth(.crv1())))
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let p = try #require(h.sink.prompts.first)
        await h.provision(revision: 2, payload: Self.revision2)
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        #expect(h.sink.resolved.contains(p.promptID))
        let b = await h.adapter(1)
        #expect(b.request?.stash == nil)
        #expect(b.request?.payload.bytesForTest == Array(Self.revision2.utf8))
        await #expect(throws: LPError(.staleAnswer)) {
            try await h.controller.answerAuth(promptID: p.promptID, answer: AuthAnswerSecrets(response: .text("1")), callerUID: h.owner)
        }
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        #expect(h.code(await t.value) == nil)
        #expect(await h.waitPhase(.connected))
    }

    // MARK: Round 5 (Codex r5 #6, Fable r5 N2): answers and commits are bound to the revision the attempt loaded

    /// Codex r5 #6: a before-Connected answer with Save is being applied (its credential save blocked) when revision 2
    /// commits. The answer is stale (never stashed for revision 2's attempt), its save never overwrites revision 2's
    /// credentials, and the kept kill-switch start goes on with a fresh attempt on revision 2.
    @Test func anAnswerBeingSavedWhenANewRevisionCommitsIsNeverUsedForIt() async throws {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.finishStart(.failure(.auth(.crv1())))
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let p = try #require(h.sink.prompts.first)
        await h.secrets.holdCredentialReads(true)
        let c = h.controller, owner = h.owner
        let answer = Task { () -> LPError? in
            do throws(LPError) {
                try await c.answerAuth(promptID: p.promptID, answer: AuthAnswerSecrets(username: .text("mallory"), password: .text("old"),
                                                                                      response: .text("1"), save: true), callerUID: owner)
                return nil
            } catch { return error }
        }
        #expect(await waitUntil { await h.secrets.heldReadCount == 1 })      // the save is reading the stored credential
        await h.provision(revision: 2, payload: Self.revision2)
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        await h.secrets.holdCredentialReads(false)
        #expect(await answer.value?.code == .staleAnswer)
        let b = await h.adapter(1)
        #expect(b.request?.stash == nil)
        #expect(b.request?.payload.bytesForTest == Array(Self.revision2.utf8))
        let saved = try #require(await h.secrets.get(.credential, h.pid, ownerUID: h.owner).flatMap(CredentialCodec.decode))
        #expect(saved.username?.bytesForTest == Array("alice".utf8))
        #expect(await h.secrets.items["\(h.owner)/\(SecretKind.credential.rawValue)/\(h.pid.uuidString)"]?.revision == 2)
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        #expect(h.code(await t.value) == nil)
    }

    /// Fable r5 N2: once the fresh attempt has loaded revision 2 and prompts, another commit of revision 2 (a
    /// same-revision retry, a reconcile) leaves that prompt and attempt alone; its answer is used.
    @Test func aSecondCommitOfTheLoadedRevisionKeepsThePrompt() async throws {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        await h.adapter().finishStart(.failure(.auth(.crv1())))
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        await h.provision(revision: 2, payload: Self.revision2)
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        let b = await h.adapter(1)
        b.finishStart(.failure(.auth(.crv1())))
        #expect(await waitUntil { h.sink.prompts.count == 2 })
        let p2 = h.sink.prompts[1]
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        #expect(!h.sink.resolved.contains(p2.promptID))
        try await h.controller.answerAuth(promptID: p2.promptID, answer: AuthAnswerSecrets(response: .text("2")), callerUID: h.owner)
        let c = await h.adapter(2)
        #expect(c.request?.stash != nil)
        #expect(h.factory.adapters.count == 3)
        _ = await c.requestSettings(Harness.plan).value()
        c.finishStart()
        #expect(h.code(await t.value) == nil)
    }

    // MARK: Fable N3: the user-clear marks are bounded

    @Test func userClearMarksAreKeptOnlyWhileAStartIsInTheGuard() async {
        let w = World(killSwitch: true, authorisation: true)
        await w.provision()
        for _ in 0..<50 { await w.h.controller.profileRemoved(UUID(), ownerUID: w.h.owner) }
        #expect(await w.h.controller.userClearMarkCount == 0)
        let a1 = w.instance(), a2 = w.instance()
        let nonce = UUID()
        _ = await w.h.controller.armStart(profileID: w.h.pid, ownerUID: w.h.owner, nonce: nonce)
        let t1 = w.start(a1, nonce: nonce)
        await w.finish(await w.adapter(0))
        #expect(w.code(await w.value(t1, "A1")) == nil)
        let t2 = w.start(a2, nonce: nonce)
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { w.binds.list.count > 1 }))
        await w.h.controller.profileRemoved(UUID(), ownerUID: w.h.owner)
        #expect(await w.h.controller.userClearMarkCount == 1)
        await w.stopTunnel(a1)
        #expect(w.code(await w.value(t2, "A2")) == .startNotAuthorised)
        #expect(await w.h.controller.userClearMarkCount == 0)
    }

    // MARK: FIX3 refusal path 2: capacity and schema keep kill-switch records

    /// Past the cap, a record without a kill switch goes first; then a kill-switch record of the admitting owner; another
    /// owner's kill-switch record only when nothing else is left.
    @Test func capacityEvictsRecordsWithoutAKillSwitchFirst() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let mineKS = ProfileKey(ownerUID: 501, profileID: UUID()), theirsKS = ProfileKey(ownerUID: 502, profileID: UUID())
        let plain = ProfileKey(ownerUID: 502, profileID: UUID()), admitted = ProfileKey(ownerUID: 502, profileID: UUID())
        var recs: [ProfileKey: AuthorisedStart] = [
            mineKS: AuthorisedStart(nonce: nil, at: base, killSwitch: true),
            theirsKS: AuthorisedStart(nonce: nil, at: base.addingTimeInterval(1), killSwitch: true),
            plain: AuthorisedStart(nonce: nil, at: base.addingTimeInterval(2), killSwitch: false),
            admitted: AuthorisedStart(nonce: nil, at: base.addingTimeInterval(3), killSwitch: true),
        ]
        #expect(TestController.evictionCandidate(recs, admitted: admitted, live: nil) == plain)
        recs[plain] = nil
        #expect(TestController.evictionCandidate(recs, admitted: admitted, live: nil) == theirsKS)   // the admitting owner's own
        recs[theirsKS] = nil
        #expect(TestController.evictionCandidate(recs, admitted: admitted, live: nil) == mineKS)
        #expect(TestController.evictionCandidate(recs, admitted: admitted, live: mineKS) == nil)
    }

    /// A state file of another schema (or with another part unreadable) keeps its start authorisations, record by record.
    @Test func aStateFileOfAnotherSchemaKeepsItsStartAuthorisations() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lp-r4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "state.plist")
        var st = PersistedTunnelState()
        let ks = ProfileKey(ownerUID: 501, profileID: UUID()), other = ProfileKey(ownerUID: 501, profileID: UUID())
        st.authorisedStarts[ks] = AuthorisedStart(nonce: UUID(), at: Date(timeIntervalSince1970: 1_700_000_000), killSwitch: true)
        st.authorisedStarts[other] = AuthorisedStart(nonce: nil, at: Date(timeIntervalSince1970: 1_700_000_001), killSwitch: false)
        st.schema = PersistedTunnelState.currentSchema + 1
        var obj = try #require(try PropertyListSerialization.propertyList(from: try PropertyListEncoder().encode(st), format: nil) as? [String: Any])
        obj["latches"] = "damaged"
        var list = try #require(obj["authorisedStarts"] as? [Any])
        list += [["ownerUID": "x"], ["at": 1]]                                 // a damaged pair is skipped
        obj["authorisedStarts"] = list
        try PropertyListSerialization.data(fromPropertyList: obj, format: .binary, options: 0).write(to: url)
        let loaded = PlistTunnelStateStore(url: url).load()
        #expect(loaded.schema == PersistedTunnelState.currentSchema)
        #expect(loaded.latches.isEmpty)
        #expect(loaded.authorisedStarts == [ks: st.authorisedStarts[ks]!, other: st.authorisedStarts[other]!])
    }
}
