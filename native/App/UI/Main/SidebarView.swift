import LPModel
import SwiftUI

/// Sidebar (§6.3): profiles with state glyph + name + the most useful fact, then the sections. No background
/// modifier on the `List`: the floating glass sidebar must show through (§2.5).
struct SidebarView: View {
    @Environment(UIEnvironment.self) private var env
    @Binding var selection: SidebarItem?
    let search: String
    @State private var renaming: ProfileItem.ID?
    @State private var renameText = ""

    var body: some View {
        List(selection: $selection) {
            if env.profiles.profiles.isEmpty {
                Button {
                    ImportPanel.run(env)
                } label: {
                    Label(String(localized: "Import Profile…", comment: "Sidebar row, empty library"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
            } else {
                Section {
                    ForEach(filtered) { p in
                        ProfileRow(profile: p)
                            .tag(SidebarItem.profile(p.id))
                            .contextMenu { contextMenu(p) }
                    }
                } header: {
                    Text("Profiles", comment: "Sidebar section")
                }
            }
            Section {
                SidebarSectionRow(title: String(localized: "Activity", comment: "Sidebar section"), symbol: "clock.arrow.circlepath")
                    .tag(SidebarItem.activity)
                SidebarSectionRow(title: String(localized: "Auto-Connect", comment: "Sidebar section"), symbol: "wifi.circle")
                    .tag(SidebarItem.autoConnect)
                SidebarSectionRow(title: String(localized: "Diagnostics", comment: "Sidebar section"), symbol: "stethoscope")
                    .badge(env.diagnostics.problems.count)
                    .tag(SidebarItem.diagnostics)
                SidebarSectionRow(title: String(localized: "Logs", comment: "Sidebar section"), symbol: "list.bullet.rectangle")
                    .tag(SidebarItem.logs)
            }
        }
        // macOS draws the selection in AccentColor (#4a6e62, the default tint) while the sidebar is focused, grey
        // otherwise; selected rows use white text on the emphasised one (SidebarInk).
        // §6.3 pins the active profile to the top; animate the move so it doesn't jump (UI-L24).
        .animation(.default, value: env.connection.condition.isActive ? env.connection.profileID : nil)
        .safeAreaInset(edge: .bottom) { footer }
        .overlay {
            if !search.isEmpty && filtered.isEmpty && !env.profiles.profiles.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .alert(Text("Rename Profile", comment: "Alert title"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(String(localized: "Name", comment: "Field label"), text: $renameText)
            Button(String(localized: "Rename", comment: "Button")) {
                if let id = renaming { env.actions.rename(id, to: renameText) }
                renaming = nil
            }
            Button(String(localized: "Cancel", comment: "Button"), role: .cancel) { renaming = nil }
        }
        // ⌘⌫ only while the sidebar has focus (never from a text field, UI-H1).
        .focusedValue(\.sidebarProfile, { if case .profile(let id) = selection { id } else { nil } }())
    }

    /// The active profile pins to the top; the rest keep the store's order (§6.3).
    private var filtered: [ProfileItem] {
        var list = env.profiles.profiles
        if let active = env.connection.profileID, env.connection.condition.isActive,
           let i = list.firstIndex(where: { $0.id == active }) {
            let p = list.remove(at: i)
            list.insert(p, at: 0)
        }
        guard !search.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder private func contextMenu(_ p: ProfileItem) -> some View {
        Button(String(localized: "Connect", comment: "Context menu")) { env.gatedConnect(p.id) }
            .disabled(p.connectHeld != nil)            // review 5 §3: the store would ignore it
            .help(p.connectHeld ?? "")
        Divider()
        Button(String(localized: "Rename", comment: "Context menu")) { renameText = p.name; renaming = p.id }
        Button(String(localized: "Edit Config…", comment: "Context menu")) { env.actions.editConfig(p.id) }
        Button(String(localized: "Duplicate", comment: "Context menu")) { env.actions.duplicate(p.id) }
        Button(String(localized: "Export…", comment: "Context menu")) { env.actions.export(p.id) }
        Divider()
        Button(String(localized: "Delete…", comment: "Context menu"), role: .destructive) { env.presentation.requestDelete(p.id) }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button { ImportPanel.run(env) } label: { Image(systemName: "plus").frame(minWidth: 24, minHeight: 24) }
                .accessibilityLabel(Text("Import Profile", comment: "Accessibility label"))
            Button {
                if case .profile(let id) = selection { env.presentation.requestDelete(id) }
            } label: { Image(systemName: "minus").frame(minWidth: 24, minHeight: 24) }
                .disabled({ if case .profile = selection { false } else { true } }())
                .accessibilityLabel(Text("Delete Profile", comment: "Accessibility label"))
            Spacer()
            Menu {
                Button(String(localized: "New WireGuard Profile", comment: "Menu item")) { env.actions.newProfile(.wireGuard) }
                Button(String(localized: "New OpenVPN Profile", comment: "Menu item")) { env.actions.newProfile(.openVPN) }
                Button(String(localized: "Export All…", comment: "Menu item")) { env.actions.exportAll() }
            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 24, minHeight: 24) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("More", comment: "Accessibility label"))
        }
        .buttonStyle(.borderless)
        .contentShape(Rectangle())          // 24×24 pt targets (WCAG 2.5.8, UI-L22)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Text colour of a sidebar row: the system's own while the row isn't selected; white on the emphasised selection, which
/// macOS draws in AccentColor (#4a6e62, 5.6:1 with white in both appearances).
/// Pre-release review LOW: with a system accent other than Multicolor the selection is the user's accent colour, where
/// the system's own text is the readable one. The unfocused selection is grey (window not key): no white there.
/// `otherwise`: the colour off the emphasised selection, for coloured icons (the state lock, the section symbols), which
/// would vanish sage-on-sage on it (E2E-7 shots 200021).
struct SidebarInk: ViewModifier {
    var otherwise: Color? = nil
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.controlActiveState) private var activeState
    func body(content: Content) -> some View {
        // A custom always-sage selection was tried and removed again (owner test 200020 on 27.3: macOS kept drawing grey,
        // and replacing AppKit's selection drawing is too fragile; known 27 issue FB24855120).
        if Self.usesAccentInk(prominence: prominence, active: activeState, selectionIsAppAccent: SelectionAppearance.shared.selectionIsAppAccent) {
            content.foregroundStyle(Color.white)
        } else if let otherwise {
            content.foregroundStyle(otherwise)
        } else {
            content
        }
    }

    static func usesAccentInk(prominence: BackgroundProminence, active: ControlActiveState, selectionIsAppAccent: Bool) -> Bool {
        prominence == .increased && active == .key && selectionIsAppAccent
    }
}

/// Whether the sidebar's selection fill is the app's own `AccentColor` (system accent Multicolor) or the user's accent
/// colour. Under Multicolor, `NSColor.controlAccentColor` is the app's own accent; any other value is the user's choice.
/// Re-read when the system colours change.
@MainActor @Observable final class SelectionAppearance {
    static let shared = SelectionAppearance()
    private(set) var selectionIsAppAccent = true
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil,
                                                          queue: .main) { @Sendable _ in
            Task { @MainActor in SelectionAppearance.shared.refresh() }
        }
    }

    func refresh() {
        guard let app = NSColor(named: "AccentColor") else { return }
        var same = true
        NSApp?.effectiveAppearance.performAsCurrentDrawingAppearance {
            same = Self.sameColor(NSColor.controlAccentColor, app)
        }
        if NSApp == nil { same = Self.sameColor(NSColor.controlAccentColor, app) }
        if selectionIsAppAccent != same { selectionIsAppAccent = same }
    }

    /// sRGB components within 1/255 (a dynamic colour resolved in the current appearance).
    nonisolated static func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        let t: CGFloat = 1.0 / 255
        return abs(a.redComponent - b.redComponent) <= t && abs(a.greenComponent - b.greenComponent) <= t
            && abs(a.blueComponent - b.blueComponent) <= t
    }
}

/// A tooltip with the full text only while the text is truncated (pre-release review LOW: it showed on every name).
/// The full single-line width is measured by a hidden copy in the same environment (font, line limit).
struct HelpWhenTruncated: ViewModifier {
    let text: String
    @State private var full: CGFloat = 0
    @State private var shown: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(alignment: .leading) {
                Text(verbatim: text).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { full = $0 }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { shown = $0 }
            .help(Self.isTruncated(full: full, shown: shown) ? text : "")
    }

    static func isTruncated(full: CGFloat, shown: CGFloat) -> Bool { full > shown + 0.5 }
}

/// One of the four section rows (Activity, Auto-Connect, Diagnostics, Logs).
struct SidebarSectionRow: View {
    let title: String
    let symbol: String
    var body: some View {
        Label {
            Text(title).modifier(SidebarInk())
        } icon: {
            Image(systemName: symbol).modifier(SidebarInk(otherwise: Color.lp.softSage))
        }
    }
}

/// "Work, protected, WireGuard" for VoiceOver (§8.2); the protocol tag only when the sidebar is wide.
struct ProfileRow: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.controlActiveState) private var activeState
    let profile: ProfileItem

