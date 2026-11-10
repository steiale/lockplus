import AppKit
import LPModel
import SwiftUI
import Testing
@testable import LockPlus

/// Every other user-facing surface (UI-CONCEPT §6): hero rows, menu header, banners, detail, sections, Auto-Connect,
/// sheets, onboarding, Settings, alerts. File names `<surface>-<light|dark>[-de].png`, see render-screenshots.sh.
extension ScreenshotTests {
    // MARK: Hero rows and menu header

    struct HeroCase: Sendable, CustomTestStringConvertible {
        enum Who: Sendable { case work, nas, acme, long }
        enum Tweak: Sendable {
            case none, readiness(ExtensionReadiness), approval, dns(DNSVerdict), link(XPCLinkState), hold(StartHoldUI.Reason),
                 error(LPErrorCode), reconnected, repairing, notVerified
        }
        let name: String
        let row: String
        var who: Who = .work
        var tweak: Tweak = .none
        var testDescription: String { name }

        static let all: [HeroCase] = [
            .init(name: "1", row: "1"),
            .init(name: "1-disabled", row: "1", tweak: .readiness(.disabledByUser)),
            .init(name: "1-removed", row: "1", tweak: .readiness(.removedDuringUpdate)),
            .init(name: "1-damaged", row: "1", tweak: .readiness(.failed)),
            .init(name: "1-reboot", row: "1", tweak: .readiness(.rebootRequired)),
            .init(name: "2", row: "2"),
            .init(name: "3", row: "3"),
            .init(name: "3-approval", row: "3", tweak: .approval),
            .init(name: "3-nokillswitch", row: "3", who: .nas),
            .init(name: "3a", row: "3a"),
            .init(name: "3b", row: "3b"),
            .init(name: "switch", row: "switch"),
            .init(name: "4", row: "4"),
            .init(name: "4a", row: "4a"),
            .init(name: "4a-unresponsive", row: "4a", tweak: .link(.unavailable)),
            .init(name: "5", row: "5"),
            .init(name: "5-overridden", row: "5", tweak: .dns(.overridden)),
            .init(name: "6", row: "6"),
            .init(name: "6-reconnected", row: "6", tweak: .reconnected),
            .init(name: "7", row: "7"),
            .init(name: "8", row: "8"),
            .init(name: "9", row: "9"),
            .init(name: "10", row: "10"),
            .init(name: "11", row: "11", who: .nas),
            .init(name: "12", row: "12"),
            .init(name: "12a", row: "12a"),
            .init(name: "12a-wait", row: "12a-wait"),
            .init(name: "12a-restart", row: "12a-restart"),
            .init(name: "12a-mayrestart", row: "12a", tweak: .hold(.mayRestart)),
            .init(name: "12a-endedearly", row: "12a", tweak: .hold(.startEndedEarly)),
            .init(name: "12a-nonet", row: "12a-nonet"),
            .init(name: "12a-netrestart", row: "12a-netrestart"),
            .init(name: "13a", row: "13a"),
            .init(name: "14", row: "14"),
            .init(name: "14-nonet", row: "14", tweak: .error(.noNetwork)),
            .init(name: "14-killswitch-not-applied", row: "14", tweak: .error(.killSwitchNotApplied)),
            .init(name: "14-server-unreachable", row: "14", tweak: .error(.endpointInterfaceUnusable)),
            .init(name: "15", row: "15"),
            .init(name: "15-nas", row: "15", who: .nas),
            .init(name: "15-repairing", row: "15", tweak: .repairing),
            .init(name: "15-notverified", row: "15", who: .acme, tweak: .notVerified),
        ]

        /// Header rows that name the profile, with a 35-character name (review 2026-11-09: the header never truncates).
        static let longNames: [HeroCase] = [
            .init(name: "3-longname", row: "3", who: .long),
            .init(name: "3b-longname", row: "3b", who: .long),
            .init(name: "switch-longname", row: "switch", who: .long),
            .init(name: "4-longname", row: "4", who: .long),
            .init(name: "4a-unresponsive-longname", row: "4a", who: .long, tweak: .link(.unavailable)),
            .init(name: "6-longname", row: "6", who: .long),
            .init(name: "9-longname", row: "9", who: .long),
            .init(name: "10-longname", row: "10", who: .long),
            .init(name: "11-longname", row: "11", who: .long),
            .init(name: "12a-longname", row: "12a", who: .long),
            .init(name: "12a-restart-longname", row: "12a-restart", who: .long),
            .init(name: "14-longname", row: "14", who: .long),
            .init(name: "15-longname", row: "15", who: .long),
        ]
        static let longName = "Frankfurt HQ Engineering Split VPN"

