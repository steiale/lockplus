import Foundation
import LPModel
import LPWire
import os
import Synchronization

/// Events the controller pushes to the app side (P2a's XPC layer fans them out by owner uid, §5.2).
public protocol TunnelEventSink: Sendable {
    func authRequired(_ prompt: AuthPrompt, ownerUID: uid_t)
    func sessionEnded(profileID: UUID, error: LPError, ownerUID: uid_t)
    func snapshotChanged(_ snapshot: TunnelSnapshot, ownerUID: uid_t?)
    /// T15: an answer or cancel settled `promptID`; the owner's other app instances close their prompt.
    func promptResolved(promptID: UUID, profileID: UUID, ownerUID: uid_t)
}

/// Engine-side re-validation of the provisioned payload (§8.1 [1]–[6], §9.1). The Tunnel target binds LPParsing.
public protocol PayloadValidator: Sendable {
    func validate(kind: VPNProtocolKind, payload: SecretBytes) throws(LPTunnelError)
    /// The `validateProfile` verdict (§8.1 [7a] fields included). `disableClientCert` nil = derived from the payload.
    func evaluate(kind: VPNProtocolKind, payload: SecretBytes, disableClientCert: Bool?) -> ValidateProfileReply
}

extension PayloadValidator {
    /// Validators without [7a] facts: the verdict is `validate`'s.
    public func evaluate(kind: VPNProtocolKind, payload: SecretBytes, disableClientCert: Bool?) -> ValidateProfileReply {
        do throws(LPTunnelError) { try validate(kind: kind, payload: payload); return ValidateProfileReply(error: nil) } catch {
            return ValidateProfileReply(error: LPError(error.code, detail: error.detail))
        }
    }
}

public struct ControllerConfig: Sendable {
    // Draft 9 (S2 E14b): no start budget. macOS has no start time limit (withheld starts of 50 s … 1000 s were never
    // stopped), so a start ends on success, on the user's stop, or by the §7.2 rows; only the connect deadline and
    // the prompt deadlines bound an engine attempt.
    public var wgConnectDeadline: Duration = .seconds(45)
    public var ovpnConnectDeadline: Duration = .seconds(50)
    public var authDeadline: Duration = .seconds(600)
    public var reassertBudget: Duration = .seconds(300)       // kill switch off; unbounded with it on
    public var attemptTimeout: Duration = .seconds(15)
    public var wakeAttemptTimeout: Duration = .seconds(30)
    public var wakeGrace: Duration = .seconds(10)
    public var watchdogInterval: Duration = .seconds(10)
    public var sleepCap: Duration = .seconds(2)
    public var stopCap: Duration = .seconds(5)
    public var pathDebounce: Duration = .milliseconds(500)
    public var resendGuard: TimeInterval = 60
    public var dataPlane: DataPlane = .utunFD
    public var backoff = Backoff()
    /// PF 50 (review PF-R4): accepted `pushEndpoints` per session; past it a push answers `.unchanged`.
    public var maxPushesPerSession = 10
    /// Residual 2 (review 2026-10-30): immediate retries of a pending start when the device ARRIVES at a network, per
    /// session. Past it a retry waits for its own schedule (hold backoff, connect deadline).
    public var maxArrivalRetriesPerSession = 10
    public init() {}
}

/// Draft 9 (S2): every deadline in the extension runs on the strict clock (`DispatchSourceTimer`, `.strict`, leeway 0).
public typealias ProductionTunnelController = TunnelController<StrictSuspendingClock>

