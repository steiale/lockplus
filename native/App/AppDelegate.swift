import AppKit
import os

/// `AppDelegate` owns `AppEnvironment` and `MenuBarController` (DESIGN §11.1). Updates and login items join in P4.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let env: AppEnvironment
    private var menuBar: MenuBarController?
    private var windowCloseObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    override init() {
        // Under XCTest the host runs inert: preview backends, so no sysex request, NE save or keychain access.
        // DEBUG only (Fable M1): a Release build never takes the test or preview path.
        env = AppEnvironment(mode: Self.isRunningTests ? .preview : .detect())
        super.init()
        Self.current = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No LSUIElement: start as an accessory and switch to .regular before opening windows (§11.1 item 6).
        NSApp.setActivationPolicy(.accessory)
        LaunchContext.capture()             // E2E-5 F5: the launch event is only current now
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A test host must never submit a system-extension request (LockPlusTests run hosted in this app).
        guard !Self.isRunningTests else { return }
        let menuBar = MenuBarController(env: env.ui)
        menuBar.onMenuVisibilityChange = { [weak self] open in
            guard let self else { return }
            if open {
                self.env.stats.addConsumer(.menu)
                self.env.recordMenuOpened()
            } else {
                self.env.stats.removeConsumer(.menu)
            }
        }
        self.menuBar = menuBar
        // Back to .accessory when the last main/editor/Settings window closes (§11.1).
        windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { @Sendable note in
            let closing = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {      // SAFETY: queue .main
                let w = NSApp.windows.first { ObjectIdentifier($0) == closing }
                AppActivation.becomeAccessoryIfNoWindows(excluding: w)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {      // SAFETY: queue .main
                self?.env.connection.didWake()
            }
        }
        Task { @MainActor in
            await env.start()
            // §11.3 visibility policy: open the window when the icon may be hidden (or at login when asked).
            if env.settings.value.iconMayBeHidden || env.settings.value.openWindowAtLogin { env.ui.actions.openMainWindow() }
        }
    }

    /// The live delegate (SwiftUI wraps it, so `NSApp.delegate` isn't this object). Tests read the host's state here.
    private(set) static weak var current: AppDelegate?
    var hasMenuBar: Bool { menuBar != nil }

    static var isRunningTests: Bool {
        #if !DEBUG
        return false
        #else
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        #endif
    }

    func mainWindowVisibility(_ visible: Bool) {
        if visible { env.stats.addConsumer(.mainWindow) } else { env.stats.removeConsumer(.mainWindow) }
        env.logs.setVisible(visible)
    }

    /// The hidden bridge window is the first scene; closing "main" must not quit the menu-bar app (§11.1, S15).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click with no window: open the main window (a user gesture, §8.4).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { env.ui.actions.openMainWindow() }
        return true
    }

    /// Quit confirmation runs only for a quit from our own menu, before it calls `terminate` (§11.3). Everything else
    /// (Sparkle's install, Homebrew's `quit:`, logout) terminates at once (ref/sparkle §5.4).
    /// UI-M13 (UI worker's minimal edit): a user quit with unsaved profile editors asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { EditorRegistry.shared.terminateReply() }

    func applicationWillTerminate(_ notification: Notification) {
        env.stop()
        menuBar?.remove()       // L-MB-1
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
