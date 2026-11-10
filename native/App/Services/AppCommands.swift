import SwiftUI

/// "Check for Updates…" in the app menu (§12.1) and "Export Diagnostics…" in Help (§14.2). Enabled from the updater's `canCheckForUpdates` (KVO, mirrored into
/// `SettingsUIModel`). The menu-bar "Update Available…" item and Settings › About call the same action.
struct AppCommands: Commands {
    let env: UIEnvironment

    var body: some Commands {
        CommandGroup(after: .help) {
            Button(String(localized: "Export Diagnostics…", comment: "Help menu command (§14.2)")) {
                (env.actions as? AppActions)?.exportDiagnostics()
            }
        }
        CommandGroup(after: .appInfo) {
            Button(String(localized: "Check for Updates…", comment: "App menu command (§12.1)")) { env.actions.checkForUpdates() }
                .disabled(!env.settings.canCheckForUpdates)
        }
    }
}
