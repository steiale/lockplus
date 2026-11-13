import Foundation
import LPModel
import Observation

// MARK: - Settings (§6.13)

/// Uninstall flow (§6.13): the admin-password dialog can be cancelled, leaving the tunnel component installed.
enum UninstallPhase: Sendable, Equatable {
    case confirm, uninstalling, componentStillInstalled
    /// §4.4: what stayed behind, named before the app quits (or before "Try Again").
    case residual(String)
}
enum LoginItemState: Sendable, Equatable { case enabled, disabled, requiresApproval }
enum AppLanguage: String, Sendable, CaseIterable, Identifiable {
    case system, en, de          // v2.0 ships English and German (lead decision)
    var id: String { rawValue }
}
enum AppAppearance: String, Sendable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
}
enum NotificationMode: String, Sendable, CaseIterable, Identifiable {
    case problemsOnly, connectAndDisconnect, off
    var id: String { rawValue }
}
enum RateLabelMode: String, Sendable, CaseIterable, Identifiable {
    case off, download, both
    var id: String { rawValue }
}
enum IconStyle: String, Sendable, CaseIterable, Identifiable {
    case monochrome, color
    var id: String { rawValue }
}
enum LogLevel: String, Sendable, CaseIterable, Identifiable {
    case error, warning, info, debug
    var id: String { rawValue }
}

@MainActor @Observable final class SettingsUIModel {
    // General
    var launchAtLogin: LoginItemState = .disabled
    /// E2E-5 F5: LockPlus 1.x opened at login (its LaunchAgent was just retired): offer LockPlus's own launch at login.
    var launchAtLoginOffer = false
    var openWindowAtLogin = false
    var language: AppLanguage = .system
    var appearance: AppAppearance = .system
    var notifications: NotificationMode = .problemsOnly
    var notificationsDeniedBySystem = false
    // Menu Bar
    var showInMenuBar = true
    var rateLabel: RateLabelMode = .both
    var iconStyle: IconStyle = .color
    /// The "menu never opened in the last 5 launches" heuristic fired (§6.1).
    var iconMayBeHidden = false
    // Profiles
    var defaultKillSwitchForFullTunnels = true
    var defaultAllowLocalNetwork = false
    // Advanced
    var logLevel: LogLevel = .info
    var receiveReleaseCandidates = false
    var isDevBuild = false
    // About
    var version = "2.0"
    var build = "1"
    var canCheckForUpdates = true
    var updateAvailable = false
    /// "Clipboard access is off for LockPlus" (§6.8, F-8).
    var clipboardDenied = false
    var uninstallPhase: UninstallPhase = .confirm
    /// The uninstall sheet is on screen, so residuals can be shown in it instead of an alert.
    var uninstallSheetVisible = false
    @ObservationIgnored private var residualAck: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var phaseBeforeResidual: UninstallPhase = .uninstalling

    init() {}

    /// §4.4 residual sheet: shows `message` in the uninstall sheet and returns once the user dismissed it. false =
    /// no uninstall sheet is showing; the caller falls back to an alert (never waits on a sheet nobody sees).
    func presentResidual(_ message: String) async -> Bool {
        guard uninstallSheetVisible else { return false }
        acknowledgeResidual()
        phaseBeforeResidual = uninstallPhase
        await withCheckedContinuation { c in
            residualAck = c
            uninstallPhase = .residual(message)
        }
        return true
    }

    /// OK, or the sheet went away.
    func acknowledgeResidual() {
        guard let c = residualAck else { return }
        residualAck = nil
        if case .residual = uninstallPhase { uninstallPhase = phaseBeforeResidual }
        c.resume()
    }
}

// MARK: - Onboarding (§6.14)

