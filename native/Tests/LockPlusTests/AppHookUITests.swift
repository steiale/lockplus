import AppKit
import LPModel
import SwiftUI
import Testing
@testable import LockPlus

/// UI for the app-root hooks in docs/native/APP-ROOT.md: §6.8 locked profiles, the inline auth error (M5), the
/// §4.5 refusal from AppActions.connect, and the §4.4 residual phase of the uninstall sheet.
@MainActor @Suite("App-root hook UI")
struct AppHookUITests {

    @Test("Locked profiles replace the empty library and the menu's Import item")
    func lockedState() throws {
        let env = UIEnvironment.preview(row: "15", profiles: [])
        env.profiles.locked = ["Work", "Home NAS"]
        let host = NSHostingView(rootView: EmptyLibraryView().environment(env).frame(width: 600, height: 460))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 460)
        host.layoutSubtreeIfNeeded()
        #expect(LockedProfilesCopy.confirmTitle(count: 2) == "Remove 2 locked profiles?")
        #expect(LockedProfilesCopy.confirmTitle(count: 1) == "Remove 1 locked profile?")

        let controller = MenuBarController(env: env)
        defer { controller.remove() }
        let menu = try #require(controller.item.menu)
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.contains { $0.title == LockedProfilesCopy.menuItem }, "\(menu.items.map(\.title))")
        env.profiles.locked = nil
        controller.menuNeedsUpdate(menu)
        #expect(!menu.items.contains { $0.title == LockedProfilesCopy.menuItem })
    }

    @Test("Removing locked profiles goes through LPUIActions (the app's implementation is dispatched)")
    func removeLockedDispatches() {
        let env = UIEnvironment.preview(row: "15", profiles: [])
        let actions = env.actions as! PreviewUIActions
        env.actions.removeLockedProfiles()
        #expect(actions.log.contains("removeLockedProfiles"))
    }

    @Test("Re-import while locked asks to start over, then dispatches startOverAndReimport")
    func startOverDispatches() {
        let env = UIEnvironment.preview(row: "15", profiles: [])
        env.profiles.locked = ["Work"]
        let actions = env.actions as! PreviewUIActions
        #expect(LockedProfilesCopy.startOverTitle == "Start over?")
        #expect(LockedProfilesCopy.startOverMessage.contains("creates a new key"))
        #expect(!actions.log.contains("startOverAndReimport"))       // the button only confirms
        env.actions.startOverAndReimport()
        #expect(actions.log == ["startOverAndReimport"])
        #expect(!actions.log.contains("removeLockedProfiles"))
        #expect(env.profiles.locked == nil)
    }

    @Test("Import from old LockPlus while locked confirms a start over, then dispatches the migration flow")
    func importFromOldAppDispatches() {
        let env = UIEnvironment.preview(row: "15", profiles: [])
        env.profiles.locked = ["Work"]
        env.onboarding.migration = .init(profileNames: ["old-office"], savedPasswords: 0)
        let actions = env.actions as! PreviewUIActions
        #expect(LockedProfilesCopy.migrateButton == "Import from Old LockPlus…")
        #expect(LockedProfilesCopy.startOverMigrateMessage.contains("creates a new key"))
        env.actions.startOverAndImportFromOldApp()
        #expect(actions.log == ["startOverAndImportFromOldApp"])
        #expect(env.profiles.locked == nil)
        #expect(env.onboarding.isPresented && env.onboarding.step == .profiles)
    }

    @Test("A refusal from AppActions.connect has its own message when the notice hasn't caught up; it is a strip, never an alert sheet (E2E-5 F8)")
    func refusalFallback() {
        let env = UIEnvironment.preview(row: "15")
        env.connection.connectGate = .refused(PreviewData.workID)
        #expect(env.connection.legacyHelper == nil)
        #expect(MainAlert.active(in: env) == nil)                      // no sheet: Quit isn't blocked
        #expect(MainSheet.active(in: env) == nil)
        #expect(!LegacyHelperCopy.refuseFallback.isEmpty)
    }

    @Test("Residuals show in the uninstall sheet and wait for OK; without a sheet the caller falls back")
    func residualPhase() async {
        let s = SettingsUIModel()
        s.uninstallPhase = .componentStillInstalled
        #expect(await s.presentResidual("left over") == false)      // no sheet: the alert path
        s.uninstallSheetVisible = true
        let done = Task { @MainActor in await s.presentResidual("left over") }
        await Task.yield()
        #expect(s.uninstallPhase == .residual("left over"))
        s.acknowledgeResidual()
        #expect(await done.value == true)
        #expect(s.uninstallPhase == .componentStillInstalled)       // back to Try Again
    }
}
