import AppKit
import SwiftUI

// Scene glue validated in spike S15 (27): the hidden bridge window, the activation policy rule and the menu
// commands. The App entry (P2a) declares the scenes and uses these:
//
//   Window("LockPlusBridge", id: "bridge") { SceneBridge().frame(width: 0, height: 0) }   // FIRST
//       .windowResizability(.contentSize).defaultLaunchBehavior(.presented).restorationBehavior(.disabled)
//   Window("LockPlus", id: "main") { MainView().environment(env) }
//       .defaultSize(width: 920, height: 620).windowResizability(.contentMinSize).defaultLaunchBehavior(.suppressed)
//       .commands { LockPlusCommands(env: env) }
//   WindowGroup("Edit Profile", for: EditorTarget.self) { $t in EditorWindow(target: t).environment(env) }
//       .restorationBehavior(.disabled).environment(\.profileEditorBackend, editorBackend)
//   Settings { SettingsView().environment(env) }                                            // AFTER the bridge
//
// and `applicationShouldTerminateAfterLastWindowClosed → false` (keep both halves, S15 Q3).

extension Notification.Name {
    static let lpOpenSettings = Notification.Name("io.github.steiale.lockplus.openSettings")
    static let lpOpenMain = Notification.Name("io.github.steiale.lockplus.openMain")
    static let lpOpenEditor = Notification.Name("io.github.steiale.lockplus.openEditor")
}

/// The invisible bridge: gives AppKit code (the status menu) a SwiftUI context for `openSettings`/`openWindow`.
/// `showSettingsWindow:` is dead since macOS 14. Stays ordered in at alpha 0 (S15: an ordered-out bridge plus a
/// `true` terminate answer quits at launch).
struct SceneBridge: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .lpOpenSettings)) { _ in
                AppActivation.becomeRegular()
                openSettings()
                AppActivation.ensureFrontAfterOpening()
            }
            .onReceive(NotificationCenter.default.publisher(for: .lpOpenEditor)) { note in
                guard let data = note.userInfo?["target"] as? Data,
                      let target = try? JSONDecoder().decode(EditorTarget.self, from: data) else { return }
                AppActivation.becomeRegular()
                openWindow(value: target)
                AppActivation.ensureFrontAfterOpening()
            }
            .onReceive(NotificationCenter.default.publisher(for: .lpOpenMain)) { _ in
                AppActivation.becomeRegular()
                openWindow(id: "main")
                AppActivation.ensureFrontAfterOpening()
            }
            .onAppear {
                NSApp.windows.first { $0.identifier?.rawValue == "bridge" }?.lpMakeInvisible()
            }
    }

    /// Post from AppKit (menu actions). Opening goes through the bridge so it works with no window open.
    @MainActor static func requestSettings() { NotificationCenter.default.post(name: .lpOpenSettings, object: nil) }
    @MainActor static func requestMainWindow() { NotificationCenter.default.post(name: .lpOpenMain, object: nil) }
    /// Opens the editor (`WindowGroup("Edit Profile", for: EditorTarget.self)`). For an existing profile, call this
    /// only after RevealGate passed (§6.5).
    @MainActor static func requestEditor(_ target: EditorTarget) {
        guard let data = try? JSONEncoder().encode(target) else { return }
        NotificationCenter.default.post(name: .lpOpenEditor, object: nil, userInfo: ["target": data])
    }
}

extension NSWindow {
    func lpMakeInvisible() {
        alphaValue = 0
        ignoresMouseEvents = true
        collectionBehavior = [.transient, .ignoresCycle]
        isExcludedFromWindowsMenu = true
        styleMask.remove(.titled)
        // Never closable or minimisable: a user/Cmd-W close of the bridge would end every menu action routed through it
        // (Settings, Edit Config…, Open LockPlus).
        styleMask.remove([.closable, .miniaturizable])
        setFrame(NSRect(x: frame.minX, y: frame.minY, width: 1, height: 1), display: false)
    }
}

/// Activation policy rule (DESIGN §11.1): `.accessory` from `applicationWillFinishLaunching` (no LSUIElement);
/// `.regular` + `NSApp.activate()` BEFORE opening main/editor/Settings; back to `.accessory` when none remains.
@MainActor enum AppActivation {
    static func becomeRegular() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    /// S15 safety net: without a user gesture `activate()` may not activate, and the new window opens behind the
    /// frontmost app. 0.4 s later, bring user windows to the front without activating, so they're at least visible.
    static func ensureFrontAfterOpening() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !NSApp.isActive else { return }
            for w in NSApp.windows where isUserWindow(w) { w.orderFrontRegardless() }
        }
    }

    /// Call from `NSWindow.willCloseNotification` with the closing window.
    static func becomeAccessoryIfNoWindows(excluding closing: NSWindow?) {
        let remaining = NSApp.windows.filter { $0 !== closing && isUserWindow($0) }
        if remaining.isEmpty, NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }

    /// Main, editor and Settings windows count; the bridge, panels, sheets, menus and the status bar don't.
    static func isUserWindow(_ w: NSWindow) -> Bool {
        w.isVisible && w.identifier?.rawValue != "bridge" && w.alphaValue > 0 && !(w is NSPanel) && w.sheetParent == nil
            && w.className != "NSStatusBarWindow" && !w.className.contains("Menu")
    }
}

