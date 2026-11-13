import AppKit
import Foundation
import LocalAuthentication
import os
import ServiceManagement
import UserNotifications

/// Calls into the host system that preview mode and tests must never make (login items, LAContext, moving the app
/// to the Trash, notification permission). `LiveSystemHooks` is the real one; `InertSystemHooks` does nothing.
@MainActor protocol SystemHooks: AnyObject {
    /// LAContext (§4.4 step 1, §4.6 step 1, RevealGate A6). false = the user cancelled.
    func authenticate(reason: String) async -> Bool
    func loginItemState() -> LoginItemState
    func setLaunchAtLogin(_ on: Bool) -> LoginItemState
    func notificationsDenied() async -> Bool
    func requestNotificationPermission() async
    /// §11.7: asked once at the end of onboarding, or when a non-Off mode is chosen while undecided.
    func notificationAuthorization() async -> NotificationAuthorization
    /// Posts a user notification (the caller applied `NotificationPolicy`).
    func post(_ notice: UserNotice)
    /// A main, editor or Settings window of ours is key (notifications are posted only while none is).
    func anyWindowKey() -> Bool
    /// Clicking a notification (a user gesture): open the main window.
    var onNotificationActivated: (@MainActor () -> Void)? { get set }
    /// FA-L5: another LockPlus instance holds the instance lock: tell the user, then quit.
    func quitBecauseAlreadyRunning() async
    /// E2E-5 F5: the same, without the alert, for a second instance started at login (the old app's LaunchAgent or a
    /// login item): nobody asked for it, so nobody is told.
    func quitSilently()
    /// §4.4: the final sheet naming what stayed behind (a modal the user dismisses).
    func showUninstallResidual(_ message: String) async
    /// §4.4 steps 8–9: unregister the login item, move the app to the Trash, quit.
    func finishUninstall() async
}

