import AppKit
import SwiftUI

/// The state glyph (UI-CONCEPT §7.1–§7.2, DESIGN §11.8). Hidden from VoiceOver: the state WORD next to it carries
/// the meaning. "The shackle closes" is Magic Replace between the custom symbols (shared layer structure; Draw
/// Off/On is used automatically for draw-annotated layers on 26+). Reduce Motion: 150 ms opacity, no breathe/ring.
struct LockGlyph: View {
    let state: GlyphState
    var size: CGFloat = 44
    var colored = true
    /// One soft sage ring on entering `.protected` (hero only).
    var ringOnConnect = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringVisible = false

    var body: some View {
        Image(state.symbolName)
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.monochrome)
            // Uncoloured: the surrounding foreground (primary by default; white on the sidebar selection).
            .foregroundStyle(colored ? AnyShapeStyle(state.color) : AnyShapeStyle(.foreground))
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.magic(fallback: .downUp)))
            .symbolEffect(.breathe, options: .repeat(.continuous), isActive: state == .connecting && !reduceMotion)
            .animation(reduceMotion ? .linear(duration: 0.15) : .default, value: state)
            .overlay {
                if ringOnConnect && ringVisible && !reduceMotion {
                    Circle()
                        .stroke(Color.lp.protected, lineWidth: 2)
                        .frame(width: size * 1.6, height: size * 1.6)
                        .offset(x: Self.ringOffsetX(size: size))
                        .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
                }
            }
            .onChange(of: state) { old, new in
                guard ringOnConnect, !reduceMotion, new == .protected, old != .protected else { return }
                withAnimation(.easeOut(duration: 0.45)) { ringVisible = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    withAnimation(.easeOut(duration: 0.2)) { ringVisible = false }
                }
            }
            .accessibilityHidden(true)
    }

    /// The closed-lock symbol's canvas reserves room on the right for the badges of the other states, so its frame
    /// centre is right of the lock. Measured in SwiftUI with the shipped symbol (owner review 2026-11-10): the ink
    /// centre sits 5.25 pt left of the frame centre at 44 pt, i.e. 0.119 × the point size, with no vertical error.
    /// `ringCentredOnLock` (DesignTokenTests) re-measures it, so new symbol art can't silently decentre the ring.
    static func ringOffsetX(size: CGFloat) -> CGFloat { -0.119 * size }
}

