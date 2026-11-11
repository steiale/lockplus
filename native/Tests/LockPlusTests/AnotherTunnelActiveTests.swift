import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import Testing
@testable import LockPlus

/// 2.0.1 start guard: the extension refuses a start made outside the app (System Settings, `scutil --nc start`) beside
/// another running LockPlus session with `.anotherTunnelActive` (DESIGN §7.2), and ends a session without the kill switch
/// for a kill-switch profile's start (`.supersededByKillSwitch`, review H1). The app says so for that profile, never
/// silently, never as "disconnected unexpectedly", leaves the running session's hero alone, and trusts a refusal only
/// when the snapshot dates it to this attempt (review L1).
@MainActor @Suite("2.0.1: another LockPlus tunnel active", .serialized, .timeLimit(.minutes(1)))
struct AnotherTunnelActiveTests {
    let t4 = OnDemandPause4Tests()
    let nn = NoNetworkRestartTests()
    var refused: NSError { LPTunnelError(.anotherTunnelActive, detail: "another LockPlus tunnel is active") as NSError }
    var superseded: NSError { LPTunnelError(.supersededByKillSwitch, detail: "another LockPlus profile with the kill switch took over") as NSError }

    func never(_ condition: () -> Bool) async -> Bool { await t4.never(condition) }

    /// What the extension's snapshot says about `id`'s last error (the fake answers one snapshot for every profile).
    func snapshot(_ w: NoNetworkRestartTests.World, _ id: UUID, _ code: LPErrorCode = .anotherTunnelActive, at: Date = Date()) {
        w.h.service.state.withLock { $0.snapshot = TunnelSnapshot(profileID: id, lastError: LPError(code), lastErrorAt: at) }
    }

    func world() async throws -> (NoNetworkRestartTests.World, Profile) {
        let w = try await nn.world(NoNetworkRestartTests.online)
        let split = try await w.h.add("Split.conf", Harness.splitConf, killSwitch: false)
        // The S12 launch rule runs once, on the first snapshot: spend it on an empty one, so the fake's single snapshot
        // (it answers every profile) never surfaces a test's refusal as a launch error under load.
        w.h.env.connection.apply(snapshot: TunnelSnapshot(profileID: split.id), for: split.id)
        return (w, split)
    }

    func refuse(_ w: NoNetworkRestartTests.World, _ id: UUID, seenConnecting: Bool = false) {
        w.h.managers.lastError = refused
        if seenConnecting { w.h.managers.emit(id, .connecting) }
        w.h.managers.emit(id, .disconnecting)
        w.h.managers.emit(id, .disconnected)
    }

    func problems(_ w: NoNetworkRestartTests.World, _ name: String) -> Int {
        w.h.env.profiles.problems.filter { $0.message.contains(name) && $0.message.contains("another LockPlus") }.count
    }

