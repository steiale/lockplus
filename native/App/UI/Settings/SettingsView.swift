import SwiftUI

/// External links in one place. The public repo is renamed to steiale/lockplus after 1.2.0 (docs/release/PUBLISH.md); until then the issues and license links 404. Update here only.
enum LockPlusLinks {
    static let issues = URL(string: "https://github.com/steiale/lockplus/issues")!
    static let releaseNotes = URL(string: "https://github.com/steiale/lockplus-updates/releases")!
    static let license = URL(string: "https://github.com/steiale/lockplus/blob/main/LICENSE")!
    static let support = URL(string: "https://ko-fi.com/steiale")!
}

/// The Settings scene (UI-CONCEPT §6.13): a `TabView` of grouped forms, about 520 pt wide.
/// System chrome only: no brand canvas here.
struct SettingsView: View {
    @Environment(UIEnvironment.self) private var env
    var body: some View {
        TabView {
            Tab(String(localized: "General", comment: "Settings tab"), systemImage: "gearshape") { GeneralSettings() }
            Tab(String(localized: "Menu Bar", comment: "Settings tab"), systemImage: "menubar.rectangle") { MenuBarSettings() }
            Tab(String(localized: "Profiles", comment: "Settings tab"), systemImage: "person.crop.rectangle.stack") { ProfileDefaultsSettings() }
            Tab(String(localized: "Advanced", comment: "Settings tab"), systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
            Tab(String(localized: "About", comment: "Settings tab"), systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 520)
        .scenePadding()
        .onAppear { env.actions.settingsDidAppear() }
    }
}

private struct GeneralSettings: View {
    @Environment(UIEnvironment.self) private var env

    var body: some View {
        @Bindable var s = env.settings
        Form {
            Section {
                Toggle(isOn: Binding(get: { s.launchAtLogin != .disabled }, set: { env.actions.setLaunchAtLogin($0) })) {
                    Text("Launch at login", comment: "Setting")
                    if s.launchAtLogin == .requiresApproval {
                        Text("Allowed in System Settings › Login Items", comment: "Launch at login pending approval")
                    }
                }
                if s.launchAtLogin == .requiresApproval {
                    Button(String(localized: "Open Login Items…", comment: "Button")) { SystemSettingsLink.open(SystemSettingsLink.loginItems) }
                }
                Toggle(String(localized: "Open window at login", comment: "Setting"), isOn: $s.openWindowAtLogin)
            }
            Section {
                Picker(selection: $s.language) {
                    Text("System", comment: "Language").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.en)
                    Text(verbatim: "Deutsch").tag(AppLanguage.de)
                } label: {
                    Text("Language", comment: "Setting")
                    Text("Applies after LockPlus restarts.", comment: "Language footnote")
                }
            }
            Section {
                Picker(String(localized: "Appearance", comment: "Setting"), selection: $s.appearance) {
                    Text("System", comment: "Appearance").tag(AppAppearance.system)
                    Text("Light", comment: "Appearance").tag(AppAppearance.light)
                    Text("Dark", comment: "Appearance").tag(AppAppearance.dark)
                }
            }
            Section {
                Picker(String(localized: "Notifications", comment: "Setting"), selection: $s.notifications) {
                    Text("Only problems", comment: "Notification mode").tag(NotificationMode.problemsOnly)
                    Text("Connect and disconnect", comment: "Notification mode").tag(NotificationMode.connectAndDisconnect)
                    Text("Off", comment: "Notification mode").tag(NotificationMode.off)
                }
                if s.notificationsDeniedBySystem {
                    HStack {
                        Text("Notifications are off for LockPlus in System Settings.", comment: "Notifications denied").foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Open System Settings", comment: "Button")) { SystemSettingsLink.open(SystemSettingsLink.notifications) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct MenuBarSettings: View {
    @Environment(UIEnvironment.self) private var env
    @State private var confirmHide = false

    var body: some View {
        @Bindable var s = env.settings
        Form {
            if s.iconMayBeHidden || !s.showInMenuBar {
                Section {
                    InlineStrip(severity: .attention, message: String(localized: "The menu bar icon may be hidden. Turn on LockPlus in System Settings › Menu Bar, or use Show in Menu Bar.", comment: "Menu bar helper (§6.15)")) {
                        Button(String(localized: "Open System Settings", comment: "Button")) { SystemSettingsLink.open(SystemSettingsLink.menuBar) }
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { s.showInMenuBar }, set: { on in
                    if on { env.actions.showInMenuBar() } else { confirmHide = true }   // warn before hiding the only UI (UI-H2)
                })) {
                    Text("Show in menu bar", comment: "Setting")
                    Text("The way back after removing the icon with ⌘-drag.", comment: "Setting footnote")
                }
                Picker(String(localized: "Show rates", comment: "Setting"), selection: $s.rateLabel) {
                    Text("Off", comment: "Rate label").tag(RateLabelMode.off)
                    Text(verbatim: "↓1.2M").tag(RateLabelMode.download)
                    Text(verbatim: "↓1.2M ↑30K").tag(RateLabelMode.both)
                }
                Picker(String(localized: "Icon style", comment: "Setting"), selection: $s.iconStyle) {
                    Text("Color", comment: "Icon style").tag(IconStyle.color)
                    Text("Monochrome", comment: "Icon style").tag(IconStyle.monochrome)
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                MenuBarIconPreview(style: s.iconStyle, rateLabel: s.rateLabel)
            } header: {
                Text("Preview", comment: "Settings section")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(Text("Hide the menu bar icon?", comment: "Hide icon confirmation"), isPresented: $confirmHide) {
            Button(String(localized: "Hide Icon", comment: "Button")) { env.settings.showInMenuBar = false }
        } message: {
            Text("LockPlus keeps running. Open it from the Dock or the Applications folder, and turn the icon back on here.", comment: "Hide icon confirmation message")
        }
    }
}

/// Preview of both states in the chosen style (§6.13).
struct MenuBarIconPreview: View {
    let style: IconStyle
    let rateLabel: RateLabelMode

    var body: some View {
        HStack(spacing: 24) {
            sample(.unprotected, label: nil)
            sample(.protected, label: rateLabel == .off ? nil : (rateLabel == .both ? "↓1.2M ↑30K" : "↓1.2M"))
            sample(.blocked, label: nil)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview of the menu bar icon: not protected, protected with rates, blocked", comment: "Accessibility"))
    }

    @ViewBuilder private func sample(_ state: GlyphState, label: String?) -> some View {
        // The menu bar's own gap to the rates (pre-release review LOW): the button's ~1.5 pt, plus the colour tile's
        // 3 pt of transparent space (4.5 pt); the monochrome canvas brings its own spare room.
        HStack(spacing: MenuBarController.buttonImageTitleGap + (style == .color ? MenuBarController.tileLabelGap : 0)) {
            if style == .color, let tile = LockGlyphImage.colorTile(state, pointSize: 13) {
                Image(nsImage: tile)
            } else if let glyph = LockGlyphImage.statusTemplate(state, pointSize: 15) {
                // The status item's own image: the lock body is centred like in the menu bar (§6.1).
                Image(nsImage: glyph).renderingMode(.template)
            }
            if let label { Text(verbatim: label).font(.system(size: 11).monospacedDigit()) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ProfileDefaultsSettings: View {
    @Environment(UIEnvironment.self) private var env

    var body: some View {
        @Bindable var s = env.settings
        Form {
            Section {
                Toggle(String(localized: "Kill switch for full tunnels", comment: "Setting"), isOn: $s.defaultKillSwitchForFullTunnels)
                Toggle(isOn: $s.defaultAllowLocalNetwork) {
                    Text("Allow local network", comment: "Setting")
                    Text("Off by default: a hostile Wi-Fi network can abuse local access.", comment: "Setting footnote (F-1)")
                }
            } header: {
                Text("Defaults for new profiles", comment: "Settings section")
            }
            Section {
                Button { env.actions.exportAll() } label: {
                    Label(String(localized: "Export All…", comment: "Button, behind Touch ID"), systemImage: "touchid")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @Environment(UIEnvironment.self) private var env
    @State private var showDiagnostics = false
    @State private var showUninstall = false
    @State private var confirmReinstall = false
    @State private var showMigration = false

    var body: some View {
        @Bindable var s = env.settings
        Form {
            Section {
                Picker(String(localized: "Log level", comment: "Setting"), selection: $s.logLevel) {
                    Text("Errors", comment: "Log level").tag(LogLevel.error)
                    Text("Warnings", comment: "Log level").tag(LogLevel.warning)
                    Text("Info", comment: "Log level").tag(LogLevel.info)
                    Text("Debug", comment: "Log level").tag(LogLevel.debug)
                }
                Toggle(String(localized: "Receive release candidates", comment: "Setting"), isOn: $s.receiveReleaseCandidates)
            }
            Section {
                Button(String(localized: "Export Diagnostics…", comment: "Button (§14.2)")) { showDiagnostics = true }
            } footer: {
                Text("A redacted report for support. You see everything inside before you save it.", comment: "Diagnostics export footer")
            }
            Section {
                // E2E-5 F4 (DESIGN §13.1): the migration is reachable any time, not only from onboarding.
                // Pre-release review: the sheet shares the migration model with onboarding and the main window's
                // sheet, so it isn't opened over either of them, during a run, or while the profiles are locked (M2:
                // every create would fail); it never clears their offer itself (the sheet re-scans, `rescan`).
                Button(String(localized: "Import from Old LockPlus…", comment: "Button, Settings › Advanced (§13.1)")) {
                    showMigration = true
                }
                .disabled(env.onboarding.isPresented || env.onboarding.migrationSheetPresented || env.onboarding.migrationRunning
                          || env.profiles.locked != nil)
            } footer: {
                Text("Copies profiles, settings and history from LockPlus 1.x. Profiles already imported are skipped.", comment: "Settings › Advanced footer (E2E-5 F4)")
            }
            Section {
                Button(String(localized: "Reinstall Tunnel Component…", comment: "Button")) { confirmReinstall = true }
                Button(String(localized: "Uninstall LockPlus…", comment: "Button"), role: .destructive) { showUninstall = true }
            }
            if s.isDevBuild {
                Section {
                    Text("The Debug menu is available in the menu bar while LockPlus is active.", comment: "Dev builds only").foregroundStyle(.secondary)
                } header: {
                    Text("Debug", comment: "Settings section")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showUninstall) { UninstallConfirmSheet(phase: s.uninstallPhase) }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsExportSheet() }
        .sheet(isPresented: $showMigration, onDismiss: { env.actions.closeMigration() }) { MigrationSheet(rescan: true) }
        .confirmationDialog(Text("Reinstall the tunnel component?", comment: "Confirmation"), isPresented: $confirmReinstall) {
            Button(String(localized: "Reinstall", comment: "Button")) { env.actions.reinstallExtension() }
        } message: {
            Text("Any connection is stopped. macOS may ask you to allow the component again.", comment: "Reinstall confirmation")
        }
    }
}

/// "Export Diagnostics…" with the "What's inside" preview (§14.2): the redacted files, readable before saving.
struct DiagnosticsExportSheet: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var files: [DiagnosticsPreviewFile]?
    @State private var selection: DiagnosticsPreviewFile.ID?

    /// Previews and screenshots pass the files directly.
    init(files: [DiagnosticsPreviewFile]? = nil) {
        _files = State(initialValue: files)
        _selection = State(initialValue: files?.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's Inside the Diagnostics Report", comment: "Diagnostics export title").font(.headline)
            Text("Keys, passwords, usernames, server names and your addresses are replaced by placeholders. DNS servers and tunnel routes stay readable so support can check them.", comment: "Diagnostics export explanation (§14.2)")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let files {
                HSplitView {
                    List(files, selection: $selection) { f in Text(verbatim: f.name).tag(f.id) }
                        .frame(minWidth: 160, idealWidth: 180, maxWidth: 240)
                    ScrollView([.vertical, .horizontal]) {
                        Text(verbatim: files.first { $0.id == selection }?.text ?? "")
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                    }
                    .background(Color.lp.sunken)
                    .foregroundStyle(Color.lp.label)
                }
                .frame(minHeight: 260)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Collecting…", comment: "Diagnostics export progress") }
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Button")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Export…", comment: "Button")) { env.actions.exportDiagnostics(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files == nil)
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
        .task {
            guard files == nil else { return }
            let loaded = await env.actions.prepareDiagnosticsPreview()
            files = loaded
            selection = loaded.first?.id
        }
    }
}

private struct AboutSettings: View {
    @Environment(UIEnvironment.self) private var env

    var body: some View {
        let s = env.settings
        VStack(spacing: 12) {
            AppIconTile(size: 96)
            Text(verbatim: "LockPlus").font(.title.weight(.semibold))
            Text("Version \(s.version) (\(s.build))", comment: "About version line").foregroundStyle(.secondary).textSelection(.enabled)
            Button(String(localized: "Check for Updates…", comment: "Button")) { env.actions.checkForUpdates() }
                .disabled(!s.canCheckForUpdates)
            HStack(spacing: 16) {
                Link(String(localized: "Release Notes", comment: "Link"), destination: LockPlusLinks.releaseNotes)
                Link(String(localized: "Report an Issue", comment: "Link"), destination: LockPlusLinks.issues)
                Link(String(localized: "License", comment: "Link"), destination: LockPlusLinks.license)
                Link(String(localized: "Support LockPlus", comment: "Link (Ko-fi)"), destination: LockPlusLinks.support)
            }
            .font(.callout)
            .tint(Color.lp.accentText)          // links: AccentColor is 2.9:1 on the dark window
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Settings") {
    SettingsView().environment(UIEnvironment.preview())
}

#Preview("Settings — General, approval pending") {
    let env = UIEnvironment.preview()
    env.settings.launchAtLogin = .requiresApproval
    env.settings.notificationsDeniedBySystem = true
    return GeneralSettings().environment(env).frame(width: 520, height: 400)
}

#Preview("Settings — Menu Bar, icon may be hidden") {
    let env = UIEnvironment.preview()
    env.settings.iconMayBeHidden = true
    env.settings.iconStyle = .color
    return MenuBarSettings().environment(env).frame(width: 520, height: 460)
}

#Preview("Diagnostics export") {
    DiagnosticsExportSheet(files: PreviewData.diagnosticsFiles).environment(UIEnvironment.preview())
}

#Preview("Settings — Advanced") {
    AdvancedSettings().environment(UIEnvironment.preview()).frame(width: 520, height: 300)
}
