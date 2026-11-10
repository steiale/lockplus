import AppKit
import Foundation
import Observation

/// Intents the UI sends. The app implements this over its stores (ConnectionStore, AuthCoordinator,
/// ImportCoordinator, …); previews use `PreviewUIActions`. Every method is main-actor: callers are views and
/// AppKit menu actions. Implementations hand work to actors/XPC with `@Sendable` closures (DESIGN §11.2).
@MainActor protocol LPUIActions: AnyObject {
    // Connection
    /// Starts with `startVPNTunnel(options:)` including `lp.manual = 1` (NSNumber); the UI never builds options.
    func connect(_ profileID: ProfileItem.ID)
    /// §4.5 "Connect Anyway" after the crashed-helper warning: the same re-check as `connect`, without the warning.
    func connectAnyway(_ profileID: ProfileItem.ID)
    func disconnect()
    /// A derived-state action for the condition's profile (`ConnectionCondition.actions`).
    func perform(_ action: StateAction)
    func pause(minutes: Int)
    func resume()

    // Auth (§6.5)
    func submitAuth(_ answer: AuthAnswer)
    func cancelAuth(_ promptID: UUID)
    func retryAuthApproval(_ promptID: UUID)

    // Profiles
    func newProfile(_ kind: ProfileKindChoice)
    func editConfig(_ profileID: ProfileItem.ID)
    func export(_ profileID: ProfileItem.ID)
    func exportAll()
    func duplicate(_ profileID: ProfileItem.ID)
    func delete(_ profileID: ProfileItem.ID)
    func rename(_ profileID: ProfileItem.ID, to name: String)
    func setKillSwitch(_ on: Bool, for profileID: ProfileItem.ID)
    func setAllowLocalNetwork(_ on: Bool, for profileID: ProfileItem.ID)
    func setBlockIPv6(_ on: Bool, for profileID: ProfileItem.ID)
    func setNotes(_ notes: String, for profileID: ProfileItem.ID)
    func changePassword(_ profileID: ProfileItem.ID)
    func forgetPassword(_ profileID: ProfileItem.ID)
    func showPassword(_ profileID: ProfileItem.ID)

    // Import (§6.8)
    func importFiles(_ urls: [URL])
    func importFromClipboard()
    func confirmImport(_ preview: ImportPreview)
    func confirmBatch(_ batch: BatchImport)
    func cancelImport()

    // Windows
    func openMainWindow()
    func openSettings()
    func quitFromMenu()

    // System extension and configuration (§6.14)
    /// Onboarding Install/Try Again and the "Approve…" banner: `ExtensionStore.retryAfterUserAction()` (clears the
    /// 4102 unauthorized-peer state), never SystemExtensionManager directly.
    func installExtension()
    /// "Reinstall…": `ExtensionStore.reinstall()`.
    func reinstallExtension()
    /// E2E-4: "Try Again" in the empty library after the profile files couldn't be read.
    func reloadProfiles()
    func allowVPNConfiguration()
    func finishOnboarding()
    func importMigration(_ names: Set<String>)
    /// §6.7 opt-in: also migrate saved OpenVPN passwords (one system prompt per item).
    func importMigration(_ names: Set<String>, includingSavedPasswords: Bool)
    func addEtcWireGuardProfiles()
    /// E2E-5 F4: Settings › Advanced "Import from Old LockPlus…": looks for the old app's data (`detect(force: true)`),
    /// any time, also after a finished or skipped migration.
    func findOldLockPlusData()
    /// The migration sheet closed (Cancel or Done).
    func closeMigration()
    /// §6.8: deletes the locked profiles (files and saved passwords). The UI confirms first.
    func removeLockedProfiles()
    /// §6.8 "Re-import…" while locked: moves the locked profiles aside, creates a new key, then shows the import
    /// panel. The UI confirms first.
    func startOverAndReimport()
    /// §6.8 "Import from old LockPlus" while locked (offered only when `OnboardingUIModel.migration` is set): the same
    /// start over, then the existing migration flow (onboarding's profiles step → `importMigration`). The UI confirms first.
    func startOverAndImportFromOldApp()
    func requestNotificationPermission()

    // Settings
    func setLaunchAtLogin(_ on: Bool)
    /// Settings appeared: re-read `SMAppService.mainApp.status` and notification authorization (no change notification exists).
    func settingsDidAppear()
    func showInMenuBar()
    func checkForUpdates()
    /// Sets `SettingsUIModel.uninstallPhase`: `.componentStillInstalled` when deactivate() throws `.cancelled`.
    func uninstall()
    /// §4.4 step 7 (requirement, so the app's implementation is dispatched; default below).
    func uninstall(deletingProfilesAndHistory: Bool)

