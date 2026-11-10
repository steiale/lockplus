import SwiftUI

/// Inline banners and strips (§6.15). Shape before colour: every severity has its own SF Symbol silhouette.
enum StripSeverity: Sendable {
    case info, attention, critical

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
    /// The icon (a mark, ≥ 3:1 on the pastel fill).
    var tint: Color {
        switch self {
        case .info: Color.lp.softSage
        case .attention: Color.lp.softAmber
        case .critical: Color.lp.softRose
        }
    }
    /// The pastel surface (§2.2a).
    var fill: Color {
        switch self {
        case .info: Color.lp.pastelSage
        case .attention: Color.lp.pastelAmber
        case .critical: Color.lp.pastelRose
        }
    }
    /// Text on the pastel surface: one ink for all severities (4.5:1 and more in every appearance).
    var textColor: Color { Color.lp.onPastel }
}

/// A row of action buttons that never truncates a title: one row when everything fits at its natural width,
/// otherwise the buttons stack vertically (and a single title wraps if even that is too narrow). No button title
/// anywhere gets `.lineLimit(1)` or a truncation mode (`ButtonTruncationTests`).
///
/// Pre-release review LOW: one `Layout` instead of `ViewThatFits` with two copies of the buttons, so a resize that
/// switches between row and stack keeps the same button views (keyboard focus stays on its button).
struct ActionRow<Content: View>: View {
    var trailing = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        StripActionsLayout(trailing: trailing, header: false) { content() }
    }
}

struct InlineStrip<Actions: View>: View {
    let severity: StripSeverity
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        // One line when icon, message and actions fit; otherwise the message wraps over the full width and the
        // actions take their own row (SF Mono and German made long messages squeeze their buttons). One layout over
        // the same views (focus survives a resize), and no actions row at all when the actions are empty (pre-release
        // review LOW: an `if` that produced nothing still left an 8 pt gap).
        StripActionsLayout(trailing: true, header: true) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon
                messageText.fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(severity.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: severity.symbol).foregroundStyle(severity.tint).accessibilityHidden(true)
    }

    private var messageText: some View {
        Text(message).foregroundStyle(severity.textColor).textSelection(.enabled)
    }
}

/// The layout behind `ActionRow` and `InlineStrip`. With `header`, the first subview is the strip's icon and message
/// and the rest are its buttons; otherwise every subview is a button.
/// - Everything fits at its ideal width: one row, first text baselines aligned, buttons 8 pt apart (strip) or 10 pt
///   (ActionRow), pushed to the trailing (or leading) edge.
/// - Otherwise: the header over the full width (it wraps), 8 pt, then the buttons in one row 10 pt apart if they fit,
///   else stacked 8 pt apart, each at most the full width (a single title wraps).
struct StripActionsLayout: Layout {
    var trailing: Bool
    var header: Bool
    static let headerGap: CGFloat = 8, stripButtonGap: CGFloat = 8, rowButtonGap: CGFloat = 10, stackGap: CGFloat = 8

    struct Plan {
        enum Mode { case oneRow, buttonsRow, stacked }
        var mode: Mode
        var frames: [CGRect]
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(ProposedViewSize(width: bounds.width, height: proposal.height), subviews)
        for (i, f) in p.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }

    func plan(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Plan {
        guard !subviews.isEmpty else { return Plan(mode: .oneRow, frames: [], size: .zero) }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let headerCount = header ? 1 : 0
        let buttons = Array(headerCount..<subviews.count)
        let firstGap = header ? Self.headerGap : 0
        let buttonGap = header ? Self.stripButtonGap : Self.rowButtonGap
        let oneRowWidth = (header ? ideal[0].width : 0) + buttons.map { ideal[$0].width }.reduce(0, +)
            + CGFloat(max(0, buttons.count - 1)) * buttonGap + (header && !buttons.isEmpty ? firstGap : 0)
        let width = proposal.width ?? oneRowWidth
        var frames = [CGRect](repeating: .zero, count: subviews.count)

        if oneRowWidth <= width + 0.5 {
            // One row, aligned on the first text baseline.
            let baselines = subviews.indices.map { subviews[$0].dimensions(in: ProposedViewSize(ideal[$0]))[VerticalAlignment.firstTextBaseline] }
            let top = baselines.max() ?? 0
            var height: CGFloat = 0
            for i in subviews.indices { height = max(height, top - baselines[i] + ideal[i].height) }
            let buttonsWidth = buttons.map { ideal[$0].width }.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * buttonGap
            var x: CGFloat = trailing ? width - buttonsWidth : 0
            if header {
                frames[0] = CGRect(origin: CGPoint(x: 0, y: top - baselines[0]), size: ideal[0])
                if !trailing { x = ideal[0].width + firstGap }
            }
            for i in buttons {
                frames[i] = CGRect(origin: CGPoint(x: x, y: top - baselines[i]), size: ideal[i])
                x += ideal[i].width + buttonGap
            }
            // Like the Spacer-filled HStack it replaces: the full width when one is proposed.
            return Plan(mode: .oneRow, frames: frames, size: CGSize(width: proposal.width == nil ? oneRowWidth : width, height: height))
        }

        var y: CGFloat = 0
        if header {
            let h = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            frames[0] = CGRect(x: 0, y: 0, width: width, height: h.height)
            y = h.height + (buttons.isEmpty ? 0 : firstGap)
        }
        let rowWidth = buttons.map { ideal[$0].width }.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * Self.rowButtonGap
        var mode = Plan.Mode.buttonsRow
        if header && rowWidth <= width + 0.5 {
            let rowHeight = buttons.map { ideal[$0].height }.max() ?? 0
            var x = trailing ? width - rowWidth : 0
            for i in buttons {
                frames[i] = CGRect(x: x, y: y + (rowHeight - ideal[i].height) / 2, width: ideal[i].width, height: ideal[i].height)
                x += ideal[i].width + Self.rowButtonGap
            }
            y += rowHeight
        } else {
            mode = .stacked
            for (n, i) in buttons.enumerated() {
                let w = min(ideal[i].width, width)
                let h = subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil))
                frames[i] = CGRect(x: trailing ? width - h.width : 0, y: y, width: min(h.width, width), height: h.height)
                y += h.height + (n == buttons.count - 1 ? 0 : Self.stackGap)
            }
        }
        return Plan(mode: mode, frames: frames, size: CGSize(width: width, height: y))
    }
}

extension InlineStrip where Actions == EmptyView {
    init(severity: StripSeverity, message: String) {
        self.init(severity: severity, message: message) { EmptyView() }
    }
}

/// The diagnostics/result glyph: ✓ ⚠ ✕ ? (§6.11). `?` is never green.
struct ResultGlyph: View {
    let result: DiagnosticCheck.Result
    var body: some View {
        Group {
            switch result {
            case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.lp.softSage)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.softAmber)
            case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.lp.softRose)
            case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(label)
    }
    var label: Text {
        switch result {
        case .pass: Text("Passed", comment: "Check result")
        case .warning: Text("Warning", comment: "Check result")
        case .fail: Text("Failed", comment: "Check result")
        case .unknown: Text("Not tested", comment: "Check result")
        }
    }
}
