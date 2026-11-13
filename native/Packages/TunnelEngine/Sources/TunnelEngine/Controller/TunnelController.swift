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

/// Extension-side re-validation of a payload (§8.1, §9.1). 2.0.2 (PLAN §1): the extension, which runs as root, no longer
/// evaluates profiles; the memory-unsafe checks ([6] on the payload, [7] `eval_config`) belong to the app's validator
/// service (`LPEngineCheck`). The Tunnel target binds LPParsing.
public protocol PayloadValidator: Sendable {
    /// §6.4 step 2: memory-safe checks only. Swift [1]–[5] and the canonical fixed point; no openvpn3, no OpenSSL.
    func validateForProvision(kind: VPNProtocolKind, payload: SecretBytes) throws(LPTunnelError)
    /// §8.1: [1]–[5] + [6] on the session's own payload, right before the session's engine parses it.
    func validateForStart(kind: VPNProtocolKind, payload: SecretBytes) throws(LPTunnelError)
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
    /// 2.0.2 (PLAN §3): the owner-authorisation table. `package`: only this package's tests can switch it off (the
    /// 2.0.1 start-guard suites predate it); the Tunnel target cannot even name it.
    package var enforceStartAuthorisation = true
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
        /// The provider instance whose `startTunnel` began this session (nil: a caller that names none, the tests).
        let owner: ProviderLease?
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
        /// Round 6 (Codex r6 #1): the payload revision of the prompt `answer` answers (nil: a prepared answer, any). An
        /// attempt that loads another revision drops the answer (its cookie and carried credentials are that server's).
        var answerRevision: UInt64?
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
        /// Round 5 (Fable r5 N2, Codex r5 #6): the payload revision the current attempt loaded (the configuration's until
        /// the first load). A commit is new to this attempt only above it, and a prompt and its answer belong to it.
        var loadedRevision: UInt64
        /// Round 5 (Codex r5 #6): the prompt whose before-Connected answer is being applied (across the save's await);
        /// a commit meanwhile clears it and starts a fresh attempt, and the answer is then stale.
        var answerInFlight: UUID?
        init(config: ProviderConfiguration?, options: StartOptions, owner: ProviderLease?, dataPlane: DataPlane, backoff: Backoff) {
            self.config = config; self.options = options; self.owner = owner; self.dataPlane = dataPlane; self.backoff = backoff
            self.loadedRevision = config?.revision ?? 0
        }
        var key: ProfileKey? { config.map(ProfileKey.init) }
        var c16: Bool { !options.isManual || (config?.hasOnDemandRules ?? false) }
        /// The NE protocol's flags, for a start whose `providerConfiguration` didn't parse (re-check N3).
        var protocolIncludeAllNetworks = false
        var protocolEnforceRoutes = false
        /// `includeAllNetworks` or route protection (after-Connected hold, never cancel).
        var killSwitch: Bool { config?.policy.killSwitch ?? (protocolIncludeAllNetworks || protocolEnforceRoutes) }
        /// `includeAllNetworks` (draft 9: withhold before Connected, no provider DNS).
        var includeAllNetworks: Bool { config?.includeAllNetworks ?? protocolIncludeAllNetworks }
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
    /// The live provider instances of this process (the 2.0.1 start guard, `start(_:owner:bind:)`).
    public nonisolated let providers: ProviderInstances

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
    /// Review L3: when a refusal's `lastError` was last written to disk, per profile (repeated refusals coalesce).
    private var refusalSavedAt: [ProfileKey: Date] = [:]
    /// Codex final 3: the accepted kill-switch start that preempted a session holds the slot across its teardown.
    private var reservation: (lease: ProviderLease, key: ProfileKey?)?
    /// Final review M1: starts waiting beside a running session of the same kill-switch profile.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Round 5 (Codex 2): every start inside the guard (waiting beside a session, holding a reservation across a
    /// preemption's teardown, or tearing a stale session down), by start: its lease, its key and its configuration's
    /// revision. `profileRemoved`, `secretsWiped` and a higher revision's provision invalidate it (the error it ends
    /// with), and it is checked after every suspension, before admission: it never begins on a removed or changed profile.
    /// Round 4 (Fable L1 = Codex r4 #1): `killSwitch` (`includeAllNetworks` or the profile's kill switch): such a start is
    /// NEVER invalidated by a commit, in any guard wait (a duplicate, a `.stopping` incumbent, a stale session's teardown).
    /// A failed protected start is open (E14c), and it may be NE's authorised replay that nothing starts again; it goes on
    /// and loads the committed payload (`runStarting` accepts a configuration older than the payload).
    private struct GuardedStart {
        let lease: ProviderLease?; let key: ProfileKey?; let revision: UInt64; let killSwitch: Bool
        var invalidated: LPTunnelError?
    }
    /// Round 3 (Fable N1): a counter bumped whenever a user's act ends a profile's record (the user's stop of the live
    /// session, a removed configuration, `profileRemoved`, `secretsWiped`), and when each key and owner last had one. A
    /// replay decided before such an end is refused (and its record never put back) once the end is seen.
    private var userClearSeq: UInt64 = 0
    private var userClearedAt: [ProfileKey: UInt64] = [:]
    private var ownerClearedAt: [uid_t: UInt64] = [:]
    /// Tests (round 4, Fable N3): how many user-clear marks are held (none while no start is in the guard).
    var userClearMarkCount: Int { userClearedAt.count + ownerClearedAt.count }
    /// Round 3 (Codex r3 #8): the pages of a paginated keep set received so far, per owner (one batch at a time).
    private var revokePages: [uid_t: (batch: UUID, count: Int, pages: [Int: Set<UUID>])] = [:]
    private var guardedStarts: [UInt64: GuardedStart] = [:]
    private var guardedSeq: UInt64 = 0
    /// 2.0.2 (PLAN §3): pending arms (memory only); the persisted authorisations live in `persisted.authorisedStarts`.
    private var arms = StartArms()
    /// Round 2 (Fable L2): this boot session; every record carries it, and one of another boot is dropped at load.
    private let bootSession: String?

