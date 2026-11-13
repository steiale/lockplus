import SwiftUI
import UniformTypeIdentifiers

/// Sidebar destinations (DESIGN §11.1): profiles, then the sections with ⌘2–⌘5.
enum SidebarItem: Hashable, Sendable {
    case profile(ProfileItem.ID)
    case activity, autoConnect, diagnostics, logs

    /// What the window shows for `selection` (UI-CONCEPT §6.3): sections stay; a profile that exists stays; nil or a
    /// profile that is gone (deleted) falls back to the selection the binder keeps in `ProfilesUIModel`
    /// (active, else last used, else first), else the first listed profile; nil only when the library is empty.
    @MainActor static func resolved(_ selection: SidebarItem?, in profiles: ProfilesUIModel) -> SidebarItem? {
        switch selection {
        case .profile(let id) where profiles.profile(id) != nil: return selection
        case .activity, .autoConnect, .diagnostics, .logs: return selection
        case .profile, nil:
            return (profiles.profile(profiles.selection)?.id ?? profiles.profiles.first?.id).map { .profile($0) }
        }
    }
}

/// The main window (UI-CONCEPT §6.3): a two-column `NavigationSplitView`. Default 920×620, minimum 900×580
/// (owner review 2026-11-10: the hero's stats need about 620 pt of detail to stay on one row).
/// System chrome stays system (no background on the sidebar `List`); the detail sits on the brand canvas.
struct MainView: View {
    @Environment(UIEnvironment.self) private var env
    @State private var selection: SidebarItem?
    @State private var search = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @FocusState private var sidebarFocused: Bool

    init(selection: SidebarItem? = nil) {
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection, search: search)
                .focused($sidebarFocused)   // see `.onAppear` below
                // The app icon and name in the sidebar's title bar row, between the traffic lights and the sidebar button
                // (owner review 2026-11-10; the system search field always takes the top of the sidebar itself).
                .toolbar {
                    ToolbarItem(placement: .automatic) { SidebarBrandHeader() }
                        .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible)
                }
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 340)
        } detail: {
            DetailRouter(selection: shown)
        }
        // The sidebar has the focus when the window opens (⌘⌫ needs it, UI-H1). Otherwise AppKit makes the window's only
        // text view, the detail's Notes editor, the first responder and the Form scrolls down to it: the hero opened out
        // of sight (README shots 200017). `defaultFocus` doesn't win over AppKit here; setting it at appear does.
        .onAppear { sidebarFocused = true }
        .searchable(text: $search, placement: .sidebar, prompt: Text("Search", comment: "Sidebar search prompt"))
        .toolbar { MainToolbar(selection: shown) }
        .navigationTitle(title)
        // The content sits below the 52 pt toolbar, so 528 makes the window's minimum 580; with 580 here the minimum
        // window was 632 high, above the 620 default, and every window opened at 920×632.
        .frame(minWidth: 900, minHeight: 528)
        // One source of truth for the profile selection: `env.profiles.selection` (the binder picks it; the editor and
        // duplicate set it). The profile list arrives after the window (async load), so this runs on every change of
        // the resolved item, not once at appear.
        .onChange(of: shown, initial: true) { _, new in
            if selection != new { selection = new }
        }
        .onChange(of: selection) { _, new in
            if case .profile(let id) = new, env.profiles.selection != id { env.profiles.selection = id }
        }
        .onChange(of: env.profiles.selection) { _, new in
            if let new, env.profiles.profile(new) != nil, selection != .profile(new) { selection = .profile(new) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NavigationRequest.notification)) { note in
            guard let raw = note.userInfo?["dest"] as? String, let dest = NavigationRequest(rawValue: raw) else { return }
            switch dest {
            case .profiles:
                if let id = env.profiles.selection ?? env.profiles.profiles.first?.id { selection = .profile(id) }
            case .activity: selection = .activity
            case .autoConnect: selection = .autoConnect
            case .diagnostics: selection = .diagnostics
            case .logs: selection = .logs
            }
        }
        .modifier(MainWindowPresentations())
    }

    /// `selection` reconciled with the profile list: never nil while profiles exist, never a deleted profile.
    private var shown: SidebarItem? { SidebarItem.resolved(selection, in: env.profiles) }

    private var title: String {
        switch shown {
        case .profile(let id): env.profiles.profile(id)?.name ?? "LockPlus"
        case .activity: String(localized: "Activity", comment: "Section title")
        case .autoConnect: String(localized: "Auto-Connect", comment: "Section title")
        case .diagnostics: String(localized: "Diagnostics", comment: "Section title")
        case .logs: String(localized: "Logs", comment: "Section title")
        case nil: "LockPlus"
        }
    }
}

