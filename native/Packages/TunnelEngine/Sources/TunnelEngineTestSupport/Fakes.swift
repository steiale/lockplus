import Foundation
import LPModel
import LPWire
import Synchronization
import TunnelEngine

// Fakes for the TunnelEngine unit tests (DESIGN §15.1). No NE, no keychain, no engines.

/// Polls `cond` (yielding, then sleeping 1 ms of real time) until it holds or `timeout` passes.
@discardableResult
public func waitUntil(timeout: Duration = .seconds(3), _ cond: @Sendable () async -> Bool) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if await cond() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await cond()
}

// MARK: FakeHost

public final class FakeHost: ProviderHost, @unchecked Sendable {
    public struct S {
        public var applied: [TunnelSettingsSpec] = []
        public var reasserting: [Bool] = []
        public var cancelled: [LPTunnelError] = []
        public var cancelledOwners: [ProviderLease?] = []
        public var applyError: LPTunnelError?
        public var applyGate: CheckedContinuation<Void, Never>?
        public var holdApply = false
        public var fd: Int32? = 7
        /// What `liveProtection(owner:)` answers (the provider's live flags); nil: unknown.
        public var protection: ProviderProtection?
    }
    public let s = Mutex(S())
    public let flow = FakeFlow()
    public var packetFlow: any PacketFlowSource { flow }
    public init() {}

    public func apply(_ settings: TunnelSettingsSpec) async throws(LPTunnelError) {
        let hold = s.withLock { $0.holdApply }
        if hold { await withCheckedContinuation { k in s.withLock { $0.applyGate = k } } }
        let e = s.withLock { st -> LPTunnelError? in st.applied.append(settings); return st.applyError }
        if let e { throw e }
    }
    public func releaseApply() { s.withLock { st in st.holdApply = false; st.applyGate?.resume(); st.applyGate = nil } }
    public func setReasserting(_ on: Bool) { s.withLock { $0.reasserting.append(on) } }
    public func cancel(with error: LPTunnelError, owner: ProviderLease?) {
        s.withLock { $0.cancelled.append(error); $0.cancelledOwners.append(owner) }
    }
    public func tunnelFileDescriptor(matching address: String?) -> Int32? { s.withLock { $0.fd } }
    public func liveProtection(owner: ProviderLease?) -> ProviderProtection? { s.withLock { $0.protection } }
    public func pin() -> AnyObject? { nil }
    /// The provider's live `includeAllNetworks` (`enforceRoutes` off); nil: unknown.
    public func setIncludeAllNetworks(_ v: Bool?) {
        s.withLock { $0.protection = v.map { ProviderProtection(includeAllNetworks: $0, enforceRoutes: false) } }
    }
    public func setProtection(_ p: ProviderProtection?) { s.withLock { $0.protection = p } }

    public var appliedCount: Int { s.withLock { $0.applied.count } }
    public var lastReasserting: Bool? { s.withLock { $0.reasserting.last } }
    public var cancelledCodes: [LPErrorCode] { s.withLock { $0.cancelled.map(\.code) } }
    public var cancelledOwners: [ProviderLease?] { s.withLock { $0.cancelledOwners } }
}

// MARK: FakeFlow

public final class FakeFlow: PacketFlowSource, @unchecked Sendable {
    public struct S { public var handlers: [@Sendable ([Data], [NSNumber]) -> Void] = []; public var written: [(Data, Int32)] = []; public var reads = 0 }
    public let s = Mutex(S())
    public init() {}
    public func readPackets(_ handler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        s.withLock { $0.handlers.append(handler); $0.reads += 1 }
    }
    public func writePackets(_ packets: [Data], protocols: [NSNumber]) -> Bool {
        s.withLock { st in for (p, n) in zip(packets, protocols) { st.written.append((p, n.int32Value)) } }
        return true
    }
    /// Delivers packets to the oldest outstanding read (NE semantics: one completion per read call).
    @discardableResult public func deliver(_ packets: [Data], _ af: Int32) -> Bool {
        guard let h = s.withLock({ st -> (@Sendable ([Data], [NSNumber]) -> Void)? in st.handlers.isEmpty ? nil : st.handlers.removeFirst() }) else { return false }
        h(packets, packets.map { _ in NSNumber(value: af) })
        return true
    }
    public var outstanding: Int { s.withLock { $0.handlers.count } }
    public var written: [(Data, Int32)] { s.withLock { $0.written } }
}

