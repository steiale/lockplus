import Foundation
import LPModel
import Observation

// Mock data for SwiftUI previews and the screenshot tests (UI-CONCEPT §12: a PreviewConnectionStore drives every
// state without an engine). Compiled into the app because previews and tests need it; nothing in the shipping
// path references it.

enum PreviewData {
    static let workID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
    static let nasID = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
    static let acmeID = UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!
    static let globexID = UUID(uuidString: "00000000-0000-0000-0000-00000000A004")!
    /// §4.4 residual copy as the uninstaller words it (AppActions Uninstaller.message).
    static let uninstallResidual = "Some VPN configurations could not be removed. Remove the LockPlus entries in System Settings › VPN."
    /// Relative to launch so clocks and "ago" values read naturally in previews and screenshots.
    static let now = Date()

    static let work = ProfileItem(
        id: workID, name: "Work", kind: .wireGuard, endpoint: "vpn.example.de:51820", resolvedEndpoint: "198.51.100.7",
        place: "Frankfurt", transport: "UDP", addresses: ["10.8.0.2/32", "fd00::2/128"], dns: ["10.8.0.1"], routes: .allTraffic,
        mtu: 1420, killSwitch: true, isAutoConnectProfile: false,
        notes: "Office VPN, ask IT for new keys in March",
        lastSessionEnded: now.addingTimeInterval(-86_400), lastSessionDuration: 5_340)
    static let nas = ProfileItem(
        id: nasID, name: "Home NAS", kind: .wireGuard, endpoint: "home.example.net:51820", place: nil, transport: "UDP",
        addresses: ["10.9.0.2/32"], dns: [], routes: .split(["192.168.1.0/24"]), mtu: 1420, killSwitch: false,
        isAutoConnectProfile: true)
    static let acme = ProfileItem(
        id: acmeID, name: "Acme", kind: .openVPN, endpoint: "vpn.acme.example:1194", place: nil, transport: "UDP",
        addresses: ["172.16.4.10/24"], dns: ["172.16.4.1"], routes: .allTraffic, cipher: "AES-256-GCM", killSwitch: true,
        credentials: .init(username: "j.appleseed", passwordSaved: true, oneTimeCode: .everyConnect),
        ignoredDirectives: [ImportReportItem(.ignored, directive: "script-security", .scriptsNeverRun),
                            ImportReportItem(.ignored, directive: "persist-tun", .persistenceNotNeeded)].compactMap { i in
            i.directive.map { IgnoredDirective(name: $0, reason: i.localizedMessage(), harmless: i.isHarmlessIgnored) } })
    static let globex = ProfileItem(
        id: globexID, name: "Globex", kind: .openVPN, endpoint: "gw.globex.example:443", transport: "TCP",
        routes: .split(["10.20.0.0/16"]), cipher: "AES-128-CBC", killSwitch: false,
        credentials: .init(username: "j.appleseed", passwordSaved: false, oneTimeCode: .staticChallenge))

    static let profiles = [work, nas, acme, globex]

    static func samples(count: Int = 300, end: Date = now, scale: Double = 1_200_000) -> [RateSample] {
        (0..<count).map { i in
            let x = Double(i)
            let rx = scale * (0.55 + 0.35 * sin(x / 9) + 0.1 * sin(x / 2.3)).magnitude
            let tx = scale * 0.04 * (1 + 0.6 * sin(x / 5 + 1)).magnitude
            return RateSample(id: i, t: end.addingTimeInterval(Double(i - count + 1)), rx: rx, tx: tx)
        }
    }

