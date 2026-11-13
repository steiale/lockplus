import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// 2.0.2 item 3 (PLAN §3.1): the arm / replay / unattended table, decided before the 2.0.1 start guard.
@Suite(.timeLimit(.minutes(1))) struct StartAuthorisationTests {
    /// Drives a start (already issued as `t`) to Connected.
    func connected(_ h: Harness, _ t: Task<Result<Void, LPTunnelError>, Never>) async {
        let n = h.factory.adapters.count - 1
        let a = await h.adapter(max(n, 0))
        _ = await a.requestSettings(Harness.plan).value()
        a.finishStart()
        if case .failure(let e) = await t.value { Issue.record("start failed \(e.code)") }
        _ = await h.waitPhase(.connected)
    }

    @Test func armedManualStartIsHonouredOnce() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        #expect(h.state.load().authorisedStarts[h.key]?.nonce == nonce)
        // The arm is consumed: the same nonce again, with no replay record after a user stop, is refused.
        await h.controller.stop(reason: .userInitiated)
        #expect(h.state.load().authorisedStarts[h.key] == nil)
        #expect(h.code(await h.start(nonce: nonce).value) == .startNotAuthorised)
    }

    @Test func armIsConsumedByTheFirstStart() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        // A second start with the arm's nonce while the first session runs is a replay of THAT session (NE's restart), not
        // a second arm: it is the one thing the persisted record admits. After the record is gone it is refused.
        var st = h.state.load(); st.authorisedStarts[h.key] = nil; h.state.save(st)
        let c2 = Harness(pid: h.pid, authorisation: true, state: { _ in st })
        await c2.provision()
        #expect(c2.code(await c2.start(nonce: nonce).value) == .startNotAuthorised)
    }

    @Test func armExpiresAfter15s() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let exp = await h.controller.armStart(profileID: h.pid, ownerUID: h.owner, nonce: UUID())
        #expect(exp == h.wall.now.addingTimeInterval(15))
        let n = UUID()
        _ = await h.controller.armStart(profileID: h.pid, ownerUID: h.owner, nonce: n)
        h.wall.advance(15)
        #expect(h.code(await h.start(nonce: n).value) == .startNotAuthorised)
        // Just inside the window it is honoured.
        let m = UUID()
        _ = await h.controller.armStart(profileID: h.pid, ownerUID: h.owner, nonce: m)
        h.wall.advance(14.9)
        await connected(h, h.start(nonce: m))
    }

    @Test func nonceMismatchRefusedAndDoesNotBurnTheArm() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let n = UUID()
        _ = await h.controller.armStart(profileID: h.pid, ownerUID: h.owner, nonce: n)
        #expect(h.code(await h.start(nonce: UUID()).value) == .startNotAuthorised)
        let t = h.start(nonce: n)
        await connected(h, t)
    }

    @Test func armOfAnotherUidDoesNotAuthorise() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let n = UUID()
        _ = await h.controller.armStart(profileID: h.pid, ownerUID: 502, nonce: n)     // cfg.ownerUID is 501
        #expect(h.code(await h.start(nonce: n).value) == .startNotAuthorised)
        #expect(h.factory.adapters.isEmpty)
    }

    @Test func manualWithoutNonceRefused() async {
        let h = Harness(authorisation: true)
        await h.provision()
        _ = await h.controller.armStart(profileID: h.pid, ownerUID: h.owner, nonce: UUID())
        #expect(h.code(await h.start().value) == .startNotAuthorised)                   // a 2.0.1 app, or System Settings
    }

    @Test func unattendedStartHonouredOnlyWithOnDemandRules() async {
        let manualProfile = Harness(authorisation: true)
        await manualProfile.provision()
        #expect(manualProfile.code(await manualProfile.start(manual: false).value) == .startNotAuthorised)   // scutil / System Settings
        let autoConnect = Harness(onDemandRules: true, authorisation: true)
        await autoConnect.provision()
        let t = autoConnect.start(manual: false)
        await connected(autoConnect, t)
    }

    @Test func aManualStartWithOnDemandRulesStillNeedsItsNonce() async {
        let h = Harness(onDemandRules: true, authorisation: true)
        await h.provision()
        #expect(h.code(await h.start(manual: true).value) == .startNotAuthorised)
    }

    @Test func foreignOptionsCarryingANonceAreNotManual() async {
        let n = UUID()
        let o = StartOptions(["lp.startNonce": n.uuidString as NSString])
        #expect(!o.isManual && o.nonce == nil)
        let m = StartOptions(["lp.manual": NSNumber(value: 1), "lp.startNonce": n.uuidString as NSString])
        #expect(m.isManual && m.nonce == n)
        #expect(StartOptions(["lp.manual": NSNumber(value: 1), "lp.startNonce": "not-a-uuid" as NSString]).nonce == nil)
        #expect(StartOptions(["lp.manual": NSNumber(value: 1), "lp.startNonce": NSNumber(value: 1)]).nonce == nil)
    }

    @Test func replayAfterCrashHonoured() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        let persisted = h.state.load()
        // The extension process dies and NE restarts the provider with the same options: a new controller, the same state file.
        let h2 = Harness(pid: h.pid, authorisation: true, state: { _ in persisted })
        await h2.provision()
        await connected(h2, h2.start(nonce: nonce))
        #expect(h2.state.load().authorisedStarts[h2.key]?.nonce == nonce)
    }

    @Test func replayWithADifferentNonceIsRefused() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (_, t) = await h.armedStart()
        await connected(h, t)
        let persisted = h.state.load()
        let h2 = Harness(pid: h.pid, authorisation: true, state: { _ in persisted })
        await h2.provision()
        #expect(h2.code(await h2.start(nonce: UUID()).value) == .startNotAuthorised)
    }

    @Test func replayAfterUserStopRefused() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        await h.controller.stop(reason: .userInitiated)
        let persisted = h.state.load()
        let h2 = Harness(pid: h.pid, authorisation: true, state: { _ in persisted })
        await h2.provision()
        #expect(h2.code(await h2.start(nonce: nonce).value) == .startNotAuthorised)
    }

    @Test(arguments: [StopReason.noNetwork, .providerFailed, .sleep, .appUpdate, .superseded, .other(3)])
    func nonUserEndsKeepTheAuthorisation(_ reason: StopReason) async {
        let h = Harness(killSwitch: true, authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        await h.controller.stop(reason: reason)
        let persisted = h.state.load()
        #expect(persisted.authorisedStarts[h.key]?.nonce == nonce)
        let h2 = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in persisted })
        await h2.provision()
        await connected(h2, h2.start(nonce: nonce))
    }

    /// Round 1 (Fable L5): NE never restarts a session without a kill switch; its record goes when it ends.
    @Test(arguments: [StopReason.noNetwork, .providerFailed, .superseded])
    func theEndOfASessionWithoutAKillSwitchDropsItsRecord(_ reason: StopReason) async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        #expect(h.state.load().authorisedStarts[h.key]?.nonce == nonce)
        await h.controller.stop(reason: reason)
        #expect(h.state.load().authorisedStarts[h.key] == nil)
    }

    /// Round 1 (Fable H1a): "Save Only" on a connected kill-switch profile provisions a higher revision and keeps the
    /// session up. NE's later restart of it (a new extension process, the same state file) replays the options with the
    /// nonce and is honoured.
    @Test func aHigherRevisionProvisionKeepsTheLiveSessionsAuthorisation() async {
        let h = Harness(killSwitch: true, authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        await h.provision(revision: 2)
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)
        #expect(await h.phase == .connected)
        #expect(h.state.load().authorisedStarts[h.key]?.nonce == nonce)
        let persisted = h.state.load()
        for revision: UInt64 in [1, 2] {               // NE replays the configuration it has: the old or the re-saved one
            let h2 = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in persisted })
            await h2.provision(revision: 2)
            await connected(h2, h2.start(revision: revision, nonce: nonce))
        }
    }

    /// Round 1 (Fable H1b): an unattended kill-switch session whose on-demand rules went away while it ran (another
    /// Auto-Connect profile chosen, Stay Connected off) is still restarted by NE with no options: honoured.
    @Test func anUnattendedSessionsRestartIsHonouredAfterItsRulesWentAway() async {
        let h = Harness(killSwitch: true, onDemandRules: true, authorisation: true)
        await h.provision()
        await connected(h, h.start(manual: false))
        let rec = h.state.load().authorisedStarts[h.key]
        #expect(rec != nil && rec?.isUnattended == true)
        let persisted = h.state.load()
        let h2 = Harness(pid: h.pid, killSwitch: true, onDemandRules: false, authorisation: true, state: { _ in persisted })
        await h2.provision()
        await connected(h2, h2.start(manual: false))
        // A manual start is still not admitted by an unattended record (no nonce to match).
        await h2.controller.stop(reason: .providerFailed)
        let h3 = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in h2.state.load() })
        await h3.provision()
        #expect(h3.code(await h3.start(manual: true).value) == .startNotAuthorised)
    }

    /// Round 1 (Codex 4), round 2 (Codex r2 #2): the owner withdrew unattended consent: a record of a session NE never
    /// restarts goes unless its session is live; armed records, other uids' records and a kill-switch session's record stay.
    @Test func revokeUnattendedClearsIdleUnattendedRecordsOnly() async {
        let h = Harness(killSwitch: true, onDemandRules: true, authorisation: true)
        await h.provision()
        await connected(h, h.start(manual: false))
        let armedKey = ProfileKey(ownerUID: h.owner, profileID: UUID())
        let foreign = ProfileKey(ownerUID: 502, profileID: h.pid)
        let idle = ProfileKey(ownerUID: h.owner, profileID: UUID())
        var st = h.state.load()
        st.authorisedStarts[armedKey] = AuthorisedStart(nonce: UUID(), at: h.wall.now)
        st.authorisedStarts[foreign] = AuthorisedStart(nonce: nil, at: h.wall.now)
        st.authorisedStarts[idle] = AuthorisedStart(nonce: nil, at: h.wall.now)
        h.state.save(st)
        let h2 = Harness(pid: h.pid, killSwitch: true, onDemandRules: true, authorisation: true, state: { _ in st })
        await h2.provision()
        await connected(h2, h2.start(manual: false))                       // the live session (a replay keeps its record)
        await h2.controller.revokeUnattended(keeping: [], ownerUID: h.owner)
        let after = h2.state.load().authorisedStarts
        #expect(after[h2.key]?.isUnattended == true)                        // live: kept (H1b)
        #expect(after[armedKey] != nil && after[foreign] != nil && after[idle] == nil)
        // Round 2 (Codex r2 #2): the kill-switch session ends without a user stop (or its process dies); a revoke in the gap
        // before NE's restart keeps the record, and NE's restart is admitted.
        await h2.controller.stop(reason: .providerFailed)
        await h2.controller.revokeUnattended(keeping: [], ownerUID: h.owner)
        #expect(h2.state.load().authorisedStarts[h2.key]?.isUnattended == true)
        let h3 = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in h2.state.load() })
        await h3.controller.revokeUnattended(keeping: [], ownerUID: h.owner)          // a fresh process (a crash), revoked at once
        await h3.provision()
        await connected(h3, h3.start(manual: false))
    }

    /// Round 2 (Codex r2 #2): crash → revoke → NE's replay is admitted, also for an armed kill-switch session.
    @Test func aRevokeInTheRestartGapNeverBreaksNEsReplay() async {
        let h = Harness(killSwitch: true, authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        let crashed = h.state.load()                                          // the process dies with the session running
        let h2 = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in crashed })
        await h2.controller.revokeUnattended(keeping: [], ownerUID: h.owner)
        await h2.provision()
        await connected(h2, h2.start(nonce: nonce))
    }

    /// Round 2: a session without a kill switch whose process died before its end dropped the record (NE never restarts
    /// it): the revoke takes the leftover record.
    @Test func aRevokeTakesALeftoverRecordOfASessionWithoutAKillSwitch() async {
        let h = Harness(onDemandRules: true, authorisation: true)
        await h.provision()
        await connected(h, h.start(manual: false))
        let crashed = h.state.load()
        #expect(crashed.authorisedStarts[h.key]?.killSwitch == false)
        let h2 = Harness(pid: h.pid, authorisation: true, state: { _ in crashed })
        await h2.controller.revokeUnattended(keeping: [], ownerUID: h.owner)
        #expect(h2.state.load().authorisedStarts[h.key] == nil)
        await h2.provision()
        #expect(h2.code(await h2.start(manual: false).value) == .startNotAuthorised)
    }

    @Test func anUnattendedRecordEndsWithTheUsersStop() async {
        let h = Harness(killSwitch: true, onDemandRules: true, authorisation: true)
        await h.provision()
        await connected(h, h.start(manual: false))
        await h.controller.stop(reason: .userInitiated)
        #expect(h.state.load().authorisedStarts[h.key] == nil)
        let persisted = h.state.load()
        let h2 = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in persisted })
        await h2.provision()
        #expect(h2.code(await h2.start(manual: false).value) == .startNotAuthorised)
    }

    /// Round 1 (Fable L8): an armed kill-switch session ended by a server-side failure keeps its record for NE's restart,
    /// but a later System Settings or `scutil --nc start` (no options) is not that restart: refused.
    @Test func anArmedRecordNeverAdmitsANonManualStart() async {
        let h = Harness(killSwitch: true, authorisation: true)
        await h.provision()
        let (_, t) = await h.armedStart()
        await connected(h, t)
        await h.controller.stop(reason: .providerFailed)
        let persisted = h.state.load()
        #expect(persisted.authorisedStarts[h.key] != nil)
        let h2 = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in persisted })
        await h2.provision()
        #expect(h2.code(await h2.start(manual: false).value) == .startNotAuthorised)
    }

    /// Round 1 (Fable L5): past the cap the oldest record goes, never the one just admitted.
    @Test func theCapEvictsTheOldestRecordOnly() async {
        var st = PersistedTunnelState()
        let base = Date(timeIntervalSince1970: 1_600_000_000)
        let keys = (0..<PersistedTunnelState.maxAuthorisedStarts).map { _ in ProfileKey(ownerUID: 502, profileID: UUID()) }
        for (i, k) in keys.enumerated() { st.authorisedStarts[k] = AuthorisedStart(nonce: UUID(), at: base.addingTimeInterval(Double(i))) }
        let h = Harness(killSwitch: true, authorisation: true, state: { _ in st })
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        let after = h.state.load().authorisedStarts
        #expect(after.count == PersistedTunnelState.maxAuthorisedStarts)
        #expect(after[h.key]?.nonce == nonce)
        #expect(after[keys[0]] == nil && after[keys[1]] != nil)
    }

    @Test func configurationRemovedClearsTheAuthorisation() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (_, t) = await h.armedStart()
        await connected(h, t)
        await h.controller.stop(reason: .configurationRemoved)
        #expect(h.state.load().authorisedStarts[h.key] == nil)
    }

    @Test func profileRemovedClearsAuthorisationAndArm() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        let pending = UUID()
        _ = await h.controller.armStart(profileID: h.pid, ownerUID: h.owner, nonce: pending)
        await h.controller.profileRemoved(h.pid, ownerUID: h.owner)
        #expect(h.state.load().authorisedStarts[h.key] == nil)
        await h.controller.stop(reason: .userInitiated)
        #expect(h.code(await h.start(nonce: nonce).value) == .startNotAuthorised)
        #expect(h.code(await h.start(nonce: pending).value) == .startNotAuthorised)
    }

    @Test func secretsWipedClearsOnlyTheCallersAuthorisations() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (_, t) = await h.armedStart()
        await connected(h, t)
        var st = h.state.load()
        let foreign = ProfileKey(ownerUID: 502, profileID: UUID())
        st.authorisedStarts[foreign] = AuthorisedStart(nonce: UUID(), at: h.wall.now)
        h.state.save(st)
        let h2 = Harness(pid: h.pid, authorisation: true, state: { _ in st })
        await h2.controller.secretsWiped(ownerUID: h.owner)
        #expect(h2.state.load().authorisedStarts.keys.contains(h.key) == false)
        #expect(h2.state.load().authorisedStarts.keys.contains(foreign))
    }

    @Test func neitherASameRevisionRetryNorAHigherRevisionClearsTheAuthorisation() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        await h.controller.payloadCommitted(h.pid, ownerUID: h.owner, revision: 1)      // a same-revision retry
        #expect(h.state.load().authorisedStarts[h.key]?.nonce == nonce)
        await h.controller.profileProvisioned(h.pid, ownerUID: h.owner, revision: 2)    // round 1 (Fable H1a): kept
        #expect(h.state.load().authorisedStarts[h.key]?.nonce == nonce)
    }

    @Test func aRefusedStartReadsNoSecretAndLeavesNoEffect() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let before = await h.secrets.gets
        #expect(h.code(await h.start().value) == .startNotAuthorised)
        #expect(await h.secrets.gets == before)
        #expect(h.factory.adapters.isEmpty)
        #expect(await h.phase == .idle)
        #expect(h.state.load().lastErrors[h.key]?.error.code == .startNotAuthorised)
        #expect(h.state.load().latches.isEmpty)
    }

    @Test func aRefusedStartLeavesARunningSessionAlone() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let (_, t) = await h.armedStart()
        await connected(h, t)
        #expect(h.code(await h.start().value) == .startNotAuthorised)
        #expect(await h.phase == .connected)
        #expect(h.factory.adapters.count == 1 && h.factory.adapters[0].stopCount == 0)
    }

    @Test func aStartWithoutAParseableConfigurationKeepsTheOldPath() async {
        // No profile to authorise: it reads nothing and ends profileInvalid (re-check N3 keeps its protocol flags in the guard).
        let h = Harness(authorisation: true)
        let req = StartRequest(options: StartOptions(isManual: false), configuration: nil)
        let c = h.controller
        let r: LPErrorCode? = await { () -> LPErrorCode? in
            do throws(LPTunnelError) { try await c.start(req); return nil } catch { return error.code }
        }()
        #expect(r == .profileInvalid)
        #expect(await h.secrets.gets == 0)
    }

    // MARK: pure table

    @Test func ninthArmDropsOldest() {
        var a = StartArms()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let keys = (0..<9).map { _ in ProfileKey(ownerUID: 501, profileID: UUID()) }
        let other = ProfileKey(ownerUID: 502, profileID: UUID())
        var nonces: [UUID] = []
        _ = a.arm(other, nonce: UUID(), now: now)
        for k in keys { let n = UUID(); nonces.append(n); _ = a.arm(k, nonce: n, now: now) }
        #expect(a.count(forOwner: 501) == StartArms.maxPerOwner && a.count(forOwner: 502) == 1)
        #expect(a.decide(keys[0], options: StartOptions(isManual: true, nonce: nonces[0]), hasOnDemandRules: false, authorised: [:], now: now) == .refused)
        #expect(a.decide(keys[8], options: StartOptions(isManual: true, nonce: nonces[8]), hasOnDemandRules: false, authorised: [:], now: now) == .armed(nonces[8]))
    }

    @Test func armsAreOneUseAndPerProfile() {
        var a = StartArms()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let k = ProfileKey(ownerUID: 501, profileID: UUID()), n1 = UUID(), n2 = UUID()
        _ = a.arm(k, nonce: n1, now: now)
        _ = a.arm(k, nonce: n2, now: now.addingTimeInterval(1))            // one pending start per profile: n1 is replaced
        let o: (UUID) -> StartOptions = { StartOptions(isManual: true, nonce: $0) }
        #expect(a.decide(k, options: o(n1), hasOnDemandRules: false, authorised: [:], now: now.addingTimeInterval(2)) == .refused)
        #expect(a.decide(k, options: o(n2), hasOnDemandRules: false, authorised: [:], now: now.addingTimeInterval(2)) == .armed(n2))
        #expect(a.decide(k, options: o(n2), hasOnDemandRules: false, authorised: [:], now: now.addingTimeInterval(2)) == .refused)
        let rec = AuthorisedStart(nonce: n2, at: now)
        #expect(a.decide(k, options: o(n2), hasOnDemandRules: false, authorised: [k: rec], now: now) == .replay(rec))
    }

    @Test func theNonManualRowOfTheTable() {
        var a = StartArms()
        let now = Date(timeIntervalSince1970: 1_000_000), k = ProfileKey(ownerUID: 501, profileID: UUID())
        let other = ProfileKey(ownerUID: 502, profileID: k.profileID)
        let auto = StartOptions(isManual: false)
        let unattended = [k: AuthorisedStart(nonce: nil, at: now)], armed = [k: AuthorisedStart(nonce: UUID(), at: now)]
        #expect(a.decide(k, options: auto, hasOnDemandRules: true, authorised: [:], now: now) == .unattended)
        #expect(a.decide(k, options: auto, hasOnDemandRules: false, authorised: [:], now: now) == .refused)
        #expect(a.decide(k, options: auto, hasOnDemandRules: false, authorised: unattended, now: now) == .replay(unattended[k]!))
        #expect(a.decide(k, options: auto, hasOnDemandRules: false, authorised: armed, now: now) == .refused)
        #expect(a.decide(other, options: auto, hasOnDemandRules: false, authorised: unattended, now: now) == .refused)
        // A manual start never matches an unattended record (a nil nonce is not a nonce).
        #expect(a.decide(k, options: StartOptions(isManual: true), hasOnDemandRules: false, authorised: unattended, now: now) == .refused)
    }

    @Test func aWallClockSetBackInvalidatesAnArm() {
        var a = StartArms()
        let now = Date(timeIntervalSince1970: 1_000_000), k = ProfileKey(ownerUID: 501, profileID: UUID()), n = UUID()
        _ = a.arm(k, nonce: n, now: now)
        #expect(a.decide(k, options: StartOptions(isManual: true, nonce: n), hasOnDemandRules: false, authorised: [:],
                         now: now.addingTimeInterval(-1)) == .refused)
    }

    @Test func authorisationsSurviveTheStateFileAndOldFilesDecodeEmpty() throws {
        var s = PersistedTunnelState()
        let k = ProfileKey(ownerUID: 501, profileID: UUID()), n = UUID(), at = Date(timeIntervalSince1970: 1_700_000_000)
        s.authorisedStarts[k] = AuthorisedStart(nonce: n, at: at)
        let d = try PropertyListEncoder.binary.encode(s)
        #expect(try PropertyListDecoder().decode(PersistedTunnelState.self, from: d).authorisedStarts[k] == AuthorisedStart(nonce: n, at: at))
        // A 2.0.1 file: same schema, no `authorisedStarts` key.
        var dict = try #require(try PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any])
        dict["authorisedStarts"] = nil
        let old = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let decoded = try PropertyListDecoder().decode(PersistedTunnelState.self, from: old)
        #expect(decoded.authorisedStarts.isEmpty && decoded.schema == PersistedTunnelState.currentSchema)
        // An unattended record (no nonce) round-trips.
        var u = PersistedTunnelState()
        u.authorisedStarts[k] = AuthorisedStart(nonce: nil, at: at)
        let ud = try PropertyListEncoder.binary.encode(u)
        #expect(try PropertyListDecoder().decode(PersistedTunnelState.self, from: ud).authorisedStarts[k]?.isUnattended == true)
    }

    // MARK: Round 2 (Fable L1, L2, L4)

    /// L2: NE never replays a session across a reboot. A record carries its boot session; one of another boot admits
    /// nothing and is gone when the controller loads.
    @Test func aRecordOfAnotherBootAdmitsNothing() async {
        let h = Harness(killSwitch: true, onDemandRules: true, authorisation: true, bootSession: "boot-A")
        await h.provision()
        await connected(h, h.start(manual: false))
        await h.controller.stop(reason: .providerFailed)
        let persisted = h.state.load()
        #expect(persisted.authorisedStarts[h.key]?.boot == "boot-A")
        let sameBoot = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in persisted }, bootSession: "boot-A")
        await sameBoot.provision()
        await connected(sameBoot, sameBoot.start(manual: false))          // NE's restart in the same boot: honoured
        let nextBoot = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in persisted }, bootSession: "boot-B")
        #expect(nextBoot.state.load().authorisedStarts.isEmpty)             // dropped (and saved) at load
        await nextBoot.provision()
        #expect(nextBoot.code(await nextBoot.start(manual: false).value) == .startNotAuthorised)
    }

    /// L4: an unattended admission keeps the nonce of the armed start before it (and a revoke keeps a kill-switch
    /// session's record whole): NE's restart with the earlier manual start's options is still honoured.
    @Test func anUnattendedAdmissionKeepsTheArmedNonceAndARevokeKeepsItToo() async {
        let h = Harness(killSwitch: true, onDemandRules: true, authorisation: true)
        await h.provision()
        let (nonce, t) = await h.armedStart()
        await connected(h, t)
        await h.controller.stop(reason: .providerFailed)
        let h1 = Harness(pid: h.pid, killSwitch: true, onDemandRules: true, authorisation: true, state: { _ in h.state.load() })
        await h1.provision()
        await connected(h1, h1.start(manual: false))                       // on-demand brings it back
        var rec = h1.state.load().authorisedStarts[h.key]
        #expect(rec?.nonce == nonce && rec?.isUnattended == true)
        await h1.controller.stop(reason: .providerFailed)
        await h1.controller.revokeUnattended(keeping: [], ownerUID: h.owner)
        rec = h1.state.load().authorisedStarts[h.key]
        #expect(rec?.nonce == nonce && rec?.isUnattended == true && rec?.killSwitch == true)
        let h2 = Harness(pid: h.pid, killSwitch: true, authorisation: true, state: { _ in h1.state.load() })
        await h2.provision()
        await connected(h2, h2.start(nonce: nonce))
    }

    /// L4: a revoke of a record without a kill switch takes only the unattended fact; the armed nonce stays.
    @Test func aRevokeKeepsAnArmedNonce() async {
        let h = Harness(authorisation: true)
        await h.provision()
        let k = ProfileKey(ownerUID: h.owner, profileID: UUID()), n = UUID()
        var st = h.state.load()
        st.authorisedStarts[k] = AuthorisedStart(nonce: n, at: h.wall.now, unattended: true)
        h.state.save(st)
        let h2 = Harness(pid: h.pid, authorisation: true, state: { _ in st })
        await h2.controller.revokeUnattended(keeping: [], ownerUID: h.owner)
        let rec = h2.state.load().authorisedStarts[k]
        #expect(rec?.nonce == n && rec?.isUnattended == false)
    }

    /// L1, L3: the request names the profiles that KEEP consent; every other unattended record of the caller goes.
    @Test func aRevokeKeepsTheNamedProfilesOnly() async {
        let h = Harness(killSwitch: true, onDemandRules: true, authorisation: true)
        await h.provision()
        await connected(h, h.start(manual: false))
        let kept = ProfileKey(ownerUID: h.owner, profileID: UUID()), gone = ProfileKey(ownerUID: h.owner, profileID: UUID())
        var st = h.state.load()
        st.authorisedStarts[kept] = AuthorisedStart(nonce: nil, at: h.wall.now)
        st.authorisedStarts[gone] = AuthorisedStart(nonce: nil, at: h.wall.now)
        h.state.save(st)
        let h2 = Harness(pid: h.pid, killSwitch: true, onDemandRules: true, authorisation: true, state: { _ in st })
        await h2.provision()
        await connected(h2, h2.start(manual: false))
        await h2.controller.revokeUnattended(keeping: [kept.profileID], ownerUID: h.owner)
        let after = h2.state.load().authorisedStarts
        #expect(after[kept] != nil && after[gone] == nil && after[h2.key] != nil)
    }
}
