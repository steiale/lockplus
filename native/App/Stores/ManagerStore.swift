import Foundation
import LPModel
import NetworkExtension
import os

/// What a saved manager tells the app (Sendable copy).
struct ManagerSnapshot: Sendable, Equatable {
    var profileID: UUID
    var stored: ProviderConfigurationValues.Stored?
    var flags: ProtocolFlags?
    var onDemandEnabled: Bool
    var status: TunnelStatus
}

/// One of our bundle's configurations that no profile can address (E2E-4): no or unreadable `profileID`, or the older
/// duplicate of one (review M3). `key` names it only until the next load. The app never removes one itself: the orphan
/// sweep (`ProfilesStore.load`) removes this user's, at idle only; another user's (U3: visible and removable without a
/// prompt) is never touched. Its live status counts as busy like any manager's.
struct StraySnapshot: Sendable, Equatable {
    var key: UUID
    var ownerUID: uid_t?
    var status: TunnelStatus
}

/// The NE seam (DESIGN §3.4 `ManagerStore`). The only owner of NETunnelProviderManager objects; `NEManagerStore`
/// is the real one, tests and preview mode use fakes. Status callbacks are already filtered to the CURRENT
/// connection object of each manager (S5: every load mints new connection objects, and a notification with
/// `object: nil` arrives once per live object).
@MainActor protocol VPNManaging: AnyObject {
    /// Must run once before the first save after launch (§3.4); `NEVPNConfigurationChange` reloads.
    func loadAll() async throws(LPError)
    var managers: [ManagerSnapshot] { get }
    /// Configurations of our provider that no profile addresses (E2E-4); never removed by `loadAll`.
    var strays: [StraySnapshot] { get }
    /// Removes the stray `key` named by the last load (a no-op if a reload renamed it). The caller defers it to idle.
    func removeStray(_ key: UUID) async throws(LPError)
    func save(_ cfg: ManagerConfiguration) async throws(LPError)
    func remove(_ id: UUID) async throws(LPError)
    func setOnDemandEnabled(_ on: Bool, for id: UUID) async throws(LPError)
    func status(_ id: UUID) -> TunnelStatus
    /// `startVPNTunnel(options:)`; the options carry `lp.manual = 1` (StartOptionsBuilder), except the app's restart
    /// after a tunnel-process crash (PF 52), which is an on-demand start (`StartOptionsBuilder.crashRestart`).
    func start(_ id: UUID, options: [String: NSObject]) throws(LPError)
    func stop(_ id: UUID)
    /// The completion-handler form only (§5.5): the async form throws the last error and returns Void.
    func fetchLastDisconnectError(_ id: UUID) async -> NSError?
    var onStatusChange: ((UUID, TunnelStatus) -> Void)? { get set }
    var onConfigurationChange: (() -> Void)? { get set }
    /// E2E-3 (200003): nesessionmanager handles a configuration change asynchronously, and one that lands while a
    /// kill-switch start is pending is the failure mode. Returns once at least `settle` has passed since the last
    /// configuration mutation, whoever made it (a save, a removal, an on-demand change, the system's own rewrite).
    /// Review R8: bounded by `cap` in total; false = the configuration never settled (a steady stream of changes), and
    /// the caller must not start beside it (fail closed).
    func waitUntilSettled(_ settle: Duration, cap: Duration) async -> Bool
}

extension VPNManaging {
    var strays: [StraySnapshot] { [] }
    func removeStray(_ key: UUID) async throws(LPError) {}
    func waitUntilSettled(_ settle: Duration, cap: Duration) async -> Bool { true }
    @discardableResult
    func waitUntilSettled(_ settle: Duration) async -> Bool { await waitUntilSettled(settle, cap: .seconds(5)) }
}

/// Time for `SerializedVPNManager`'s settle window; tests substitute a clock that never really sleeps.
struct SettleClock: Sendable {
    /// Monotonic time since an arbitrary origin.
    var now: @Sendable () -> Duration
    var sleep: @Sendable (Duration) async -> Void

