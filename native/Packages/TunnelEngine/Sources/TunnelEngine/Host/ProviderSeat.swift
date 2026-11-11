import Foundation
import LPModel
import os
import Synchronization

/// One provider instance's side of the 2.0.1 start guard (DESIGN §7.1, §7.2), without NetworkExtension so the wiring is
/// tested (review M4). `PacketTunnelProvider` owns one and forwards every NE entry point to it:
/// - `startTunnel` marks the instance live at once, on the provider queue, and lets the controller bind it only when
///   it accepts the start;
/// - `stopTunnel` marks it stopped at once, BEFORE its Task reaches the controller, and that stop ends only this
///   instance's own session;
/// - `sleep`/`wake` drive only this instance's session (review L4);
/// - `released` (`deinit`) marks it stopped.
public final class ProviderSeat<C: Clock>: Sendable where C.Duration == Duration {
    private let controller: TunnelController<C>
    public let token: ProviderToken
    private let lease = Mutex<ProviderLease?>(nil)
    private let gate: (any ProviderLifecycleGate)?

    /// `gate`: the process's lifecycle gate (`ProcessProviderHost.shared`, Codex r3 2); nil only in tests of the seat
    /// alone.
    public init(controller: TunnelController<C>, gate: (any ProviderLifecycleGate)? = nil) {
        self.controller = controller
        self.gate = gate
        token = controller.providers.makeToken()
    }

    /// The lease of this instance's latest `startTunnel` (nil before the first).
    public var currentLease: ProviderLease? { lease.withLock { $0 } }

    /// `bind` binds this start (its lease) as the process's provider; false: the provider is gone or the router refused
    /// the bind (a newer generation was published). The new generation is published through the lifecycle gate at
    /// once, on the provider queue, before the controller sees the start: becoming current, retiring the instance's
    /// older starts and raising its watermark are one step (Codex r3 2), whether or not this start is accepted.
    public func startTunnel(_ req: StartRequest,
                            bind: @escaping @Sendable (ProviderLease) -> Bool,
                            completion: @escaping @Sendable (LPTunnelError?) -> Void) {
        let providers = controller.providers, token = token
        let l = gate?.publish(token) { providers.started(token) } ?? providers.started(token)
        lease.withLock { $0 = l }
        let c = controller
        Task(name: "startTunnel") {
            do throws(LPTunnelError) {
                try await c.start(req, owner: l, bind: { bind(l) })
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// `unbind` forgets this stop's own start's binding (re-check L2: never a newer start of a reused instance).
    public func stopTunnel(reason: StopReason, unbind: @escaping @Sendable (ProviderLease) -> Void, completion: @escaping @Sendable () -> Void) {
        let l = currentLease
        controller.providers.stopped(token)          // at once: a start after this may replace our session
        let c = controller
        Task(name: "stopTunnel") {
            // Only our own session (never one a newer instance runs); an instance that never started owns nothing.
            if let l {
                await c.stop(reason: reason, owner: l)    // the controller caps the adapter stop at 5 s
                unbind(l)
            }
            completion()
        }
    }

    public func sleep(completion: @escaping @Sendable () -> Void) {
        let l = currentLease, c = controller
        Task(name: "sleep") {
            if let l { await c.sleep(owner: l) }      // capped at 2 s by the controller (§7.4)
            completion()
        }
    }

    public func wake() {
        guard let l = currentLease else { return }
        let c = controller
        Task(name: "wake") { await c.wake(owner: l) }
    }

    /// The provider is freed: marked at once; a start waiting on its session re-checks (final review M1).
    public func released() {
        controller.providers.stopped(token)
        let c = controller
        Task { await c.recheckWaitingStarts() }
    }

    /// The provider's `protocolConfiguration` changed (KVO, r3 N1): its live protection may differ now, so a start
    /// waiting on its session re-checks.
    public func protectionChanged() {
        engineLog.info("provider protocolConfiguration changed: waiting starts re-check")   // t9 (round 4 N1) measures this
        let c = controller
        Task { await c.recheckWaitingStarts() }
    }
}
