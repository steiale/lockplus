import AppKit
import SwiftUI

/// Where the status item is on screen (onboarding step 5, UI-CONCEPT §6.14). `MenuBarController` registers itself;
/// nothing else needs wiring. There's no reliable "hidden" signal on 27 (§6.1), so the frame is only trusted when
/// the button's window is on a screen, inside the menu bar strip, and not stacked under the notch overflow.
@MainActor enum StatusItemLocation {
    weak static var controller: MenuBarController?

    /// The status item's frame in screen coordinates, or nil when it can't be seen.
    static var visibleFrame: NSRect? {
        guard let c = controller, c.item.isVisible, let window = c.item.button?.window, window.isVisible else { return nil }
        let frame = window.frame
        guard frame.width > 1, let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return nil }
        // Inside the top strip of that screen (the menu bar), fully on screen.
        let menuBarBottom = screen.visibleFrame.maxY
        guard frame.minY >= menuBarBottom - 2, screen.frame.contains(frame) else { return nil }
        // Items pushed behind the notch overflow sit inside the auxiliary area (MacBooks with a camera housing).
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = NSRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
            if notch.width > 0, notch.intersects(frame) { return nil }
        }
        return frame
    }
}

/// A transparent, click-through panel under the status item: an arrow and "LockPlus lives here". When the item
/// can't be located, it explains where to look instead (a sentence in the onboarding sheet, not a floating panel).
@MainActor final class StatusItemCallout {
    private var panel: NSPanel?

    /// Shows the callout and returns true, or returns false when the status item isn't visibly placed.
    @discardableResult
    func show() -> Bool {
        hide()
        guard let frame = StatusItemLocation.visibleFrame else { return false }
        let size = NSSize(width: 220, height: 92)
        let origin = NSPoint(x: min(max(frame.midX - size.width / 2, 8), (NSScreen.main?.frame.maxX ?? frame.maxX) - size.width - 8),
                             y: frame.minY - size.height - 4)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let arrowX = frame.midX - origin.x
        panel.contentView = NSHostingView(rootView: CalloutBubble(arrowX: arrowX).lpTypography())
        panel.orderFrontRegardless()
        self.panel = panel
        return true
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct CalloutBubble: View {
    /// Horizontal position of the arrow tip inside the bubble, pointing at the status item's centre.
    let arrowX: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.lp.softSage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: arrowX - 9, y: bounce ? -4 : 0)
            Text("LockPlus lives here", comment: "Onboarding callout under the menu bar icon")
                .font(.headline)
                .foregroundStyle(Color.lp.connectLabel)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.lp.connectFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(radius: 6, y: 2)
        }
        .padding(8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { bounce = true }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Callout bubble") {
    CalloutBubble(arrowX: 160).frame(width: 220, height: 92)
}
