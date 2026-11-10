#if DEBUG
import AppKit
import LPModel
import os
import SwiftUI

/// Debug menu (DESIGN §4.2): DEBUG builds only. The ⌥-click-on-About entry point joins with P4's About view.
struct DebugCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Activate Extension") { Task { await env.systemExtensions?.activate() } }
            Button("Deactivate Extension") { Task { await DebugLog.deactivate(env) } }
            // L-EXT-6: each activation of a rebuilt Apple Development extension needs approval in System Settings;
            // deactivated-but-not-removed extensions clear at reboot.
            Button("Deactivate + Activate") {
                Task {
                    if await DebugLog.deactivate(env) { await env.systemExtensions?.activate() }
                }
            }
            Button("Show the Switch Again") { env.extensionStore.openExtensionSettings() }
            Divider()
            Button("Send Hello + Reconcile") { env.helloAndReconcile() }
            Button("Show Extension Log") { DebugLog.showExtensionLog() }
        }
    }
}

enum DebugLog {
    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "debug")

    /// Deactivates and logs a failure or cancellation instead of swallowing it. Returns whether it succeeded.
    @MainActor static func deactivate(_ env: AppEnvironment) async -> Bool {
        do throws(LPError) {
            try await env.extensionStore.deactivate()
            return true
        } catch {
            log.error("deactivate failed: \(error.code.rawValue, privacy: .public) \(error.detail ?? "", privacy: .public)")
            return false
        }
    }

    /// A sysex logs as root; Console shows it with the subsystem filter. The stream command goes to the pasteboard.
    static let command = #"log stream --level debug --predicate 'subsystem BEGINSWITH "io.github.steiale.lockplus"'"#

    @MainActor static func showExtensionLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        if let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.openApplication(at: console, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
#endif