    var body: some View {
        // The active row's "Protected · 02:14" ticks once a minute (UI-L24).
        if profile.id == env.connection.profileID, env.connection.condition.showsRateLabel {
            TimelineView(.everyMinute) { _ in row }
        } else {
            row
        }
    }

    private var row: some View {
        let glyph = env.glyph(for: profile)
        return HStack(spacing: 8) {
            LockGlyph(state: glyph, size: 16, colored: false)
                .modifier(SidebarInk(otherwise: glyph.color))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                // Text colours come from the selection (SidebarInk, UI-M18). The name: one line, middle truncation (names
                // like "ovpn-auth-crv1" keep both ends), the full name in a tooltip only when it is truncated (UI-CONCEPT
                // §6.3 sidebar rule). The subtitle: one line if it fits, else its "·" facts stacked without a dangling dot
                // (DotSeparatedText), else it wraps to a second line for longer German text (UI-M17) and truncates
                // only beyond two lines.
                Text(profile.name).font(.headline).lineLimit(1).truncationMode(.middle).modifier(HelpWhenTruncated(text: profile.name)).modifier(SidebarInk())
                if let subtitle = ProfileSubtitle.text(for: profile, env: env) {
                    DotSeparatedText(text: subtitle, wrapLimit: 2).font(.subheadline).modifier(SidebarInk())
                }
            }
            Spacer(minLength: 4)
            // The protocol tag only when the sidebar is wide enough (§6.3); otherwise it's in the VoiceOver label.
            ViewThatFits(in: .horizontal) {
                Text(verbatim: profile.protocolTag)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.lp.onPastel)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(badgeFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .fixedSize()
                    .frame(minWidth: 60, alignment: .trailing)
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        // Name, state, protocol, and the subtitle's fact (UI-M10: subtitles weren't reachable by VoiceOver).
        .accessibilityLabel(Text(verbatim: ([profile.name, stateWord(glyph), profile.protocolName]
            + [ProfileSubtitle.text(for: profile, env: env)].compactMap { $0 }).joined(separator: ", ")))
    }

    /// Pastel chip; on the emphasised selection (AccentColor) it lifts off it with the canvas colour. On a selection in
    /// the user's accent colour (not Multicolor) or the grey unfocused one it keeps its pastel, where `onPastel` is readable.
    private var badgeFill: Color {
        if SidebarInk.usesAccentInk(prominence: prominence, active: activeState, selectionIsAppAccent: SelectionAppearance.shared.selectionIsAppAccent) {
            return Color.lp.canvas.opacity(0.55)
        }
        return profile.kind == .wireGuard ? Color.lp.pastelSage : Color.lp.pastelTeal
    }

    private func stateWord(_ glyph: GlyphState) -> String {
        profile.id == env.connection.profileID ? env.connection.condition.shortStateWord
                                               : String(localized: "not protected", comment: "Sidebar VoiceOver state")
    }
}

/// Profiles exist but none is selected (§6.15): neutral, never the empty-library copy.
struct NoSelectionView: View {
    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Select a profile", comment: "Detail placeholder when profiles exist but none is selected (§6.15)")
            } icon: {
                AppIconTile(size: 80)
            }
        } description: {
            Text("Choose a profile in the sidebar to see its details.", comment: "Detail placeholder description (§6.15)")
        }
    }
}