    /// Inputs for one §6.6 row, about `profile`.
    static func inputs(row: String, profile: ProfileItem = work) -> DerivedStateInputs {
        var i = DerivedStateInputs(profileName: profile.name, killSwitch: profile.killSwitch)
        i.now = now
        switch row {
        case "1": i.extensionReadiness = .needsUserApproval
        case "2": i.pausedUntil = now.addingTimeInterval(11 * 60 + 10)
        case "3": i.status = .connecting; i.snapshot.phase = .awaitingAuth
        case "3a": i.status = .connecting; i.killSwitch = true; i.snapshot.holdReason = .blockedAfterFailure(.connectTimeout)
                   i.snapshot.holdBeforeConnected = true; i.snapshot.attempt = 2; i.snapshot.nextRetryAt = now.addingTimeInterval(4)
        case "3b": i.status = .connecting; i.snapshot.holdReason = .nonRetryable(.authFailed); i.snapshot.holdBeforeConnected = true
        case "switch": i.status = .connecting; i.switchingTo = "Home NAS"
        case "4": i.status = .connecting; i.snapshot.phase = .establishing
        case "4a": i.status = .connected; i.link = .reconnecting
        case "5": i.status = .connected; i.dns = .unverified
        case "6": i.status = .connected; i.dns = .verified
        case "7": i.status = .reasserting; i.killSwitch = true; i.snapshot.holdReason = .blockedAfterFailure(.serverIdentityMismatch)
        case "8": i.status = .reasserting; i.snapshot.holdReason = .nonRetryable(.authFailed)
        case "9": i.status = .reasserting; i.killSwitch = true; i.snapshot.phase = .awaitingAuth
        case "10": i.status = .reasserting; i.killSwitch = true; i.snapshot.attempt = 3; i.snapshot.nextRetryAt = now.addingTimeInterval(20)
        case "11": i.status = .reasserting; i.killSwitch = false; i.snapshot.attempt = 2
        case "12": i.status = .disconnecting
        case "12a": i.status = .disconnected; i.startHold = StartHoldUI(name: profile.name, reason: .preparing)
        case "12a-wait": i.status = .disconnected; i.startHold = StartHoldUI(name: profile.name, reason: .waitingForStop(of: profile.name))
        case "12a-restart": i.status = .disconnected; i.lastError = .init(code: .engineDied)
                            i.startHold = StartHoldUI(name: profile.name, reason: .awaitingRestart)
        case "12a-nonet": i.status = .disconnected; i.startHold = StartHoldUI(name: profile.name, reason: .waitingForNetwork)
        case "12a-netrestart": i.status = .disconnected; i.startHold = StartHoldUI(name: profile.name, reason: .awaitingNetwork)
        case "13a": i.status = .disconnected; i.snapshot.startLatch = .init(code: .authFailed, kind: .hard)
        case "14": i.status = .disconnected; i.lastError = .init(code: .engineDied)
        default: i.status = .disconnected
        }
        return i
    }

    static let allRows = ["1", "2", "3", "3a", "3b", "switch", "4", "4a", "5", "6", "7", "8", "9", "10", "11", "12", "12a", "12a-wait", "12a-restart", "12a-nonet", "12a-netrestart", "13a", "14", "15"]

    static let sessions: [SessionRow] = [
        .init(id: UUID(), profileName: "Work", started: now.addingTimeInterval(-3_600 * 2), duration: nil, received: 1_400_000_000, sent: 92_000_000, ended: .active),
        .init(id: UUID(), profileName: "Work", started: now.addingTimeInterval(-86_400 - 3_600 * 3), duration: 5_340, received: 31_800_000, sent: 1_200_000, ended: .user),
        .init(id: UUID(), profileName: "Acme", started: now.addingTimeInterval(-86_400 - 3_600 * 10), duration: 3_420, received: 1_300_000, sent: 2_200_000, ended: .network),
        .init(id: UUID(), profileName: "Home NAS", started: now.addingTimeInterval(-86_400 * 3), duration: 600, received: 8_000_000, sent: 300_000, ended: .error),
    ]

    static let checks: [DiagnosticCheck] = [
        .init(kind: .tunnel, result: .pass, summary: "Handshake 21 s ago · latency 12 ms", detail: "peer mJ3…= endpoint 198.51.100.7:51820"),
        .init(kind: .dns, result: .pass, summary: "Tunnel resolver 10.8.0.1 owns all domains", detail: "resolver #1\n  nameserver[0] : 10.8.0.1 (tunnel)\n  if_index : 24 (utun4)"),
        .init(kind: .ipv6, result: .unknown, summary: "Not tested while disconnected", detail: ""),
        .init(kind: .otherVPNs, result: .warning, summary: "utun7 (another app) has a default route", detail: "default  link#27  utun7"),
        .init(kind: .oldHelper, result: .pass, summary: "Removed", detail: "/Library/PrivilegedHelperTools/io.github.steiale.wireguide-helper: absent"),
    ]

    static let routes: [RouteRow] = [
        .init(destination: "0.0.0.0/0", gateway: "10.8.0.1", interface: "utun4", viaTunnel: true),
        .init(destination: "::/0", gateway: "fe80::1%utun4", interface: "utun4", viaTunnel: true),
        .init(destination: "192.168.1.0/24", gateway: "link#6", interface: "en0", viaTunnel: false),
    ]

    static let logs: [LogEntry] = (0..<40).map { i in
        let levels: [LogEntry.Level] = [.info, .info, .debug, .warning, .info, .error]
        let messages = ["Starting tunnel Work", "Handshake completed", "Rekey timer armed", "DNS answer from a non-tunnel resolver ignored",
                        "Statistics: rx 1.4 GB tx 92 MB", "Peer unreachable, retrying in 20 s"]
        return LogEntry(id: i, date: now.addingTimeInterval(Double(i - 40) * 7), level: levels[i % levels.count],
                        source: i % 3 == 0 ? .app : .tunnel, message: messages[i % messages.count])
    }

