import Foundation
import LPModel
import LPWire
import Testing
@testable import LockPlus

/// Review H3: NE manager operations are serialized, a stale configuration is retried once after a reload, statuses
/// swallowed by a reload are replayed, and nothing is saved before the first successful load.
@MainActor @Suite("NE manager serialization (H3)", .serialized)
struct ManagerSerializationTests {
    func cfg(_ name: String) -> ManagerConfiguration {
        let p = Profile(id: UUID(), name: name, kind: .wireGuard, policy: NetworkPolicy(killSwitch: true), auth: nil, notes: "",
                        summary: ProfileSummary(isFullTunnel: true), payloadRevision: 1, payloadDigest: "d", metaRevision: 1,
                        ownerUID: getuid(), createdAt: Date(), updatedAt: Date(), origin: .editor, importReport: nil, engineVerified: true)
        return ManagerConfiguration(profile: p, onDemand: nil)
    }

    @Test func concurrentMutationsDoNotInterleave() async throws {
        let fake = FakeVPNManager()
        let m = SerializedVPNManager(inner: fake)
        try await m.loadAll()
        fake.log.removeAll()
        async let a: Void = m.save(cfg("A"))
        async let b: Void = m.save(cfg("B"))
        async let c: Void = m.loadAll()
        _ = try await (a, b, c)
        // Every begin is immediately followed by its own end.
        for i in stride(from: 0, to: fake.log.count, by: 2) {
            #expect(fake.log[i].hasPrefix("begin") && fake.log[i + 1] == fake.log[i].replacingOccurrences(of: "begin", with: "end"))
        }
        #expect(fake.log.count == 6)
    }

    /// 2.0.1 round 4 (Codex 2): a conditional save (the protective flag heal) checks its condition when the save is
    /// issued, after waiting for an earlier mutation: the session left `.connected` meanwhile, nothing is saved.
    @Test func aConditionalSaveRechecksAfterTheWait() async throws {
        let fake = FakeVPNManager()
        let m = SerializedVPNManager(inner: fake)
        try await m.loadAll()
        let c = cfg("A")
        try await m.save(c)
        fake.entries[c.profileID]?.status = .connected
        final class Gate { var k: CheckedContinuation<Void, Never>?; var parked = false }
        let gate = Gate()
        fake.loadGate = { await withCheckedContinuation { gate.k = $0; gate.parked = true } }
        let reload = Task { try? await m.loadAll() }                     // an earlier mutation, parked
        while !gate.parked { await Task.yield() }
        let saves = fake.log.filter { $0.hasPrefix("begin save") }.count
        let heal = Task { try? await m.save(c, onlyIf: { m.status(c.profileID) == .connected }) }
        for _ in 0..<20 { await Task.yield() }
        fake.entries[c.profileID]?.status = .reasserting                // it left `.connected` while the heal waited
        gate.k?.resume()
        _ = await reload.value
        #expect(await heal.value == false)
        #expect(fake.log.filter { $0.hasPrefix("begin save") }.count == saves)
        fake.entries[c.profileID]?.status = .connected
        #expect(try await m.save(c, onlyIf: { m.status(c.profileID) == .connected }))
    }

    @Test func aStaleSaveIsRetriedOnceAfterAReload() async throws {
        let fake = FakeVPNManager()
        let m = SerializedVPNManager(inner: fake)
        try await m.loadAll()
        fake.staleNext = true
        let c = cfg("A")
        try await m.save(c)
        #expect(fake.loads == 2)
        #expect(m.managers.map(\.profileID) == [c.profileID])          // the observable snapshot followed
        fake.staleNext = true
        try await m.setOnDemandEnabled(true, for: c.profileID)
        #expect(fake.entries[c.profileID]?.onDemand == true)
    }

    @Test func aReloadReplaysASwallowedTransition() async throws {
        let fake = FakeVPNManager()
        let m = SerializedVPNManager(inner: fake)
        let c = cfg("A")
        try await m.loadAll()
        try await m.save(c)
        var seen: [TunnelStatus] = []
        m.onStatusChange = { _, s in seen.append(s) }
        fake.emit(c.profileID, .connected)
        fake.entries[c.profileID]?.status = .disconnected               // happened while the connection objects were replaced
        try await m.loadAll()
        #expect(seen == [.connected, .disconnected])
        try await m.loadAll()                                           // no change: nothing replayed
        #expect(seen.count == 2)
    }

    @Test func nothingIsSavedBeforeAFirstSuccessfulLoad() async throws {
        let fake = FakeVPNManager()
        fake.loadError = LPError(.extensionUnavailable, detail: "denied")
        let m = SerializedVPNManager(inner: fake)
        await #expect(throws: LPError.self) { try await m.save(cfg("A")) }
        #expect(fake.entries.isEmpty)
        fake.loadError = nil
        try await m.save(cfg("A"))                                      // loads first, then saves
        #expect(fake.entries.count == 1)
    }

    @Test func connectionStoreSeesTheReplay() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        h.managers.entries[p.id]?.status = .disconnected
        try await h.env.managers.loadAll()
        #expect(h.env.connection.statuses[p.id] == .disconnected)
    }
}
