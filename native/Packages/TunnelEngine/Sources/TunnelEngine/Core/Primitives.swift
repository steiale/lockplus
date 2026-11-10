import Foundation
import LPModel
import LPWire
import os
import Synchronization

let engineLog = Logger(subsystem: "io.github.steiale.lockplus.mac.tunnel", category: "engine")

/// Calls an NE completion handler at most once (DESIGN §7.1). Release builds log a fault on a second call.
public final class CompletionOnce<Arg: Sendable>: Sendable {
    private let body: Mutex<(@Sendable (Arg) -> Void)?>
    public init(_ body: @escaping @Sendable (Arg) -> Void) { self.body = Mutex(body) }
    public var isPending: Bool { body.withLock { $0 != nil } }
    @discardableResult public func callAsFunction(_ arg: Arg) -> Bool {
        guard let b = body.withLock({ b in defer { b = nil }; return b }) else {
            engineLog.fault("completion called twice")
            return false
        }
        b(arg); return true
    }
}

/// Full-jitter capped backoff (DESIGN §7.6). Every retry loop uses it; tests pass a seeded generator.
public struct Backoff: Sendable, Equatable {
    public var base: Duration = .seconds(1)
    public var cap: Duration = .seconds(60)
    public var factor: Double = 2.0
    public private(set) var attempt: Int = 0

    public init(base: Duration = .seconds(1), cap: Duration = .seconds(60), factor: Double = 2.0) {
        self.base = base; self.cap = cap; self.factor = factor
    }

    /// random(0.8…1.2) × min(cap, base × factor^attempt). T1: computed in Double seconds with the exponent clamped
    /// (≤ 32) and capped BEFORE building a Duration, so no attempt count can overflow `Duration`'s Int128 (an
    /// unbounded kill-switch outage retries forever).
    public mutating func next(using rng: inout some RandomNumberGenerator) -> Duration {
        let capS = cap.seconds
        let raw = base.seconds * pow(factor, Double(min(attempt, 32)))
        let capped = raw.isFinite ? min(capS, raw) : capS
        if attempt < Int.max { attempt += 1 }
        let j = Double.random(in: 0.8...1.2, using: &rng)
        return .milliseconds(Int64((capped * j * 1000).rounded()))
    }
    public mutating func reset() { attempt = 0 }
}

/// The `.backoff` start-latch schedule (DESIGN §7.6): 5 s doubling to 5 min, no jitter.
public enum LatchBackoff {
    public static let first: TimeInterval = 5
    public static let cap: TimeInterval = 300
    public static func next(after previous: TimeInterval?) -> TimeInterval {
        guard let p = previous else { return first }
        return min(cap, p * 2)
    }
}

/// splitmix64; deterministic, for tests and as the production default seed source's carrier.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Engine log ring (DESIGN §7.1): synchronous append from any thread, including Go and C++ callbacks.
public final class LogRing: Sendable {
    public static let shared = LogRing()
    private struct S { var lines: [String] = []; var base = 0 }
    private let s = Mutex(S())
    private let capacity: Int
    public init(capacity: Int = 4000) { self.capacity = capacity }
    public func append(_ line: String) {
        s.withLock { st in
            st.lines.append(line)
            if st.lines.count > capacity { let d = st.lines.count - capacity; st.lines.removeFirst(d); st.base += d }
        }
    }
    /// Lines after absolute index `since` (≤ `max`), and the next index.
    /// Clamped arithmetic throughout: any `since`/`max` (negative, Int.min/max) is safe.
    public func lines(since: Int, max: Int = 1000) -> (lines: [String], next: Int) {
        s.withLock { st in
            let start = since <= st.base ? 0 : since - st.base          // since > base: no overflow
            guard start < st.lines.count else { return ([], st.base + st.lines.count) }
            let n = Swift.min(Swift.max(0, max), st.lines.count - start)
            let slice = Array(st.lines[start..<(start + n)])
            return (slice, st.base + start + slice.count)
        }
    }
}

/// What the controller tells the adapter after applying a plan (DESIGN §7.3).
public enum EstablishAnswer: Sendable, Equatable {
    case fd(Int32)          // utun-fd mode: NE's utun descriptor (the adapter dups or hands it to Go, never closes it)
    case applied            // packetFlow mode: settings applied, the adapter uses the session pump
    case failed(LPErrorCode)
}

/// The extension-wide log level (§14.1). `.debug` adds redacted engine lines to the ring. Not settable over XPC
/// (review M1: any uid could raise it); the Tunnel target may set it at startup.
public enum EngineLogLevel {
    public enum Level: String, Sendable, CaseIterable { case error, notice, info, debug }
    private static let level = Mutex<Level>(.info)
    public static var current: Level {
        get { level.withLock { $0 } }
        set { level.withLock { $0 = newValue } }
    }
}
