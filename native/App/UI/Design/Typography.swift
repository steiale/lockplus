import AppKit
import SwiftUI

/// The one typography definition (UI-CONCEPT §2.4): the whole UI is set in SF Mono, the system monospaced design.
/// Sizes and weights keep the system hierarchy (`.title`, `.headline`, `.body`, `.caption`, ...); only the design
/// changes. SwiftUI: apply `lpTypography()` once at each root (scene content, hosting views, the render harness);
/// everything below inherits it, sheets included. AppKit-drawn text (NSMenu items, the status item label, text views)
/// takes its font from `LPTypography.nsFont`. Views never name a design themselves.
enum LPTypography {
    static let design: Font.Design = .monospaced

    static func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Fixed-width digits are inherent to the design; the status item label and gutters use the same font.
    static func nsFont(textStyle: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        nsFont(size: NSFont.preferredFont(forTextStyle: textStyle).pointSize, weight: weight)
    }

    /// NSMenu items: the menu font's point size in SF Mono.
    static func menuFont(weight: NSFont.Weight = .regular) -> NSFont {
        nsFont(size: NSFont.menuFont(ofSize: 0).pointSize, weight: weight)
    }
}

extension View {
    /// Sets SF Mono for this view tree. Call at roots only.
    func lpTypography() -> some View { fontDesign(LPTypography.design) }
}
