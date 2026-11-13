import Foundation
import LPModel
import NetworkExtension
import Synchronization
import Testing
@testable import LockPlus

/// E2E-4 200011 (`native/e2e/RESULTS-E2E-4.md`, "Open issue"): a Connect of a kill-switch profile without on-demand rules
/// while en0 is down was refused by NE ("No network available", `NEVPNConnectionErrorDomain` 2; the app saw only
/// `.disconnecting` → `.disconnected`), the app restored the paused auto profile, and NE restarted the kill-switch session
/// by itself when the network came back, beside the enabled on-demand configuration (the E2E-3 failure mode).
/// The fix: no `startVPNTunnel` without a network (`.waitingForNetwork`), and the code-2 safety net
/// (`.awaitingNetworkRestart`, persisted). Fakes only: the path monitor is `FixtureNetworkWatcher`, timers `FakeTimers`.
@MainActor @Suite("E2E-4 200011: no network", .serialized)
struct NoNetworkRestartTests {
    let t4 = OnDemandPause4Tests()

    static let online = "satisfied|wifi:en0"
    static let offline = "unsatisfied|"
    var noNetwork: NSError { NSError(domain: NEVPNConnectionErrorDomain, code: 2) }

    func never(_ condition: () -> Bool) async -> Bool { await t4.never(condition) }

    /// The app's NWPathMonitor, as `AppEnvironment.start` wires it.
    func watch(_ h: Harness, _ signature: String) -> FixtureNetworkWatcher {
        let net = FixtureNetworkWatcher()
        net.current = signature
        net.onChange = { [weak connection = h.env.connection] in connection?.networkChanged($0) }
        net.start()
        return net
    }

    struct World {
        let h: Harness
        let auto: Profile
        let work: Profile
        let net: FixtureNetworkWatcher
        let timers: FakeTimers
    }

    func world(_ signature: String = online) async throws -> World {
        let h = Harness()
        let (auto, work) = try await t4.setUp(h)
        let timers = FakeTimers()
        h.env.connection.timerSleep = timers.sleeper
        h.env.connection.endpointPushSettle = .zero
        let net = watch(h, signature)
        return World(h: h, auto: auto, work: work, net: net, timers: timers)
    }

    /// The measured refusal: our start issued, then NE's `.disconnecting` → `.disconnected` with code 2.
    func refused(_ w: World) async {
        w.h.env.connection.connect(w.work.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        #expect(w.h.managers.entries[w.auto.id]?.onDemand == false)      // paused at the start
        w.net.change(to: Self.offline)                                  // the monitor catches up with en0 down
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(w.h.env.settings.value.networkRestartHold == w.work.id)
        // Review b47da1c L-6: on disk already when the hold is armed (read in the same turn, no wait).
        #expect(AtomicFile.loadJSON(AppSettings.self, from: w.h.dir.data.settings)?.networkRestartHold == w.work.id)
    }

    // MARK: 1. No start without a network

    @Test func aConnectWithoutANetworkIssuesNothingAndStartsWhenOneReturns() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        #expect(w.h.env.connection.connect(w.work.id))
        #expect(await never { !w.h.managers.starts.isEmpty })
        #expect(w.h.env.connection.startHold == .init(profile: w.work.id, reason: .waitingForNetwork))
        #expect(w.h.env.connection.connectHold(for: w.auto.id)?.reason == .waitingForNetwork)   // other Connects held
        #expect(!w.h.env.connection.isBusy)                             // nothing paused, nothing pending in NE
        #expect(w.h.managers.onDemandChanges[w.auto.id] == nil)         // the auto profile is not paused while waiting
        #expect(w.timers.armed.isEmpty)                                 // no time limit
        w.net.change(to: Self.online)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        #expect(w.h.managers.starts.first?.0 == w.work.id)
        #expect(w.h.managers.onDemandAtStart == [[]])                   // the normal pause ran before the start
        #expect(w.h.managers.onDemandChanges[w.auto.id] == [false])
        #expect(w.h.env.connection.startHold?.reason == .preparing)
    }