// MARK: FakeAdapter

public final class FakeAdapter: TunnelAdapter, @unchecked Sendable {
    public let kind: VPNProtocolKind
    public struct S {
        public var req: AdapterStart?
        public var events: AdapterEventSink?
        public var epoch: UInt64 = 0
        public var startK: CheckedContinuation<Result<Void, AdapterStartError>, Never>?
        public var startCalls = 0
        public var stops = 0
        public var reconnects: [ReconnectReason] = []
        public var sleeps = 0
        public var hangSleep = false
        public var sleepK: CheckedContinuation<Void, Never>?
        /// `stop()` waits for `releaseStop()` (a slow engine teardown).
        public var hangStop = false
        public var stopReleased = false
        public var stopK: CheckedContinuation<Void, Never>?
        public var wakes = 0
        public var provided: [AuthAnswerSecrets] = []
        public var liveness: Liveness = .healthy
        public var stats = AdapterStats()
        public var consumed: [(answer: AuthAnswerSecrets?, carriedUsername: SecretBytes?, carriedPassword: SecretBytes?, cookie: SecretBytes?)] = []
    }
    public let s = Mutex(S())
    public init(kind: VPNProtocolKind) { self.kind = kind }

    public func start(_ req: AdapterStart, events: AdapterEventSink, epoch: UInt64) async throws(AdapterStartError) {
        let r: Result<Void, AdapterStartError> = await withCheckedContinuation { k in
            s.withLock { st in st.req = req; st.events = events; st.epoch = epoch; st.startK = k; st.startCalls += 1 }
        }
        if case .failure(let e) = r { throw e }
    }
    public var started: Bool { s.withLock { $0.req != nil } }
    public var request: AdapterStart? { s.withLock { $0.req } }
    public var epoch: UInt64 { s.withLock { $0.epoch } }

    public func finishStart(_ r: Result<Void, AdapterStartError> = .success(())) {
        let k = s.withLock { st -> CheckedContinuation<Result<Void, AdapterStartError>, Never>? in defer { st.startK = nil }; return st.startK }
        k?.resume(returning: r)
    }
    /// What the OpenVPN adapter does at provide_creds: consume the bound stash once.
    @discardableResult public func consumeStash() -> Bool {
        guard let b = s.withLock({ $0.req?.stash })?.consume() else { return false }
        s.withLock { $0.consumed.append(b) }
        return true
    }
    public func emit(_ make: (UInt64) -> AdapterEvent) { let (ev, ep) = s.withLock { ($0.events, $0.epoch) }; ev?.yield(make(ep)) }
    public func emit(_ e: AdapterEvent) { s.withLock { $0.events }?.yield(e) }
    /// Posts `.networkSettings` and returns the ticket.
    public func requestSettings(_ plan: NetworkPlan) -> EstablishTicket {
        let t = EstablishTicket(); emit { .networkSettings(plan, t, epoch: $0) }; return t
    }

    public func stop() async {
        let (k, hang) = s.withLock { st -> (CheckedContinuation<Result<Void, AdapterStartError>, Never>?, Bool) in
            st.stops += 1; defer { st.startK = nil }; return (st.startK, st.hangStop)
        }
        k?.resume(returning: .failure(.failed(LPTunnelError(.startCancelled))))
        if hang {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let released = s.withLock { st -> Bool in if st.stopReleased { return true }; st.stopK = c; return false }
                if released { c.resume() }
            }
        }
    }
    public func releaseStop() {
        let k = s.withLock { st -> CheckedContinuation<Void, Never>? in st.stopReleased = true; defer { st.stopK = nil }; return st.stopK }
        k?.resume()
    }
    public func reconnect(reason: ReconnectReason) async { s.withLock { $0.reconnects.append(reason) } }
    public func sleep() async {
        let hang = s.withLock { st -> Bool in st.sleeps += 1; return st.hangSleep }
        if hang { await withCheckedContinuation { k in s.withLock { $0.sleepK = k } } }
    }
    public func releaseSleep() { s.withLock { st in st.sleepK?.resume(); st.sleepK = nil } }
    public func wake() async { s.withLock { $0.wakes += 1 } }
    public func provideAuth(_ answer: AuthAnswerSecrets) async throws(LPTunnelError) { s.withLock { $0.provided.append(answer) } }
    public func statistics() async -> AdapterStats { s.withLock { $0.stats } }
    public func liveness() async -> Liveness { s.withLock { $0.liveness } }

    public var stopCount: Int { s.withLock { $0.stops } }
    public var reconnectReasons: [ReconnectReason] { s.withLock { $0.reconnects } }
}