    public init(host: any ProviderHost, secrets: any ExtensionSecretStore, stateStore: any TunnelStateStore,
                adapters: any TunnelAdapterFactory, validator: (any PayloadValidator)?, clock: C,
                wallClock: @escaping @Sendable () -> Date = { Date() },
                rng: any RandomNumberGenerator = SystemRandomNumberGenerator(),
                pathSource: (any PathSource)? = nil, endpointCheck: (any EndpointInterfaceCheck)? = nil,
                sink: (any TunnelEventSink)? = nil, config: ControllerConfig = ControllerConfig(),
                providers: ProviderInstances = ProviderInstances(), bootSession: String? = BootSession.current()) {
        self.host = host; self.secrets = secrets; self.stateStore = stateStore; self.adapters = adapters
        self.validator = validator; self.clock = clock; self.wallClock = wallClock
        self.rng = rng; self.pathSource = pathSource; self.endpointCheck = endpointCheck; self.sink = sink
        self.config = config; self.providers = providers
        self.bootSession = bootSession
        var loaded = stateStore.load()
        // Round 2 (Fable L2): NE never restarts a session of an earlier boot; such a record would only be a standing
        // authorisation for an outside start. Round 3 (Fable N2): only when this boot's value could be read; with none,
        // nothing is dropped (dropping every record would refuse NE's restart of the running session).
        let stale = bootSession.map { boot in loaded.authorisedStarts.filter { $0.value.boot != boot } } ?? [:]
        if !stale.isEmpty {
            for k in stale.keys { loaded.authorisedStarts[k] = nil }
            stateStore.save(loaded)
        }
        persisted = loaded
    }

    // MARK: - startTunnel

    /// Completes (returns or throws) exactly once per call. Draft 9: with `includeAllNetworks` it returns only on
    /// Connected or throws only when the user stops (or the profile changes): failures before Connected are held.
    ///
    /// The 2.0.1 start guard (DESIGN §7.2): `owner` is the calling provider instance's `startTunnel` (its lease). A
    /// session that another instance's CURRENT lease began (or an accepted kill-switch start's reservation, Codex final 3)
    /// is not displaced (the same profile included: Codex review 3); a duplicate kill-switch configuration of the running
    /// kill-switch profile waits, pending (final review M1); and one exception:
    /// - review H1, kill-switch priority: this start has `includeAllNetworks` and that session's effective protection
    ///   (its provider's live flag, Codex final 1) hasn't. That session is
    ///   ended visibly (`.supersededByKillSwitch`: its pending start fails, or its own provider is cancelled after the
    ///   teardown) and this start goes on. A failed `includeAllNetworks` start is open (E14c), so a split session that
    ///   got in first must never keep a kill-switch profile down.
    /// Otherwise this start fails with `.anotherTunnelActive` and that session, its host binding and its packet flow
    /// stay untouched (kill switch against kill switch: first wins; a start without the flag beside a kill-switch
    /// session: refused). A session of the same instance, of a lease that is no longer current (stopped, freed, reused)
    /// or of no named instance is stale and is torn down first, as before. Review M3: a start whose own lease stopped
    /// meanwhile ends with `.startCancelled`. `bind` binds the caller as the process's provider (`ProcessProviderHost`)
    /// and says whether it still exists; it runs only for an accepted start, on the actor, with no suspension between
    /// the last check and the new session.
    public func start(_ req: StartRequest, owner: ProviderLease? = nil, bind: @Sendable () -> Bool = { true }) async throws(LPTunnelError) {
        // 2.0.2 (PLAN §3.1): who may start this profile, decided FIRST: before the latch, the guard loop (a refused start
        // never reaches the kill-switch priority rule), any suspension, and any payload or credential read. The decision
        // and (for an armed start) the consumption of its arm happen here, synchronously on the actor. A start with no
        // parseable configuration has no profile to authorise: it reads nothing and ends in `runStarting` (profileInvalid),
        // and keeps the 2.0.1 behaviour that its protocol flags still count in the guard (re-check N3).
        // Round 1 (Fable H1): what to record once the start is admitted: an armed start's nonce, or an unattended
        // admission. Round 2 (L1): a replay puts back the record it matched if a revoke removed it meanwhile.
        var admission: Admission?
        let decidedAt = userClearSeq
        if config.enforceStartAuthorisation, let cfg = req.configuration {
            let now = wallClock()
            let k = ProfileKey(cfg)
            switch arms.decide(k, options: req.options, hasOnDemandRules: cfg.hasOnDemandRules,
                               authorised: persisted.authorisedStarts, now: now) {
            case .armed(let n): admission = .armed(n)
            case .unattended: admission = .unattended
            case .replay(let rec): admission = .replay(rec)
            case .refused:
                let e = LPTunnelError(.startNotAuthorised, detail: "start not authorised by the profile's owner")
                recordRefusal(e, k, sameProfile: false, unauthorised: true)
                throw e
            }
        }
        // Row idle → starting, FIRST: an on-demand start against a latch does no credential or network I/O. Without
        // the flag it fails at once; with `includeAllNetworks` it is held (a failed start would be open, E14c).
        if let l = activeLatch(req, at: wallClock()) {
            engineLog.info("start latched: \(l.code.rawValue)")
            guard req.includeAllNetworks else { throw LPTunnelError(l.code, detail: "start latched") }
        }
        let key = req.configuration.map(ProfileKey.init)
        let killSwitchStart = req.includeAllNetworks
        var notedWait = false
        guardedSeq &+= 1
        let gid = guardedSeq
        guardedStarts[gid] = GuardedStart(lease: owner, key: key, revision: req.configuration?.revision ?? 0,
                                          killSwitch: req.includeAllNetworks || req.configuration?.policy.killSwitch == true)
        // Round 3 (Fable N1): a replay whose record a user's act ended while it waited is no longer NE's restart of a
        // session the user wants: refused (and its record not put back).
        func replayEndedByUser() -> LPTunnelError? {
            guard case .replay? = admission, let key, userClearedSince(decidedAt, key) else { return nil }
            let e = LPTunnelError(.startNotAuthorised, detail: "the owner stopped the profile while this start waited")
            recordRefusal(e, key, sameProfile: false, unauthorised: true)
            return e
        }
        // Codex final 3: a reservation this start took for a preemption ends with the start (accepted or not).
        defer {
            guardedStarts[gid] = nil
            // Round 4 (Fable N3): the user-clear marks matter only to starts in the guard; none left, none kept.
            if guardedStarts.isEmpty { userClearedAt = [:]; ownerClearedAt = [:] }
            if let owner, reservation?.lease == owner { reservation = nil; wakeWaiters() }
        }
        while true {
            // Re-check L3: a start NE already stopped (or whose instance it reused) never preempts or replaces anything.
            if let owner, !providers.isCurrent(owner) { throw abandoned() }
            // Round 5 (Codex 2): its profile was removed, wiped or changed while it waited.
            if let e = guardedStarts[gid]?.invalidated { throw e }
            if let e = replayEndedByUser() { throw e }
            // Phase 0 (2026-11-10, 26.6.2 and 27.2): macOS DOES start a second LockPlus configuration while one runs,
            // in this same process. Displacing the running session black-holed it while NE still reported it Connected.
            // A loop: after each `await` the state is checked again from the top (a session or reservation may be a
            // concurrent start's, and is never overwritten, which would leak its continuation).
            //
            // Codex final 3: an accepted kill-switch replacement reserves the slot across the preempted session's
            // teardown; other starts meet that reservation like a running kill-switch session.
            if let r = reservation, r.lease.token != owner?.token, providers.isCurrent(r.lease) {
                switch verdict(killSwitchStart: killSwitchStart, key: key, incumbentKey: r.key, incumbentIncludeAllNetworks: true) {
                case .wait:
                    await waitForChange(); continue
                case .refuse, .preempt: throw refuse(key, sameProfile: key != nil && r.key == key)
                }
            }
            guard let s = session else { break }
            // Codex review 3: no exception for the same `ProfileKey` (a payload namespace, not an NE configuration;
            // duplicate configurations are a supported state): a live lease is never overridden by key equality. The
            // incumbent is replaced only once its lease is no longer current (NE stopped, freed or reused it).
            if let o = s.owner, o.token != owner?.token, providers.isCurrent(o) {
                // Round 3 (Codex 4): a session already ending (its engine's teardown, then the cancel or, if it turned
                // out protected, a hold) is waited for, then decided against as it ends up.
                if phase == .stopping {
                    await waitForChange()
                    continue
                }
                // Codex final 1 / round 3: the incumbent's EFFECTIVE protection now (a flag save on a connected session
                // changes its enforcement at once, U7), not the flag it started with.
                switch verdict(killSwitchStart: killSwitchStart, key: key, incumbentKey: s.key,
                               incumbentIncludeAllNetworks: effectiveProtection(s).includeAllNetworks) {
                case .preempt:
                    engineLog.notice("start of a kill-switch profile ends the running session without the kill switch")
                    if let owner { reservation = (owner, key) }
                    await endForReplacement(LPTunnelError(.supersededByKillSwitch, detail: "another LockPlus profile with the kill switch took over"),
                                            reasonText: "superseded by a kill-switch profile")
                    if session != nil {                                     // vetoed: the session was kept
                        // Round 8 (Fable L1): the reservation goes back, so this start is a plain waiter from here on.
                        // Round 4 (2.0.2, Fable L1): a kill-switch start, so no later revision ends it (it waits and
                        // then loads the committed payload).
                        if let owner, reservation?.lease == owner { reservation = nil; wakeWaiters() }
                    }
                    continue
                case .wait:
                    // Final review M1: a duplicate kill-switch configuration of the running kill-switch profile waits,
                    // pending (blocked, so closed: E14a), bound to nothing and with no I/O, until that session ends or
                    // its instance stops; its own stop ends the wait. An instance NE abandoned keeps it waiting: closed.
                    if !notedWait {                     // round 3 N4: once per start
                        notedWait = true
                        engineLog.notice("start of the running kill-switch profile from another configuration waits for that session to end")
                    }
                    await waitForChange()
                    continue
                case .refuse:
                    throw refuse(key, sameProfile: key != nil && s.key == key)
                }
            }
            await stop(reason: .superseded)
        }
        if let owner, !providers.isCurrent(owner) { throw abandoned() }
        // (No invalidation check here: the loop's checks run after its last suspension.)
        // Round 5 (Codex 5): the latch as persisted NOW, after every wait (credentials updated meanwhile clear it; one
        // installed meanwhile counts), with nothing suspending between this read and the new session.
        let latched = activeLatch(req, at: wallClock())
        if let l = latched, !req.includeAllNetworks { throw LPTunnelError(l.code, detail: "start latched") }
        guard bind() else { throw LPTunnelError(.startCancelled, detail: "provider gone") }
        // The authorisation is recorded only for a start that is admitted (no suspension since the last check): an armed
        // start the guard refused or a removal cancelled must not overwrite the record NE's replay of the RUNNING session
        // of the same profile still needs.
        if let a = admission, let cfg = req.configuration {
            recordAuthorisation(ProfileKey(cfg), a, killSwitch: req.includeAllNetworks || cfg.policy.killSwitch)
        }
        let result: Result<Void, LPTunnelError> = await withCheckedContinuation { k in
            if let owner, reservation?.lease == owner { reservation = nil }
            beginStart(req, k, owner: owner, latched: latched)
            wakeWaiters()                        // starts waiting on the reservation re-check against this session
        }
        switch result { case .success: return; case .failure(let e): throw e }
    }