/// Drop target and every sheet of the main window (split out to keep the type checker fast).
private struct MainWindowPresentations: ViewModifier {
    @Environment(UIEnvironment.self) private var env

    func body(content: Content) -> some View {
        @Bindable var importer = env.importer
        let alert = MainAlert.active(in: env)
        content
            // The whole window is a drop target (§6.3).
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                env.actions.importFiles(urls)
                return true
            } isTargeted: { importer.isDropTargeted = $0 }
            .overlay { if importer.isDropTargeted { DropOverlay() } }
            // ONE sheet, chosen by priority (auth first); dismissing clears only the shown one (UI-M9).
            .sheet(item: Binding(get: { MainSheet.active(in: env) }, set: { new in
                if new == nil, let shown = MainSheet.active(in: env) { shown.clear(in: env) }
            })) { sheet in sheet.content }
            // ONE alert, chosen by priority.
            // While onboarding is shown, its own sheet presents the import alert (2.0.1 E2E F5).
            .alert(alertTitle(alert), isPresented: Binding(get: { alert != nil && !env.onboarding.isPresented }, set: { if !$0 { alert?.clear(in: env) } }),
                   presenting: alert) { a in
                switch a {
                case .importError:
                    Button(String(localized: "OK", comment: "Button")) {}
                }
            } message: { a in
                switch a {
                case .importError(let m): Text(m)
                }
            }
            // Every "Delete…" asks first (UI-H1).
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { env.presentation.pendingDelete != nil },
                                                                  set: { if !$0 { env.presentation.pendingDelete = nil } })) {
                Button(String(localized: "Delete", comment: "Button"), role: .destructive) {
                    if let id = env.presentation.pendingDelete { env.actions.delete(id) }
                    env.presentation.pendingDelete = nil
                }
            } message: {
                Text("The profile and its saved credentials are removed from this Mac.", comment: "Delete confirmation message")
            }
    }

    private var deleteTitle: Text {
        let name = env.profiles.profile(env.presentation.pendingDelete)?.name ?? ""
        return Text("Delete “\(name)”?", comment: "Delete confirmation")
    }

    private func alertTitle(_ a: MainAlert?) -> Text {
        switch a {
        case .importError: Text("Can't Import", comment: "Import error alert title")
        case nil: Text(verbatim: "")
        }
    }
}

private struct DetailRouter: View {
    @Environment(UIEnvironment.self) private var env
    let selection: SidebarItem?

