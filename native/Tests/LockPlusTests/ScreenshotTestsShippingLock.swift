import AppKit
import LPModel
import SwiftUI
import Testing
@testable import LockPlus

/// The shipping lock (V2 Sturdy with a + in the body, owner pick "p2" in review S-12.02): every state in the menu bar
/// (mono and colour tile, with and without rates), as pixels at 15 and 13 pt @1x/@2x, at 40 pt, in the menu header and
/// in the hero, all through the app's real paths (`LockGlyphImage.statusTemplate`, `colorTile`, `LockGlyph`,
/// `MenuHeaderView`, `ProtectionHero`).
extension ScreenshotTests {
    static let candidateStates: [(GlyphState, String)] = [
        (.unprotected, "Not protected"), (.connecting, "Connecting"), (.reasserting, "Reasserting"), (.protected, "Protected"),
        (.blocked, "Blocked"), (.attention, "Needs attention"), (.paused, "Paused"), (.errorStopped, "Stopped, error"),
    ]

    @Test("Shipping lock: menu bar (mono + colour, with and without rates, @1x/@2x pixels at 15 and 13 pt), 40 pt family, menu header, hero")
    func shippingLock() async throws {
        for name in GlyphState.allCases.map(\.symbolName) + GlyphState.connectingFrames {
            #expect(LockGlyphImage.template(name, pointSize: 15) != nil, "\(name) missing from the app's catalog")
        }
        let headerModel = MenuHeaderModel()
        headerModel.refresh(from: UIEnvironment.preview(row: "6", profiles: PreviewData.profiles), now: PreviewData.now)
        let hero = HeroCase(name: "10", row: "10")
        let view = VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "LockPlus lock (shipping)").font(.headline)
                Text(verbatim: "V2 Sturdy with a + in the body (owner pick, S-12.02): heavy strokes, large corner radius, short shackle almost as wide as the body. The + is cut out of filled bodies and sits in the window of outline bodies; next to a badge it moves up and left.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ShippingMenuBarTable()
            ShippingFamilyRow()
            HStack(alignment: .top, spacing: 16) {
                MenuHeaderView(model: headerModel)
                ProtectionHero(profile: hero.profile).environment(hero.makeEnv()).frame(width: 420)
            }
        }
        .padding(18)
        .background(BrandCanvasBackground())
        try await Self.renderFitted(view, width: 940, name: "glyph-shipping-lock")
    }
}

/// Every state as the status item shows it, one column per state: monochrome template (15 pt, as
/// `MenuBarController`), colour tile (13 pt), then the glyph's actual pixels at @1x and @2x for 15 pt (monochrome) and
/// 13 pt (the tile's glyph), enlarged with no smoothing.
private struct ShippingMenuBarTable: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink: NSColor = scheme == .dark ? .white : .black
        let bar = scheme == .dark ? Color(white: 0.17) : Color(white: 0.93)
        let states = ScreenshotTests.candidateStates
        Grid(alignment: .center, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text(verbatim: "")
                ForEach(states, id: \.0) { s in
                    Text(verbatim: s.1).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6).frame(width: 74)
                }
            }
            row("Monochrome") { s in MenuBarStrip { StatusGlyph(state: s) } }
            row("Colour tile") { s in MenuBarStrip { TileGlyph(state: s) } }
            row("Mono + rates") { s in MenuBarStrip { StatusGlyph(state: s, label: "↓1.2M") } }
            row("Tile + rates") { s in MenuBarStrip { TileGlyph(state: s, label: "↓1.2M") } }
            row("15 pt @1x") { s in PixelGlyph(state: s, pointSize: 15, scale: 1, zoom: 3, ink: ink, bar: bar) }
            row("15 pt @2x") { s in PixelGlyph(state: s, pointSize: 15, scale: 2, zoom: 1.5, ink: ink, bar: bar) }
            row("13 pt @1x") { s in PixelGlyph(state: s, pointSize: 13, scale: 1, zoom: 3, ink: ink, bar: bar) }
            row("13 pt @2x") { s in PixelGlyph(state: s, pointSize: 13, scale: 2, zoom: 1.5, ink: ink, bar: bar) }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ cell: @escaping (GlyphState) -> C) -> some View {
        GridRow {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            ForEach(ScreenshotTests.candidateStates, id: \.0) { s in cell(s.0) }
        }
    }
}

/// The 40 pt colour family over the 13 pt monochrome glyph, like the shipping glyph sheet (S-11.01).
private struct ShippingFamilyRow: View {

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ScreenshotTests.candidateStates, id: \.0) { s in
                VStack(spacing: 4) {
                    LockGlyph(state: s.0, size: 40).frame(height: 56)
                    LockGlyph(state: s.0, size: 13, colored: false)
                    Text(verbatim: s.1).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(width: 80)
            }
        }
    }
}

private struct MenuBarStrip<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.horizontal, 8).frame(height: 26)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct StatusGlyph: View {
    let state: GlyphState
    var label: String?
    var body: some View {
        HStack(spacing: 4) {
            if let img = LockGlyphImage.statusTemplate(state, pointSize: 15) {
                Image(nsImage: img).renderingMode(.template).foregroundStyle(.primary)
            }
            if let label { Text(verbatim: label).font(.system(size: 11).monospacedDigit()) }
        }
    }
}

private struct TileGlyph: View {
    let state: GlyphState
    var label: String?
    var body: some View {
        HStack(spacing: 4) {
            if let img = LockGlyphImage.colorTile(state, pointSize: 13) { Image(nsImage: img) }
            if let label { Text(verbatim: label).font(.system(size: 11).monospacedDigit()) }
        }
    }
}

/// The status template (at `pointSize`) rasterised at `scale` pixels per point (what the menu bar draws on a 1x or 2x display),
/// shown `zoom` times larger with nearest-neighbour scaling.
private struct PixelGlyph: View {
    let state: GlyphState
    let pointSize: CGFloat
    let scale: CGFloat
    let zoom: CGFloat
    let ink: NSColor
    let bar: Color

    var body: some View {
        if let img = LockGlyphImage.statusTemplate(state, pointSize: pointSize), let px = Self.raster(img, scale: scale, ink: ink) {
            Image(nsImage: px).resizable().interpolation(.none)
                .frame(width: px.size.width * zoom, height: px.size.height * zoom)
                .padding(4).background(bar)
        }
    }

    @MainActor static func raster(_ img: NSImage, scale: CGFloat, ink: NSColor) -> NSImage? {
        let w = Int(ceil(img.size.width * scale)), h = Int(ceil(img.size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let r = NSRect(x: 0, y: 0, width: img.size.width * scale, height: img.size.height * scale)
        img.draw(in: r)
        ink.set()
        r.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: w, height: h)
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }
}