    private enum Verdict { case preempt, wait, refuse }

    /// The start latch that applies to `req` at `now`: an on-demand start of a profile with a `.hard` latch, or a
    /// `.backoff` latch not yet expired. nil for a manual start.
    private func activeLatch(_ req: StartRequest, at now: Date) -> StartLatch? {
        guard !req.options.isManual, let cfg = req.configuration, let l = persisted.latches[ProfileKey(cfg)]?.latch,
              l.kind == .hard || (l.notBefore.map { now < $0 } ?? false) else { return nil }
        return l
    }

    /// Round 5 (Codex 2): marks the guarded starts `match` selects with `e` and wakes them; each throws it at its next
    /// check, before admission.
    private func invalidateGuardedStarts(_ e: LPTunnelError, where match: (GuardedStart) -> Bool) {
        var any = false
        for (id, g) in guardedStarts where g.invalidated == nil && match(g) {
            guardedStarts[id]?.invalidated = e
            any = true
        }
        if any { wakeWaiters() }
    }

    /// The start guard's policy (DESIGN §7.2) for a start beside another live start's session or reservation:
    /// kill-switch priority over a session without the flag; a duplicate configuration of the running kill-switch
    /// profile waits; everything else is refused (first wins).
    private func verdict(killSwitchStart: Bool, key: ProfileKey?, incumbentKey: ProfileKey?, incumbentIncludeAllNetworks: Bool) -> Verdict {
        if killSwitchStart && !incumbentIncludeAllNetworks { return .preempt }
        if killSwitchStart, let key, incumbentKey == key { return .wait }
        return .refuse
    }

    /// `.anotherTunnelActive`, recorded like any failed start's error (the app's freshness check reads it as this
    /// attempt's). Review N3: under the app-asserted key, before any payload lookup (like every pre-validation failure,
    /// §1.3 A2); a constant, non-secret detail in the root-owned state file.
    private func refuse(_ key: ProfileKey?, sameProfile: Bool) -> LPTunnelError {
        let e = LPTunnelError(.anotherTunnelActive, detail: "another LockPlus tunnel is active")
        if let key { recordRefusal(e, key, sameProfile: sameProfile) }
        return e
    }

    /// The GUARD's read of a session's protection, used ONLY by the start guard's verdict and by the preemption's
    /// keep-or-cancel after the teardown (round 4, Fable M1: the two use the same read, or the start loop preempts, keeps
    /// and preempts again without suspending). Its provider's LIVE flags (a flag save on a connected session is
    /// enforced at once, U7), else the flags the session started with (the provider is gone or unbound).
    func effectiveProtection(_ s: Session) -> ProviderProtection {
        host.liveProtection(owner: s.owner) ?? startProtection(s)
    }

