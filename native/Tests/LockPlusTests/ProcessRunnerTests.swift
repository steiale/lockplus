import Foundation
import LPModel
import Testing
@testable import LockPlus

/// Reviews M6, M10, FA-L4: no full-pipe stall, sub-second timeouts, deadlines that really end.
@Suite("ProcessRunner and deadlines (M6, M10)")
struct ProcessRunnerTests {
    /// A runner that stopped draining would stall dd on the full pipe until the timeout terminated it, and a terminated
    /// tool yields nil: the output check alone proves the drain, without an elapsed-time bound (the timeout is only a
    /// backstop, far above any CI load).
    @Test func largeOutputIsDrainedAndCapped() async {
        let out = await ProcessRunner.run("/bin/dd", ["if=/dev/zero", "bs=1048576", "count=8"], timeout: .seconds(120), maxBytes: 1 << 20)
        #expect(out?.utf8.count == 1 << 20)
    }

    /// nil means the timeout terminated the tool: had it not fired, `sleep` would exit 0 after 60 s and yield "".
    /// No elapsed-time bound (a fully loaded Unit run measured 3.1 s for this 300 ms timeout and failed the old 2 s one).
    @Test func aSubSecondTimeoutStopsTheTool() async {
        let out = await ProcessRunner.run("/bin/sleep", ["60"], timeout: .milliseconds(300))
        #expect(out == nil)
    }

    @Test func aMissingToolIsNil() async {
        #expect(await ProcessRunner.run("/nonexistent/tool", [], timeout: .seconds(1)) == nil)
    }

    /// The deadline's sleep is injected and elapses at once; the blocking work is released only after `withDeadline`
    /// returned, so the result can't depend on the machine's speed (a deadline that waited for it would never return).
    @Test(.timeLimit(.minutes(1))) func aDeadlineEndsEvenWhenTheWorkBlocks() async {
        let stuck = DispatchSemaphore(value: 0)
        let v = await withDeadline(.milliseconds(200), onTimeout: -1, sleep: { _ in }) {
            await Blocking.run { stuck.wait(); return 1 }
        }
        #expect(v == -1)
        stuck.signal()
    }
}

@MainActor @Suite("LogsStore pacing (M10)", .serialized)
struct LogsPacingTests {
    final class CountingSources: LogSources, @unchecked Sendable {     // SAFETY: test-only, main-actor use
        var appSince: [Date] = []
        var tunnelCalls = 0
        func appLines(since: Date) async -> [LogLine] { appSince.append(since); return [] }
        func tunnelLines(since: Date) async -> Result<[LogLine], LogReadGap> { tunnelCalls += 1; return .success([]) }
    }

    @Test func noRescanOfTheDayAndTheTunnelReadIsPaced() async {
        let src = CountingSources()
        let store = LogsStore(sources: src, model: LogsUIModel(), redactor: { Redactor() })
        await store.refresh()
        await store.refresh()
        #expect(src.tunnelCalls == 1)                                       // ≤ every 30 s
        #expect(src.appSince.count == 2)
        #expect(Date().timeIntervalSince(src.appSince[1]) < 60)             // the second read starts near now
    }
}
