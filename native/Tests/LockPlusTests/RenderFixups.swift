import AppKit

/// Offscreen-capture fixups (UI-M18). `cacheDisplay` draws the AppKit view tree without the window server's
/// compositing, so two things the real app gets from it come out wrong in the PNGs:
/// 1. Vibrant text. Inside the sidebar glass and the inspector material, default-styled text (`.primary`, `.secondary`)
///    is blended against the backdrop; without one it renders near-black, in dark mode too. `ScreenshotTests.render`
///    therefore sets an explicit `labelColor` foreground at the root (same colour, not vibrant).
/// 2. The list selection is an `NSVisualEffectView` (material .selection, blending behind window) that renders as a
///    black bar. It is replaced here by the colour the list gives a selected row in a key window (AccentColor, the real selection).
/// The real app is correct (checked on macOS 27 on 2026-11-09: ux-review/real/*.png), so only the renderer compensates.
/// The harness window also reports itself key (`RenderWindow`), so switches and tabs draw their active look.
@MainActor enum RenderFixups {
    static func apply(to root: NSView, dark: Bool) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        walk(root) { v in
            if let effect = v as? NSVisualEffectView, effect.material == .selection, effect.superview != nil {
                replaceSelection(effect, appearance: appearance)
            }
        }
    }

    private static func replaceSelection(_ effect: NSVisualEffectView, appearance: NSAppearance?) {
        var color = NSColor.selectedContentBackgroundColor
        if let named = NSColor(named: "AccentColor") {
            appearance?.performAsCurrentDrawingAppearance { color = NSColor(cgColor: named.cgColor) ?? color }
        }
        let fill = NSView(frame: effect.frame)
        fill.wantsLayer = true
        fill.layer?.backgroundColor = color.cgColor
        fill.layer?.cornerRadius = 10
        fill.layer?.cornerCurve = .continuous
        effect.superview?.addSubview(fill, positioned: .above, relativeTo: effect)
        effect.isHidden = true
    }

    private static func walk(_ view: NSView, _ body: (NSView) -> Void) {
        body(view)
        for child in view.subviews { walk(child, body) }
    }
}

/// A borderless window that reports itself key, so controls draw their active look.
final class RenderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
