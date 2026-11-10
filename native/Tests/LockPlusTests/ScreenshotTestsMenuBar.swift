import AppKit
import LPModel
import SwiftUI
import Testing
@testable import LockPlus

/// Menu bar surfaces. An `NSMenu` can't be snapshotted offscreen (it is drawn by the window server as Liquid Glass),
/// so the full menu is an equivalent: the REAL item list is built by `MenuBarController` (`menuNeedsUpdate`) and drawn
/// by `MenuFacsimile` below; the header is the real `MenuHeaderView`. Row styling is an approximation, the content,
/// order, enablement, checkmarks, subtitles and glyphs are the controller's. The status item itself is drawn the same
/// way from `LockGlyphImage` (the images the controller assigns to the button).
extension ScreenshotTests {
    struct MenuCase: Sendable, CustomTestStringConvertible {
        let name: String
        let row: String
        var tweak: String = ""
        var testDescription: String { name }

        static let all: [MenuCase] = [
            .init(name: "protected", row: "6"),
            .init(name: "protected-pause-submenu", row: "6", tweak: "pause-submenu"),
            .init(name: "not-protected", row: "15"),
            .init(name: "blocked", row: "10"),
            .init(name: "paused", row: "2"),
            .init(name: "preparing", row: "12a"),
            .init(name: "waiting-for-stop", row: "12a-wait"),
            .init(name: "waiting-for-network", row: "12a-nonet"),
            .init(name: "network-restart", row: "12a-netrestart"),
            .init(name: "sign-in-pending", row: "3", tweak: "enter-code"),
            .init(name: "extension-approval", row: "1"),
            .init(name: "update-available", row: "15", tweak: "update"),
            .init(name: "tunnel-component-not-updated", row: "15", tweak: "update-failed"),
            .init(name: "no-network", row: "14"),
            .init(name: "many-profiles", row: "6", tweak: "many"),
            .init(name: "empty-library", row: "15", tweak: "empty"),
            .init(name: "locked-profiles", row: "15", tweak: "locked"),
        ]
    }

    @Test("Full menu bar menu", arguments: MenuCase.all)
    func fullMenu(_ c: MenuCase) async throws {
        var profiles = PreviewData.profiles
        if c.tweak == "empty" || c.tweak == "locked" { profiles = [] }
        if c.tweak == "many" {
            profiles += (1...6).map { i in
                var p = PreviewData.nas; p = ProfileItem(id: UUID(), name: "Extra \(i)", kind: .wireGuard, endpoint: "x\(i).example.net:51820")
                return p
            }
        }
        let env = UIEnvironment.preview(row: c.row, profiles: profiles)
        if c.tweak == "locked" { env.profiles.locked = ["Work", "Home NAS"] }
        if c.tweak == "update" { env.settings.updateAvailable = true }
        if c.tweak == "update-failed" {
            env.connection.inputs.extensionReadiness = .updateFailed
            env.connection.extensionUpdateFailedMessage = ExtensionMapping.updateFailedMessage()
        }
        if c.tweak == "enter-code" { env.connection.pendingPromptProfileName = "Acme" }
        let controller = MenuBarController(env: env)
        defer { controller.remove() }
        let menu = try #require(controller.item.menu)
        controller.menuNeedsUpdate(menu)
        let header = MenuHeaderModel()
        header.refresh(from: env, now: PreviewData.now)
        let rows = menu.items.map(MenuFacsimile.Row.init)
        var sub: [MenuFacsimile.Row]?
        if c.tweak == "pause-submenu" {
            sub = menu.items.first { $0.title == String(localized: "Pause Protection", comment: "Menu submenu") }?.submenu?.items.map(MenuFacsimile.Row.init)
            #expect(sub != nil)
        }
        let view = MenuFacsimile(rows: rows, header: header, submenu: sub).padding(20).background(BrandCanvasBackground())
        try await Self.renderFitted(view, width: MenuFacsimile.panelWidth + (sub == nil ? 40 : 216), name: "menu-full-\(c.name)")
    }

    struct IconCase: Sendable, CustomTestStringConvertible {
        let style: IconStyle
        var testDescription: String { style.rawValue }
    }

