import Charts
import SwiftUI

/// Menu header sparkline (§7.4): 60 samples, rx sage area, tx teal dashed, baseline fixed at 0. A `Canvas`, so there
/// is no Charts layout pass inside the `NSMenu`; it carries its own accessibility label and value.
struct SparklineCanvas: View {
    let samples: [RateSample]

    var body: some View {
        let rx = samples.map(\.rx), tx = samples.map(\.tx)
        let ceiling = max(rx.max() ?? 0, tx.max() ?? 0, 1_024)
        Canvas { ctx, size in
            func path(_ v: [Double], close: Bool) -> Path {
                var p = Path()
                guard v.count > 1 else { return p }
                let dx = size.width / CGFloat(v.count - 1)
                for (i, s) in v.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * dx, y: size.height * (1 - CGFloat(min(s / ceiling, 1))))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                if close {
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.addLine(to: CGPoint(x: 0, y: size.height))
                    p.closeSubpath()
                }
                return p
            }
            ctx.fill(path(rx, close: true), with: .color(Color.lp.rx.opacity(0.35)))
            ctx.stroke(path(rx, close: false), with: .color(Color.lp.rx), lineWidth: 1.25)
            ctx.stroke(path(tx, close: false), with: .color(Color.lp.tx), style: StrokeStyle(lineWidth: 1.25, dash: [3, 2]))
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Throughput, last minute", comment: "Sparkline accessibility label"))
        .accessibilityValue(Text(ThroughputSummary(samples: samples).sentence))
    }
}

/// "Download averaged 800 KB/s, peak 10 MB/s" (§8.2 chart summary).
struct ThroughputSummary {
    let samples: [RateSample]
    var average: Double { samples.isEmpty ? 0 : samples.map(\.rx).reduce(0, +) / Double(samples.count) }
    var peak: Double { samples.map(\.rx).max() ?? 0 }
    var sentence: String {
        String(localized: "Download averaged \(RateFormat.text(average)), peak \(RateFormat.text(peak))", comment: "Chart summary")
    }
    var spokenSentence: String {
        String(localized: "average \(RateFormat.spoken(average)), peak \(RateFormat.spoken(peak))", comment: "Spoken chart summary in the VoiceOver status item")
    }
}

/// Hero and Activity chart (§6.10, §7.4): vectorized `AreaPlot`/`LinePlot`, 300 points at 1 Hz, no downsampling,
/// fixed domains (Y ceiling moves only when the peak changes by > 25 %), animations off. Reads only its samples.
struct LiveThroughputChart: View {
    /// `.tile` inside the status tiles keeps the tile colours; everywhere else the pastel marks (§2.2a).
    enum Palette: Sendable {
        case tile, pastel
        var rx: Color { self == .tile ? Color.lp.rx : Color.lp.softSage }
        var rxFill: Color { self == .tile ? Color.lp.rx.opacity(0.35) : Color.lp.softSage.opacity(0.40) }
        var tx: Color { self == .tile ? Color.lp.tx : Color.lp.softTeal }
    }
    let samples: [RateSample]
    var palette: Palette = .tile
    var window: TimeInterval = 300
    @State private var ceiling: Double = 1_024

    /// The samples inside the window plus the one just before it (so the marks enter from the edge). A slice: no copy
    /// per body evaluation.
    static func visible(_ samples: [RateSample], from start: Date) -> ArraySlice<RateSample> {
        let firstVisible = samples.firstIndex { $0.t >= start } ?? samples.endIndex
        return samples[max(samples.startIndex, firstVisible - 1)...]
    }

    var body: some View {
        let end = samples.last?.t ?? Date()
        let start = end.addingTimeInterval(-window)
        // Only the window (plus the sample just before it, so the marks enter from the edge), and the plot is clipped:
        // a longer buffer drew its older samples left of the plot, over the card's padding (owner test 2026-11-10). The
        // ceiling follows what is visible.
        let shown = Self.visible(samples, from: start)
        let peak = max(shown.map(\.rx).max() ?? 0, shown.map(\.tx).max() ?? 0, 1_024)
        Chart {
            AreaPlot(shown, x: .value("Time", \.t), y: .value("Download", \.rx))
                .foregroundStyle(palette.rxFill)
            LinePlot(shown, x: .value("Time", \.t), y: .value("Upload", \.tx))
                .foregroundStyle(palette.tx)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...ceiling)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [ceiling / 2, ceiling]) { value in
                AxisGridLine().foregroundStyle(Color.lp.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(RateFormat.text(v)).foregroundStyle(Color.lp.label2) }
                }
            }
        }
        .transaction { $0.animation = nil }
        .onAppear { ceiling = peak * 1.1 }
        .onChange(of: peak) { _, new in
            if new > ceiling || new < ceiling * 0.75 / 1.1 { ceiling = new * 1.1 }
        }
        .accessibilityChartDescriptor(RateChartDescriptor(samples: shown))
    }
}

struct RateChartDescriptor: AXChartDescriptorRepresentable {
    let samples: ArraySlice<RateSample>

    /// Whole seconds before the newest sample (the window's extra pre-window sample is simply further back).
    static func secondsAgo(_ sample: RateSample, newest: Date) -> Double {
        max(0, newest.timeIntervalSince(sample.t).rounded())
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let all = Array(samples)
        let newest = all.last?.t ?? Date()
        let ago = all.map { Self.secondsAgo($0, newest: newest) }
        let peak = max(all.map(\.rx).max() ?? 0, all.map(\.tx).max() ?? 0, 1)
        let x = AXNumericDataAxisDescriptor(title: String(localized: "Seconds ago", comment: "Chart axis"),
                                            range: 0...max(ago.max() ?? 0, 1), gridlinePositions: []) { "\(Int($0))" }
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Rate", comment: "Chart axis"),
                                            range: 0...peak, gridlinePositions: []) { RateFormat.text($0) }
        let down = AXDataSeriesDescriptor(name: String(localized: "Download", comment: "Chart series"), isContinuous: true,
                                          dataPoints: zip(all, ago).map { s, a in .init(x: a, y: s.rx) })
        let up = AXDataSeriesDescriptor(name: String(localized: "Upload", comment: "Chart series"), isContinuous: true,
                                        dataPoints: zip(all, ago).map { s, a in .init(x: a, y: s.tx) })
        return AXChartDescriptor(title: String(localized: "Throughput", comment: "Chart title"),
                                 summary: ThroughputSummary(samples: all).sentence,
                                 xAxis: x, yAxis: y, additionalAxes: [], series: [down, up])
    }
}

/// "↓ 1.2 MB/s   ↑ 30 KB/s" as ONE accessibility element so it doesn't chatter (§8.2).
struct RatePair: View {
    let rate: Rate?
    var font: Font = .callout
    var columnWidth: CGFloat? = 100

    var body: some View {
        let r = rate ?? Rate(down: 0, up: 0)
        HStack(spacing: 12) {
            Text(verbatim: "↓ \(RateFormat.text(r.down))").frame(width: columnWidth, alignment: .leading)
            Text(verbatim: "↑ \(RateFormat.text(r.up))").frame(width: columnWidth, alignment: .leading)
        }
        .font(font.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("download \(RateFormat.spoken(r.down)), upload \(RateFormat.spoken(r.up))",
                                 comment: "Combined rate accessibility label"))
    }
}