    @Test func anotherConnectWhileWaitingIsIgnored() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(w.work.id)
        #expect(!w.h.env.connection.connect(w.auto.id))
        #expect(w.h.env.connection.startHold == .init(profile: w.work.id, reason: .waitingForNetwork))
    }

    /// Review b47da1c L-3: NE's on-demand start of the auto profile lands with the network, before our start: the start
    /// goes through a Connect's checks (a switch: pause, stop, wait), never prepares beside the `.connecting` session.
    @Test func anOnDemandStartAtTheNetworksReturnIsSwitchedOutFirst() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(w.work.id)
        var autoLiveAtStart: [Bool] = []
        w.h.managers.onStart = { [h = w.h, auto = w.auto] _ in autoLiveAtStart.append(h.managers.status(auto.id).isLive) }
        w.net.change(to: Self.online)
        w.h.managers.emit(w.auto.id, .connecting)                       // same turn: before our start's Task runs
        #expect(await eventually { w.h.managers.stops == [w.auto.id] })
        #expect(w.h.managers.starts.isEmpty)
        #expect(w.h.env.connection.startHold == .init(profile: w.work.id, reason: .waitingForStop(of: w.auto.id)))
        w.h.managers.emit(w.auto.id, .disconnected)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        #expect(autoLiveAtStart == [false])
        #expect(w.h.managers.onDemandAtStart == [[]])
    }

    @Test func cancelEndsTheWaitForANetwork() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(w.work.id)
        #expect(w.h.env.connection.startHold?.reason == .waitingForNetwork)
        w.h.env.connection.disconnect()
        #expect(w.h.env.connection.startHold == nil)
        w.net.change(to: Self.online)
        #expect(await never { !w.h.managers.starts.isEmpty })
    }

    /// The network goes away inside the start's settle (after its pause): still no `startVPNTunnel`; the entry waits
    /// (not busy), so the pause is undone meanwhile, and the start pauses again when the network is back.
    @Test func theNetworkGoingAwayDuringTheStartHoldsItBeforeStartVPNTunnel() async throws {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)
        let (auto, work) = try await t4.setUp(h)
        h.env.connection.endpointPushSettle = .zero
        let net = watch(h, Self.online)
        fake.onFirstSleep { await MainActor.run { net.change(to: Self.offline) } }
        h.env.connection.connect(work.id)
        #expect(await eventually { h.env.connection.startHold?.reason == .waitingForNetwork })
        #expect(h.managers.starts.isEmpty)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })   // paused, then given back
        net.change(to: Self.online)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.onDemandAtStart == [[]])
        #expect(h.managers.onDemandChanges[auto.id] == [false, true, false])
    }

    // MARK: 2. The code-2 safety net

    @Test func aRefusalForNoNetworkHoldsUntilNEsRestartWithoutATimeLimit() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        let fallback = w.h.env.connection.systemRestartTimeout
        // No network: no timer at all, so no restore however long it takes; other events restore nothing either.
        #expect(await never { w.timers.armed.contains(fallback) })
        #expect(w.timers.armed.isEmpty)
        w.h.env.connection.configurationChanged()
        w.net.change(to: "requiresConnection|")                         // still no interface
        #expect(await never { w.h.env.connection.restoring })
        #expect(w.h.managers.entries[w.auto.id]?.onDemand == false)
        #expect(w.h.env.connection.isBusy)
        // An interface returns: NE's restart is awaited with the fallback armed; it comes (no start command of ours).
        w.net.change(to: Self.online)
        #expect(await eventually { w.timers.armed.contains(fallback) })
        w.h.managers.emit(w.work.id, .connecting)
        #expect(w.h.env.connection.startHold == nil)
        #expect(await never { w.h.env.connection.restoring })
        w.h.managers.emit(w.work.id, .connected)
        #expect(await never { w.h.env.connection.restoring })
        #expect(w.h.managers.onDemandChanges[w.auto.id] == [false])     // no on-demand change beside the session
        #expect(w.h.managers.starts.count == 1)
        #expect(w.h.managers.stops.isEmpty)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
        await w.h.env.settings.flush()
        #expect(AtomicFile.loadJSON(AppSettings.self, from: w.h.dir.data.settings)?.networkRestartHold == nil)
    }

    @Test func noRestartAfterTheNetworkReturnedRestoresAfterTheFallback() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        w.net.change(to: Self.online)
        await w.timers.fire(w.h.env.connection.systemRestartTimeout)
        #expect(await eventually { w.h.managers.entries[w.auto.id]?.onDemand == true })
        #expect(w.h.env.connection.startHold == nil)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
    }

    /// The network comes and goes again before NE's restart: the fallback is disarmed; no restore while it is gone.
    @Test func aNetworkThatGoesAgainDisarmsTheFallback() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        let fallback = w.h.env.connection.systemRestartTimeout
        w.net.change(to: Self.online)
        #expect(await eventually { w.timers.armed.contains(fallback) })
        w.net.change(to: Self.offline)
        #expect(await eventually { !w.timers.armed.contains(fallback) })
        #expect(w.h.env.connection.startHold?.reason == .awaitingNetwork)
        #expect(await never { w.h.env.connection.restoring })
    }

    /// Review b47da1c L-1: a start made in System Settings that NE refuses for want of a network, at the measured
    /// sequence: only `.disconnecting` → `.disconnected` (no `.connecting`, no entry of ours). The teardown is held (a
    /// Connect of another profile is ignored inside it), then the same hold, with no "stopped unexpectedly" notice.
    @Test func aSystemSettingsRefusalForNoNetworkIsHeldToo() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        var notices: [ConnectionNotice] = []
        w.h.env.connection.onNotice = { notices.append($0) }
        w.h.managers.entries[w.auto.id]?.onDemand = false
        w.h.env.settings.update { $0.onDemandPausedByStart = [w.auto.id] }
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        #expect(w.h.env.connection.connectHold(for: w.auto.id) != nil)
        #expect(!w.h.env.connection.connect(w.auto.id))
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(w.h.env.connection.currentID == w.work.id)              // review aad7527 #3: the row and Cancel are Work's
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(w.h.env.connection.isBusy)
        #expect(await never { w.h.env.connection.restoring })
        #expect(w.h.managers.entries[w.auto.id]?.onDemand == false)
        #expect(w.h.managers.starts.isEmpty)
        #expect(notices.isEmpty)
        w.net.change(to: Self.online)
        w.h.managers.emit(w.work.id, .connecting)                       // NE's restart
        #expect(w.h.env.connection.startHold == nil)
        #expect(await never { w.h.env.connection.restoring })
        #expect(w.h.managers.entries[w.auto.id]?.onDemand == false)
    }

    /// A session started elsewhere that was seen `.connecting` (never `.connected`) and ends with code 2: the same hold.
    @Test func aSessionSeenConnectingThatEndsForNoNetworkIsHeld() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        var notices: [ConnectionNotice] = []
        w.h.env.connection.onNotice = { notices.append($0) }
        w.h.managers.entries[w.auto.id]?.onDemand = false
        w.h.env.settings.update { $0.onDemandPausedByStart = [w.auto.id] }
        w.h.managers.emit(w.work.id, .connecting)
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(await never { w.h.env.connection.restoring })
        #expect(!notices.contains(.stoppedUnexpectedly(w.work.id)))
    }

    /// Review b47da1c L-7: a code 2 read at the end of a session that was CONNECTED is a sticky older one (a connected
    /// session that loses the network goes `.reasserting`, measured (e)): no hold, and no "no network" error shown.
    @Test func aStickyCodeTwoAfterAConnectedSessionIsNotHeld() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.managers.fetchCount == 1 })
        #expect(await never { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(w.h.env.connection.observedError?.code != .noNetwork)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
    }

    /// Review b47da1c L-7: once a hold ends without NE's restart, row 14 says there was no network (not "engine").
    @Test func codeTwoReadsAsNoNetwork() {
        let (e, detail) = ConnectionStore.observedError(noNetwork)
        #expect(e.code == .noNetwork)
        #expect(detail == "NEVPNConnectionError 2")
        #expect(LPErrorCode.noNetwork.message() == "Your Mac isn't connected to a network.")
        var i = DerivedStateInputs(profileName: "Work")
        i.status = .disconnected
        i.lastError = e
        #expect(i.condition == .stoppedWithError(.noNetwork))
    }

    /// Review b47da1c L-2: a Connect of another profile inside the refusal's `.disconnecting` is ignored (held), so its
    /// pause never runs beside NE's coming restart.
    @Test func aConnectInsideTheRefusalsTeardownIsHeld() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(w.work.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        #expect(w.h.env.connection.connectHold(for: w.auto.id) != nil)
        #expect(!w.h.env.connection.connect(w.auto.id))
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(await never { w.h.managers.starts.count > 1 })
    }

    /// Cancel inside the "start ended early" hold, before code 2 is read: a user stop; the late read enters no hold.
    @Test func cancelBeforeTheErrorIsReadEntersNoHold() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(w.work.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(w.h.env.connection.startHold?.reason == .startEndedEarly)
        w.h.env.connection.disconnect()                                 // same turn: the read hasn't run yet
        #expect(await eventually { w.h.managers.fetchCount == 1 })
        #expect(await never { w.h.env.connection.startHold != nil })
        #expect(await eventually { w.h.managers.entries[w.auto.id]?.onDemand == true })
        #expect(w.h.env.settings.value.networkRestartHold == nil)
    }

    /// The read times out (a wedged nesessionmanager): no network hold; the "start ended early" fallback restores.
    @Test func aReadThatTimesOutKeepsTheBoundedHold() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        w.h.env.connection.disconnectErrorTimeout = .milliseconds(50)
        w.h.managers.fetchNeverAnswers = true
        w.h.env.connection.connect(w.work.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await never { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(w.h.env.connection.startHold?.reason == .startEndedEarly)
        await w.timers.fire(w.h.env.connection.systemRestartTimeout)
        #expect(await eventually { w.h.managers.entries[w.auto.id]?.onDemand == true })
    }

    // MARK: Cancel, another Connect, Pause

    /// Cancel is a user stop (`stopVPNTunnel` cancels NE's restart), issued before the restore saves anything.
    @Test func cancelStopsTheSessionThenRestores() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        var stoppedBeforeSave: [Bool] = []
        w.h.managers.onSave = { [h = w.h, work = w.work] _ in stoppedBeforeSave.append(h.managers.stops.contains(work.id)) }
        w.h.env.connection.disconnect()
        #expect(w.h.managers.stops == [w.work.id])
        #expect(w.h.env.connection.startHold == nil)
        #expect(await eventually { w.h.managers.entries[w.auto.id]?.onDemand == true })
        #expect(!stoppedBeforeSave.isEmpty && stoppedBeforeSave.allSatisfy { $0 })
        #expect(w.h.env.settings.value.networkRestartHold == nil)
        // NE's restart landing right after the stop anyway is stopped again (L-E).
        w.net.change(to: Self.online)
        w.h.managers.emit(w.work.id, .connecting)
        #expect(await eventually { w.h.managers.stops == [w.work.id, w.work.id] })
    }

    /// Another profile's Connect stops X first (a user stop), then proceeds; X's own Connect is held.
    @Test func anotherProfilesConnectStopsTheHeldSessionFirst() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        #expect(w.h.env.connection.connectHold(for: w.work.id)?.reason == .awaitingNetwork)
        #expect(w.h.env.connection.connectHold(for: w.auto.id) == nil)
        #expect(!w.h.env.connection.connect(w.work.id))                // its own Connect: NE connects it
        #expect(w.h.managers.stops.isEmpty)
        w.net.change(to: Self.online)
        var stoppedAtStart: [Bool] = []
        w.h.managers.onStart = { [h = w.h, work = w.work] _ in stoppedAtStart.append(h.managers.stops.contains(work.id)) }
        #expect(w.h.env.connection.connect(w.auto.id))
        #expect(w.h.managers.stops == [w.work.id])                      // at once, before anything of the new start
        #expect(await eventually { w.h.managers.starts.count == 2 })
        #expect(w.h.managers.starts.last?.0 == w.auto.id)
        #expect(stoppedAtStart == [true])
        #expect(w.h.env.settings.value.networkRestartHold == nil)
    }

    @Test func pauseStopsTheHeldSessionAndResumesIt() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        await w.h.env.connection.pause(minutes: 5)
        #expect(w.h.managers.stops == [w.work.id])
        #expect(w.h.env.connection.startHold == nil)
        #expect(w.h.env.settings.value.pausedState?.profileID == w.work.id)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
        // Review b47da1c L-4: cleared in the pause's own durable write, not a later queued one.
        #expect(AtomicFile.loadJSON(AppSettings.self, from: w.h.dir.data.settings)?.networkRestartHold == nil)
        // The pause's end reconnects the profile NE would have restarted.
        w.net.change(to: Self.online)
        await w.h.env.connection.resume().value
        #expect(await eventually { w.h.managers.starts.count == 2 })
        #expect(w.h.managers.starts.last?.0 == w.work.id)
    }

    /// Review b47da1c L-4: a hand-back whose target's Connect its own hold ignored says so.
    @Test func aHandBackIgnoredByItsOwnHoldIsNoted() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        await w.h.env.connection.returnOnDemand([], thenConnect: w.work.id)
        #expect(w.h.env.profiles.problems.map(\.message) == ["Work wasn't reconnected yet: macOS connects it when a network is available."])
        #expect(w.h.env.connection.startHold?.reason == .awaitingNetwork)
    }

    /// Review b47da1c L-8a: an unverified other profile's Connect fails without stopping the held session.
    @Test func anUnverifiedConnectDoesNotStopTheHeldSession() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        try await w.h.env.profiles.updateMetadata(w.auto.id) { $0.engineVerified = false }
        #expect(w.h.env.connection.connect(w.auto.id))                  // taken, and failed
        #expect(w.h.managers.stops.isEmpty)
        #expect(w.h.env.connection.startHold?.reason == .awaitingNetwork)
    }

    /// Review b47da1c L-8b: with a second entry beside the hold the Connect would be ignored, so it isn't offered.
    @Test func anotherConnectIsHeldWhenTheHoldIsNotTheOnlyEntry() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        let third = try await w.h.add("Third.conf", Harness.wgConf, killSwitch: true)
        try await w.h.env.managers.loadAll()
        w.h.managers.emit(third.id, .connecting)                        // a session started elsewhere
        w.h.managers.emit(third.id, .disconnecting)                     // its teardown entry
        #expect(w.h.env.connection.connectHold(for: w.auto.id) != nil)
        #expect(!w.h.env.connection.connect(w.auto.id))
        #expect(w.h.managers.stops.isEmpty)
    }

    /// Review b47da1c L-8c: the pane names no holder for NE's restart when nothing of the auto profile was paused.
    @Test func theHoldIsNoHolderOfAnUnpausedAutoProfile() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(w.h.managers.entries[w.auto.id]?.onDemand == true)
        #expect(w.h.env.connection.holder(of: w.auto.id) == nil)
        w.h.env.settings.update { $0.onDemandPausedByStart = [w.auto.id] }
        #expect(w.h.env.connection.holder(of: w.auto.id) == w.work.id)  // recorded: it is the holder
    }

    // MARK: Delete, removal

    @Test func deletingTheHeldProfileEndsTheHold() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        await w.h.env.profiles.delete(w.work.id)
        #expect(w.h.managers.stops == [w.work.id])
        #expect(w.h.managers.removed.contains(w.work.id))
        #expect(w.h.env.connection.startHold == nil)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
        #expect(await eventually { w.h.managers.entries[w.auto.id]?.onDemand == true })
    }

    @Test func aConfigurationRemovedElsewhereEndsTheHold() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        w.h.managers.entries[w.work.id] = nil
        try await w.h.env.managers.loadAll()
        w.h.env.connection.configurationChanged()
        #expect(w.h.env.connection.startHold == nil)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
    }

    // MARK: 3. Durability

    /// The record is on disk while held; a relaunch while still waiting re-enters the hold before the launch's restore.
    @Test func aRelaunchDuringTheHoldReentersIt() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        #expect(await eventually { AtomicFile.loadJSON(AppSettings.self, from: w.h.dir.data.settings)?.networkRestartHold == w.work.id })

        let h2 = Harness(dir: w.h.dir, managers: w.h.managers, keychain: w.h.keychain)
        h2.env.settings.replaceAll(try #require(await h2.env.files?.loadSettingsChecked().settings))
        try await h2.env.managers.loadAll()
        await h2.env.profiles.load()
        let timers = FakeTimers()
        h2.env.connection.timerSleep = timers.sleeper
        h2.env.connection.start()
        #expect(h2.env.connection.startHold == .init(profile: w.work.id, reason: .awaitingNetwork))
        #expect(await never { h2.env.connection.restoring })
        #expect(w.h.managers.entries[w.auto.id]?.onDemand == false)
        #expect(timers.armed.isEmpty)                                   // no reading of the path yet: no fallback
        let net = watch(h2, Self.offline)
        #expect(await never { !timers.armed.isEmpty })
        net.change(to: Self.online)
        #expect(await eventually { timers.armed.contains(h2.env.connection.systemRestartTimeout) })
        w.h.managers.emit(w.work.id, .connecting)                       // NE's restart
        #expect(h2.env.connection.startHold == nil)
        #expect(await never { h2.env.connection.restoring })
        #expect(w.h.managers.entries[w.auto.id]?.onDemand == false)
        #expect(h2.env.settings.value.networkRestartHold == nil)
    }

    /// Review aad7527 #1: a refusal DURING a pause (its write cleared nothing of it), then a relaunch: the hold is entered
    /// again, and the pause's end stops Work (cancelling NE's restart) before it starts its own target.
    @Test func aRefusalDuringAPauseSurvivesARelaunchAndTheResumeStopsItFirst() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await w.h.env.connection.pause(minutes: 5)
        // The profile to reconnect, with its resume intent (round 1, Codex 3), as the GUI's own pause writes it.
        let until = try #require(w.h.env.settings.value.autoConnect.pausedUntil)
        let intent = await resumeIntent(w.auto.id, until: until, keychain: w.h.keychain, dir: w.h.dir.data)
        await w.h.env.settings.updateDurably { $0.pausedState?.profileID = w.auto.id; $0.pausedState?.intent = intent }
        w.h.env.connection.connect(w.work.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.net.change(to: Self.offline)
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })

        let h2 = Harness(dir: w.h.dir, managers: w.h.managers, keychain: w.h.keychain)
        h2.env.settings.replaceAll(try #require(await h2.env.files?.loadSettingsChecked().settings))
        #expect(h2.env.settings.value.autoConnect.pausedUntil != nil)
        try await h2.env.managers.loadAll()
        await h2.env.profiles.load()
        h2.env.connection.endpointPushSettle = .zero
        let timers2 = FakeTimers()
        h2.env.connection.timerSleep = timers2.sleeper                   // review f0c8c57: no real fallback outlives the test
        h2.env.connection.start()
        #expect(h2.env.connection.startHold == .init(profile: w.work.id, reason: .awaitingNetwork))
        _ = watch(h2, Self.online)
        #expect(await eventually { timers2.armed.contains(h2.env.connection.systemRestartTimeout) })
        var workStoppedAtStart: [Bool] = []
        w.h.managers.onStart = { [managers = w.h.managers, work = w.work] _ in workStoppedAtStart.append(managers.stops.contains(work.id)) }
        await h2.env.connection.resume().value
        #expect(w.h.managers.stops == [w.work.id])
        #expect(await eventually { w.h.managers.starts.count == 2 })
        #expect(w.h.managers.starts.last?.0 == w.auto.id)
        #expect(workStoppedAtStart == [true])
        #expect(h2.env.settings.value.networkRestartHold == nil)
    }

    /// A record that no longer applies at launch (NE's restart is live, or the configuration gained on-demand) is dropped.
    @Test func aRecordThatNoLongerAppliesIsDroppedAtLaunch() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        w.h.managers.entries[w.work.id]?.onDemand = true
        let h2 = Harness(dir: w.h.dir, managers: w.h.managers, keychain: w.h.keychain)
        h2.env.settings.replaceAll(try #require(await h2.env.files?.loadSettingsChecked().settings))
        try await h2.env.managers.loadAll()
        await h2.env.profiles.load()
        h2.env.connection.start()
        #expect(h2.env.connection.startHold == nil)
        #expect(h2.env.settings.value.networkRestartHold == nil)
    }

    // MARK: Headless resume

    func expiredPause(_ dir: TestDir, profile: UUID?, onDemand: [UUID], held: UUID, keychain: InMemoryKeychain) async throws {
        var s = AppSettings()
        let until = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-5))
        s.autoConnect.pausedUntil = until
        s.pausedState = PausedState(profileID: profile, onDemandEnabledIDs: onDemand, agentBuild: "1",
                                    intent: await resumeIntent(profile, until: until, keychain: keychain, dir: dir.data))
        s.networkRestartHold = held
        try AtomicFile.saveJSON(s, to: dir.data.settings)
    }

    /// The held session is still coming: the resume stops it (cancelling NE's restart) before it restores on-demand.
    @Test func theHeadlessResumeStopsAComingRestartBeforeItRestores() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        try await expiredPause(h.dir, profile: nil, onDemand: [auto.id], held: work.id, keychain: h.keychain)
        var stoppedFirst: [Bool] = []
        h.managers.onSetOnDemand = { [managers = h.managers] _, on in if on { stoppedFirst.append(managers.stops == [work.id]) } }
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(r == .resumed(restarted: nil, onDemand: [auto.id]))
        #expect(h.managers.stops == [work.id])
        #expect(stoppedFirst == [true])                                 // the stop came before the restore
        #expect(h.managers.entries[auto.id]?.onDemand == true)
        #expect(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)?.networkRestartHold == nil)
    }

    /// Review b47da1c L-5: the held session is the pause's own target and it is live: the "target already live" path
    /// (nothing started, the pause cleared), not a retry every minute.
    @Test func theHeadlessResumeCompletesWhenTheLiveHeldSessionIsItsTarget() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        try await h.env.managers.loadAll()
        h.managers.entries[work.id]?.status = .connected
        try await expiredPause(h.dir, profile: work.id, onDemand: [auto.id], held: work.id, keychain: h.keychain)
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(r == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.starts.isEmpty)
        #expect(h.managers.stops.isEmpty)
        let s = AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)
        #expect(s?.autoConnect.pausedUntil == nil)
        #expect(s?.networkRestartHold == nil)
        #expect(s?.onDemandPausedByStart == [auto.id])
    }

    /// The held session is the target and still coming: not stopped before the start; a failed start stops it (its
    /// restart by NE would otherwise land beside the on-demand restored after the failure).
    @Test func theHeadlessResumeStopsTheHeldTargetWhenItsStartFails() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        try await expiredPause(h.dir, profile: work.id, onDemand: [auto.id], held: work.id, keychain: h.keychain)
        h.managers.startError = LPError(.extensionUnavailable)
        var stoppedFirst: [Bool] = []
        h.managers.onSetOnDemand = { [managers = h.managers] _, on in if on { stoppedFirst.append(managers.stops == [work.id]) } }
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: ProbeResumeAgent(), keychain: h.keychain)
        #expect(r == .resumed(restarted: nil, onDemand: [auto.id]))
        #expect(h.managers.stops == [work.id])
        #expect(stoppedFirst == [true])
    }

    /// NE's restart is live: nothing changes beside it; the pause and the record stay for the next run.
    @Test func theHeadlessResumeLeavesALiveRestartAlone() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        try await h.env.managers.loadAll()
        h.managers.entries[auto.id]?.onDemand = false
        h.managers.entries[work.id]?.status = .connecting
        try await expiredPause(h.dir, profile: nil, onDemand: [auto.id], held: work.id, keychain: h.keychain)
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain)
        #expect(r == .networkRestartPending)
        #expect(h.managers.stops.isEmpty)
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(agent.calls.isEmpty)
        let s = AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings)
        #expect(s?.networkRestartHold == work.id)
        #expect(s?.autoConnect.pausedUntil != nil)
    }

    // MARK: Review aad7527

    /// #2: a start waiting for a network finds NE's restart of another profile still awaited when the network returns:
    /// it keeps waiting (one start at a time) and runs when that hold ends, as a switch out of the restarted session.
    @Test func theNetworkReturnStartWaitsForAnotherHoldToEnd() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        let other = try await w.h.add("Other.conf", Harness.wgConf, killSwitch: true)
        try await w.h.env.managers.loadAll()
        w.h.env.connection.connect(w.work.id)
        #expect(w.h.env.connection.startHold?.reason == .waitingForNetwork)
        w.h.managers.lastError = noNetwork                              // Other started in System Settings, refused
        w.h.managers.emit(other.id, .disconnecting)
        w.h.managers.emit(other.id, .disconnected)
        #expect(await eventually { w.h.env.connection.networkRestartHolder == other.id })
        w.net.change(to: Self.online)
        #expect(await never { !w.h.managers.starts.isEmpty || !w.h.managers.stops.isEmpty })
        #expect(w.h.env.connection.connectHold(for: w.auto.id) != nil)
        w.h.managers.emit(other.id, .connecting)                        // NE's restart ends the hold
        #expect(await eventually { w.h.managers.stops == [other.id] })  // the waiting Connect switches out of it
        #expect(w.h.managers.starts.isEmpty)
        w.h.managers.emit(other.id, .disconnected)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        #expect(w.h.managers.starts.first?.0 == w.work.id)
    }

    /// #3: Cancel of the hedged hold of a start made elsewhere (before code 2 is read) stops that profile, not the
    /// previously current one.
    @Test func cancelOfAnUnwatchedRefusalStopsThatProfile() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        #expect(w.h.env.connection.currentID != w.work.id)
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(w.h.env.connection.startHold == .init(profile: w.work.id, reason: .startEndedEarly))
        w.h.env.connection.disconnect()
        #expect(await eventually { w.h.managers.stops == [w.work.id] })
        #expect(await never { w.h.env.connection.startHold != nil })
    }

    /// #4: a session already stopping when LockPlus launched (never seen, not a refusal's `.disconnected` → `.disconnecting`)
    /// ends without a hold.
    @Test func aSessionStoppingAtLaunchIsNoRefusal() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        h.env.settings.update { $0.autoConnect.enabled = true; $0.autoConnect.profileID = auto.id }
        await h.env.profiles.resaveOnDemand()
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.managers.entries[auto.id]?.onDemand = false
        h.env.settings.update { $0.onDemandPausedByStart = [auto.id] }
        h.managers.entries[work.id]?.status = .disconnecting
        try await h.env.managers.loadAll()
        h.env.connection.start()
        h.managers.lastError = noNetwork
        h.managers.emit(work.id, .disconnected)
        #expect(h.env.connection.startHold == nil)
        #expect(await eventually { h.managers.entries[auto.id]?.onDemand == true })
    }

    /// #4: the kill switch of a profile's previous session doesn't count for a start made elsewhere after it was turned off.
    @Test func aStaleSessionKillSwitchIsNotRead() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await t4.connected(w.h, w.work)                                 // a kill-switch session, seen
        w.h.env.connection.disconnect()
        #expect(await eventually { w.h.managers.stops == [w.work.id] })
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.managers.entries[w.auto.id]?.onDemand == true })
        w.h.managers.entries[w.work.id]?.cfg.flags.includeAllNetworks = false
        try await w.h.env.managers.loadAll()
        w.h.managers.lastError = noNetwork                              // a System Settings start, refused
        w.h.managers.emit(w.work.id, .disconnecting)
        #expect(w.h.env.connection.startHold == nil)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await never { w.h.env.connection.startHold != nil })
    }

    /// NE already reports `.disconnecting` (the loaded snapshot) while its status event hasn't been delivered yet.
    func statusAheadOfItsEvent(_ w: World, _ id: UUID) async throws {
        w.h.managers.entries[id]?.status = .disconnecting
        let deliver = w.h.env.managers.onStatusChange
        w.h.env.managers.onStatusChange = nil
        try await w.h.env.managers.loadAll()
        w.h.env.managers.onStatusChange = deliver
    }

    /// #5 / L-2: a Connect that waited for a session NE may restart is dropped (and said); one that waited for a session
    /// NE won't restart starts.
    @Test func aWaitingConnectIsDroppedOnlyBesideARestartNEMayMake() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        try await statusAheadOfItsEvent(w, w.work.id)
        #expect(w.h.env.connection.connect(w.auto.id))
        #expect(w.h.env.connection.startHold == .init(profile: w.auto.id, reason: .waitingForStop(of: w.work.id)))
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(w.h.env.connection.startHold?.profile == w.work.id)
        #expect(w.h.managers.starts.isEmpty)
        #expect(w.h.env.profiles.problems.map(\.message) == ["Home NAS wasn't connected: macOS may restart Work. Connect Home NAS again if you need it."])

        let split = try await w.h.add("Split.conf", Harness.splitConf, killSwitch: false)
        try await w.h.env.managers.loadAll()
        w.h.env.connection.disconnect()                                 // Cancel Work's hold
        try await statusAheadOfItsEvent(w, split.id)
        #expect(w.h.env.connection.connect(w.auto.id))
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        #expect(w.h.managers.starts.first?.0 == w.auto.id)
    }

    /// #7: our own refusal whose restart never came reads "no network" in row 14.
    @Test func ourRefusalWithoutARestartShowsNoNetwork() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        w.net.change(to: Self.online)
        await w.timers.fire(w.h.env.connection.systemRestartTimeout)
        #expect(await eventually { w.h.env.connection.startHold == nil })
        #expect(w.h.env.connection.observedError?.code == .noNetwork)
    }

    // MARK: Review f0c8c57

    /// #1: a Connect waiting for a network (Home NAS) and a refusal of a start made elsewhere (Work): the hero's profile
    /// becomes Work and the hold shown is Work's, deterministically; Cancel stops Work and says that Home NAS's wait ended.
    @Test func twoEntriesShowTheCurrentProfilesHoldAndCancelSaysWhatItEnded() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(w.auto.id)
        #expect(w.h.env.connection.startHold == .init(profile: w.auto.id, reason: .waitingForNetwork))
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(w.h.env.connection.currentID == w.work.id)
        #expect(w.h.env.connection.startHold == .init(profile: w.work.id, reason: .startEndedEarly))
        #expect(await eventually { w.h.env.connection.startHold == .init(profile: w.work.id, reason: .awaitingNetwork) })
        for _ in 0..<5 { #expect(w.h.env.connection.startHold?.profile == w.work.id) }
        w.h.env.connection.disconnect()
        #expect(w.h.managers.stops == [w.work.id])
        #expect(w.h.env.connection.startHold == nil)
        #expect(w.h.env.profiles.problems.map(\.message) == ["LockPlus stopped waiting for a network to connect Home NAS. Connect Home NAS again if you need it."])
    }

    /// aad7527 #2 re-run, via a timer: the other entry is a teardown that times out (22 s); the waiting start then waits
    /// for that session's stop and starts at its `.disconnected`.
    @Test func theWaitingStartRunsWhenAnotherTeardownTimesOut() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        let other = try await w.h.add("Other.conf", Harness.wgConf, killSwitch: true)
        try await w.h.env.managers.loadAll()
        w.h.env.connection.connect(w.work.id)
        w.h.managers.emit(other.id, .disconnecting)                     // a start elsewhere being refused
        w.net.change(to: Self.online)
        #expect(await never { !w.h.managers.starts.isEmpty })
        await w.timers.fire(w.h.env.connection.stopTimeout)
        #expect(await eventually { w.h.env.connection.startHold == .init(profile: w.work.id, reason: .waitingForStop(of: other.id)) })
        w.h.managers.emit(other.id, .disconnected)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        #expect(w.h.managers.starts.first?.0 == w.work.id)
    }

    /// aad7527 #2 re-run, via the fallback: NE's restart of the other profile never comes.
    @Test func theWaitingStartRunsWhenAnotherHoldsFallbackFires() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        let other = try await w.h.add("Other.conf", Harness.wgConf, killSwitch: true)
        try await w.h.env.managers.loadAll()
        w.h.env.connection.connect(w.work.id)
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(other.id, .disconnecting)
        w.h.managers.emit(other.id, .disconnected)
        #expect(await eventually { w.h.env.connection.networkRestartHolder == other.id })
        w.net.change(to: Self.online)
        #expect(await never { !w.h.managers.starts.isEmpty })
        await w.timers.fire(w.h.env.connection.systemRestartTimeout)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        #expect(w.h.managers.starts.first?.0 == w.work.id)
        #expect(w.h.managers.stops.isEmpty)
    }

    /// aad7527 #2 re-run, via a failure: the other entry is the app's own crash restart (a kill-switch profile WITH
    /// on-demand rules) whose `startVPNTunnel` throws.
    @Test func theWaitingStartRunsWhenAnotherEntryFails() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.env.connection.crashRestartGrace = .zero
        let other = try await w.h.add("Other.conf", Harness.wgConf, killSwitch: true)
        try await w.h.env.managers.loadAll()
        w.h.env.connection.connect(w.work.id)
        w.h.managers.entries[other.id]?.onDemand = true                 // NE's on-demand starts it
        w.h.managers.emit(other.id, .connecting)
        w.h.managers.emit(other.id, .connected)
        w.h.service.state.withLock { $0.linkInterruptedAt = Date() }    // then its tunnel process crashes
        w.h.managers.lastError = pluginFailed
        w.h.managers.startError = LPError(.extensionUnavailable)
        w.h.managers.onStart = { [managers = w.h.managers, work = w.work] id in if id == work.id { managers.startError = nil } }
        w.h.managers.emit(other.id, .disconnecting)
        w.net.change(to: Self.online)                                   // the waiting start meets Other's entry
        w.h.managers.emit(other.id, .disconnected)
        #expect(await eventually { w.h.managers.starts.count == 1 })    // Other's restart threw; Work's start follows
        #expect(w.h.managers.starts.first?.0 == w.work.id)
    }
    var pluginFailed: NSError { NSError(domain: NEVPNConnectionErrorDomain, code: 12) }

    /// Runs `body` on the main actor in the turn after the settings change that makes `condition` true (observation
    /// fires at the change, before its write is queued, so `body` runs while that write is awaited).
    func landWhen(_ settings: SettingsStore, _ condition: @escaping @MainActor (AppSettings) -> Bool,
                  _ body: @escaping @MainActor () -> Void) {
        withObservationTracking { _ = settings.value } onChange: {
            Task { @MainActor in
                if condition(settings.value) { body() } else { landWhen(settings, condition, body) }
            }
        }
    }

    /// #2: a pending start of another profile is a switch for the crash decision: no app restart of the crashed session
    /// beside that start (it began while the crashed session was still up).
    @Test func noCrashRestartBesideAnotherPendingStart() async throws {
        let fake = FakeSettleClock()
        let h = Harness(settleClock: fake.clock)
        defer { h.dir.cleanup() }
        h.env.profiles.settleAfterSave = .milliseconds(500)
        let (_, work) = try await t4.setUp(h)
        h.env.connection.crashRestartGrace = .zero
        let other = try await h.add("Other.conf", Harness.wgConf, killSwitch: true)
        try await h.env.managers.loadAll()
        let managers = h.managers, service = h.service, otherID = other.id, error = pluginFailed
        fake.onFirstSleep {                                             // inside Work's settle: Other comes and crashes
            await MainActor.run {
                managers.entries[otherID]?.onDemand = true
                managers.emit(otherID, .connecting)
                managers.emit(otherID, .connected)
                service.state.withLock { $0.linkInterruptedAt = Date() }
                managers.lastError = error
                managers.emit(otherID, .disconnecting)
                managers.emit(otherID, .disconnected)
            }
            try? await Task.sleep(for: .milliseconds(300))              // the error read and the crash decision run (grace zero)
        }
        h.env.connection.connect(work.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(await never { h.managers.starts.count > 1 })
        #expect(h.managers.starts.map(\.0) == [work.id])                // never Other's restart beside Work's start
    }

    /// Nit 6 (aad7527): NE's restart lands while the hold's record is being written: no hold, and the end is said like
    /// any end ("stopped unexpectedly").
    @Test func aRestartDuringTheRecordsWriteEndsInNoHold() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        var notices: [ConnectionNotice] = []
        w.h.env.connection.onNotice = { notices.append($0) }
        w.h.managers.emit(w.work.id, .connecting)                       // seen (started elsewhere), never connected
        w.h.managers.lastError = noNetwork
        // At the record's `update` (before its write is queued), NE's restart is queued for the next turn: it lands while
        // the durable write is awaited.
        landWhen(w.h.env.settings, { $0.networkRestartHold == w.work.id }) { [managers = w.h.managers, work = w.work.id] in
            managers.emit(work, .connecting)
        }
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { notices.contains(.stoppedUnexpectedly(w.work.id)) })
        #expect(w.h.env.connection.startHold == nil)
        #expect(await eventually { w.h.env.settings.value.networkRestartHold == nil })
    }

    /// Nit 8 (aad7527) / #4: NE's restart lands during the pause's write: the session is stopped (it is live now) and is
    /// the profile the pause's end reconnects.
    @Test func aRestartDuringThePausesWriteIsStoppedAndReconnectedLater() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        await refused(w)
        landWhen(w.h.env.settings, { $0.autoConnect.pausedUntil != nil }) { [managers = w.h.managers, work = w.work.id] in
            managers.emit(work, .connecting)
        }
        await w.h.env.connection.pause(minutes: 5)
        #expect(await eventually { w.h.managers.stops == [w.work.id] })
        #expect(w.h.env.settings.value.pausedState?.profileID == w.work.id)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
    }

    /// Review fd65f25 nit 2 (f0c8c57 #4, LOW 1): nothing live or held when the pause's write begins; a session goes live
    /// during it (a System Settings start): it is stopped. Round 6 (Fable r6 L1): it is the profile the pause's end
    /// reconnects only if this run saw it connected; one still `.connecting` (a start made elsewhere, possibly refused)
    /// is stopped unsigned.
    @Test(arguments: [false, true]) func aSessionBegunDuringThePausesWriteIsStopped(connected: Bool) async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        #expect(!w.h.env.connection.isBusy)
        landWhen(w.h.env.settings, { $0.autoConnect.pausedUntil != nil }) { [managers = w.h.managers, work = w.work.id] in
            managers.emit(work, .connecting)
            if connected { managers.emit(work, .connected) }
        }
        await w.h.env.connection.pause(minutes: 5)
        #expect(await eventually { w.h.managers.stops == [w.work.id] })
        let expected = connected ? w.work.id : nil
        #expect(w.h.env.settings.value.pausedState?.profileID == expected)
        #expect(AtomicFile.loadJSON(AppSettings.self, from: w.h.dir.data.settings)?.pausedState?.profileID == expected)
    }

    /// #3: an earlier `.disconnecting` → `.invalid` (the manager kept) doesn't stop a later System Settings refusal from
    /// being held.
    @Test func aRefusalAfterAnInvalidIsHeld() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.managers.emit(w.work.id, .disconnecting)                    // an earlier end that NE reported as `.invalid`
        w.h.managers.emit(w.work.id, .invalid)
        #expect(w.h.env.connection.statuses[w.work.id] == .invalid)
        #expect(w.h.env.connection.startHold == nil)
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
    }

    /// #5: a second own session active at launch (not the current one) is watched: its unexpected end goes through the
    /// error read like the current one's.
    @Test func everyActiveOwnSessionAtLaunchIsWatched() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let (_, work) = try await t4.setUp(h)
        let other = try await h.add("Other.conf", Harness.wgConf, killSwitch: true)
        h.managers.entries[work.id]?.status = .connected
        h.managers.entries[other.id]?.status = .connected
        try await h.env.managers.loadAll()
        h.env.connection.start()
        let current = try #require(h.env.connection.currentID)
        #expect([work.id, other.id].contains(current))
        let notCurrent = current == work.id ? other.id : work.id
        h.managers.emit(notCurrent, .disconnecting)
        h.managers.emit(notCurrent, .disconnected)
        #expect(await eventually { h.managers.fetchCount == 1 })        // read like a watched session's end
    }

    // MARK: Negatives

    /// A profile without the kill switch: NE doesn't restart it after code 2 (measured), so no hold.
    @Test func noHoldWithoutTheKillSwitch() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        let split = try await w.h.add("Split.conf", Harness.splitConf, killSwitch: false)
        try await w.h.env.managers.loadAll()
        w.h.env.connection.connect(split.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.managers.entries[w.auto.id]?.onDemand == true })
        #expect(w.h.env.connection.startHold == nil)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
    }

    /// A configuration with on-demand rules is not restarted by NE itself: no hold.
    @Test func noHoldWithOnDemandRules() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(w.work.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.entries[w.work.id]?.onDemand = true
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .connecting)
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.managers.fetchCount == 1 })
        #expect(await never { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(w.h.env.settings.value.networkRestartHold == nil)
    }

    /// After the user's stop the sticky code 2 is no refusal (and the stop cancelled NE's restart): no hold.
    @Test func noHoldAfterAUserStop() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(w.work.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(w.work.id, .connecting)
        w.h.env.connection.disconnect()
        #expect(await eventually { w.h.managers.stops == [w.work.id] })
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.managers.entries[w.auto.id]?.onDemand == true })
        #expect(await never { w.h.env.connection.startHold != nil })
        #expect(w.h.env.settings.value.networkRestartHold == nil)
    }

    /// Before the fix the measured refusal (`.disconnecting` first, no active status) restored at `.disconnected`. Another
    /// error than code 2 keeps the existing "the start ended early" hold with its 10 s fallback.
    @Test func aRefusalWithAnotherErrorKeepsTheStartEndedEarlyHold() async throws {
        let w = try await world()
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(w.work.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.lastError = nil
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(w.h.env.connection.startHold?.reason == .startEndedEarly)
        #expect(await eventually { w.h.managers.fetchCount == 1 })
        #expect(await never { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        await w.timers.fire(w.h.env.connection.systemRestartTimeout)
        #expect(await eventually { w.h.managers.entries[w.auto.id]?.onDemand == true })
    }

    // MARK: E2E-4 200012

    /// LOW: Cancel of a held System Settings refusal, then a second System Settings start of the same profile in the same
    /// run, still offline: it is a new session and its refusal is evaluated fresh (held again). The Cancel's own stop
    /// (`.disconnecting` → `.disconnected`, never an active status) left `userStops` set, so the second refusal read as
    /// a user stop and was dropped; NE restarted the session at the network's return with nothing held.
    @Test func aSecondRefusalAfterACancelIsHeldToo() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        w.h.env.connection.disconnect()
        #expect(w.h.managers.stops == [w.work.id])
        w.h.managers.emit(w.work.id, .disconnecting)                    // NE's stop of the disconnected session
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(w.h.env.connection.startHold == nil)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
        // The second System Settings start, same app run, still offline.
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        #expect(w.h.env.connection.startHold != nil)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(await eventually { w.h.env.settings.value.networkRestartHold == w.work.id })
        // Cancel again stops it again (a fresh stop, not a leftover).
        w.h.env.connection.disconnect()
        #expect(w.h.managers.stops == [w.work.id, w.work.id])
    }

    /// The same Cancel's L-E stays: NE's restart landing within the stop's window is stopped again (no new session first).
    @Test func aRestartRightAfterACancelIsStillStoppedAgain() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        w.h.env.connection.disconnect()
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        w.net.change(to: Self.online)
        w.h.managers.emit(w.work.id, .connecting)
        #expect(await eventually { w.h.managers.stops == [w.work.id, w.work.id] })
    }

    /// A refusal of a profile NE never restarts (no kill switch), started elsewhere, with nothing active: the hero follows
    /// that profile and row 14 says why.
    @Test func aRefusalWithoutAKillSwitchShowsRow14ForThatProfile() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        let split = try await w.h.add("Split.conf", Harness.splitConf, killSwitch: false)
        #expect(w.h.env.connection.currentID != split.id)
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.env.connection.observedError?.code == .noNetwork })
        #expect(w.h.env.connection.currentID == split.id)
        #expect(w.h.env.connection.startHold == nil)
        #expect(w.h.env.settings.value.networkRestartHold == nil)
    }

    /// The same beside another session that is active: the hero stays, Diagnostics gets the problem.
    @Test func aRefusalWithoutAKillSwitchBesideAnActiveSessionIsAProblem() async throws {
        let w = try await world(Self.online)
        defer { w.h.dir.cleanup() }
        let split = try await w.h.add("Split.conf", Harness.splitConf, killSwitch: false)
        w.h.managers.emit(w.work.id, .connecting)
        w.h.managers.emit(w.work.id, .connected)
        #expect(w.h.env.connection.currentID == w.work.id)
        w.net.change(to: Self.offline)
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.env.profiles.problems.contains { $0.message.contains("Split") } })
        #expect(w.h.env.connection.currentID == w.work.id)
        #expect(w.h.env.connection.observedError == nil)
    }

    /// A switch out of an active session, before NE reports `.connecting` for the target: the store holds the start
    /// (row 12a "Waiting for X to disconnect…"), and the derived state shows it, never "Switching/Connecting…".
    @Test func aSwitchBeforeNEsConnectingShowsTheWaitingRow() async throws {
        let w = try await world(Self.online)
        defer { w.h.dir.cleanup() }
        w.h.managers.emit(w.auto.id, .connecting)
        w.h.managers.emit(w.auto.id, .connected)
        w.h.env.connection.connect(w.work.id)
        #expect(w.h.env.connection.switchingTo == w.work.id)
        #expect(w.h.env.connection.currentStatus == .disconnected)
        let hold = try #require(w.h.env.connection.startHold)
        #expect(hold.reason == .waitingForStop(of: w.auto.id))
        let ui = UIMapping.startHold(hold, name: { w.h.env.profiles.profile($0)?.name })
        var i = DerivedStateInputs(profileName: w.work.name)
        i.status = .disconnected; i.switchingTo = w.work.name; i.startHold = ui
        let condition = i.condition
        guard case .startHeld = condition else { Issue.record("expected row 12a, got \(condition)"); return }
        #expect(condition.shortStateWord == "Waiting…")
    }

    /// Review 2518e93 #1: NE may report NOTHING for the Cancel's stop of the already-down session (`stopReport = .silent`,
    /// the fake's default): the stop settles after its grace and the second refusal is evaluated fresh all the same.
    @Test func aSecondRefusalAfterASilentCancelStopIsHeldToo() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.managers.stopReport = .silent
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        w.h.env.connection.disconnect()
        #expect(w.h.managers.stops == [w.work.id])
        await w.timers.fire(ConnectionStore.stopReportGrace)
        #expect(await eventually { w.timers.armed.isEmpty })
        await Task.yield()
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(w.work.id, .disconnecting)
        w.h.managers.emit(w.work.id, .disconnected)
        #expect(await eventually { w.h.env.connection.startHold?.reason == .awaitingNetwork })
        #expect(await eventually { w.h.env.settings.value.networkRestartHold == w.work.id })
    }

    /// Review 2518e93 #1: the app's own next start after a Cancel of a start that waited for a network, refused: held.
    @Test func ourRefusalAfterACancelledWaitForNetworkIsHeld() async throws {
        let w = try await world(Self.offline)
        defer { w.h.dir.cleanup() }
        w.h.env.connection.connect(w.work.id)
        #expect(w.h.env.connection.startHold?.reason == .waitingForNetwork)
        w.h.env.connection.disconnect()
        w.net.change(to: Self.online)
        await w.timers.fire(ConnectionStore.stopReportGrace)
        #expect(await eventually { w.timers.armed.isEmpty })
        await Task.yield()
        await refused(w)
    }

    /// Review 2518e93 #1, second half: a stop elsewhere of a session that is already down (`scutil --nc stop`) reports
    /// `.disconnecting` → `.disconnected` with a sticky older code 2: no row 14, no problem, the hero stays.
    @Test func aStopElsewhereOfADownSessionWithAStaleErrorShowsNothing() async throws {
        let w = try await world(Self.online)
        defer { w.h.dir.cleanup() }
        let split = try await w.h.add("Split.conf", Harness.splitConf, killSwitch: false)
        let before = w.h.env.connection.currentID
        w.h.managers.lastError = noNetwork
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await never { w.h.env.connection.observedError != nil })
        #expect(w.h.env.profiles.problems.isEmpty)
        #expect(w.h.env.connection.currentID == before)
    }
}
