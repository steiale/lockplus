import Dispatch
import Foundation
import Synchronization

/// DESIGN §7.1/§7.6 (draft 9, S2): the extension's deadline clock. `SuspendingClock.sleep` and
/// `DispatchQueue.asyncAfter` let the system coalesce a wake-up by up to ~10 % of the interval; in the S2 VMs a 50 s
/// deadline fired at 53.4 s and a 300 s one at 304.9 s. Every start, hold, auth and stop deadline of the controller
/// therefore sleeps on this clock: a `DispatchSourceTimer` with `.strict` and zero leeway.
///
/// Instants are `SuspendingClock` instants (uptime: they pause while the Mac sleeps, like `DispatchTime`), so a
/// connect or auth deadline never fires the instant the Mac wakes (§7.1 rule 4).
public struct StrictSuspendingClock: Clock, Sendable {
    public typealias Instant = SuspendingClock.Instant
    public typealias Duration = Swift.Duration

    /// One serial queue for every strict timer of the process; handlers only resume a continuation.
    private static let queue = DispatchQueue(label: "lockplus.strict-timer", qos: .userInitiated)

    public init() {}

    public var now: Instant { SuspendingClock.now }
    public var minimumResolution: Duration { SuspendingClock().minimumResolution }

    /// `tolerance` is ignored on purpose: strict means no coalescing.
    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let remaining = now.duration(to: deadline)
        if remaining <= .zero { try Task.checkCancellation(); return }
        try await Self.sleep(for: remaining)
    }

    /// The timer itself (also used directly by tests): `.strict`, leeway 0, cancellable.
    static func sleep(for d: Duration) async throws {
        let gate = StrictTimerGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
                let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
                timer.schedule(deadline: .now() + .nanoseconds(Self.nanoseconds(d)), repeating: .never, leeway: .nanoseconds(0))
                timer.setEventHandler { @Sendable in gate.finish(nil) }
                // Already cancelled: cancel, then activate, so the source is never released while inactive.
                if !gate.arm(k, timer) { timer.cancel() }
                timer.resume()
            }
        } onCancel: {
            gate.finish(CancellationError())
        }
    }

    static func nanoseconds(_ d: Duration) -> Int {
        let c = d.components
        let ns = Double(c.seconds) * 1e9 + Double(c.attoseconds) / 1e9
        return ns >= Double(Int.max) ? Int.max : max(0, Int(ns))
    }
}

/// Resumes the sleeper exactly once (timer fire or cancellation) and cancels the timer source.
// SAFETY: all mutable state is guarded by its Mutex; the continuation is resumed at most once.
private final class StrictTimerGate: Sendable {
    private struct S {
        var k: CheckedContinuation<Void, any Error>?
        var timer: (any DispatchSourceTimer)?
        var done: (any Error)??
    }
    private let s = Mutex(S())

    /// Returns false if the sleep was already cancelled (the continuation is resumed here, the timer never runs).
    func arm(_ k: CheckedContinuation<Void, any Error>, _ timer: any DispatchSourceTimer) -> Bool {
        let early: (any Error)?? = s.withLock { st in
            if let d = st.done { return d }
            st.k = k; st.timer = timer
            return nil
        }
        guard let early else { return true }
        if let e = early { k.resume(throwing: e) } else { k.resume() }
        return false
    }

    func finish(_ error: (any Error)?) {
        let (k, t): (CheckedContinuation<Void, any Error>?, (any DispatchSourceTimer)?) = s.withLock { st in
            guard st.done == nil else { return (nil, nil) }
            st.done = .some(error)
            defer { st.k = nil; st.timer = nil }
            return (st.k, st.timer)
        }
        t?.cancel()
        guard let k else { return }
        if let error { k.resume(throwing: error) } else { k.resume() }
    }
}
