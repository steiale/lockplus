import LPModel
import LPWire

/// The §5.4 respawn-throttle rule (draft 7, S5 on 27): launchd respawns a crashed extension no earlier than 10 s after
/// its previous spawn, so a `hello` inside that window times out although nothing is wrong. After an interruption the
/// client retries `hello` on the SAME connection object with a capped doubling backoff (base 0.5 s, cap 4 s) for 12 s (≥ 11 s) before
/// mapping to `.extensionUnavailable`. These retries never count toward the 3-consecutive-timeouts busy rule.
public struct HelloRetryPolicy: Sendable, Equatable {
    public var window: Duration
    public var base: Duration
    public var cap: Duration

    public init(window: Duration = .seconds(12), base: Duration = .milliseconds(500), cap: Duration = .seconds(4)) {
        self.window = window; self.base = base; self.cap = cap
    }

    public static let standard = HelloRetryPolicy()

    /// What one hello attempt produced.
    public enum Attempt: Sendable {
        case success(ServerHello)
        /// Timeout or 4097: the extension may still be throttled; try again inside the window.
        case retryable(LPError)
        /// 4099 (name gone), 4102 (wrong peer), a version mismatch, a malformed reply: stop now.
        case fatal(LPError)
    }

    /// Runs `attempt` until it succeeds, fails fatally, or the window is spent.
    public func run<C: Clock>(
        clock: C,
        _ attempt: () async -> Attempt
    ) async -> Result<ServerHello, LPError> where C.Duration == Duration {
        let deadline = clock.now.advanced(by: window)
        var delay = base                       // 0.5, 1, 2, 4, 4, … s (capped doubling, no jitter)
        var last = LPError(.extensionUnavailable, detail: "respawn window elapsed")
        while true {
            switch await attempt() {
            case .success(let h): return .success(h)
            case .fatal(let e): return .failure(e)
            case .retryable(let e): last = e
            }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            // Sleep is clipped to the window, so the last attempt starts at the deadline at the latest.
            do { try await clock.sleep(for: min(delay, remaining)) } catch { return .failure(LPError(.cancelled)) }
            delay = min(delay * 2, cap)
        }
        return .failure(LPError(.extensionUnavailable, detail: "respawn window elapsed: \(last.code)"))
    }
}