@MainActor final class LiveSystemHooks: SystemHooks {
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "system")
    private let notifications = UserNotificationCenterBridge()
    var onNotificationActivated: (@MainActor () -> Void)? {
        didSet {
            notifications.onActivate = onNotificationActivated
            notifications.install()
        }
    }

    func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) } catch {
            // 200026 E2E (Edit Config…): a refused or cancelled prompt ends the action silently by design; logged (the
            // LAError code only, never the reason, which names the profile) so "nothing happened" can be told apart
            // from a window that didn't open.
            log.notice("authentication not granted: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            return false
        }
    }

    func loginItemState() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    /// Register on toggle-on (already registered = success; code 1 = approval pending), unregister on toggle-off
    /// (job not found = success). Never automatic (NR pitfall 14).
    func setLaunchAtLogin(_ on: Bool) -> LoginItemState {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.notice("login item \(on ? "register" : "unregister", privacy: .public): \((error as NSError).code, privacy: .public)")
        }
        return loginItemState()
    }

    func notificationsDenied() async -> Bool { await notifications.authorization() == .denied }
    func requestNotificationPermission() async { await notifications.requestAuthorization() }
    func notificationAuthorization() async -> NotificationAuthorization { await notifications.authorization() }
    func post(_ notice: UserNotice) { notifications.post(notice) }

    /// The hidden bridge window (alpha 0, 0×0) and panels don't count.
    func anyWindowKey() -> Bool {
        guard NSApp.isActive, let w = NSApp.keyWindow else { return false }
        return w.isVisible && w.alphaValue > 0 && w.frame.width > 20 && !(w is NSPanel)
    }

    func quitBecauseAlreadyRunning() async {
        let a = NSAlert()
        a.messageText = String(localized: "LockPlus is already running", comment: "Second instance alert")
        a.informativeText = String(localized: "Use the LockPlus icon in the menu bar.", comment: "Second instance alert")
        a.addButton(withTitle: String(localized: "OK", comment: "Button"))
        a.runModal()
        NSApp.terminate(nil)
    }

    func quitSilently() { NSApp.terminate(nil) }

    /// The uninstall sheet's residual phase (`SettingsUIModel.presentResidual`); false = no sheet, use the alert.
    var presentResidual: (@MainActor (String) async -> Bool)?

    func showUninstallResidual(_ message: String) async {
        if let presentResidual, await presentResidual(message) { return }
        let a = NSAlert()
        a.messageText = String(localized: "LockPlus couldn't remove everything", comment: "§4.4 residual sheet title")
        a.informativeText = message
        a.addButton(withTitle: String(localized: "OK", comment: "Button"))
        a.runModal()
    }

    func finishUninstall() async {
        try? await SMAppService.mainApp.unregister()
        let app = Bundle.main.bundleURL
        do { _ = try await NSWorkspace.shared.recycle([app]) } catch {
            // E2E-1 (26): another admin installed the app, the move needed authentication and was cancelled. Say so
            // instead of quitting silently with the app still in Applications.
            log.error("uninstall: moving the app to the Trash failed: \((error as NSError).code, privacy: .public)")
            Self.endAttachedSheets(NSApp.windows)
            await showUninstallResidual(Self.trashFailedMessage)
        }
        // E2E-1: the Settings uninstall sheet is still attached here, and AppKit refuses to quit with a sheet up
        // ("App termination blocked by modal sheet"): the app stayed running after a successful uninstall.
        Self.endAttachedSheets(NSApp.windows)
        NSApp.terminate(nil)
    }

    static var trashFailedMessage: String {
        String(localized: "The tunnel component was removed, but LockPlus couldn't move itself to the Trash. Drag LockPlus from Applications to the Trash to finish.", comment: "§4.4 uninstall: the app bundle could not be moved to the Trash")
    }

    /// Ends every sheet attached to these windows, nested sheets first, in ONE bounded loop (review PF-R6: a sheet
    /// that won't detach must not spin the quit path). Returns false, and logs, when `cap` steps weren't enough.
    @discardableResult
    static func endAttachedSheets(_ windows: [NSWindow], cap: Int = 8) -> Bool {
        var stack = windows.filter { $0.attachedSheet != nil }
        var steps = 0
        while let w = stack.last, steps < cap {
            steps += 1
            guard let s = w.attachedSheet else { stack.removeLast(); continue }
            if s.attachedSheet != nil { stack.append(s); continue }        // the innermost sheet ends first
            w.endSheet(s)
            s.orderOut(nil)
        }
        let done = stack.allSatisfy { $0.attachedSheet == nil }
        if !done { sheetLog.error("uninstall: sheets still attached after \(cap, privacy: .public) steps; quitting anyway") }
        return done
    }

    private static let sheetLog = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "system")
}

/// Preview mode and tests: records, touches nothing.
@MainActor final class InertSystemHooks: SystemHooks {
    private(set) var calls: [String] = []
    private(set) var posted: [UserNotice] = []
    var authenticateResult = true
    var authorization = NotificationAuthorization.notDetermined
    var windowKey = false
    var onNotificationActivated: (@MainActor () -> Void)?
    private var loginItem = LoginItemState.disabled

    /// Tests (round 1, Codex 5): runs while the authentication is "showing", so a change can land inside the wait.
    var duringAuthenticate: (@MainActor () async -> Void)?
    func authenticate(reason: String) async -> Bool {
        calls.append("authenticate")
        await duringAuthenticate?()
        return authenticateResult
    }
    func loginItemState() -> LoginItemState { loginItem }
    func setLaunchAtLogin(_ on: Bool) -> LoginItemState { calls.append("launchAtLogin \(on)"); loginItem = on ? .enabled : .disabled; return loginItem }
    func notificationsDenied() async -> Bool { false }
    func requestNotificationPermission() async { calls.append("notifications"); authorization = .authorized }
    func notificationAuthorization() async -> NotificationAuthorization { authorization }
    func post(_ notice: UserNotice) { posted.append(notice) }
    func anyWindowKey() -> Bool { windowKey }
    private(set) var residualMessages: [String] = []
    func quitBecauseAlreadyRunning() async { calls.append("alreadyRunning") }
    func quitSilently() { calls.append("quitSilently") }
    func showUninstallResidual(_ message: String) async { residualMessages.append(message) }
    func finishUninstall() async { calls.append("finishUninstall") }
}
