import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// Review H6 / L4: epoch-0 snapshots (an idle profile's latch and lastError) are never dropped as "stale"; the
/// epoch floor resets with a new session; the launch rule waits for a real snapshot.
@MainActor @Suite("Snapshot epochs (H6, L4)", .serialized)
struct SnapshotEpochTests {
    @Test func epochZeroIsNeverStaleAndANewSessionResets() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let c = h.env.connection
        c.apply(snapshot: TunnelSnapshot(profileID: p.id, phase: .connected, epoch: 7), for: p.id)
        c.apply(snapshot: TunnelSnapshot(profileID: p.id, phase: .connected, epoch: 5), for: p.id)
        #expect(c.snapshot?.epoch == 7)                                   // older in the same session: dropped
        let idle = TunnelSnapshot(profileID: p.id, phase: .idle, lastError: LPError(.authFailed), epoch: 0)
        c.apply(snapshot: idle, for: p.id)
        #expect(c.snapshot?.epoch == 0 && c.snapshot?.lastError?.code == .authFailed)   // epoch 0 kept
        c.apply(snapshot: TunnelSnapshot(profileID: p.id, phase: .connected, epoch: 9), for: p.id)
        c.resetSnapshotEpoch()                                            // session end / new attempt
        c.apply(snapshot: TunnelSnapshot(profileID: p.id, phase: .connecting, epoch: 1), for: p.id)
        #expect(c.snapshot?.epoch == 1)
    }

    @Test func theLaunchRuleWaitsForARealSnapshot() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let c = h.env.connection
        c.apply(snapshot: nil, for: p.id)                                 // the first read failed
        let latched = TunnelSnapshot(profileID: p.id, phase: .held, startLatch: StartLatch(code: .authFailed, kind: .hard, notBefore: nil, revision: 1),
                                     lastError: LPError(.authFailed), lastErrorAt: Date(), epoch: 0)
        c.apply(snapshot: latched, for: p.id)
        #expect(c.observedError?.code == .authFailed)                     // the launch rule still ran
    }
}

/// Review M5: a failed answerAuth puts the prompt back with the error.
@MainActor @Suite("Auth answer failure (M5)", .serialized)
struct AuthAnswerFailureTests {
    @Test func theSheetComesBackWithTheError() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Office.ovpn", PreviewSeed.officeOvpn)
        h.env.connection.start()
        UIBinder.bind(h.env)
        h.env.ui.actions.connect(p.id)
        #expect(await eventually { h.env.auth.prompt != nil })
        let prompt = try #require(h.env.auth.prompt)
        h.service.state.withLock { $0.failAll = LPError(.extensionBusy) }
        h.env.ui.actions.submitAuth(AuthAnswer(promptID: prompt.promptID, username: "u", password: "p", response: "", savePassword: false))
        #expect(await eventually { h.env.auth.reshowCount == 1 })
        #expect(h.env.auth.prompt?.promptID == prompt.promptID)
        #expect(await eventually { h.env.ui.auth.prompt?.id == prompt.promptID })
        #expect(await eventually { h.env.ui.auth.error != nil })      // inline in the re-shown sheet, no alert
        #expect(h.managers.starts.isEmpty)
    }
}

/// Review M8: stale user stops and sticky disconnect errors.
@MainActor @Suite("Disconnect attribution (M8)", .serialized)
struct DisconnectAttributionTests {
    @Test func aStopThatProducedNoTransitionDoesNotHideALaterFailure() async throws {
        var clock = Date()
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let c = ConnectionStore(managers: h.env.managers, service: h.service, profiles: h.env.profiles, settings: h.env.settings,
                                now: { clock })
        c.start()
        c.connect(p.id)
        c.disconnect()                                                  // already down: no transition follows
        clock = clock.addingTimeInterval(60)
        h.managers.lastError = NSError(domain: LPTunnelError.errorDomain, code: LPErrorCode.peerUnreachable.rawValue)
        h.service.state.withLock { $0.snapshot = TunnelSnapshot(profileID: p.id, lastError: LPError(.peerUnreachable), lastErrorAt: clock, epoch: 0) }
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .disconnected)
        #expect(await eventually { c.observedError?.code == .peerUnreachable })
    }

    @Test func anOldStickyErrorIsNotThisDisconnects() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.settings.update { $0.lastQuitAt = Date() }                // the launch rule hides the old error too
        h.env.connection.start()
        h.managers.lastError = NSError(domain: LPTunnelError.errorDomain, code: LPErrorCode.authFailed.rawValue)
        h.service.state.withLock { $0.snapshot = TunnelSnapshot(profileID: p.id, lastError: LPError(.authFailed), lastErrorAt: Date().addingTimeInterval(-3600), epoch: 0) }
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        h.managers.emit(p.id, .disconnected)
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.env.connection.observedError == nil)
    }
}
