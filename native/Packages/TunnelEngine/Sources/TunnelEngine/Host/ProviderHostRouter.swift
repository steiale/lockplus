import Foundation
import LPModel
import Synchronization

/// Codex r3 2: the one lifecycle gate of the provider instances. `ProviderSeat` publishes every new `startTunnel`
/// through it, so the generation becomes visible, the instance's older starts are retired and its watermark is raised
/// as one step that a cancel or a bind of an older generation can't interleave with.
public protocol ProviderLifecycleGate: Sendable {
    /// Runs `start` (which makes the new lease current) and retires the instance's older generations, atomically.
    func publish(_ token: ProviderToken, _ start: () -> ProviderLease) -> ProviderLease
}

/// The process-scope `ProviderHost` the controller talks to (DESIGN §5.1, §7.1): it routes every call to the right
/// provider instance's host. The extension's `ProcessProviderHost.shared` is a `ProviderHostRouter<RealProviderHost>`;
/// the tests drive the same type with fakes (Codex review 1: the real dispatch is tested, not a recording fake).
/// - `apply`, `setReasserting`, `tunnelFileDescriptor` and the packet flow go to the CURRENT binding (the session's
///   provider: a refused start is never bound).
/// - `cancel(with:owner:)` goes to `owner`'s own start only (review M1, re-check L2), and never below the instance's
///   generation watermark (Codex r3 2): nothing when that binding is gone, retired or rebound by a newer start.
/// - `bind` is refused below the watermark (an older start that passed the controller's check before a newer one was
///   published can't reinstall itself). It takes `lifecycle` too (round 4, Codex 3): a bind can't slip between a
///   publication's `providers.started` and its watermark.
/// - `unbind(id:lease:)` forgets only that start's binding; `release` (deinit) forgets every binding of the instance
///   and its watermark (round 4, Codex 5: the bookkeeping is bounded by the live instances).
/// Locks: `lifecycle` (outer) serialises publication with binding, cancel validation AND dispatch; `state` (inner, short)
/// guards the bindings, the watermarks and the packet-flow swap. No host call runs under `state`. A cancel's dispatch
/// keeps the native provider pinned until both locks are released (Codex r3 3, final review L2): a `deinit` it
/// triggers, which calls `release` (taking `state`), runs after the unlock, never inside it.
// SAFETY: @unchecked Sendable: all mutable state is behind the two Mutexes; `Host` is Sendable.
public final class ProviderHostRouter<Host: ProviderHost>: ProviderHost, ProviderLifecycleGate, @unchecked Sendable {
    private struct State {
        var bindings = ProviderBindings<Host>()
        var watermark: [ProviderToken: UInt64] = [:]
        func isBelowWatermark(_ l: ProviderLease) -> Bool { l.generation < (watermark[l.token] ?? 0) }
    }
    private let lifecycle = Mutex(())
    private let state = Mutex(State())
    #if DEBUG
    /// Test seam (final review N1): cancels dispatched or dropped so far. Not compiled into release builds (r3 N3).
    private let cancelRequests = Mutex(0)
    var cancelRequestCount: Int { cancelRequests.withLock { $0 } }
    /// Test seam (round 4): instances with a watermark or a dispatch entry (bounded by the live instances).
    var trackedInstanceCount: Int { state.withLock { Set($0.watermark.keys).union($0.bindings.trackedTokens).count } }
    #endif
    private let flow = ForwardingPacketFlow()
    public var packetFlow: any PacketFlowSource { flow }

    public init() {}

    public func publish(_ token: ProviderToken, _ start: () -> ProviderLease) -> ProviderLease {
        lifecycle.withLock { _ in
            let l = start()
            state.withLock { s in
                s.watermark[token] = max(s.watermark[token] ?? 0, l.generation)
                s.bindings.retire(olderThan: l)
            }
            return l
        }
    }