    static let importPreview = ImportPreview(
        id: UUID(), fileName: "office.ovpn", name: "Office", kind: .openVPN,
        summary: ProfileSummary(endpoints: ["vpn.example.com:1194"], transport: "udp", isFullTunnel: true),
        report: ImportReport(items: [
            ImportReportItem(.ignored, line: 12, directive: "script-security", .scriptsNeverRun),
            // `up` itself is rejected by the importer; verify-hash is a realistic not-applied line.
            ImportReportItem(.ignored, line: 13, directive: "verify-hash", .verifyHashNotSupported),
            ImportReportItem(.ignored, line: 15, directive: "persist-tun", .persistenceNotNeeded),
            ImportReportItem(.note, line: 20, directive: "auth-nocache", .authNocacheAppended),
        ], supportedCount: 41))

    static let importPreviewWarnings: ImportPreview = {
        var p = importPreview
        p.report.add(.securityWarning, line: 7, directive: "cipher", .legacyCBCEncryption)
        p.report.add(.securityWarning, .serverOnOtherNetwork(interface: "bridge100"))
        return p
    }()

    static let importPreviewUnsupported: ImportPreview = {
        var p = importPreview
        p.report.add(.notSupported, line: 7, directive: "cipher", .outdatedCipher(name: "BF-CBC"))
        return p
    }()

    static let legacyRefuse = LegacyHelperNotice(
        message: "LockPlus 1.x is connected with its kill switch on. Its firewall would block this tunnel. Quit the old LockPlus or disconnect it first.",
        blocksConnect: true, warnsBeforeConnect: false)
    static let tunnelGap = "The tunnel's logs are readable only by administrators. They are included when an administrator exports diagnostics."

    static let diagnosticsFiles: [DiagnosticsPreviewFile] = [
        .init(name: "summary.txt", text: "LockPlus 2.0 (200)\nmacOS 27.0.1\nTunnel component: ready\nProfiles: 4 (2 WireGuard, 2 OpenVPN)\nActive: profile-1 (connected 02:14:07)"),
        .init(name: "dns.txt", text: "resolver #1\n  nameserver[0] : 10.8.0.1\n  if_index : 24 (utun4)\nresolver #2\n  domain : host-7f3a\n  nameserver[0] : ip-2c91"),
        .init(name: "routes.txt", text: "0.0.0.0/0        10.8.0.1   utun4\n192.168.1.0/24   link#6     en0"),
        .init(name: "app-log.txt", text: "21:02:11 info  Starting tunnel profile-1\n21:02:12 info  Handshake completed with host-a1b2"),
    ]

    static let batch = BatchImport(id: UUID(), archiveName: "profiles.zip", items: [
        .init(id: UUID(), fileName: "work.conf", report: ImportReport(supportedCount: 6)),
        .init(id: UUID(), fileName: "nas.conf", report: ImportReport(supportedCount: 5)),
        .init(id: UUID(), fileName: "office.ovpn", report: importPreview.report),
        .init(id: UUID(), fileName: "legacy.ovpn", selected: false, report: importPreviewUnsupported.report),
    ])
}

/// A no-op action sink for previews that also drives the preview state a little (connect/disconnect).
@MainActor final class PreviewUIActions: LPUIActions {
    weak var env: UIEnvironment?
    private(set) var log: [String] = []
    private func record(_ s: String) { log.append(s) }

    func connect(_ profileID: ProfileItem.ID) { start(profileID, acceptingWarning: false) }
    func connectAnyway(_ profileID: ProfileItem.ID) { start(profileID, acceptingWarning: true) }

