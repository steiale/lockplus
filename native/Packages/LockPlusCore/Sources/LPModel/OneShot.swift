import Synchronization

/// Resumes a continuation exactly once; later resumes are dropped (DESIGN §5.4, ref/swift-concurrency §6.1 rule 5).
/// The reply block, the proxy error handler, the timer task and the task-cancellation handler all go through it.
///
///     let gate = OneShot<Result<X, LPError>>()
///     let r = await withTaskCancellationHandler {
///         await withCheckedContinuation { k in
///             gate.attach(k, ifCancelled: .failure(LPError(.cancelled)))
///             … start the work; every completion path calls gate.resume(…)
///         }
///     } onCancel: { gate.cancel(.failure(LPError(.cancelled))) }
public final class OneShot<T: Sendable>: Sendable {
    private enum State { case idle, pending(CheckedContinuation<T, Never>), cancelledEarly, done }
    private let state = Mutex<State>(.idle)

    public init() {}

    /// Arms the gate. If `cancel` already ran (cancellation before attach), resumes at once with `ifCancelled`.
    /// Callers start the work only after `attach`, so no `resume` can precede it.
    public func attach(_ k: CheckedContinuation<T, Never>, ifCancelled value: @autoclosure () -> T) {
        let early = state.withLock { s -> Bool in
            switch s {
            case .cancelledEarly: s = .done; return true
            case .idle: s = .pending(k); return false
            case .pending, .done: preconditionFailure("OneShot attached twice")
            }
        }
        if early { k.resume(returning: value()) }
    }

    /// Resumes once; every later call is a no-op. Returns whether this call won.
    @discardableResult
    public func resume(_ value: T) -> Bool {
        let k: CheckedContinuation<T, Never>? = state.withLock { s in
            guard case .pending(let k) = s else { return nil }
            s = .done
            return k
        }
        k?.resume(returning: value)           // resumed outside the lock
        return k != nil
    }

    /// May run before `attach` (a task-cancellation handler).
    public func cancel(_ value: T) {
        let k: CheckedContinuation<T, Never>? = state.withLock { s in
            switch s {
            case .pending(let k): s = .done; return k
            case .idle: s = .cancelledEarly; return nil
            case .cancelledEarly, .done: return nil
            }
        }
        k?.resume(returning: value)
    }

    public var isDone: Bool { state.withLock { if case .done = $0 { true } else { false } } }
}

/// Runs `body` with a deadline through a `OneShot` (never a TaskGroup race, ref/swift-concurrency SC9): returns
/// `onTimeout` if `body` has not finished after `timeout`. `body` keeps running; its late result is dropped. The
/// deadline's sleeper is cancelled when `withDeadline` returns (review on-demand 4 #4: one sleeping Task per call
/// otherwise outlived every early answer); a cancelled sleep's late `resume(onTimeout)` is dropped by the gate.
public func withDeadline<T: Sendable>(
    _ timeout: Duration,
    onTimeout: T,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    _ body: @escaping @Sendable () async -> T
) async -> T {
    let gate = OneShot<T>()
    let sleeper = Mutex<Task<Void, Never>?>(nil)
    defer { sleeper.withLock { $0?.cancel() } }
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (k: CheckedContinuation<T, Never>) in
            gate.attach(k, ifCancelled: onTimeout)
            Task { gate.resume(await body()) }
            // Started after `attach`, so even a sleep that returns at once can't resume before the gate is armed.
            sleeper.withLock {
                $0 = Task {
                    try? await sleep(timeout)
                    gate.resume(onTimeout)
                }
            }
        }
    } onCancel: {
        gate.cancel(onTimeout)
    }
}