@MainActor @Observable final class OnboardingUIModel {
    enum Step: Int, Sendable, CaseIterable { case welcome, installExtension, allowConfiguration, profiles, done }
    enum ExtensionStep: Sendable, Equatable {
        case idle, requesting, needsApproval, rebootRequired, failed(String), done
    }
    enum ConfigurationStep: Sendable, Equatable {
        case explain, requesting, denied, done
        /// The save waits for a running or starting VPN (review 5 #5); the step can be continued, the message says when.
        case deferred(message: String)
    }
    struct MigrationOffer: Sendable, Equatable {
        var profileNames: [String]
        var savedPasswords: Int
        /// E2E-5 F4: an earlier import didn't finish; this run completes it (possibly with no profiles left to copy).
        var finishesEarlierImport = false
    }
    struct MigrationReport: Sendable, Equatable {
        var imported: [String]
        var needsAttention: [String]
        var notMigrated: [String]
        /// Per profile, nothing to do: harmless ignored lines, migration notes (E2E-5 F6).
        var info: [String] = []
        /// What changed for the whole app (appearance, DNS, per-network choices, a finished earlier import).
        var notes: [String] = []
        /// LockPlus 1.x opened at login (its `auto_start`, or its LaunchAgent): offer LockPlus's own (E2E-5 F5, F6).
        var offerLaunchAtLogin = false
    }

    /// With no profile yet, macOS has nothing to ask about: its "add VPN configurations" alert comes with the first
    /// profile that is added (the import in step 4), not in step 3. With profiles (re-onboarding) step 3 saves one now.
    /// Once a LockPlus VPN configuration exists in the system (`configurationExists`) macOS has asked already: a user who
    /// allowed it, deleted every profile and imports again is not told it will ask.
    static func asksAtFirstProfile(profileCount: Int, configurationExists: Bool = false) -> Bool { profileCount == 0 && !configurationExists }

    var step: Step = .welcome
    var extensionStep: ExtensionStep = .idle
    var configurationStep: ConfigurationStep = .explain
    var migration: MigrationOffer?
    var migrationSelection: Set<String> = []
    var migrationReport: MigrationReport?
    /// E2E-5 F4: Settings › Advanced "Import from Old LockPlus…" is looking for the old app's data.
    var migrationChecking = false
    /// Pre-release review M1: an import runs (Import and the Settings re-scan are disabled).
    var migrationRunning = false
    /// E2E-5 F4: an earlier import didn't finish and onboarding is already done: the main window offers to finish it.
    var migrationResumePending = false
    /// The main window's "Import from Old LockPlus" sheet (the resume banner, Settings › Advanced).
    var migrationSheetPresented = false
    var etcWireGuardCount = 0
    var isPresented = false

    init() {}

    /// The migration sheet closed: a shown report ends the migration (and the "finish" offer); a cancelled sheet keeps
    /// the offer for the banner.
    func closeMigration() {
        if migrationReport != nil {
            migration = nil
            migrationReport = nil
            migrationResumePending = false
        }
        migrationSheetPresented = false
    }
}

// MARK: - Import (§6.8)

/// The single-file import sheet's data (§6.8). Parsing, the report and the RouteProbe warning come from
/// LPParsing/XPCProfileValidator as LPModel types; the sheet only edits name and protection.
struct ImportPreview: Identifiable, Sendable, Equatable {
    let id: UUID
    var fileName: String
    var name: String
    var kind: VPNProtocolKind
    var summary: ProfileSummary
    var report: ImportReport
    var killSwitch = true
    var allowLocalNetwork = false
    /// Round 1 (Fable L2): where an open event's file came from ("~/Downloads/work.ovpn"); nil for the user's own drop,
    /// file panel or paste. Such a sheet has no default button and its Import enables after a moment.
    var openedFrom: String? = nil