    // Diagnostics, logs, activity
    /// The redacted files of the diagnostics bundle, for the "What's inside" preview (§14.2).
    func prepareDiagnosticsPreview() async -> [DiagnosticsPreviewFile]
    /// Builds the bundle again and asks where to save it.
    func exportDiagnostics()
    /// §4.5: opens the old LockPlus (Go app) so the user can quit it or remove its helper.
    func openOldLockPlus()
    /// E2E-5 F1: removes the old helper after one administrator authentication (`LegacyHelperStore.removeHelper`).
    func removeOldHelper()
    /// The removal's result strip was dismissed.
    func dismissOldHelperRemoval()
    /// Migration matrix: moves the old WireGuide+ app to the Trash (after the UI's confirmation).
    func trashOldWireGuidePlusApp()
    func runDiagnostics()
    func reloadRoutes()
    func copyLogs()
    func saveLogs()
    func clearLogs()
    func clearHistory()
    /// Opens Logs filtered around a session start (Activity context menu, §6.10).
    func showLogs(around date: Date)

    // Auto-Connect (§6.7)
    func addCurrentNetwork()
    func requestLocationAccess()
}

extension LPUIActions {
    /// §4.4 step 7: the uninstall sheet's "Also delete your profiles and history" choice. The default forwards to
    /// `uninstall()` (profiles kept) so existing conformers compile; the app overrides it to honour the flag.
    func uninstall(deletingProfilesAndHistory: Bool) { uninstall() }
    func importMigration(_ names: Set<String>, includingSavedPasswords: Bool) { importMigration(names) }
    func connectAnyway(_ profileID: ProfileItem.ID) { connect(profileID) }
    func prepareDiagnosticsPreview() async -> [DiagnosticsPreviewFile] { [] }
    func exportDiagnostics() {}
    func openOldLockPlus() {}
    func removeOldHelper() {}
    func findOldLockPlusData() {}
    func closeMigration() {}
    func dismissOldHelperRemoval() {}
    func trashOldWireGuidePlusApp() {}
    func removeLockedProfiles() {}
    func startOverAndReimport() {}
    func startOverAndImportFromOldApp() {}
}

/// One redacted file of the diagnostics bundle (the app maps `DiagnosticsBundle.File`).
struct DiagnosticsPreviewFile: Identifiable, Sendable, Equatable {
    var name: String
    var text: String
    var id: String { name }
}

/// §4.5 old Go helper finding (the app maps `LegacyHelperStore.finding`). nil: nothing found.
struct LegacyHelperNotice: Sendable, Equatable {
    var message: String
    /// The old helper's firewall would fight the tunnel: Connect is refused.
    var blocksConnect: Bool
    /// The old helper crashed with its firewall on: warn before connecting.
    var warnsBeforeConnect: Bool
    /// The old app is still installed, so "Open the old LockPlus" can do something (E2E-5 F8).
    var oldAppInstalled = false
    /// The helper is installed and idle: the banner offers "Remove Old Helper…" (E2E-5 F1).
    var canRemoveHelper = false
}

/// E2E-5 F1: where "Remove Old Helper" stands.
enum LegacyHelperRemovalState: Sendable, Equatable {
    case removing
    /// `leftNetworkState`: the helper's DNS journal or pf marker stayed (a restart clears that state).
    /// `staleTunnel` (E2E-7 F3 review L3): the old helper had crashed with a tunnel up and its crash recovery never ran, so
    /// its endpoint routes stay until a restart.
    case removed(leftNetworkState: Bool, staleTunnel: Bool = false)
    case cancelled
    case failed(Failure)

    enum Failure: Sendable, Equatable {
        /// The old LockPlus is connected or its kill switch is on (§4.5): nothing was changed.
        case busy
        /// E2E-7 F3 review L4/L5: root said busy because of a tunnel-state file (`LP_BUSY=tunnel`) while LockPlus itself
        /// is connected: its utun may carry the number a crashed old tunnel recorded, so disconnecting LockPlus comes first.
        case busyWhileConnected
        /// The old app is running: its health monitor would reinstall the helper (review E2E-5 F1-1).
        case oldAppRunning
        /// The helper isn't running and its DNS journal was never replayed (review E2E-5 F1-2).
        case dnsNotRestored
        /// Review 650b251: the journal holds the user's own DNS servers; the old helper restores them at its next start.
        case dnsRestartRestores
        /// Fable follow-up LOW-3: the helper's socket is there but it doesn't answer.
        case notResponding
        /// E2E-6 N2: only 1.0.x's DNS-protection rules are left in its pf anchor (no tunnel, no kill switch).
        case dnsProtectionLeft
        /// The installed files aren't the Go helper's (owner, label, path or signature): nothing was changed.
        case notTheOldHelper
        /// The helper is still there after the run.
        case incomplete
        /// The administrator authorization or the run itself failed (the system's message).
        case couldNotRun(String)
    }
}

