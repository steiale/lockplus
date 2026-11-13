import Foundation
import Synchronization

/// How a headless run (`--resume-protection`) is driven (200026 E2E S9, release blocker).
///
/// 2.0.2 RC: the agent called `dispatchMain()`. That parks the main thread and drains the main queue on a worker thread,
/// so `Thread.isMainThread` is false inside a main-queue block. NE delivers `NEVPNStatusDidChange` from a main-queue
/// block; `NEManagerStore`'s observer is registered with `queue: .main`, and NotificationCenter, seeing a current queue
/// that isn't `OperationQueue.main`, enqueues the observer on it and `waitUntilFinished`: on the queue it is blocking.
/// The agent hung forever (sampled on 26.6.2 and 27.2), and its 5 s watchdog, itself a main-queue `asyncAfter`, never ran,
/// so launchd never started another run and the paused profile was never resumed.
///
/// Now:
/// - the main thread runs its run loop (`runMainLoop`), as in the GUI, so main-queue blocks run ON the main thread and
///   the observer runs inline (lint `lp_no_dispatch_main_in_app`);
/// - the hard deadline runs on its own queue, never the main queue, so a main thread stuck anyway (a framework call that
///   never returns) still ends the process. `end` is called exactly once: `.finished` when the work returns first,
///   `.timedOut` when the deadline passes first (the caller exits; the pause stays set, so the next run retries).
///   The caller ends the process with `_exit` either way (Fable L4), so nothing after `end` can keep it alive.
enum HeadlessRunner {
    enum End: Sendable, Equatable { case finished, timedOut }

    /// Starts `work` on the main actor and arms the deadline on `watchdogQueue`. Returns at once; the main actor's job
    /// runs when the main queue is next drained (in production: by `runMainLoop()`).
    static func start(timeout: Duration, watchdogQueue: DispatchQueue = DispatchQueue(label: "io.github.steiale.lockplus.mac.resume-watchdog"),
                      work: @escaping @MainActor @Sendable () async -> Void, end: @escaping @Sendable (End) -> Void) {
        let once = Once()
        // 2.0.2 RC review (N3): a strict timer, no leeway (`asyncAfter` may fire about 10 % late, DESIGN D9-5). It holds
        // itself (the handler captures it) until it fired; cancelled then.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: watchdogQueue)
        timer.schedule(deadline: .now() + timeout.dispatchInterval, leeway: .nanoseconds(0))
        timer.setEventHandler { @Sendable in
            timer.cancel()
            if once.claim() { end(.timedOut) }
        }
        timer.activate()
        Task { @MainActor in
            await work()
            if once.claim() { end(.finished) }
        }
    }

    /// Runs the main thread's run loop forever (the process ends through `end`). The default mode is one of the common
    /// modes, so the main dispatch queue (main actor jobs, NE's callbacks) is serviced by it; the timer only keeps the mode
    /// from ever being empty.
    static func runMainLoop() -> Never {
        precondition(Thread.isMainThread, "the headless run loop is the main thread's")
        RunLoop.main.add(Timer(timeInterval: 3600, repeats: true) { @Sendable _ in }, forMode: .default)
        while true { _ = RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    /// The first `claim()` wins.
    private final class Once: Sendable {
        private let done = Mutex(false)
        func claim() -> Bool { done.withLock { d in if d { return false }; d = true; return true } }
    }
}

extension Duration {
    /// Whole milliseconds, for `DispatchTime` arithmetic.
    fileprivate var dispatchInterval: DispatchTimeInterval {
        let c = components
        return .milliseconds(Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000))
    }
}