    /// Mirrors `AppActions`: the §4.5 notice decides refuse/warn (the app re-reads the helper first).
    private func start(_ profileID: ProfileItem.ID, acceptingWarning: Bool) {
        guard let env else { record("connect"); return }
        if let n = env.connection.legacyHelper {
            if n.blocksConnect { env.connection.connectGate = .refused(profileID); return }
            if n.warnsBeforeConnect && !acceptingWarning { env.connection.connectGate = .warn(profileID); return }
        }
        record("connect")
        guard let p = env.profiles.profile(profileID) else { return }
        env.connection.profileID = profileID
        env.connection.inputs = DerivedStateInputs(profileName: p.name, status: .connected, killSwitch: p.killSwitch, dns: .verified)
        env.connection.connectedSince = Date()
    }
    func disconnect() {
        record("disconnect")
        env?.connection.inputs.status = .disconnected
    }
    func perform(_ action: StateAction) {
        record("perform \(action)")
        switch action {
        case .connect: if let id = env?.connection.profileID { connect(id) }
        case .disconnect, .disconnectAndRestoreInternet, .cancel: disconnect()
        case .resumeNow: resume()
        case .showSwitchAgain, .openSystemSettings, .approve: SystemSettingsLink.open(SystemSettingsLink.networkExtensions)
        default: break
        }
    }
    func pause(minutes: Int) { record("pause \(minutes)"); env?.connection.inputs.pausedUntil = Date().addingTimeInterval(Double(minutes * 60)) }
    func resume() { record("resume"); env?.connection.inputs.pausedUntil = nil }
    func submitAuth(_ answer: AuthAnswer) { record("submitAuth"); env?.auth.prompt = nil }
    func cancelAuth(_ promptID: UUID) { record("cancelAuth"); env?.auth.prompt = nil }
    func retryAuthApproval(_ promptID: UUID) { record("retryAuthApproval") }
    func newProfile(_ kind: ProfileKindChoice) { record("newProfile"); SceneBridge.requestEditor(.new(kind == .wireGuard ? .wireGuard : .openVPN)) }
    func editConfig(_ profileID: ProfileItem.ID) { record("editConfig"); SceneBridge.requestEditor(.existing(profileID)) }
    func export(_ profileID: ProfileItem.ID) { record("export") }
    func exportAll() { record("exportAll") }
    func duplicate(_ profileID: ProfileItem.ID) { record("duplicate") }
    func delete(_ profileID: ProfileItem.ID) { record("delete") }
    func rename(_ profileID: ProfileItem.ID, to name: String) { record("rename") }
    func setKillSwitch(_ on: Bool, for profileID: ProfileItem.ID) { update(profileID) { $0.killSwitch = on } }
    func setAllowLocalNetwork(_ on: Bool, for profileID: ProfileItem.ID) { update(profileID) { $0.allowLocalNetwork = on } }
    func setBlockIPv6(_ on: Bool, for profileID: ProfileItem.ID) { update(profileID) { $0.blockIPv6WithoutKillSwitch = on } }
    func setNotes(_ notes: String, for profileID: ProfileItem.ID) { update(profileID) { $0.notes = notes } }
    func changePassword(_ profileID: ProfileItem.ID) {
        record("changePassword")
        guard let env, let p = env.profiles.profile(profileID) else { return }
        env.profiles.passwordChange = PasswordChangeRequest(profileID: profileID, profileName: p.name,
                                                            username: p.credentials?.username ?? "", onSave: { _, _, _ in })
    }
    func forgetPassword(_ profileID: ProfileItem.ID) { record("forgetPassword") }
    func showPassword(_ profileID: ProfileItem.ID) {
        record("showPassword")
        guard let env, let p = env.profiles.profile(profileID) else { return }
        env.profiles.passwordReveal = PasswordReveal(profileName: p.name, username: p.credentials?.username, password: "preview-password")
    }
    func importFiles(_ urls: [URL]) { record("importFiles \(urls.count)") }
    func importFromClipboard() { record("importFromClipboard") }
    func confirmImport(_ preview: ImportPreview) { record("confirmImport"); env?.importer.preview = nil }
    func confirmBatch(_ batch: BatchImport) { record("confirmBatch"); env?.importer.batch = nil }
    func cancelImport() { record("cancelImport"); env?.importer.preview = nil; env?.importer.batch = nil }
    func openMainWindow() { record("openMainWindow") }
    func openSettings() { record("openSettings") }
    func quitFromMenu() { record("quit") }
    func reloadProfiles() { record("reloadProfiles") }
    func installExtension() { record("installExtension"); env?.onboarding.extensionStep = .needsApproval }
    func reinstallExtension() { record("reinstallExtension") }
    func allowVPNConfiguration() { record("allowVPNConfiguration"); env?.onboarding.configurationStep = .done }
    func finishOnboarding() { record("finishOnboarding"); env?.onboarding.isPresented = false }
    func importMigration(_ names: Set<String>) { record("importMigration \(names.count)") }
    func addEtcWireGuardProfiles() { record("addEtcWireGuardProfiles") }
    func requestNotificationPermission() { record("requestNotificationPermission") }
    func setLaunchAtLogin(_ on: Bool) { env?.settings.launchAtLogin = on ? .enabled : .disabled }
    func showInMenuBar() { env?.settings.showInMenuBar = true }
    func checkForUpdates() { record("checkForUpdates") }
    func uninstall() { record("uninstall") }
    func uninstall(deletingProfilesAndHistory: Bool) { record("uninstall deleting=\(deletingProfilesAndHistory)") }
    func runDiagnostics() { record("runDiagnostics") }
    func reloadRoutes() { record("reloadRoutes") }
    func copyLogs() { record("copyLogs") }
    func saveLogs() { record("saveLogs") }
    func clearLogs() { env?.logs.entries = [] }
    func clearHistory() { env?.activity.sessions = [] }
    func prepareDiagnosticsPreview() async -> [DiagnosticsPreviewFile] { PreviewData.diagnosticsFiles }
    func exportDiagnostics() { record("exportDiagnostics") }
    func openOldLockPlus() { record("openOldLockPlus") }
    func removeOldHelper() {
        record("removeOldHelper")
        env?.connection.legacyHelper = nil
        env?.connection.legacyHelperRemoval = .removed(leftNetworkState: false)
    }
    func findOldLockPlusData() {
        record("findOldLockPlusData")
        env?.onboarding.migration = .init(profileNames: ["old-office"], savedPasswords: 0)
        env?.onboarding.migrationSelection = ["old-office"]
    }
    func closeMigration() { record("closeMigration"); env?.onboarding.closeMigration() }
    func dismissOldHelperRemoval() { record("dismissOldHelperRemoval"); env?.connection.legacyHelperRemoval = nil }
    func removeLockedProfiles() { record("removeLockedProfiles"); env?.profiles.locked = nil }
    func startOverAndReimport() { record("startOverAndReimport"); env?.profiles.locked = nil }
    func startOverAndImportFromOldApp() {
        record("startOverAndImportFromOldApp"); env?.profiles.locked = nil
        env?.onboarding.step = .profiles; env?.onboarding.isPresented = true
    }
    func importMigration(_ names: Set<String>, includingSavedPasswords: Bool) { record("importMigration \(names.count) passwords=\(includingSavedPasswords)") }
    func showLogs(around date: Date) { record("showLogs"); NavigationRequest.post(.logs) }
    func settingsDidAppear() { record("settingsDidAppear") }
    func addCurrentNetwork() { record("addCurrentNetwork") }
    func requestLocationAccess() { record("requestLocationAccess"); env?.autoConnect.location = .authorized }