        var profile: ProfileItem {
            var p = switch who { case .work, .long: PreviewData.work; case .nas: PreviewData.nas; case .acme: PreviewData.acme }
            if who == .long { p.name = Self.longName }
            if case .repairing = tweak { p.protectionRepairing = true }
            if case .notVerified = tweak { p.notYetVerified = true }
            return p
        }

        @MainActor func makeEnv() -> UIEnvironment {
            let p = profile
            let env = UIEnvironment.preview(row: row, profile: p, profiles: PreviewData.profiles.map { $0.id == p.id ? p : $0 })
            let name = p.name
            switch tweak {
            case .readiness(let r): env.connection.inputs.extensionReadiness = r
            case .approval: env.connection.inputs.awaitingApproval = true
            case .dns(let d): env.connection.inputs.dns = d
            case .link(let l): env.connection.inputs.link = l
            case .hold(let r): env.connection.inputs.status = .disconnected; env.connection.inputs.startHold = StartHoldUI(name: name, reason: r)
            case .error(let c): env.connection.inputs.lastError = .init(code: c)
            case .reconnected: env.connection.reconnectedAfterRestart = true
            case .none, .repairing, .notVerified: break
            }
            if who == .long, env.connection.inputs.switchingTo != nil { env.connection.inputs.switchingTo = "Home NAS via Munich Datacenter 2" }
            return env
        }
    }

    @Test("Hero, one image per derived-state row", arguments: HeroCase.all)
    func hero(_ c: HeroCase) async throws {
        let view = ProtectionHero(profile: c.profile).environment(c.makeEnv()).padding(16).background(BrandCanvasBackground())
        try await Self.renderFitted(view, width: 640, name: "hero-row\(c.name)")
    }

    @Test("Menu header, one image per derived-state row (and long profile names)", arguments: HeroCase.all + HeroCase.longNames)
    func menuHeader(_ c: HeroCase) async throws {
        let env = c.makeEnv()
        let model = MenuHeaderModel()
        model.refresh(from: env, now: PreviewData.now)
        try await Self.renderFitted(MenuHeaderView(model: model).padding(4).background(.background), width: MenuHeaderView.width + 8,
                                    name: "menu-header-row\(c.name)")
    }

    // MARK: Main window states

    @Test("Main window, other states", arguments: ["1", "2", "3", "12a", "12a-nonet", "14", "15"])
    func mainRows(row: String) async throws {
        try await Self.renderBoth(MainView(selection: .profile(PreviewData.workID)).environment(UIEnvironment.preview(row: row)),
                                  size: CGSize(width: 920, height: 620), name: "main-row\(row)")
    }

    @Test("Main window, empty library, locked, unreadable", arguments: ["empty", "locked", "unreadable"])
    func mainEmpty(kind: String) async throws {
        let env = UIEnvironment.preview(row: "15", profiles: [])
        if kind == "locked" { env.profiles.locked = ["Work", "Home NAS", "Acme"] }
        if kind == "unreadable" { env.profiles.readError = "permission denied" }
        try await Self.renderBoth(MainView().environment(env), size: CGSize(width: 920, height: 620), name: "main-library-\(kind)")
    }

    @Test("Detail placeholder, nothing selected")
    func noSelection() async throws {
        let env = UIEnvironment.preview(row: "15")
        try await Self.renderBoth(NoSelectionView().environment(env).frame(maxWidth: .infinity, maxHeight: .infinity).background(BrandCanvasBackground()),
                                  size: CGSize(width: 640, height: 360), name: "detail-no-selection")
    }

    @Test("Main window, sections", arguments: ["activity", "autoconnect", "diagnostics", "logs"])
    func mainSections(kind: String) async throws {
        let sel: SidebarItem = switch kind { case "activity": .activity; case "autoconnect": .autoConnect; case "diagnostics": .diagnostics; default: .logs }
        try await Self.renderBoth(MainView(selection: sel).environment(UIEnvironment.preview(row: "6")),
                                  size: CGSize(width: 920, height: 620), name: "main-section-\(kind)")
    }

