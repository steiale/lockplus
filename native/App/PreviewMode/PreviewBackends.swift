// Fable M1: preview mode exists in DEBUG builds only; a Release app can never show simulated protection.
#if DEBUG
import Foundation
import LPModel
import LPParsing
import LPWire
import Observation
import Synchronization

// "No extension" preview mode (launch with LP_PREVIEW_MODE=1, see docs/native/APP-ROOT.md): the real app root,
// stores and UI over simulated NE, XPC and system-extension backends. Nothing here touches NetworkExtension,
// SystemExtensions, the host keychains, login items or the Go app's real data.

/// Shared simulated tunnel state between the fake NE manager and the fake XPC service.
final class PreviewWorld: Sendable {
    struct State: Sendable {
        var connected: UUID?
        /// The profile whose start is pending (its phase is shown, e.g. a sign-in inside the start).
        var starting: UUID?
        var phase: TunnelPhase = .idle
        var sessionID: UUID?
        var sessionStart: Date?
        var provisioned: [UUID: ProvisionedEntry] = [:]
        var lastError: [UUID: LPError] = [:]
        var prompts: [UUID: AuthPrompt] = [:]
        var answered: Set<UUID> = []
        var sessions: [SessionSummary] = []
        var epoch: UInt64 = 0
    }
    let state = Mutex(State())
    let events: AsyncStream<TunnelEvent>
    private let cont: AsyncStream<TunnelEvent>.Continuation

    init() {
        (events, cont) = AsyncStream.makeStream(of: TunnelEvent.self, bufferingPolicy: .bufferingNewest(64))
    }

    func post(_ e: TunnelEvent) { cont.yield(e) }

    func snapshot(_ id: UUID) -> TunnelSnapshot {
        state.withLock { s in
            s.epoch += 1
            let mine = s.connected == id || s.starting == id
            return TunnelSnapshot(profileID: id, phase: mine ? s.phase : .idle, lastError: s.lastError[id],
                                  lastErrorAt: s.lastError[id] == nil ? nil : Date(), endpoint: mine ? "198.51.100.7:51820" : nil,
                                  localAddresses: mine ? ["10.8.0.2"] : [], epoch: s.epoch)
        }
    }
}

/// Fake `ManagerStore`: status transitions on timers, like NE would report them.
@MainActor final class PreviewManagerStore: VPNManaging {
    private struct Entry { var cfg: ManagerConfiguration; var status: TunnelStatus; var onDemand: Bool }
    private var entries: [UUID: Entry] = [:]
    private let world: PreviewWorld
    /// Profiles whose first manual start asks for a CRV1 code inside the start (draft 9: answered into that start).
    var challengeOnStart: Set<UUID> = []
    var onStatusChange: ((UUID, TunnelStatus) -> Void)?
    var onConfigurationChange: (() -> Void)?
    var onStrayStatusChange: (() -> Void)?

    init(world: PreviewWorld) { self.world = world }

    func loadAll() async throws(LPError) {}

    var managers: [ManagerSnapshot] {
        entries.map { id, e in
            ManagerSnapshot(profileID: id, stored: .init(revision: e.cfg.provider.revision, metaRev: e.cfg.provider.metaRev, ownerUID: e.cfg.provider.ownerUID),
                            flags: e.cfg.flags, onDemandEnabled: e.onDemand, status: e.status)
        }
    }

    func save(_ cfg: ManagerConfiguration) async throws(LPError) {
        let old = entries[cfg.profileID]
        entries[cfg.profileID] = Entry(cfg: cfg, status: old?.status ?? .disconnected, onDemand: cfg.onDemand?.enabled ?? false)
    }

    func remove(_ id: UUID) async throws(LPError) { entries[id] = nil }

    func setOnDemandEnabled(_ on: Bool, for id: UUID) async throws(LPError) { entries[id]?.onDemand = on }

    func status(_ id: UUID) -> TunnelStatus { entries[id]?.status ?? .invalid }

    private func set(_ id: UUID, _ s: TunnelStatus) {
        entries[id]?.status = s
        onStatusChange?(id, s)
        world.post(TunnelEvent(kind: .snapshotChanged, profileID: id))
    }