    /// Round 4 (Fable M1): the read for every hold-vs-cancel, withhold, latch and reconnect-budget decision. Protected
    /// when the live flags OR the start-time flags say so: the app never weakens a live session's flags itself (L-KS-2),
    /// so start-time on with live off is a system change (the drift `healProtectiveDrift` repairs only at `.connected`),
    /// and a protected session is HELD (or withheld), never cancelled or failed.
    func holdProtection(_ s: Session) -> ProviderProtection {
        let st = startProtection(s)
        guard let live = host.liveProtection(owner: s.owner) else { return st }
        return ProviderProtection(includeAllNetworks: st.includeAllNetworks || live.includeAllNetworks,
                                  enforceRoutes: st.enforceRoutes || live.enforceRoutes)
    }

    private func startProtection(_ s: Session) -> ProviderProtection {
        ProviderProtection(includeAllNetworks: s.includeAllNetworks, enforceRoutes: s.killSwitch && !s.includeAllNetworks)
    }

    /// Final review M1: suspends a waiting start until something it waits on may have changed (a session ended, a stop
    /// or a provider's release arrived, a reservation ended). The caller re-checks everything.
    private func waitForChange() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in waiters.append(k) }
    }

    private func wakeWaiters() {
        guard !waiters.isEmpty else { return }
        let w = waiters
        waiters = []
        for k in w { k.resume() }
    }

    #if DEBUG
    /// Tests only: a latch installed as a session's failure would (round 6, Fable L4: one appearing while a start waits).
    func installLatchForTesting(_ key: ProfileKey, _ latch: StartLatch) {
        persisted.latches[key] = .init(latch: latch, interval: nil)
    }
    #endif

    /// A provider instance was freed, or a provider's protection changed (`ProviderSeat`): waiting starts re-check.
    public func recheckWaitingStarts() {
        noteLiveKillSwitch()
        wakeWaiters()
    }

    /// Round 3 (Fable N3): the running session's record says `killSwitch` as soon as its live flags (or start-time
    /// flags) say so, saved at once: a crash before an orderly end must not leave the admission-time value (a record
    /// without the flag is revocable, and NE restarts a session protected by its live flags).
    private func noteLiveKillSwitch() {
        guard let s = session, let key = s.key, let rec = persisted.authorisedStarts[key], !rec.killSwitch,
              holdProtection(s).killSwitch else { return }
        persisted.authorisedStarts[key]?.killSwitch = true
        save()
    }

    private func abandoned() -> LPTunnelError {
        engineLog.notice("start abandoned: its provider was stopped meanwhile")
        return LPTunnelError(.startCancelled, detail: "provider stopped")
    }

    /// Review H1: the running session (decided unprotected BEFORE this, by `verdict`) yields to a kill-switch start,
    /// visibly to NE. A pending start fails with `e`. A started session stays TRACKED (phase `.stopping`) while its
    /// engine is torn down, under the starter's reservation; then its protection is read again (round 3, Codex 4): if it
    /// got `includeAllNetworks` meanwhile it is kept, HELD (closed), and the starter re-decides against it; otherwise it
    /// ends and its OWN provider is cancelled, so NE never keeps it Connected with nothing behind it.
    private func endForReplacement(_ e: LPTunnelError, reasonText: String) async {
        guard let s = session else { return }
        if s.startGate != nil {
            let previousError = s.key.flatMap { persisted.lastErrors[$0] }
            recordLastError(e, s.key)
            // Round 7 (Codex M3): read again after that I/O, right before failing the start (the guard's read, as in
            // the verdict): protected by then, it is kept and the 223 withdrawn; the preemptor re-decides against it.
            if session === s, effectiveProtection(s).includeAllNetworks {
                if let key = s.key { persisted.lastErrors[key] = previousError; save() }
                engineLog.notice("pending session protected by the time its 223 was recorded: kept")
                return
            }
            await stopSession(reasonText: reasonText, startError: e)
            return
        }
        beginEnding(s)
        for t in Array(teardowns.values) { await t.value }
        // The guard's read, as in the verdict (round 4, Fable M1). Round 4 N4: 223 is recorded only once it ends.
        // Round 5 (Codex 6, Fable N1): kept, it is held as interrupted, not as superseded (that start was refused).
        _ = finishEnding(s, e, reasonText: reasonText, recordError: true, keptAs: .sessionInterrupted,
                         keepIf: { self.effectiveProtection($0).includeAllNetworks })
    }

    /// The first half of ending a started session visibly: timers, prompt, engine and path watcher end; the session stays
    /// tracked as `.stopping` (a start beside it waits) until `finishEnding`.
    private func beginEnding(_ s: Session) {
        cancelSessionTimers()
        resolveLivePrompt()                     // round 4 N3: an after-Connected prompt showing is resolved for the app
        teardownAdapter()
        stopPathWatcher()
        phase = .stopping
    }

    /// The second half, after the engine's teardown: the protection is read again right before the cancel. Kept as a
    /// HELD session (`keepIf`) or ended and cancelled on its own provider. False: kept. A session that ended meanwhile
    /// (its own stop, or a successor's start) is left alone: NE ends it.
    ///
    /// Round 4 (Codex 2): the session stays tracked through the summary's plist I/O (S2 E3: written before the cancel,
    /// NE never calls `stopTunnel` after it), and the protection is read once more AFTER that I/O, immediately before
    /// the cancel, with nothing in between. A flag NE saves between that read and `cancelTunnelWithError` can't be
    /// excluded from our side (DESIGN §20 risk 27, accepted residual).
    /// `keptAs`: the hold code of a kept session (default: `e`'s).
    private func finishEnding(_ s: Session, _ e: LPTunnelError, reasonText: String, recordError: Bool = false,
                              keptAs: LPErrorCode? = nil, keepIf: (Session) -> Bool) -> Bool {
        guard session === s, phase == .stopping else { return true }
        let holdCode = keptAs ?? e.code
        if keepIf(s) { holdEnding(holdCode); return false }
        // Round 4 N4: the error is recorded only for a session that ends; one save carries it with the summary.
        let key = recordError ? s.key : nil
        let previousError = key.flatMap { persisted.lastErrors[$0] }
        if let key { persisted.lastErrors[key] = .init(error: e.asLPError, at: wallClock()) }
        let previousSessions = persisted.sessions          // round 5 (Fable N2): the append may trim the oldest
        let previousAuthorisation = s.key.flatMap { persisted.authorisedStarts[$0] }
        let dropped = dropAuthorisationOfEnding(s)
        let written = appendSummary(s, reason: reasonText)
        if key != nil || dropped, !written { save() }
        if keepIf(s) {                                      // protected during the I/O: kept, the end withdrawn
            if written { persisted.sessions = previousSessions }
            if let key { persisted.lastErrors[key] = previousError }
            if dropped, let k = s.key { persisted.authorisedStarts[k] = previousAuthorisation }
            save()
            holdEnding(holdCode)
            return false
        }
        forgetSession()
        host.cancel(with: e, owner: s.owner)
        return true
    }

    private func holdEnding(_ code: LPErrorCode) {
        engineLog.notice("session protected by the time its teardown finished: held, not cancelled")
        phase = .held(.blockedAfterFailure(code))
        host.setReasserting(true)
        wakeWaiters()
    }

    private func beginStart(_ req: StartRequest, _ k: CheckedContinuation<Result<Void, LPTunnelError>, Never>,
                            owner: ProviderLease?, latched: StartLatch?) {
        epoch &+= 1
        let s = Session(config: req.configuration, options: req.options, owner: owner,
                        dataPlane: req.dataPlaneOverride ?? config.dataPlane, backoff: config.backoff)
        s.protocolIncludeAllNetworks = req.protocolIncludeAllNetworks
        s.protocolEnforceRoutes = req.protocolEnforceRoutes
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
            // Round 6 (Codex r6 #1): the payload and its revision from one read.
            let found = try await secrets.load(.payload, pid, ownerUID: cfg.ownerUID)
            guard current(ep, .starting) else { return }
            guard let (entry, bytes) = found, entry.ownerUID == cfg.ownerUID, entry.id == pid else {
                throw LPError(.profileNotProvisioned)
            }
            if cfg.revision > entry.revision { throw LPError(.profileRevisionStale) }
            s.loadedRevision = entry.revision
            payload = bytes
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
            try validator?.validateForStart(kind: cfg.kind, payload: payload!)
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
        // Round 6 (Codex r6 #1): an answer to another revision's prompt is never used (the server prompts again).
        let sameRevision = s.answerRevision.map { $0 == s.loadedRevision } ?? true
        let binding = sameRevision ? s.answer : nil
        if binding == nil, s.answer != nil { engineLog.notice("answer of another payload revision dropped") }
        s.answer = nil; s.answerRevision = nil
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
        noteLiveKillSwitch()
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
        broker.live = .init(prompt: p, ownerUID: cfg.ownerUID, beforeConnected: true, challenge: ch, restartsEngine: true, revision: s.loadedRevision)
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
            broker.live = .init(prompt: p, ownerUID: cfg.ownerUID, beforeConnected: true, challenge: ch, restartsEngine: false, revision: s.loadedRevision)
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
        broker.live = .init(prompt: p, ownerUID: cfg.ownerUID, beforeConnected: false, challenge: ch, restartsEngine: false, revision: s.loadedRevision)
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
            } else if holdProtection(s).killSwitch {
                armLatch(key, e.code, .backoff)     // retryable kill-switch failure under on-demand
            }
        }
        if holdProtection(s).includeAllNetworks {
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
        } else if holdProtection(s).killSwitch {
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
    /// `stopTunnel` would do happens first: the adapter stops (its descriptors close), the pump and the path watcher
    /// end, the session summary is written. Only then the cancel, on the session's own provider (review M1). Round 3
    /// (Codex 1): the session stays tracked (`.stopping`) through the teardown and its EFFECTIVE protection is read
    /// again right before the cancel; protected by then (the kill switch enabled live), it is held instead.
    private func cancelAfterTeardown(_ e: LPTunnelError) {
        guard let s = session else { return }
        guard !holdProtection(s).killSwitch else {                  // never under the kill switch: hold instead
            teardownAdapter(); phase = .held(.blockedAfterFailure(e.code)); host.setReasserting(true); return
        }
        beginEnding(s)
        let pending = Array(teardowns.values)
        Task {
            for t in pending { await t.value }
            _ = finishEnding(s, e, reasonText: "error:\(e.code.rawValue)", keepIf: { self.holdProtection($0).killSwitch })   // L-LC-1
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
            if !holdProtection(s).killSwitch { s.reassertRemaining = config.reassertBudget; resumeReassertBudget() }
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
        guard let s = session, let rem = s.reassertRemaining, !holdProtection(s).killSwitch else { return }
        s.reassertArmedAt = clock.now
        arm(.reassertBudget, after: rem) { $0.reassertBudgetExhausted() }
    }

    private func reassertBudgetExhausted() {
        // Round 3 (Codex 1): a kill switch enabled live ends the budget (kill switch on: retry at the cap, never cancel).
        guard let s = session, !holdProtection(s).killSwitch else { return }
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

    /// Review L4: `owner` is the calling provider's lease; another instance's sleep or wake never drives this session.
    public func sleep(owner: ProviderLease? = nil) async {
        if let owner, let o = session?.owner, o != owner { return }
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

    public func wake(owner: ProviderLease? = nil) async {
        if let owner, let o = session?.owner, o != owner { return }
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
    /// `owner`: the provider instance whose `stopTunnel` this is. It never ends a session another live instance owns
    /// (a refused start's provider, or a stop that lands after a newer instance replaced this one's session).
    public func stop(reason: StopReason, owner: ProviderLease? = nil) async {
        wakeWaiters()                             // a waiting start (its own stop, or its incumbent's) re-checks
        if let owner, let o = session?.owner, o != owner, providers.isCurrent(o) {
            engineLog.notice("stop ignored: another provider instance owns the running session")
            // Review N1: this instance's own replaced session may still be tearing down; NE's stop completion waits.
            for t in Array(teardowns.values) { await t.value }
            return
        }
        // 2.0.2 (PLAN §3.1): only the user's stop and a removed configuration end the authorisation of the session being
        // stopped (a stop that landed on another live instance's session returned above). providerFailed, noNetwork, sleep,
        // appUpdate and every other end keep it for a kill-switch session: NE's own restart of the session must still be
        // honoured (any other session's record goes when it ends, round 1 L5: `dropAuthorisationOfEnding`).
        if reason == .userInitiated || reason == .configurationRemoved, let key = session?.key {
            noteUserClear(key)
            clearAuthorisation(key)
        }
        await stopSession(reasonText: reason == .userInitiated ? "user" : reason == .sleep ? "sleep" : "\(reason)", startError: nil)
    }

    // MARK: - start authorisation (2.0.2, PLAN §3)

    /// `armStart` over XPC: the caller (kernel-reported `ownerUID`, already checked to have `profileID` provisioned in its
    /// own namespace) announces the manual start it is about to make. Returns when the arm expires.
    public func armStart(profileID: UUID, ownerUID: uid_t, nonce: UUID) -> Date {
        arms.arm(ProfileKey(ownerUID: ownerUID, profileID: profileID), nonce: nonce, now: wallClock())
    }

    /// Round 1 (Codex 4), round 2 (Fable L1, L3; Codex r2 #2): the owner's unattended-start consent now stands only for
    /// `keep` (the profiles with an Auto-Connect or Stay Connected plan, and those the app sees starting, running or
    /// awaiting NE's restart). Consent for NEW unattended sessions is the configuration's on-demand rules (row 3); this
    /// withdraws what is left over: the `unattended` fact of a record whose session NE never restarts (no kill switch,
    /// e.g. one whose process died before its end could drop the record; a record left with no nonce goes). Never
    /// touched: a kill-switch session's record (NE's own restart after a crash, `noNetwork` or `providerFailed` must
    /// still be admitted, the plan's stop condition; such a record ends with the user's stop, a removal, a wipe or the
    /// next boot), the running session's, a profile with a start in the guard, and armed nonces (L4).
    public func revokeUnattended(keeping keep: Set<UUID>, ownerUID: uid_t) {
        revokePages[ownerUID] = nil                   // a single-page request supersedes a partial batch
        applyRevoke(keeping: keep, ownerUID: ownerUID)
    }

    /// Round 3 (Codex r3 #8): one page of a keep set sent in `count` pages of `batch`. The union is applied only once
    /// every page of the same batch arrived; a page of another batch starts over (only the newest batch counts).
    public func revokeUnattendedPage(batch: UUID, page: Int, count: Int, keeping keep: Set<UUID>, ownerUID: uid_t) {
        guard count > 1 else { revokeUnattended(keeping: keep, ownerUID: ownerUID); return }
        guard (0..<count).contains(page) else { return }
        var b = revokePages[ownerUID].flatMap { $0.batch == batch && $0.count == count ? $0 : nil } ?? (batch: batch, count: count, pages: [:])
        b.pages[page] = keep
        guard b.pages.count == count else { revokePages[ownerUID] = b; return }
        revokePages[ownerUID] = nil
        applyRevoke(keeping: b.pages.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }, ownerUID: ownerUID)
    }

    private func noteUserClear(_ key: ProfileKey) {
        guard !guardedStarts.isEmpty else { return }     // round 4 (Fable N3): only a start in the guard reads it
        userClearSeq &+= 1
        userClearedAt[key] = userClearSeq
    }

    private func userClearedSince(_ seq: UInt64, _ key: ProfileKey) -> Bool {
        (userClearedAt[key] ?? 0) > seq || (ownerClearedAt[key.ownerUID] ?? 0) > seq
    }

    private func applyRevoke(keeping keep: Set<UUID>, ownerUID: uid_t) {
        let live = session?.key
        let guarded = Set(guardedStarts.values.compactMap(\.key))
        var changed = false
        for (key, rec) in persisted.authorisedStarts where key.ownerUID == ownerUID && rec.isUnattended && !rec.killSwitch {
            guard !keep.contains(key.profileID), key != live, !guarded.contains(key) else { continue }
            if rec.nonce == nil { persisted.authorisedStarts[key] = nil } else { persisted.authorisedStarts[key]?.unattended = false }
            changed = true
        }
        if changed { save() }
    }

    /// What an admitted start records (round 2, L4: merged into the existing record of this boot, never overwriting the
    /// other fact).
    enum Admission: Sendable, Equatable {
        case armed(UUID)
        case unattended
        case replay(AuthorisedStart)
    }

    /// Past `maxAuthorisedStarts` the oldest record goes, never the one just admitted nor the running session's (round 1,
    /// Fable L5: a long-running session is the oldest, and its NE restart needs its record).
    private func recordAuthorisation(_ key: ProfileKey, _ admission: Admission, killSwitch: Bool) {
        let now = wallClock()
        let existing = persisted.authorisedStarts[key].flatMap { $0.boot == bootSession ? $0 : nil }
        switch admission {
        case .armed(let n):
            persisted.authorisedStarts[key] = AuthorisedStart(nonce: n, at: now, unattended: existing?.unattended ?? false, boot: bootSession,
                                                              killSwitch: killSwitch)
        case .unattended:
            persisted.authorisedStarts[key] = AuthorisedStart(nonce: existing?.nonce, at: now, unattended: true, boot: bootSession,
                                                              killSwitch: killSwitch)
        case .replay(let matched):
            // The record NE's restart matched is the one that stays; a revoke during the guard wait removed nothing for good.
            // Round 3 (Fable N1): never one a user's act ended (the start is refused before admission then).
            guard existing == nil else { return }
            persisted.authorisedStarts[key] = matched
        }
        if persisted.authorisedStarts.count > PersistedTunnelState.maxAuthorisedStarts,
           let victim = Self.evictionCandidate(persisted.authorisedStarts, admitted: key, live: session?.key) {
            persisted.authorisedStarts[victim] = nil
        }
        save()
    }

    /// Round 4 (Codex r4, FIX3 refusal path 2): which record makes room past the cap. Never the one just admitted nor the
    /// running session's. A record without a kill switch first (NE never restarts such a session), oldest first; then a
    /// kill-switch record of the ADMITTING owner (another local user filling the table pushes out only their own); a
    /// kill-switch record of another owner only when nothing else is left (that needs 256 kill-switch records of one
    /// boot).
    static func evictionCandidate(_ records: [ProfileKey: AuthorisedStart], admitted: ProfileKey, live: ProfileKey?) -> ProfileKey? {
        let others = records.filter { $0.key != admitted && $0.key != live }
        func oldest(_ m: [ProfileKey: AuthorisedStart]) -> ProfileKey? { m.min { $0.value.at < $1.value.at }?.key }
        return oldest(others.filter { !$0.value.killSwitch })
            ?? oldest(others.filter { $0.key.ownerUID == admitted.ownerUID })
            ?? oldest(others)
    }

    /// Round 1 (Fable L5): NE restarts only a session with a kill switch (E2E-4); the record of any other session that
    /// ends goes with it, which also keeps the replay surface small. In memory: the caller's next save carries it.
    /// Returns whether a record was dropped. Protection as `holdProtection` reads it (start-time or live flags): a
    /// session either says is protected keeps its record.
    private func dropAuthorisationOfEnding(_ s: Session) -> Bool {
        guard let key = s.key else { return false }
        if holdProtection(s).killSwitch {
            // Round 2 (Codex r2 #2): protected by its live flags at its end: NE restarts it, so never revocable.
            persisted.authorisedStarts[key]?.killSwitch = true
            return false
        }
        return persisted.authorisedStarts.removeValue(forKey: key) != nil
    }

    /// Drops the persisted authorisation only; a pending arm is the NEXT start's and survives (a late stop of the old
    /// session must not burn it).
    private func clearAuthorisation(_ key: ProfileKey) {
        if persisted.authorisedStarts.removeValue(forKey: key) != nil { save() }
    }

    /// `stop`'s body. `startError`: what a pending start completes with (default: the held error, else `.startCancelled`).
    private func stopSession(reasonText: String, startError: LPTunnelError?) async {
        if let s = session {
            if s.startGate != nil {
                s.startTask?.cancel()
                resolveLivePrompt()
                completeStart(.failure(startError ?? s.heldError ?? .of(.startCancelled)))
            }
            phase = .stopping
            cancelAllTimers()
            teardownAdapter()
            endSession(reason: reasonText)
        }
        stopPathWatcher()
        // Re-check N1: the tasks stay in `teardowns` until each removes itself (`teardownFinished`), so a stop that
        // arrives meanwhile (an ignored late stop, a second stop) waits for the same engine stops.
        for t in Array(teardowns.values) { await t.value }
    }

    // MARK: - teardown helpers

    private func completeStart(_ r: Result<Void, LPTunnelError>) {
        guard let s = session, let k = s.startGate else { return }
        s.startGate = nil
        s.answer = nil; s.answerRevision = nil    // an unused answer never outlives its start
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
        let dropped = dropAuthorisationOfEnding(s)
        if !appendSummary(s, reason: reason), dropped { save() }
        forgetSession()
    }

    /// The session's summary (plist I/O). True: one was written.
    private func appendSummary(_ s: Session, reason: String) -> Bool {
        guard let id = s.sessionID, let key = s.key, let at = s.connectedAt else { return false }
        let summary = SessionSummary(id: id, profileID: key.profileID, start: at, end: wallClock(),
                                     rxBytes: s.stats.rxBytes, txBytes: s.stats.txBytes, endReason: reason)
        persisted.sessions.append(.init(ownerUID: key.ownerUID, summary: summary))
        if persisted.sessions.count > 100 { persisted.sessions.removeFirst(persisted.sessions.count - 100) }
        save()
        return true
    }

    /// The bookkeeping half of ending a session: no I/O.
    private func forgetSession() {
        guard let s = session else { return }
        cancelAllTimers()
        s.answer = nil; s.answerRevision = nil
        resolveLivePrompt()
        session = nil
        phase = .idle
        wakeWaiters()
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

    /// Review L3: a refusal's error is always current in memory (the app's freshness check reads it through the
    /// snapshot), but repeated refusals of one profile (NE retrying an on-demand start) reach the disk at most once a
    /// minute, and are logged at notice level only then.
    private func recordRefusal(_ e: LPTunnelError, _ key: ProfileKey, sameProfile: Bool, unauthorised: Bool = false) {
        let now = wallClock()
        persisted.lastErrors[key] = .init(error: e.asLPError, at: now)
        let what = unauthorised ? "start not authorised by the profile's owner" : "another provider instance owns the running session"
        if let at = refusalSavedAt[key], now.timeIntervalSince(at) < 60, at <= now {
            engineLog.debug("start refused again: \(what, privacy: .public)")
            return
        }
        if sameProfile {
            // Codex final 6: throttled with the refusal (once a minute per profile), not per start.
            engineLog.fault("start of the running session's own profile from another live provider instance (a duplicate configuration, or an instance NE never stopped): refused")
        }
        engineLog.notice("start refused: \(what, privacy: .public)")
        refusalSavedAt = refusalSavedAt.filter { now.timeIntervalSince($0.value) < 60 }   // re-check N4: bounded
        refusalSavedAt[key] = now
        save()
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
    /// Round 9 (Codex LOW): only the caller's own recorded last error, for a profile whose payload is gone (a refusal is
    /// recorded before any payload lookup, and the app's freshness check reads its time). No session data.
    public func lastErrorSnapshot(profileID: UUID, ownerUID: uid_t) -> TunnelSnapshot {
        var snap = TunnelSnapshot(profileID: profileID, phase: .idle, epoch: 0)
        if let le = persisted.lastErrors[ProfileKey(ownerUID: ownerUID, profileID: profileID)] { snap.lastError = le.error; snap.lastErrorAt = le.at }
        return snap
    }

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
                s.answerInFlight = promptID
                let rev = l.revision
                if answer.save, let key = s.key { await saveAnswer(answer, key, revision: rev) }
                guard session === s, s.answerInFlight == promptID, phase == .awaitingAuth(beforeConnected: true),
                      s.isWaitingBeforeConnected else {
                    throw LPError(.staleAnswer)
                }
                s.answerInFlight = nil
                s.answer = StashBinding(promptID: promptID, answer: answer, carriedUsername: l.challenge.carriedUsername,
                                        carriedPassword: l.challenge.carriedPassword, cookie: l.challenge.cookie)
                s.answerRevision = rev
                phase = .starting
                let ep = epoch
                s.startTask = Task { await self.runStarting(ep) }
                return
            }
            guard let a = s.adapter else { throw LPError(.staleAnswer) }
            broker.live = nil
            sink?.promptResolved(promptID: promptID, profileID: l.prompt.profileID, ownerUID: l.ownerUID)
            if l.beforeConnected { s.answerInFlight = promptID }
            let rev = l.revision
            if answer.save, let key = s.key { await saveAnswer(answer, key, revision: rev) }
            guard session === s, let a2 = s.adapter, a2 === a, !l.beforeConnected || s.answerInFlight == promptID else {
                throw LPError(.staleAnswer)
            }
            s.answerInFlight = nil
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
    /// Round 5 (Codex r5 #6): `revision`: the payload revision the prompt's attempt loaded (nil: a prepared prompt, any).
    /// Round 6 (Codex r6 #2 = Fable r6 N1): the write is conditional in the store on the payload still being at that
    /// revision, so a newer revision provisioned before or during the save always keeps its own credentials.
    private func saveAnswer(_ a: AuthAnswerSecrets, _ key: ProfileKey, revision: UInt64? = nil) async {
        guard let p = try? await secrets.entry(.payload, key.profileID, ownerUID: key.ownerUID), p.ownerUID == key.ownerUID,
              revision.map({ $0 == p.revision }) ?? true else { return }
        var c = (try? await secrets.get(.credential, p.id, ownerUID: p.ownerUID)).flatMap { $0.flatMap(CredentialCodec.decode) }
            ?? CredentialSecrets()
        if let u = a.username { c.username = u }
        if let pw = a.password { c.password = pw }
        _ = try? await secrets.putCredential(p.id, ownerUID: p.ownerUID, ifPayloadRevision: p.revision, CredentialCodec.encode(c))
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
    /// owner's profile only). It keeps the start authorisation (round 1, Fable H1a).
    public func profileProvisioned(_ pid: UUID, ownerUID: uid_t, revision: UInt64) {
        let key = ProfileKey(ownerUID: ownerUID, profileID: pid)
        if let l = persisted.latches[key]?.latch, revision > l.revision { clearLatch(key) }
        broker.dropPrepared(key)
        // Round 1 (Fable H1a): the authorisation is NOT cleared here. It belongs to the session, which a provision does not
        // end ("Save Only" keeps a connected session up on the old payload); NE's restart of that session replays its
        // options and must be honoured. The user's stop, a removal and a wipe still clear it; the next armed start replaces it.
        payloadCommitted(pid, ownerUID: ownerUID, revision: revision)
    }

    /// Round 6 (Codex M2, Fable N3): the payload of `revision` is stored (called right after the write, before any
    /// credential I/O, and again by a same-revision retry after a partial failure: idempotent). A waiting start and every
    /// start in the guard of an OLDER revision end. Round 6 (Fable L3): not the start holding the reservation of a
    /// preemption already decided (its teardown can't be undone): it proceeds on the new payload (`runStarting` accepts
    /// a configuration older than the payload).
    ///
    /// Round 3 (Codex r3 #1, HIGH): the waiting start of a session with a kill switch (start-time or live flags) is NEVER
    /// ended by a commit. A failed protected start is open (E14c), and this one may be NE's authorised replay that no app
    /// will start again (a verified Save Only revision provisioned in the background while NE restarts the old one). It
    /// goes on: an attempt in flight finishes on the payload it loaded; a hold retries at its own time (or when new
    /// credentials arrive, `credentialsUpdated`) and loads the committed payload under the configuration NE started with,
    /// exactly as NE's restart after a Save Only does (`runStarting` accepts a configuration older than the payload).
    ///
    /// Round 4 (2.0.2, Fable L1 = Codex r4 #1): the same for a kill-switch start still in the GUARD, in every wait (a
    /// duplicate beside its running profile, a `.stopping` incumbent of any profile, a stale session's teardown after NE
    /// stopped the old instance): it is never invalidated by a commit and, once admitted, loads the committed payload. A
    /// start without a kill switch in the guard of an older revision still ends (the app starts the new revision; a
    /// failed split start is not open). Fable N2: a kept start at a live before-Connected prompt gets a fresh attempt on
    /// the new revision (the prompt is resolved, its carried credentials and challenge cookie of the old revision's server
    /// are never sent), and prompts again if the server asks.
    ///
    /// Round 5 (Fable r5 N2, Codex r5 #6), kill-switch starts only: "newer" means above the revision the current attempt
    /// LOADED (not the one NE started with), so a second commit of that revision (a same-revision retry, a reconcile)
    /// keeps its prompt; an answer being applied across its save counts as a live prompt (it is dropped and the fresh
    /// attempt prompts again). Round 6 (Fable r6 L2): a start without a kill switch still compares with the revision NE
    /// started it under (round 6 Codex M2), so a same-revision retry ends a start of the old configuration even when it
    /// already loaded the new payload (possibly beside the old revision's credentials).
    public func payloadCommitted(_ pid: UUID, ownerUID: uid_t, revision: UInt64) {
        let key = ProfileKey(ownerUID: ownerUID, profileID: pid)
        if let s = session, s.key == key, s.isWaitingBeforeConnected {
            if holdProtection(s).killSwitch {
                if revision > s.loadedRevision {
                    engineLog.notice("profile changed during a kill-switch start: the start goes on (revision \(revision) is used by its next attempt)")
                    restartAttemptAtLivePrompt(s)
                }
            } else if revision > (s.config?.revision ?? 0) {
                endWaitingStart(key, reason: "profile changed")
            }
        }
        invalidateGuardedStarts(.of(.startCancelled, "profile changed")) {
            $0.key == key && revision > $0.revision && !$0.killSwitch
        }
    }

    /// Fable N2 (round 4): a kill-switch start kept across a commit while its before-Connected prompt is live (or its
    /// answer is stashed for the next attempt, or, round 5 Codex r5 #6, is being applied across the save's await): the
    /// prompt is resolved and the answer dropped (both belong to the old revision's server), and a fresh attempt starts
    /// now on the committed payload.
    private func restartAttemptAtLivePrompt(_ s: Session) {
        let live = broker.live.flatMap { $0.beforeConnected && $0.ownerUID == s.key?.ownerUID && $0.prompt.profileID == s.key?.profileID ? $0 : nil }
        guard live != nil || s.answer != nil || s.answerInFlight != nil else { return }
        if let l = live {
            broker.live = nil
            sink?.promptResolved(promptID: l.prompt.promptID, profileID: l.prompt.profileID, ownerUID: l.ownerUID)
        }
        s.answer = nil; s.answerRevision = nil; s.answerInFlight = nil
        cancel(.authDeadline)
        s.startTask?.cancel()
        teardownAdapter()
        cancel(.connect); cancel(.heldRetry)
        phase = .starting
        let ep = epoch
        s.startTask = Task { await self.runStarting(ep) }
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
        invalidateGuardedStarts(.of(.startCancelled, "profile removed")) { $0.key == key }
        noteUserClear(key)
        clearLatch(key); broker.dropPrepared(key); arms.drop(key)
        persisted.authorisedStarts[key] = nil
        persisted.lastErrors[key] = nil; persisted.endpointHosts[key] = nil; persisted.authFailedAt[key] = nil; save()
    }
    /// `wipeAllSecrets` (L1): the caller's latches, resend guards, last errors, cached endpoints, session-ring
    /// entries (NEW-6) and prompts only; other uids keep theirs.
    public func secretsWiped(ownerUID: uid_t) {
        if let key = session?.key, key.ownerUID == ownerUID { endWaitingStart(key, reason: "secrets wiped") }
        invalidateGuardedStarts(.of(.startCancelled, "secrets wiped")) { $0.key?.ownerUID == ownerUID }
        if !guardedStarts.isEmpty {
            userClearSeq &+= 1
            ownerClearedAt[ownerUID] = userClearSeq
        }
        persisted.latches = persisted.latches.filter { $0.key.ownerUID != ownerUID }
        persisted.authFailedAt = persisted.authFailedAt.filter { $0.key.ownerUID != ownerUID }
        persisted.lastErrors = persisted.lastErrors.filter { $0.key.ownerUID != ownerUID }
        persisted.endpointHosts = persisted.endpointHosts.filter { $0.key.ownerUID != ownerUID }
        persisted.sessions.removeAll { $0.ownerUID == ownerUID }
        persisted.authorisedStarts = persisted.authorisedStarts.filter { $0.key.ownerUID != ownerUID }
        arms.drop(ownerUID: ownerUID)
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
