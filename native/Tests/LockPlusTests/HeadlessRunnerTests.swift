import Foundation
import Synchronization
import Testing
@testable import LockPlus

/// 200026 E2E S9 (release blocker): the headless resume agent hung forever on a main queue deadlocked inside NE's status
/// notification, and its watchdog (a main-queue `asyncAfter`) never fired. `HeadlessRunner` drives the run: work on the
/// main actor, the hard deadline on its own queue, exactly one end.
@Suite("Headless runner (200026 S9)", .serialized)
struct HeadlessRunnerTests {
    final class Ends: Sendable {
        private let state = Mutex<[HeadlessRunner.End]>([])
        var all: [HeadlessRunner.End] { state.withLock { $0 } }
        func record(_ e: HeadlessRunner.End) { state.withLock { $0.append(e) } }

        func wait(for n: Int, timeout: Duration) async -> Bool {
            let end = ContinuousClock.now + timeout
            while all.count < n {
                if ContinuousClock.now > end { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
    }

    /// Synchronous on purpose: the main thread waits, as it did inside `waitUntilFinished`.
    @MainActor static func blockMainThread(on s: DispatchSemaphore, ceiling seconds: Int) -> Bool {
        s.wait(timeout: .now() + .seconds(seconds)) == .success
    }

    @MainActor static func onMainThread() -> Bool { Thread.isMainThread }

    /// The S9 hang itself: the main thread blocked (as by the observer waiting on its own queue). The deadline still
    /// fires: it isn't on the main queue. Its `end` releases the main thread here; in production it exits the process.
    /// The deadline's queue is held until the main thread is stuck, so the order is the hang's under any load.
    @Test func theDeadlineFiresWhileTheMainThreadIsStuck() async throws {
        let ends = Ends()
        let stuck = DispatchSemaphore(value: 0)
        let blocking = Mutex(false)
        let released = Mutex(false)
        let deadlineQueue = DispatchQueue(label: "HeadlessRunnerTests.deadline")
        deadlineQueue.suspend()
        HeadlessRunner.start(timeout: .milliseconds(50), watchdogQueue: deadlineQueue, work: { @MainActor @Sendable in
            blocking.withLock { $0 = true }
            // A main-thread wait with a 20 s ceiling, so a regression fails the test instead of hanging the suite.
            let ok = Self.blockMainThread(on: stuck, ceiling: 20)
            released.withLock { $0 = ok }
        }, end: { @Sendable e in
            ends.record(e)
            stuck.signal()
        })
        let until = ContinuousClock.now + .seconds(30)
        while !blocking.withLock({ $0 }), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        try #require(blocking.withLock { $0 })
        let t0 = ContinuousClock.now
        deadlineQueue.resume()                                // the main thread is stuck now
        #expect(await ends.wait(for: 1, timeout: .seconds(10)))
        #expect(ends.all == [.timedOut])
        #expect(ContinuousClock.now - t0 < .seconds(10))
        let end = ContinuousClock.now + .seconds(15)
        while !released.withLock({ $0 }), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(released.withLock { $0 })                  // the deadline, not the 20 s ceiling, released it
        #expect(ends.all == [.timedOut])                    // the work's late return is no second end
    }

    /// Work that awaits forever (an NE callback that never comes): ended by the deadline, once.
    @Test func workThatNeverReturnsEndsAtTheDeadline() async throws {
        let ends = Ends()
        let never = AsyncStream<Void>.makeStream()
        HeadlessRunner.start(timeout: .milliseconds(200), work: { @MainActor @Sendable in
            for await _ in never.stream {}
        }, end: { @Sendable e in ends.record(e) })
        #expect(await ends.wait(for: 1, timeout: .seconds(5)))
        #expect(ends.all == [.timedOut])
        never.continuation.finish()
        try await Task.sleep(for: .milliseconds(100))
        #expect(ends.all == [.timedOut])
    }

    /// Work that returns in time ends `.finished`; the deadline passing later is no second end. The deadline's queue is
    /// held until the work ended (deterministic under full-suite load, where the main actor may be busy for seconds).
    @Test func workThatReturnsEndsFinishedOnce() async throws {
        let ends = Ends()
        let ran = Mutex(false)
        let deadlineQueue = DispatchQueue(label: "HeadlessRunnerTests.deadline")
        deadlineQueue.suspend()
        HeadlessRunner.start(timeout: .milliseconds(50), watchdogQueue: deadlineQueue, work: { @MainActor @Sendable in
            let onMain = Self.onMainThread()                 // main-actor work runs on the main thread
            ran.withLock { $0 = onMain }
        }, end: { @Sendable e in ends.record(e) })
        #expect(await ends.wait(for: 1, timeout: .seconds(30)))
        #expect(ends.all == [.finished])
        #expect(ran.withLock { $0 })
        deadlineQueue.resume()                                // the deadline (long past) runs now
        try await Task.sleep(for: .milliseconds(300))
        #expect(ends.all == [.finished])
    }

    /// The deadlock's mechanism: a `queue: .main` observer posted to from a main-queue block. Under the main run loop
    /// (the GUI's, this test host's, and now the agent's) that block runs on the main thread and the observer runs inline.
    /// Under `dispatchMain()` the same post waited on itself forever (`lp_no_dispatch_main_in_app` keeps it out).
    @Test func aMainQueueObserverRunsInlineFromAMainQueuePost() async throws {
        let name = Notification.Name("HeadlessRunnerTests.\(UUID().uuidString)")
        let seen = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { @Sendable _ in
            seen.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let ends = Ends()
        HeadlessRunner.start(timeout: .seconds(60), work: { @MainActor @Sendable in
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { @Sendable in
                    NotificationCenter.default.post(name: name, object: nil)
                    k.resume()
                }
            }
        }, end: { @Sendable e in ends.record(e) })
        #expect(await ends.wait(for: 1, timeout: .seconds(61)))
        #expect(ends.all == [.finished])
        #expect(seen.withLock { $0 } == 1)
    }

    /// The live agent's budget is the hard deadline: the design's 5 s run (an arm lapses after 15 s, §10.4).
    @Test func theAgentsDeadlineIsItsBudget() {
        #expect(HeadlessResume.budget == .seconds(5))
        #expect(HeadlessResume.reserve < HeadlessResume.budget)
    }
}