/// Empty library (§6.15).
struct EmptyLibraryView: View {
    @Environment(UIEnvironment.self) private var env
    var body: some View {
        if let locked = env.profiles.locked {
            LockedProfilesView(names: locked)
        } else if let reason = env.profiles.readError {
            unreadable(reason)
        } else {
            emptyLibrary
        }
    }

    /// E2E-4: a read failure is not an empty library (no "No Profiles", no import call to action over existing files).
    private func unreadable(_ reason: String) -> some View {
        ContentUnavailableView {
            Label {
                Text("LockPlus Couldn't Read Your Profiles", comment: "Profile files unreadable (E2E-4)")
            } icon: {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundStyle(Color.lp.softSage)
            }
        } description: {
            Text("Your profile files are still there. Details are in Diagnostics › Problems. (\(reason))", comment: "Profile files unreadable (E2E-4)")
        } actions: {
            Button(String(localized: "Try Again", comment: "Button")) { env.actions.reloadProfiles() }
                .buttonStyle(.lpConnect)
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label {
                Text("No Profiles", comment: "Empty library title")
            } icon: {
                AppIconTile(size: 96)
            }
        } description: {
            Text("Drop a .conf, .ovpn or .zip file here, or import one.", comment: "Empty library description")
        } actions: {
            Button(String(localized: "Import Profile…", comment: "Button")) { ImportPanel.run(env) }
                .buttonStyle(.lpConnect)
            Button(String(localized: "New WireGuard Profile", comment: "Button")) { env.actions.newProfile(.wireGuard) }
        }
    }
}

#Preview("Sidebar") {
    @Previewable @State var selection: SidebarItem? = .profile(PreviewData.workID)
    SidebarView(selection: $selection, search: "")
        .environment(UIEnvironment.preview(row: "6"))
        .frame(width: 260, height: 520)
}

#Preview("Empty library") {
    EmptyLibraryView().environment(UIEnvironment.preview(row: "15", profiles: [])).frame(width: 600, height: 420)
}

/// The app icon and name in the sidebar's title bar row (owner review 2026-11-10). MainView places it as a toolbar item
/// of the sidebar column, so it hides with the sidebar. The tile follows light/dark like the Dock icon. Decorative:
/// VoiceOver already has the window title.
struct SidebarBrandHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            AppIconTile(size: 22)
            Text(verbatim: "LockPlus").font(.headline)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}
