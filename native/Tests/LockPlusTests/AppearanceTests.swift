import AppKit
import Foundation
import Testing
@testable import LockPlus

/// §6.14: the Appearance setting applies live, including when the app itself changes it (the Go migration carries the
/// 1.x theme over): that change reaches the UI through `UIBinder.render`, not through the UI's own edit path.
@MainActor @Suite("Appearance (§6.14)", .serialized, .timeLimit(.minutes(1)))
struct AppearanceTests {
    private func reset() { NSApp.appearance = nil }

    @Test("AppAppearanceApplier: System follows macOS, Light is Aqua, Dark is Dark Aqua")
    func applier() throws {
        defer { reset() }
        AppAppearanceApplier.apply(.dark)
        #expect(NSApp.appearance?.name == .darkAqua)
        AppAppearanceApplier.apply(.light)
        #expect(NSApp.appearance?.name == .aqua)
        AppAppearanceApplier.apply(.system)
        #expect(NSApp.appearance == nil)
    }

    @Test("An appearance written by the app (migration) is applied by the push, without a relaunch")
    func appWrittenAppearanceApplies() async throws {
        defer { reset() }
        let h = Harness()
        defer { h.dir.cleanup() }
        reset()
        UIBinder.bind(h.env)
        #expect(NSApp.appearance == nil)
        h.env.settings.update { $0.appearance = .dark }               // what the Go migration does
        UIBinder.render(h.env)
        #expect(NSApp.appearance?.name == .darkAqua)
        #expect(h.env.ui.settings.appearance == .dark)                 // and the picker shows it
        h.env.settings.update { $0.appearance = .system }
        UIBinder.render(h.env)
        #expect(NSApp.appearance == nil)
    }

    @Test("A render with no appearance change leaves NSApp.appearance alone")
    func unchangedRenderDoesNotTouch() async throws {
        defer { reset() }
        let h = Harness()
        defer { h.dir.cleanup() }
        UIBinder.bind(h.env)
        NSApp.appearance = NSAppearance(named: .aqua)                  // set by something else
        h.env.settings.update { $0.supportNoteShown = true }
        UIBinder.render(h.env)
        #expect(NSApp.appearance?.name == .aqua)
    }

    @Test("The picker (UI's own edit) still applies live")
    func pickerApplies() async throws {
        defer { reset() }
        let h = Harness()
        defer { h.dir.cleanup() }
        UIBinder.bind(h.env)
        h.env.ui.settings.appearance = .dark
        let applied = await eventually { NSApp.appearance?.name == .darkAqua }
        #expect(applied)
        #expect(h.env.settings.value.appearance == .dark)
    }
}

/// L10: the chart's window and its accessibility x values.
@MainActor @Suite("Throughput chart window (L10)")
struct ThroughputWindowTests {
    static func samples(_ n: Int, end: Date = Date(timeIntervalSince1970: 10_000)) -> [RateSample] {
        (0..<n).map { RateSample(id: $0, t: end.addingTimeInterval(Double($0 - (n - 1))), rx: Double($0), tx: 0) }
    }

    @Test("Only the window plus the one sample before it")
    func visible() {
        let s = Self.samples(600)
        let start = s.last!.t.addingTimeInterval(-300)
        let v = LiveThroughputChart.visible(s, from: start)
        #expect(v.count == 302)                                        // 301 in [start, end] plus the one before
        #expect(v.first!.t == start.addingTimeInterval(-1))
        #expect(v.last == s.last)
    }

    @Test("A short buffer is shown whole; an empty one stays empty; a stale buffer shows its last sample")
    func edges() {
        let s = Self.samples(20)
        #expect(LiveThroughputChart.visible(s, from: s.first!.t.addingTimeInterval(-1000)).count == 20)
        #expect(LiveThroughputChart.visible([], from: Date()).isEmpty)
        let stale = LiveThroughputChart.visible(s, from: s.last!.t.addingTimeInterval(60))
        #expect(stale.count == 1 && stale.first == s.last)             // the sample before the (empty) window
    }

    @Test("The slice shares storage: indices stay those of the buffer")
    func isSlice() {
        let s = Self.samples(400)
        let v = LiveThroughputChart.visible(s, from: s.last!.t.addingTimeInterval(-10))
        #expect(v.startIndex == 388)
    }

    @Test("Seconds ago is measured from the newest sample, so the pre-window sample is 301 s back, not off by one")
    func secondsAgo() {
        let s = Self.samples(600)
        let v = LiveThroughputChart.visible(s, from: s.last!.t.addingTimeInterval(-300))
        let newest = v.last!.t
        #expect(RateChartDescriptor.secondsAgo(v.last!, newest: newest) == 0)
        #expect(RateChartDescriptor.secondsAgo(v[v.endIndex - 2], newest: newest) == 1)
        #expect(RateChartDescriptor.secondsAgo(v.first!, newest: newest) == 301)
        let d = RateChartDescriptor(samples: v).makeChartDescriptor()
        #expect(d.series.count == 2 && d.series[0].dataPoints.count == 302)
        #expect((d.xAxis as? AXNumericDataAxisDescriptor)?.range == 0...301)
    }
}