    private func update(_ id: ProfileItem.ID, _ change: (inout ProfileItem) -> Void) {
        guard let env, let i = env.profiles.profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&env.profiles.profiles[i])
    }
}

extension UIEnvironment {
    /// A fully populated environment for previews, with the derived state set to one §6.6 row.
    static func preview(row: String = "6", profile: ProfileItem = PreviewData.work, profiles: [ProfileItem] = PreviewData.profiles,
                        prompt: AuthPromptState? = nil) -> UIEnvironment {
        let actions = PreviewUIActions()
        let connection = ConnectionUIModel(profileID: profile.id, inputs: PreviewData.inputs(row: row, profile: profile))
        connection.connectedSince = PreviewData.now.addingTimeInterval(-(2 * 3_600 + 14 * 60 + 7))
        connection.anyOnDemandEnabled = true
        connection.lastErrorAt = PreviewData.now.addingTimeInterval(-40)
        let samples = PreviewData.samples()
        let stats = StatsUIModel(current: Rate(down: 1_234_567, up: 30_120), samples: samples)
        stats.sessionReceived = 1_400_000_000
        stats.sessionSent = 92_000_000
        stats.lastHandshake = PreviewData.now.addingTimeInterval(-21)
        stats.latencyMilliseconds = 12
        let activity = ActivityUIModel(sessions: PreviewData.sessions)
        let diagnostics = DiagnosticsUIModel()
        diagnostics.checks = PreviewData.checks
        diagnostics.routes = PreviewData.routes
        let autoConnect = AutoConnectUIModel()
        autoConnect.enabled = true
        autoConnect.profileID = PreviewData.nasID
        autoConnect.trustedNetworks = ["Home-5G", "Office-Guest"]
        let env = UIEnvironment(
            profiles: ProfilesUIModel(profiles: profiles, selection: profiles.isEmpty ? nil : profile.id),
            connection: connection, stats: stats, auth: AuthUIModel(prompt: prompt), settings: SettingsUIModel(),
            onboarding: OnboardingUIModel(), importer: ImportUIModel(), activity: activity, diagnostics: diagnostics,
            logs: LogsUIModel(entries: PreviewData.logs), autoConnect: autoConnect, actions: actions)
        actions.env = env
        return env
    }
}
