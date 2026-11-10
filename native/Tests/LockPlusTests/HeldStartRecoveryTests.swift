import Foundation
import LPModel
import LPWire
import NetworkExtension
import Synchronization
import Testing
@testable import LockPlus

/// PENDING-FOLD 50–53, app side: fresh endpoint IPs pushed into a held start, the `http-proxy` resolved before a
/// start, the restart after a tunnel-process crash for on-demand kill-switch profiles, and its "reconnected" copy.
@MainActor @Suite("Held start recovery and crash restart (PF 50–53)", .serialized)
struct HeldStartRecoveryTests {
    static let hostConf = """
    [Interface]
    PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
    Address = 10.8.0.2/32
    DNS = 10.8.0.1

    [Peer]
    PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
    Endpoint = vpn.example.com:51820
    AllowedIPs = 0.0.0.0/0, ::/0
    """

    static func held(_ id: UUID, _ code: LPErrorCode, before: Bool = true, nonRetryable: Bool = false) -> TunnelSnapshot {
        TunnelSnapshot(profileID: id, phase: .held, holdReason: nonRetryable ? .nonRetryable(code) : .blockedAfterFailure(code),
                       holdBeforeConnected: before, lastError: LPError(code))
    }

    func harness(resolved: [String: [String]]) -> (Harness, FixtureNetworkWatcher) {
        let net = FixtureNetworkWatcher()
        let h = Harness(network: net)
        h.env.connection.endpointPushSettle = .zero
        h.env.connection.crashRestartGrace = .zero
        h.env.connection.resolveEndpoints = { @Sendable _ in resolved }
        return (h, net)
    }

    // MARK: PF 50

    @Test(arguments: [LPErrorCode.dnsResolutionFailed, .connectTimeout, .peerUnreachable, .endpointInterfaceUnusable])
    func networkChangePushesFreshIPsIntoAHeldStart(code: LPErrorCode) async throws {
        let (h, net) = harness(resolved: ["vpn.example.com": ["198.51.100.9", "198.51.100.9", "2001:db8::9"]])
        defer { h.dir.cleanup() }
        let p = try await h.add("Home.conf", Self.hostConf, killSwitch: true)
        h.env.connection.start()
        net.onChange = { h.env.connection.networkChanged($0) }
        net.start()
        h.managers.emit(p.id, .connecting)
        h.service.state.withLock { $0.snapshot = Self.held(p.id, code) }
        net.change(to: "satisfied|wifi:en0,wiredEthernet:en7")
        #expect(await eventually { h.service.state.withLock { $0.pushes.count } == 1 })
        let r = try #require(h.service.state.withLock { $0.pushes.first })
        #expect(r.profileID == p.id && r.endpoints == ["vpn.example.com": ["198.51.100.9", "2001:db8::9"]])   // de-duplicated
    }

    /// E2E-3: leaving a network pushes nothing (a retry then has no interface; WireGuard's socket went into its own
    /// tunnel); arriving at one pushes, once.
    @Test func pushOnlyOnArrivingAtANetwork() async throws {
        let (h, net) = harness(resolved: ["vpn.example.com": ["198.51.100.9"]])
        defer { h.dir.cleanup() }
        h.env.connection.endpointPushSettle = .milliseconds(200)
        let p = try await h.add("Home.conf", Self.hostConf, killSwitch: true)
        h.env.connection.start()
        net.onChange = { h.env.connection.networkChanged($0) }
        net.start()
        h.managers.emit(p.id, .connecting)
        h.service.state.withLock { $0.snapshot = Self.held(p.id, .connectTimeout) }
        net.change(to: "unsatisfied|")                                  // leaving: no push, not even after the settle
        try await Task.sleep(for: .milliseconds(450))
        #expect(h.service.state.withLock { $0.pushes.isEmpty })
        net.change(to: "unsatisfied|wifi:en0")                          // arriving: one push
        #expect(await eventually { h.service.state.withLock { $0.pushes.count } == 1 })
        try await Task.sleep(for: .milliseconds(450))
        #expect(h.service.state.withLock { $0.pushes.count } == 1)
        #expect(!ConnectionStore.isArrival("unsatisfied|"))
        #expect(ConnectionStore.isArrival("unsatisfied|wifi:en0"))
    }

    @Test func wakePushesToo() async throws {
        let (h, _) = harness(resolved: ["vpn.example.com": ["198.51.100.9"]])
        defer { h.dir.cleanup() }
        let p = try await h.add("Home.conf", Self.hostConf, killSwitch: true)
        h.env.connection.start()
        h.managers.emit(p.id, .connecting)
        h.service.state.withLock { $0.snapshot = Self.held(p.id, .connectTimeout) }
        h.env.connection.didWake()
        #expect(await eventually { h.service.state.withLock { $0.pushes.count } == 1 })
    }

