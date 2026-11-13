import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// 2.0.2 (Codex r9 MEDIUM, carried over from the 2.0.1 reviews): a start's own configuration mutations (the
/// `prepareForStart` saves, the pause of the others' on-demand) re-check, INSIDE the manager serialization, that they
/// still belong to the current attempt, and an automatic retry also that nothing else is busy. Before, an automatic
/// retry's queued save only excluded other users' pending starts, so it could land inside this user's kill-switch start
/// made meanwhile from System Settings (`scutil`): a configuration change inside a `.connecting` kill-switch session
/// leaves it passing no traffic (E2E-4 U2/U13).
@MainActor @Suite("2.0.2: automatic retries never mutate a manager during another start", .serialized, .timeLimit(.minutes(1)))
struct AutomaticRetryMutationTests {
    let a = AnotherTunnelActiveTests()

    /// Parks the next manager operation (a reload) inside the serialization until `release()`.
    final class Gate {
        var k: CheckedContinuation<Void, Never>?
        var parked = false
        func release() { k?.resume(); k = nil }
    }

    func park(_ h: Harness) async -> (Gate, Task<Void, Never>) {
        let gate = Gate()
        h.managers.loadGate = { await withCheckedContinuation { gate.k = $0; gate.parked = true } }
        let reload = Task { _ = try? await h.env.managers.loadAll() }
        _ = await eventually { gate.parked }
        return (gate, reload)
    }

    func saves(_ h: Harness, named prefix: String) -> Int { h.managers.log.filter { $0.hasPrefix("begin save \(prefix)") }.count }

    func didntRetry(_ w: NoNetworkRestartTests.World, _ name: String) -> Bool {
        w.h.env.profiles.problems.contains { $0.message == "LockPlus didn't retry \(name) automatically: another connection is active." }
    }

    /// Split's start fails with `profileNotProvisioned`; its manager is behind (renamed while it connected). The automatic
    /// retry's `prepareForStart` save queues behind another manager operation; meanwhile the kill-switch Work starts
    /// from System Settings. The save never lands inside Work's start, Split isn't started, Work isn't stopped, and
    /// Diagnostics says why.
    @Test func aQueuedPrepareSaveOfAnAutomaticRetryNeverLandsInAnotherStart() async throws {
        let (w, split) = try await a.world()
        defer { w.h.dir.cleanup() }
        w.h.service.state.withLock { $0.holdSnapshots = true; $0.snapshot = nil }
        w.h.env.connection.connect(split.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(split.id, .connecting)
        try await w.h.env.profiles.rename(split.id, to: "Split 2")      // live: its manager waits for the next start
        #expect(w.h.env.profiles.managerIsBehind(try #require(w.h.env.profiles.profile(split.id))))
        w.h.managers.lastError = LPTunnelError(.profileNotProvisioned, detail: "x") as NSError
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.service.heldSnapshotCalls > 0 })
        let (gate, reload) = await park(w.h)
        #expect(gate.parked)
        w.h.managers.log = []
        w.h.service.releaseSnapshots()
        #expect(await eventually { w.h.service.calls(.provisionProfile) > 0 })
        try? await Task.sleep(for: .milliseconds(200))                  // the retry's save is queued behind the reload
        w.h.managers.emit(w.work.id, .connecting)                       // `scutil --nc start` of the kill-switch Work
        gate.release()
        await reload.value
        #expect(await a.never { saves(w.h, named: "Split") > 0 || w.h.managers.starts.count > 1 || w.h.managers.stops.contains(w.work.id) })
        #expect(await eventually { didntRetry(w, "Split 2") })
    }

    /// The same for the pause of the others' on-demand: the automatic retry's pause of Home NAS's on-demand queues
    /// behind another manager operation, Work starts meanwhile: Home NAS's on-demand is left alone, no start.
    @Test func aQueuedPauseOfAnAutomaticRetryNeverLandsInAnotherStart() async throws {
        let (w, split) = try await a.world()
        defer { w.h.dir.cleanup() }
        w.h.service.state.withLock { $0.holdSnapshots = true; $0.snapshot = nil }
        w.h.env.connection.connect(split.id)
        #expect(await eventually { w.h.managers.starts.count == 1 })
        w.h.managers.emit(split.id, .connecting)
        w.h.managers.lastError = LPTunnelError(.profileNotProvisioned, detail: "x") as NSError
        w.h.managers.emit(split.id, .disconnecting)
        w.h.managers.emit(split.id, .disconnected)
        #expect(await eventually { w.h.service.heldSnapshotCalls > 0 })
        // Home NAS's on-demand is on again (configured elsewhere), so the retry's start has to pause it.
        w.h.managers.entries[w.auto.id]?.onDemand = true
        try await w.h.env.managers.loadAll()
        #expect(w.h.env.managers.managers.first { $0.profileID == w.auto.id }?.onDemandEnabled == true)
        let (gate, reload) = await park(w.h)
        final class Seen { var changes: [Bool] = [] }
        let pausedInside = Seen()
        w.h.managers.onSetOnDemand = { id, on in if id == w.auto.id { pausedInside.changes.append(on) } }
        w.h.service.releaseSnapshots()
        #expect(await eventually { w.h.service.calls(.provisionProfile) > 0 })
        try? await Task.sleep(for: .milliseconds(200))                  // the retry's pause is queued behind the reload
        w.h.managers.emit(w.work.id, .connecting)                       // `scutil --nc start` of the kill-switch Work
        gate.release()
        await reload.value
        #expect(await a.never { pausedInside.changes.contains(false) || w.h.managers.starts.count > 1 || w.h.managers.stops.contains(w.work.id) })
        #expect(w.h.managers.entries[w.auto.id]?.onDemand == true)
        #expect(await eventually { didntRetry(w, "Split") })
    }

    /// A stale attempt: the user's Connect queues its `prepareForStart` save, then cancels it (Disconnect) while it
    /// waits. The save of the cancelled attempt never lands and nothing is started.
    @Test func aQueuedPrepareSaveOfACancelledAttemptNeverLands() async throws {
        let (w, split) = try await a.world()
        defer { w.h.dir.cleanup() }
        w.h.env.settings.update { $0.autoConnect.enabled = false }       // nothing to pause
        await w.h.env.profiles.resaveOnDemand()
        w.h.managers.entries[split.id]?.cfg.flags.excludeLocalNetworks.toggle()     // the manager is behind its profile
        try await w.h.env.managers.loadAll()
        #expect(w.h.env.profiles.managerIsBehind(try #require(w.h.env.profiles.profile(split.id))))
        let (gate, reload) = await park(w.h)
        w.h.managers.log = []
        #expect(w.h.env.connection.connect(split.id))
        try? await Task.sleep(for: .milliseconds(200))                  // its save is queued behind the reload
        w.h.env.connection.disconnect()                                 // the user's Cancel
        gate.release()
        await reload.value
        #expect(await a.never { saves(w.h, named: "Split") > 0 || !w.h.managers.starts.isEmpty })
    }
}
