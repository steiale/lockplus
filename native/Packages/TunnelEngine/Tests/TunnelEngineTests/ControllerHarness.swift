import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

typealias TestController = TunnelController<ManualClock>
typealias Phase = TestController.Phase

/// `TunnelController` with `FakeAdapter`, `FakeHost`, a `ManualClock` (every deadline) and a manual wall clock (§15.1).
final class Harness: Sendable {
    let clock = ManualClock()
    let wall = MutableWallClock()
    let host = FakeHost()
    /// `routed`: the controller talks to the production router (`ProviderHostRouter`) over per-start fake hosts that the
    /// test binds itself (Codex review 1), instead of `host`.
    let router = ProviderHostRouter<FakeHost>()
    let secrets = InMemorySecretStore()
    let state: InMemoryTunnelStateStore
    let factory = FakeAdapterFactory()
    let sink = FakeEventSink()
    let paths = FakePathSource()
    let interfaceCheck: FakeInterfaceCheck
    let controller: TestController
    let pid: UUID
    let owner: uid_t = 501
    let kind: VPNProtocolKind
    let policy: NetworkPolicy
    let onDemandRules: Bool

    let includeAllNetworks: Bool

    /// `killSwitch: true` is a full-tunnel kill switch (`includeAllNetworks`) unless `routeProtection` (split tunnel,
    /// `enforceRoutes`) says otherwise.
    init(pid: UUID = UUID(), kind: VPNProtocolKind = .openVPN, killSwitch: Bool = false, routeProtection: Bool = false,
         onDemandRules: Bool = false,
         rejectPayload: Bool = false, flaggedInterface: String? = nil, dataPlane: DataPlane = .utunFD,
         state: (UUID) -> PersistedTunnelState = { _ in .init() }, routed: Bool = false,
         configure: (inout ControllerConfig) -> Void = { _ in }) {
        self.pid = pid; self.kind = kind; self.onDemandRules = onDemandRules
        let state = state(pid)
        policy = NetworkPolicy(killSwitch: killSwitch)
        includeAllNetworks = killSwitch && !routeProtection
        self.state = InMemoryTunnelStateStore(state)
        var cfg = ControllerConfig(); cfg.dataPlane = dataPlane; configure(&cfg)
        interfaceCheck = FakeInterfaceCheck(flaggedInterface)
        controller = TestController(host: routed ? router : host, secrets: secrets, stateStore: self.state, adapters: factory,
                                    validator: FakeValidator(reject: rejectPayload), clock: clock,
                                    wallClock: wall.function, rng: SplitMix64(seed: 1), pathSource: paths,
                                    endpointCheck: interfaceCheck, sink: sink, config: cfg)
    }

    func provision(revision: UInt64 = 1, password: String? = "pw", payload: String? = nil) async {
        try? await secrets.put(.payload, pid, ownerUID: owner, revision: revision, .text(payload ?? Self.payload(kind)))
        if let password {
            try? await secrets.put(.credential, pid, ownerUID: owner, revision: revision,
                                   CredentialCodec.encode(CredentialSecrets(username: .text("alice"), password: .text(password))))
        }
    }

    /// The hostnames the harness profile references (the controller caches IPs for these only, review PF-R4).
    static let referencedHosts = ["vpn.example", "a.example", "b.example"]
    static func payload(_ kind: VPNProtocolKind) -> String {
        switch kind {
        case .openVPN: "client\n" + referencedHosts.map { "remote \"\($0)\" \"1194\"\n" }.joined()
        case .wireGuard: "[Interface]\n" + referencedHosts.map { "[Peer]\nEndpoint = \($0):51820\n" }.joined()
        }
    }

    func config(revision: UInt64 = 1) -> ProviderConfiguration {
        ProviderConfiguration(profileID: pid, kind: kind, revision: revision, ownerUID: owner, policy: policy, hasOnDemandRules: onDemandRules,
                              includeAllNetworks: includeAllNetworks)
    }

    func start(manual: Bool = true, endpoints: [String: [String]] = [:], revision: UInt64 = 1,
               dataPlaneOverride: DataPlane? = nil) -> Task<Result<Void, LPTunnelError>, Never> {
        let req = StartRequest(options: StartOptions(isManual: manual, endpoints: endpoints), configuration: config(revision: revision),
                               dataPlaneOverride: dataPlaneOverride)
        let c = controller
        return Task {
            do throws(LPTunnelError) { try await c.start(req); return .success(()) } catch { return .failure(error) }
        }
    }

    /// The n-th adapter once its `start` was called.
    func adapter(_ n: Int = 0) async -> FakeAdapter {
        let ok = await waitUntil { self.factory.adapters.count > n && self.factory.adapters[n].started }
        precondition(ok, "adapter \(n) never started")
        return factory.adapters[n]
    }

    var phase: Phase { get async { await controller.currentPhase } }

    func waitPhase(_ p: Phase) async -> Bool { await waitUntil { await self.controller.currentPhase == p } }

    static let plan = NetworkPlan(ipv4: [.init("10.8.0.2", 24)], includedRoutes4: [.init("10.20.0.0", 16)],
                                  redirectGateway: .init(v4: true), dns: DNSPlan(servers: ["10.8.0.1"]), remoteAddress: "198.51.100.7")

    /// manual start → settings applied → data plane up → connected.
    @discardableResult
    func connect(manual: Bool = true) async -> FakeAdapter {
        let t = start(manual: manual)
        let a = await adapter(factory.adapters.count)
        let ticket = a.requestSettings(Self.plan)
        _ = await ticket.value()
        a.finishStart()
        if case .failure(let e) = await t.value { Issue.record("start failed \(e.code)") }
        _ = await waitPhase(.connected)
        return a
    }

    /// Advances `clock` once at least `sleepers` are registered.
    func advance(_ c: ManualClock, by d: Duration, sleepers: Int = 1) async {
        _ = await waitUntil { c.sleeperCount >= sleepers }
        c.advance(by: d)
    }

    func code(_ r: Result<Void, LPTunnelError>) -> LPErrorCode? { if case .failure(let e) = r { return e.code }; return nil }
    var key: ProfileKey { ProfileKey(ownerUID: owner, profileID: pid) }
    var latch: StartLatch? { state.load().latches[key]?.latch }
}

extension AuthChallenge {
    static func crv1(_ cookie: String = "CRV1:R,E:c3RhdGU=:YWxpY2U=:Enter code") -> AuthChallenge {
        AuthChallenge(kind: .dynamicChallenge, reason: .initial, challengeText: "Enter code", lockedUsername: "alice", cookie: .text(cookie))
    }
}