/// AppKit images of the same symbols for the status item and menu items (template, sized by symbol configuration).
enum LockGlyphImage {
    @MainActor static func template(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        guard let base = NSImage(named: name) else { return nil }
        let img = base.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) ?? base
        img.isTemplate = true
        return img
    }

    @MainActor static func template(_ state: GlyphState, pointSize: CGFloat) -> NSImage? {
        template(state.symbolName, pointSize: pointSize)
    }

    /// For the status item: every state on one fixed canvas with a shared baseline. Symbol images are sized to their
    /// ink, and badges hang below the baseline, so without this the body would jump vertically between states
    /// (the button centres its image). The lock BODY is centred horizontally on the canvas (§6.1, review S-12.02):
    /// the canvas is symmetric around the body's centre and wide enough for the badge on the right, so the lock never
    /// sits left of centre in the status item.
    @MainActor static func statusTemplate(_ name: String, pointSize: CGFloat) -> NSImage? {
        guard let img = template(name, pointSize: pointSize) else { return nil }
        return place(img, in: statusBox(pointSize))
    }

    @MainActor private static func place(_ img: NSImage, in box: Box) -> NSImage {
        let out = NSImage(size: box.size, flipped: false) { _ in
            img.draw(in: NSRect(x: box.originX, y: box.baseline - img.alignmentRect.minY, width: img.size.width, height: img.size.height))
            return true
        }
        out.isTemplate = true
        out.accessibilityDescription = nil
        return out
    }

    @MainActor static func statusTemplate(_ state: GlyphState, pointSize: CGFloat) -> NSImage? {
        statusTemplate(state.symbolName, pointSize: pointSize)
    }

        private struct Box { let size: NSSize; let baseline: CGFloat; let originX: CGFloat }
    @MainActor private static var boxes: [CGFloat: Box] = [:]

    @MainActor private static func statusBox(_ pointSize: CGFloat) -> Box {
        if let b = boxes[pointSize] { return b }
        let images = (GlyphState.allCases.map(\.symbolName) + GlyphState.connectingFrames)
            .compactMap { template($0, pointSize: pointSize) }
        let baseline = images.map(\.alignmentRect.minY).max() ?? 0
        let top = images.map { $0.size.height - $0.alignmentRect.minY }.max() ?? 0
        let width = images.map(\.size.width).max() ?? 0
        // The body's centre comes from the closed lock without a badge (`GlyphState.protected`); the extent from every
        // state's ink (badges reach furthest right, open shackles furthest left). Measured on the PLACED images: symbol
        // images don't always land exactly where `draw(in:)` puts them, so raw-image coordinates would be off.
        let height = ceil(baseline + top)
        var box = Box(size: NSSize(width: width, height: height), baseline: baseline, originX: 0)
        guard let body = template(GlyphState.protected.symbolName, pointSize: pointSize) else { return box }
        // 1. Measure on a canvas with room on both sides, so no ink is clipped.
        let pad: CGFloat = 4
        let wide = Box(size: NSSize(width: width + pad * 2, height: height), baseline: baseline, originX: pad)
        let inks = images.compactMap { inkSpan(place($0, in: wide)) }
        guard let b = inkSpan(place(body, in: wide)), let left = inks.map(\.lowerBound).min(),
              let right = inks.map(\.upperBound).max() else { return box }
        let centre = (b.lowerBound + b.upperBound) / 2
        // 2. The narrowest symmetric canvas around the body's centre; checked once placed, widened if it clips.
        var half = ceil(max(centre - left, right - centre) + 0.25)
        for _ in 0..<3 {
            box = Box(size: NSSize(width: half * 2, height: height), baseline: baseline, originX: pad + half - centre)
            let placed = images.compactMap { inkSpan(place($0, in: box)) }
            if placed.allSatisfy({ $0.lowerBound > 0 && $0.upperBound < half * 2 }) { break }
            half += 1
        }
        boxes[pointSize] = box
        return box
    }

    /// The horizontal extent of an image's ink in points (rasterised at 4 px per point), nil when it has none.
    @MainActor static func inkSpan(_ img: NSImage) -> ClosedRange<CGFloat>? {
        let scale: CGFloat = 4
        let w = Int(ceil(img.size.width * scale)), h = Int(ceil(img.size.height * scale))
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        var minX = Int.max, maxX = Int.min
        for y in 0..<h {
            let row = data + y * rep.bytesPerRow
            for x in 0..<w where row[x * 4 + 3] > 40 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard minX <= maxX else { return nil }
        return CGFloat(minX) / scale...CGFloat(maxX + 1) / scale
    }

    /// The Color icon style (§6.1): a whole-background tile with a navy glyph. Never the only signal: the glyph shape
    /// is the same as in the monochrome style.
    @MainActor static func colorTile(_ state: GlyphState, pointSize: CGFloat) -> NSImage? {
        guard let glyph = statusTemplate(state, pointSize: pointSize) else { return nil }
        let tile: NSColor = switch state {
        case .protected: .lp.trayProtected
        case .blocked, .attention, .paused, .errorStopped: .lp.trayAttention
        case .unprotected, .connecting, .reasserting: .lp.trayIdle
        }
        let pad: CGFloat = 3
        let size = NSSize(width: glyph.size.width + pad * 2, height: max(glyph.size.height + 2, 18))
        let image = NSImage(size: size, flipped: false) { rect in
            tile.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let navyGlyph = NSImage(size: glyph.size, flipped: false) { r in
                glyph.draw(in: r)
                NSColor.lp.navy.set()
                r.fill(using: .sourceAtop)
                return true
            }
            navyGlyph.draw(in: NSRect(x: pad, y: (rect.height - glyph.size.height) / 2,
                                      width: glyph.size.width, height: glyph.size.height))
            return true
        }
        image.isTemplate = false
        return image
    }
}