    func start(_ id: UUID, options: [String: NSObject]) throws(LPError) {
        guard entries[id] != nil else { throw LPError(.profileNotProvisioned) }
        guard (options[StartOptionKey.manual] as? NSNumber)?.intValue == 1 else { throw LPError(.malformedRequest) }
        if let other = entries.first(where: { $0.key != id && $0.value.status != .disconnected })?.key { set(other, .disconnected) }
        world.state.withLock { $0.lastError[id] = nil; $0.phase = .starting; $0.starting = id }
        set(id, .connecting)
        let challenge = challengeOnStart.remove(id) != nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.world.state.withLock { $0.phase = .establishing }
            self?.world.post(TunnelEvent(kind: .snapshotChanged, profileID: id))
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.entries[id]?.status == .connecting else { return }
            if challenge {
                // Draft 9: the start stays pending (NE `.connecting`); the answer connects this same start.
                let prompt = AuthPrompt(promptID: UUID(), profileID: id, kind: .dynamicChallenge,
                                        challengeText: "Enter the code from your authenticator app", echo: true,
                                        lockedUsername: "j.appleseed", reason: .initial, savedUsername: nil, nextStart: false,
                                        expiresAt: Date().addingTimeInterval(300))
                self.world.state.withLock { $0.prompts[id] = prompt; $0.phase = .awaitingAuth }
                self.world.post(TunnelEvent(kind: .authRequired, profileID: id, prompt: prompt))
                self.world.post(TunnelEvent(kind: .snapshotChanged, profileID: id))
                while true {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard self.entries[id]?.status == .connecting else { return }
                    let (answered, open) = self.world.state.withLock { ($0.answered.contains(prompt.promptID), $0.prompts[id] != nil) }
                    if answered { break }
                    if !open { return }                                   // cancelled: the app stops the start
                }
                self.world.state.withLock { $0.phase = .establishing }
                try? await Task.sleep(for: .milliseconds(500))
                guard self.entries[id]?.status == .connecting else { return }
            }
            self.world.state.withLock {
                $0.starting = nil
                $0.connected = id
                $0.phase = .connected
                $0.sessionID = UUID()
                $0.sessionStart = Date()
            }
            self.set(id, .connected)
        }
    }

    func stop(_ id: UUID) {
        guard let e = entries[id], e.status != .disconnected else { return }
        set(id, .disconnecting)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.world.state.withLock { s in
                if s.connected == id, let sid = s.sessionID, let start = s.sessionStart {
                    let secs = Date().timeIntervalSince(start)
                    s.sessions.append(SessionSummary(id: sid, profileID: id, start: start, end: Date(),
                                                     rxBytes: UInt64(secs * 1_200_000), txBytes: UInt64(secs * 40_000), endReason: "user"))
                    s.connected = nil
                    s.sessionID = nil
                    s.sessionStart = nil
                }
                if s.starting == id { s.starting = nil; s.prompts[id] = nil }
                s.phase = .idle
            }
            self.set(id, .disconnected)
            self.world.post(TunnelEvent(kind: .sessionEnded, profileID: id))
        }
    }

    func fetchLastDisconnectError(_ id: UUID) async -> NSError? {
        world.state.withLock { $0.lastError[id] }.map { LPTunnelError($0.code, detail: $0.detail) as NSError }
    }
}

/// Fake XPC service.
final class PreviewTunnelService: TunnelServicing {
    let world: PreviewWorld
    let linkUpdates: AsyncStream<ServiceLinkStatus>
    private let linkCont: AsyncStream<ServiceLinkStatus>.Continuation

    init(world: PreviewWorld) {
        self.world = world
        (linkUpdates, linkCont) = AsyncStream.makeStream(of: ServiceLinkStatus.self, bufferingPolicy: .bufferingNewest(4))
    }

    var events: AsyncStream<TunnelEvent> { world.events }

    static let serverHello = ServerHello(extVersion: "2.0.0", extBuild: "preview", capabilities: [.openVPN, .wireGuard, .keyPassphrase])

    func hello() async throws(LPError) -> ServerHello {
        linkCont.yield(ServiceLinkStatus(link: .validated(Self.serverHello), busy: false))
        return Self.serverHello
    }