/// DESIGN §7.1/§7.2: all state and transitions of one NE session. Every `await` is a reentrancy point; after each
/// one the controller re-checks `epoch` (adapter generation) and the phase before acting (§7.1 contract).
/// `clock` drives every deadline (connect, prompt, hold retry, backoff, watchdog, stop cap); in production it is
/// `StrictSuspendingClock`.
///
/// Draft 9 rules from S2 (DESIGN §7.2, §10.1.1):
/// - **Withhold before Connected** (E14b/E14c): with `includeAllNetworks`, a failure before Connected never completes
///   the start (a failed start is OPEN); the start stays pending in `held` with the adapter down (blocked, E14a).
///   Retryable failures retry inside the hold with the backoff; it ends on the user's stop (completing the start with
///   the held error), a successful retry, or a change/removal of the profile.
/// - **Auth inside the pending start** (E14b): every first-connect prompt is `awaitingAuth(beforeConnected: true)`;
///   the answer starts a new engine attempt in the same start. No start option ever carries a secret (E1 replays them).
/// - **No `cancelTunnelWithError` under the kill switch** (E3: it is open, and NE never calls `stopTunnel` after it).
///   Without the kill switch the adapter is stopped and the summary written BEFORE the cancel.
public actor TunnelController<C: Clock> where C.Duration == Duration {

    // MARK: phase

    public enum Phase: Equatable, Sendable {
        case idle, starting, connecting, establishing
        case awaitingAuth(beforeConnected: Bool)
        case connected
        case reasserting(ReconnectReason)
        case sleeping
        case held(HoldReason)
        case stopping

        var tunnelPhase: TunnelPhase {
            switch self {
            case .idle: .idle
            case .starting: .starting
            case .connecting: .connecting
            case .establishing: .establishing
            case .awaitingAuth: .awaitingAuth
            case .connected: .connected
            case .reasserting: .reasserting
            case .sleeping: .sleeping
            case .held: .held
            case .stopping: .stopping
            }
        }
        var isBeforeConnectedRunning: Bool {
            switch self {
            case .starting, .connecting, .establishing, .awaitingAuth(beforeConnected: true): true
            default: false
            }
        }
    }

    final class Session {
        let config: ProviderConfiguration?
        let options: StartOptions
        /// `ControllerConfig.dataPlane`, or the request's FaultInjection override; fixed for the session.
        let dataPlane: DataPlane
        var adapter: (any TunnelAdapter)?
        var events: AdapterEventSink?
        var startGate: CheckedContinuation<Result<Void, LPTunnelError>, Never>?
        var startTask: Task<Void, Never>?
        var startCompleted = false
        /// The answer the NEXT engine attempt of this start uses (a `prepareStartAuth` answer, or an in-start answer
        /// with the challenge's cookie and carried base credentials). Handed to exactly one attempt.
        var answer: StashBinding?
        var lastSpec: TunnelSettingsSpec?
        var flaggedInterface: String?
        /// hostname → IPs for this session (the start's own resolution over the cache, §9.3).
        var endpoints: [String: [String]] = [:]
        /// PF 50: IPs the owner's app pushed into this held start (`pushEndpoints`); merged over the start options.
        var pushedEndpoints: [String: [String]] = [:]
        /// PF 50: pushes this session accepted (`ControllerConfig.maxPushesPerSession`).
        var pushesAccepted = 0
        /// Arrivals at a network that retried this pending start at once (`ControllerConfig.maxArrivalRetriesPerSession`).
        var arrivalRetries = 0
        /// Review PF-R2: the engine attempt in flight carries a one-shot answer (an OTP, a prepared answer).
        var answerAttempt = false
        /// Review PF-R4: the hostnames the payload references (lowercased); only these are cached.
        var referencedHosts: Set<String> = []
        /// Draft 9 withhold: the failure a before-Connected hold completes the start with on a stop, and its reason
        /// (kept while the held start retries, so the snapshot keeps saying "blocked").
        var heldError: LPTunnelError?
        var heldReason: HoldReason?
        var sessionID: UUID?
        var connectedAt: Date?
        var attempt: UInt32 = 0
        var nextRetryAt: Date?
        var backoff: Backoff
        var reassertRemaining: Duration?
        var reassertArmedAt: C.Instant?
        var reassertReason: ReconnectReason = .engine
        var wakeAt: C.Instant?
        var stats = AdapterStats()
        /// T10: slept while an after-Connected prompt was showing; `wake()` restores `.awaitingAuth`.
        var sleptInAuth = false
        var authDeadlinePassedAsleep = false
        /// T15: the stored username, offered as `savedUsername` in this session's prompts (not secret, ≤ 512 B).
        var savedUsername: String?
        init(config: ProviderConfiguration?, options: StartOptions, dataPlane: DataPlane, backoff: Backoff) {
            self.config = config; self.options = options; self.dataPlane = dataPlane; self.backoff = backoff
        }
        var key: ProfileKey? { config.map(ProfileKey.init) }
        var c16: Bool { !options.isManual || (config?.hasOnDemandRules ?? false) }
        /// `includeAllNetworks` or route protection (after-Connected hold, never cancel).
        var killSwitch: Bool { config?.policy.killSwitch ?? false }
        /// `includeAllNetworks` (draft 9: withhold before Connected, no provider DNS).
        var includeAllNetworks: Bool { config?.includeAllNetworks ?? false }
        /// The start is pending and waits on the user or a retry (held, or a prompt that ended the engine attempt).
        var isWaitingBeforeConnected: Bool { !startCompleted && startGate != nil }
    }

    enum TimerKind: Hashable { case connect, attempt, retry, heldRetry, reassertBudget, authDeadline, watchdog, pathDebounce }

    // MARK: dependencies

    private let host: any ProviderHost
    private let secrets: any ExtensionSecretStore
    private let stateStore: any TunnelStateStore
    private let adapters: any TunnelAdapterFactory
    private let validator: (any PayloadValidator)?
    private let clock: C
    private let wallClock: @Sendable () -> Date
    private var rng: any RandomNumberGenerator
    private let pathSource: (any PathSource)?
    private let endpointCheck: (any EndpointInterfaceCheck)?
    private let sink: (any TunnelEventSink)?
    public let config: ControllerConfig

    // MARK: state

    public private(set) var phase: Phase = .idle { didSet { if phase != oldValue { publish() } } }
    private(set) var epoch: UInt64 = 0
    private var session: Session?
    private var persisted: PersistedTunnelState
    private var broker = AuthBroker()
    private var timers: [TimerKind: (token: UInt64, task: Task<Void, Never>)] = [:]
    private var timerToken: UInt64 = 0
    private var teardowns: [UInt64: Task<Void, Never>] = [:]     // each removes itself when done (hold retries)
    private var teardownSeq: UInt64 = 0
    private var pump: PacketFlowPump?
    private var pathTask: Task<Void, Never>?
    private var lastPath: PathSnapshot?
    private var pendingPath: PathSnapshot?
    private var eventTask: Task<Void, Never>?
    private var statsSampledAt: Date?

    public init(host: any ProviderHost, secrets: any ExtensionSecretStore, stateStore: any TunnelStateStore,
                adapters: any TunnelAdapterFactory, validator: (any PayloadValidator)?, clock: C,
                wallClock: @escaping @Sendable () -> Date = { Date() },
                rng: any RandomNumberGenerator = SystemRandomNumberGenerator(),
                pathSource: (any PathSource)? = nil, endpointCheck: (any EndpointInterfaceCheck)? = nil,
                sink: (any TunnelEventSink)? = nil, config: ControllerConfig = ControllerConfig()) {
        self.host = host; self.secrets = secrets; self.stateStore = stateStore; self.adapters = adapters
        self.validator = validator; self.clock = clock; self.wallClock = wallClock
        self.rng = rng; self.pathSource = pathSource; self.endpointCheck = endpointCheck; self.sink = sink
        self.config = config
        persisted = stateStore.load()
    }

    // MARK: - startTunnel

    /// Completes (returns or throws) exactly once per call. Draft 9: with `includeAllNetworks` it returns only on
    /// Connected or throws only when the user stops (or the profile changes): failures before Connected are held.
    public func start(_ req: StartRequest) async throws(LPTunnelError) {
        let now = wallClock()
        // Row idle → starting, FIRST: an on-demand start against a latch does no credential or network I/O. Without
        // the flag it fails at once; with `includeAllNetworks` it is held (a failed start would be open, E14c).
        var latched: StartLatch?
        if !req.options.isManual, let cfg = req.configuration, let l = persisted.latches[ProfileKey(cfg)]?.latch,
           l.kind == .hard || (l.notBefore.map { now < $0 } ?? false) {
            engineLog.info("start latched: \(l.code.rawValue)")
            guard cfg.includeAllNetworks else { throw LPTunnelError(l.code, detail: "start latched") }
            latched = l
        }
        while session != nil {
            // NE never starts while a session runs; a stale session left by a cancel is torn down first. A loop, not
            // an `if`: a concurrent start must never overwrite (and leak the continuation of) another start's session.
            await stop(reason: .other(-1))
        }
        let result: Result<Void, LPTunnelError> = await withCheckedContinuation { k in
            beginStart(req, k, latched: latched)
        }
        switch result { case .success: return; case .failure(let e): throw e }
    }

    private func beginStart(_ req: StartRequest, _ k: CheckedContinuation<Result<Void, LPTunnelError>, Never>, latched: StartLatch?) {
        epoch &+= 1
        let s = Session(config: req.configuration, options: req.options, dataPlane: req.dataPlaneOverride ?? config.dataPlane,
                        backoff: config.backoff)
        s.startGate = k
        session = s
        phase = .starting
        // Residual 2: watch the path from the START, not from Connected, so arriving at a network during a pending
        // start retries it at once instead of waiting out the connect deadline (`retryPendingStartOnArrival`).
        stopPathWatcher()                    // review R12: a watcher that outlived a session carries a stale baseline
        startPathWatcher()
        if let l = latched {
            // Held with no I/O: a `.hard` latch never retries; a `.backoff` latch retries at its `notBefore`.
            let wait = l.kind == .backoff ? l.notBefore.map { max(0, $0.timeIntervalSince(wallClock())) } : nil
            enterHold(LPTunnelError(l.code, detail: "start latched"),
                      reason: l.kind == .hard ? .nonRetryable(l.code) : .blockedAfterFailure(l.code), retryAfter: wait)
            return
        }
        if req.options.isManual, let cfg = req.configuration {
            let key = ProfileKey(cfg)
            clearLatch(key)                                    // §7.2: a manual start clears it
            broker.expire(now: wallClock())
            s.answer = broker.takePrepared(key, now: wallClock())   // a prepareStartAuth answer, for this start only
        }
        let ep = epoch
        s.startTask = Task { await self.runStarting(ep) }
    }

    /// One engine attempt of the pending start: load and re-validate, then `adapter.start`. Also the entry for a
    /// retry inside a hold and for the new attempt after an in-start answer.
    private func runStarting(_ ep: UInt64) async {
        guard let s = session, ep == epoch, phase == .starting else { return }
        guard let cfg = s.config else { beforeConnectedFailure(.of(.profileInvalid, "no providerConfiguration"), ep); return }
        let pid = cfg.profileID
        let key = ProfileKey(cfg)

        var payload: SecretBytes?
        var creds: CredentialSecrets?
        do throws(LPError) {
            // H1: the payload is looked up in the namespace of the uid the NE configuration names, so a start only
            // ever reads that uid's item. The ownerUID/id comparison below is a consistency check on the store's
            // answer, NOT a security boundary. `providerConfiguration.ownerUID` is app-asserted, and S2 E13 showed
            // another local user can start our configuration: accepted for v2.0 (§1.3 A2, §20).
            let found = try await secrets.entry(.payload, pid, ownerUID: cfg.ownerUID)
            guard current(ep, .starting) else { return }
            guard let entry = found, entry.ownerUID == cfg.ownerUID, entry.id == pid else {
                throw LPError(.profileNotProvisioned)
            }
            if cfg.revision > entry.revision { throw LPError(.profileRevisionStale) }
            payload = try await secrets.get(.payload, pid, ownerUID: entry.ownerUID)
            guard current(ep, .starting) else { return }
            if payload == nil { throw LPError(.profileNotProvisioned) }
            // C16 resend guard: no STORED credentials within 60 s of an AUTH_FAILED (an answer is fresh input).
            let guarded = persisted.authFailedAt[key].map { wallClock().timeIntervalSince($0) < config.resendGuard } ?? false
            if let c = try await secrets.get(.credential, pid, ownerUID: entry.ownerUID), var d = CredentialCodec.decode(c) {
                s.savedUsername = d.username.flatMap { u in u.withUnsafeBytes { String(validating: $0, as: UTF8.self) } }
                // T14: the guard withholds only the stored username/password; key passphrase and proxy credentials stay.
                if guarded { d.username = nil; d.password = nil }
                creds = d
            }
            guard current(ep, .starting) else { return }
        } catch {
            beforeConnectedFailure(LPTunnelError(error.code, detail: error.detail), ep); return
        }
        do throws(LPTunnelError) {
            try validator?.validate(kind: cfg.kind, payload: payload!)
        } catch {
            beforeConnectedFailure(error.code == .profileInvalid ? error : .of(.profileInvalid, error.detail), ep); return
        }
        // §9.3 (draft 9, S2 E10): endpoints are resolved BEFORE the start, by the app; the cache fills the gaps. The
        // adapters use these IPs; under includeAllNetworks they resolve nothing themselves.
        let map = effectiveEndpoints(s, key)
        s.endpoints = map
        s.referencedHosts = EndpointHostnames.referenced(kind: cfg.kind, payload: payload!)
        var ips: [String] = []
        for h in map.keys.sorted() { for ip in map[h] ?? [] where !ips.contains(ip) { ips.append(ip) } }
        s.flaggedInterface = endpointCheck?.nonPrimaryInterface(for: ips)

        // starting → connecting
        phase = .connecting
        armConnectDeadline(cfg)
        let adapter = adapters.makeAdapter(kind: cfg.kind)
        let (stream, cont) = AsyncStream.makeStream(of: AdapterEvent.self, bufferingPolicy: .unbounded)
        s.adapter = adapter
        s.events = cont
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await ev in stream { await self?.handle(ev) }
        }
        if s.dataPlane == .packetFlow && pump == nil { pump = PacketFlowPump(flow: host.packetFlow) }
        let binding = s.answer
        s.answer = nil
        s.answerAttempt = binding != nil
        let req = AdapterStart(profileID: pid, payload: payload!, credentials: creds, stash: binding, policy: cfg.policy,
                               connectTimeout: cfg.kind == .wireGuard ? config.wgConnectDeadline : config.ovpnConnectDeadline,
                               endpoints: map, providerDNS: !cfg.includeAllNetworks, dataPlane: s.dataPlane, pump: pump,
                               interactiveKind: cfg.interactiveKind)
        do throws(AdapterStartError) {
            try await adapter.start(req, events: cont, epoch: ep)
            adapterStarted(ep)
        } catch {
            adapterStartFailed(error, ep)
        }
    }

    private func armConnectDeadline(_ cfg: ProviderConfiguration) {
        arm(.connect, after: cfg.kind == .wireGuard ? config.wgConnectDeadline : config.ovpnConnectDeadline) {
            $0.connectDeadlineFired()
        }
    }

    private func current(_ ep: UInt64, _ p: Phase) -> Bool { ep == epoch && phase == p && session != nil }

    private func adapterStarted(_ ep: UInt64) {
        guard ep == epoch, let s = session, s.startGate != nil, phase.isBeforeConnectedRunning else { return }
        cancel(.connect); cancel(.heldRetry); cancel(.authDeadline)
        broker.live = nil
        s.startCompleted = true
        s.heldError = nil; s.heldReason = nil
        s.attempt = 0; s.nextRetryAt = nil; s.backoff.reset()
        s.sessionID = UUID()
        s.connectedAt = wallClock()
        phase = .connected
        completeStart(.success(()))
        if let key = s.key {
            broker.clearRejections(key); persisted.authFailedAt[key] = nil; clearLatch(key)
            if !s.options.endpoints.isEmpty || !s.pushedEndpoints.isEmpty {
                cacheEndpoints(s.endpoints, key, referenced: s.referencedHosts)                        // last good resolution
            }
        }
        armWatchdog()
        // A new monitor: it reports the current path first, which becomes the connected baseline (the pending-start
        // baseline may have been "no network", and our own tunnel coming up must not read as a change).
        stopPathWatcher()
        startPathWatcher()
        let adapter = s.adapter
        Task { [weak self] in
            guard let st = await adapter?.statistics() else { return }
            await self?.noteStats(st, ep)
        }
    }

    private func noteStats(_ st: AdapterStats, _ ep: UInt64) {
        guard ep == epoch, let s = session, let key = s.key else { return }
        s.stats = st
        if !st.resolvedEndpoints.isEmpty {
            var m = persisted.endpointHosts[key] ?? [:]
            for (h, ips) in st.resolvedEndpoints { m[h] = ips }
            cacheEndpoints(m, key, referenced: s.referencedHosts)
        }
        publish()
    }

    /// The start's endpoint map: the cache, the start options over it, the app's pushed IPs over both (PF 50).
    private func effectiveEndpoints(_ s: Session, _ key: ProfileKey) -> [String: [String]] {
        var map = persisted.endpointHosts[key] ?? [:]
        for (h, ips) in s.options.endpoints { map[h] = ips }
        for (h, ips) in s.pushedEndpoints { map[h] = ips }      // PF 50: the app's fresher resolution wins
        return map
    }

    /// Review PF-R4: the persisted cache holds only hostnames the profile references, at most `EndpointMapRules.maxHosts`
    /// (the app's options and pushes may name others; they are used for the attempt, never kept).
    private func cacheEndpoints(_ m: [String: [String]], _ key: ProfileKey, referenced: Set<String>) {
        var kept: [String: [String]] = [:]
        for h in m.keys.sorted() where referenced.contains(h) && kept.count < EndpointMapRules.maxHosts { kept[h] = m[h] }
        let value = kept.isEmpty ? nil : kept
        if value != persisted.endpointHosts[key] { persisted.endpointHosts[key] = value; save() }
    }

    private func adapterStartFailed(_ err: AdapterStartError, _ ep: UInt64) {
        guard ep == epoch, let s = session, s.startGate != nil else { return }
        switch err {
        case .auth(let ch): inStartAuth(ch, ep)
        case .failed(let e): beforeConnectedFailure(mapTimeout(e), ep)
        }
    }

    /// `.endpointInterfaceUnusable` replaces `.connectTimeout`/`.peerUnreachable` when the start-time check flagged
    /// the endpoint (§9.3).
    private func mapTimeout(_ e: LPTunnelError) -> LPTunnelError {
        if let iface = session?.flaggedInterface, e.code == .connectTimeout || e.code == .peerUnreachable {
            return .of(.endpointInterfaceUnusable, iface)
        }
        return e
    }

    // MARK: auth inside the pending start (draft 9, §7.2, §8.4)

    /// The engine attempt ended with a prompt (CRV1, AUTH_FAILED, NEED_CREDS, SESSION_EXPIRED). A manual start keeps
    /// the NE start pending in `awaitingAuth(beforeConnected: true)` until the answer, the prompt deadline (10 min,
    /// CRV1 5 min) or a cancel; the answer gets a NEW client in the same start. An on-demand start has nobody to
    /// answer: the §7.2 failure rows with a `.hard` latch (C16: never resend).
    private func inStartAuth(_ ch: AuthChallenge, _ ep: UInt64) {
        guard ep == epoch, let s = session, s.startGate != nil, let cfg = s.config else { return }
        let key = ProfileKey(cfg)
        let now = wallClock()
        // Review PF-R2: a prompt is no longer a pushable hold (an on-demand start re-enters one below).
        s.heldError = nil; s.heldReason = nil
        if let old = broker.live, old.beforeConnected {
            // The attempt ended while an AUTH_PENDING prompt was showing: that prompt is dead (review nit).
            broker.live = nil
            sink?.promptResolved(promptID: old.prompt.promptID, profileID: old.prompt.profileID, ownerUID: old.ownerUID)
        }
        if ch.rejectedStoredCredentials { clearStoredPassword(key) }
        if ch.reason == .rejected {
            if ch.rejectedStoredCredentials || ch.kind == .userPass { persisted.authFailedAt[key] = now; save() }
            if broker.recordRejection(key, now: now) >= AuthBroker.rejectionLimit {
                beforeConnectedFailure(.of(.authFailed, "3 rejections"), ep); return     // third within 10 min: .fatal rows
            }
        }
        guard s.options.isManual else {
            let code: LPErrorCode = (ch.reason == .rejected && ch.kind != .dynamicChallenge) ? .authFailed : .authRequired
            beforeConnectedFailure(LPTunnelError(code), ep)
            return
        }
        teardownAdapter()                                  // single-use client; the answer gets a new one (§7.3)
        cancel(.connect)
        let ttl = AuthBroker.ttl(for: ch.kind)
        let p = AuthPrompt(promptID: UUID(), profileID: cfg.profileID, kind: ch.kind, challengeText: ch.challengeText, echo: ch.echo,
                           lockedUsername: ch.lockedUsername, reason: ch.reason, savedUsername: Self.offered(ch.kind, s.savedUsername),
                           nextStart: false, expiresAt: now.addingTimeInterval(ttl))
        broker.live = .init(prompt: p, ownerUID: cfg.ownerUID, beforeConnected: true, challenge: ch, restartsEngine: true)
        phase = .awaitingAuth(beforeConnected: true)
        arm(.authDeadline, after: .seconds(ttl)) { $0.authDeadlineFired() }
        sink?.authRequired(p, ownerUID: cfg.ownerUID)
    }

    private func clearStoredPassword(_ key: ProfileKey) {
        let secrets = secrets
        Task {
            // §6.6: AUTH_FAILED with saved credentials clears the extension's password copy, never the username.
            // L2: the record is re-written under the owner of the EXISTING entry; the NE configuration's ownerUID only
            // selects the namespace to look in, and no record is ever created by this path.
            guard let e = try? await secrets.entry(.credential, key.profileID, ownerUID: key.ownerUID),
                  let raw = try? await secrets.get(.credential, e.id, ownerUID: e.ownerUID), var c = CredentialCodec.decode(raw) else { return }
            c.password = nil
            try? await secrets.put(.credential, e.id, ownerUID: e.ownerUID, revision: e.revision, CredentialCodec.encode(c))
        }
    }

    // MARK: - adapter events

    private func handle(_ ev: AdapterEvent) async {
        switch ev {
        case .networkSettings(let plan, let ticket, let ep):
            guard ep == epoch, session != nil else { ticket.answer(.failed(.startCancelled)); return }
            await applyPlan(plan, ticket, ep)
        case .reconnecting(let r, let ep):
            guard ep == epoch else { return }
            if phase == .connected { enterReasserting(r, callAdapter: false) }
        case .reconnected(let ep):
            guard ep == epoch else { return }
            reconnected()
        case .authRequired(let ch, let ep):
            guard ep == epoch else { return }
            engineAuthRequired(ch)
        case .fatal(let e, let ep):
            guard ep == epoch else { return }
            handleFatal(e)
        }
    }

    private func applyPlan(_ plan: NetworkPlan, _ ticket: EstablishTicket, _ ep: UInt64) async {
        guard let s = session, let cfg = s.config else { ticket.answer(.failed(.startCancelled)); return }
        if phase == .connecting { phase = .establishing }
        let spec: TunnelSettingsSpec
        do throws(LPTunnelError) {
            spec = try NetworkSettingsBuilder.spec(for: plan, policy: cfg.policy, profileID: cfg.profileID)
        } catch {
            ticket.answer(.failed(error.code)); handleFatal(error); return
        }
        if spec != s.lastSpec {           // MUST (S11): re-apply only when the plan changed
            do throws(LPTunnelError) {
                try await host.apply(spec)
            } catch {
                ticket.answer(.failed(.networkSettingsFailed))
                guard ep == epoch else { return }
                handleFatal(.of(.networkSettingsFailed, error.detail)); return
            }
            guard ep == epoch, session === s else { ticket.answer(.failed(.startCancelled)); return }
            s.lastSpec = spec
        }
        switch s.dataPlane {
        case .utunFD:
            if let fd = host.tunnelFileDescriptor(matching: plan.primaryAddress) { ticket.answer(.fd(fd)) }
            else { ticket.answer(.failed(.tunDeviceFailed)) }
        case .packetFlow:
            ticket.answer(.applied)
        }
    }

    private func engineAuthRequired(_ ch: AuthChallenge) {
        guard let s = session, let cfg = s.config else { return }
        let now = wallClock()
        if !s.startCompleted {
            // A mid-attempt prompt (AUTH_PENDING: the engine keeps waiting for an out-of-band approval): awaitingAuth
            // inside the pending start, bounded by the 10 min auth deadline (draft 9: no start budget).
            guard phase.isBeforeConnectedRunning, phase != .awaitingAuth(beforeConnected: true) else { return }
            cancel(.connect)
            let p = AuthPrompt(promptID: UUID(), profileID: cfg.profileID, kind: ch.kind, challengeText: ch.challengeText, echo: ch.echo,
                               lockedUsername: ch.lockedUsername, reason: ch.reason, savedUsername: Self.offered(ch.kind, s.savedUsername),
                               nextStart: false, expiresAt: now.addingTimeInterval(config.authDeadline.seconds))
            broker.live = .init(prompt: p, ownerUID: cfg.ownerUID, beforeConnected: true, challenge: ch, restartsEngine: false)
            phase = .awaitingAuth(beforeConnected: true)
            arm(.authDeadline, after: config.authDeadline) { $0.authDeadlineFired() }
            sink?.authRequired(p, ownerUID: cfg.ownerUID)
            return
        }
        // After Connected (reasserting): pause the reconnect budget; 10 min auth deadline (L-RC-4).
        guard phase != .stopping, !isHeld else { return }
        let key = ProfileKey(cfg)
        if ch.reason == .rejected, broker.recordRejection(key, now: now) >= AuthBroker.rejectionLimit {
            handleFatal(.of(.authFailed, "3 rejections")); return
        }
        if ch.rejectedStoredCredentials { clearStoredPassword(key); persisted.authFailedAt[key] = now; save() }
        cancel(.attempt); cancel(.retry); cancel(.watchdog)
        pauseReassertBudget()
        host.setReasserting(true)
        let p = AuthPrompt(promptID: UUID(), profileID: cfg.profileID, kind: ch.kind, challengeText: ch.challengeText, echo: ch.echo,
                           lockedUsername: ch.lockedUsername, reason: ch.reason, savedUsername: Self.offered(ch.kind, s.savedUsername),
                           nextStart: false, expiresAt: now.addingTimeInterval(config.authDeadline.seconds))
        broker.live = .init(prompt: p, ownerUID: cfg.ownerUID, beforeConnected: false, challenge: ch, restartsEngine: false)
        phase = .awaitingAuth(beforeConnected: false)
        arm(.authDeadline, after: config.authDeadline) { $0.authDeadlineFired() }
        sink?.authRequired(p, ownerUID: cfg.ownerUID)
    }

    private var isHeld: Bool { if case .held = phase { return true }; return false }

    /// The username to prefill: only for prompts that ask for one.
    static func offered(_ kind: AuthKind, _ saved: String?) -> String? {
        kind == .userPass || kind == .staticChallenge ? saved : nil
    }

    // MARK: - fatal rows (§7.2)

    private func handleFatal(_ e: LPTunnelError) {
        guard let s = session else { return }
        if !s.startCompleted { beforeConnectedFailure(mapTimeout(e)) } else { afterConnectedFatal(e) }
    }

    /// Before Connected (the start completion is pending). Latches first (C16, unchanged); then:
    /// - `includeAllNetworks` (draft 9, S2 E14): WITHHOLD. The start stays pending, `held` with the adapter down
    ///   (blocked: E14a). A retryable failure retries inside the hold with the backoff; a non-retryable one, and
    ///   `.dnsResolutionFailed` (no new IPs can appear inside the hold), waits for the user. No `setReasserting`.
    /// - otherwise: fail the start with `e`, as before.
    /// `ep` (when given) is the engine attempt the failure belongs to (T6: a stale attempt never fails a newer one).
    private func beforeConnectedFailure(_ e: LPTunnelError, _ ep: UInt64? = nil) {
        guard let s = session, s.startGate != nil, ep.map({ $0 == epoch }) ?? true else { return }
        let key = s.key
        teardownAdapter()
        cancel(.connect); cancel(.authDeadline)
        if let l = broker.live, l.beforeConnected {
            broker.live = nil
            sink?.promptResolved(promptID: l.prompt.promptID, profileID: l.prompt.profileID, ownerUID: l.ownerUID)
        }
        recordLastError(e, key)
        let preLogin = e.code == .secretStoreUnavailable && e.detail == SecretStoreDetail.lockedBeforeLogin
        let nonRetryable = e.code.isNonRetryable && !preLogin
        if let key, s.c16 {
            if preLogin {
                armLatch(key, e.code, .backoff)     // §6.3: on-demand retries after login without a tight loop
            } else if nonRetryable {
                armLatch(key, e.code, .hard)        // C16 rows win over kill-switch rows
                sessionEnded(e)
            } else if s.killSwitch {
                armLatch(key, e.code, .backoff)     // retryable kill-switch failure under on-demand
            }
        }
        if s.includeAllNetworks {
            let reason: HoldReason = s.c16 && nonRetryable ? .nonRetryable(e.code) : .blockedAfterFailure(e.code)
            // Review L4: under the flag nothing inside the hold can add endpoint IPs (no provider DNS; the app resolves
            // only when the user connects), so a resolution failure waits for the user instead of retrying the same map.
            let waitsForUser = nonRetryable || e.code == .dnsResolutionFailed
            var retry: TimeInterval?
            if !waitsForUser {
                s.attempt &+= 1
                retry = s.backoff.next(using: &rng).seconds
            }
            enterHold(e, reason: reason, retryAfter: retry)
            return
        }
        completeStart(.failure(e))
        endSession(reason: "error:\(e.code.rawValue)")
    }

    /// Draft 9 withhold: `held(reason)` before Connected, the start completion still pending (NE status `.connecting`,
    /// blocked), the adapter already down. `retryAfter` schedules one retry of the whole start sequence.
    private func enterHold(_ e: LPTunnelError, reason: HoldReason, retryAfter: TimeInterval?) {
        guard let s = session, !s.startCompleted else { return }
        s.heldError = e
        s.heldReason = reason
        cancel(.connect); cancel(.authDeadline); cancel(.heldRetry)
        if let d = retryAfter {
            s.nextRetryAt = wallClock().addingTimeInterval(d)
            arm(.heldRetry, after: .seconds(d)) { $0.heldRetryFired() }
        } else {
            s.nextRetryAt = nil
        }
        phase = .held(reason)
        publish()
    }

    /// A retry inside a before-Connected hold: the whole start sequence again (reload, re-validate, new adapter).
    private func heldRetryFired() {
        guard let s = session, case .held = phase, s.isWaitingBeforeConnected else { return }
        s.nextRetryAt = nil
        phase = .starting
        let ep = epoch
        s.startTask = Task { await self.runStarting(ep) }
    }

    /// After Connected: C16 hold, kill-switch hold (`holdBlocked`), or (kill switch off only) cancel.
    private func afterConnectedFatal(_ e: LPTunnelError) {
        guard let s = session, phase != .stopping else { return }
        if isHeld { return }
        recordLastError(e, s.key)
        cancelSessionTimers()
        broker.live = nil
        if s.c16 && e.code.isNonRetryable {
            teardownAdapter()
            phase = .held(.nonRetryable(e.code))
            host.setReasserting(true)
            sessionEnded(e)
        } else if s.killSwitch {
            // S2 E3/E4: `cancelTunnelWithError` is OPEN under the flag; `held` with the adapter down blocks (and
            // `reasserting` alone would not: E4r). The user's Disconnect ends it.
            teardownAdapter()          // closes only the engine's dup; NE's utun fd and the session stay (§7.3)
            phase = .held(.blockedAfterFailure(e.code))
            host.setReasserting(true)
        } else {
            cancelAfterTeardown(e)
        }
    }

    /// Kill switch off only. S2 E3: NE never calls `stopTunnel` after `cancelTunnelWithError`, so everything
    /// `stopTunnel` would do happens first: the adapter stops (its descriptors close), the session summary is written,
    /// the pump and the path watcher end. Only then the cancel.
    private func cancelAfterTeardown(_ e: LPTunnelError) {
        guard let s = session else { return }
        guard !s.killSwitch else {             // never under the kill switch: hold instead
            teardownAdapter(); phase = .held(.blockedAfterFailure(e.code)); host.setReasserting(true); return
        }
        cancelSessionTimers()
        teardownAdapter()
        let pending = Array(teardowns.values)
        stopPathWatcher()
        endSession(reason: "error:\(e.code.rawValue)")
        let host = host
        Task {
            for t in pending { await t.value }
            host.cancel(with: e)               // L-LC-1: as soon as the teardown is done
        }
    }

    // MARK: - reasserting

    private func enterReasserting(_ reason: ReconnectReason, callAdapter: Bool) {
        guard let s = session, s.startCompleted else { return }
        cancel(.watchdog)
        host.setReasserting(true)
        phase = .reasserting(reason)
        s.reassertReason = reason
        if s.reassertRemaining == nil {             // new episode
            s.attempt = 0; s.backoff.reset()
            if !s.killSwitch { s.reassertRemaining = config.reassertBudget; resumeReassertBudget() }
        }
        publish()
        if reason == .noNetwork { cancel(.attempt); cancel(.retry); return }   // wait for a satisfied path, no backoff consumed
        if callAdapter { startAttempt(reason) } else {
            arm(.attempt, after: reason == .wake ? config.wakeAttemptTimeout : config.attemptTimeout) { $0.attemptFailed() }
        }
    }

    private func startAttempt(_ reason: ReconnectReason) {
        guard let s = session, let a = s.adapter else { return }
        s.nextRetryAt = nil
        arm(.attempt, after: reason == .wake ? config.wakeAttemptTimeout : config.attemptTimeout) { $0.attemptFailed() }
        Task { await a.reconnect(reason: reason) }
    }

    private func attemptFailed() {
        guard let s = session, case .reasserting(let r) = phase else { return }
        if let w = s.wakeAt, w.duration(to: clock.now) < config.wakeGrace {
            // Failures in the first 10 s after wake consume no backoff budget (§7.2 wake row).
            startAttempt(r); return
        }
        s.attempt += 1
        let d = s.backoff.next(using: &rng)
        s.nextRetryAt = wallClock().addingTimeInterval(d.seconds)
        publish()
        arm(.retry, after: d) { $0.retryFired() }
    }

    private func retryFired() {
        guard case .reasserting(let r) = phase else { return }
        startAttempt(r == .noNetwork ? .pathChanged : r)
    }

    private func reconnected() {
        guard let s = session, s.startCompleted else { return }
        switch phase {
        case .reasserting, .awaitingAuth(beforeConnected: false): break
        default: return
        }
        cancel(.attempt); cancel(.retry); cancel(.reassertBudget); cancel(.authDeadline)
        broker.live = nil
        s.attempt = 0; s.nextRetryAt = nil; s.backoff.reset(); s.reassertRemaining = nil; s.reassertArmedAt = nil; s.wakeAt = nil
        host.setReasserting(false)
        phase = .connected
        armWatchdog()
    }

    private func pauseReassertBudget() {
        guard let s = session, let rem = s.reassertRemaining, let at = s.reassertArmedAt else { return }
        cancel(.reassertBudget)
        let used = at.duration(to: clock.now)
        s.reassertRemaining = max(.zero, rem - used)
        s.reassertArmedAt = nil
    }

    private func resumeReassertBudget() {
        guard let s = session, let rem = s.reassertRemaining, !s.killSwitch else { return }
        s.reassertArmedAt = clock.now
        arm(.reassertBudget, after: rem) { $0.reassertBudgetExhausted() }
    }

    private func reassertBudgetExhausted() {
        guard let s = session, !s.killSwitch else { return }
        switch phase { case .reasserting: break; default: return }
        afterConnectedFatal(mapTimeout(.of(.peerUnreachable)))
    }

    // MARK: - timers

    private func arm(_ kind: TimerKind, after d: Duration, _ body: @escaping @Sendable (isolated TunnelController) -> Void) {
        timers[kind]?.task.cancel()
        timerToken &+= 1
        let token = timerToken
        let clock = clock
        let task = Task { [weak self] in
            do { try await clock.sleep(for: d) } catch { return }
            await self?.fire(kind, token, body)
        }
        timers[kind] = (token, task)
    }

    private func fire(_ kind: TimerKind, _ token: UInt64, _ body: @Sendable (isolated TunnelController) -> Void) {
        guard timers[kind]?.token == token else { return }      // stale deadline: changes nothing
        timers[kind] = nil
        body(self)
    }

    private func cancel(_ kind: TimerKind) { timers[kind]?.task.cancel(); timers[kind] = nil }
    private func cancelSessionTimers() { for k in timers.keys where k != .pathDebounce { cancel(k) } }
    private func cancelAllTimers() { for k in timers.keys { cancel(k) } }

    private func connectDeadlineFired() {
        guard let s = session, !s.startCompleted, phase.isBeforeConnectedRunning,
              phase != .awaitingAuth(beforeConnected: true) else { return }
        beforeConnectedFailure(mapTimeout(.of(.connectTimeout)))
    }

    /// The prompt deadline. In the pending start (draft 9): the §7.2 failure rows with `.authTimedOut` (a hold under
    /// `includeAllNetworks`, a failed start otherwise). After Connected: unchanged (T10 across sleep).
    private func authDeadlineFired() {
        if phase == .awaitingAuth(beforeConnected: true) {
            beforeConnectedFailure(.of(.authTimedOut))
            return
        }
        if phase == .sleeping, let s = session, s.sleptInAuth { s.authDeadlinePassedAsleep = true; return }   // T10: handled at wake
        guard phase == .awaitingAuth(beforeConnected: false) else { return }
        broker.live = nil
        afterConnectedFatal(.of(.authTimedOut))
    }

    private func armWatchdog() {
        arm(.watchdog, after: config.watchdogInterval) { $0.watchdogTick() }
    }

    private func watchdogTick() {
        guard phase == .connected, let s = session, let a = s.adapter else { return }
        let ep = epoch
        Task { [weak self] in
            let l = await a.liveness()
            await self?.watchdogResult(l, ep)
        }
    }

    private func watchdogResult(_ l: Liveness, _ ep: UInt64) {
        guard ep == epoch, phase == .connected else { return }
        switch l {
        case .healthy: armWatchdog()
        case .stale: enterReasserting(.deadPeer, callAdapter: true)
        case .dead: handleFatal(.of(.engineDied))
        }
    }

    // MARK: - path

    private func stopPathWatcher() { pathTask?.cancel(); pathTask = nil; lastPath = nil }

    private func startPathWatcher() {
        guard pathTask == nil, let src = pathSource else { return }
        let stream = src.paths()
        pathTask = Task { [weak self] in
            for await p in stream { await self?.pathUpdate(p) }
        }
    }

    private func pathUpdate(_ p: PathSnapshot) {
        pendingPath = p
        arm(.pathDebounce, after: config.pathDebounce) { $0.pathSettled() }
    }

    private func pathSettled() {
        guard let p = pendingPath else { return }
        pendingPath = nil
        let prev = lastPath
        lastPath = p
        guard let prev, prev != p else { return }
        switch phase {
        case .starting, .connecting, .establishing, .held:
            // Residual 2: push-on-arrival semantics (8d7d7f5): act when arriving at a network, never while there is none.
            if Self.isArrival(from: prev, to: p) { retryPendingStartOnArrival() }
        case .connected:
            if p.status != .satisfied { enterReasserting(.noNetwork, callAdapter: false) }
            else { enterReasserting(.pathChanged, callAdapter: true) }
        case .reasserting(let r):
            if p.status == .satisfied { cancel(.retry); startAttempt(.pathChanged) }
            else if r != .noNetwork { cancel(.attempt); cancel(.retry); phase = .reasserting(.noNetwork) }
        default:
            break
        }
    }

    /// Review R12: "en0:wifi" → "en0"; a type-label change of the same interface is not an arrival.
    private static func interfaceNames(_ p: PathSnapshot) -> Set<String> {
        Set(p.interfaces.map { String($0.split(separator: ":", maxSplits: 1).first ?? "") })
    }

    /// Arriving at a network: some physical interface is there now and the set differs from the previous path's. Status
    /// flips alone are not arrivals (our own kill-switch start turns the path `unsatisfied` with en0 still listed).
    static func isArrival(from prev: PathSnapshot, to p: PathSnapshot) -> Bool {
        !p.interfaces.isEmpty && interfaceNames(p) != interfaceNames(prev)
    }

    /// Residual 2: a start pending before Connected with no usable interface waits out its 45/50 s connect deadline (a
    /// WireGuard socket opened with no interface goes nowhere) or sits in a hold until the backoff. Arriving at a
    /// network retries the whole start sequence at once, under the same rules as `pushEndpoints` (a retryable hold,
    /// or a WireGuard attempt in flight; never a prompt, never an attempt carrying a one-shot answer, OpenVPN only
    /// from the hold) and bounded per session. The endpoint IPs are the ones the start would use (cache, options, the
    /// app's pushes): the extension resolves nothing under `includeAllNetworks`; the app pushes fresh ones itself.
    private func retryPendingStartOnArrival() {
        guard let s = session, s.isWaitingBeforeConnected, broker.live == nil else { return }
        let inHold: Bool
        switch phase {
        case .held(.blockedAfterFailure(let code)):
            // `.dnsResolutionFailed` waits for the user: the same map can't resolve (review L4).
            guard code != .dnsResolutionFailed, PushEndpointsRequest.recoverableCodes.contains(code) else { return }
            inHold = true
        case .connecting where s.config?.kind == .wireGuard, .establishing where s.config?.kind == .wireGuard:
            guard !s.answerAttempt else { return }
            inHold = false
        default: return
        }
        guard s.arrivalRetries < config.maxArrivalRetriesPerSession else {
            engineLog.notice("pending start: arrival retry limit (\(self.config.maxArrivalRetriesPerSession)) spent")
            return
        }
        s.arrivalRetries += 1
        engineLog.notice("pending start: arrived at a network; retrying now")
        if inHold {
            cancel(.heldRetry)
            heldRetryFired()
        } else {
            s.startTask?.cancel()
            teardownAdapter()
            cancel(.connect)
            phase = .starting
            let ep = epoch
            s.startTask = Task { await self.runStarting(ep) }
        }
    }

    // MARK: - sleep / wake

    public func sleep() async {
        guard let s = session, s.startCompleted, let a = s.adapter else { return }
        switch phase {
        case .connected, .reasserting, .awaitingAuth(beforeConnected: false): break
        default: return
        }
        host.setReasserting(true)                // first (Apple's order, forum 95988)
        cancel(.watchdog); cancel(.attempt); cancel(.retry)
        pauseReassertBudget()
        s.sleptInAuth = phase == .awaitingAuth(beforeConnected: false)    // T10: the prompt and its deadline survive sleep
        s.authDeadlinePassedAsleep = false
        phase = .sleeping
        await capped(config.sleepCap) { await a.sleep() }
    }

    public func wake() async {
        guard phase == .sleeping, let s = session, let a = s.adapter else { return }
        s.wakeAt = clock.now
        if s.sleptInAuth {
            // T10: back to the prompt (the reassert budget stays paused while it shows); a deadline that passed asleep
            // ends it now.
            s.sleptInAuth = false
            Task { await a.wake() }
            if s.authDeadlinePassedAsleep || broker.live == nil {
                s.authDeadlinePassedAsleep = false
                phase = .awaitingAuth(beforeConnected: false)
                authDeadlineFired()
            } else {
                phase = .awaitingAuth(beforeConnected: false)
            }
            return
        }
        if s.reassertRemaining != nil { resumeReassertBudget() }
        enterReasserting(.wake, callAdapter: false)
        Task { await a.wake() }
    }

    // MARK: - stopTunnel

    /// Idempotent. Order (§7.2): cancel the start task; complete the start (`.startCancelled`, or the held error `e`
    /// when the stop ends a before-Connected hold, §5.5); tear down; return (the caller then calls NE's completion).
    public func stop(reason: StopReason) async {
        if let s = session {
            if s.startGate != nil {
                s.startTask?.cancel()
                resolveLivePrompt()
                completeStart(.failure(s.heldError ?? .of(.startCancelled)))
            }
            phase = .stopping
            cancelAllTimers()
            teardownAdapter()
            let reasonText = reason == .userInitiated ? "user" : reason == .sleep ? "sleep" : "\(reason)"
            endSession(reason: reasonText)
        }
        stopPathWatcher()
        let pending = Array(teardowns.values)
        teardowns = [:]
        for t in pending { await t.value }
    }

    // MARK: - teardown helpers

    private func completeStart(_ r: Result<Void, LPTunnelError>) {
        guard let s = session, let k = s.startGate else { return }
        s.startGate = nil
        s.answer = nil                            // an unused answer never outlives its start
        cancel(.heldRetry)
        k.resume(returning: r)
    }

    /// Detaches the adapter and stops it in a controller-owned task capped at 5 s (never a child of a cancelled task).
    private func teardownAdapter() {
        guard let s = session else { return }
        epoch &+= 1
        let a = s.adapter
        s.adapter = nil
        s.events?.finish(); s.events = nil
        guard let a else { return }
        let cap = config.stopCap
        let sid = s.sessionID
        teardownSeq &+= 1
        let id = teardownSeq
        let t = Task { [weak self] in
            guard let self else { await a.stop(); return }
            // T4: a final counter sample (≤ 1 s) BEFORE the engine stops, for the session summary. (A best-effort cap,
            // not a start/hold/auth deadline; the 5 s stop cap below runs on the strict clock.)
            if let sid, let st = await withDeadline(.seconds(1), onTimeout: AdapterStats?.none, { await a.statistics() }) {
                await self.noteFinalStats(st, sid)
            }
            await self.capped(cap) { await a.stop() }
            await self.teardownFinished(id)
        }
        teardowns[id] = t
    }

    private func teardownFinished(_ id: UInt64) { teardowns[id] = nil }

    /// A session that ends takes its prompt with it; every app instance is told (no dead prompt left showing).
    private func resolveLivePrompt() {
        guard let l = broker.live else { return }
        broker.live = nil
        sink?.promptResolved(promptID: l.prompt.promptID, profileID: l.prompt.profileID, ownerUID: l.ownerUID)
    }

    /// T4: the teardown's final sample: into the still-running (held) session, or into its already-written summary.
    private func noteFinalStats(_ st: AdapterStats, _ sid: UUID) {
        if let s = session, s.sessionID == sid { s.stats = st; return }
        guard let i = persisted.sessions.lastIndex(where: { $0.summary.id == sid }) else { return }
        persisted.sessions[i].summary.rxBytes = max(persisted.sessions[i].summary.rxBytes, st.rxBytes)
        persisted.sessions[i].summary.txBytes = max(persisted.sessions[i].summary.txBytes, st.txBytes)
        save()
    }

    private func endSession(reason: String) {
        guard let s = session else { return }
        cancelAllTimers()
        s.answer = nil
        resolveLivePrompt()
        if let id = s.sessionID, let key = s.key, let at = s.connectedAt {
            let summary = SessionSummary(id: id, profileID: key.profileID, start: at, end: wallClock(),
                                         rxBytes: s.stats.rxBytes, txBytes: s.stats.txBytes, endReason: reason)
            persisted.sessions.append(.init(ownerUID: key.ownerUID, summary: summary))
            if persisted.sessions.count > 100 { persisted.sessions.removeFirst(persisted.sessions.count - 100) }
            save()
        }
        session = nil
        phase = .idle
        pump?.endSession(); pump = nil              // T16: every end path; the next session gets a fresh pump
    }

    /// Runs non-cancellable work with a cap (gate + timer, never a TaskGroup race, ref/swift-concurrency §6.2).
    private nonisolated func capped(_ d: Duration, _ op: @escaping @Sendable () async -> Void) async {
        let gate = CapGate()
        let clock = clock
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            gate.set(k)
            Task { await op(); gate.resume() }
            Task { try? await clock.sleep(for: d); gate.resume() }
        }
    }

    // MARK: - latches and persisted state

    private func armLatch(_ key: ProfileKey, _ code: LPErrorCode, _ kind: StartLatch.Kind) {
        let rev = session?.config?.revision ?? 0
        if kind == .hard {
            persisted.latches[key] = .init(latch: StartLatch(code: code, kind: .hard, notBefore: nil, revision: rev), interval: nil)
        } else {
            let prevInterval = persisted.latches[key]?.latch.kind == .backoff ? persisted.latches[key]?.interval : nil
            let i = LatchBackoff.next(after: prevInterval)
            persisted.latches[key] = .init(latch: StartLatch(code: code, kind: .backoff, notBefore: wallClock().addingTimeInterval(i), revision: rev),
                                           interval: i)
        }
        save()
    }

    private func clearLatch(_ key: ProfileKey) {
        if persisted.latches.removeValue(forKey: key) != nil { save() }
    }

    private func recordLastError(_ e: LPTunnelError, _ key: ProfileKey?) {
        guard let key else { return }
        persisted.lastErrors[key] = .init(error: e.asLPError, at: wallClock())
        save()
    }

    private func sessionEnded(_ e: LPTunnelError) {
        guard let cfg = session?.config else { return }
        sink?.sessionEnded(profileID: cfg.profileID, error: e.asLPError, ownerUID: cfg.ownerUID)
    }

    private func save() { stateStore.save(persisted) }

    private func publish() {
        sink?.snapshotChanged(sessionSnapshot(), ownerUID: session?.config?.ownerUID)
    }

    // MARK: - queries (XPC-facing; every one is scoped to the caller's (uid, profile))

    /// The running session as its owner sees it (events go only to the owner's connections).
    private func sessionSnapshot() -> TunnelSnapshot {
        var snap = TunnelSnapshot(profileID: session?.config?.profileID, phase: phase.tunnelPhase, epoch: epoch)
        if let s = session {
            snap.attempt = s.attempt
            snap.nextRetryAt = s.nextRetryAt
            snap.endpoint = s.stats.endpoint
            snap.localAddresses = s.stats.localAddresses
            snap.cipher = s.stats.cipher
        }
        if case .held(let r) = phase { snap.holdReason = r }
        if let s = session, !s.startCompleted, let r = s.heldReason {
            snap.holdReason = r                      // also while a held start retries (status `.connecting`)
            snap.holdBeforeConnected = true          // draft 9 withhold (S2 E14)
        }
        if let key = session?.key { addPersisted(&snap, key) }
        return snap
    }

    private func addPersisted(_ snap: inout TunnelSnapshot, _ key: ProfileKey) {
        snap.startLatch = persisted.latches[key]?.latch
        if let le = persisted.lastErrors[key] { snap.lastError = le.error; snap.lastErrorAt = le.at }
    }

    /// `tunnelSnapshot` (M2): the full snapshot only when (ownerUID, profileID) IS the running session. Any other
    /// profile gets its own latch/lastError and `.idle`, never the running session's phase detail, endpoint,
    /// addresses, cipher, retry state or epoch (NEW-7: epoch 0, the adapter generation is the running session's).
    public func snapshot(profileID: UUID, ownerUID: uid_t) -> TunnelSnapshot {
        let key = ProfileKey(ownerUID: ownerUID, profileID: profileID)
        if let s = session, s.key == key { return sessionSnapshot() }
        var snap = TunnelSnapshot(profileID: profileID, phase: .idle, epoch: 0)
        addPersisted(&snap, key)
        return snap
    }

    /// Tests: the running session's snapshot as its owner sees it.
    func snapshot() -> TunnelSnapshot { sessionSnapshot() }

    public var currentPhase: Phase { phase }
    /// Tests: whether the path watcher runs (it ends with every session end, including before a cancel).
    var isWatchingPath: Bool { pathTask != nil }
    /// Tests: the last debounced path and whether one is still pending.
    var pathState: (settled: PathSnapshot?, pending: Bool) { (lastPath, pendingPath != nil) }
    public var persistedState: PersistedTunnelState { persisted }

    public func statistics() async -> AdapterStats {
        guard let a = session?.adapter else { return session?.stats ?? AdapterStats() }
        let ep = epoch
        let st = await a.statistics()
        if ep == epoch { session?.stats = st }
        return st
    }

    /// §7.7 statistics for the app (cached 250 ms; zeros when (ownerUID, profileID) is not the running session).
    public func statisticsReport(profileID: UUID, ownerUID: uid_t) async -> TunnelStatistics {
        let now = wallClock()
        let key = ProfileKey(ownerUID: ownerUID, profileID: profileID)
        let zero = TunnelStatistics(profileID: profileID, sessionID: nil, sessionStart: nil, rxBytes: 0, txBytes: 0,
                                    lastHandshakeAt: nil, sampledAt: now)
        guard let s = session, s.key == key else { return zero }
        if let at = statsSampledAt, now.timeIntervalSince(at) < 0.25 {
            // cached
        } else {
            statsSampledAt = now
            _ = await statistics()
        }
        guard let s2 = session, s2 === s else { return zero }
        return TunnelStatistics(profileID: profileID, sessionID: s.sessionID, sessionStart: s.connectedAt, rxBytes: s.stats.rxBytes,
                                txBytes: s.stats.txBytes, lastHandshakeAt: s.stats.lastHandshake, sampledAt: now)
    }

    /// `ownerUID`'s session ring entries, after `after` (exclusive), oldest first.
    public func sessionSummaries(ownerUID: uid_t, after: UUID?) -> [SessionSummary] {
        var list = persisted.sessions.filter { $0.ownerUID == ownerUID }.map(\.summary)
        if let after, let i = list.firstIndex(where: { $0.id == after }) { list = Array(list[(i + 1)...]) }
        return Array(list.prefix(SessionSummariesReply.maxEntries))
    }

    // MARK: - auth API (§5.2)

    public func pendingAuthPrompt(profileID: UUID, ownerUID: uid_t) -> AuthPrompt? {
        broker.expire(now: wallClock())
        return broker.pendingPrompt(ProfileKey(ownerUID: ownerUID, profileID: profileID), now: wallClock())
    }

    /// Known-interactive profiles prompt before the first start (a UX optimisation: the user types while the Mac is
    /// still online). The answer waits here until this owner's next manual start of the profile takes it (once).
    public func prepareStartAuth(profileID: UUID, ownerUID: uid_t, kind: AuthKind, savedUsername: String? = nil) -> AuthPrompt {
        broker.expire(now: wallClock())
        return broker.prepare(profileID: profileID, ownerUID: ownerUID, kind: kind, savedUsername: savedUsername, now: wallClock())
    }

    /// `answerAuth`: answers the live prompt (into the pending start or the reasserting session), or attaches the
    /// answer to a `prepareStartAuth` prompt (it starts nothing). Unknown/expired → `.staleAnswer`.
    public func answerAuth(promptID: UUID, answer: AuthAnswerSecrets, callerUID: uid_t) async throws(LPError) {
        let now = wallClock()
        broker.expire(now: now)
        if let e = broker.prepared(promptID: promptID), e.ownerUID != callerUID { throw LPError(.notOwner) }
        if let l = broker.live, l.prompt.promptID == promptID, l.ownerUID != callerUID { throw LPError(.notOwner) }
        let preparedKey = broker.prepared(promptID: promptID)?.key
        switch broker.attach(promptID: promptID, answer: answer, now: now) {
        case .stale:
            throw LPError(.staleAnswer)
        case .prepared:
            if let preparedKey { sink?.promptResolved(promptID: promptID, profileID: preparedKey.profileID, ownerUID: preparedKey.ownerUID) }
            if answer.save, let preparedKey { await saveAnswer(answer, preparedKey) }
        case .live:
            guard let l = broker.live, let s = session else { throw LPError(.staleAnswer) }
            if l.beforeConnected && l.restartsEngine {
                // Draft 9: the answer goes into the SAME pending start, as a new engine attempt (a new openvpn3
                // client) with the challenge's CRV1 cookie and the carried base credentials (§8.4).
                broker.live = nil
                cancel(.authDeadline)
                sink?.promptResolved(promptID: promptID, profileID: l.prompt.profileID, ownerUID: l.ownerUID)
                if answer.save, let key = s.key { await saveAnswer(answer, key) }
                guard session === s, phase == .awaitingAuth(beforeConnected: true), s.isWaitingBeforeConnected else {
                    throw LPError(.staleAnswer)
                }
                s.answer = StashBinding(promptID: promptID, answer: answer, carriedUsername: l.challenge.carriedUsername,
                                        carriedPassword: l.challenge.carriedPassword, cookie: l.challenge.cookie)
                phase = .starting
                let ep = epoch
                s.startTask = Task { await self.runStarting(ep) }
                return
            }
            guard let a = s.adapter else { throw LPError(.staleAnswer) }
            broker.live = nil
            sink?.promptResolved(promptID: promptID, profileID: l.prompt.profileID, ownerUID: l.ownerUID)
            if answer.save, let key = s.key { await saveAnswer(answer, key) }
            guard session === s, let a2 = s.adapter, a2 === a else { throw LPError(.staleAnswer) }
            cancel(.authDeadline)
            if l.beforeConnected {
                phase = .connecting
                if let cfg = s.config { armConnectDeadline(cfg) }
            } else {
                phase = .reasserting(.auth)
                resumeReassertBudget()
                arm(.attempt, after: config.attemptTimeout) { $0.attemptFailed() }
            }
            let ep = epoch
            Task { [weak self] in
                do throws(LPTunnelError) { try await a.provideAuth(answer) } catch { await self?.provideAuthFailed(error, ep) }
            }
        }
    }

    private func provideAuthFailed(_ e: LPTunnelError, _ ep: UInt64) {
        guard ep == epoch else { return }
        handleFatal(e)
    }

    /// "Save" persists the username and BASE password only (never a response/OTP).
    /// L2: written only into a namespace that holds this profile's payload, under that entry's owner and revision.
    private func saveAnswer(_ a: AuthAnswerSecrets, _ key: ProfileKey) async {
        guard let p = try? await secrets.entry(.payload, key.profileID, ownerUID: key.ownerUID), p.ownerUID == key.ownerUID else { return }
        var c = (try? await secrets.get(.credential, p.id, ownerUID: p.ownerUID)).flatMap { $0.flatMap(CredentialCodec.decode) }
            ?? CredentialSecrets()
        if let u = a.username { c.username = u }
        if let pw = a.password { c.password = pw }
        try? await secrets.put(.credential, p.id, ownerUID: p.ownerUID, revision: p.revision, CredentialCodec.encode(c))
    }

    public func cancelAuth(promptID: UUID, callerUID: uid_t) throws(LPError) {
        if let l = broker.live, l.prompt.promptID == promptID {
            guard l.ownerUID == callerUID else { throw LPError(.notOwner) }
            broker.live = nil
            sink?.promptResolved(promptID: promptID, profileID: l.prompt.profileID, ownerUID: l.ownerUID)
            if l.beforeConnected { beforeConnectedFailure(.of(.authRequired)) } else { afterConnectedFatal(.of(.authRequired)) }
            return
        }
        if let e = broker.prepared(promptID: promptID) {
            guard e.ownerUID == callerUID else { throw LPError(.notOwner) }
            broker.cancel(promptID: promptID)
            sink?.promptResolved(promptID: promptID, profileID: e.profileID, ownerUID: e.ownerUID)
        }
    }

    // MARK: - pushEndpoints (PENDING-FOLD 50, §20 risk 25)

    /// `pushEndpoints`: the owner's app resolved the profile's endpoints (on a network change or wake) while this start
    /// is held before Connected. Under `includeAllNetworks` nothing inside the hold can find new IPs (no provider DNS,
    /// S2 E10), so without this an on-demand start against a stale cache waits for the user (D9-20), or retries the
    /// same dead IPs forever.
    /// Accepted only for (ownerUID, profileID) == the running session whose start is pending in a before-Connected
    /// hold with a pushable reason, `.blockedAfterFailure` of one of `PushEndpointsRequest.recoverableCodes`: while it
    /// waits (`held`) or while one of its retries is starting or connecting (that attempt uses the old IPs; it is
    /// replaced). Never for a `.nonRetryable` (C16) hold, an after-Connected hold (`holdBlocked` waits for the user by
    /// design), a prompt (live, or answered: an attempt carrying a one-shot answer is never replaced, review PF-R2), or
    /// an OpenVPN attempt that is already applying settings (the server answered; a WireGuard retry applies them before
    /// any handshake and IS replaced, E2E-2). IPs equal to the ones the start would use now (cache ∪ options ∪
    /// earlier pushes, per host, as sets) change nothing, so a repeated push can't loop the start and a `.backoff`
    /// latch's `notBefore` holds unless the IPs really changed (review PF-R3). At most `ControllerConfig.maxPushesPerSession`
    /// pushes per session are accepted (then `.unchanged`). Otherwise the IPs win over the options and the cache for
    /// this start, are cached on success (hostnames the profile references only), and the start sequence runs again now.
    public func pushEndpoints(profileID: UUID, ownerUID: uid_t, endpoints: [String: [String]]) -> PushEndpointsReply.Outcome {
        let key = ProfileKey(ownerUID: ownerUID, profileID: profileID)
        guard let s = session, s.key == key, s.isWaitingBeforeConnected, broker.live == nil,
              case .blockedAfterFailure(let code)? = s.heldReason, PushEndpointsRequest.recoverableCodes.contains(code) else { return .notHeld }
        let inHold: Bool
        switch phase {
        case .held: inHold = true
        case .starting, .connecting: inHold = false            // a retry inside the hold, still on the old IPs
        // E2E-2: WireGuard applies the settings BEFORE its first handshake, so its retry on dead IPs waits out the
        // connect deadline in .establishing; OpenVPN's .establishing means the server answered (never replaced).
        case .establishing where s.config?.kind == .wireGuard: inHold = false
        default: return .notHeld
        }
        guard inHold || (!s.answerAttempt && s.answer == nil) else { return .notHeld }
        let pushed = EndpointMapRules.sanitized(endpoints)       // the app's filter too (defence in depth)
        guard !pushed.isEmpty else { return .notHeld }
        let effective = effectiveEndpoints(s, key)
        guard pushed.contains(where: { h, ips in Set(ips) != Set(effective[h] ?? []) }) else { return .unchanged }
        guard s.pushesAccepted < config.maxPushesPerSession else {
            engineLog.notice("held start: push limit (\(self.config.maxPushesPerSession)) spent; ignored")
            return .unchanged
        }
        s.pushesAccepted += 1
        engineLog.notice("held start: \(pushed.count) endpoint host(s) pushed by the app; retrying now")
        s.pushedEndpoints.merge(pushed) { $1 }
        if s.pushedEndpoints.count > EndpointMapRules.maxHosts {           // bounded per session, newest kept
            s.pushedEndpoints = s.pushedEndpoints.filter { pushed[$0.key] != nil }
        }
        if inHold {
            cancel(.heldRetry)
            heldRetryFired()
        } else {
            // Replace the attempt in flight: its adapter goes (epoch bump: its late events and failures are dropped,
            // T6), and the whole start sequence runs again with the pushed IPs.
            s.startTask?.cancel()
            teardownAdapter()
            cancel(.connect)
            phase = .starting
            let ep = epoch
            s.startTask = Task { await self.runStarting(ep) }
        }
        return .retrying
    }

    // MARK: - provisioning hooks (§7.2 latch/prompt clearing rules)

    /// Draft 9: a pending start (in ANY before-Connected phase: held, a retry attempt in flight, a prompt, AUTH_PENDING)
    /// ends when its profile changes or goes away: it would otherwise run or retry the new payload under the old
    /// configuration (review L2/L6). The start completes with the held error (`.startCancelled` otherwise), so NE ends
    /// the session and the app can start the changed profile.
    private func endWaitingStart(_ key: ProfileKey, reason: String) {
        guard let s = session, s.key == key, s.isWaitingBeforeConnected else { return }
        s.startTask?.cancel()
        if let l = broker.live, l.beforeConnected {
            broker.live = nil
            sink?.promptResolved(promptID: l.prompt.promptID, profileID: l.prompt.profileID, ownerUID: l.ownerUID)
        }
        completeStart(.failure(s.heldError ?? .of(.startCancelled, reason)))
        teardownAdapter()
        endSession(reason: reason)
    }

    /// A provision with a higher revision clears the latch, drops the prepared answer and ends a waiting start (of that
    /// owner's profile only).
    public func profileProvisioned(_ pid: UUID, ownerUID: uid_t, revision: UInt64) {
        let key = ProfileKey(ownerUID: ownerUID, profileID: pid)
        if let l = persisted.latches[key]?.latch, revision > l.revision { clearLatch(key) }
        broker.dropPrepared(key)
        if let cfg = session?.config, ProfileKey(cfg) == key, revision > cfg.revision { endWaitingStart(key, reason: "profile changed") }
    }
    /// New credentials: the latch and the resend guard go; a before-Connected hold retries now (they may fix it).
    public func credentialsUpdated(_ pid: UUID, ownerUID: uid_t) {
        let key = ProfileKey(ownerUID: ownerUID, profileID: pid)
        clearLatch(key); persisted.authFailedAt[key] = nil; save()
        if let s = session, s.key == key, s.isWaitingBeforeConnected, case .held = phase {
            cancel(.heldRetry)
            heldRetryFired()
        }
    }
    public func profileRemoved(_ pid: UUID, ownerUID: uid_t) {
        let key = ProfileKey(ownerUID: ownerUID, profileID: pid)
        endWaitingStart(key, reason: "profile removed")
        clearLatch(key); broker.dropPrepared(key)
        persisted.lastErrors[key] = nil; persisted.endpointHosts[key] = nil; persisted.authFailedAt[key] = nil; save()
    }
    /// `wipeAllSecrets` (L1): the caller's latches, resend guards, last errors, cached endpoints, session-ring
    /// entries (NEW-6) and prompts only; other uids keep theirs.
    public func secretsWiped(ownerUID: uid_t) {
        if let key = session?.key, key.ownerUID == ownerUID { endWaitingStart(key, reason: "secrets wiped") }
        persisted.latches = persisted.latches.filter { $0.key.ownerUID != ownerUID }
        persisted.authFailedAt = persisted.authFailedAt.filter { $0.key.ownerUID != ownerUID }
        persisted.lastErrors = persisted.lastErrors.filter { $0.key.ownerUID != ownerUID }
        persisted.endpointHosts = persisted.endpointHosts.filter { $0.key.ownerUID != ownerUID }
        persisted.sessions.removeAll { $0.ownerUID == ownerUID }
        save()
        broker.dropPrepared(ownerUID: ownerUID)
    }
}

// SAFETY: guarded by its Mutex; the continuation is resumed at most once.
private final class CapGate: Sendable {
    private let k = Mutex<CheckedContinuation<Void, Never>?>(nil)
    func set(_ c: CheckedContinuation<Void, Never>) { k.withLock { $0 = c } }
    func resume() { k.withLock { c in c?.resume(); c = nil } }
}

extension Duration {
    var seconds: TimeInterval { let c = components; return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18 }
}