/// A Connect that the old-helper rule stopped, waiting for the user (§4.5). Shown as a strip above the detail, not as an
/// alert sheet (E2E-5 F8: the sheet blocked Quit, including AppleScript `quit` and logout).
enum ConnectGateRequest: Identifiable, Sendable, Equatable {
    case refused(ProfileItem.ID)
    case warn(ProfileItem.ID)
    var id: String {
        switch self {
        case .refused(let p): "refused-\(p)"
        case .warn(let p): "warn-\(p)"
        }
    }
}

extension UIEnvironment {
    /// Every Connect in the UI goes through here. The §4.5 old-helper rule is decided by `actions.connect`, which
    /// re-reads the old helper on EVERY attempt (E2E-5 F3): a refusal is never repeated from the cached notice, so
    /// Connect works again as soon as the old tunnel is down. A new attempt replaces an earlier refusal or warning.
    func gatedConnect(_ profileID: ProfileItem.ID) {
        connection.connectGate = nil
        actions.connect(profileID)
    }
}

enum ProfileKindChoice: Sendable { case wireGuard, openVPN }

/// System Settings deep links (§6.14, DESIGN §4.2). Opened by the UI itself; no store involved.
enum SystemSettingsLink {
    /// "Show the Switch Again": Login Items & Extensions › Network Extensions.
    static let networkExtensions = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    static let loginItems = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    static let notifications = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    static let locationPrivacy = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices")!
    static let pastePrivacy = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard")!
    static let menuBar = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
    static let vpn = URL(string: "x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension")!

    @MainActor static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Everything the UI reads, injected once with `.environment(env)` and handed to `MenuBarController`.
@MainActor @Observable final class UIEnvironment {
    let profiles: ProfilesUIModel
    let connection: ConnectionUIModel
    let stats: StatsUIModel
    let auth: AuthUIModel
    let settings: SettingsUIModel
    let onboarding: OnboardingUIModel
    let importer: ImportUIModel
    let activity: ActivityUIModel
    let diagnostics: DiagnosticsUIModel
    let logs: LogsUIModel
    let autoConnect: AutoConnectUIModel
    @ObservationIgnored let actions: any LPUIActions
    /// Confirmations and sheets requested by several views (no store owns them). Default-initialised, so the app
    /// root's `init` call is unchanged.
    let presentation = PresentationModel()

    init(profiles: ProfilesUIModel, connection: ConnectionUIModel, stats: StatsUIModel, auth: AuthUIModel,
         settings: SettingsUIModel, onboarding: OnboardingUIModel, importer: ImportUIModel,
         activity: ActivityUIModel, diagnostics: DiagnosticsUIModel, logs: LogsUIModel,
         autoConnect: AutoConnectUIModel, actions: any LPUIActions) {
        self.profiles = profiles
        self.connection = connection
        self.stats = stats
        self.auth = auth
        self.settings = settings
        self.onboarding = onboarding
        self.importer = importer
        self.activity = activity
        self.diagnostics = diagnostics
        self.logs = logs
        self.autoConnect = autoConnect
        self.actions = actions
    }

    /// The profile the derived state talks about.
    var conditionProfile: ProfileItem? { profiles.profile(connection.profileID) }

    var conditionContext: ProfileContext {
        conditionProfile?.context(errorDetail: connection.lastErrorDetail)
            ?? ProfileContext(name: connection.inputs.profileName, place: nil, protocolName: "")
    }

    /// The derived state as it applies to one profile row: the condition for the active profile, otherwise the
    /// profile's resting glyph (sidebar and menu items, §6.3).
    func glyph(for profile: ProfileItem) -> GlyphState {
        profile.id == connection.profileID ? connection.condition.glyph : .unprotected
    }

    /// Switch confirmation (§6.2): only when the active profile has the kill switch on and the target doesn't.
    func switchNeedsConfirmation(to target: ProfileItem) -> Bool {
        guard connection.condition.isActive, let active = conditionProfile, active.id != target.id else { return false }
        return active.killSwitch && !target.killSwitch
    }
}