    /// False: `lease` is below its instance's watermark (a newer start was published): not bound. Under `lifecycle`
    /// (round 4, Codex 3): a publication in progress finishes (its watermark raised) before this decides.
    @discardableResult
    public func bind(id: ObjectIdentifier, lease: ProviderLease, host: Host) -> Bool {
        lifecycle.withLock { _ in
            state.withLock { s in
                guard !s.isBelowWatermark(lease) else { return false }
                s.bindings.bind(id: id, lease: lease, host: host)
                flow.set(host.packetFlow)
                return true
            }
        }
    }

    public func unbind(id: ObjectIdentifier, lease: ProviderLease) {
        state.withLock { s in if s.bindings.unbind(id: id, lease: lease) { flow.set(nil) } }
    }

    /// Without `publish` (tests of the bindings alone): retire the instance's older starts.
    public func retire(olderThan lease: ProviderLease) {
        state.withLock { s in
            s.watermark[lease.token] = max(s.watermark[lease.token] ?? 0, lease.generation)
            s.bindings.retire(olderThan: lease)
        }
    }

    /// The provider is freed (`deinit`; takes only `state`, never `lifecycle`). Its token is never used again, so its
    /// watermark goes with its bindings (round 4, Codex 5).
    public func release(id: ObjectIdentifier, token: ProviderToken) {
        state.withLock { s in
            s.watermark[token] = nil
            if s.bindings.release(id: id, token: token) { flow.set(nil) }
        }
    }

    private var current: Host? { state.withLock { $0.bindings.currentHost } }

    public func apply(_ settings: TunnelSettingsSpec) async throws(LPTunnelError) {
        guard let h = current else { throw LPTunnelError(.networkSettingsFailed, detail: "no provider") }
        try await h.apply(settings)
    }

    public func setReasserting(_ on: Bool) { current?.setReasserting(on) }

    /// Validated and dispatched under `lifecycle` (no publication can slip between), the host call outside `state`,
    /// the provider pinned until after both unlocks.
    public func cancel(with error: LPTunnelError, owner: ProviderLease?) {
        var pinned: AnyObject?
        lifecycle.withLock { _ in
            let target: Host? = state.withLock { s in
                if let owner, s.isBelowWatermark(owner) { return nil }
                return s.bindings.host(for: owner)
            }
            guard let target else { return }
            pinned = target.pin()
            target.cancel(with: error, owner: owner)
        }
        #if DEBUG
        cancelRequests.withLock { $0 += 1 }
        #endif
        withExtendedLifetime(pinned) {}           // the last strong reference may go here, outside both locks
        pinned = nil
    }

    public func liveProtection(owner: ProviderLease?) -> ProviderProtection? {
        let target: Host? = state.withLock { s in
            if let owner, s.isBelowWatermark(owner) { return nil }
            return s.bindings.host(for: owner)
        }
        let pinned = target?.pin()
        defer { withExtendedLifetime(pinned) {} }
        return target?.liveProtection(owner: owner)
    }

    public func pin() -> AnyObject? { nil }

    public func tunnelFileDescriptor(matching address: String?) -> Int32? { current?.tunnelFileDescriptor(matching: address) }
}

/// Forwards to the bound provider's packet flow; without one, reads never complete (nothing to pump).
// SAFETY: @unchecked Sendable: `flow` is guarded by its Mutex; the wrapped flow is thread safe.
public final class ForwardingPacketFlow: PacketFlowSource, @unchecked Sendable {
    private let flow = Mutex<(any PacketFlowSource)?>(nil)
    public init() {}
    public func set(_ f: (any PacketFlowSource)?) { flow.withLock { $0 = f } }
    public func readPackets(_ handler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        flow.withLock { $0 }?.readPackets(handler)
    }
    @discardableResult public func writePackets(_ packets: [Data], protocols: [NSNumber]) -> Bool {
        flow.withLock { $0 }?.writePackets(packets, protocols: protocols) ?? false
    }
}
