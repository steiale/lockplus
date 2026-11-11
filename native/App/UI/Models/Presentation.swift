import Observation
import SwiftUI

/// Presentation state that isn't owned by a store: confirmations and sheets that several views can request.
/// The main window presents ONE sheet at a time from `MainSheet.active(in:)` (priority queue, auth first) and one
/// alert from `MainAlert.active(in:)`, so a late auth prompt never fails to present behind another sheet.
@MainActor @Observable final class PresentationModel {
    /// "Delete…" (⌘⌫, context menu, sidebar −): asks before `actions.delete` (UI-H1).
    var pendingDelete: ProfileItem.ID?
    /// Pause duration waiting for confirmation (PauseConfirmSheet).
    var pauseMinutes: Int?
    var showErrorDetails = false

    init() {}

    /// Every "Delete…" goes through here; nothing deletes without the confirmation.
    func requestDelete(_ id: ProfileItem.ID) { pendingDelete = id }
}

/// The main window's sheets, highest priority first (UI-M9).
enum MainSheet: Identifiable {
    case auth(AuthPromptState)
    case onboarding
    /// E2E-5 F4: "Import from Old LockPlus" outside onboarding (the "finish" banner).
    case migration
    case passwordReveal(PasswordReveal)
    case passwordChange(PasswordChangeRequest)
    case importPreview(ImportPreview)
    case batchImport(BatchImport)
    case pause(Int)
    case errorDetails

    var id: String {
        switch self {
        case .auth(let p): "auth-\(p.id)"
        case .onboarding: "onboarding"
        case .migration: "migration"
        case .passwordReveal(let r): "reveal-\(r.id)"
        case .passwordChange(let r): "change-\(r.id)"
        case .importPreview(let p): "import-\(p.id)"
        case .batchImport(let b): "batch-\(b.id)"
        case .pause(let m): "pause-\(m)"
        case .errorDetails: "errorDetails"
        }
    }

    @MainActor static func active(in env: UIEnvironment) -> MainSheet? {
        if let p = env.auth.prompt { return .auth(p) }
        if env.onboarding.isPresented { return .onboarding }
        if env.onboarding.migrationSheetPresented { return .migration }
        if let r = env.profiles.passwordReveal { return .passwordReveal(r) }
        if let r = env.profiles.passwordChange { return .passwordChange(r) }
        if let p = env.importer.preview { return .importPreview(p) }
        if let b = env.importer.batch { return .batchImport(b) }
        if let m = env.presentation.pauseMinutes { return .pause(m) }
        if env.presentation.showErrorDetails { return .errorDetails }
        return nil
    }

    /// 2.0.1 E2E F5: the sheets shown ON TOP of onboarding. Onboarding outranks the import preview in `active`, so a
    /// file chosen in step 4 ("Choose Files…") produced a preview nobody could see (and, once onboarding closed, the
    /// dismissal cleared it). While onboarding is up its own sheet presents the import preview or batch.
    @MainActor static func nested(in env: UIEnvironment) -> MainSheet? {
        guard case .onboarding? = active(in: env) else { return nil }
        if let p = env.importer.preview { return .importPreview(p) }
        if let b = env.importer.batch { return .batchImport(b) }
        return nil
    }

    /// The sheet was dismissed: clear its source.
    @MainActor func clear(in env: UIEnvironment) {
        switch self {
        case .auth: env.auth.prompt = nil
        case .onboarding: env.onboarding.isPresented = false
        case .migration: env.onboarding.closeMigration()
        case .passwordReveal: env.profiles.passwordReveal = nil
        case .passwordChange: env.profiles.passwordChange = nil
        case .importPreview: env.importer.preview = nil
        case .batchImport: env.importer.batch = nil
        case .pause: env.presentation.pauseMinutes = nil
        case .errorDetails: env.presentation.showErrorDetails = false
        }
    }

    @MainActor @ViewBuilder var content: some View {
        switch self {
        case .auth(let p): AuthPromptView(prompt: p)
        case .onboarding: OnboardingSheet()
        case .migration: MigrationSheet()
        case .passwordReveal(let r): RevealPasswordSheet(reveal: r)
        case .passwordChange(let r): ChangePasswordSheet(request: r)
        case .importPreview(let p): ImportPreviewSheet(preview: p)
        case .batchImport(let b): BatchImportSheet(batch: b)
        case .pause(let m): PauseConfirmSheet(minutes: m)
        case .errorDetails: ErrorDetailsSheet()
        }
    }
}

/// The main window's alerts, highest priority first. The §4.5 connect gate is a strip (`ConnectGateStrip`), not an
/// alert: an alert sheet blocked Quit (E2E-5 F8).
enum MainAlert: Identifiable, Equatable {
    case importError(String)

    var id: String {
        switch self {
        case .importError(let m): "import-\(m)"
        }
    }

    @MainActor static func active(in env: UIEnvironment) -> MainAlert? {
        if let m = env.importer.errorMessage { return .importError(m) }
        return nil
    }

    @MainActor func clear(in env: UIEnvironment) {
        switch self {
        case .importError: env.importer.errorMessage = nil
        }
    }
}

/// The sidebar publishes the selected profile only while it has focus, so ⌘⌫ never fires from a text field (UI-H1).
struct SidebarProfileFocusKey: FocusedValueKey {
    typealias Value = ProfileItem.ID
}

extension FocusedValues {
    var sidebarProfile: ProfileItem.ID? {
        get { self[SidebarProfileFocusKey.self] }
        set { self[SidebarProfileFocusKey.self] = newValue }
    }
}