/// Menu commands (DESIGN §11.6, UI-CONCEPT §8.1). ⌘1–⌘5 post a navigation request the main window handles.
struct LockPlusCommands: Commands {
    let env: UIEnvironment
    @FocusedValue(\.sidebarProfile) private var sidebarProfile

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "New WireGuard Profile", comment: "Menu command")) { env.actions.newProfile(.wireGuard) }
                .keyboardShortcut("n", modifiers: .command)
            Button(String(localized: "New OpenVPN Profile", comment: "Menu command")) { env.actions.newProfile(.openVPN) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button(String(localized: "Import…", comment: "Menu command")) { ImportPanel.run(env) }
                .keyboardShortcut("o", modifiers: .command)
            Button(String(localized: "Import from Clipboard", comment: "Menu command")) { env.actions.importFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(env.settings.clipboardDenied)
            Divider()
            Button(String(localized: "Export…", comment: "Menu command")) { if let id = env.profiles.selection { env.actions.export(id) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(env.profiles.selection == nil)
            Button(String(localized: "Export All…", comment: "Menu command")) { env.actions.exportAll() }
        }
        CommandMenu(String(localized: "Profile", comment: "Menu")) {
            let c = env.connection.condition
            let selected = env.profiles.selection
            Button(c.isActive && selected == env.connection.profileID ? String(localized: "Disconnect", comment: "Menu command")
                                                                      : String(localized: "Connect", comment: "Menu command")) {
                if c.isActive && selected == env.connection.profileID { env.actions.disconnect() } else if let id = selected { env.gatedConnect(id) }
            }
            .keyboardShortcut("k", modifiers: .command)
            // Review 5 §3: a Connect the store would ignore isn't offered (Disconnect stays available).
            .disabled(selected == nil || (!(c.isActive && selected == env.connection.profileID)
                                          && env.profiles.profile(selected)?.connectHeld != nil))
            Menu(String(localized: "Pause Protection", comment: "Menu command")) {
                ForEach(PauseChoice.all, id: \.self) { m in
                    Button(PauseChoice.title(m)) { env.actions.pause(minutes: m) }
                }
            }
            .disabled(!c.showsPauseMenu(anyOnDemandEnabled: env.connection.anyOnDemandEnabled))
            Button(String(localized: "Resume Protection", comment: "Menu command")) { env.actions.resume() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled({ if case .paused = c { false } else { true } }())
            Divider()
            Button(String(localized: "Edit Config…", comment: "Menu command")) { if let id = selected { env.actions.editConfig(id) } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(selected == nil)
            Button(String(localized: "Duplicate", comment: "Menu command")) { if let id = selected { env.actions.duplicate(id) } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(selected == nil)
            // Asks first; enabled only while the sidebar has focus, so ⌘⌫ in a text field still deletes text.
            Button(String(localized: "Delete…", comment: "Menu command")) { if let id = sidebarProfile { env.presentation.requestDelete(id) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(sidebarProfile == nil)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(NavigationRequest.allCases.enumerated()), id: \.offset) { i, dest in
                Button(dest.title) { NavigationRequest.post(dest) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Link(String(localized: "Report an Issue", comment: "Help menu"), destination: LockPlusLinks.issues)
            Button(String(localized: "Show Logs", comment: "Help menu")) { NavigationRequest.post(.logs) }
        }
    }
}

/// ⌘1–⌘5 (View menu) → the main window's sidebar.
enum NavigationRequest: String, CaseIterable, Sendable {
    case profiles, activity, autoConnect, diagnostics, logs

    static let notification = Notification.Name("io.github.steiale.lockplus.navigate")

    var title: String {
        switch self {
        case .profiles: String(localized: "Profiles", comment: "View menu")
        case .activity: String(localized: "Activity", comment: "View menu")
        case .autoConnect: String(localized: "Auto-Connect", comment: "View menu")
        case .diagnostics: String(localized: "Diagnostics", comment: "View menu")
        case .logs: String(localized: "Logs", comment: "View menu")
        }
    }

    @MainActor static func post(_ dest: NavigationRequest) {
        SceneBridge.requestMainWindow()
        NotificationCenter.default.post(name: notification, object: nil, userInfo: ["dest": dest.rawValue])
    }
}
