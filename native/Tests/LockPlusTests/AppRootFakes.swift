import Foundation
import LPModel
import LPParsing
import LPWire
import Observation
import Synchronization
import Testing
@testable import LockPlus

// Fakes for the app-root tests: no NetworkExtension, no XPC, no SystemExtensions, no host keychain.

/// A scratch directory under ~/Library/Caches (never /tmp), removed by `cleanup()`.
struct TestDir {
    let url: URL
    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = caches.appending(path: "io.github.steiale.lockplus.tests/\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var data: AppDataDirectory { AppDataDirectory(root: url) }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

@MainActor final class FakeVPNManager: VPNManaging {
    struct Entry { var cfg: ManagerConfiguration; var status: TunnelStatus; var onDemand: Bool }
    var entries: [UUID: Entry] = [:]
    var starts: [(UUID, [String: NSObject])] = []
    /// E2E-3: the profiles with on-demand enabled at each `start` (in `starts` order).
    var onDemandAtStart: [Set<UUID>] = []
    var startError: LPError?
    var stops: [UUID] = []
    var fetchCount = 0
    var lastError: NSError?
    var saveError: LPError?
    /// The next save / on-demand change fails with NEVPNError.configurationStale (review H3).
    var staleNext = false
    var removeError: LPError?
    var loadError: LPError?
    var onDemandError: LPError?
    /// Review 2026-10-30: every on-demand state CHANGE per profile (a save or `setOnDemandEnabled`), in order, so a
    /// pause and its restore read `[false, true]`.
    var onDemandChanges: [UUID: [Bool]] = [:]
    /// E2E-1: macOS (nehelper) rewrote a just-saved configuration without includeAllNetworks. Every save drops it.
    var dropIncludeAllNetworksOnSave = false
    var loads = 0
    /// begin/end markers of every mutation, to prove serialization.
    var log: [String] = []
    var onStatusChange: ((UUID, TunnelStatus) -> Void)?
    var onConfigurationChange: (() -> Void)?
    /// Pulsed after every state change of the fake (`until` re-checks its condition on it: event-driven, no polling).
    var onChange: (@MainActor () -> Void)?

    static let stale = LPError(.extensionUnavailable, detail: "saveToPreferences: configurationStale")

    /// Suspends like NE does, so concurrent callers can interleave unless something serializes them.
    private func hop() async { for _ in 0..<3 { await Task.yield() } }

    /// One-shot: suspends the next `loadAll` after its hop until the test lets it go (a start's prepare parked inside its reload).
    var loadGate: (@MainActor () async -> Void)?
    /// Called at the start of each `save` (before its hop): a Delete, or anything else, can begin inside the save.
    var onSave: (@MainActor (UUID) -> Void)?

    func loadAll() async throws(LPError) {
        log.append("begin load")
        await hop()
        if let g = loadGate { loadGate = nil; await g() }
        loads += 1
        log.append("end load")
        onChange?()
        if let loadError { throw loadError }
    }
    var managers: [ManagerSnapshot] {
        entries.map { id, e in
            ManagerSnapshot(profileID: id, stored: .init(revision: e.cfg.provider.revision, metaRev: e.cfg.provider.metaRev, ownerUID: e.cfg.provider.ownerUID),
                            flags: e.cfg.flags, onDemandEnabled: e.onDemand, status: e.status)
        }
    }
    func save(_ cfg: ManagerConfiguration) async throws(LPError) {
        log.append("begin save \(cfg.name)")
        onSave?(cfg.profileID)
        await hop()
        defer { log.append("end save \(cfg.name)"); onChange?() }
        if staleNext { staleNext = false; throw Self.stale }
        if let saveError { throw saveError }
        var kept = cfg
        if dropIncludeAllNetworksOnSave { kept.flags.includeAllNetworks = false }
        let was = entries[cfg.profileID]?.onDemand
        entries[cfg.profileID] = Entry(cfg: kept, status: entries[cfg.profileID]?.status ?? .disconnected, onDemand: cfg.onDemand?.enabled ?? false)
        if let was, was != entries[cfg.profileID]?.onDemand { onDemandChanges[cfg.profileID, default: []].append(!was) }
    }
    func remove(_ id: UUID) async throws(LPError) {
        await hop()
        if let removeError { throw removeError }
        entries[id] = nil
        removed.append(id)
    }
    /// Every `remove` (profile IDs) and `removeStray` (keys), in order.
    var removed: [UUID] = []
    /// E2E-4: unaddressable configurations (no profile ID, a duplicate), any user's.
    var strayEntries: [StraySnapshot] = []
    var strays: [StraySnapshot] { strayEntries }
    func removeStray(_ key: UUID) async throws(LPError) {
        await hop()
        if let removeError { throw removeError }
        strayEntries.removeAll { $0.key == key }
        removed.append(key)
    }
    /// Called at each `setOnDemandEnabled`, before its hop (ordering probes, review b47da1c).
    var onSetOnDemand: (@MainActor (UUID, Bool) -> Void)?
    func setOnDemandEnabled(_ on: Bool, for id: UUID) async throws(LPError) {
        onSetOnDemand?(id, on)
        await hop()
        defer { onChange?() }
        if staleNext { staleNext = false; throw Self.stale }
        if let onDemandError { throw onDemandError }
        if let was = entries[id]?.onDemand, was != on { onDemandChanges[id, default: []].append(on) }
        entries[id]?.onDemand = on
    }
    func status(_ id: UUID) -> TunnelStatus { entries[id]?.status ?? .invalid }
    /// Called at each `start`, before it is recorded (ordering probes).
    var onStart: ((UUID) -> Void)?
    func start(_ id: UUID, options: [String: NSObject]) throws(LPError) {
        defer { onChange?() }               // wakes `until` (pre-release review: it passed by scheduling order only)
        onStart?(id)
        if let startError { throw startError }
        starts.append((id, options))
        onDemandAtStart.append(Set(entries.filter(\.value.onDemand).map(\.key)))
    }
    /// How `stop` reports (review e321e10). `.silent`: the status is `.disconnected` at once and nothing is reported (most
    /// tests emit by hand). `.reports(end)`: like NE, `.disconnecting` is reported later (a task hop), then `end`; nil
    /// never ends it (a `.disconnected` NE never delivered).
    enum StopReport { case silent, reports(TunnelStatus?) }
    var stopReport: StopReport = .silent
    func stop(_ id: UUID) {
        defer { onChange?() }
        stops.append(id)
        switch stopReport {
        case .silent: entries[id]?.status = .disconnected
        case .reports(let end):
            Task { @MainActor in
                guard self.entries[id] != nil else { return }
                self.emit(id, .disconnecting)
                guard let end else { return }
                await Task.yield()
                if self.entries[id] != nil { self.emit(id, end) }
            }
        }
    }
    /// Review R9: a wedged nesessionmanager never answers.
    var fetchNeverAnswers = false
    func fetchLastDisconnectError(_ id: UUID) async -> NSError? {
        fetchCount += 1
        if fetchNeverAnswers { try? await Task.sleep(for: .seconds(60)) }
        return lastError
    }

    /// What NE would report.
    func emit(_ id: UUID, _ s: TunnelStatus) {
        defer { onChange?() }
        entries[id]?.status = s
        onStatusChange?(id, s)
    }
}

/// Scripted XPC service; records every call.
final class FakeTunnelService: TunnelServicing {
    struct State {
        var calls: [LPMethod] = []
        var resets = 0
        var provisioned: [UUID: ProvisionedEntry] = [:]
        var snapshot: TunnelSnapshot?
        var prompt: AuthPrompt?
        var answers: [WireAuthAnswer] = []
        var failAll: LPError?
        var validateAccepts = true
        /// PF 50: every `pushEndpoints` request, and the outcome to answer.
        var pushes: [PushEndpointsRequest] = []
        var pushOutcome: PushEndpointsReply.Outcome = .retrying
        /// Review PF-R1: when the XPC link was last interrupted (a tunnel-process crash).
        var linkInterruptedAt: Date?
    }
    let state = Mutex(State())
    let events = AsyncStream<TunnelEvent> { _ in }
    let linkUpdates = AsyncStream<ServiceLinkStatus> { _ in }

    func calls(_ m: LPMethod) -> Int { state.withLock { $0.calls.filter { $0 == m }.count } }

    func hello() async throws(LPError) -> ServerHello {
        ServerHello(extVersion: "2.0.0", extBuild: "test", capabilities: [.openVPN, .wireGuard])
    }

    func call<Req: Encodable & Sendable, Resp: Decodable & Sendable>(
        _ method: LPMethod, _ request: Req, as: Resp.Type) async throws(LPError) -> Resp {
        let s = state.withLock { $0.calls.append(method); return $0 }
        if let e = s.failAll { throw e }
        let v: Any
        switch method {
        case .tunnelSnapshot:
            guard let snap = s.snapshot else { throw LPError(.extensionUnavailable) }
            v = snap
        case .listProvisioned: v = ListProvisionedReply(entries: Array(s.provisioned.values))
        case .pendingAuthPrompt: v = PendingAuthPromptReply(prompt: s.prompt)
        case .prepareStartAuth:
            guard let r = request as? PrepareStartAuth else { throw LPError(.malformedRequest) }
            v = AuthPrompt(promptID: UUID(), profileID: r.profileID, kind: r.kind, challengeText: nil, echo: false, lockedUsername: nil,
                           reason: .initial, savedUsername: "u", nextStart: true, expiresAt: Date().addingTimeInterval(600))
        case .validateProfile: v = ValidateProfileReply(error: s.validateAccepts ? nil : LPError(.unsupportedDirective), rejectedCategory: s.validateAccepts ? nil : "UNUSED_OPTIONS", autologin: true)
        case .sessionSummaries: v = SessionSummariesReply(sessions: [])
        case .pushEndpoints:
            guard let r = request as? PushEndpointsRequest, r.isWireValid else { throw LPError(.malformedRequest) }
            v = state.withLock { $0.pushes.append(r); return PushEndpointsReply(outcome: $0.pushOutcome) }
        default: throw LPError(.malformedRequest)
        }
        guard let r = v as? Resp else { throw LPError(.malformedRequest) }
        return r
    }

    func callVoid<Req: Encodable & Sendable>(_ method: LPMethod, _ request: Req) async throws(LPError) {
        let fail = state.withLock { $0.calls.append(method); return $0.failAll }
        if let fail { throw fail }
        if let r = request as? ProvisionRequest {
            let digest = PayloadDigest.sha256Hex(String(decoding: r.payload, as: UTF8.self))
            state.withLock { $0.provisioned[r.profileID] = ProvisionedEntry(id: r.profileID, revision: r.revision, digest: digest) }
        }
        if let a = request as? WireAuthAnswer { state.withLock { $0.answers.append(a) } }
    }

    func resetAfterUserAction() async { state.withLock { $0.resets += 1 } }

    func lastLinkInterruption() async -> Date? { state.withLock { $0.linkInterruptedAt } }
}

@MainActor @Observable final class FakeExtension: ExtensionControlling {
    var state: SystemExtensionManager.State = .ready(version: "2.0.0")
    var activationEndedWithoutResult = false
    var updateInProgress = false
    var link = ServiceLinkStatus.idle
    @ObservationIgnored var onReady: (@MainActor () -> Void)?
    @ObservationIgnored var onPreflightFinished: (@MainActor () -> Void)?
    var retries = 0
    var reinstalls = 0
    var deactivations = 0
    var deactivateError: LPError?

    func start() { onPreflightFinished?() }
    func retryAfterUserAction() async { retries += 1 }
    func reinstall() async throws(LPError) { reinstalls += 1 }
    func deactivate() async throws(LPError) {
        deactivations += 1
        if let deactivateError { throw deactivateError }
    }
    func openExtensionSettings() {}
}

/// A settle clock that never really sleeps: `sleep` advances its own time and records the request.
final class FakeSettleClock: Sendable {
    private let state = Mutex<(t: Duration, sleeps: [Duration])>((.zero, []))
    private let hook = Mutex<(@Sendable () async -> Void)?>(nil)
    var sleeps: [Duration] { state.withLock { $0.sleeps } }
    func advance(_ d: Duration) { state.withLock { $0.t += d } }
    /// Runs once, inside the first sleep (the window between the pause and the start).
    func onFirstSleep(_ body: @escaping @Sendable () async -> Void) { hook.withLock { $0 = body } }
    var clock: SettleClock {
        SettleClock(now: { [self] in state.withLock { $0.t } },
                    sleep: { [self] d in
                        state.withLock { $0.sleeps.append(d); $0.t += d }
                        if let body = hook.withLock({ let b = $0; $0 = nil; return b }) { await body() }
                    })
    }
}

/// `ConnectionStore.timerSleep` that never really sleeps: each timer waits until the test releases it with `fire`.
/// Replaces a short real timeout that raced the test's own assertions.
final class FakeTimers: Sendable {
    private let state = Mutex<(next: Int, armed: [Int: (d: Duration, go: AsyncStream<Void>.Continuation)])>((0, [:]))
    var armed: [Duration] { state.withLock { $0.armed.sorted { $0.key < $1.key }.map(\.value.d) } }
    var sleeper: @Sendable (Duration) async -> Void {
        { [self] d in
            let (stream, go) = AsyncStream<Void>.makeStream()
            let id = state.withLock { s in s.next += 1; s.armed[s.next] = (d, go); return s.next }
            // A cancelled sleeper leaves `armed` at once (in the cancel call), not when its task next runs: the store
            // cancels the old entry's timer and arms the new one in the same turn, and `fire` must never release the stale one.
            await withTaskCancellationHandler {
                for await _ in stream { break }
            } onCancel: {
                state.withLock { _ = $0.armed.removeValue(forKey: id) }
            }
            state.withLock { _ = $0.armed.removeValue(forKey: id) }
        }
    }
    /// Releases every armed timer of duration `d` (waits for one to be armed; the arming is a task hop, not a clock).
    @MainActor func fire(_ d: Duration) async {
        #expect(await eventually { armed.contains(d) }, "no \(d) timer was armed")
        state.withLock { s in for (_, e) in s.armed where e.d == d { e.go.yield() } }
    }
}

struct NullProbe: EndpointRouteProbing {
    func nonPrimaryInterface(for endpoint: ImportEndpoint) async -> String? { nil }
}

/// An `AppEnvironment` over the fakes.
@MainActor struct Harness {
    let dir: TestDir
    let managers: FakeVPNManager
    let service = FakeTunnelService()
    let ext = FakeExtension()
    let hooks = InertSystemHooks()
    let keychain: InMemoryKeychain
    let env: AppEnvironment

    init(goSource: (@Sendable () -> (any GoAppDataSource)?)? = nil, legacyKeychain: (any LegacyKeychainReading)? = nil,
         legacySystem: (any LegacySystemReading)? = nil, legacyHelperRunner: (any PrivilegedScriptRunning)? = nil, makeWiFi: (@MainActor () -> any WiFiLocating)? = nil,
         network: FixtureNetworkWatcher? = nil, settleClock: SettleClock? = nil,
         dir: TestDir? = nil, managers: FakeVPNManager? = nil, keychain: InMemoryKeychain? = nil,
         settingsWritableBeforeLoad: Bool = true, agentHome: String? = nil) {
        self.dir = dir ?? TestDir()
        self.managers = managers ?? FakeVPNManager()
        self.keychain = keychain ?? InMemoryKeychain()
        var b = AppEnvironment.Backends(
            mode: .preview, dataDirectory: self.dir.data, keychain: self.keychain, managers: self.managers, service: service,
            extensionStore: ext, systemExtensions: nil, hooks: hooks, goSource: goSource ?? { nil }, probe: NullProbe(),
            persistFiles: true)
        b.legacyKeychain = legacyKeychain
        b.settingsWritableBeforeLoad = settingsWritableBeforeLoad
        b.makeUpdater = { PreviewUpdater(coordinator: $0) }
        if let legacySystem { b.legacySystem = legacySystem }
        if let legacyHelperRunner { b.legacyHelperRunner = legacyHelperRunner }
        b.legacyAgentHome = agentHome
        if let makeWiFi { b.makeWiFi = makeWiFi }
        if let network { b.makeNetworkWatcher = { network } }
        if let settleClock { b.settleClock = settleClock }
        env = AppEnvironment(backends: b)
        env.profiles.settleAfterSave = .zero        // prepareForStart's NE settle (E2E-1) is real time
    }

    static let wgConf = PreviewSeed.workConf
    static let splitConf = PreviewSeed.nasConf

    /// Creates a profile through the real import pipeline and store.
    @discardableResult
    func add(_ name: String, _ text: String, killSwitch: Bool? = nil) async throws -> Profile {
        let a = await ImportCoordinator.analyse(fileName: name, bytes: Array(text.utf8), service: service, probe: NullProbe())
        let d = try #require(env.importer.draft(a, name: a.displayName, killSwitch: killSwitch ?? a.summary.isFullTunnel, allowLAN: false))
        return try await env.profiles.create(d)
    }
}


/// Suspends until `condition` holds, woken by the fake manager's changes and by `@Observable` changes of whatever the
/// condition reads (the stores): no wall-clock deadline to starve under load (a hang is the test's own time limit: every
/// suite that uses it has `.timeLimit(.minutes(1))`). One waiter at a time: `managers.onChange` has a single slot.
@MainActor func until(_ managers: FakeVPNManager, _ condition: @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let wake = Mutex<CheckedContinuation<Void, Never>?>(c)
            @Sendable func fire() { wake.withLock { let k = $0; $0 = nil; return k }?.resume() }
            managers.onChange = { fire() }
            withObservationTracking { _ = condition() } onChange: { fire() }
        }
        managers.onChange = nil
    }
}

/// Polls a main-actor condition (≤ 10 s, generous for a loaded machine; passing returns at once) instead of a fixed sleep
/// (review: sleep-based tests are flaky).
@MainActor func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A resume agent that checks the world at the moment it is called (ordering tests, review: "assert something real").
@MainActor final class ProbeResumeAgent: ResumeAgentControlling {
    var status: ResumeAgentStatus = .notRegistered
    var registerResult: ResumeAgentStatus = .enabled
    private(set) var calls: [String] = []
    /// Evaluated at each call; its result is recorded with the call ("register:<probe>").
    var probe: @MainActor () -> String = { "" }

    func register() -> ResumeAgentStatus {
        calls.append("register:" + probe())
        status = registerResult
        return status
    }

    func unregister() async {
        calls.append("unregister:" + probe())
        status = .notRegistered
    }
}
