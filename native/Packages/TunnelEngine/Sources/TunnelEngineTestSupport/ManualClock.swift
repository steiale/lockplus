import Synchronization

/// Test clock (DESIGN §15.1, ref/swift-concurrency §12.3): sleepers register synchronously under a `Mutex`, tests
/// call `await waitForSleepers(n)` and then `advance(by:)`. No yielding heuristics, no swift-clocks dependency.
public final class ManualClock: Clock, Sendable {
    public struct Instant: InstantProtocol, Sendable {
        public var offset: Duration
        public init(offset: Duration) { self.offset = offset }
        public func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private enum Slot { case waiting(Instant, CheckedContinuation<Void, any Error>), cancelled }
    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var registered = 0
        var slots: [Int: Slot] = [:]
        var watchers: [(Int, CheckedContinuation<Void, Never>)] = []
        var waitingCount: Int { slots.values.reduce(0) { if case .waiting = $1 { return $0 + 1 } else { return $0 } } }
    }
    private let state = Mutex(State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }
    /// Number of registered sleepers.
    public var sleeperCount: Int { state.withLock { $0.waitingCount } }

    /// Sleepers ever registered (monotonic; a cancelled or fired one still counts). `sleeperCount` can't tell a sleeper
    /// that was replaced from the one it replaced, so a test that must know a NEW one registered waits on this.
    public var registrations: Int { state.withLock { $0.registered } }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { s in defer { s.nextID += 1 }; return s.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
                enum Action { case resume, cancel, wait([CheckedContinuation<Void, Never>]) }
                let action: Action = state.withLock { s in
                    if case .cancelled = s.slots[id] { s.slots[id] = nil; return .cancel }
                    if deadline <= s.now { return .resume }
                    s.slots[id] = .waiting(deadline, k)
                    s.registered += 1
                    let n = s.waitingCount
                    var ready: [CheckedContinuation<Void, Never>] = []
                    s.watchers.removeAll { w in if w.0 <= n { ready.append(w.1); return true }; return false }
                    return .wait(ready)
                }
                switch action {
                case .resume: k.resume()
                case .cancel: k.resume(throwing: CancellationError())
                case .wait(let ready): for w in ready { w.resume() }
                }
            }
        } onCancel: {
            let k: CheckedContinuation<Void, any Error>? = state.withLock { s in
                switch s.slots[id] {
                case .waiting(_, let k): s.slots[id] = nil; return k
                case .cancelled: return nil
                case nil: s.slots[id] = .cancelled; return nil
                }
            }
            k?.resume(throwing: CancellationError())
        }
    }

    /// Moves `now` forward and resumes every due sleeper (outside the lock).
    public func advance(by d: Duration) {
        let due: [CheckedContinuation<Void, any Error>] = state.withLock { s in
            s.now = s.now.advanced(by: d)
            var out: [(Instant, Int, CheckedContinuation<Void, any Error>)] = []
            for (id, slot) in s.slots { if case .waiting(let t, let k) = slot, t <= s.now { out.append((t, id, k)) } }
            for o in out { s.slots[o.1] = nil }
            return out.sorted { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }.map(\.2)
        }
        for k in due { k.resume() }
    }

    /// Returns once at least `n` sleepers are registered.
    public func waitForSleepers(_ n: Int) async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if s.waitingCount >= n { return true }
                s.watchers.append((n, k)); return false
            }
            if ready { k.resume() }
        }
    }
}
