import AppKit
import SwiftUI
import Testing
@testable import LockPlus

/// DESIGN §15.1: the seven(+1) state glyphs are distinguishable as 16 px black-on-white template images, and every
/// documented contrast pair (UI-CONCEPT §2.3) holds in light, dark and High Contrast.
@MainActor @Suite("Glyph language (§7.2)")
struct GlyphTests {
    /// Renders a symbol at 16×16 px, black on white, as luminance values 0…1.
    static func pixels(_ name: String, px: Int = 16) throws -> [Double] {
        let image = try #require(LockGlyphImage.template(name, pointSize: CGFloat(px) * 0.8))
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: px, height: px).fill()
        let k = min(CGFloat(px) / image.size.width, CGFloat(px) / image.size.height)
        let w = image.size.width * k, h = image.size.height * k
        let tinted = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r); NSColor.black.set(); r.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: NSRect(x: (CGFloat(px) - w) / 2, y: (CGFloat(px) - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return (0..<px).flatMap { y in (0..<px).map { x in Double(rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) } }
    }

    @Test("Every state symbol exists in the asset catalog", arguments: GlyphState.allCases)
    func symbolExists(state: GlyphState) {
        #expect(NSImage(named: state.symbolName) != nil)
    }

    @Test("Connecting frames exist")
    func framesExist() {
        for name in GlyphState.connectingFrames { #expect(NSImage(named: name) != nil, "\(name)") }
    }

    /// The status item can't jump: it uses one fixed canvas (`statusCanvas`). The raw symbols only need to be close:
    /// macOS's rasterisation differs by build (CI's 27.0.1 image drew `paused` 18 pt wide, 19 pt here), and NSMenu
    /// aligns titles after its widest image, so 1 pt never moves a menu row.
    @Test("All states have about one width (within 1 pt)")
    func sameWidth() throws {
        let widths = try GlyphState.allCases.map { try #require(LockGlyphImage.template($0, pointSize: 15)).size.width }
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1.0, "\(widths)")
    }

    @Test("Status-item images share one canvas (no vertical jump between states)")
    func statusCanvas() throws {
        let names = GlyphState.allCases.map(\.symbolName) + GlyphState.connectingFrames
        let sizes = try names.map { try #require(LockGlyphImage.statusTemplate($0, pointSize: 15)).size }
        #expect(Set(sizes.map { "\($0.width)x\($0.height)" }).count == 1, "\(sizes)")
    }

    /// Review S-12.02 / S-6.02: the lock sat left of centre because the canvas reserved the badge's room on the right.
    @Test("The lock body is centred in the status-item canvas, every badge stays inside it", arguments: [CGFloat(15), 13])
    func statusCentred(pointSize: CGFloat) throws {
        let body = try #require(LockGlyphImage.statusTemplate(.protected, pointSize: pointSize))
        let span = try #require(LockGlyphImage.inkSpan(body))
        #expect(abs((span.lowerBound + span.upperBound) / 2 - body.size.width / 2) <= 0.5, "\(span) in \(body.size.width)")
        for state in GlyphState.allCases {
            // Nothing clipped: no ink touches the canvas edges (the badge's room is inside the canvas).
            let canvas = try #require(LockGlyphImage.statusTemplate(state, pointSize: pointSize))
            let ink = try #require(LockGlyphImage.inkSpan(canvas))
            #expect(ink.lowerBound > 0 && ink.upperBound < canvas.size.width, "\(state): \(ink) in \(canvas.size.width)")
        }
    }

    /// Owner review 2026-11-10: the hero's connect ring sat right of the lock (centred on the symbol frame, which
    /// reserves the badge's room). Renders the hero setup in SwiftUI, lock red and ring blue, and compares centres.
    @Test("The connect ring is centred on the closed lock", arguments: [CGFloat(44), 32])
    func ringCentredOnLock(size: CGFloat) throws {
        let view = Image(GlyphState.protected.symbolName).font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.monochrome).foregroundStyle(Color(red: 1, green: 0, blue: 0))
            .overlay {
                Circle().stroke(Color(red: 0, green: 0, blue: 1), lineWidth: 2)
                    .frame(width: size * 1.6, height: size * 1.6).offset(x: LockGlyph.ringOffsetX(size: size))
            }
            .padding(size)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        let cg = try #require(renderer.cgImage)
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func centre(_ pick: (Int) -> Bool) throws -> (x: Double, y: Double) {
            var box = (w, -1, h, -1)
            for y in 0..<h { for x in 0..<w where pick(4 * (y * w + x)) { box = (min(box.0, x), max(box.1, x), min(box.2, y), max(box.3, y)) } }
            try #require(box.1 >= 0)
            return (Double(box.0 + box.1 + 1) / 8, Double(box.2 + box.3 + 1) / 8)
        }
        let lock = try centre { px[$0 + 3] > 60 && px[$0] > 150 && px[$0 + 2] < 100 }
        let ring = try centre { px[$0 + 3] > 60 && px[$0 + 2] > 150 && px[$0] < 100 }
        #expect(abs(ring.x - lock.x) <= 0.5 && abs(ring.y - lock.y) <= 0.5, "ring \(ring) vs lock \(lock) at \(size) pt")
    }

    /// The 16 px shape test: every pair differs in a meaningful number of pixels (mean absolute difference).
    @Test("Each pair of states is distinguishable at 16 px in grayscale")
    func distinguishableAt16px() throws {
        let states = GlyphState.allCases
        let images = try states.map { try Self.pixels($0.symbolName) }
        for i in states.indices {
            for j in states.indices where j > i {
                let diff = zip(images[i], images[j]).map { abs($0 - $1) }.reduce(0, +)
                // ≥ 6 px worth of full black/white difference out of 256.
                #expect(diff >= 6, "\(states[i]) vs \(states[j]): \(diff)")
            }
        }
    }
}

@MainActor @Suite("Contrast (§2.3, WCAG 2.2 AA)")
struct ContrastTests {
    enum Mode: String, CaseIterable, CustomTestStringConvertible {
        case light, dark, lightHC, darkHC
        var testDescription: String { rawValue }
        var appearance: NSAppearance {
            switch self {
            case .light: NSAppearance(named: .aqua)!
            case .dark: NSAppearance(named: .darkAqua)!
            case .lightHC: NSAppearance(named: .accessibilityHighContrastAqua)!
            case .darkHC: NSAppearance(named: .accessibilityHighContrastDarkAqua)!
            }
        }
    }

    /// Resolves a named color (compositing alpha over `background`) in an appearance.
    static func rgb(_ name: String, over background: (Double, Double, Double)? = nil, in mode: Mode) throws -> (Double, Double, Double) {
        let color = try #require(NSColor(named: name))
        var result = (0.0, 0.0, 0.0)
        mode.appearance.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            let a = Double(c.alphaComponent)
            let bg = background ?? (1, 1, 1)
            result = (Double(c.redComponent) * a + bg.0 * (1 - a),
                      Double(c.greenComponent) * a + bg.1 * (1 - a),
                      Double(c.blueComponent) * a + bg.2 * (1 - a))
        }
        return result
    }

    static func luminance(_ c: (Double, Double, Double)) -> Double {
        func ch(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.0) + 0.7152 * ch(c.1) + 0.0722 * ch(c.2)
    }

    static func ratio(_ fg: String, on bg: String, in mode: Mode) throws -> Double {
        let b = try rgb(bg, in: mode)
        let f = try rgb(fg, over: b, in: mode)
        let (l1, l2) = (luminance(f), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Text pairs need 4.5:1; glyph/stroke pairs need 3:1.
    static let textPairs: [(String, String)] = [
        ("lp.label", "lp.canvas"), ("lp.label", "lp.card"), ("lp.label2", "lp.canvas"), ("lp.label2", "lp.card"),
        ("lp.sage", "lp.canvas"), ("lp.transitionText", "lp.canvas"), ("lp.attentionText", "lp.canvas"),
        ("lp.criticalText", "lp.card"), ("lp.criticalText", "lp.canvas"), ("lp.tx", "lp.canvas"),
        ("lp.connectLabel", "lp.connectFill"), ("lp.label", "lp.grouped"),
        // Activity and Diagnostics sit on `lp.panel` (pre-release review LOW).
        ("lp.label", "lp.panel"), ("lp.label2", "lp.panel"),
        // Editor syntax on the editor background (§6.9).
        ("lp.syntaxSection", "lp.sunken"), ("lp.syntaxKey", "lp.sunken"), ("lp.syntaxValue", "lp.sunken"),
        ("lp.syntaxNumber", "lp.sunken"), ("lp.syntaxComment", "lp.sunken"), ("lp.label", "lp.sunken"),
    ] + pastelTextPairs
    /// Pastel surfaces (§2.2a): their text inks hold 4.5:1 on every one.
    static let pastelSurfaces = ["lp.pastelSage", "lp.pastelAmber", "lp.pastelRose", "lp.pastelTeal", "lp.pastelYellow"]
    static let pastelTextPairs: [(String, String)] = pastelSurfaces.flatMap { [("lp.onPastel", $0), ("lp.onPastel2", $0)] }
    /// Marks on canvas surfaces and on their own pastel fill.
    static let pastelMarkPairs: [(String, String)] = ["lp.softSage", "lp.softAmber", "lp.softRose", "lp.softTeal", "lp.softYellow"]
        .flatMap { [($0, "lp.canvas"), ($0, "lp.grouped"), ($0, "lp.card")] }
        + [("lp.softSage", "lp.pastelSage"), ("lp.softAmber", "lp.pastelAmber"), ("lp.softRose", "lp.pastelRose")]
        + [("lp.softSage", "lp.panel"), ("lp.softAmber", "lp.panel"), ("lp.softRose", "lp.panel")]
    static let glyphPairs: [(String, String)] = [
        ("lp.stroke", "lp.canvas"), ("lp.stroke", "lp.card"), ("lp.transition", "lp.canvas"), ("lp.attention", "lp.canvas"),
        ("lp.critical", "lp.card"), ("lp.protected", "lp.card"), ("lp.sage", "lp.grouped"), ("lp.rx", "lp.card"),
    ] + pastelMarkPairs

    @Test("Text pairs ≥ 4.5:1", arguments: Mode.allCases)
    func text(mode: Mode) throws {
        for (fg, bg) in Self.textPairs {
            let r = try Self.ratio(fg, on: bg, in: mode)
            #expect(r >= 4.5, "\(fg) on \(bg) in \(mode): \(String(format: "%.2f", r))")
        }
    }

    @Test("Glyph and meaningful stroke pairs ≥ 3:1", arguments: Mode.allCases)
    func glyphs(mode: Mode) throws {
        for (fg, bg) in Self.glyphPairs {
            let r = try Self.ratio(fg, on: bg, in: mode)
            #expect(r >= 3, "\(fg) on \(bg) in \(mode): \(String(format: "%.2f", r))")
        }
    }

    @Test("White on AccentColor ≥ 4.5:1 (prominent buttons, selection)")
    func accent() throws {
        for mode in Mode.allCases {
            let bg = try Self.rgb("AccentColor", in: mode)
            let r = (1.05) / (Self.luminance(bg) + 0.05)
            #expect(r >= 4.5, "\(mode): \(r)")
        }
    }

    /// The protocol badge on a selected sidebar row (pre-release review LOW): `onPastel` on `lp.canvas` at 55 % over
    /// the real selection, `AccentColor` (ProfileRow.badgeFill).
    @Test("Selected-row badge: onPastel on canvas 55 % over the AccentColor selection ≥ 4.5:1", arguments: Mode.allCases)
    func selectedBadge(mode: Mode) throws {
        let sel = try Self.rgb("AccentColor", in: mode)
        let canvas = try Self.rgb("lp.canvas", in: mode)
        let a = 0.55
        let badge = (canvas.0 * a + sel.0 * (1 - a), canvas.1 * a + sel.1 * (1 - a), canvas.2 * a + sel.2 * (1 - a))
        let ink = try Self.rgb("lp.onPastel", over: badge, in: mode)
        let (l1, l2) = (Self.luminance(ink), Self.luminance(badge))
        let r = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        #expect(r >= 4.5, "\(mode): \(String(format: "%.2f", r))")
    }

    /// The text field boundary (WCAG 1.4.11). The soft `lp.fieldBorder` is the owner's decision (UI-CONCEPT §2.5,
    /// review S-4.04: "more subtle", no grey block) and stays under 3:1 on purpose; the field is still identified by its
    /// label, its fill and the 2 pt accent focus ring. Under Increase Contrast the border is `lp.stroke`, which holds 3:1
    /// against the field fill and the window surfaces (pre-release review LOW: tested, not assumed).
    @Test("Field boundary: lp.stroke ≥ 3:1 under Increase Contrast; the soft border stays visible", arguments: Mode.allCases)
    func fieldBorder(mode: Mode) throws {
        if mode == .lightHC || mode == .darkHC {
            for bg in ["lp.canvas", "lp.card", "lp.panel"] {
                let fieldFill = try Self.rgb("lp.field", over: try Self.rgb(bg, in: mode), in: mode)
                let stroke = try Self.rgb("lp.stroke", over: fieldFill, in: mode)
                let (l1, l2) = (Self.luminance(stroke), Self.luminance(fieldFill))
                let r = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
                #expect(r >= 3, "lp.stroke on lp.field over \(bg) in \(mode): \(String(format: "%.2f", r))")
            }
        }
        // The soft border is a real, visible line (not merged into the fill): ≥ 1.3:1 against the field.
        let fieldFill = try Self.rgb("lp.field", over: try Self.rgb("lp.canvas", in: mode), in: mode)
        let border = try Self.rgb("lp.fieldBorder", over: fieldFill, in: mode)
        let (l1, l2) = (Self.luminance(border), Self.luminance(fieldFill))
        let r = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        #expect(r >= 1.3, "lp.fieldBorder on lp.field in \(mode): \(String(format: "%.2f", r))")
    }

    /// The system window background in an appearance (the surface links and the focus ring sit on).
    static func windowBackground(in mode: Mode) -> (Double, Double, Double) {
        var result = (1.0, 1.0, 1.0)
        mode.appearance.performAsCurrentDrawingAppearance {
            let c = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
            result = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        return result
    }

    static func ratio(_ fg: (Double, Double, Double), _ bg: (Double, Double, Double)) -> Double {
        let (l1, l2) = (luminance(fg), luminance(bg))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// AccentColor (the selection sage) is about 2.9:1 on the dark window, so links and the focus ring use `lp.accentText`.
    @Test("Link text lp.accentText ≥ 4.5:1 on the window background", arguments: Mode.allCases)
    func linkText(mode: Mode) throws {
        let r = Self.ratio(try Self.rgb("lp.accentText", in: mode), Self.windowBackground(in: mode))
        #expect(r >= 4.5, "\(mode): \(String(format: "%.2f", r))")
    }

    @Test("Focus ring lp.accentText ≥ 3:1 on the window background and the field fill", arguments: Mode.allCases)
    func focusRing(mode: Mode) throws {
        let window = Self.windowBackground(in: mode)
        let ring = try Self.rgb("lp.accentText", in: mode)
        #expect(Self.ratio(ring, window) >= 3, "\(mode): \(String(format: "%.2f", Self.ratio(ring, window)))")
        let field = try Self.rgb("lp.field", over: window, in: mode)
        #expect(Self.ratio(ring, field) >= 3, "\(mode) on field: \(String(format: "%.2f", Self.ratio(ring, field)))")
    }

    @Test("Color icon style: navy glyph on every tile ≥ 3:1")
    func trayTiles() throws {
        for tile in ["lp.trayIdle", "lp.trayProtected", "lp.trayAttention"] {
            #expect(try Self.ratio("lp.navy", on: tile, in: .light) >= 3, "\(tile)")
        }
    }
}