    @Test func theErrorsMapToTheirCodesAndCopy() {
        let (observed, detail) = ConnectionStore.observedError(refused)
        #expect(observed.code == .anotherTunnelActive)
        #expect(detail == "another LockPlus tunnel is active")
        #expect(LPErrorCode.anotherTunnelActive.message() == "Another LockPlus profile is connected. Disconnect it first.")
        #expect(LPErrorCode.anotherTunnelActive.reason() == "another LockPlus profile is connected")
        #expect(LPErrorCode.anotherTunnelActive.causeReason() == "another LockPlus profile was connected")
        let unseen = LPErrorCode.unseenSessionDetail
        #expect(LPErrorCode.anotherTunnelActive.message(detail: unseen)
                == "Another LockPlus connection is active: another user's on this Mac, or one LockPlus can't show. It has to end first.")
        #expect(LPErrorCode.anotherTunnelActive.reason(detail: unseen) == "another LockPlus connection is active (another user's, or one LockPlus can't show)")
        #expect(LPErrorCode.anotherTunnelActive.causeReason(detail: unseen) == "another LockPlus connection was active")
        #expect(ConnectionStore.observedError(superseded).0.code == .supersededByKillSwitch)
        #expect(LPErrorCode.supersededByKillSwitch.message() == "Another LockPlus profile with the kill switch took over, so this one was disconnected.")
        #expect(LPErrorCode.supersededByKillSwitch.reason() == "another LockPlus profile with the kill switch took over")
        #expect(LPErrorCode.supersededByKillSwitch.causeReason() == "another LockPlus profile with the kill switch took over")
    }

    /// The refused start's `.connecting` is never delivered (`.disconnecting` → `.disconnected` only), split profile:
    /// a Diagnostics problem names it; the running session stays current with no error.
    @Test func aRefusalBesideARunningSessionIsAProblem() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        #expect(w.h.env.connection.currentID == w.work.id)
        snapshot(w, split.id)
        refuse(w, split.id)
        #expect(await eventually { problems(w, "Split") == 1 })
        #expect(w.h.env.profiles.problems.contains { $0.message.contains("another LockPlus profile is connected") })
        #expect(w.h.env.connection.currentID == w.work.id)
        #expect(w.h.env.connection.observedError == nil)
        #expect(w.h.managers.stops.isEmpty)                             // the running session is never touched
    }

    /// Review L3: NE retrying the start (on-demand) beside the running session: one Diagnostics line, not one per try.
    @Test func repeatedRefusalsLeaveOneProblemLine() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        for _ in 0..<3 {
            snapshot(w, split.id)
            refuse(w, split.id)
            _ = await eventually { problems(w, "Split") >= 1 }
        }
        #expect(await never { problems(w, "Split") > 1 })
    }

    /// Review L1: a sticky older refusal (the snapshot dates it long before this end) beside a running session: nothing.
    @Test func aStaleRefusalShowsNothing() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        snapshot(w, split.id, at: Date().addingTimeInterval(-3600))
        refuse(w, split.id)
        #expect(await never { problems(w, "Split") > 0 })
        #expect(w.h.env.connection.observedError == nil)
    }

    /// Review L1: a session of B that was connected and ends elsewhere, with B's earlier refusal still sticky: no 222 copy,
    /// and the disconnect is a "disconnected unexpectedly" like any other.
    @Test func aConnectedSessionsEndNeverReadsAsARefusal() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        var notices: [ConnectionNotice] = []
        w.h.env.connection.onNotice = { notices.append($0) }
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .connected)
        snapshot(w, split.id)                                           // even "fresh": a connected session wasn't refused
        w.h.managers.lastError = refused
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { notices.contains(.stoppedUnexpectedly(split.id)) })
        #expect(w.h.env.connection.observedError?.code != .anotherTunnelActive)
    }

    /// Review L2: nothing this user can see is active (another user's session, or one LockPlus can't address): the hero
    /// follows the refused profile with the copy that doesn't ask to disconnect it.
    @Test func aRefusalBesideAnUnseenSessionSaysSo() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        snapshot(w, split.id)
        refuse(w, split.id)
        #expect(await eventually { w.h.env.connection.observedError?.code == .anotherTunnelActive })
        #expect(w.h.env.connection.currentID == split.id)
        #expect(w.h.env.connection.errorDetail == LPErrorCode.unseenSessionDetail)
    }

    /// A kill-switch profile without on-demand: the issued-start hold ("may restart") ends at once, since NE doesn't
    /// restart the extension's own refusal, the problem says why, and (review H1) a notification says its kill switch
    /// isn't active.
    @Test func aKillSwitchRefusalEndsTheHoldIsAProblemAndNotifies() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, split)
        var notices: [ConnectionNotice] = []
        w.h.env.connection.onNotice = { notices.append($0) }
        snapshot(w, w.work.id)
        refuse(w, w.work.id)
        #expect(await eventually { problems(w, w.work.name) == 1 })
        #expect(await eventually { w.h.env.connection.startHold == nil })
        #expect(w.h.env.connection.currentID == split.id)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
        #expect(notices.contains(.killSwitchStartRefused(w.work.id)))
        #expect(!notices.contains(.stoppedUnexpectedly(w.work.id)))
    }

    /// 2.0.1 E2E F1: the refused start's `.connecting` was delivered (27.2). The hero stays on the profile NE still
    /// reports connected (never "not protected" with Connect on it); the refusal is a Diagnostics line and the refused
    /// profile's own detail note; no "disconnected unexpectedly" notification goes out.
    @Test func aRefusalSeenConnectingNeverTakesTheHeroFromTheConnectedProfile() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        var notices: [ConnectionNotice] = []
        w.h.env.connection.onNotice = { notices.append($0) }
        snapshot(w, split.id)
        refuse(w, split.id, seenConnecting: true)
        #expect(await eventually { problems(w, "Split") == 1 })
        #expect(w.h.env.connection.currentID == w.work.id)
        #expect(w.h.env.connection.currentStatus == .connected)
        #expect(w.h.env.connection.observedError == nil)
        #expect(w.h.env.connection.endNotes[split.id]?.code == .anotherTunnelActive)
        UIBinder.render(w.h.env)
        #expect(w.h.env.ui.connection.profileID == w.work.id)
        #expect(w.h.env.ui.connection.endNotes[split.id] == "Another LockPlus profile is connected. Disconnect it first.")
        #expect(!notices.contains(.stoppedUnexpectedly(split.id)))
        #expect(!notices.contains(.killSwitchStartRefused(split.id)))  // no kill switch: no notice
        #expect(w.h.managers.stops.isEmpty)
    }

    /// Review H1: the split session the extension ended for a kill-switch start (now current) is a disconnect with its
    /// own problem line and notice.
    @Test func aSessionEndedForAKillSwitchStartSaysWhy() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .connected)
        var notices: [ConnectionNotice] = []
        w.h.env.connection.onNotice = { notices.append($0) }
        w.h.managers.emit(w.work.id, .connecting)                      // the kill-switch profile's start (elsewhere)
        #expect(w.h.env.connection.currentID == split.id)                // E2E F1: split still reported connected
        snapshot(w, split.id, .supersededByKillSwitch)
        w.h.managers.lastError = superseded
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.env.profiles.problems.contains {
            $0.message == "Split stopped: another LockPlus profile with the kill switch took over." } })
        #expect(notices.contains(.stoppedUnexpectedly(split.id)))
        w.h.managers.emit(w.work.id, .connected)
        #expect(w.h.env.connection.currentID == w.work.id)
        // E2E F2: split's own detail says why, after the hero moved to the kill-switch profile.
        UIBinder.render(w.h.env)
        #expect(w.h.env.ui.connection.endNotes[split.id]
                == "Another LockPlus profile with the kill switch took over, so this one was disconnected.")
        w.h.managers.lastError = nil
        w.h.managers.emit(split.id, .connecting)                       // split runs again: the note goes
        #expect(w.h.env.connection.endNotes[split.id] == nil)
    }

    /// Re-check L4: a later refusal of the same profile beside a different set of active profiles is said again.
    @Test func aRefusalBesideADifferentBlockerIsSaidAgain() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        snapshot(w, split.id)
        refuse(w, split.id)
        #expect(await eventually { problems(w, "Split") == 1 })
        w.h.managers.emit(w.auto.id, .connecting)                      // another profile became active meanwhile
        snapshot(w, split.id)
        refuse(w, split.id)
        #expect(await eventually { problems(w, "Split") == 2 })
    }

    /// Review L1 window boundary: a refusal recorded 8 s before the `.disconnecting` counts; 12 s before doesn't.
    @Test(arguments: [(8.0, true), (12.0, false)])
    func theFreshnessWindowBoundary(age: TimeInterval, shown: Bool) async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        snapshot(w, split.id, at: Date().addingTimeInterval(-age))
        refuse(w, split.id)
        if shown { #expect(await eventually { problems(w, "Split") == 1 }) }
        else { #expect(await never { problems(w, "Split") > 0 }) }
    }

    /// Re-check N4: a sticky 223 read at a later, clean stop elsewhere of a connected session: no "took over" line.
    @Test func aStaleSupersededAtALaterStopShowsNoTakeOverLine() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .connected)
        w.h.managers.emit(w.work.id, .connecting)                      // keeps `work` current, `split` not
        // Round 9 (Fable L1): 20 s back, inside the 223 window: only the generic filter of a connected session drops it.
        snapshot(w, split.id, .supersededByKillSwitch, at: Date().addingTimeInterval(-20))
        w.h.managers.lastError = superseded
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await never { w.h.env.profiles.problems.contains { $0.message.contains("took over") } })
    }

    /// Codex 4: B ran earlier without the kill switch (the store cached that), then got `includeAllNetworks` and on-demand.
    /// Its refusal now (no `.connecting`) reads the configuration's current flag: the kill-switch notice goes out.
    @Test func aRefusalUsesTheConfigurationsCurrentKillSwitchFlag() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        w.h.managers.lastError = nil
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .connected)
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        _ = await eventually { w.h.env.connection.isBusy == false }
        await t4.connected(w.h, w.work)                                 // (its start pauses others' on-demand: before the change)
        w.h.managers.entries[split.id]?.cfg.flags.includeAllNetworks = true
        w.h.managers.entries[split.id]?.onDemand = true                 // on-demand on: the teardown hold doesn't refresh the flag
        try await w.h.env.managers.loadAll()
        var notices: [ConnectionNotice] = []
        w.h.env.connection.onNotice = { notices.append($0) }
        snapshot(w, split.id)
        refuse(w, split.id)
        #expect(await eventually { notices.contains(.killSwitchStartRefused(split.id)) })
    }

    /// Codex 5: a refusal recorded 2 s before the app saw its `.connecting` is this attempt's (the generic 1 s M8 filter
    /// doesn't apply to it).
    @Test func aRefusalRecordedTwoSecondsBeforeConnectingCounts() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        snapshot(w, split.id, at: Date().addingTimeInterval(-2))
        refuse(w, split.id, seenConnecting: true)
        #expect(await eventually { problems(w, "Split") == 1 })
        #expect(w.h.env.connection.currentID == w.work.id)
    }

    /// Round 8 (Codex L4): the same for a 223: recorded 2 s before its `.connecting` reached the app, it is still this
    /// attempt's (its own 30 s window, not the generic 1 s filter): Diagnostics and the end note say so.
    @Test func aSupersededRecordedTwoSecondsBeforeConnectingCounts() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        snapshot(w, split.id, .supersededByKillSwitch, at: Date().addingTimeInterval(-2))
        w.h.managers.lastError = superseded
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.env.profiles.problems.contains { $0.message.hasPrefix("Split stopped: another LockPlus profile with the kill switch took over") } })
        #expect(w.h.env.connection.endNotes[split.id]?.code == .supersededByKillSwitch)
    }

    /// Round 9 (Codex LOW): another USER's connection is active (its status delivered to the store): a refusal of Split
    /// beside it says "another LockPlus connection" (unseen), never "Disconnect it first" about a profile Split's user
    /// can't see.
    @Test func aRefusalBesideAnotherUsersConnectionNamesTheUnseenBlocker() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        var cfg = ManagerConfiguration(profile: w.work, onDemand: nil)
        cfg.profileID = UUID()
        cfg.provider.profileID = cfg.profileID
        cfg.provider.ownerUID = getuid() &+ 1
        w.h.managers.entries[cfg.profileID] = .init(cfg: cfg, status: .disconnected, onDemand: false)
        try await w.h.env.managers.loadAll()
        w.h.managers.emit(cfg.profileID, .connecting)
        w.h.managers.emit(cfg.profileID, .connected)
        snapshot(w, split.id)
        refuse(w, split.id, seenConnecting: true)
        #expect(await eventually { w.h.env.connection.endNotes[split.id]?.code == .anotherTunnelActive })
        #expect(w.h.env.connection.endNotes[split.id]?.detail == LPErrorCode.unseenSessionDetail)
        #expect(!w.h.env.profiles.problems.contains { $0.message.contains("Disconnect it first") })
    }

    /// Round 9 (Fable, CS:1200): the user's own Connect of a profile right after its automatic retry ended (its end is
    /// being read) is the user's start: beside Work it switches (stops Work), it never gives up as the automatic retry
    /// would. (The issued automatic entry is kept through that read, `keep`, and ends before a Connect can take it over,
    /// so the clear at the Connect is a safety; this pins the user-visible behaviour.)
    @Test func aUsersConnectOverAnAutomaticRetryStillSwitches() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        w.h.service.state.withLock { $0.holdSnapshots = true; $0.snapshot = nil }
        w.h.env.connection.connect(split.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.lastError = LPTunnelError(.profileNotProvisioned, detail: "x") as NSError
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.service.heldSnapshotCalls > 0 })
        w.h.service.releaseSnapshots()
        #expect(await eventually { w.h.managers.starts.count == 2 })     // the automatic retry was issued
        w.h.service.state.withLock { $0.holdSnapshots = true }
        w.h.managers.lastError = LPTunnelError(.connectTimeout, detail: "x") as NSError
        w.h.managers.emit(split.id, .disconnecting)                    // it ends before any active status: the same
        w.h.managers.emit(split.id, .disconnected)                     // entry reads its end (`.awaitingRestart`)
        #expect(await eventually { w.h.service.heldSnapshotCalls > 0 })
        w.h.managers.emit(w.work.id, .connecting)                      // Work starts elsewhere
        w.h.managers.emit(w.work.id, .connected)
        #expect(w.h.env.connection.connect(split.id))                  // the user's Connect
        #expect(await eventually { w.h.managers.stops.contains(w.work.id) })
        #expect(!w.h.env.profiles.problems.contains { $0.message.contains("didn't retry Split automatically") })
        w.h.service.releaseSnapshots()
    }

    /// Round 8 (Codex M2, Fable L3): the automatic retry after re-provisioning has to wait for a network; meanwhile the
    /// kill-switch Work starts from System Settings; when the network returns the retry ends (Diagnostics) and never
    /// stops Work.
    @Test func anAutomaticRetryThatWaitedForANetworkNeverSwitches() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        w.h.service.state.withLock { $0.holdSnapshots = true; $0.snapshot = nil }
        w.h.env.connection.connect(split.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.lastError = LPTunnelError(.profileNotProvisioned, detail: "x") as NSError
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.service.heldSnapshotCalls > 0 })
        w.net.change(to: NoNetworkRestartTests.offline)
        w.h.service.releaseSnapshots()
        #expect(await eventually { w.h.env.connection.startHold?.reason == .waitingForNetwork })
        w.h.managers.emit(w.work.id, .connecting)                      // `scutil --nc start` of Work
        w.h.managers.emit(w.work.id, .connected)
        w.net.change(to: NoNetworkRestartTests.online)
        #expect(await never { w.h.managers.stops.contains(w.work.id) || w.h.managers.starts.count > 1 })
        #expect(w.h.env.profiles.problems.contains { $0.message == "LockPlus didn't retry Split automatically: another connection is active." })
    }

    /// 2.0.1 E2E F1, no other profile active: the hero follows the refused profile (row 14 with the code).
    @Test func aRefusalSeenConnectingWithNothingElseActiveShowsRow14() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        snapshot(w, split.id)
        refuse(w, split.id, seenConnecting: true)
        #expect(await eventually { w.h.env.connection.observedError?.code == .anotherTunnelActive })
        #expect(w.h.env.connection.currentID == split.id)
    }

    /// 2.0.1 E2E F3: a profile that becomes current while another's session time is set never shows that time.
    @Test func aNewCurrentProfileStartsItsOwnSessionClock() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        let workSince = try #require(w.h.env.connection.connectedSince)
        try await Task.sleep(for: .milliseconds(20))
        w.h.managers.emit(split.id, .connecting)                       // started elsewhere, beside work
        #expect(w.h.env.connection.currentID == w.work.id)
        w.h.managers.emit(split.id, .connected)                        // it runs: it becomes current
        #expect(w.h.env.connection.currentID == split.id)
        let since = try #require(w.h.env.connection.connectedSince)
        #expect(since > workSince)
    }

    /// Codex 6: repeated kill-switch refusals whose `.connecting` was seen: one notice, like the ones without it.
    @Test func repeatedKillSwitchRefusalsSeenConnectingNotifyOnce() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, split)
        var notices: [ConnectionNotice] = []
        w.h.env.connection.onNotice = { notices.append($0) }
        for _ in 0..<3 {
            snapshot(w, w.work.id)
            refuse(w, w.work.id, seenConnecting: true)
            _ = await eventually { notices.contains(.killSwitchStartRefused(w.work.id)) }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await never { notices.filter { $0 == .killSwitchStartRefused(w.work.id) }.count > 1 })
        #expect(notices.filter { $0 == .killSwitchStartRefused(w.work.id) }.count == 1)
    }

    /// Codex final 4: B1's refusal read waits on a slow snapshot; meanwhile B2 starts and shows its sign-in prompt. When
    /// B1's read finishes it changes nothing: no 222 copy, and B2's prompt stays.
    @Test func aSlowRefusalReadNeverTouchesANewerAttempt() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        snapshot(w, split.id)
        w.h.service.state.withLock { $0.holdSnapshots = true }
        refuse(w, split.id, seenConnecting: true)                      // B1
        #expect(await eventually { w.h.service.heldSnapshotCalls > 0 })
        let prompt = AuthPrompt(promptID: UUID(), profileID: split.id, kind: .dynamicChallenge, challengeText: "Code?", echo: true,
                                lockedUsername: "alex", reason: .initial, savedUsername: nil, nextStart: false,
                                expiresAt: Date().addingTimeInterval(300))
        w.h.service.state.withLock { $0.prompt = prompt }
        w.h.managers.lastError = nil
        w.h.managers.emit(split.id, .connecting)                       // B2, with its prompt
        #expect(await eventually { w.h.env.auth.prompt?.promptID == prompt.promptID })
        w.h.service.releaseSnapshots()
        #expect(await never { w.h.env.auth.prompt == nil })
        #expect(w.h.env.connection.observedError?.code != .anotherTunnelActive)
    }

    /// Codex final 5: a pending split start the extension ended for a kill-switch start, never seen active: the problem
    /// line says why.
    @Test func aPendingStartEndedForAKillSwitchStartSaysWhy() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        snapshot(w, split.id, .supersededByKillSwitch)
        w.h.managers.lastError = superseded
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.env.profiles.problems.contains {
            $0.message == "Split couldn't connect: another LockPlus profile with the kill switch took over." } })
    }

    /// Final review L1/N3: an old refusal's time doesn't make a later, app-issued start's bare end read as refused: the
    /// "may restart" hold of the kill-switch profile stays.
    @Test func anOldRefusalDoesNotEndALaterIssuedStartsHold() async throws {
        let (w, _) = try await world()
        defer { w.h.dir.cleanup() }
        var notices: [ConnectionNotice] = []
        w.h.env.connection.onNotice = { notices.append($0) }
        snapshot(w, w.work.id, at: Date().addingTimeInterval(-5))        // recorded 5 s ago
        refuse(w, w.work.id)                                            // a refusal, read as fresh then
        #expect(await eventually { notices.contains(.killSwitchStartRefused(w.work.id)) })
        #expect(await eventually { w.h.env.connection.startHold == nil })
        w.h.env.connection.connect(w.work.id)                          // our own start, later
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(w.work.id, .disconnected)                     // ends with no status read; the 222 is sticky
        #expect(await eventually { w.h.env.connection.startHold != nil })
        #expect(await never { w.h.env.connection.startHold == nil })
    }

    /// Round 3 (Codex 5, final review N2): A is preempted by a kill-switch start made elsewhere that stays pending and
    /// held. At A's end the held K becomes current: its hold shows, and Cancel targets K, not A.
    @Test func aHeldPreemptorBecomesCurrentWhenThePreemptedProfileEnds() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .connected)
        w.h.managers.emit(w.work.id, .connecting)                      // K, pending (held) in the extension
        #expect(w.h.env.connection.currentID == split.id)
        snapshot(w, split.id, .supersededByKillSwitch)
        w.h.managers.lastError = superseded
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(w.h.env.connection.currentID == w.work.id)
        #expect(w.h.env.connection.currentStatus == .connecting)
        #expect(await eventually { w.h.env.connection.endNotes[split.id]?.code == .supersededByKillSwitch })
        w.h.service.state.withLock { $0.snapshot = TunnelSnapshot(profileID: w.work.id, phase: .held,
                                                                  holdReason: .blockedAfterFailure(.connectTimeout),
                                                                  holdBeforeConnected: true, epoch: 7) }
        w.h.env.connection.refreshSnapshot()
        #expect(await eventually { w.h.env.connection.snapshot?.holdReason == .blockedAfterFailure(.connectTimeout) })
        w.h.env.connection.disconnect()
        #expect(await eventually { w.h.managers.stops == [w.work.id] })
    }

    /// Round 3 (Codex 6, Fable L1): an app-issued attempt of Split an hour ago doesn't make a later, external refusal
    /// read with its issue time: a 222 recorded 50 min ago is stale now.
    @Test func anOldIssueTimeDoesNotWidenTheFreshnessWindow() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        final class Clock { var t = Date() }
        let clock = Clock()
        w.h.env.connection.now = { clock.t }
        let t0 = clock.t
        w.h.env.connection.connect(split.id)                           // our own start, issued at t0
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(split.id, .disconnected)                     // it ended (bare)
        try await Task.sleep(for: .milliseconds(50))
        clock.t = t0.addingTimeInterval(3600)
        await t4.connected(w.h, w.work)
        snapshot(w, split.id, at: t0.addingTimeInterval(600))          // an old refusal, sticky
        refuse(w, split.id)
        #expect(await never { problems(w, "Split") > 0 })
    }

    /// Round 4 (N5): the previous session's late `.disconnected` lands after our new start was issued; it doesn't clear
    /// the new attempt's issue time, so a refusal recorded before that issue (inside the 10 s window) is still stale.
    @Test func aLateDisconnectedKeepsTheNewAttemptsIssueTime() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        final class Clock { var t = Date() }
        let clock = Clock()
        w.h.env.connection.now = { clock.t }
        let t0 = clock.t
        w.h.env.connection.connect(split.id)                           // our start, issued at t0
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(split.id, .disconnected)                     // the previous session's late end
        try await Task.sleep(for: .milliseconds(50))
        await t4.connected(w.h, w.work)
        snapshot(w, split.id, at: t0.addingTimeInterval(-5))           // recorded BEFORE this attempt was issued
        refuse(w, split.id)
        #expect(await never { problems(w, "Split") > 0 })
    }

    func strayNotes(_ w: NoNetworkRestartTests.World) -> Int {
        w.h.env.profiles.problems.filter { $0.message.contains("A second configuration of Work was started outside LockPlus") }.count
    }

    /// Round 5: this user's stray duplicate of the active profile, started elsewhere and waiting in the extension, is
    /// not stopped (there is no stop: a waiter can't be told from a protective replacement); Diagnostics names it once
    /// per attempt and says where to stop it. Another user's duplicate, a running one and one of an inactive profile
    /// are not noted.
    @Test func aWaitingStrayDuplicateIsNotedOncePerAttempt() async throws {
        let (w, _) = try await world()
        defer { w.h.dir.cleanup() }
        let key = UUID(), me = w.h.env.profiles.ownerUID
        let stray = StraySnapshot(key: key, ownerUID: me, status: .connecting, profileID: w.work.id, includeAllNetworks: true)
        w.h.managers.strayEntries = [stray]
        w.h.managers.onStrayStatusChange?()
        #expect(strayNotes(w) == 0)                                     // Work isn't active: nothing waits beside it
        w.h.managers.strayEntries = []
        w.h.managers.onStrayStatusChange?()
        w.h.env.connection.connect(w.work.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(w.work.id, .connecting)
        w.h.managers.strayEntries = [stray]
        w.h.managers.onStrayStatusChange?()
        #expect(strayNotes(w) == 0)                                     // Work only starting: not kept waiting yet
        w.h.managers.emit(w.work.id, .connected)
        #expect(strayNotes(w) == 1)                                     // noted at Work's status event
        w.h.managers.onStrayStatusChange?()
        #expect(strayNotes(w) == 1)                                     // once per attempt
        #expect(w.h.env.profiles.problems.last?.message ==
                "A second configuration of Work was started outside LockPlus and is waiting. Stop it in System Settings › VPN.")
        // Round 6 (Codex L3, Fable L1): reloads mint new keys for the same waiting stray: nothing new.
        for _ in 0..<3 {
            w.h.managers.strayEntries = [StraySnapshot(key: UUID(), ownerUID: me, status: .connecting, profileID: w.work.id, includeAllNetworks: true)]
            try await w.h.env.managers.loadAll()
            w.h.env.connection.configurationChanged()
            w.h.managers.onStrayStatusChange?()
        }
        #expect(strayNotes(w) == 1)
        w.h.managers.strayEntries[0].status = .disconnected             // stopped in System Settings
        w.h.managers.onStrayStatusChange?()
        #expect(!w.h.env.connection.mutationBlocked(w.work.id))
        w.h.managers.strayEntries[0].status = .connecting               // `scutil --nc start` again: a new attempt
        w.h.managers.onStrayStatusChange?()
        #expect(strayNotes(w) == 2)
        w.h.managers.strayEntries = [StraySnapshot(key: UUID(), ownerUID: 4242, status: .connecting, profileID: w.work.id, includeAllNetworks: true),
                                     StraySnapshot(key: UUID(), ownerUID: me, status: .connected, profileID: w.work.id, includeAllNetworks: true),
                                     StraySnapshot(key: UUID(), ownerUID: me, status: .reasserting, profileID: w.work.id, includeAllNetworks: true)]
        w.h.managers.onStrayStatusChange?()
        #expect(strayNotes(w) == 2)
    }

    /// Round 6 (Fable L2): no note where the extension doesn't keep the duplicate waiting: beside a connected Work whose
    /// manager lost `includeAllNetworks` (a kill-switch duplicate is the protective replacement there), and beside a
    /// profile without the kill switch (its duplicate is refused).
    @Test func aStrayIsNotNotedWhereItIsNotKeptWaiting() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        let me = w.h.env.profiles.ownerUID
        await t4.connected(w.h, w.work)
        w.h.managers.strayEntries = [StraySnapshot(key: UUID(), ownerUID: me, status: .connecting, profileID: w.work.id, includeAllNetworks: true)]
        w.h.managers.entries[w.work.id]?.cfg.flags.includeAllNetworks = false   // weakened (the heal waits: busy)
        try await w.h.env.managers.loadAll()
        w.h.managers.onStrayStatusChange?()
        #expect(strayNotes(w) == 0)
        w.h.managers.strayEntries = []
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.emit(split.id, .connected)
        w.h.managers.strayEntries = [StraySnapshot(key: UUID(), ownerUID: me, status: .connecting, profileID: split.id, includeAllNetworks: true)]
        w.h.managers.onStrayStatusChange?()
        #expect(w.h.env.profiles.problems.filter { $0.message.contains("A second configuration of") }.isEmpty)
    }

    /// Round 7 (Codex M1): Split's start fails with `profileNotProvisioned`; while its error is read (a slow XPC answer)
    /// the kill-switch Work connects from System Settings. The automatic retry after re-provisioning doesn't switch
    /// away from Work: Work is never stopped, no second start; Diagnostics says why.
    @Test func aDelayedRecoveryNeverSwitchesAwayFromAnotherSession() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        w.h.service.state.withLock { $0.holdSnapshots = true; $0.snapshot = nil }
        w.h.env.connection.connect(split.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.lastError = LPTunnelError(.profileNotProvisioned, detail: "x") as NSError
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.service.heldSnapshotCalls > 0 })
        w.h.managers.emit(w.work.id, .connecting)                      // `scutil --nc start` of Work
        w.h.managers.emit(w.work.id, .connected)
        w.h.service.releaseSnapshots()
        #expect(await eventually { w.h.service.calls(.provisionProfile) > 0 })
        #expect(await never { w.h.managers.stops.contains(w.work.id) || w.h.managers.starts.count > 1 })
        #expect(w.h.env.profiles.problems.contains { $0.message == "LockPlus didn't retry Split automatically: another connection is active." })
    }

    /// Round 7 (Codex L6): a duplicate WITHOUT the kill switch beside the connected kill-switch Work is refused (222),
    /// not kept waiting: no note.
    @Test func aStrayWithoutTheKillSwitchIsNotNoted() async throws {
        let (w, _) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        w.h.managers.strayEntries = [StraySnapshot(key: UUID(), ownerUID: w.h.env.profiles.ownerUID, status: .connecting,
                                                   profileID: w.work.id, includeAllNetworks: false)]
        w.h.managers.onStrayStatusChange?()
        #expect(strayNotes(w) == 0)
    }

    /// Round 5: a duplicate already waiting when the app launches is noted at launch, not at the next status event.
    @Test func aStrayWaitingAtLaunchIsNoted() async throws {
        let (w, _) = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        w.h.managers.strayEntries = [StraySnapshot(key: UUID(), ownerUID: w.h.env.profiles.ownerUID, status: .connecting,
                                                   profileID: w.work.id, includeAllNetworks: true)]
        try await w.h.env.managers.loadAll()                            // launch: the load, then the store's start
        #expect(strayNotes(w) == 0)
        w.h.env.connection.start()
        #expect(strayNotes(w) == 1)
    }

    /// A sticky older `.anotherTunnelActive` read at a stop elsewhere of a down session, with nothing else active: stale,
    /// nothing shown.
    @Test func aStaleRefusalWithNothingElseActiveShowsNothing() async throws {
        let (w, split) = try await world()
        defer { w.h.dir.cleanup() }
        let before = w.h.env.connection.currentID
        w.h.env.settings.update { $0.lastQuitAt = Date() }              // the launch rule (S12) doesn't show it either
        snapshot(w, split.id, at: Date().addingTimeInterval(-3600))
        refuse(w, split.id)
        #expect(await never { w.h.env.connection.observedError != nil })
        #expect(w.h.env.profiles.problems.isEmpty)
        #expect(w.h.env.connection.currentID == before)
    }
}

