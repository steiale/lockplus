import Foundation
import LPModel
import LPWire
import LPXPCClient
import Synchronization
import Testing

/// A test clock whose sleeps return at once and move `now` to their deadline, recording each requested duration.
/// The retry schedule is then exact and independent of the machine's speed (the CI runner fit only 4 attempts into
/// a real 400 ms window).
final class SteppingClock: Clock, Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration
        func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct State { var now = Instant(offset: .zero); var sleeps: [Duration] = [] }
    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    /// Every sleep so far, in order.
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        state.withLock { s in
            s.sleeps.append(s.now.duration(to: deadline))
            if s.now < deadline { s.now = deadline }
        }
    }
}

@Suite struct HelloRetryTests {
    static let hello = ServerHello(extVersion: "2.0.0", extBuild: "200000", capabilities: [])
    static let fast = HelloRetryPolicy(window: .milliseconds(400), base: .milliseconds(20), cap: .milliseconds(80))

    @Test func standardPolicyIsTheDesignValues() {
        #expect(HelloRetryPolicy.standard.window == .seconds(12))
        #expect(HelloRetryPolicy.standard.base == .milliseconds(500))
        #expect(HelloRetryPolicy.standard.cap == .seconds(4))
    }

    @Test func retriesThroughTheThrottleThenSucceeds() async {
        let clock = SteppingClock()
        let n = Mutex(0)
        let r = await Self.fast.run(clock: clock) {
            n.withLock { $0 += 1 }
            return n.withLock { $0 } < 4 ? .retryable(LPError(.timeout)) : .success(Self.hello)
        }
        #expect(r == .success(Self.hello))
        #expect(n.withLock { $0 } == 4)
        #expect(clock.sleeps == [.milliseconds(20), .milliseconds(40), .milliseconds(80)])   // capped doubling
    }

    @Test func fatalStopsAtOnce() async {
        let clock = SteppingClock()
        let n = Mutex(0)
        let r = await Self.fast.run(clock: clock) {
            n.withLock { $0 += 1 }
            return .fatal(LPError(.unauthorizedPeer))
        }
        #expect(r == .failure(LPError(.unauthorizedPeer)))
        #expect(n.withLock { $0 } == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func givesUpAfterTheWindowAsUnavailable() async {
        let clock = SteppingClock()
        let attemptsAt = Mutex<[Duration]>([])
        let r = await Self.fast.run(clock: clock) {
            attemptsAt.withLock { $0.append(clock.now.offset) }
            return .retryable(LPError(.timeout))
        }
        guard case .failure(let e) = r else { Issue.record("expected failure"); return }
        #expect(e.code == .extensionUnavailable)
        // 20, 40, 80, 80, 80, 80 ms, then the last sleep is clipped to the window, so the last attempt is AT the deadline.
        #expect(clock.sleeps == [20, 40, 80, 80, 80, 80, 20].map { .milliseconds($0) })
        #expect(attemptsAt.withLock { $0 } == [0, 20, 60, 140, 220, 300, 380, 400].map { .milliseconds($0) })
        #expect(clock.now.offset == .milliseconds(400))
    }

    /// The design schedule (§5.4): 0.5, 1, 2, 4, 4 s, then clipped; seven attempts span exactly the 12 s window.
    @Test func standardScheduleCoversTheRespawnThrottle() async {
        let clock = SteppingClock()
        let attemptsAt = Mutex<[Duration]>([])
        let r = await HelloRetryPolicy.standard.run(clock: clock) {
            attemptsAt.withLock { $0.append(clock.now.offset) }
            return .retryable(LPError(.timeout))
        }
        #expect((try? r.get()) == nil)
        #expect(attemptsAt.withLock { $0 } == [0, 500, 1_500, 3_500, 7_500, 11_500, 12_000].map { .milliseconds($0) })
    }

    @Test func cancellationDuringTheBackoffIsCancelled() async {
        let clock = SteppingClock()
        let r = await Task {
            await Self.fast.run(clock: clock) {
                withUnsafeCurrentTask { $0?.cancel() }
                return .retryable(LPError(.timeout))
            }
        }.value
        #expect(r == .failure(LPError(.cancelled)))
    }
}