    @Test("Menu bar icon, every state, rates off and on", arguments: [IconStyle.monochrome, .color])
    func statusItemIcons(style: IconStyle) async throws {
        let states: [(GlyphState, String)] = [
            (.unprotected, "Not protected"), (.connecting, "Connecting"), (.reasserting, "Reasserting"), (.protected, "Protected"),
            (.blocked, "Blocked"), (.attention, "Needs attention"), (.paused, "Paused"), (.errorStopped, "Stopped, error"),
        ]
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(states, id: \.0) { s in
                HStack(spacing: 14) {
                    StatusItemSample(state: s.0, style: style, label: nil).frame(width: 90, alignment: .leading)
                    Text(verbatim: s.1).frame(width: 130, alignment: .leading)
                    if s.0 == .protected {
                        StatusItemSample(state: s.0, style: style, label: "↓1.2M").frame(width: 110, alignment: .leading)
                        StatusItemSample(state: s.0, style: style, label: "↓1.2M ↑30K").frame(width: 150, alignment: .leading)
                        Text(verbatim: "rates: off · download · both").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .background(.background)
        try await Self.renderFitted(view, width: 640, name: "menubar-icon-\(style.rawValue)")
    }

    /// Notifications are system UI (Notification Center); drawn from `NotificationPolicy.notice`, the exact title and body.
    @Test("Notifications")
    func notifications() async throws {
        let id = PreviewData.workID
        let notices: [(String, ConnectionNotice)] = [
            ("connected", .connected(id)), ("disconnected", .disconnectedByUser(id)), ("reconnected", .reconnectedAfterRestart(id)),
            ("stopped", .stoppedUnexpectedly(id)), ("sign-in", .needsSignIn(id, reconnect: false)), ("new-code", .needsSignIn(id, reconnect: true)),
        ]
        for (name, n) in notices {
            let notice = NotificationPolicy.notice(n, profileName: name == "sign-in" || name == "new-code" ? "Acme" : "Work")
            try await Self.renderFitted(NotificationFacsimile(notice: notice).padding(20).background(BrandCanvasBackground()), width: 420, name: "notification-\(name)")
        }
    }
}

/// A status item button: the glyph image the controller assigns, plus the rate label, on a menu bar strip.
private struct StatusItemSample: View {
    let state: GlyphState
    let style: IconStyle
    let label: String?

    var body: some View {
        HStack(spacing: 4) {
            switch style {
            case .monochrome:
                if let img = LockGlyphImage.statusTemplate(state, pointSize: 15) {
                    Image(nsImage: img).renderingMode(.template).foregroundStyle(.primary)
                }
            case .color:
                if let img = LockGlyphImage.colorTile(state, pointSize: 13) { Image(nsImage: img) }
            }
            if let label { Text(verbatim: label).font(.system(size: 11).monospacedDigit()) }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct NotificationFacsimile: View {
    let notice: UserNotice
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: notice.title).font(.headline)
                Text(verbatim: notice.body).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(verbatim: "LockPlus").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }
}

/// The menu as the controller built it. Not the system's drawing (see the file comment).
struct MenuFacsimile: View {
    struct Row: Identifiable {
        let id = UUID()
        var kind: Kind
        var title = ""
        var subtitle: String?
        var checked = false
        var enabled = true
        var key: String?
        var hasSubmenu = false
        var image: NSImage?
        var bold = false
        enum Kind { case header, separator, section, item }

        init(_ item: NSMenuItem) {
            if item.view != nil { kind = .header }
            else if item.isSeparatorItem { kind = .separator }
            else if item.isSectionHeader { kind = .section }
            else { kind = .item }
            title = item.title
            subtitle = item.subtitle
            checked = item.state == .on
            enabled = item.isEnabled
            hasSubmenu = item.submenu != nil
            image = item.image
            if !item.keyEquivalent.isEmpty {
                key = item.keyEquivalentModifierMask.isEmpty ? "↩" : "⌘" + item.keyEquivalent.uppercased()
            }
            if let a = item.attributedTitle, let f = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { bold = f.fontDescriptor.symbolicTraits.contains(.bold) }
        }
    }

    let rows: [Row]
    let header: MenuHeaderModel
    var submenu: [Row]?

    /// The menu is as wide as its header (`MenuHeaderView.width`) plus the menu's own inset.
    static let panelWidth = MenuHeaderView.width + 32

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            panel(rows, header: true).frame(width: Self.panelWidth)
            if let submenu {
                panel(submenu, header: false).frame(width: 170).padding(.top, 220)
            }
        }
    }

    private func panel(_ rows: [Row], header showHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { r in
                switch r.kind {
                case .header: if showHeader { MenuHeaderView(model: header) }
                case .separator: Divider().padding(.vertical, 4).padding(.horizontal, 8)
                case .section: Text(verbatim: r.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 2)
                case .item: item(r)
                }
            }
        }
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .shadow(radius: 8, y: 3)
    }

    private func item(_ r: Row) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: r.checked ? "✓" : "").frame(width: 14)
            if let img = r.image { Image(nsImage: img).renderingMode(.template) }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: r.title).fontWeight(r.bold ? .bold : .regular)
                if let s = r.subtitle { Text(verbatim: s).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            if let k = r.key { Text(verbatim: k).foregroundStyle(.secondary) }
            if r.hasSubmenu { Text(verbatim: "▸").foregroundStyle(.secondary) }
        }
        .foregroundStyle(r.enabled ? Color.primary : Color.secondary.opacity(0.7))
        .padding(.horizontal, 10).padding(.vertical, 3)
    }
}