    static let live: SettleClock = {
        let clock = ContinuousClock(), origin = clock.now
        return SettleClock(now: { origin.duration(to: clock.now) }, sleep: { try? await Task.sleep(for: $0) })
    }()
}

/// Maps `NEVPNStatusDidChange` objects to profiles, keeping only each manager's current connection object (S5).
struct ConnectionStatusFilter {
    private var current: [ObjectIdentifier: UUID] = [:]

    mutating func update(_ pairs: [(connection: AnyObject, profileID: UUID)]) {
        current = Dictionary(pairs.map { (ObjectIdentifier($0.connection), $0.profileID) }, uniquingKeysWith: { a, _ in a })
    }

    /// nil for a stale connection object (an earlier load's) or a foreign one.
    func profile(for object: ObjectIdentifier?) -> UUID? {
        guard let object else { return nil }
        return current[object]
    }
}

/// Sorts our provider's configurations into the addressable (one per profile ID) and the strays (E2E-4). Pure, so
/// the classification is tested without NE. A stray is never removed by the classification; the orphan sweep removes
/// only this user's, at idle.
enum ManagerClassifier {
    struct Candidate<M> {
        var manager: M
        /// `providerConfiguration["profileID"]` as stored (a string, if present).
        var profileID: String?
        /// `ProviderConfigurationValues.ownerUID`: readable even when `stored` isn't.
        var owner: uid_t?
        /// `stored?.metaRev`; nil when the dictionary isn't ours to parse (counts as the oldest).
        var metaRev: UInt64?
    }

    /// - No (or unparsable) profile ID: a stray (review M3).
    /// - A duplicate profile ID: when both are wholly this user's (owner readable and `me`), the newest metadata
    ///   revision is addressable and the older is a stray, a tie keeps the first. Otherwise (another user's, or one
    ///   whose owner can't be read) the later one is a stray too (E2E-4 review L2): never silently dropped, so its
    ///   live status counts as busy; removal stays gated by the owner (`ProfilesStore.load`).
    static func classify<M>(_ candidates: [Candidate<M>], me: uid_t) -> (addressable: [UUID: M], strays: [M]) {
        var map: [UUID: Candidate<M>] = [:]
        var strays: [M] = []
        for c in candidates {
            guard let ids = c.profileID, let id = UUID(uuidString: ids) else { strays.append(c.manager); continue }
            guard let other = map[id] else { map[id] = c; continue }
            if c.owner == me, other.owner == me, (c.metaRev ?? 0) > (other.metaRev ?? 0) {
                strays.append(other.manager)
                map[id] = c
            } else {
                strays.append(c.manager)
            }
        }
        return (map.mapValues(\.manager), strays)
    }
}