public final class FakeAdapterFactory: TunnelAdapterFactory, @unchecked Sendable {
    private let made = Mutex<[FakeAdapter]>([])
    public init() {}
    public func makeAdapter(kind: VPNProtocolKind) -> any TunnelAdapter {
        let a = FakeAdapter(kind: kind); made.withLock { $0.append(a) }; return a
    }
    public var adapters: [FakeAdapter] { made.withLock { $0 } }
    public var last: FakeAdapter? { made.withLock { $0.last } }
}

// MARK: secret store

/// In-memory `ExtensionSecretStore` with injectable failures (never a keychain). Namespaced by uid like the real stores.
public actor InMemorySecretStore: ExtensionSecretStore {
    public struct Item: Sendable { public var bytes: [UInt8]; public var owner: uid_t; public var revision: UInt64 }
    public var items: [String: Item] = [:]
    public var failure: LPError?
    public var gets = 0
    public var puts = 0
    public init() {}
    func key(_ k: SecretKind, _ id: UUID, _ uid: uid_t) -> String { "\(uid)/\(k.rawValue)/\(id.uuidString)" }
    /// A failure of one kind's `put` and `delete` only (round 6: a partial provision or removal).
    public var kindFailures: [SecretKind: LPError] = [:]
    public func setFailure(_ e: LPError?) { failure = e }
    public func setFailure(_ e: LPError?, for kind: SecretKind) { kindFailures[kind] = e }
    public func put(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t, revision: UInt64, _ bytes: SecretBytes) throws(LPError) {
        if let failure { throw failure }
        if let f = kindFailures[kind] { throw f }
        puts += 1
        items[key(kind, id, ownerUID)] = Item(bytes: bytes.withUnsafeBytes { Array($0) }, owner: ownerUID, revision: revision)
    }
    public func get(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) throws(LPError) -> SecretBytes? {
        gets += 1
        if let failure { throw failure }
        return items[key(kind, id, ownerUID)].map { SecretBytes(copying: $0.bytes) }
    }
    public func entry(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) throws(LPError) -> ProvisionIndexEntry? {
        if let failure { throw failure }
        return items[key(kind, id, ownerUID)].map { ProvisionIndexEntry(id: id, kind: kind, revision: $0.revision, ownerUID: $0.owner, digest: nil) }
    }
    public func delete(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t) throws(LPError) {
        if let f = kindFailures[kind] { throw f }
        items[key(kind, id, ownerUID)] = nil
    }
    public func deleteAll(ownerUID: uid_t) throws(LPError) { items = items.filter { $0.value.owner != ownerUID } }
    public func index(ownerUID: uid_t) throws(LPError) -> [ProvisionIndexEntry] {
        if let failure { throw failure }
        return items.compactMap { k, v in
            let p = k.split(separator: "/")
            guard v.owner == ownerUID, let kind = SecretKind(rawValue: String(p[1])), let id = UUID(uuidString: String(p[2])) else { return nil }
            return ProvisionIndexEntry(id: id, kind: kind, revision: v.revision, ownerUID: v.owner, digest: nil)
        }
    }
    public func bytes(_ kind: SecretKind, _ id: UUID, ownerUID: uid_t = 501) -> [UInt8]? { items[key(kind, id, ownerUID)]?.bytes }
}