    func call<Req: Encodable & Sendable, Resp: Decodable & Sendable>(
        _ method: LPMethod, _ request: Req, as: Resp.Type) async throws(LPError) -> Resp {
        let value: Any
        switch method {
        case .tunnelSnapshot:
            guard let r = request as? ProfileRequest else { throw LPError(.malformedRequest) }
            value = world.snapshot(r.profileID)
        case .statistics:
            guard let r = request as? ProfileRequest else { throw LPError(.malformedRequest) }
            value = world.state.withLock { s -> TunnelStatistics in
                guard s.connected == r.profileID, let start = s.sessionStart else {
                    return TunnelStatistics(profileID: r.profileID, sessionID: nil, sessionStart: nil, rxBytes: 0, txBytes: 0,
                                            lastHandshakeAt: nil, sampledAt: Date())
                }
                let t = Date().timeIntervalSince(start)
                let rx = 1_200_000 * t + 400_000 * sin(t / 4) * 4
                let tx = 40_000 * t + 15_000 * sin(t / 3) * 3
                return TunnelStatistics(profileID: r.profileID, sessionID: s.sessionID, sessionStart: start,
                                        rxBytes: UInt64(max(0, rx)), txBytes: UInt64(max(0, tx)),
                                        lastHandshakeAt: Date().addingTimeInterval(-Double(Int(t) % 120)), sampledAt: Date())
            }
        case .listProvisioned:
            value = ListProvisionedReply(entries: world.state.withLock { Array($0.provisioned.values) })
        case .validateProfile:
            guard let r = request as? ValidateProfileRequest else { throw LPError(.malformedRequest) }
            let text = String(decoding: r.payload, as: UTF8.self)
            value = ValidateProfileReply(error: nil, autologin: !text.contains("auth-user-pass"))
        case .pendingAuthPrompt:
            guard let r = request as? ProfileRequest else { throw LPError(.malformedRequest) }
            value = PendingAuthPromptReply(prompt: world.state.withLock { $0.prompts[r.profileID] })
        case .prepareStartAuth:
            guard let r = request as? PrepareStartAuth else { throw LPError(.malformedRequest) }
            let p = AuthPrompt(promptID: UUID(), profileID: r.profileID, kind: r.kind,
                               challengeText: r.kind == .staticChallenge ? "Enter your one-time code" : nil, echo: true,
                               lockedUsername: nil, reason: .initial, savedUsername: "j.appleseed", nextStart: true,
                               expiresAt: Date().addingTimeInterval(600))
            world.state.withLock { $0.prompts[r.profileID] = p }
            value = p
        case .sessionSummaries:
            value = SessionSummariesReply(sessions: world.state.withLock { $0.sessions })
        case .measureLatency:
            value = MeasureLatencyReply(results: [])
        case .pushEndpoints:
            value = PushEndpointsReply(outcome: .notHeld)            // preview starts never hold
        default:
            throw LPError(.malformedRequest, detail: "preview: \(method.rawValue)")
        }
        guard let v = value as? Resp else { throw LPError(.malformedRequest, detail: "preview reply type") }
        return v
    }

    func callVoid<Req: Encodable & Sendable>(_ method: LPMethod, _ request: Req) async throws(LPError) {
        switch method {
        case .provisionProfile:
            guard let r = request as? ProvisionRequest else { throw LPError(.malformedRequest) }
            let digest = PayloadDigest.sha256Hex(String(decoding: r.payload, as: UTF8.self))
            world.state.withLock { $0.provisioned[r.profileID] = ProvisionedEntry(id: r.profileID, revision: r.revision, digest: digest) }
        case .removeProfile:
            if let r = request as? ProfileRequest { _ = world.state.withLock { $0.provisioned.removeValue(forKey: r.profileID) } }
        case .answerAuth:
            if let r = request as? WireAuthAnswer {
                world.state.withLock { s in
                    for (k, p) in s.prompts where p.promptID == r.promptID { s.prompts[k] = nil; s.lastError[k] = nil }
                    s.answered.insert(r.promptID)
                }
            }
        case .cancelAuth:
            if let r = request as? CancelAuthRequest {
                world.state.withLock { s in for (k, p) in s.prompts where p.promptID == r.promptID { s.prompts[k] = nil } }
            }
        case .wipeAllSecrets:
            world.state.withLock { $0.provisioned = [:] }
        default:
            break
        }
    }

    func resetAfterUserAction() async {}
}

/// Fake extension lifecycle: "Installing…" for a moment, then ready. Deactivation reports a cancelled admin dialog,
/// so the uninstall sheet's "component still installed" outcome can be seen.
@MainActor @Observable final class PreviewExtensionStore: ExtensionControlling {
    private(set) var state: SystemExtensionManager.State = .unknown
    private(set) var activationEndedWithoutResult = false
    private(set) var updateInProgress = false
    private(set) var link = ServiceLinkStatus(link: .validated(PreviewTunnelService.serverHello), busy: false)
    @ObservationIgnored var onReady: (@MainActor () -> Void)?
    @ObservationIgnored var onPreflightFinished: (@MainActor () -> Void)?

