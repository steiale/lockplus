import Observation
import SwiftUI

/// Everything the menu header shows, as one Equatable value: setting an equal snapshot doesn't notify (Swift 6.2
/// Observation), so the header re-renders only when something visible changed.
struct MenuHeaderSnapshot: Equatable, Sendable {
    var glyph: GlyphState = .unprotected
    var tint: StateTint = .none
    var title = ""
    var message: String?
    var detail: String?
    var isOn = false
    var toggleEnabled = true
    var showsRates = false
    var rate: Rate?
    var samples: [RateSample] = []
    /// "02:14:07" while connected; recomputed on each stats tick (no clock timer, DESIGN §11.3).
    var clock: String?
}

/// The only thing the header reads (DESIGN §11.3).
@MainActor @Observable final class MenuHeaderModel {
    var snapshot = MenuHeaderSnapshot()
    @ObservationIgnored var onToggle: (Bool) -> Void = { _ in }

    init(snapshot: MenuHeaderSnapshot = MenuHeaderSnapshot()) {
        self.snapshot = snapshot
    }

    /// Reads the environment (inside `withObservationTracking`) and publishes a new snapshot.
    func refresh(from env: UIEnvironment, now: Date = Date()) {
        let c = env.connection.condition
        let copy = c.headerCopy(for: env.conditionContext, now: now)
        var s = MenuHeaderSnapshot()
        s.glyph = c.glyph
        s.tint = c.heroTint
        s.title = copy.title
        s.message = copy.message
        s.detail = copy.detail
        s.isOn = c.isActive
        // Row 12a: Cancel is a standard item; switching on would be ignored (review 5 §3).
        s.toggleEnabled = !(c == .disconnecting) && (env.conditionProfile != nil) && !{ if case .startHeld = c { true } else { false } }()
        if c.showsRateLabel {
            s.showsRates = true
            s.rate = env.stats.current
            s.samples = Array(env.stats.menuSamples)
            if let since = env.connection.connectedSince {
                s.clock = DurationFormat.clock(now.timeIntervalSince(since))
            }
        }
        snapshot = s
    }
}

/// Item 0 of the status menu: a live SwiftUI view in an `NSMenuItem.view` (UI-CONCEPT §6.2, S15).
/// Width fixed at `width`; height follows the content: no line is ever truncated, every line wraps as far as its text
/// needs (review 2026-11-09). Not an accessibility element: the switch and the facts are duplicated by standard items.
struct MenuHeaderView: View {
    /// Wide enough for the widest standard item in SF Mono (German "Systemeinstellungen öffnen…", "Enter Code for
    /// <name>…") and two-line German titles; the menu is at least this wide.
    static let width: CGFloat = 340

    let model: MenuHeaderModel

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                LockGlyph(state: s.glyph, size: 28)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title)
                        .font(.headline)
                        .foregroundStyle(s.glyph.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = subtitle(s) {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail = s.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Toggle(isOn: Binding(get: { s.isOn }, set: { model.onToggle($0) })) {
                    Text("Protection", comment: "Menu header switch label (hidden)")
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!s.toggleEnabled)
            }
            if s.showsRates {
                RatePair(rate: s.rate, font: .callout)
                    .padding(.leading, 46)
                SparklineCanvas(samples: s.samples)
                    .frame(height: 28)
                    .padding(.leading, 46)
            }
        }
        .padding(10)
        .lpSurface(.menuHeader, tint: s.tint.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: Self.width)
        .lpTypography()
    }

    private func subtitle(_ s: MenuHeaderSnapshot) -> String? {
        guard let message = s.message else { return s.clock }
        guard let clock = s.clock else { return message }
        return [message, clock].joined(separator: " · ")
    }
}