    var body: some View {
        VStack(spacing: 0) {
            WindowBanners()
            Group {
                switch selection {
                case .profile(let id):
                    if let p = env.profiles.profile(id) { ProfileDetailView(profile: p) } else { emptyOrPlaceholder }
                case .activity: ActivityView()
                case .autoConnect: AutoConnectView()
                case .diagnostics: DiagnosticsView()
                case .logs: LogsView()
                case nil: emptyOrPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BrandCanvasBackground())
    }

    /// The empty-library copy only when there are no profiles (or they are locked/unreadable); otherwise neutral.
    @ViewBuilder private var emptyOrPlaceholder: some View {
        if env.profiles.profiles.isEmpty { EmptyLibraryView() } else { NoSelectionView() }
    }
}

/// Persistent banners above the detail (§6.15).
struct WindowBanners: View {
    @Environment(UIEnvironment.self) private var env

    var body: some View {
        let c = env.connection
        VStack(spacing: 6) {
            // §4.5: a Connect the old helper stopped, first (E2E-5 F8: a strip, never a sheet that blocks Quit).
            if let gate = c.connectGate { ConnectGateStrip(gate: gate) }
            if case .extensionNotReady(let r) = c.condition {
                switch r {
                case .needsUserApproval:
                    InlineStrip(severity: .attention, message: String(localized: "The tunnel component isn't allowed yet.", comment: "Banner (§6.15)")) {
                        Button(String(localized: "Open System Settings", comment: "Button")) { SystemSettingsLink.open(SystemSettingsLink.networkExtensions) }
                        Button(String(localized: "Show the Switch Again", comment: "Button (§6.14)")) { env.actions.perform(.showSwitchAgain) }   // re-requests activation, then opens the pane (UI-L20)
                    }
                case .disabledByUser:
                    InlineStrip(severity: .attention, message: String(localized: "LockPlus's network extension is turned off in System Settings.", comment: "Banner (§6.15)")) {
                        Button(String(localized: "Open System Settings", comment: "Button")) { SystemSettingsLink.open(SystemSettingsLink.networkExtensions) }
                    }
                case .removedDuringUpdate:
                    InlineStrip(severity: .attention, message: String(localized: "The tunnel component was removed during the update. Approve it again to reconnect.", comment: "Banner (§6.15)")) {
                        Button(String(localized: "Approve…", comment: "Button")) { env.actions.installExtension() }
                    }
                case .failed:
                    InlineStrip(severity: .critical, message: String(localized: "The tunnel component is damaged.", comment: "Banner")) {
                        Button(String(localized: "Reinstall…", comment: "Button")) { env.actions.reinstallExtension() }
                    }
                case .rebootRequired:
                    InlineStrip(severity: .attention, message: String(localized: "Restart your Mac to finish installing the tunnel component.", comment: "Banner, will complete after reboot"))
                case .ready, .activating, .updateFailed:
                    EmptyView()
                }
            }
            if c.inputs.extensionReadiness == .updateFailed {
                // E2E-4 (U15): the old tunnel component still connects the profiles; only XPC is out of reach.
                InlineStrip(severity: .attention, message: c.extensionUpdateFailedMessage ?? ExtensionMapping.updateFailedMessage()) {
                    Button(String(localized: "Try Again", comment: "Button")) { env.actions.installExtension() }
                }
            }
            if c.connectGate == nil, c.legacyHelper != nil || c.legacyHelperRemoval != nil {
                // §4.5: persistent while the old helper is present (the gate strip says it while it shows), and
                // "Remove Old Helper" with its result (E2E-5 F1).
                LegacyHelperBanner()
            }
            if c.oldWireGuidePlusApp != nil, !c.oldAppOfferDismissed { OldAppTrashBanner() }
            if env.onboarding.migrationResumePending { MigrationResumeBanner() }
            if env.settings.launchAtLoginOffer && env.settings.launchAtLogin == .disabled { LaunchAtLoginOfferBanner() }
            if c.vpnConfigurationDenied {
                InlineStrip(severity: .attention, message: String(localized: "macOS hasn't allowed LockPlus to add VPN configurations.", comment: "Banner (§6.15)")) {
                    Button(String(localized: "Allow…", comment: "Button")) { env.actions.allowVPNConfiguration() }
                }
            }
            if let other = c.otherVPNName, !c.condition.isActive {
                InlineStrip(severity: .attention, message: String(localized: "Another VPN (\(other)) is active. Connecting \(env.conditionContext.name) will disconnect it.", comment: "Attention strip (§6.15)"))
            }
            if let result = env.importer.exportResult {
                InlineStrip(severity: .info, message: String(localized: "Exported \(result.count) profiles to \(result.folderName)", comment: "Export result banner (§6.8)")) {
                    Button(String(localized: "Show in Finder", comment: "Button")) { NSWorkspace.shared.activateFileViewerSelecting([result.folderURL]) }
                    Button { env.importer.exportResult = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Dismiss", comment: "Accessibility label"))
                }
            }
        }
        // The banners (§6.15) sit outside the detail's scroll view, so their minimum height is the split view's. The window's
        // minimum-size pass proposes width 0, where a strip's wrapping copy is one glyph per line (the old-helper strip:
        // 1596 pt); the split view then outgrew the window and its top slid under the toolbar. 300 pt fits the
        // narrowest detail (900 − 340 sidebar − 2 × 20 padding = 520).
        .frame(minWidth: 300)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

/// Full-window drop overlay (§6.3): `lp.stroke` dashed 2 pt around the detail area.
private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.lp.canvas.opacity(0.85)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.lp.stroke, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .padding(16)
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 40)).foregroundStyle(Color.lp.softSage)
                Text("Drop .conf, .ovpn or .zip", comment: "Drop overlay (§6.3)")
                    .font(.title3)
                    .foregroundStyle(Color.lp.label)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// Unified toolbar (§6.3): the + menu and the primary Connect/Disconnect for the selected profile.
struct MainToolbar: ToolbarContent {
    @Environment(UIEnvironment.self) private var env
    let selection: SidebarItem?

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(String(localized: "New WireGuard Profile", comment: "Menu item")) { env.actions.newProfile(.wireGuard) }
                Button(String(localized: "New OpenVPN Profile", comment: "Menu item")) { env.actions.newProfile(.openVPN) }
                Divider()
                Button(String(localized: "Import File…", comment: "Menu item")) { ImportPanel.run(env) }
                Button(env.settings.clipboardDenied ? String(localized: "Clipboard access is off for LockPlus", comment: "Menu item (§6.8)")
                                                    : String(localized: "Import from Clipboard", comment: "Menu item")) {
                    if env.settings.clipboardDenied { SystemSettingsLink.open(SystemSettingsLink.pastePrivacy) } else { env.actions.importFromClipboard() }
                }
            } label: {
                Label(String(localized: "Add Profile", comment: "Toolbar menu"), systemImage: "plus")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if case .profile(let id) = selection, let p = env.profiles.profile(id) {
                ToolbarConnectButton(profile: p)
            }
        }
    }
}

/// Mirrors the hero's primary action for the selected profile.
struct ToolbarConnectButton: View {
    @Environment(UIEnvironment.self) private var env
    let profile: ProfileItem