    func start() {
        activate()
        onPreflightFinished?()
    }

    private func activate() {
        state = .activating
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            state = .ready(version: "2.0.0 (preview)")
            onReady?()
        }
    }

    func retryAfterUserAction() async { activate() }

    func reinstall() async throws(LPError) {
        updateInProgress = true
        defer { updateInProgress = false }
        state = .deactivating
        try? await Task.sleep(for: .milliseconds(600))
        activate()
    }

    func deactivate() async throws(LPError) {
        try? await Task.sleep(for: .milliseconds(600))
        throw LPError(.cancelled, detail: "preview: the administrator dialog was cancelled")
    }

    func openExtensionSettings() {}
}

/// Seed data for preview mode: real profile texts run through the real import pipeline. The keys are the public
/// examples from the WireGuard documentation; the OpenVPN certificate is a placeholder.
enum PreviewSeed {
    static let workConf = """
    [Interface]
    PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
    Address = 10.8.0.2/32, fd00::2/128
    DNS = 10.8.0.1

    [Peer]
    PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
    Endpoint = 198.51.100.7:51820
    AllowedIPs = 0.0.0.0/0, ::/0
    PersistentKeepalive = 25
    """

    static let nasConf = """
    [Interface]
    PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
    Address = 10.9.0.2/32

    [Peer]
    PublicKey = TrMvSoP4jYQlY6RIzBgbssQqY3vxI2Pi+y71lOWWXX0=
    Endpoint = 203.0.113.20:51820
    AllowedIPs = 10.9.0.0/24, 192.168.1.0/24
    """

    static let officeOvpn = """
    client
    dev tun
    proto udp
    remote 203.0.113.44 1194
    auth-user-pass
    cipher AES-256-GCM
    remote-cert-tls server
    verb 3
    <ca>
    -----BEGIN CERTIFICATE-----
    MIIBPreviewPlaceholderCertificateBodyOnlyForTheNoExtensionPreviewMode
    -----END CERTIFICATE-----
    </ca>
    """

    static let otpOvpn = """
    client
    dev tun
    proto tcp
    remote 203.0.113.80 443
    auth-user-pass
    static-challenge "Enter your one-time code" 1
    cipher AES-256-GCM
    remote-cert-tls server
    <ca>
    -----BEGIN CERTIFICATE-----
    MIIBPreviewPlaceholderCertificateBodyOnlyForTheNoExtensionPreviewMode
    -----END CERTIFICATE-----
    </ca>
    """

    static let files: [(String, String)] = [
        ("Work.conf", workConf), ("Home NAS.conf", nasConf), ("Office.ovpn", officeOvpn), ("Remote Desk.ovpn", otpOvpn),
    ]

    /// An in-memory Go app directory for the migration offer in onboarding (never the owner's real data).
    struct GoFixture: GoAppDataSource {
        var sourceDescription: String { "preview fixture" }
        func tunnelEntries() throws -> [GoAppEntry] {
            [GoAppEntry(name: "old-office.conf", kind: .regular), GoAppEntry(name: "old-office.meta.json", kind: .regular)]
        }
        func readTunnelFile(_ name: String, maxBytes: Int) throws -> [UInt8] {
            name.hasSuffix(".meta.json") ? Array(#"{"auto_reconnect":true,"notes":"from the Go app"}"#.utf8)
                                         : Array(nasConf.replacingOccurrences(of: "203.0.113.20", with: "203.0.113.21").utf8)
        }
        func readDataFile(_ name: String, maxBytes: Int) throws -> [UInt8]? {
            name == "config.json" ? Array(#"{"kill_switch":true,"dns_protection":true,"tray_icon_style":"color"}"#.utf8) : nil
        }
    }
}
/// Preview mode's old Go helper: installed and idle until "Remove Old Helper…" (E2E-5 F1) removes it.
final class PreviewLegacySystem: LegacySystemReading {
    private let files = Mutex<Set<String>>([LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary])
    func removeHelper() { files.withLock { $0.removeAll() } }
    func fileExists(_ path: String) -> Bool { files.withLock { $0.contains(path) } }
    func probeHelper() async -> HelperProbe {
        files.withLock { $0.isEmpty } ? .unreachable : .reachable(active: false, killSwitchBlocked: false)
    }
    @MainActor func goGUIRunning() -> Bool { false }
}
#endif
