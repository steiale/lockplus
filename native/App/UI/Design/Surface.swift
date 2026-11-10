import SwiftUI

/// The one surface helper (DESIGN §11.8, ref/swiftui-appkit §2.3).
/// Hero and menu header are CONTENT: opaque `lp.card` with a 12 % state tint on every OS, never Liquid Glass
/// (HIG: no glass in the content layer; glass can't sample the glass menu). The app has no custom floating
/// controls, so there is no glass role; toolbar buttons use the system glass styles.
enum LPSurfaceRole: Sendable {
    case heroCard, menuHeader
}

extension View {
    func lpSurface(_ role: LPSurfaceRole, tint: Color? = nil) -> some View {
        modifier(LPSurface(role: role, tint: tint))
    }
}

struct LPSurface: ViewModifier {
    let role: LPSurfaceRole
    let tint: Color?
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: role == .menuHeader ? 10 : 16, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(Color.lp.card)
                    shape.fill((tint ?? .clear).opacity(0.12))
                }
            }
            // Increase Contrast: a 1 pt meaningful stroke around the card (§7.3, §8.2).
            .overlay { shape.strokeBorder(Color.lp.stroke, lineWidth: contrast == .increased ? 1 : 0) }
    }
}

/// Grouped rows under a tile (§2.5, draft 8.3, review S-8.17): tables sit on `lp.panel`, a navy between the canvas
/// and the hero card in dark mode, so the rows below a blue tile stay in the tile's family instead of the system's
/// grey. Light mode keeps the system table's white. Activity and Diagnostics use it.
struct LPPanel: ViewModifier {
    @Environment(\.lpPanelSurfaces) private var enabled

    func body(content: Content) -> some View {
        if enabled {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            // The table's own row fills are the system grey (every other row); without them the rows sit on the panel.
            content
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                .background(Color.lp.panel, in: shape)
                .clipShape(shape)
        } else {
            content
        }
    }
}

extension View {
    func lpPanel() -> some View { modifier(LPPanel()) }
}

extension EnvironmentValues {
    /// Only the review's before/after render (S-8.24) turns this off, to show the system grey next to `lp.panel`.
    @Entry var lpPanelSurfaces = true
}

/// The detail column background: navy canvas in dark mode, the light canvas in light mode (§2.5). Never applied to
/// the sidebar `List`.
struct BrandCanvasBackground: View {
    var body: some View {
        Color.lp.canvas.ignoresSafeArea()
    }
}

/// Section header with the heading trait for VoiceOver's Headings rotor (§6.4, §8.2).
struct SectionHeading: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View {
        Text(title).accessibilityAddTraits(.isHeader)
    }
}