@MainActor final class NEManagerStore: VPNManaging {
    private var byID: [UUID: NETunnelProviderManager] = [:]
    private var strayByKey: [UUID: NETunnelProviderManager] = [:]
    private var filter = ConnectionStatusFilter()
    private var statusObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    private let providerBundleIdentifier: String
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "managers")

    var onStatusChange: ((UUID, TunnelStatus) -> Void)?
    var onConfigurationChange: (() -> Void)?

    init(providerBundleIdentifier: String) {
        self.providerBundleIdentifier = providerBundleIdentifier
        // queue: .main, Sendable values extracted, then assumeIsolated (ref/swift-concurrency SC16).
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { @Sendable [weak self] note in
            let oid = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {       // SAFETY: queue .main
                self?.statusNotification(oid)
            }
        }
        configObserver = NotificationCenter.default.addObserver(forName: .NEVPNConfigurationChange, object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {       // SAFETY: queue .main
                // The reload itself is serialized by SerializedVPNManager (review H3).
                self?.onConfigurationChange?()
            }
        }
    }

    isolated deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    private func statusNotification(_ oid: ObjectIdentifier?) {
        guard let id = filter.profile(for: oid), let m = byID[id] else { return }
        onStatusChange?(id, TunnelStatus(m.connection.status))
    }

    func loadAll() async throws(LPError) {
        let list: [NETunnelProviderManager]
        do {
            list = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            throw Self.map(error, "loadAllFromPreferences")
        }
        let candidates: [ManagerClassifier.Candidate<NETunnelProviderManager>] = list.compactMap { m in
            guard let p = m.protocolConfiguration as? NETunnelProviderProtocol, p.providerBundleIdentifier == providerBundleIdentifier else { return nil }
            return .init(manager: m, profileID: p.providerConfiguration?["profileID"] as? String,
                         owner: ProviderConfigurationValues.ownerUID(p.providerConfiguration),
                         metaRev: ProviderConfigurationValues.stored(p.providerConfiguration)?.metaRev)
        }
        let (map, strays) = ManagerClassifier.classify(candidates, me: getuid())
        // E2E-4: a load never removes anything. It removed every unaddressable configuration of our provider, any
        // user's, at once (8–12 ms after another user's LockPlus created one) and inside our own or another user's
        // pending kill-switch start (U13: a removal breaks it like a save). The orphan sweep decides, at idle.
        strayByKey = Dictionary(uniqueKeysWithValues: strays.map { (UUID(), $0) })
        byID = map
        filter.update(map.map { ($0.value.connection, $0.key) })
    }

    var managers: [ManagerSnapshot] {
        byID.map { id, m in
            let p = m.protocolConfiguration as? NETunnelProviderProtocol
            return ManagerSnapshot(
                profileID: id, stored: ProviderConfigurationValues.stored(p?.providerConfiguration),
                flags: p.map { Self.flags($0) }, onDemandEnabled: m.isOnDemandEnabled, status: TunnelStatus(m.connection.status))
        }
    }

    var strays: [StraySnapshot] {
        strayByKey.map { key, m in
            let p = m.protocolConfiguration as? NETunnelProviderProtocol
            return StraySnapshot(key: key, ownerUID: ProviderConfigurationValues.ownerUID(p?.providerConfiguration),
                                 status: TunnelStatus(m.connection.status))
        }
    }

    func removeStray(_ key: UUID) async throws(LPError) {
        guard let m = strayByKey[key] else { return }
        do { try await m.removeFromPreferences() } catch { throw Self.map(error, "removeFromPreferences (stray)") }
        strayByKey[key] = nil
    }

    private static func flags(_ p: NETunnelProviderProtocol) -> ProtocolFlags {
        var f = ProtocolFlags(policy: NetworkPolicy(killSwitch: false), isFullTunnel: false)
        f.includeAllNetworks = p.includeAllNetworks
        f.enforceRoutes = p.enforceRoutes
        f.excludeLocalNetworks = p.excludeLocalNetworks
        f.excludeAPNs = p.excludeAPNs
        f.excludeCellularServices = p.excludeCellularServices
        f.excludeDeviceCommunication = p.excludeDeviceCommunication
        return f
    }

    func save(_ cfg: ManagerConfiguration) async throws(LPError) {
        let m = byID[cfg.profileID] ?? NETunnelProviderManager()
        let p = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        p.providerBundleIdentifier = providerBundleIdentifier
        p.serverAddress = cfg.serverAddress.isEmpty ? "LockPlus" : cfg.serverAddress
        p.providerConfiguration = cfg.provider.dictionary
        p.username = nil
        p.passwordReference = nil          // the extension can't read it (L-CRED-1)
        p.disconnectOnSleep = false
        p.includeAllNetworks = cfg.flags.includeAllNetworks
        p.enforceRoutes = cfg.flags.enforceRoutes
        p.excludeLocalNetworks = cfg.flags.excludeLocalNetworks
        p.excludeAPNs = cfg.flags.excludeAPNs
        p.excludeCellularServices = cfg.flags.excludeCellularServices
        p.excludeDeviceCommunication = cfg.flags.excludeDeviceCommunication
        m.protocolConfiguration = p
        m.localizedDescription = cfg.name
        m.isEnabled = true
        if let od = cfg.onDemand {
            m.onDemandRules = od.rules.map(Self.rule)
            m.isOnDemandEnabled = od.enabled
        } else {
            m.onDemandRules = []
            m.isOnDemandEnabled = false
        }
        do {
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
        } catch {
            throw Self.map(error, "saveToPreferences")
        }
        // E2E-1: verify what NE kept. A discrepancy here (or the asynchronous rewrite ProfilesStore.load catches as
        // drift) is a system behaviour we must see every time.
        if let back = m.protocolConfiguration as? NETunnelProviderProtocol, Self.flags(back) != cfg.flags {
            log.fault("saved protocol flags not kept for \(cfg.profileID.uuidString.prefix(8), privacy: .public)")
        }
        byID[cfg.profileID] = m
        filter.update(byID.map { ($0.value.connection, $0.key) })
    }

    private static func rule(_ s: OnDemandRuleSpec) -> NEOnDemandRule {
        let r: NEOnDemandRule = switch s.action {
        case .connect: NEOnDemandRuleConnect()
        case .disconnect: NEOnDemandRuleDisconnect()
        case .ignore: NEOnDemandRuleIgnore()
        }
        r.interfaceTypeMatch = switch s.interface {
        case .any: .any
        case .wiFi: .wiFi
        case .ethernet: .ethernet
        }
        r.ssidMatch = s.ssids
        r.probeURL = s.probeURL
        return r
    }

    func remove(_ id: UUID) async throws(LPError) {
        guard let m = byID[id] else { return }
        do { try await m.removeFromPreferences() } catch { throw Self.map(error, "removeFromPreferences") }
        byID[id] = nil
        filter.update(byID.map { ($0.value.connection, $0.key) })
    }

    func setOnDemandEnabled(_ on: Bool, for id: UUID) async throws(LPError) {
        guard let m = byID[id], m.isOnDemandEnabled != on else { return }
        m.isOnDemandEnabled = on
        do { try await m.saveToPreferences() } catch { throw Self.map(error, "saveToPreferences") }
    }

    func status(_ id: UUID) -> TunnelStatus { byID[id].map { TunnelStatus($0.connection.status) } ?? .invalid }

    func start(_ id: UUID, options: [String: NSObject]) throws(LPError) {
        guard let m = byID[id] else { throw LPError(.profileNotProvisioned, detail: "no VPN configuration") }
        do { try m.connection.startVPNTunnel(options: options) } catch { throw Self.map(error, "startVPNTunnel") }
    }

    func stop(_ id: UUID) { byID[id]?.connection.stopVPNTunnel() }

    func fetchLastDisconnectError(_ id: UUID) async -> NSError? {
        guard let c = byID[id]?.connection else { return nil }
        return await withCheckedContinuation { (k: CheckedContinuation<NSError?, Never>) in
            c.fetchLastDisconnectError { @Sendable e in k.resume(returning: e.map { $0 as NSError }) }
        }
    }

    /// `NEVPNErrorDomain` 5 (configurationReadWriteFailed) is what a denied "add VPN configurations" prompt yields.
    /// A save that failed because the user didn't allow the VPN configuration (NEVPNError.configurationReadWriteFailed).
    nonisolated static func isConfigurationDenied(_ e: LPError) -> Bool { e.detail?.contains("NEVPNErrorDomain 5") == true }

    static func map(_ error: any Error, _ what: String) -> LPError {
        let ns = error as NSError
        // SerializedVPNManager retries once on a stale configuration (review H3).
        if ns.domain == NEVPNErrorDomain, ns.code == NEVPNError.Code.configurationStale.rawValue {
            return LPError(.extensionUnavailable, detail: "\(what): configurationStale")
        }
        return LPError(.extensionUnavailable, detail: "\(what): \(ns.domain) \(ns.code)")
    }
}