/// Fake `SecItem` backend (S4 behaviour: enumeration may return items twice). Records every attribute it was given:
/// there are none besides service/account/label, which the L4 test asserts.
public final class FakeKeychainBackend: GenericPasswordBackend, @unchecked Sendable {
    public struct S { public var items: [String: Data] = [:]; public var duplicateEnumeration = true
        public var failStatus: OSStatus?; public var labels: Set<String> = [] }
    public let s = Mutex(S())
    public init() {}
    func k(_ svc: String, _ a: String) -> String { svc + "|" + a }
    public func copyData(service: String, account: String) -> (OSStatus, Data?) {
        s.withLock { st in
            if let f = st.failStatus { return (f, nil) }
            guard let d = st.items[k(service, account)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, d)
        }
    }
    public func update(service: String, account: String, data: Data) -> OSStatus {
        s.withLock { st in
            if let f = st.failStatus { return f }
            guard st.items[k(service, account)] != nil else { return errSecItemNotFound }
            st.items[k(service, account)] = data; return errSecSuccess
        }
    }
    public func add(service: String, account: String, data: Data, label: String) -> OSStatus {
        s.withLock { st in
            if let f = st.failStatus { return f }
            if st.items[k(service, account)] != nil { return errSecDuplicateItem }
            st.items[k(service, account)] = data; st.labels.insert(label); return errSecSuccess
        }
    }
    public func delete(service: String, account: String) -> OSStatus {
        s.withLock { st in st.items.removeValue(forKey: k(service, account)) == nil ? errSecItemNotFound : errSecSuccess }
    }
    public func enumerate(service: String) -> (OSStatus, [String]) {
        s.withLock { st in
            if let f = st.failStatus { return (f, []) }
            var out: [String] = []
            for key in st.items.keys.sorted() where key.hasPrefix(service + "|") {
                let acct = String(key.dropFirst(service.count + 1))
                out.append(acct)
                if st.duplicateEnumeration { out.append(acct) }
            }
            return out.isEmpty ? (errSecItemNotFound, []) : (errSecSuccess, out)
        }
    }
    /// Every (service, account) pair, i.e. everything a non-root user could list.
    public var addresses: [String] { s.withLock { Array($0.items.keys) } }
}

// MARK: misc

public final class FakeEventSink: TunnelEventSink, @unchecked Sendable {
    public struct S { public var prompts: [AuthPrompt] = []; public var ended: [(UUID, LPError)] = []; public var snapshots: [TunnelSnapshot] = []
        public var resolved: [UUID] = [] }
    public let s = Mutex(S())
    public init() {}
    public func authRequired(_ prompt: AuthPrompt, ownerUID: uid_t) { s.withLock { $0.prompts.append(prompt) } }
    public func sessionEnded(profileID: UUID, error: LPError, ownerUID: uid_t) { s.withLock { $0.ended.append((profileID, error)) } }
    public func snapshotChanged(_ snapshot: TunnelSnapshot, ownerUID: uid_t?) { s.withLock { $0.snapshots.append(snapshot) } }
    public func promptResolved(promptID: UUID, profileID: UUID, ownerUID: uid_t) { s.withLock { $0.resolved.append(promptID) } }
    public var prompts: [AuthPrompt] { s.withLock { $0.prompts } }
    public var endedCodes: [LPErrorCode] { s.withLock { $0.ended.map(\.1.code) } }
    public var resolved: [UUID] { s.withLock { $0.resolved } }
}

public final class FakePathSource: PathSource, @unchecked Sendable {
    private let c = Mutex<AsyncStream<PathSnapshot>.Continuation?>(nil)
    public init() {}
    public func paths() -> AsyncStream<PathSnapshot> {
        let (s, k) = AsyncStream.makeStream(of: PathSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        c.withLock { $0 = k }
        return s
    }
    public var subscribed: Bool { c.withLock { $0 != nil } }
    public func send(_ p: PathSnapshot) { c.withLock { $0 }?.yield(p) }
}

public struct FakeValidator: PayloadValidator {
    public var reject: Bool
    public init(reject: Bool = false) { self.reject = reject }
    public func validate(kind: VPNProtocolKind, payload: SecretBytes) throws(LPTunnelError) {
        if reject { throw LPTunnelError(.profileInvalid, detail: "fake") }
    }
}

public final class FakeInterfaceCheck: EndpointInterfaceCheck, Sendable {
    public let name: String?
    private let seen = Mutex<[[String]]>([])
    public init(_ name: String?) { self.name = name }
    public func nonPrimaryInterface(for endpointIPs: [String]) -> String? { seen.withLock { $0.append(endpointIPs) }; return name }
    /// The IP lists the controller checked, in order.
    public var checked: [[String]] { seen.withLock { $0 } }
}

public final class MutableWallClock: Sendable {
    private let t: Mutex<Date>
    public init(_ d: Date = Date(timeIntervalSince1970: 2_000_000_000)) { t = Mutex(d) }
    public var now: Date { t.withLock { $0 } }
    public func advance(_ s: TimeInterval) { t.withLock { $0 = $0.addingTimeInterval(s) } }
    public var function: @Sendable () -> Date { { [self] in self.now } }
}

extension SecretBytes {
    public var bytesForTest: [UInt8] { withUnsafeBytes { Array($0) } }
    public static func text(_ s: String) -> SecretBytes { SecretBytes(copying: Array(s.utf8)) }
}
