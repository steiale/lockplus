import AppKit
import LPModel
import SwiftUI
import Testing
@testable import LockPlus

/// Renders key screens offscreen (an `NSHostingView` in a borderless window, so AppKit-backed controls draw too)
/// and writes PNGs for review (copied to `native/Tools/ui/Screenshots/` by the script). Opt-in only, so the Unit plan never waits on the
/// window server: `native/Tools/ui/render-screenshots.sh` (sets `TEST_RUNNER_LP_RENDER_SCREENSHOTS=1`).
@MainActor @Suite("Screenshots", .serialized,
                  .enabled(if: ProcessInfo.processInfo.environment["LP_RENDER_SCREENSHOTS"] == "1", "opt-in: LP_RENDER_SCREENSHOTS=1"),
                  .timeLimit(.minutes(1)))
struct ScreenshotTests {
    /// Written under ~/Library/Caches: the unsigned test host has no access to the repo volume (a TCC prompt would
    /// block `mkdir` forever). `render-screenshots.sh` copies the files to `native/Tools/ui/Screenshots/`.
    static var outputDirectory: URL? {
        guard ProcessInfo.processInfo.environment["LP_RENDER_SCREENSHOTS"] == "1" else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LockPlusUIScreenshots")
    }

    static func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String,
                                configure: (NSView) -> Void = { _ in }) async throws -> NSBitmapImageRep {
        // The test host can't become active without a user gesture, so this window is never key: AppKit-backed
        // controls draw their inactive look (a grey switch track, unemphasized selection). Verified 2026-10-26.
        // The app's scenes apply `lpTypography()` at their roots; the harness renders the views below that root.
        let host = NSHostingView(rootView: view.lpTypography().foregroundStyle(Color(nsColor: .labelColor)).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = RenderWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))             // let SwiftUI settle; yields the main actor
        host.layoutSubtreeIfNeeded()
        configure(host)
        RenderFixups.apply(to: host, dark: dark)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        if let dir = outputDirectory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // German runs (render-screenshots.sh --de, `-testLanguage de`) get a "-de" suffix.
            let lang = (Locale.preferredLanguages.first ?? "en").hasPrefix("de") ? "-de" : ""
            let file = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light")\(lang).png")
            try rep.representation(using: .png, properties: [:])?.write(to: file)
        }
        return rep
    }

    /// A rendered image isn't a flat fill.
    static func hasContent(_ rep: NSBitmapImageRep) -> Bool {
        var seen = Set<Int>()
        let step = max(rep.pixelsWide / 160, 1)       // fine enough to hit text in a short banner
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    seen.insert(Int(c.redComponent * 15) << 8 | Int(c.greenComponent * 15) << 4 | Int(c.blueComponent * 15))
                }
            }
        }
        return seen.count > 3
    }

    /// Both appearances of one surface (every image has a light and a dark variant).
    static func renderBoth<V: View>(_ view: V, size: CGSize, name: String) async throws {
        for dark in [false, true] {
            #expect(hasContent(try await render(view, size: size, dark: dark, name: name)), "\(name) \(dark ? "dark" : "light")")
        }
    }

    /// The view's natural height at `width` (at least `minHeight`), for surfaces whose height depends on the copy.
    static func fittedSize<V: View>(_ view: V, width: CGFloat, minHeight: CGFloat = 0) -> CGSize {
        let host = NSHostingView(rootView: view.lpTypography().frame(width: width))
        return CGSize(width: width, height: max(ceil(host.fittingSize.height), minHeight))
    }

    static func renderFitted<V: View>(_ view: V, width: CGFloat, minHeight: CGFloat = 0, name: String) async throws {
        try await renderBoth(view, size: fittedSize(view, width: width, minHeight: minHeight), name: name)
    }

    @Test("Main window, protected")
    func mainProtected() async throws {
        try await Self.renderBoth(MainView(selection: .profile(PreviewData.workID)).environment(UIEnvironment.preview(row: "6")),
                                  size: CGSize(width: 920, height: 620), name: "main-protected")
    }

    /// Launch with profiles and nothing selected: the window resolves a profile, never the empty-library copy.
    @Test("Main window at launch, profiles, no selection")
    func mainLaunch() async throws {
        try await Self.renderBoth(MainView().environment(UIEnvironment.preview(row: "6")),
                                  size: CGSize(width: 920, height: 620), name: "main-launch")
    }

    /// UI-M18: the offscreen capture drops sidebar vibrancy (selected and plain rows come out unreadable in dark), so
    /// the selected row is rendered on its own: the accent selection with `backgroundProminence(.increased)`, which is
    /// what the List gives a selected row. Its text must follow (no forced foreground styles).
    @Test("Sidebar rows, selected and not, without vibrancy")
    func sidebarRows() async throws {
        let env = UIEnvironment.preview(row: "10")
        let rows = SidebarRowsSample(profiles: Array(env.profiles.profiles.prefix(2)), selected: PreviewData.workID)
            .padding(10)
            .frame(width: 260)
            .background(.background)
            .environment(env)
        try await Self.renderBoth(rows, size: CGSize(width: 260, height: 130), name: "sidebar-rows")
    }

    /// All four fixture profiles with their subtitles, the connected one pinned on top as in the real sidebar.
    @Test("Sidebar rows, all profiles, connected and disconnected", arguments: ["6", "15"])
    func sidebarRowsAll(row: String) async throws {
        let env = UIEnvironment.preview(row: row, profile: PreviewData.work)
        let rows = SidebarRowsSample(profiles: env.profiles.profiles, selected: PreviewData.nasID)
            .padding(10)
            .frame(width: 260)
            .background(.background)
            .environment(env)
        try await Self.renderBoth(rows, size: CGSize(width: 260, height: 190), name: "sidebar-rows-all-row\(row)")
    }

    @Test("Locked profiles (§6.8)")
    func lockedProfiles() async throws {
        let env = UIEnvironment.preview(row: "15", profiles: [])
        env.profiles.locked = ["Work", "Home NAS", "Acme"]
        let view = LockedProfilesView(names: env.profiles.locked ?? []).frame(maxWidth: .infinity, maxHeight: .infinity).environment(env).background(BrandCanvasBackground())
        try await Self.renderBoth(view, size: CGSize(width: 640, height: 460), name: "locked-profiles")
    }

    @Test("Main window, blocked reconnecting")
    func mainBlocked() async throws {
        try await Self.renderBoth(MainView(selection: .profile(PreviewData.workID)).environment(UIEnvironment.preview(row: "10")),
                                  size: CGSize(width: 920, height: 620), name: "main-blocked")
    }

    // Sidebar artifact (verified 2026-10-26): a stock `List(.sidebar)` with plain `Text` rows, no LockPlus code, renders
    // the same black selected row with invisible text (Screenshots/harness-control-sidebar-light.png). Sidebar
    // selection and labels are vibrant, composited by the window server, which `cacheDisplay` doesn't capture. The
    // control render is not kept as a test: a second NavigationSplitView host in the same process stalls in layout.

    @Test("Editor, WireGuard and OpenVPN")
    func editor() async throws {
        let env = UIEnvironment.preview(row: "15")
        let wg = EditorModel.preview(kind: .wireGuard, text: EditorPreviewText.wireGuard)
        try await Self.renderBoth(NavigationStack { EditorWindow(model: wg) }.environment(env),
                                  size: CGSize(width: 900, height: 460), name: "editor-wireguard")
        let ovpn = EditorModel.preview(kind: .openVPN, text: EditorPreviewText.openVPN, name: "Office")
        ovpn.caretLine = 4
        try await Self.renderBoth(NavigationStack { EditorWindow(model: ovpn) }.environment(env),
                                  size: CGSize(width: 900, height: 460), name: "editor-openvpn")
    }

    @Test("Editor, private key revealed, and a new profile")
    func editorMore() async throws {
        let env = UIEnvironment.preview(row: "15")
        let revealed = EditorModel.preview(kind: .wireGuard, text: EditorPreviewText.wireGuard, revealed: true)
        try await Self.renderBoth(NavigationStack { EditorWindow(model: revealed) }.environment(env),
                                  size: CGSize(width: 900, height: 460), name: "editor-wireguard-key-revealed")
        let fresh = EditorModel(target: .new(.wireGuard))
        try await Self.renderBoth(NavigationStack { EditorWindow(model: fresh) }.environment(env),
                                  size: CGSize(width: 900, height: 460), name: "editor-new-profile")
    }

    @Test("Glyph sheet at 16 px and 48 pt")
    func glyphSheet() async throws {
        let view = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                ForEach(GlyphState.allCases, id: \.self) { s in
                    VStack(spacing: 4) {
                        LockGlyph(state: s, size: 40)
                        LockGlyph(state: s, size: 13, colored: false)
                        Text(verbatim: s.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 70)
                }
            }
        }
        .padding(16)
        .background(.background)
        try await Self.renderBoth(view, size: CGSize(width: 660, height: 120), name: "glyphs")
    }
}


/// The List's selected-row treatment without the vibrant sidebar material (see `sidebarRows`).
private struct SidebarRowsSample: View {
    let profiles: [ProfileItem]
    let selected: ProfileItem.ID

    var body: some View {
        VStack(spacing: 2) {
            ForEach(profiles) { p in row(p, selected: p.id == selected) }
        }
    }

    @ViewBuilder private func row(_ p: ProfileItem, selected: Bool) -> some View {
        let fill: Color = selected ? Color.accentColor : .clear
        ProfileRow(profile: p)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .environment(\.backgroundProminence, selected ? .increased : .standard)
            .environment(\.controlActiveState, .key)   // a key window: offscreen hosting isn't one
    }
}
