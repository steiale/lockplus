import Dispatch
import LPModel
import Synchronization

/// One answer wins (DESIGN §7.3, ref/swift-concurrency §8.3): the controller's apply result, a stop, or the deadline.
/// `wait(timeout:)` blocks and is called ONLY on the openvpn3 connect thread (the one legitimate semaphore wait in the
/// extension). `value()` is the async form for adapters that are not on a dedicated thread (WireGuard).
// SAFETY: DispatchSemaphore is the documented exception (ref/swift-concurrency §8.3); it is never waited on from the
// cooperative pool or the NE provider queue.
public final class EstablishTicket: Sendable {
    private struct S {
        var answer: EstablishAnswer?
        var waiters: [CheckedContinuation<EstablishAnswer, Never>] = []
    }
    private let s = Mutex(S())
    private let sem = DispatchSemaphore(value: 0)

    public init() {}

    /// First answer wins; returns false when the ticket was already answered.
    @discardableResult public func answer(_ a: EstablishAnswer) -> Bool {
        let waiters: [CheckedContinuation<EstablishAnswer, Never>]? = s.withLock { st in
            guard st.answer == nil else { return nil }
            st.answer = a
            defer { st.waiters = [] }
            return st.waiters
        }
        guard let waiters else { return false }
        sem.signal()
        for w in waiters { w.resume(returning: a) }
        return true
    }

    public var answered: EstablishAnswer? { s.withLock { $0.answer } }

    /// Connect thread only. A timeout answers `.failed(.tunDeviceFailed)`.
    public func wait(timeout: DispatchTime) -> EstablishAnswer {
        if sem.wait(timeout: timeout) == .timedOut { answer(.failed(.tunDeviceFailed)) }
        return s.withLock { $0.answer! }
    }

    /// Async wait; the caller enforces its own deadline by answering the ticket.
    public func value() async -> EstablishAnswer {
        await withCheckedContinuation { (k: CheckedContinuation<EstablishAnswer, Never>) in
            let ready: EstablishAnswer? = s.withLock { st in
                if let a = st.answer { return a }
                st.waiters.append(k); return nil
            }
            if let ready { k.resume(returning: ready) }
        }
    }
}