    var isFullTunnel: Bool { summary.isFullTunnel }
    var canImport: Bool { !report.blocksImport && !name.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct BatchImportItem: Identifiable, Sendable, Equatable {
    enum State: Sendable, Equatable { case pending, imported, skipped }
    let id: UUID
    var fileName: String
    var selected = true
    var report: ImportReport
    var state: State = .pending

    var verdict: ImportVerdict { ImportVerdict(report: report) }
    var isImportable: Bool { verdict != .rejected && state == .pending }
}

struct BatchImport: Identifiable, Sendable, Equatable {
    let id: UUID
    var archiveName: String
    var items: [BatchImportItem]
    /// Cap violations appear as errors, never as silent truncation (500 entries, 1 MB per entry, 64 MB in total; 2.0.2 validator service caps).
    var capErrors: [String] = []
    var finished = false
    /// Round 1 (Fable L2): as `ImportPreview.openedFrom`.
    var openedFrom: String? = nil
}

@MainActor @Observable final class ImportUIModel {
    var preview: ImportPreview?
    var batch: BatchImport?
    /// "office.ovpn can't be imported: …" sheet alert.
    var errorMessage: String?
    var isDropTargeted = false
    /// Non-modal result banner: "Exported 6 profiles to Downloads".
    var exportResult: ExportResult?
    init() {}
}

struct ExportResult: Sendable, Equatable {
    var count: Int
    var folderName: String
    var folderURL: URL
}

// MARK: - Activity (§6.10)

struct SessionRow: Identifiable, Sendable, Equatable {
    enum EndReason: Sendable, Equatable { case active, user, network, error, system }
    let id: UUID
    var profileName: String
    var started: Date
    var duration: TimeInterval?
    var received: UInt64
    var sent: UInt64
    var ended: EndReason
    /// The profile's ID when known (filters by ID, not by a name that can repeat or change; UI-M11).
    var profileID: ProfileItem.ID? = nil
}

@MainActor @Observable final class ActivityUIModel {
    var sessions: [SessionRow] = []
    var profileFilter: ProfileItem.ID?
    var rangeDays = 7
    init(sessions: [SessionRow] = []) { self.sessions = sessions }
}

// MARK: - Diagnostics (§6.11)

struct DiagnosticCheck: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case tunnel, dns, ipv6, otherVPNs, oldHelper }
    enum Result: Sendable, Equatable { case pass, warning, fail, unknown }
    var id: Kind { kind }
    var kind: Kind
    var result: Result
    var summary: String
    var detail: String
}

struct RouteRow: Identifiable, Sendable, Equatable {
    var id: String { destination + interface }
    var destination: String
    var gateway: String
    var interface: String
    var viaTunnel: Bool
}

struct ProblemRow: Identifiable, Sendable, Equatable {
    let id: UUID
    var date: Date
    var message: String
}

@MainActor @Observable final class DiagnosticsUIModel {
    var checks: [DiagnosticCheck] = []
    var routes: [RouteRow] = []
    var problems: [ProblemRow] = []
    var isRunning = false
    init() {}
}

// MARK: - Logs (§6.12)

struct LogEntry: Identifiable, Sendable, Equatable {
    enum Level: Int, Sendable, Comparable, CaseIterable {
        case debug, info, warning, error
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    enum Source: Sendable, Equatable { case app, tunnel }
    let id: Int
    var date: Date
    var level: Level
    var source: Source
    var message: String
}

@MainActor @Observable final class LogsUIModel {
    enum LevelFilter: String, Sendable, CaseIterable, Identifiable {
        case all, info, warnings, errors
        var id: String { rawValue }
    }
    enum SourceFilter: String, Sendable, CaseIterable, Identifiable {
        case both, app, tunnel
        var id: String { rawValue }
    }
    var entries: [LogEntry] = []
    var levelFilter: LevelFilter = .all
    var sourceFilter: SourceFilter = .both
    var follow = true
    /// `LogsStore.tunnelGap`: why the tunnel's logs can't be read (non-admin users), shown as a footer.
    var tunnelLogsGap: String?
    init(entries: [LogEntry] = []) { self.entries = entries }
}

// MARK: - Auto-Connect (§6.7)

enum LocationAuthorization: Sendable, Equatable { case notDetermined, authorized, denied, restricted }

@MainActor @Observable final class AutoConnectUIModel {
    var enabled = false
    var profileID: ProfileItem.ID?
    var onUntrustedWiFi = true
    var onEthernet = false
    var trustedNetworks: [String] = []
    var location: LocationAuthorization = .notDetermined
    var currentSSID: String?
    /// Spike S1 failed: the app-assisted mode needs Location and a running app.
    var requiresRunningApp = false
    /// "Auto-connect is paused until you join another network" / "…resumes when you disconnect Home NAS".
    var statusLine: String?
    init() {}
}