    /// Nothing is pushed for a hold fresh IPs can't fix, an after-Connected hold, a C16 hold, the same network, or
    /// when nothing resolved.
    @Test func noPushOutsideARecoverableHold() async throws {
        let (h, net) = harness(resolved: ["vpn.example.com": ["198.51.100.9"]])
        defer { h.dir.cleanup() }
        let p = try await h.add("Home.conf", Self.hostConf, killSwitch: true)
        h.env.connection.start()
        net.onChange = { h.env.connection.networkChanged($0) }
        net.start()
        h.managers.emit(p.id, .connecting)
        var n = 0
        for snap in [Self.held(p.id, .serverIdentityMismatch), Self.held(p.id, .connectTimeout, before: false),
                     Self.held(p.id, .authFailed, nonRetryable: true), TunnelSnapshot(profileID: p.id, phase: .connecting)] {
            h.service.state.withLock { $0.snapshot = snap }
            n += 1
            net.change(to: "satisfied|wifi:en\(n)")
            try await Task.sleep(for: .milliseconds(50))
        }
        h.service.state.withLock { $0.snapshot = Self.held(p.id, .connectTimeout) }
        net.change(to: net.current)                                      // same network: no trigger
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.service.state.withLock { $0.pushes.isEmpty })
        h.env.connection.resolveEndpoints = { @Sendable _ in [:] }       // nothing resolved (the hold blocks DNS)
        net.change(to: "satisfied|wifi:en9")
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.service.state.withLock { $0.pushes.isEmpty })
    }

    @Test func pushableEndpointsFollowTheWireRules() {
        let m = ConnectionStore.pushableEndpoints(["a.example": ["192.0.2.1", "192.0.2.1", "fe80::1%en0", "x"], "192.0.2.5": ["192.0.2.6"],
                                                   "b.example": [], "c.example": (0..<20).map { "198.51.100.\($0)" }])
        #expect(m == ["a.example": ["192.0.2.1"], "c.example": (0..<16).map { "198.51.100.\($0)" }])
        #expect(EndpointMapRules.isValid(m))
        #expect(PushEndpointsRequest.appliesTo(Self.held(UUID(), .dnsResolutionFailed), profileID: UUID()) == false)
    }

    // MARK: PF 51

    static let proxyOvpn = """
    client
    dev tun
    proto tcp
    remote vpn.example.com 443
    http-proxy proxy.example 8080
    cipher AES-256-GCM
    remote-cert-tls server
    <ca>
    -----BEGIN CERTIFICATE-----
    MIIBPreviewPlaceholderCertificateBodyOnlyForTheNoExtensionPreviewMode
    -----END CERTIFICATE-----
    </ca>
    """

    @Test func startResolvesTheProxyHostWithTheRemotes() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let asked = LockBox<[String]>([])
        h.env.connection.resolveEndpoints = { @Sendable e in
            asked.set(e)
            return ["vpn.example.com": ["192.0.2.4"], "proxy.example": ["198.51.100.8"]]
        }
        let p = try await h.add("Proxy.ovpn", Self.proxyOvpn, killSwitch: false)
        #expect(p.summary.proxyEndpoint == "proxy.example:8080")
        h.env.connection.start()
        h.env.connection.connect(p.id)
        #expect(await eventually { !h.managers.starts.isEmpty })
        #expect(asked.value == ["vpn.example.com:443", "proxy.example:8080"])
        let eps = h.managers.starts.first?.1[StartOptionKey.endpoints] as? [String: [String]]
        #expect(eps == ["vpn.example.com": ["192.0.2.4"], "proxy.example": ["198.51.100.8"]])
    }

    @Test func importWarnsWhenTheProxyHostDoesNotResolve() async {
        var s = ProfileSummary(endpoints: ["vpn.example:443"], transport: "tcp")
        let none: @Sendable ([String]) async -> [String: [String]] = { _ in [:] }
        #expect(await ImportCoordinator.proxyCheck(ImportReport(), summary: s, resolve: none).items.isEmpty)   // no proxy
        s.proxyEndpoint = "198.51.100.8:8080"
        #expect(await ImportCoordinator.proxyCheck(ImportReport(), summary: s, resolve: none).items.isEmpty)   // a literal
        s.proxyEndpoint = "proxy.example:8080"
        let warned = await ImportCoordinator.proxyCheck(ImportReport(), summary: s, resolve: none)
        #expect(warned.items.map(\.reason) == [.proxyHostUnresolved] && warned.items.first?.group == .securityWarning)
        let ok = await ImportCoordinator.proxyCheck(ImportReport(), summary: s, resolve: { @Sendable _ in ["proxy.example": ["198.51.100.8"]] })
        #expect(ok.items.isEmpty)
    }

    // MARK: PF 52

    @Test func crashRestartPolicyTable() {
        let now = Date()
        func d(_ s: TunnelStatus = .disconnected, od: Bool = true, ian: Bool = true, user: Bool = false, sw: Bool = false,
               paused: Bool = false, recent: [Date] = []) -> CrashRestartPolicy.Decision {
            CrashRestartPolicy.decide(status: s, onDemandEnabled: od, includeAllNetworks: ian, userStopped: user, switching: sw,
                                      paused: paused, recentRestarts: recent, now: now)
        }
        #expect(d() == .restart)
        #expect(d(.connecting) != .restart)                              // NE (or on-demand) already restarted it
        #expect(d(od: false) == .expectSystemRestart)                    // NE's own restart covers it (S2 E1, review R1)
        #expect(d(.connecting, od: false) != .expectSystemRestart)       // already back: nothing to expect
        #expect(d(ian: false) != .restart)
        #expect(d(user: true) != .restart && d(sw: true) != .restart && d(paused: true) != .restart)
        #expect(d(recent: [now, now, now].map { $0.addingTimeInterval(-60) }) != .restart)     // crash loop: the user decides
        #expect(d(recent: [now, now, now].map { $0.addingTimeInterval(-601) }) == .restart)
    }

    /// A tunnel-process crash as the app sees it: the XPC link is interrupted (the process died), then NE reports
    /// `.disconnected` with `pluginFailed`. (In the tests the session connected just now, so the interruption is "now":
    /// it must follow the last `.connected`; the real ~5 s lead is in `freshCrashSignalTable`.)
    func crashed(_ h: Harness, _ id: UUID) {
        h.service.state.withLock { $0.linkInterruptedAt = Date() }
        h.managers.lastError = NSError(domain: NEVPNConnectionErrorDomain, code: 12)
        h.managers.emit(id, .disconnected)
    }

    @Test func freshCrashSignalTable() {
        let off = Date()
        func fresh(_ dt: TimeInterval?, connected: Bool = true, connectedAgo: TimeInterval? = 3600) -> Bool {
            CrashRestartPolicy.isFreshCrash(wasConnected: connected, linkInterruptedAt: dt.map { off.addingTimeInterval($0) },
                                            connectedAt: connectedAgo.map { off.addingTimeInterval(-$0) }, disconnectedAt: off)
        }
        #expect(fresh(-5))                                               // S2 E1: the link drops ~5 s before NE says so
        #expect(fresh(0.5))
        #expect(!fresh(nil))                                             // no interruption at all: a sticky 12
        #expect(!fresh(-60))                                             // an earlier crash's interruption
        #expect(!fresh(5))                                               // the process exited after a clean stop
        #expect(!fresh(-5, connected: false))                            // never connected: no PF 52/53
        #expect(!fresh(-5, connectedAgo: 2))                             // before the session's last .connected
    }

    /// Review PF-R1: an earlier crash leaves `pluginFailed` sticky; a later clean on-demand Disconnect (trusted SSID, a
    /// stop from System Settings or another user) reports it again and must not be restarted or called a crash.
    @Test func stickyPluginFailedOnACleanDisconnectRestartsNothing() async throws {
        let (h, _) = harness(resolved: [:])
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.managers.entries[p.id]?.onDemand = true
        var notices: [ConnectionNotice] = []
        h.env.connection.start()
        h.env.connection.onNotice = { notices.append($0) }
        h.service.state.withLock { $0.linkInterruptedAt = Date().addingTimeInterval(-600) }     // the earlier crash
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        h.managers.lastError = NSError(domain: NEVPNConnectionErrorDomain, code: 12)             // sticky
        h.managers.emit(p.id, .disconnected)                                                    // on-demand Disconnect
        #expect(await eventually { h.managers.fetchCount >= 1 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.managers.starts.isEmpty)
        notices.removeAll()
        h.managers.emit(p.id, .connecting)                                                      // on-demand connects again
        h.managers.emit(p.id, .connected)
        #expect(notices == [.connected(p.id)] && h.env.connection.restartedAfterCrash == nil)
        // No interruption ever recorded: the same.
        h.service.state.withLock { $0.linkInterruptedAt = nil }
        h.managers.emit(p.id, .disconnected)
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.managers.starts.isEmpty)
    }

    /// The positive case beside it: after a sticky-12 clean disconnect (nothing), a crash this disconnect saw → one
    /// restart, and the "reconnected" copy.
    @Test func freshCrashAfterAStickyCleanDisconnectRestarts() async throws {
        let (h, _) = harness(resolved: [:])
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.managers.entries[p.id]?.onDemand = true
        h.env.connection.start()
        h.service.state.withLock { $0.linkInterruptedAt = Date().addingTimeInterval(-600) }
        h.managers.emit(p.id, .connected)
        h.managers.lastError = NSError(domain: NEVPNConnectionErrorDomain, code: 12)
        h.managers.emit(p.id, .disconnected)
        #expect(await eventually { h.managers.fetchCount >= 1 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.managers.starts.isEmpty)
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        crashed(h, p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        #expect(h.env.connection.restartedAfterCrash == p.id)
    }

    @Test func onDemandKillSwitchProfileIsRestartedWithOnDemandSemantics() async throws {
        let (h, _) = harness(resolved: [:])
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.managers.entries[p.id]?.onDemand = true
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        crashed(h, p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        let (id, options) = try #require(h.managers.starts.first)
        #expect(id == p.id && options.isEmpty)                           // no lp.manual: the latch applies
        #expect(StartOptionsBuilder.crashRestart.isEmpty)
    }

    @Test func noAppRestartWhereNERestartsOrTheUserActed() async throws {
        let (h, _) = harness(resolved: [:])
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.env.connection.start()
        h.managers.emit(p.id, .connected)
        crashed(h, p.id)                                                 // no on-demand rules: NE restarts it itself
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.managers.starts.isEmpty)
        h.managers.entries[p.id]?.onDemand = true
        h.managers.emit(p.id, .connected)
        h.env.connection.disconnect()                                    // the user's stop
        h.managers.lastError = NSError(domain: NEVPNConnectionErrorDomain, code: 12)
        h.managers.emit(p.id, .disconnected)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.managers.starts.isEmpty)
    }

    // MARK: PF 53

    @Test func reconnectAfterACrashIsAnnouncedOnce() async throws {
        let (h, _) = harness(resolved: [:])
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        var notices: [ConnectionNotice] = []
        h.env.connection.start()
        h.env.connection.onNotice = { notices.append($0) }
        h.managers.emit(p.id, .connected)
        crashed(h, p.id)
        #expect(await eventually { notices.contains(.stoppedUnexpectedly(p.id)) })
        notices.removeAll()
        h.managers.emit(p.id, .connecting)                               // NE's own restart
        h.managers.emit(p.id, .connected)
        #expect(h.env.connection.restartedAfterCrash == p.id)
        #expect(notices == [.reconnectedAfterRestart(p.id)])             // instead of "Connected to …"
        UIBinder.render(h.env)
        #expect(h.env.ui.connection.reconnectedAfterRestart)
        h.env.connection.disconnect()
        #expect(h.env.connection.restartedAfterCrash == nil)
        UIBinder.render(h.env)
        #expect(!h.env.ui.connection.reconnectedAfterRestart)
        // A later ordinary connect is an ordinary "Connected".
        h.managers.emit(p.id, .disconnected)
        notices.removeAll()
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        #expect(notices == [.connected(p.id)] && h.env.connection.restartedAfterCrash == nil)
    }

    @Test func reconnectCopyInEnglishAndGerman() throws {
        let n = NotificationPolicy.notice(.reconnectedAfterRestart(UUID()), profileName: "Work")
        #expect(n.title == "Protected" && n.body == "Reconnected to Work after a tunnel process restart.")
        #expect(ConnectionUIModel.reconnectedAfterRestartText == "Reconnected after a tunnel process restart.")
        #expect(!ConnectionNotice.reconnectedAfterRestart(UUID()).isProblem)
        let path = try #require(Bundle.main.path(forResource: "de", ofType: "lproj"))
        let de = try #require(Bundle(path: path))
        #expect(de.localizedString(forKey: "Reconnected after a tunnel process restart.", value: nil, table: "Localizable")
                == "Nach einem Neustart des Tunnelprozesses wieder verbunden.")
        #expect(de.localizedString(forKey: "Reconnected to %@ after a tunnel process restart.", value: nil, table: "Localizable")
                == "Nach einem Neustart des Tunnelprozesses wieder mit %@ verbunden.")
    }
}

/// A Sendable box for values a `@Sendable` closure records.
// SAFETY: every access to `v` goes through `lock`.
final class LockBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func set(_ n: T) { lock.withLock { v = n } }
}