    var body: some View {
        let isCurrent = profile.id == env.connection.profileID
        let c = env.connection.condition
        // The glass capsule hugs SF Mono tightly; a little side padding (owner test 2026-11-10: "squeezed").
        if isCurrent && c.isActive {
            Button {
                env.actions.perform(c.isBlocked ? .disconnectAndRestoreInternet : .disconnect)
            } label: {
                Text(c.isBlocked ? String(localized: "Disconnect and Restore Internet", comment: "Button")
                                 : String(localized: "Disconnect", comment: "Button"))
                    .padding(.horizontal, 6)
            }
        } else {
            // In the toolbar the system glass style matches the 26/27 toolbar; the brand style stays in the hero.
            Button { env.gatedConnect(profile.id) } label: {
                Text(String(localized: "Connect", comment: "Button")).padding(.horizontal, 6)
            }
                .buttonStyle(.glassProminent)
                .disabled(c == .disconnecting || c.isExtensionNotReady || profile.notYetVerified || profile.connectHeld != nil)
                .help(profile.notYetVerified ? ProfileItem.notYetVerifiedExplanation : profile.connectHeld ?? "")
        }
    }
}

/// File import panel (§6.8). Reading files happens in the ImportCoordinator, not here.
enum ImportPanel {
    @MainActor static func run(_ env: UIEnvironment) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "conf"), UTType(filenameExtension: "ovpn")].compactMap { $0 }
        panel.prompt = String(localized: "Import", comment: "Open panel button")
        if panel.runModal() == .OK { env.actions.importFiles(panel.urls) }
    }
}

#Preview("Main — protected") {
    MainView().environment(UIEnvironment.preview(row: "6")).frame(width: 920, height: 620)
}

#Preview("Main — blocked") {
    MainView().environment(UIEnvironment.preview(row: "10")).frame(width: 920, height: 620)
}

#Preview("Main — extension needs approval") {
    MainView().environment(UIEnvironment.preview(row: "1")).frame(width: 920, height: 620)
}

#Preview("Main — old LockPlus helper present") {
    let env = UIEnvironment.preview(row: "15")
    env.connection.legacyHelper = PreviewData.legacyRefuse
    return MainView().environment(env).frame(width: 920, height: 620)
}

#Preview("Main — empty library") {
    MainView().environment(UIEnvironment.preview(row: "15", profiles: [])).frame(width: 920, height: 620)
}