/// 2.0.1 E2E F4, F5 and the update launch.
@MainActor @Suite("2.0.1 E2E app fixes", .timeLimit(.minutes(1)))
struct E2E201AppFixTests {
    /// F4: a WireGuard split tunnel without a DNS server sets no DNS: nothing to verify (no "overridden" alarm). A full
    /// tunnel without one, or any OpenVPN profile (servers may be pushed), is still checked.
    @Test func aWireGuardSplitTunnelWithoutDNSIsNotChecked() {
        #expect(DiagnosticsStore.setsNoDNS(kind: .wireGuard, dnsServers: [], isFullTunnel: false))
        #expect(!DiagnosticsStore.setsNoDNS(kind: .wireGuard, dnsServers: ["10.0.0.1"], isFullTunnel: false))
        #expect(!DiagnosticsStore.setsNoDNS(kind: .wireGuard, dnsServers: [], isFullTunnel: true))
        #expect(!DiagnosticsStore.setsNoDNS(kind: .openVPN, dnsServers: [], isFullTunnel: false))
    }

    /// F5: a file chosen in onboarding step 4 presents its import preview ON TOP of onboarding (it was queued behind
    /// it, invisible); the import error alert moves there too; with onboarding closed the main window shows them.
    @Test func onboardingPresentsItsImportPreviewOnTop() {
        let env = UIEnvironment.preview(row: "15")
        env.onboarding.isPresented = true
        env.onboarding.step = .profiles
        #expect(MainSheet.nested(in: env) == nil)
        env.importer.preview = PreviewData.importPreview
        guard case .onboarding? = MainSheet.active(in: env) else { Issue.record("onboarding stays the main sheet"); return }
        #expect(MainSheet.nested(in: env)?.id.hasPrefix("import-") == true)
        MainSheet.nested(in: env)?.clear(in: env)                       // the user's Cancel/Import
        #expect(env.importer.preview == nil)
        #expect(env.onboarding.isPresented && env.onboarding.step == .profiles)
        env.importer.preview = PreviewData.importPreview
        env.onboarding.isPresented = false
        #expect(MainSheet.nested(in: env) == nil)
        #expect(MainSheet.active(in: env)?.id.hasPrefix("import-") == true)
    }

    /// The update launch: the first launch of a build opens the main window (UI-CONCEPT §11.3), a relaunch doesn't.
    @Test func theFirstLaunchOfABuildOpensTheWindow() throws {
        #expect(AppSettings.isNewBuildLaunch(previous: nil, current: "200023"))
        #expect(AppSettings.isNewBuildLaunch(previous: "200022", current: "200023"))
        #expect(!AppSettings.isNewBuildLaunch(previous: "200023", current: "200023"))
        var s = AppSettings()
        s.lastLaunchedBuild = "200023"
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.lastLaunchedBuild == "200023")
    }
}