/// A FIFO async lock on the main actor: one NE manager operation at a time (review H3).
@MainActor final class AsyncSerialLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// The `VPNManaging` every store uses (review H3). Wraps the NE store (or a fake) and:
/// - serializes every mutation and reload (`loadAll`, `save`, `remove`, `setOnDemandEnabled`), so a reload can't
///   clobber an edit in flight and two saves never race into `configurationStale`;
/// - retries a save or on-demand change ONCE after a stale-configuration error, with a reload first;
/// - replays status after every reload: a reload mints new connection objects, and a transition that happened in
///   between would otherwise be lost (S5), so every status that differs from the last one reported is re-emitted;
/// - refuses saves until one `loadAll` has succeeded (review M3: a save after a failed first load can duplicate);
/// - publishes the manager snapshot as observable state.
@MainActor @Observable final class SerializedVPNManager: VPNManaging {
    @ObservationIgnored let inner: any VPNManaging
    private(set) var managers: [ManagerSnapshot] = []
    private(set) var strays: [StraySnapshot] = []
    @ObservationIgnored var onStatusChange: ((UUID, TunnelStatus) -> Void)?
    @ObservationIgnored var onConfigurationChange: (() -> Void)?
    @ObservationIgnored private let lock = AsyncSerialLock()
    @ObservationIgnored private var reported: [UUID: TunnelStatus] = [:]
    @ObservationIgnored private(set) var loadedOnce = false
    /// When the last configuration mutation finished (or the system announced a change): `waitUntilSettled`.
    @ObservationIgnored private var lastMutation: Duration?
    @ObservationIgnored private let settleClock: SettleClock
    /// Review 385b6ea L-A: ids whose live status was last seen on a manager that the latest load did not return. One
    /// load missing a manager is not proof it is gone (a partial list would end a live kill-switch session's bookkeeping
    /// and let the restore save beside it); the end is reported when the NEXT load agrees. `remove` is certain: immediate.
    @ObservationIgnored private var missingOnce: Set<UUID> = []
    /// After a first miss a confirming reload follows (nobody else may reload soon: one configuration change is one load).
    @ObservationIgnored var confirmDelay: Duration = .seconds(2)
    @ObservationIgnored var confirmSleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored private var confirmTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "managers")

    init(inner: any VPNManaging, settleClock: SettleClock = .live) {
        self.inner = inner
        self.settleClock = settleClock
        inner.onStatusChange = { [weak self] id, s in self?.forward(id, s) }
        inner.onConfigurationChange = { [weak self] in
            guard let self else { return }
            self.lastMutation = self.settleClock.now()       // our own save's echo or nehelper's rewrite: either one settles
            Task { @MainActor in
                try? await self.loadAll()
                self.onConfigurationChange?()
            }
        }
    }

    /// NEVPNError.configurationStale, as `NEManagerStore.map` reports it.
    static func isStale(_ e: LPError) -> Bool { e.detail?.contains("configurationStale") == true }

    private func forward(_ id: UUID, _ s: TunnelStatus) {
        reported[id] = s
        refreshSnapshot()
        onStatusChange?(id, s)
    }

    private func refreshSnapshot() {
        let now = inner.managers.sorted { $0.profileID.uuidString < $1.profileID.uuidString }
        if now != managers { managers = now }
        let s = inner.strays.sorted { $0.key.uuidString < $1.key.uuidString }
        if s != strays { strays = s }
    }

    private func locked<T>(_ op: () async throws(LPError) -> T) async throws(LPError) -> T {
        await lock.acquire()
        defer { lock.release() }
        return try await op()
    }

    func loadAll() async throws(LPError) {
        try await locked { () throws(LPError) in try await loadUnlocked() }
    }

    private func loadUnlocked() async throws(LPError) {
        try await inner.loadAll()
        loadedOnce = true
        refreshSnapshot()
        for m in inner.managers where reported[m.profileID] != m.status {
            let had = reported[m.profileID] != nil
            reported[m.profileID] = m.status
            if had { onStatusChange?(m.profileID, m.status) }       // replay a transition the reload swallowed
        }
        let known = Set(inner.managers.map(\.profileID))
        missingOnce.formIntersection(reported.keys)
        missingOnce.subtract(known)                              // it came back: not gone
        var confirmed: [UUID: TunnelStatus] = [:]
        var firstMiss = false
        for (id, last) in reported where !known.contains(id) {
            if missingOnce.remove(id) != nil { confirmed[id] = last; reported[id] = nil }
            else if last.isLive { missingOnce.insert(id); firstMiss = true }
            else { reported[id] = nil }                          // nothing live to end
        }
        reportEnd(of: confirmed)
        if firstMiss { scheduleConfirmingReload() }
    }

    /// Review 5c3a899/f18c0d6 L-2: a confirming reload that THROWS leaves `missingOnce` as it was, and after an external
    /// removal no further `NEVPNConfigurationChange` may come: it is rescheduled (at most `maxConfirmRetries` times, one
    /// `confirmDelay` apart) and logged, so a gone manager can't stay Connected and busy indefinitely.
    static let maxConfirmRetries = 3

    private func scheduleConfirmingReload(retry: Int = 0) {
        confirmTask?.cancel()
        let sleep = confirmSleep, delay = confirmDelay
        confirmTask = Task { @MainActor [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self, !self.missingOnce.isEmpty else { return }
            do throws(LPError) { try await self.loadAll() } catch {
                self.log.error("confirming reload failed (\(error.code.rawValue, privacy: .public)); attempt \(retry + 1) of \(Self.maxConfirmRetries)")
                if retry < Self.maxConfirmRetries - 1, !self.missingOnce.isEmpty { self.scheduleConfirmingReload(retry: retry + 1) }
            }
        }
    }

    /// Review e321e10 (HIGH): a configuration removed while its session was live (ours, another user's, System
    /// Settings) never reports `.disconnected` (NE drops the notification of a manager it no longer has). Its end is
    /// reported as `.invalid`, so the store's last status of it can't stay live (busy) until relaunch.
    private func reportEnd(of vanished: [UUID: TunnelStatus]) {
        for (id, last) in vanished where last.isLive { onStatusChange?(id, .invalid) }
    }

    func waitUntilSettled(_ settle: Duration, cap: Duration) async -> Bool {
        let began = settleClock.now()
        while true {
            await lock.acquire()                              // a mutation in flight finishes first
            lock.release()
            guard let last = lastMutation else { return true }
            let remaining = settle - (settleClock.now() - last)
            guard remaining > .zero else { return true }
            // Review R8: every `NEVPNConfigurationChange` (our echoes, nehelper's rewrites, other users' configurations
            // of our bundle id) restarts the settle; a steady stream must not hold a start forever.
            let left = cap - (settleClock.now() - began)
            guard left > .zero else { return false }
            await settleClock.sleep(min(remaining, left))
        }
    }

    func save(_ cfg: ManagerConfiguration) async throws(LPError) {
        try await locked { () throws(LPError) in
            defer { lastMutation = settleClock.now() }
            if !loadedOnce { try await loadUnlocked() }
            do throws(LPError) { try await inner.save(cfg) } catch where Self.isStale(error) {
                try await loadUnlocked()
                try await inner.save(cfg)
            }
            refreshSnapshot()
        }
    }

    func remove(_ id: UUID) async throws(LPError) {
        try await locked { () throws(LPError) in
            defer { lastMutation = settleClock.now() }
            try await inner.remove(id)
            let last = reported.removeValue(forKey: id)
            missingOnce.remove(id)
            refreshSnapshot()
            if let last { reportEnd(of: [id: last]) }
        }
    }

    func removeStray(_ key: UUID) async throws(LPError) {
        try await locked { () throws(LPError) in
            defer { lastMutation = settleClock.now() }
            try await inner.removeStray(key)
            refreshSnapshot()
        }
    }

    func setOnDemandEnabled(_ on: Bool, for id: UUID) async throws(LPError) {
        try await locked { () throws(LPError) in
            defer { lastMutation = settleClock.now() }
            do throws(LPError) { try await inner.setOnDemandEnabled(on, for: id) } catch where Self.isStale(error) {
                try await loadUnlocked()
                try await inner.setOnDemandEnabled(on, for: id)
            }
            refreshSnapshot()
        }
    }

    func status(_ id: UUID) -> TunnelStatus { inner.status(id) }
    func start(_ id: UUID, options: [String: NSObject]) throws(LPError) { try inner.start(id, options: options) }
    func stop(_ id: UUID) { inner.stop(id) }
    func fetchLastDisconnectError(_ id: UUID) async -> NSError? { await inner.fetchLastDisconnectError(id) }
}
