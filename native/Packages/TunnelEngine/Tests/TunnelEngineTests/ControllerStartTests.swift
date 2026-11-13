import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// §7.2 rows up to Connected, the connect deadline, the start latch and the before-Connected `.fatal` rows (draft 9:
/// withheld under `includeAllNetworks`, S2 E14).
@Suite(.timeLimit(.minutes(1))) struct ControllerStartTests {     // round 7 (Fable N2): a start that never ends fails, not hangs
    static func latched(_ kind: StartLatch.Kind, _ code: LPErrorCode, notBefore: Date? = nil) -> (UUID) -> PersistedTunnelState {
        { pid in
            var st = PersistedTunnelState()
            st.latches[ProfileKey(ownerUID: 501, profileID: pid)] = .init(latch: StartLatch(code: code, kind: kind, notBefore: notBefore, revision: 1), interval: notBefore == nil ? nil : 5)
            return st
        }
    }

    // MARK: idle → starting

    @Test func manualStartConnects() async {
        let h = Harness()
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        #expect(await h.phase == .connecting)
        #expect(a.request?.credentials?.username?.bytesForTest == Array("alice".utf8))
        let ticket = a.requestSettings(Harness.plan)
        #expect(await ticket.value() == .fd(7))                       // utun-fd mode: NE's fd, chosen by the host
        #expect(await h.phase == .establishing)
        #expect(h.host.appliedCount == 1)
        a.finishStart()
        #expect(h.code(await t.value) == nil)
        #expect(await h.waitPhase(.connected))
        let snap = await h.controller.snapshot()
        #expect(snap.phase == .connected && snap.profileID == h.pid)
    }

    @Test func packetFlowModeAnswersApplied() async {
        let h = Harness(dataPlane: .packetFlow)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        #expect(a.request?.pump != nil && a.request?.dataPlane == .packetFlow)
        #expect(await a.requestSettings(Harness.plan).value() == .applied)
        a.finishStart()
        #expect(h.code(await t.value) == nil)
    }

    /// The FaultInjection data-plane switch (Tunnel target, `LP_FAULT_INJECTION` only) reaches the controller as a
    /// per-request override: it wins over `ControllerConfig.dataPlane` for that session only.
    @Test func dataPlaneOverrideForcesPacketFlowForOneSession() async {
        let h = Harness()                                              // config: .utunFD
        await h.provision()
        let t = h.start(dataPlaneOverride: .packetFlow)
        let a = await h.adapter()
        #expect(a.request?.pump != nil && a.request?.dataPlane == .packetFlow)
        #expect(await a.requestSettings(Harness.plan).value() == .applied)
        #expect(h.host.appliedCount == 1)
        a.finishStart()
        #expect(h.code(await t.value) == nil)
        _ = await h.waitPhase(.connected)
        let next = await h.connect()                                   // no override: back to the configured plane
        #expect(next.request?.dataPlane == .utunFD && next.request?.pump == nil)
    }

    @Test func unchangedPlanIsNotReapplied() async {
        let h = Harness()
        await h.provision()
        let a = await h.connect()
        _ = await a.requestSettings(Harness.plan).value()            // openvpn3 reconnect with the same plan
        #expect(h.host.appliedCount == 1)
        var p = Harness.plan; p.remoteAddress = "198.51.100.8"         // remote switch: re-applied
        _ = await a.requestSettings(p).value()
        #expect(h.host.appliedCount == 2)
    }

    @Test func hardLatchFailsOnDemandStartBeforeAnyIO() async {
        let h = Harness(state: Self.latched(.hard, .authFailed))
        await h.provision()
        let r = await h.start(manual: false).value
        #expect(h.code(r) == .authFailed)
        #expect(h.factory.adapters.isEmpty)
        #expect(await h.secrets.gets == 0)
    }

    /// Draft 9: under `includeAllNetworks` a latched on-demand start is HELD (a failed start would be open, E14c),
    /// still with no credential or network I/O.
    @Test func hardLatchHoldsAnOnDemandStartUnderTheFlag() async {
        let h = Harness(killSwitch: true, state: Self.latched(.hard, .authFailed))
        await h.provision()
        let t = h.start(manual: false)
        #expect(await h.waitPhase(.held(.nonRetryable(.authFailed))))
        let gets = await h.secrets.gets
        #expect(h.factory.adapters.isEmpty && gets == 0)
        h.clock.advance(by: .seconds(3600)); try? await Task.sleep(for: .milliseconds(5))
        #expect(h.factory.adapters.isEmpty)                            // a hard latch never retries
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .authFailed)
    }

    @Test func backoffLatchUnderTheFlagRetriesAtNotBefore() async {
        let h = Harness(killSwitch: true, state: Self.latched(.backoff, .connectTimeout, notBefore: MutableWallClock().now.addingTimeInterval(5)))
        await h.provision()
        _ = h.start(manual: false)
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        #expect(h.factory.adapters.isEmpty)
        await h.advance(h.clock, by: .seconds(5))
        _ = await h.adapter()                                         // the retry runs the start
    }

    @Test func backoffLatchBlocksUntilNotBefore() async {
        let h2 = Harness(state: Self.latched(.backoff, .connectTimeout, notBefore: MutableWallClock().now.addingTimeInterval(5)))
        await h2.provision()
        #expect(h2.code(await h2.start(manual: false).value) == .connectTimeout)
        #expect(h2.factory.adapters.isEmpty)
        h2.wall.advance(6)
        _ = h2.start(manual: false)
        _ = await h2.adapter()                                        // after notBefore the start runs
    }

    @Test func manualStartClearsTheLatch() async {
        let h = Harness(state: Self.latched(.hard, .authFailed))
        await h.provision()
        _ = h.start(manual: true)
        _ = await h.adapter()
        #expect(h.latch == nil)
    }

    // MARK: starting → stopped

    @Test func notProvisioned() async {
        let h = Harness()
        #expect(h.code(await h.start().value) == .profileNotProvisioned)
        #expect(h.latch == nil)                                        // manual, no on-demand rules: no latch
        #expect(await h.phase == .idle)
    }

    @Test func notProvisionedOnDemandArmsHardLatchAndSessionEnded() async {
        let h = Harness()
        #expect(h.code(await h.start(manual: false).value) == .profileNotProvisioned)
        #expect(h.latch?.kind == .hard && h.latch?.code == .profileNotProvisioned)
        #expect(h.sink.endedCodes == [.profileNotProvisioned])
    }

    @Test func staleRevision() async {
        let h = Harness()
        await h.provision(revision: 1)
        #expect(h.code(await h.start(revision: 2).value) == .profileRevisionStale)
    }

    @Test func invalidPayload() async {
        let h = Harness(rejectPayload: true)
        await h.provision()
        #expect(h.code(await h.start().value) == .profileInvalid)
    }

    @Test func preLoginSecretStoreLockArmsBackoffNotHard() async {
        let h = Harness(onDemandRules: true)
        await h.provision()
        await h.secrets.setFailure(LPError(.secretStoreUnavailable, detail: SecretStoreDetail.lockedBeforeLogin))
        #expect(h.code(await h.start(manual: false).value) == .secretStoreUnavailable)
        #expect(h.latch?.kind == .backoff && h.latch?.notBefore == h.wall.now.addingTimeInterval(5))
        #expect(h.sink.endedCodes.isEmpty)
        // second failure doubles the interval
        h.wall.advance(6)
        _ = await h.start(manual: false).value
        #expect(h.latch?.notBefore == h.wall.now.addingTimeInterval(10))
    }

    @Test func resendGuardWithholdsStoredCredentials() async {
        let h = Harness(state: { pid in
            var st = PersistedTunnelState(); st.authFailedAt[ProfileKey(ownerUID: 501, profileID: pid)] = MutableWallClock().now.addingTimeInterval(-30); return st
        })
        await h.provision()
        _ = h.start()
        let a = await h.adapter()
        // T14: within 60 s of an AUTH_FAILED only the stored username/password are withheld
        #expect(a.request?.credentials?.username == nil && a.request?.credentials?.password == nil)
    }

    @Test func resendGuardKeepsPassphraseAndProxyCredentials() async throws {
        let h = Harness(state: { pid in
            var st = PersistedTunnelState(); st.authFailedAt[ProfileKey(ownerUID: 501, profileID: pid)] = MutableWallClock().now.addingTimeInterval(-30); return st
        })
        await h.provision()
        try await h.secrets.put(.credential, h.pid, ownerUID: h.owner, revision: 1, CredentialCodec.encode(CredentialSecrets(
            username: .text("alice"), password: .text("pw"), keyPassphrase: .text("kp"), proxyUsername: .text("pu"), proxyPassword: .text("pp"))))
        _ = h.start()
        let c = await h.adapter().request?.credentials
        #expect(c?.password == nil && c?.username == nil)
        #expect(c?.keyPassphrase?.bytesForTest == Array("kp".utf8) && c?.proxyUsername?.bytesForTest == Array("pu".utf8))
        #expect(c?.proxyPassword?.bytesForTest == Array("pp".utf8))
    }

    /// T16: a failed packetFlow start ends its pump; the next start gets a fresh one (not one reading the old flow).
    @Test func failedStartEndsThePump() async {
        let h = Harness(dataPlane: .packetFlow)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        let first = a.request?.pump
        a.finishStart(.failure(.failed(LPTunnelError(.engineFatal))))
        _ = await t.value
        _ = h.start()
        let b = await h.adapter(1)
        #expect(first != nil && b.request?.pump != nil && b.request?.pump !== first)
    }

    // MARK: stopTunnel during a pending start

    @Test(arguments: ["connecting", "establishing", "awaitingAuth"])
    func stopDuringPendingStart(at: String) async {
        let h = Harness()
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        switch at {
        case "establishing":
            h.host.s.withLock { $0.holdApply = true }
            _ = a.requestSettings(Harness.plan)
            #expect(await h.waitPhase(.establishing))
        case "awaitingAuth":
            a.emit { .authRequired(AuthChallenge(kind: .pendingApproval, reason: .initial), epoch: $0) }
            #expect(await h.waitPhase(.awaitingAuth(beforeConnected: true)))
        default: break
        }
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .startCancelled)            // the start completes first, with .startCancelled
        #expect(a.stopCount == 1)                                     // then teardown
        #expect(await h.phase == .idle)
        h.host.releaseApply()
        a.finishStart()                                               // a racing late success changes nothing
        #expect(await h.phase == .idle)
    }

    @Test func stopIsIdempotent() async {
        let h = Harness()
        await h.provision()
        await h.connect()
        await h.controller.stop(reason: .userInitiated)
        await h.controller.stop(reason: .userInitiated)
        #expect(await h.phase == .idle)
        #expect(h.state.load().sessions.count == 1)
        #expect(h.state.load().sessions[0].summary.endReason == "user")
    }

    // MARK: connect deadline (draft 9: no start budget, S2 E14b)

    @Test func noStartBudget() {
        #expect(!Mirror(reflecting: ControllerConfig()).children.contains { $0.label?.lowercased().contains("budget") == true && $0.label != "reassertBudget" })
    }

    @Test(arguments: [(VPNProtocolKind.openVPN, 50), (.wireGuard, 45)])
    func connectDeadlineBoundsEachAttempt(kind: VPNProtocolKind, seconds: Int) async {
        let h = Harness(kind: kind)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()                                     // never finishes
        await h.advance(h.clock, by: .seconds(seconds - 1))
        #expect(await h.phase == .connecting)
        await h.advance(h.clock, by: .seconds(1))
        #expect(h.code(await t.value) == .connectTimeout)
        #expect(await waitUntil { a.stopCount == 1 })
    }

    @Test func connectDeadlineFiresDuringASlowApply() async {
        let h = Harness()
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        h.host.s.withLock { $0.holdApply = true }
        let ticket = a.requestSettings(Harness.plan)
        #expect(await h.waitPhase(.establishing))
        await h.advance(h.clock, by: .seconds(50))
        #expect(h.code(await t.value) == .connectTimeout)
        h.host.releaseApply()
        #expect(await ticket.value() == .failed(.startCancelled))
    }

    @Test func flaggedEndpointMapsTimeoutToInterfaceUnusable() async {
        let h = Harness(flaggedInterface: "bridge100")
        await h.provision()
        let t = h.start()
        _ = await h.adapter()
        await h.advance(h.clock, by: .seconds(50))
        if case .failure(let e) = await t.value { #expect(e.code == .endpointInterfaceUnusable && e.detail == "bridge100") }
        else { Issue.record("start succeeded") }
    }

    // MARK: endpoints (draft 9, S2 E10: no provider DNS under the flag)

    @Test func startEndpointsWinOverTheCacheAndAreCachedOnSuccess() async {
        let h = Harness(state: { pid in
            var st = PersistedTunnelState()
            st.endpointHosts[ProfileKey(ownerUID: 501, profileID: pid)] = ["a.example": ["192.0.2.1"], "b.example": ["192.0.2.2"]]
            return st
        })
        await h.provision()
        let t = h.start(endpoints: ["a.example": ["198.51.100.1"]])
        let a = await h.adapter()
        #expect(a.request?.endpoints == ["a.example": ["198.51.100.1"], "b.example": ["192.0.2.2"]])
        #expect(h.interfaceCheck.checked.last == ["198.51.100.1", "192.0.2.2"])       // the start-time interface check
        _ = await a.requestSettings(Harness.plan).value()
        a.finishStart()
        _ = await t.value
        #expect(h.state.load().endpointHosts[h.key] == ["a.example": ["198.51.100.1"], "b.example": ["192.0.2.2"]])
    }

    @Test(arguments: [(true, false), (false, true)])
    func providerDNSOnlyWithoutTheFlag(killSwitch: Bool, providerDNS: Bool) async {
        let h = Harness(killSwitch: killSwitch)
        await h.provision()
        _ = h.start()
        #expect(await h.adapter().request?.providerDNS == providerDNS)
    }

    @Test func adapterResolutionIsCachedWithoutTheFlag() async {
        let h = Harness()
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.s.withLock { $0.stats = AdapterStats(resolvedEndpoints: ["vpn.example": ["203.0.113.4"]]) }
        _ = await a.requestSettings(Harness.plan).value()
        a.finishStart()
        _ = await t.value
        #expect(await waitUntil { h.state.load().endpointHosts[h.key] == ["vpn.example": ["203.0.113.4"]] })
    }

    // MARK: establishing failures

    @Test func applyThrows() async {
        let h = Harness()
        await h.provision()
        h.host.s.withLock { $0.applyError = LPTunnelError(.networkSettingsFailed) }
        let t = h.start()
        let a = await h.adapter()
        #expect(await a.requestSettings(Harness.plan).value() == .failed(.networkSettingsFailed))
        #expect(h.code(await t.value) == .networkSettingsFailed)
    }

    @Test func killSwitchFullTunnelWithoutDNSHoldsDNSPlanMissing() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        var p = Harness.plan; p.dns = nil
        #expect(await a.requestSettings(p).value() == .failed(.dnsPlanMissing))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.dnsPlanMissing))))
        #expect(h.host.appliedCount == 0)
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .dnsPlanMissing)
    }

    // MARK: before-Connected .fatal rows

    @Test func fatalBeforeConnectedKillSwitchOffFailsTheStart() async {
        let h = Harness()
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.finishStart(.failure(.failed(LPTunnelError(.engineFatal))))
        #expect(h.code(await t.value) == .engineFatal)
        #expect(h.latch == nil && h.state.load().lastErrors[h.key]?.error.code == .engineFatal)
    }

    @Test func fatalEventBeforeConnectedFailsTheStart() async {
        let h = Harness()
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.emit { .fatal(LPTunnelError(.serverIdentityMismatch), epoch: $0) }
        #expect(h.code(await t.value) == .serverIdentityMismatch)
        #expect(await waitUntil { a.stopCount == 1 })
    }

    @Test(arguments: [(LPErrorCode.connectTimeout, StartLatch.Kind.backoff), (.legacyCryptoUnavailable, .hard)])
    func killSwitchBeforeConnectedWithOnDemandRulesArmsLatchAndHolds(code: LPErrorCode, kind: StartLatch.Kind) async {
        let h = Harness(killSwitch: true, onDemandRules: true)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.finishStart(.failure(.failed(LPTunnelError(code))))
        #expect(await h.waitPhase(.held(kind == .hard ? .nonRetryable(code) : .blockedAfterFailure(code))))
        #expect(h.latch?.kind == kind)
        #expect(h.host.s.withLock { $0.reasserting.isEmpty })        // setReasserting never called before Connected
        #expect(h.sink.endedCodes == (kind == .hard ? [code] : []))
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == code)
    }

    @Test func killSwitchManualWithoutOnDemandRulesHasNoLatch() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.engineFatal))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.engineFatal))))
        #expect(h.latch == nil)
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    // MARK: withhold before Connected (draft 9, S2 E14: a failed start is OPEN, a pending one is blocked)

    /// A retryable failure is held (start pending, adapter down) and retried inside the hold with the backoff; the
    /// retry that connects completes the start with success, once.
    @Test func retryableFailureRetriesInsideTheHoldAndConnects() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        a.finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        #expect(await waitUntil { a.stopCount == 1 })                // adapter DOWN while held
        var snap = await h.controller.snapshot()
        #expect(snap.holdBeforeConnected && snap.holdReason == .blockedAfterFailure(.connectTimeout) && snap.attempt == 1)
        #expect(snap.nextRetryAt != nil && snap.lastError?.code == .connectTimeout)
        #expect(h.host.cancelledCodes.isEmpty && h.host.s.withLock { $0.reasserting.isEmpty })
        await h.advance(h.clock, by: .seconds(2))                    // backoff ≤ 1.2 s → the whole start again
        let b = await h.adapter(1)
        snap = await h.controller.snapshot()
        #expect(snap.phase == .connecting && snap.holdBeforeConnected)   // still "blocked, retrying" for the UI
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        #expect(h.code(await t.value) == nil)
        #expect(await h.waitPhase(.connected))
        snap = await h.controller.snapshot()
        #expect(!snap.holdBeforeConnected && snap.holdReason == nil && snap.attempt == 0)
    }

    @Test func nonRetryableHoldNeverRetriesAndTheStopCompletesWithTheHeldError() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.serverIdentityMismatch))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.serverIdentityMismatch))))
        h.clock.advance(by: .seconds(1000)); try? await Task.sleep(for: .milliseconds(10))   // E14b: 1000 s, never stopped
        #expect(h.factory.adapters.count == 1)
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .serverIdentityMismatch)    // §5.5: the held error, not .startCancelled
    }

    @Test func startingFailuresAreHeldToo() async {
        let h = Harness(killSwitch: true)                            // nothing provisioned
        let t = h.start()
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.profileNotProvisioned))))
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .profileNotProvisioned)
    }

    /// Route protection (`enforceRoutes`, split tunnel) keeps failing the start: only includeAllNetworks withholds.
    @Test func routeProtectionFailsTheStartAsBefore() async {
        let h = Harness(killSwitch: true, routeProtection: true)
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.engineFatal))))
        #expect(h.code(await t.value) == .engineFatal)
    }

    /// Round 3 (Codex r3 #1): a profile change never ends a kill-switch start's hold (a failed protected start is open,
    /// and this may be NE's replay that nothing else would start again). It stays held, closed; the user's stop ends it.
    @Test func aChangedProfileKeepsAKillSwitchHold() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.serverIdentityMismatch))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.serverIdentityMismatch))))
        await h.provision(revision: 2)
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await h.phase == .held(.blockedAfterFailure(.serverIdentityMismatch)))
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .serverIdentityMismatch)
        #expect(await h.phase == .idle)
    }

    @Test func newCredentialsRetryAHeldStartAtOnce() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        _ = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.serverIdentityMismatch))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.serverIdentityMismatch))))
        await h.controller.credentialsUpdated(h.pid, ownerUID: h.owner)
        _ = await h.adapter(1)
    }

    /// Review L2, round 3 (Codex r3 #1): new credentials AND a higher revision (one `provision`) while a kill-switch
    /// start's retry is in flight: the attempt is not torn down, it finishes and the start connects. Without a kill
    /// switch the profile change still ends a waiting start (`aWaitingStartEndsWhenTheProfileChanges`).
    @Test func aChangedProfileLeavesAKillSwitchRetryInFlight() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.serverIdentityMismatch))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.serverIdentityMismatch))))
        await h.controller.credentialsUpdated(h.pid, ownerUID: h.owner)     // the retry attempt is now running
        let b = await h.adapter(1)
        await h.provision(revision: 2)
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(b.stopCount == 0)
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        #expect(h.code(await t.value) == nil)
        #expect(await h.waitPhase(.connected))
        #expect(h.factory.adapters.count == 2)
    }

    /// Without a kill switch the round 9 rule stands: a higher revision ends the attempt in flight (the app starts the
    /// new revision; a failed split start is not open).
    @Test func aChangedProfileEndsAStartWithoutAKillSwitch() async {
        let h = Harness()
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        #expect(h.code(await t.value) == .startCancelled)
        #expect(await waitUntil { a.stopCount == 1 })
        #expect(await h.phase == .idle)
    }

    /// Review L4: under the flag no new endpoint IPs can appear inside the hold, so a resolution failure waits for the
    /// user instead of retrying the same empty map every ≤ 60 s.
    @Test func dnsResolutionFailureUnderTheFlagWaitsForTheUser() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.dnsResolutionFailed, detail: "no endpoint IPs"))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.dnsResolutionFailed))))
        #expect(await h.controller.snapshot().nextRetryAt == nil)
        h.clock.advance(by: .seconds(1000)); try? await Task.sleep(for: .milliseconds(10))
        #expect(h.factory.adapters.count == 1)
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await t.value) == .dnsResolutionFailed)
    }

    /// The hold's retry waits on the controller's clock (in production the strict clock, S2: `asyncAfter` fired 3–5 s
    /// late): nothing retries before the deadline.
    @Test func holdRetryWaitsForItsDeadline() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        _ = h.start()
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        await h.advance(h.clock, by: .milliseconds(700))             // backoff 0.8–1.2 s: not yet
        try? await Task.sleep(for: .milliseconds(10))
        #expect(h.factory.adapters.count == 1)
    }

    @Test func nonRetryableBeforeConnectedUnderOnDemandArmsHardLatchAndSessionEnded() async {
        let h = Harness()
        await h.provision()
        let t = h.start(manual: false)
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.pushedOptionRejected))))
        #expect(h.code(await t.value) == .pushedOptionRejected)
        #expect(h.latch?.kind == .hard)
        #expect(h.sink.endedCodes == [.pushedOptionRejected])
    }

    // MARK: epochs

    @Test func staleEpochEventsAndDeadlinesChangeNothing() async {
        let h = Harness()
        await h.provision()
        let a = await h.connect()
        // the connect deadline armed before Connected: advancing past it does nothing now
        await h.advance(h.clock, by: .seconds(60))
        #expect(await h.phase == .connected)
        // an event under an old epoch is dropped: events are handled in order, so once the current-epoch event that
        // follows it has taken effect, the stale one has been processed (no real-time sleep)
        a.emit(.fatal(LPTunnelError(.engineFatal), epoch: a.epoch &- 1))
        a.emit { .reconnecting(.engine, epoch: $0) }
        #expect(await h.waitPhase(.reasserting(.engine)))
        #expect(h.host.cancelledCodes.isEmpty && h.sink.endedCodes.isEmpty)
    }

    /// The start's NE completion runs exactly once: late adapter results and events of the failed attempt neither
    /// complete it again nor revive the session (and a CheckedContinuation double resume would trap the test).
    @Test func secondStartCallCompletesOnce() async {
        let h = Harness()
        await h.provision()
        let calls = Mutex(0)
        let done = CompletionOnce<LPTunnelError?> { _ in calls.withLock { $0 += 1 } }
        let c = h.controller, req = StartRequest(options: StartOptions(isManual: true), configuration: h.config())
        let t = Task { do throws(LPTunnelError) { try await c.start(req); done(nil) } catch { done(error) } }
        let a = await h.adapter()
        a.finishStart(.failure(.failed(LPTunnelError(.engineFatal))))
        await t.value
        a.finishStart()                                                // late second result
        a.emit(.reconnected(epoch: a.epoch))
        a.emit(.fatal(LPTunnelError(.engineDied), epoch: a.epoch))
        #expect(!done(nil))                                            // already completed
        #expect(calls.withLock { $0 } == 1)
        #expect(await h.phase == .idle && h.host.cancelledCodes.isEmpty)
    }
}