    /// Review S-8.17 (dark mode: a blue tile over grey rows looks unbalanced): the same Diagnostics pane with the
    /// system's table rows (before) and on `lp.panel` (after), side by side. Light mode is unchanged by design.
    @Test("Diagnostics before/after: system rows vs lp.panel")
    func diagnosticsPanelCompare() async throws {
        let env = UIEnvironment.preview(row: "6")
        let view = HStack(alignment: .top, spacing: 12) {
            ForEach([false, true], id: \.self) { after in
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: after ? "After: rows on lp.panel" : "Before: system table rows")
                        .font(.headline).foregroundStyle(Color.lp.label).padding(.horizontal, 20).padding(.top, 14)
                    DiagnosticsView().environment(\.lpPanelSurfaces, after)
                }
                .frame(width: 700, height: 600, alignment: .top)
                .background(BrandCanvasBackground())
            }
        }
        .environment(env)
        try await Self.renderBoth(view, size: CGSize(width: 1412, height: 600), name: "diagnostics-panel-compare")
    }

    // MARK: Profile detail

    struct DetailCase: Sendable, CustomTestStringConvertible {
        let name: String
        let who: HeroCase.Who
        let row: String
        var testDescription: String { name }
        static let all = [DetailCase(name: "work-protected", who: .work, row: "6"), .init(name: "acme-openvpn", who: .acme, row: "15"),
                          .init(name: "nas-split-tunnel", who: .nas, row: "15")]
    }

    @Test("Profile detail", arguments: DetailCase.all)
    func detail(_ c: DetailCase) async throws {
        let p = switch c.who { case .work, .long: PreviewData.work; case .nas: PreviewData.nas; case .acme: PreviewData.acme }
        let view = ProfileDetailView(profile: p).environment(UIEnvironment.preview(row: c.row, profile: p)).background(BrandCanvasBackground())
        try await Self.renderBoth(view, size: CGSize(width: 680, height: 1_000), name: "detail-\(c.name)")
    }

    @Test("Profile detail, import report open")
    func detailImportReport() async throws {
        let p = PreviewData.acme
        let view = ProfileDetailView(profile: p, ignoredExpanded: true).environment(UIEnvironment.preview(row: "15", profile: p)).background(BrandCanvasBackground())
        try await Self.renderBoth(view, size: CGSize(width: 680, height: 1_500), name: "detail-acme-import-report")
    }

    // MARK: Window banners (extension, update, helper, configuration)

    struct BannerCase: Sendable, CustomTestStringConvertible {
        let name: String
        var testDescription: String { name }
        static let all = ["extension-approval", "extension-disabled", "extension-removed", "extension-damaged", "extension-reboot",
                          "extension-update-failed", "legacy-helper-warn", "vpn-configuration-denied", "other-vpn", "export-result",
                          // E2E-5: the old helper's removal (F1), the refusal strip (F8), finish an import (F4), launch at login (F5)
                          "legacy-helper-idle", "legacy-helper-removing", "legacy-helper-removed", "legacy-helper-removal-failed",
                          "legacy-helper-removal-cancelled", "legacy-refuse-gate", "migration-resume", "launch-at-login-offer"].map(BannerCase.init)
    }

    @Test("Window banners", arguments: BannerCase.all)
    func banners(_ c: BannerCase) async throws {
        let env = UIEnvironment.preview(row: "15")
        switch c.name {
        case "extension-approval": env.connection.inputs.extensionReadiness = .needsUserApproval
        case "extension-disabled": env.connection.inputs.extensionReadiness = .disabledByUser
        case "extension-removed": env.connection.inputs.extensionReadiness = .removedDuringUpdate
        case "extension-damaged": env.connection.inputs.extensionReadiness = .failed
        case "extension-reboot": env.connection.inputs.extensionReadiness = .rebootRequired
        case "extension-update-failed":
            env.connection.inputs.extensionReadiness = .updateFailed
            env.connection.extensionUpdateFailedMessage = ExtensionMapping.updateFailedMessage(code: 8)
        case "legacy-helper-warn":
            env.connection.legacyHelper = LegacyHelperNotice(message: "The old LockPlus helper crashed with its firewall on. Connecting may fail until it is removed.",
                                                             blocksConnect: false, warnsBeforeConnect: true)
        case "legacy-helper-idle":
            env.connection.legacyHelper = Self.idleHelper
        case "legacy-helper-removing":
            env.connection.legacyHelper = Self.idleHelper
            env.connection.legacyHelperRemoval = .removing
        case "legacy-helper-removed": env.connection.legacyHelperRemoval = .removed(leftNetworkState: false)
        case "legacy-helper-removal-failed":
            env.connection.legacyHelper = Self.idleHelper
            env.connection.legacyHelperRemoval = .failed(.busy)
        case "legacy-helper-removal-cancelled":
            env.connection.legacyHelper = Self.idleHelper
            env.connection.legacyHelperRemoval = .cancelled
        case "legacy-refuse-gate":
            var n = PreviewData.legacyRefuse
            n.oldAppInstalled = true
            env.connection.legacyHelper = n
            env.connection.connectGate = .refused(PreviewData.workID)
        case "migration-resume": env.onboarding.migrationResumePending = true
        case "launch-at-login-offer": env.settings.launchAtLoginOffer = true
        case "vpn-configuration-denied": env.connection.vpnConfigurationDenied = true
        case "other-vpn": env.connection.otherVPNName = "Tailscale"
        default: env.importer.exportResult = ExportResult(count: 6, folderName: "Downloads", folderURL: URL(fileURLWithPath: NSHomeDirectory()))
        }
        try await Self.renderFitted(VStack { WindowBanners() }.environment(env).padding(.bottom, 8).background(BrandCanvasBackground()), width: 720, name: "banner-\(c.name)")
    }

    /// E2E-5 F1: an installed, idle old helper (the banner offers "Remove Old Helper…").
    static var idleHelper: LegacyHelperNotice {
        LegacyHelperNotice(message: LegacyFinding.helperIdle.message ?? "", blocksConnect: false, warnsBeforeConnect: false, canRemoveHelper: true)
    }

    @Test("Import from Old LockPlus sheet (E2E-5 F4)")
    func migrationSheet() async throws {
        let env = UIEnvironment.preview(row: "15")
        env.onboarding.migration = .init(profileNames: ["old-office", "lab", "ovpn-tcp"], savedPasswords: 1)
        env.onboarding.migrationSelection = ["old-office", "lab", "ovpn-tcp"]
        try await Self.renderFitted(MigrationSheet().environment(env).background(.background), width: 560, minHeight: 360, name: "settings-advanced-import-old")
    }

    // MARK: Sections

    @Test("Activity, with sessions and empty")
    func activity() async throws {
        let env = UIEnvironment.preview(row: "6")
        try await Self.renderBoth(ActivityView().environment(env).background(BrandCanvasBackground()), size: CGSize(width: 760, height: 620), name: "section-activity")
        let empty = UIEnvironment.preview(row: "15")
        empty.activity.sessions = []
        try await Self.renderBoth(ActivityView().environment(empty).background(BrandCanvasBackground()), size: CGSize(width: 760, height: 460), name: "section-activity-empty")
    }

    @Test("Diagnostics, checks and problems")
    func diagnostics() async throws {
        let env = UIEnvironment.preview(row: "6")
        try await Self.renderBoth(DiagnosticsView().environment(env).background(BrandCanvasBackground()), size: CGSize(width: 760, height: 640), name: "section-diagnostics")
        let p = UIEnvironment.preview(row: "14")
        p.diagnostics.problems = [ProblemRow(id: UUID(), date: PreviewData.now, message: "Work stopped: LockPlus's tunnel process stopped unexpectedly."),
                                  ProblemRow(id: UUID(), date: PreviewData.now.addingTimeInterval(-3_600), message: "The profile files couldn't be read once; retried.")]
        p.diagnostics.checks = PreviewData.checks.enumerated().map { i, c in
            var c = c
            if i == 0 { c.result = .fail; c.summary = "Tunnel component not responding" }
            return c
        }
        try await Self.renderBoth(DiagnosticsView().environment(p).background(BrandCanvasBackground()), size: CGSize(width: 760, height: 700), name: "section-diagnostics-problems")
    }

    @Test("Logs")
    func logs() async throws {
        try await Self.renderBoth(NavigationStack { LogsView() }.environment(UIEnvironment.preview(row: "6")), size: CGSize(width: 760, height: 420), name: "section-logs")
        let gap = UIEnvironment.preview(row: "6")
        gap.logs.tunnelLogsGap = PreviewData.tunnelGap
        try await Self.renderBoth(NavigationStack { LogsView() }.environment(gap), size: CGSize(width: 760, height: 420), name: "logs-tunnel-gap")
    }

    // MARK: Auto-Connect

    struct ACCase: Sendable, CustomTestStringConvertible {
        let name: String
        var testDescription: String { name }
        static let all = ["default", "off", "status-suspended", "status-resumes", "status-handover", "status-restore-failed", "status-another-user",
                          "location-authorized", "location-denied", "location-restricted", "requires-running-app"].map(ACCase.init)
    }

    @Test("Auto-Connect pane and its status lines", arguments: ACCase.all)
    func autoConnect(_ c: ACCase) async throws {
        let env = UIEnvironment.preview(row: "15")
        let ac = env.autoConnect
        switch c.name {
        case "off": ac.enabled = false
        case "status-suspended":
            ac.statusLine = String(localized: "Auto-connect for \("Home NAS") is paused until you join another network, because you disconnected it. To resume now, turn Auto-Connect off and on again.",
                                   comment: "Auto-connect status: suspended by the user's Disconnect (§10.4)")
        case "status-resumes": ac.statusLine = String(localized: "Auto-connect resumes when you disconnect \("Work").", comment: "Auto-connect status (§10.4)")
        case "status-handover":
            ac.statusLine = String(localized: "Auto-connect is paused while the tunnel component is updated.",
                                   comment: "Auto-connect status: every plan is held during an extension update or reinstall (review N2, review 4 #3)")
        case "status-restore-failed":
            ac.statusLine = String(localized: "Auto-connect is off; LockPlus couldn't turn it back on.", comment: "Auto-connect status: a restore failed and is retried (review F4)")
        case "status-another-user": ac.statusLine = ConnectionStore.BusyReason.anotherUser.explanation
        case "location-authorized": ac.location = .authorized; ac.currentSSID = "Home-5G"
        case "location-denied": ac.location = .denied
        case "location-restricted": ac.location = .restricted
        case "requires-running-app": ac.requiresRunningApp = true
        default: break
        }
        try await Self.renderBoth(AutoConnectView().environment(env).background(BrandCanvasBackground()), size: CGSize(width: 720, height: 660), name: "autoconnect-\(c.name)")
    }

    // MARK: Sign-in prompts

    @Test("Auth sheets")
    func auth() async throws {
        let kinds: [(String, AuthPromptState.Kind)] = [
            ("password", .password(oneTimeCode: true)),
            ("password-plain", .password(oneTimeCode: false)),
            ("static-challenge", .staticChallenge(StaticChallenge(text: "Enter your Authenticator code", echo: true, concat: false))),
            ("crv1", .dynamicChallenge(text: "Enter the code sent to ••42", echo: false)),
            ("rejected", .rejected(serverReason: "Invalid OTP", oneTimeCode: true)),
            ("key-passphrase", .keyPassphrase),
            ("waiting-approval", .waitingForApproval(tooLate: false)),
            ("approval-too-late", .waitingForApproval(tooLate: true)),
        ]
        for (name, kind) in kinds {
            let prompt = AuthPromptState(id: UUID(), profileName: "Acme", kind: kind, username: "j.appleseed",
                                         notice: name == "crv1" ? .codeExpiredFreshChallenge : nil)
            let env = UIEnvironment.preview(row: "3", profile: PreviewData.acme, prompt: prompt)
            try await Self.renderFitted(AuthPromptView(prompt: prompt).environment(env).background(.background), width: 420, minHeight: 200, name: "auth-\(name)")
        }
        let failed = AuthPromptState(id: UUID(), profileName: "Acme", kind: .password(oneTimeCode: true), username: "j.appleseed")
        let env = UIEnvironment.preview(row: "3", profile: PreviewData.acme, prompt: failed)
        env.auth.error = "The tunnel process is busy. Try again."
        try await Self.renderFitted(AuthPromptView(prompt: failed).environment(env).background(.background), width: 420, minHeight: 200, name: "auth-answer-failed")
        let expired = UIEnvironment.preview(row: "3", profile: PreviewData.acme, prompt: failed)
        expired.auth.expired = true
        try await Self.renderFitted(AuthPromptView(prompt: failed).environment(expired).background(.background), width: 420, minHeight: 200, name: "auth-expired")
    }

    // MARK: Import and sheets

    @Test("Import sheets")
    func importSheets() async throws {
        let env = UIEnvironment.preview()
        for (name, p) in [("typical", PreviewData.importPreview), ("unsupported", PreviewData.importPreviewUnsupported)] {
            try await Self.renderBoth(ImportPreviewSheet(preview: p, ignoredExpanded: true).environment(env).background(.background), size: CGSize(width: 520, height: 560), name: "import-\(name)-expanded")
        }
        for (name, p) in [("typical", PreviewData.importPreview), ("warnings", PreviewData.importPreviewWarnings), ("unsupported", PreviewData.importPreviewUnsupported)] {
            try await Self.renderBoth(ImportPreviewSheet(preview: p).environment(env).background(.background), size: CGSize(width: 520, height: 470), name: "import-\(name)")
        }
        try await Self.renderBoth(BatchImportSheet(batch: PreviewData.batch).environment(env).background(.background), size: CGSize(width: 520, height: 420), name: "import-batch")
        var capped = PreviewData.batch
        capped.capErrors = ["“x.ovpn” is a link, not a file, and was skipped."]
        try await Self.renderBoth(BatchImportSheet(batch: capped).environment(env).background(.background), size: CGSize(width: 520, height: 420), name: "import-batch-errors")
    }

    @Test("Password sheets")
    func passwordSheets() async throws {
        let change = PasswordChangeRequest(profileID: PreviewData.acmeID, profileName: "Acme", username: "j.appleseed", onSave: { _, _, _ in })
        try await Self.renderBoth(ChangePasswordSheet(request: change).background(.background), size: CGSize(width: 420, height: 230), name: "password-change")
        let reveal = PasswordReveal(profileName: "Acme", username: "j.appleseed", password: "correct horse battery")
        try await Self.renderBoth(RevealPasswordSheet(reveal: reveal).background(.background), size: CGSize(width: 400, height: 220), name: "password-reveal")
    }

    @Test("Pause, error details, location pre-prompt, diagnostics export, legacy banner")
    func smallSheets() async throws {
        let pause = UIEnvironment.preview(row: "6")
        pause.connection.resumeAgentNeedsApproval = true
        try await Self.renderBoth(PauseConfirmSheet(minutes: 15).environment(pause).background(.background), size: CGSize(width: 440, height: 230), name: "pause-resume-approval")
        try await Self.renderBoth(PauseConfirmSheet(minutes: 15).environment(UIEnvironment.preview(row: "6")).background(.background), size: CGSize(width: 440, height: 160), name: "pause-confirm")
        let err = UIEnvironment.preview(row: "14")
        err.connection.lastErrorDetail = "provider exited with signal 11"
        try await Self.renderBoth(ErrorDetailsSheet().environment(err).background(.background), size: CGSize(width: 440, height: 260), name: "error-details")
        try await Self.renderBoth(LocationPrePromptSheet().environment(UIEnvironment.preview()).background(.background), size: CGSize(width: 420, height: 170), name: "location-preprompt")
        try await Self.renderBoth(DiagnosticsExportSheet(files: PreviewData.diagnosticsFiles).environment(UIEnvironment.preview()).background(.background),
                                  size: CGSize(width: 640, height: 460), name: "diagnostics-export")
        let legacy = UIEnvironment.preview(row: "15")
        legacy.connection.legacyHelper = PreviewData.legacyRefuse
        try await Self.renderBoth(VStack { WindowBanners(); Spacer() }.environment(legacy).background(BrandCanvasBackground()),
                                  size: CGSize(width: 680, height: 120), name: "banner-legacy-helper")
    }

    // MARK: Onboarding

    struct OBCase: Sendable, CustomTestStringConvertible {
        let name: String
        var testDescription: String { name }
        static let all = ["step1-welcome", "step2-idle", "step2-requesting", "step2-approval", "step2-reboot", "step2-failed", "step2-installed",
                          "step3-explain", "step3-requesting", "step3-denied", "step3-deferred", "step4-choose", "step4-migration",
                          "step4-migration-passwords", "step4-report", "step4-resume", "step5-done", "step3-first", "step4-first-choose", "step4-first-migration-passwords"].map(OBCase.init)
    }

    @Test("Onboarding, every step and state", arguments: OBCase.all)
    func onboarding(_ c: OBCase) async throws {
        let env = UIEnvironment.preview(row: "1")
        let ob = env.onboarding
        switch c.name {
        case "step1-welcome": ob.step = .welcome
        case "step2-idle": ob.step = .installExtension
        case "step2-requesting": ob.step = .installExtension; ob.extensionStep = .requesting
        case "step2-approval": ob.step = .installExtension; ob.extensionStep = .needsApproval
        case "step2-reboot": ob.step = .installExtension; ob.extensionStep = .rebootRequired
        case "step2-failed": ob.step = .installExtension; ob.extensionStep = .failed("The extension couldn't be activated (code 4).")
        case "step2-installed": ob.step = .installExtension; ob.extensionStep = .done
        case "step3-explain": ob.step = .allowConfiguration
        case "step3-requesting": ob.step = .allowConfiguration; ob.configurationStep = .requesting
        case "step3-denied": ob.step = .allowConfiguration; ob.configurationStep = .denied
        case "step3-deferred": ob.step = .allowConfiguration; ob.configurationStep = .deferred(message: "A VPN is connecting. LockPlus continues when it has finished.")
        case "step3-first": ob.step = .allowConfiguration; env.profiles.profiles = []
        case "step4-first-choose": ob.step = .profiles; env.profiles.profiles = []
        case "step4-first-migration-passwords":
            ob.step = .profiles; env.profiles.profiles = []
            ob.migration = .init(profileNames: ["Work", "Home NAS", "Acme"], savedPasswords: 2)
            ob.migrationSelection = ["Work", "Home NAS", "Acme"]
        case "step4-choose": ob.step = .profiles; ob.etcWireGuardCount = 2
        case "step4-migration":
            ob.step = .profiles
            ob.migration = .init(profileNames: ["Work", "Home NAS", "Acme", "Globex", "Lab", "Test"], savedPasswords: 0)
            ob.migrationSelection = ["Work", "Home NAS", "Acme", "Globex", "Lab", "Test"]
        case "step4-migration-passwords":
            ob.step = .profiles
            ob.migration = .init(profileNames: ["Work", "Home NAS", "Acme"], savedPasswords: 2)
            ob.migrationSelection = ["Work", "Home NAS", "Acme"]
        case "step4-report":
            ob.step = .profiles
            // E2E-5 F6: the whole report (reasons, information, global notes, the launch-at-login offer).
            let lab = GoAppMigrator.classify(ImportReport(items: [ImportReportItem(.ignored, line: 12, directive: "verify-hash", .verifyHashNotSupported)]), engineVerified: true, name: "lab")
            let tcp = GoAppMigrator.classify(ImportReport(items: [ImportReportItem(.ignored, line: 4, directive: "nobind", .localBindingNotUsed),
                                                                  ImportReportItem(.ignored, line: 9, directive: "verb", .loggingManaged)]), engineVerified: true, name: "ovpn-tcp")
            ob.migrationReport = .init(imported: ["wg-full", "wg-split", "ovpn-tcp"], needsAttention: [lab.concern ?? ""], notMigrated: [],
                                       info: tcp.info, notes: [GoAppMigrator.migrationNoteText(.migrationDNSAlwaysTunnelled) ?? ""],
                                       offerLaunchAtLogin: true)
        case "step4-resume":
            ob.step = .profiles
            ob.migration = .init(profileNames: ["ovpn-tcp"], savedPasswords: 2, finishesEarlierImport: true)
            ob.migrationSelection = ["ovpn-tcp"]
        default: ob.step = .done
        }
        try await Self.renderFitted(OnboardingSheet().environment(env).background(.background), width: 600, minHeight: 480, name: "onboarding-\(c.name)")
    }

    @Test("Onboarding callout under the menu bar icon")
    func callout() async throws {
        try await Self.renderBoth(CalloutBubble(arrowX: 160).frame(width: 220, height: 92).background(.background), size: CGSize(width: 220, height: 92), name: "onboarding-callout")
    }

    // MARK: Settings

    /// The Settings `TabView` never settles in an offscreen window, so the panes that are internal types are rendered
    /// directly; the three `private` ones (General, Profiles, About) come from the real `SettingsView` by selecting
    /// its tab through the hosting hierarchy.
    @Test("Settings panes, direct", arguments: ["menubar", "menubar-hidden-color", "advanced", "advanced-dev"])
    func settingsDirect(kind: String) async throws {
        let env = UIEnvironment.preview()
        switch kind {
        case "menubar-hidden-color": env.settings.iconMayBeHidden = true; env.settings.iconStyle = .color; env.settings.rateLabel = .download
        case "menubar": env.settings.iconMayBeHidden = true
        case "advanced-dev": env.settings.isDevBuild = true
        default: break
        }
        if kind.hasPrefix("menubar") {
            try await Self.renderBoth(MenuBarSettings().environment(env).background(.background), size: CGSize(width: 520, height: 520), name: "settings-\(kind)")
        } else {
            try await Self.renderBoth(AdvancedSettings().environment(env).background(.background), size: CGSize(width: 520, height: 420), name: "settings-\(kind)")
        }
    }

    @Test("Settings tabs through SettingsView", arguments: [0, 2, 4])
    func settingsTabs(index: Int) async throws {
        let env = UIEnvironment.preview()
        env.settings.launchAtLogin = .requiresApproval
        env.settings.notificationsDeniedBySystem = index == 0
        let names = [0: "settings-general", 2: "settings-profiles", 4: "settings-about"]
        for dark in [false, true] {
            let rep = try await Self.render(SettingsView().environment(env).background(.background), size: CGSize(width: 560, height: 460), dark: dark,
                                            name: names[index]!) { root in
                Self.selectTab(index, in: root)
            }
            #expect(Self.hasContent(rep))
        }
    }

    static func selectTab(_ index: Int, in view: NSView) {
        if let tabs = view as? NSTabView, index < tabs.numberOfTabViewItems { tabs.selectTabViewItem(at: index); return }
        for s in view.subviews { selectTab(index, in: s) }
    }

    @Test("Uninstall sheet, every phase", arguments: ["confirm", "uninstalling", "still-installed", "residual"])
    func uninstall(kind: String) async throws {
        let phase: UninstallPhase = switch kind {
        case "uninstalling": .uninstalling
        case "still-installed": .componentStillInstalled
        case "residual": .residual(PreviewData.uninstallResidual)
        default: .confirm
        }
        try await Self.renderFitted(UninstallConfirmSheet(phase: phase).environment(UIEnvironment.preview()).background(.background), width: 460, minHeight: 200, name: "uninstall-\(kind)")
    }

    // MARK: Alerts and confirmation dialogs (system UI; drawn from the same copy)

    @Test("Alerts and confirmations")
    func alerts() async throws {
        let items: [(String, String, String, [String])] = [
            ("switch-confirm", SwitchCopy.title("Home NAS"), SwitchCopy.message("Home NAS"), [String(localized: "Switch", comment: "Switch confirmation button"), String(localized: "Cancel", comment: "Button")]),
            ("pause", String(localized: "Pause protection?", comment: "Pause confirmation title"), PauseChoice.confirmation(15, resumeNeedsApproval: false),
             [String(localized: "Pause", comment: "Pause confirmation button"), String(localized: "Cancel", comment: "Button")]),
            ("delete-profile", String(localized: "Delete “\("Work")”?", comment: "Delete confirmation"),
             String(localized: "The profile and its saved credentials are removed from this Mac.", comment: "Delete confirmation message"),
             [String(localized: "Delete", comment: "Button"), String(localized: "Cancel", comment: "Button")]),
            ("locked-remove", LockedProfilesCopy.confirmTitle(count: 3), "", [String(localized: "Cancel", comment: "Button")]),
            ("locked-start-over", LockedProfilesCopy.startOverTitle, LockedProfilesCopy.startOverMessage, [String(localized: "Cancel", comment: "Button")]),
        ]
        for (name, title, message, buttons) in items {
            try await Self.renderFitted(AlertFacsimile(title: title, message: message, buttons: buttons).padding(20).background(BrandCanvasBackground()), width: 400, name: "alert-\(name)")
        }
    }
}

/// An `NSAlert`/`confirmationDialog` stand-in: the title, message and buttons are the app's own strings.
struct AlertFacsimile: View {
    let title: String
    let message: String
    let buttons: [String]
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            Text(verbatim: title).font(.headline).multilineTextAlignment(.center)
            if !message.isEmpty { Text(verbatim: message).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary) }
            VStack(spacing: 6) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { i, b in
                    Text(verbatim: b).frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(i == 0 ? Color.accentColor : Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(i == 0 ? Color.white : Color.primary)
                }
            }.padding(.top, 6)
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
    }
}
