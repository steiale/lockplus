import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// §7.2/§8.4 auth inside the pending start (draft 9: S2 E14b measured no start time limit, so the two-start flow is
/// gone). A first-connect prompt keeps the NE start pending; the answer becomes a new engine attempt of that start.
@Suite struct ControllerAuthTests {

    /// Starts, and lets the first engine attempt end with `ch`. Returns the start task and the adapter.
    func challenge(_ h: Harness, _ ch: AuthChallenge, manual: Bool = true) async -> (Task<Result<Void, LPTunnelError>, Never>, FakeAdapter) {
        let t = h.start(manual: manual)
        let a = await h.adapter(h.factory.adapters.count)
        a.finishStart(.failure(.auth(ch)))
        return (t, a)
    }

    func answer(_ h: Harness, _ p: AuthPrompt, _ a: AuthAnswerSecrets) async throws {
        try await h.controller.answerAuth(promptID: p.promptID, answer: a, callerUID: h.owner)
    }

    // MARK: the prompt keeps the start pending

    @Test func crv1KeepsTheStartPendingWithOnePrompt() async throws {
        let h = Harness()
        await h.provision()
        let (t, a) = await challenge(h, .crv1())
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        #expect(h.sink.prompts.count == 1)
        let p = h.sink.prompts[0]
        #expect(!p.nextStart && p.kind == .dynamicChallenge && p.lockedUsername == "alice" && p.profileID == h.pid)
        #expect(p.expiresAt == h.wall.now.addingTimeInterval(300))       // CRV1: 5 min
        #expect(await h.controller.pendingAuthPrompt(profileID: h.pid, ownerUID: h.owner) == p)
        #expect(await waitUntil { a.stopCount == 1 })                     // the single-use client is gone
        #expect(h.latch == nil && h.state.load().lastErrors[h.key] == nil)
        // nothing completes the start: no budget (S2 E14b), only the prompt deadline
        await h.advance(h.clock, by: .seconds(299))
        #expect(await h.phase == .awaitingAuth(beforeConnected: true))
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .startCancelled)
    }

    /// The answer goes into the SAME start: a new engine attempt (a new openvpn3 client) with the response, the CRV1
    /// cookie and the base credentials; the start then completes once, with success.
    @Test func crv1AnswerConnectsInsideTheSameStart() async throws {
        let h = Harness()
        await h.provision()
        let (t, _) = await challenge(h, .crv1())
        let p = try #require(await waitUntil { h.sink.prompts.count == 1 } ? h.sink.prompts[0] : nil)
        try await answer(h, p, AuthAnswerSecrets(response: .text("123456")))
        let a2 = await h.adapter(1)
        #expect(a2.request?.stash?.promptID == p.promptID)
        #expect(a2.request?.credentials?.password?.bytesForTest == Array("pw".utf8))   // stored base password reloaded
        #expect(a2.consumeStash())
        #expect(!a2.consumeStash())                                       // exactly once
        let got = a2.s.withLock { $0.consumed[0] }
        #expect(got.answer?.response?.bytesForTest == Array("123456".utf8))
        #expect(got.cookie?.bytesForTest == Array("CRV1:R,E:c3RhdGU=:YWxpY2U=:Enter code".utf8))
        _ = await a2.requestSettings(Harness.plan).value()
        a2.finishStart()
        #expect(h.code(await t.value) == nil)
        #expect(await h.waitPhase(.connected))
        #expect(h.sink.resolved.contains(p.promptID))
        #expect(await h.controller.pendingAuthPrompt(profileID: h.pid, ownerUID: h.owner) == nil)
    }

    @Test func crv1AnswerCarriesTheAnsweredBasePassword() async throws {
        let h = Harness()
        await h.provision(password: nil)
        var ch = AuthChallenge.crv1()
        ch.carriedUsername = .text("alice"); ch.carriedPassword = .text("base")     // base password came from an answer
        _ = await challenge(h, ch)
        #expect(await waitUntil { h.sink.prompts.count == 1 })
        try await answer(h, h.sink.prompts[0], AuthAnswerSecrets(response: .text("654321")))
        let a = await h.adapter(1)
        #expect(a.consumeStash())
        let b = a.s.withLock { $0.consumed[0] }
        #expect(b.carriedUsername?.bytesForTest == Array("alice".utf8) && b.carriedPassword?.bytesForTest == Array("base".utf8))
        #expect(b.answer?.response?.bytesForTest == Array("654321".utf8) && b.cookie != nil)
    }

    @Test func needCredsPromptsWithA10MinDeadline() async {
        let h = Harness()
        await h.provision(password: nil)
        _ = await challenge(h, AuthChallenge(kind: .userPass, reason: .initial))
        #expect(await waitUntil { h.sink.prompts.count == 1 })
        #expect(h.sink.prompts[0].expiresAt == h.wall.now.addingTimeInterval(600) && !h.sink.prompts[0].nextStart)
    }

    @Test func authFailedBelowThreeIsAPromptThirdIsFatal() async throws {
        let h = Harness()
        await h.provision()
        let rejected = AuthChallenge(kind: .userPass, reason: .rejected, challengeText: "bad password", rejectedStoredCredentials: true)
        let (t, _) = await challenge(h, rejected)
        #expect(await waitUntil { h.sink.prompts.count == 1 })
        #expect(h.sink.prompts[0].reason == .rejected)
        #expect(h.state.load().authFailedAt[h.key] == h.wall.now)          // 60 s resend guard armed
        #expect(await waitUntil { await h.secrets.bytes(.credential, h.pid).flatMap { CredentialCodec.decode(SecretBytes(copying: $0)) }?.password == nil })
        // answer → a new attempt → rejected again
        try await answer(h, h.sink.prompts[0], AuthAnswerSecrets(username: .text("alice"), password: .text("wrong")))
        (await h.adapter(1)).finishStart(.failure(.auth(rejected)))
        #expect(await waitUntil { h.sink.prompts.count == 2 })
        try await answer(h, h.sink.prompts[1], AuthAnswerSecrets(username: .text("alice"), password: .text("wrong2")))
        (await h.adapter(2)).finishStart(.failure(.auth(rejected)))
        #expect(h.code(await t.value) == .authFailed)                     // the third: the .fatal rows, no prompt
        #expect(h.sink.prompts.count == 2)
    }

    // MARK: on-demand starts have nobody to answer (C16)

    @Test func onDemandPromptFailsWithAHardLatch() async {
        let h = Harness()
        await h.provision()
        let (t, _) = await challenge(h, .crv1(), manual: false)
        #expect(h.code(await t.value) == .authRequired)
        #expect(h.sink.prompts.isEmpty)
        #expect(h.latch?.kind == .hard && h.sink.endedCodes == [.authRequired])
    }

    @Test func onDemandPromptUnderTheFlagIsHeldNotFailed() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let (t, _) = await challenge(h, .crv1(), manual: false)
        #expect(await h.waitPhase(.held(.nonRetryable(.authRequired))))
        #expect(h.sink.prompts.isEmpty && h.latch?.kind == .hard && h.sink.endedCodes == [.authRequired])
        let snap = await h.controller.snapshot()
        #expect(snap.holdBeforeConnected && snap.holdReason == .nonRetryable(.authRequired))
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .authRequired)                   // the held error, not .startCancelled
    }

    /// A manual start of a profile with on-demand rules prompts in-start; nothing latches while the start is pending.
    @Test func manualPromptWithOnDemandRulesDoesNotLatch() async {
        let h = Harness(onDemandRules: true)
        await h.provision()
        _ = await challenge(h, .crv1())
        #expect(await waitUntil { h.sink.prompts.count == 1 })
        #expect(h.latch == nil)
    }

    // MARK: deadlines and cancel

    @Test func promptDeadlineFailsTheStartWithoutTheFlag() async {
        let h = Harness()
        await h.provision()
        let (t, _) = await challenge(h, .crv1())
        #expect(await waitUntil { h.sink.prompts.count == 1 })
        await h.advance(h.clock, by: .seconds(300))
        #expect(h.code(await t.value) == .authTimedOut)
        #expect(h.sink.resolved.contains(h.sink.prompts[0].promptID))
    }

    @Test func promptDeadlineHoldsTheStartUnderTheFlag() async {
        let h = Harness(killSwitch: true)
        await h.provision(password: nil)
        let (t, _) = await challenge(h, AuthChallenge(kind: .userPass, reason: .initial))
        #expect(await waitUntil { h.sink.prompts.count == 1 })
        await h.advance(h.clock, by: .seconds(600))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.authTimedOut))))
        #expect(h.host.cancelledCodes.isEmpty && h.host.s.withLock { $0.reasserting.isEmpty })
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .authTimedOut)
    }

    @Test(arguments: [false, true])
    func cancelAuthInTheStart(killSwitch: Bool) async throws {
        let h = Harness(killSwitch: killSwitch)
        await h.provision()
        let (t, _) = await challenge(h, .crv1())
        #expect(await waitUntil { h.sink.prompts.count == 1 })
        try await h.controller.cancelAuth(promptID: h.sink.prompts[0].promptID, callerUID: h.owner)
        if killSwitch {
            #expect(await h.waitPhase(.held(.blockedAfterFailure(.authRequired))))
            await h.controller.stop(reason: .userInitiated)
        }
        #expect(h.code(await t.value) == .authRequired)
    }

    @Test func staleAndForeignAnswers() async throws {
        let h = Harness()
        await h.provision()
        _ = await challenge(h, .crv1())
        #expect(await waitUntil { h.sink.prompts.count == 1 })
        let p = h.sink.prompts[0]
        await #expect(throws: LPError(.staleAnswer)) {
            try await h.controller.answerAuth(promptID: UUID(), answer: AuthAnswerSecrets(), callerUID: h.owner)
        }
        await #expect(throws: LPError(.notOwner)) {
            try await h.controller.answerAuth(promptID: p.promptID, answer: AuthAnswerSecrets(), callerUID: 502)
        }
        await #expect(throws: LPError(.notOwner)) { try await h.controller.cancelAuth(promptID: p.promptID, callerUID: 502) }
        // an answered prompt is gone: a second answer is stale
        try await answer(h, p, AuthAnswerSecrets(response: .text("1")))
        await #expect(throws: LPError(.staleAnswer)) { try await self.answer(h, p, AuthAnswerSecrets(response: .text("2"))) }
    }

    /// A waiting start ends when its profile changes or goes away (the app then starts the new revision).
    @Test(arguments: ["removeProfile", "higherRevision", "wipeAllSecrets"])
    func aWaitingStartEndsWhenTheProfileChanges(_ event: String) async {
        let h = Harness()
        await h.provision()
        let (t, _) = await challenge(h, .crv1())
        #expect(await waitUntil { h.sink.prompts.count == 1 })
        switch event {
        case "removeProfile": await h.controller.profileRemoved(h.pid, ownerUID: h.owner)
        case "higherRevision": await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        default: await h.controller.secretsWiped(ownerUID: h.owner)
        }
        #expect(h.code(await t.value) == .startCancelled)
        #expect(await h.phase == .idle)
        #expect(h.sink.resolved.contains(h.sink.prompts[0].promptID))
    }

    // MARK: prepareStartAuth (known-interactive profiles; the answer waits for the next manual start)

    @Test func preparedAnswerIsTakenByTheNextManualStartOnce() async throws {
        let h = Harness()
        await h.provision(password: nil)
        let p = await h.controller.prepareStartAuth(profileID: h.pid, ownerUID: h.owner, kind: .staticChallenge)
        #expect(p.nextStart && p.kind == .staticChallenge && p.reason == .initial)
        try await answer(h, p, AuthAnswerSecrets(username: .text("alice"), password: .text("pw"), response: .text("42")))
        #expect(h.factory.adapters.isEmpty)                               // answerAuth started nothing
        #expect(await h.controller.pendingAuthPrompt(profileID: h.pid, ownerUID: h.owner) == nil)
        _ = h.start()
        let a = await h.adapter()
        #expect(a.consumeStash())
        #expect(a.s.withLock { $0.consumed[0].answer?.password?.bytesForTest } == Array("pw".utf8))
        await h.controller.stop(reason: .userInitiated)
        _ = h.start()                                                     // used once: the next start has none
        #expect(await h.adapter(1).request?.stash == nil)
    }

    @Test func onDemandStartNeverTakesAPreparedAnswer() async throws {
        let h = Harness()
        await h.provision(password: nil)
        let p = await h.controller.prepareStartAuth(profileID: h.pid, ownerUID: h.owner, kind: .userPass)
        try await answer(h, p, AuthAnswerSecrets(username: .text("a"), password: .text("b")))
        _ = h.start(manual: false)
        #expect(await h.adapter().request?.stash == nil)
    }

    @Test func aFailedStartDropsThePreparedAnswer() async throws {
        let h = Harness()
        await h.provision(password: nil)
        let p = await h.controller.prepareStartAuth(profileID: h.pid, ownerUID: h.owner, kind: .userPass)
        try await answer(h, p, AuthAnswerSecrets(username: .text("a"), password: .text("b")))
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.dnsResolutionFailed))))   // before provide_creds
        _ = await t.value
        _ = h.start()                                                     // no cross-start stash: asked again in-start
        #expect(await h.adapter(1).request?.stash == nil)
    }

    @Test(arguments: ["expiry", "cancelAuth", "removeProfile", "wipeAllSecrets", "higherRevision", "newerPrompt"])
    func preparedAnswerIsDropped(by event: String) async throws {
        let h = Harness()
        await h.provision(password: nil)
        let p = await h.controller.prepareStartAuth(profileID: h.pid, ownerUID: h.owner, kind: .userPass)
        if event != "cancelAuth" && event != "expiry" {
            try await answer(h, p, AuthAnswerSecrets(username: .text("a"), password: .text("b")))
        }
        switch event {
        case "expiry": h.wall.advance(601); await #expect(throws: LPError(.staleAnswer)) { try await self.answer(h, p, AuthAnswerSecrets()) }
        case "cancelAuth": try await h.controller.cancelAuth(promptID: p.promptID, callerUID: h.owner)
        case "removeProfile": await h.controller.profileRemoved(h.pid, ownerUID: h.owner)
        case "wipeAllSecrets": await h.controller.secretsWiped(ownerUID: h.owner)
        case "higherRevision":
            await h.provision(revision: 2, password: nil)
            await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        default: _ = await h.controller.prepareStartAuth(profileID: h.pid, ownerUID: h.owner, kind: .userPass)
        }
        _ = h.start(revision: event == "higherRevision" ? 2 : 1)
        if event == "removeProfile" || event == "wipeAllSecrets" { return }     // nothing provisioned any more
        #expect(await h.adapter().request?.stash == nil)
    }

    @Test func saveTickedPersistsTheBasePasswordOnly() async throws {
        let h = Harness()
        await h.provision(password: nil)
        let p = await h.controller.prepareStartAuth(profileID: h.pid, ownerUID: h.owner, kind: .userPass)
        try await answer(h, p, AuthAnswerSecrets(username: .text("bob"), password: .text("base"), response: .text("otp"), save: true))
        let c = try #require(await h.secrets.bytes(.credential, h.pid).flatMap { CredentialCodec.decode(SecretBytes(copying: $0)) })
        #expect(c.username?.bytesForTest == Array("bob".utf8) && c.password?.bytesForTest == Array("base".utf8))
    }

    /// L2: a credential record is only ever re-written under the owner of the existing entry; with no payload in the
    /// answering uid's namespace nothing is created, and another uid's record is never touched.
    @Test func credentialRewritesStayInTheEntrysNamespace() async throws {
        let h = Harness()
        await h.provision()
        try await h.secrets.put(.credential, h.pid, ownerUID: 502, revision: 1,
                                CredentialCodec.encode(CredentialSecrets(username: .text("mallory"), password: .text("m"))))
        _ = await challenge(h, AuthChallenge(kind: .userPass, reason: .rejected, rejectedStoredCredentials: true))
        #expect(await waitUntil { await h.secrets.bytes(.credential, h.pid).flatMap { CredentialCodec.decode(SecretBytes(copying: $0)) }?.password == nil })
        let m = await h.secrets.bytes(.credential, h.pid, ownerUID: 502).flatMap { CredentialCodec.decode(SecretBytes(copying: $0)) }
        #expect(m?.password?.bytesForTest == Array("m".utf8))
        let p = await h.controller.prepareStartAuth(profileID: UUID(), ownerUID: 503, kind: .userPass)
        try await h.controller.answerAuth(promptID: p.promptID, answer: AuthAnswerSecrets(username: .text("x"), password: .text("y"), save: true),
                                          callerUID: 503)
        #expect(await h.secrets.items.keys.contains { $0.hasPrefix("503/") } == false)
    }

    // MARK: AUTH_PENDING (the engine attempt keeps running)

    @Test func authPendingAnsweredIntoTheRunningAttempt() async throws {
        let h = Harness()
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.emit { .authRequired(AuthChallenge(kind: .pendingApproval, reason: .initial), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let p = try #require(h.sink.prompts.first)
        #expect(!p.nextStart && p.expiresAt == h.wall.now.addingTimeInterval(600))    // the auth deadline, no budget
        // the connect deadline does not run while the user approves (50 s pass, nothing happens)
        await h.advance(h.clock, by: .seconds(60))
        #expect(await h.phase == .awaitingAuth(beforeConnected: true))
        try await answer(h, p, AuthAnswerSecrets(response: .text("x")))
        #expect(await waitUntil { a.s.withLock { $0.provided.count } == 1 })
        #expect(await h.phase == .connecting && h.factory.adapters.count == 1)
        a.finishStart()
        #expect(h.code(await t.value) == nil)
    }

    @Test(arguments: [false, true])
    func authPendingDeadline(killSwitch: Bool) async throws {
        let h = Harness(killSwitch: killSwitch)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.emit { .authRequired(AuthChallenge(kind: .pendingApproval, reason: .initial), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        await h.advance(h.clock, by: .seconds(600))
        if killSwitch {
            #expect(await h.waitPhase(.held(.blockedAfterFailure(.authTimedOut))))
            #expect(await waitUntil { a.stopCount == 1 })
            await h.controller.stop(reason: .userInitiated)
        }
        #expect(h.code(await t.value) == .authTimedOut)
    }

    @Test func cancelAuthPendingFailsTheStart() async throws {
        let h = Harness()
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.emit { .authRequired(AuthChallenge(kind: .pendingApproval, reason: .initial), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        try await h.controller.cancelAuth(promptID: try #require(h.sink.prompts.first).promptID, callerUID: h.owner)
        #expect(h.code(await t.value) == .authRequired)
    }

    // MARK: review L6 / nits: a live prompt never outlives what it belongs to

    /// L6: AUTH_PENDING (the attempt still runs) and the profile goes away: the pending start ends, the prompt is
    /// resolved for every app instance (before: the prompt was dropped silently and the start kept running).
    @Test(arguments: ["removeProfile", "wipeAllSecrets", "higherRevision"])
    func authPendingStartEndsWithItsProfile(_ how: String) async throws {
        let h = Harness()
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.emit { .authRequired(AuthChallenge(kind: .pendingApproval, reason: .initial), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let p = try #require(h.sink.prompts.first)
        switch how {
        case "removeProfile": await h.controller.profileRemoved(h.pid, ownerUID: h.owner)
        case "wipeAllSecrets": await h.controller.secretsWiped(ownerUID: h.owner)
        default: await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        }
        #expect(h.code(await t.value) == .startCancelled)
        #expect(h.sink.resolved.contains(p.promptID))
        #expect(await waitUntil { a.stopCount == 1 })
        #expect(await h.phase == .idle)
    }

    /// Nit: the attempt ends with a new prompt while an AUTH_PENDING prompt was showing: the old one is resolved.
    @Test func aNewInStartPromptResolvesTheAuthPendingOne() async throws {
        let h = Harness()
        await h.provision()
        _ = h.start()
        let a = await h.adapter()
        a.emit { .authRequired(AuthChallenge(kind: .pendingApproval, reason: .initial), epoch: $0) }
        #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        let old = try #require(h.sink.prompts.first)
        a.finishStart(.failure(.auth(AuthChallenge(kind: .userPass, reason: .rejected))))
        #expect(await waitUntil { h.sink.prompts.count == 2 })
        #expect(h.sink.resolved.contains(old.promptID))
        #expect(!h.sink.resolved.contains(h.sink.prompts[1].promptID))
        await h.controller.stop(reason: .userInitiated)
        #expect(h.sink.resolved.contains(h.sink.prompts[1].promptID))      // and the stop resolves the new one
    }
}
