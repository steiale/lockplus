import SwiftUI

/// Started from `main.swift` (`AppEntry`), which first handles the headless `--resume-protection` path (§10.4).
struct LockPlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 1. Hidden bridge FIRST: it gives AppKit code (the status menu) a SwiftUI context for openSettings/openWindow
        //    (§11.1, SceneSupport.swift). Kept ordered in, together with the delegate's `false` answer (S15).
        Window("LockPlusBridge", id: "bridge") { SceneBridge().frame(width: 0, height: 0) }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.presented)
            .restorationBehavior(.disabled)

        // 2. Main window: suppressed at launch (menu-bar app); opened through the bridge.
        Window("LockPlus", id: "main") {
            MainView()
                .environment(delegate.env.ui)
                .environment(\.selfTestStore, delegate.env.diagnostics)      // 2.0.2: the Connection Test (Diagnostics, hero)
                .lpTypography()
                .onAppear { delegate.mainWindowVisibility(true) }
                .onDisappear { delegate.mainWindowVisibility(false) }
        }
        .defaultSize(width: 920, height: 620)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .commands { LockPlusCommands(env: delegate.env.ui) }
        .commands { AppCommands(env: delegate.env.ui) }
        .lpDebugCommands(env: delegate.env)

        // 3. The profile editor (§11.4): never restored (secrets).
        WindowGroup("Edit Profile", for: EditorTarget.self) { $t in
            EditorWindow(target: t)
                .environment(delegate.env.ui)
                .environment(\.profileEditorBackend, delegate.env.editorBackend)
                .lpTypography()
        }
        .restorationBehavior(.disabled)
        // A document open event must never spawn an empty editor window (item 4, E2E O7): the router opens "main".
        .handlesExternalEvents(matching: [])

        // 4. Settings, AFTER the bridge.
        Settings {
            SettingsView()
                .environment(delegate.env.ui)
                .lpTypography()
                .onAppear { delegate.env.ui.actions.settingsDidAppear() }
        }
    }
}

extension Scene {
    /// The Debug menu exists only in DEBUG builds (§4.2); Release gets the scene unchanged.
    @MainActor func lpDebugCommands(env: AppEnvironment) -> some Scene {
        #if DEBUG
        commands { DebugCommands(env: env) }
        #else
        self
        #endif
    }
}
