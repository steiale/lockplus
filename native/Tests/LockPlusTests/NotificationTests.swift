import Foundation
import LPModel
import LPWire
import Testing
@testable import LockPlus

/// §11.7 user notifications: the mode rules, the "no window key" rule, wording (profile name only), the events the
/// stores emit, and the permission flow (asked once; a non-Off mode asks only while undecided).
@MainActor @Suite("User notifications (§11.7)", .serialized)
struct NotificationTests {
    func settle(_ ms: Int = 50) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    @Test func modeRules() {
        let id = UUID()
        typealias P = NotificationPolicy
        #expect(P.shouldPost(.stoppedUnexpectedly(id), mode: .problemsOnly, anyWindowKey: false))
        #expect(P.shouldPost(.needsSignIn(id, reconnect: false), mode: .problemsOnly, anyWindowKey: false))
        #expect(!P.shouldPost(.connected(id), mode: .problemsOnly, anyWindowKey: false))
        #expect(!P.shouldPost(.disconnectedByUser(id), mode: .problemsOnly, anyWindowKey: false))
        #expect(P.shouldPost(.connected(id), mode: .connectDisconnect, anyWindowKey: false))
        #expect(P.shouldPost(.disconnectedByUser(id), mode: .connectDisconnect, anyWindowKey: false))
        #expect(!P.shouldPost(.stoppedUnexpectedly(id), mode: .off, anyWindowKey: false))
        #expect(!P.shouldPost(.stoppedUnexpectedly(id), mode: .connectDisconnect, anyWindowKey: true))
    }

    @Test func wordingNamesTheProfileOnly() {
        let id = UUID()
        let n = NotificationPolicy.notice(.needsSignIn(id, reconnect: true), profileName: "Acme")
        #expect(n.title.contains("Acme"))
        #expect(n.id.hasSuffix(".auth"))
        let s = NotificationPolicy.notice(.stoppedUnexpectedly(id), profileName: "Work")
        #expect(s.body.contains("Work"))
        #expect(s.id == "lp.\(id.uuidString)")
    }

    @Test func anUnexpectedStopIsPostedOnlyWithoutAKeyWindow() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        try await h.env.managers.save(ManagerConfiguration(profile: p, onDemand: nil))
        h.env.connection.start()
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        h.managers.lastError = NSError(domain: LPTunnelError.errorDomain, code: LPErrorCode.peerUnreachable.rawValue)
        h.managers.emit(p.id, .disconnected)
        // Waits for the post itself (a fixed 50 ms settle flaked under a loaded full run).
        #expect(await eventually { h.hooks.posted.count == 1 })   // problems only: no "connected"
        #expect(h.hooks.posted.first?.body.contains("Work") == true)

        h.hooks.windowKey = true
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        h.managers.emit(p.id, .disconnected)
        try await settle()
        #expect(h.hooks.posted.count == 1)                       // a key window suppresses it
    }

    @Test func connectAndDisconnectMode() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        h.env.settings.update { $0.notifications = .connectDisconnect }
        let p = try await h.add("Work.conf", Harness.wgConf)
        try await h.env.managers.save(ManagerConfiguration(profile: p, onDemand: nil))
        h.env.connection.start()
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        h.managers.emit(p.id, .reasserting)
        h.managers.emit(p.id, .connected)                        // a reassert isn't a second "connected"
        h.env.connection.disconnect()
        try await settle()
        h.managers.emit(p.id, .disconnected)
        try await settle()
        #expect(h.hooks.posted.map(\.title) == [String(localized: "Protected", comment: "Notification title"),
                                                String(localized: "Not protected", comment: "Notification title")])
    }

    @Test func authFailuresAreSignInsNotStops() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        try await h.env.managers.save(ManagerConfiguration(profile: p, onDemand: nil))
        h.env.connection.start()
        h.managers.emit(p.id, .connecting)
        h.managers.lastError = NSError(domain: LPTunnelError.errorDomain, code: LPErrorCode.authRequired.rawValue)
        h.managers.emit(p.id, .disconnected)
        try await settle()
        #expect(h.hooks.posted.isEmpty)
        h.env.notify(.needsSignIn(p.id, reconnect: false))
        #expect(h.hooks.posted.count == 1)
    }

    @Test func permissionIsAskedOnceAndOnlyWhileUndecided() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        h.env.ui.actions.requestNotificationPermission()
        try await settle()
        #expect(h.hooks.calls.filter { $0 == "notifications" }.count == 1)
        h.env.ui.actions.requestNotificationPermission()        // already decided: never asks again
        try await settle()
        #expect(h.hooks.calls.filter { $0 == "notifications" }.count == 1)
    }

    @Test func choosingANonOffModeAsksWhileUndecided() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        await h.env.notificationModeChanged(to: .off)
        #expect(!h.hooks.calls.contains("notifications"))
        await h.env.notificationModeChanged(to: .connectDisconnect)
        #expect(h.hooks.calls.contains("notifications"))
    }
}
