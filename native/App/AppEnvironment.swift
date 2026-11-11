import AppKit
import LPModel
import LPParsing
import LPRouteProbe
import LPWire
import LPXPCClient
import Observation
import os

/// How the app runs. `.preview` = the "no extension" mode: real stores and UI over simulated NE/XPC/sysext backends
/// (`LP_PREVIEW_MODE=1` or `-LPPreviewMode YES`).
enum AppMode: Sendable, Equatable {
    case live, preview

    /// Fable M1: honoured in DEBUG builds only; a Release build is always `.live`.
    static func detect(_ env: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) -> AppMode {
        #if DEBUG
        if env["LP_PREVIEW_MODE"] == "1" || defaults.bool(forKey: "LPPreviewMode") { return .preview }
        #endif
        return .live
    }
}

/// Owns every store and long-lived service of the app (DESIGN §11.1), and the one `UIEnvironment` the views read.
/// Created by `AppDelegate`.
@MainActor final class AppEnvironment {
    let mode: AppMode
    let ui: UIEnvironment
    let settings: SettingsStore
    let profiles: ProfilesStore
    let connection: ConnectionStore
    let auth: AuthCoordinator
    let stats: StatsStore
    let diagnostics: DiagnosticsStore
    let logs: LogsStore
    let dnsSystem: any DNSSystemReading
    let logSources: any LogSources
    let host: any HostDiagnosticsReading
    let legacy: LegacyHelperStore
    let wifi: any WiFiLocating
    let network: any NetworkWatching
    /// The editor windows' backend (§11.4); created lazily because it holds the environment weakly.
    private(set) lazy var editorBackend: AppEditorBackend = AppEditorBackend(env: self)
    let importer: ImportCoordinator
    let migrator: GoAppMigrator
    let extensionStore: any ExtensionControlling
    let managers: any VPNManaging
    let service: any TunnelServicing
    let hooks: any SystemHooks
    let files: SettingsFileStore?
    /// §12.3: the Sparkle-independent update logic, and the updater (Sparkle live, simulated in preview mode).
    let updates: UpdateCoordinator
    let updater: any Updating
    /// Live mode only (the Debug menu).
    let systemExtensions: SystemExtensionManager?
    private(set) var history: [HistoryEntry] = []
    /// UIBinder state (E2E-2 bug 1): the settings last pushed into the editable models, and the on-demand re-save
    /// in flight (one at a time; a change meanwhile asks for one more pass).
    var uiAppliedSettings: AppSettings?
    var uiResaving = false
    var uiResaveAgain = false

    private var tasks: [Task<Void, Never>] = []
    /// E2E-5 F5.
    let legacyAgentHome: String?
    var launchContext = LaunchContext()
    /// The old agent was retired during this launch (the migration report then knows the old app opened at login).
    private(set) var retiredGoAgent = false
    /// §10.4: held for the GUI's lifetime so the headless resume agent leaves expiry to us.
    private var instanceLock: InstanceLock?
    let dataDirectory: AppDataDirectory
    private var started = false
    /// 2.0.1 E2E: this launch is the first of its build (a first launch or an update): the main window opens.
    private(set) var launchedNewBuild = false
    private var menuOpenedThisLaunch = false
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "app")

    struct Backends {
        var mode: AppMode
        var dataDirectory: AppDataDirectory
        var keychain: any SecretItemStore
        var managers: any VPNManaging
        var service: any TunnelServicing
        var extensionStore: any ExtensionControlling
        var systemExtensions: SystemExtensionManager?
        var hooks: any SystemHooks
        var goSource: @Sendable () -> (any GoAppDataSource)?
        var probe: any EndpointRouteProbing
        var persistFiles: Bool
        var quiescer: ManagerQuiescer? = nil
        var makeUpdater: @MainActor (UpdateCoordinator) -> any Updating = { _ in InertUpdater() }
        var resumeAgent: any ResumeAgentControlling = InertResumeAgent()
        /// Draft 9 (S2 E10): endpoint hostnames resolved by the app before each start (`lp.endpoints`). Previews and
        /// tests resolve nothing.
        var resolveEndpoints: @Sendable ([String]) async -> [String: [String]] = { _ in [:] }
        var dnsSystem: any DNSSystemReading = FixtureDNSSystem.preview
        var logSources: any LogSources = FixtureLogSources.preview
        var host: any HostDiagnosticsReading = FixtureHostDiagnostics()
        /// §6.7: the login keychain (live only); preview mode and tests never touch a host keychain.
        var legacyKeychain: (any LegacyKeychainReading)? = nil
        /// §4.5 Go helper coexistence reads (live: files + the helper socket; tests: nothing installed).
        var legacySystem: any LegacySystemReading = FixtureLegacySystem()
        /// E2E-5 F5: the home folder whose `Library/LaunchAgents` may hold LockPlus 1.0.x's agent (live: the user's;
        /// nil: never looked at, preview mode).
        var legacyAgentHome: String? = nil
        /// E2E-5 F1: "Remove Old Helper" (live: osascript `with administrator privileges`; tests and preview: fakes).
        var legacyHelperRunner: any PrivilegedScriptRunning = FakePrivilegedRunner()
        /// "Add Current Network" (live: CoreLocation + CoreWLAN).
        var makeWiFi: @MainActor () -> any WiFiLocating = { FixtureWiFiLocator() }
        /// §10.4 network changes (live: NWPathMonitor).
        var makeNetworkWatcher: @MainActor () -> any NetworkWatching = { FixtureNetworkWatcher() }
        /// The settle window before a start (review F5); tests substitute a clock that never really sleeps.
        var settleClock: SettleClock = .live
        /// E2E-4: settings.json is written only after `start()` has read it (a quit before that wrote defaults over the
        /// file). Tests that drive the stores without `start()` opt out.
        var settingsWritableBeforeLoad = false
    }

    static func liveBackends(bundle: Bundle = .main) -> Backends {
        let quiescer = ManagerQuiescer()
        let manager = SystemExtensionManager(bundle: bundle, quiescer: quiescer)
        let service: any TunnelServicing
        if let name = manager.machServiceName {
            service = XPCTunnelService(client: TunnelServiceClient(
                machServiceName: name, peerRequirement: EXT_REQ,
                appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))
        } else {
            service = UnavailableTunnelService()
        }
        return Backends(mode: .live, dataDirectory: .standard(), keychain: DataProtectionKeychain(),
                        managers: NEManagerStore(providerBundleIdentifier: manager.extensionIdentifier), service: service,
                        extensionStore: ExtensionStore(manager: manager, service: service), systemExtensions: manager,
                        hooks: LiveSystemHooks(), goSource: GoAppMigrator.liveSource, probe: RouteProbe(), persistFiles: true,
                        quiescer: quiescer, makeUpdater: { UpdateController(coordinator: $0) }, resumeAgent: SMResumeAgent(),
                        resolveEndpoints: { @Sendable in await StartEndpointResolver.resolve($0) },
                        dnsSystem: LiveDNSSystem(), logSources: LiveLogSources(), host: LiveHostDiagnostics(),
                        legacyKeychain: LoginKeychainReader(), legacySystem: LiveLegacySystem(), legacyAgentHome: NSHomeDirectory(), legacyHelperRunner: InProcessAppleScriptRunner(),
                        makeWiFi: { LiveWiFiLocator() }, makeNetworkWatcher: { LiveNetworkWatcher() })
    }

    #if DEBUG
    /// Preview mode (DEBUG only): a separate data directory (reset at every preview launch), an in-memory keychain and
    /// the simulated backends. Never the live bundle ID's directory, never the Go app's data.
    static func previewBackends() -> Backends {
        let world = PreviewWorld()
        let dir = AppDataDirectory.standard(bundleID: "io.github.steiale.lockplus.mac.preview")
        var b = Backends(mode: .preview, dataDirectory: dir, keychain: InMemoryKeychain(),
                         managers: PreviewManagerStore(world: world), service: PreviewTunnelService(world: world),
                         extensionStore: PreviewExtensionStore(), systemExtensions: nil, hooks: InertSystemHooks(),
                         goSource: { PreviewSeed.GoFixture() }, probe: NoRouteProbe(), persistFiles: true)
        // Demo: the old helper is still installed but idle (the §4.5 banner and the Diagnostics row); "Remove Old
        // Helper…" simulates the administrator run and removes it from the demo world.
        let legacy = PreviewLegacySystem()
        b.legacySystem = legacy
        b.legacyHelperRunner = FakePrivilegedRunner(answer: .finished(output: "LP_RESULT=removed")) { legacy.removeHelper() }
        b.makeUpdater = { PreviewUpdater(coordinator: $0) }
        return b
    }
    #endif

    convenience init(mode: AppMode = .detect()) {
        #if DEBUG
        self.init(backends: mode == .preview ? Self.previewBackends() : Self.liveBackends())
        #else
        self.init(backends: Self.liveBackends())
        #endif
    }

    init(backends b: Backends) {
        mode = b.mode
        dataDirectory = b.dataDirectory
        legacyAgentHome = b.legacyAgentHome
        let managers = SerializedVPNManager(inner: b.managers, settleClock: b.settleClock)    // review H3: every store goes through it
        self.managers = managers
        service = b.service
        extensionStore = b.extensionStore
        systemExtensions = b.systemExtensions
        hooks = b.hooks
        files = b.persistFiles ? SettingsFileStore(dir: b.dataDirectory) : nil
        settings = SettingsStore(files: files, loadedFromDisk: files == nil || b.settingsWritableBeforeLoad)
        let repo = ProfileRepository(directory: b.dataDirectory.profiles, keys: b.keychain)
        profiles = ProfilesStore(repository: repo, credentialStore: CredentialStore(items: b.keychain), managers: managers,
                                 service: b.service, settings: settings,
                                 factsFile: b.persistFiles ? b.dataDirectory.credentialFacts : nil)
        connection = ConnectionStore(managers: managers, service: b.service, profiles: profiles, settings: settings)
        connection.resumeAgent = b.resumeAgent
        connection.resolveEndpoints = b.resolveEndpoints
        profiles.onDemandHeldBack = { [weak connection] id in connection?.holdsBackOnDemand(of: id) ?? false }   // E2E-3
        profiles.mutationBlocked = { [weak connection] id in connection?.mutationBlocked(id) ?? false }           // review F5, R3
        profiles.otherStartPending = { [weak connection] id in connection?.foreignStartPending(except: id) ?? false }   // round 7
        profiles.stopSessionBeforeRemoval = { [weak connection] id in                                              // review e321e10
            guard let connection else { return }
            _ = await connection.stopAndWait(id, timeout: connection.removalStopTimeout)
        }
        diagnostics = DiagnosticsStore(system: b.dnsSystem, profiles: profiles)
        dnsSystem = b.dnsSystem
        logSources = b.logSources
        host = b.host
        legacy = LegacyHelperStore(system: b.legacySystem, runner: b.legacyHelperRunner)
        legacy.nativeTunnelUp = { [weak connection] in                                                             // E2E-7 F3 L4
            connection?.statuses.values.contains { $0 != .disconnected && $0 != .invalid } ?? false
        }
        wifi = b.makeWiFi()
        network = b.makeNetworkWatcher()
        auth = AuthCoordinator(service: b.service, profiles: profiles, connection: connection)
        b.quiescer?.attach(managers: managers, settings: settings, connection: connection)
        let extensionStore = b.extensionStore
        let coordinator = UpdateCoordinator(settings: settings, extensionStore: { [weak extensionStore] in extensionStore })
        coordinator.onInstallDidNotHappen = { [weak connection] in
            await connection?.endExtensionHandOver { $0.expectedUpdate = nil }       // review 4 #2: one marker-clearing path
        }
        updates = coordinator
        updater = b.makeUpdater(coordinator)

        let actions = AppActions()
        ui = UIEnvironment(profiles: ProfilesUIModel(), connection: ConnectionUIModel(inputs: DerivedStateInputs(profileName: "")),
                           stats: StatsUIModel(), auth: AuthUIModel(), settings: SettingsUIModel(), onboarding: OnboardingUIModel(),
                           importer: ImportUIModel(), activity: ActivityUIModel(), diagnostics: DiagnosticsUIModel(),
                           logs: LogsUIModel(), autoConnect: AutoConnectUIModel(), actions: actions)
        let connection = self.connection
        stats = StatsStore(service: b.service, model: ui.stats, profileID: { connection.currentID },
                           isActive: { connection.currentStatus.isActive })
        importer = ImportCoordinator(model: ui.importer, profiles: profiles, service: b.service, settings: settings, probe: b.probe)
        importer.resolveEndpoints = b.resolveEndpoints
        migrator = GoAppMigrator(source: b.goSource, profiles: profiles, settings: settings, files: files, service: b.service,
                                 probe: b.probe, keychain: b.legacyKeychain)
        // Migration matrix: only the live app looks for upstream WireGuide's directory (preview and tests never do).
        if b.mode == .live { migrator.upstreamWireGuide = GoAppMigrator.liveUpstreamWireGuide }
        let logsModel = ui.logs
        logs = LogsStore(sources: b.logSources, model: logsModel, redactor: { Redactor() })
        actions.env = self
        logs.redactorFactory = { [weak self] in self?.makeRedactor() ?? Redactor() }
        connection.onNotice = { [weak self] n in self?.notify(n) }
        (hooks as? LiveSystemHooks)?.presentResidual = { [weak self] m in await self?.ui.settings.presentResidual(m) ?? false }
        connection.onStatusForDiagnostics = { [weak self] id, s in self?.diagnostics.statusChanged(id, s) }
        auth.onPromptShown = { [weak self] p in
            // AUTH_PENDING (approve on another device) is a wait, not a sign-in to type.
            guard p.kind != .pendingApproval else { return }
            // A reconnect prompt (the session was up) vs. a sign-in to connect (in the pending start or before it).
            let reconnect = self?.connection.statuses[p.profileID] == .reasserting
            self?.notify(.needsSignIn(p.profileID, reconnect: reconnect))
        }
        hooks.onNotificationActivated = { [weak self] in self?.ui.actions.openMainWindow() }
        importer.onImported = { [weak self] id in
            guard let self else { return }
            ui.profiles.selection = id
            // E2E-4 review L5: after a failed update XPC is out of reach, so a profile imported now can't be set up.
            if case .updateFailed = extensionStore.state, let name = profiles.profile(id)?.name {
                profiles.note(String(localized: "LockPlus couldn't update its tunnel component, so \(name) can't connect yet. Profiles set up before the update still connect.",
                                     comment: "Problem: a profile was imported while the tunnel component update had failed (E2E-4 review L5)"))
            }
        }
        migrator.history = { [weak self] entries in await self?.appendHistory(entries) }
        migrator.onAutoConnectChanged = { [weak self] in if let self { UIBinder.requestOnDemandResave(self) } }
        migrator.launchAtLogin = .init(retireGoAgent: { [weak self] in
                                           guard let self else { return false }
                                           return self.retireGoLaunchAgent(offer: false) || self.retiredGoAgent
                                       },
                                       nativeEnabled: { [weak self] in self.map { $0.hooks.loginItemState() != .disabled } ?? false })
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        ui.settings.version = version
        ui.settings.build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        #if DEBUG
        ui.settings.isDevBuild = true
        #endif
        ui.settings.canCheckForUpdates = false        // until the updater reports canCheckForUpdates (KVO, §12.1)
        let settingsUI = ui.settings
        updater.onCanCheckChange = { [weak settingsUI] can in settingsUI?.canCheckForUpdates = can }
        updates.onUpdateAvailableChange = { [weak settingsUI] available in settingsUI?.updateAvailable = available }
    }

    // MARK: Lifecycle

    /// `applicationDidFinishLaunching`. Order: settings → NE managers (before any save, §3.4) → profiles (replay check
    /// against the managers) → connection state → extension activation (hello + reconcile on `.completed`).
    func start() async {
        guard !started else { return }
        started = true
        if mode == .live { launchContext = LaunchContext.current }
        // Preview mode starts from a clean, separate directory every launch (its keychain is in memory).
        if mode == .preview, let files { try? FileManager.default.removeItem(at: files.dir.root) }
        await acquireInstanceLock()
        let settingsProblem = await loadSettingsAtLaunch()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        settings.update { s in
            s.launches = Array((s.launches + [Date()]).suffix(5))
            launchedNewBuild = AppSettings.isNewBuildLaunch(previous: s.lastLaunchedBuild, current: build)
            s.lastLaunchedBuild = build
        }
        do throws(LPError) { try await managers.loadAll() } catch { log.error("loadAllFromPreferences: \(error.code.rawValue, privacy: .public)") }
        #if DEBUG
        if mode == .preview { await seedPreviewProfiles() }
        #endif
        await profiles.load()
        noteSettingsProblem(settingsProblem)
        retireGoLaunchAgent()
        connection.start()
        await connection.reconcileResumeAgent()
        network.onChange = { [weak self] sig in self?.connection.networkChanged(sig) }
        network.start()
        managers.onConfigurationChange = { [weak self] in
            guard let self else { return }
            self.connection.configurationChanged()
            Task { await self.profiles.load() }
        }
        extensionStore.onReady = { [weak self] in self?.helloAndReconcile() }
        // §12.1: Sparkle starts only after the activation preflight, so no update alert lands on "Updating…".
        extensionStore.onPreflightFinished = { [weak self] in self?.updater.start() }
        extensionStore.start()
        let events = service.events
        tasks.append(Task { @MainActor [weak self] in
            for await e in events { self?.handle(e) }
        })
        UIBinder.bind(self)
        Task { await legacy.refresh() }
        ui.autoConnect.location = wifi.authorization            // reading the state never prompts
        ui.autoConnect.currentSSID = wifi.currentSSID()
        if let id = connection.currentID { Task { await auth.pullPending(id) } }
        await startOnboardingIfNeeded()
        await offerMigrationWhileLocked()
        await offerToFinishMigration()
    }

    /// E2E-4: settings.json (and history) from disk; from here on settings writes go through. Returns the load when the
    /// file was unreadable (moved aside, defaults in use), for `noteSettingsProblem` once Diagnostics exists.
    func loadSettingsAtLaunch() async -> SettingsFileStore.SettingsLoad? {
        guard let files else { return nil }
        let loaded = await files.loadSettingsChecked()
        settings.replaceAll(loaded.settings)
        AppAppearanceApplier.apply(loaded.settings.appearance)         // §6.14: before the first window shows
        history = await files.loadHistory()
        return loaded.problem == nil ? nil : loaded
    }

    /// E2E-4: never silent. The file is kept under its new name; defaults are in use.
    func noteSettingsProblem(_ p: SettingsFileStore.SettingsLoad?) {
        guard let p else { return }
        let why = p.problem ?? ""
        if let kept = p.movedAside?.lastPathComponent {
            profiles.note(String(localized: "LockPlus couldn't read its settings (\(why)) and started with default settings. The old file was kept as \(kept).", comment: "Problem: settings.json was unreadable and moved aside (E2E-4)"))
        } else {
            profiles.note(String(localized: "LockPlus couldn't read its settings (\(why)) and started with default settings.", comment: "Problem: settings.json was unreadable and couldn't be moved aside (E2E-4)"))
        }
        // L6: a dropped Auto-Connect (or its pause) is off now; on-demand of a paused profile stays off in the system.
        if p.mayHaveHeldAutoConnect {
            profiles.note(String(localized: "Auto-connect is off after this reset; turn it on again in Settings.", comment: "Problem: the reset settings may have held Auto-Connect or a pause of it (E2E-4 review L6)"))
        }
    }

    /// A resume agent run may hold the lock for a moment (≤ 5 s); retry briefly, never block the main thread.
    func acquireInstanceLock(attempts: Int = 20, interval: Duration = .milliseconds(300)) async {
        for _ in 0..<attempts {
            if let l = InstanceLock.tryAcquire(at: dataDirectory.instanceLock) { instanceLock = l; return }
            try? await Task.sleep(for: interval)
        }
        // FA-L5: after ~6 s (longer than a resume-agent run) the holder is another LockPlus GUI: say so and quit
        // rather than run two instances against one data directory.
        // E2E-5 F5: a copy started at login (LockPlus 1.0.x's LaunchAgent, now pointing at this binary, or a login
        // item) quits silently; it also retires the old agent so the next login doesn't start it again.
        if launchContext.quietIfAlreadyRunning {
            log.notice("instance lock held by another LockPlus; started at login (old agent: \(self.launchContext.byGoLaunchAgent, privacy: .public)), quitting silently")
            retireGoLaunchAgent(offer: false)
            hooks.quitSilently()
            return
        }
        log.error("instance lock held by another LockPlus; quitting")
        await hooks.quitBecauseAlreadyRunning()
    }

    /// E2E-5 F5: removes LockPlus 1.0.x's LaunchAgent (user domain, exact file only). With `offer`, a user who had the
    /// old app open at login is offered LockPlus's own launch at login (never registered without asking, NR pitfall 14).
    @discardableResult
    func retireGoLaunchAgent(offer: Bool = true) -> Bool {
        guard let home = legacyAgentHome, LegacyLaunchAgent.retire(home: home) else { return false }
        retiredGoAgent = true
        if offer, hooks.loginItemState() == .disabled {
            settings.update { $0.launchAtLoginOffer = true }       // persisted until answered (pre-release review LOW)
            ui.settings.launchAtLoginOffer = true
        }
        return true
    }

    /// §4.4 step 7 deleted the data directory: nothing may write it again (the quit path included).
    private(set) var dataDeleted = false

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        // E2E-4: a quit before `start()` read settings.json (a scripted quit right after launch, the second-instance
        // alert) must not write: `writeSynchronously` refuses until the file was read, and so does the queue.
        guard !dataDeleted, settings.loadedFromDisk else { return }
        settings.update { $0.lastQuitAt = Date() }
        settings.writeSynchronously()          // the app is about to exit
    }

    /// §4.4 step 7: removes the app data directory (profiles, history, settings). Never the Go app's data.
    func deleteAppData() async {
        stop()
        dataDeleted = true
        await settings.flush()                 // no queued write may recreate the directory
        try? FileManager.default.removeItem(at: dataDirectory.root)
    }

    func helloAndReconcile() {
        let service = self.service
        Task { @MainActor in
            do throws(LPError) {
                let h = try await service.hello()
                log.notice("hello OK ext \(h.extVersion, privacy: .public) (\(h.extBuild, privacy: .public))")
            } catch {
                log.error("hello failed: \(error.code.rawValue, privacy: .public)")
                return
            }
            await profiles.reconcile()
            await syncSessions()
            connection.refreshSnapshot()
            if let id = connection.currentID { await auth.pullPending(id) }
        }
    }

    /// Events are hints: re-pull snapshot and prompts on every one (§11.2).
    private func handle(_ e: TunnelEvent) {
        auth.handle(e)
        switch e.kind {
        case .sessionEnded:
            connection.resetSnapshotEpoch()          // the next session's epochs start over (H6)
            connection.refreshSnapshot()
            Task { await syncSessions() }
        case .snapshotChanged, .anyTunnelStateChanged: connection.refreshSnapshot()
        case .authRequired, .promptResolved: break
        }
    }

    // MARK: Diagnostics (§10.2, UI-CONCEPT §6.11)

    /// "Run All" (⌘R): the DNS verifier on demand plus the check rows.
    func runDiagnostics() async {
        ui.diagnostics.isRunning = true
        defer { ui.diagnostics.isRunning = false }
        let id = connection.currentID
        let connected = connection.currentStatus == .connected
        if connected, let id { await diagnostics.verify(id) }
        var checks = [tunnelCheck(), diagnostics.dnsCheck(connected: connected)]
        checks.append(DiagnosticCheck(kind: .ipv6, result: .unknown,
                                      summary: connected ? String(localized: "Not tested", comment: "Diagnostics IPv6 row")
                                                         : String(localized: "Not tested while disconnected", comment: "Diagnostics IPv6 row"),
                                      detail: ""))
        await reloadRoutes()
        checks.append(otherVPNsCheck(connected: connected))
        await legacy.refresh()
        checks.append(legacy.check)
        ui.diagnostics.checks = checks
    }

    /// Other utun interfaces with a default route: one is ours while connected (UI-CONCEPT §6.11).
    private func otherVPNsCheck(connected: Bool) -> DiagnosticCheck {
        let tunnels = RouteTable.otherDefaultTunnels(ui.diagnostics.routes).sorted()
        let foreign = connected ? max(0, tunnels.count - 1) : tunnels.count
        if foreign == 0 {
            return DiagnosticCheck(kind: .otherVPNs, result: .pass,
                                   summary: String(localized: "No other VPN has a default route", comment: "Diagnostics other-VPNs row"),
                                   detail: tunnels.joined(separator: ", "))
        }
        return DiagnosticCheck(kind: .otherVPNs, result: .warning,
                               summary: String(localized: "Another VPN may route all traffic", comment: "Diagnostics other-VPNs row"),
                               detail: tunnels.joined(separator: ", "))
    }

    private func tunnelCheck() -> DiagnosticCheck {
        let name = profiles.profile(connection.currentID)?.name ?? ""
        switch connection.currentStatus {
        case .connected:
            return DiagnosticCheck(kind: .tunnel, result: .pass,
                                   summary: String(localized: "Connected to \(name)", comment: "Diagnostics tunnel row"), detail: "")
        case .connecting, .reasserting:
            return DiagnosticCheck(kind: .tunnel, result: .warning,
                                   summary: String(localized: "Connecting \(name)…", comment: "Diagnostics tunnel row"), detail: "")
        default:
            let err = connection.observedError.map { "\($0.code.rawValue)" } ?? ""
            return DiagnosticCheck(kind: .tunnel, result: connection.observedError == nil ? .unknown : .fail,
                                   summary: String(localized: "Not connected", comment: "Diagnostics tunnel row"), detail: err)
        }
    }

    // MARK: Auto-Connect: "Add Current Network" (§10.4)

    func addCurrentNetwork() async {
        var state = wifi.authorization
        if state == .notDetermined { state = await wifi.requestAuthorization() }
        ui.autoConnect.location = state
        guard state == .authorized, let ssid = wifi.currentSSID(), !ssid.isEmpty else {
            ui.autoConnect.currentSSID = nil
            return
        }
        ui.autoConnect.currentSSID = ssid
        // Settings are the source of truth (§3.2 caps); the binder mirrors them into the UI model.
        let list = AutoConnectRules.sanitizedSSIDs(settings.value.autoConnect.trustedSSIDs + [ssid])
        guard list != settings.value.autoConnect.trustedSSIDs else { return }
        settings.update { $0.autoConnect.trustedSSIDs = list }
        UIMapping.set(&ui.autoConnect.trustedNetworks, list)
        await profiles.resaveOnDemand()
    }

    // MARK: User notifications (§11.7)

    /// Posted only while no LockPlus window is key, per the `notifications` setting; the profile name only.
    func notify(_ n: ConnectionNotice) {
        guard NotificationPolicy.shouldPost(n, mode: settings.value.notifications, anyWindowKey: hooks.anyWindowKey()),
              let name = profiles.profile(n.profileID)?.name else { return }
        hooks.post(NotificationPolicy.notice(n, profileName: name))
    }

    /// Choosing a non-Off mode while authorization is undecided asks then (§11.7); never otherwise.
    func notificationModeChanged(to mode: AppSettings.Notifications) async {
        guard mode != .off, await hooks.notificationAuthorization() == .notDetermined else { return }
        await hooks.requestNotificationPermission()
        ui.settings.notificationsDeniedBySystem = await hooks.notificationsDenied()
    }

    // MARK: History (§3.2, §7.7)

    func appendHistory(_ entries: [HistoryEntry]) async {
        var h = history
        for e in entries where !h.contains(where: { $0.id == e.id }) { h.append(e) }
        h.sort { $0.start < $1.start }
        history = Array(h.suffix(HistoryEntry.cap))
        await files?.save(history: history)
    }

    func syncSessions() async {
        guard let r = try? await service.call(.sessionSummaries, SessionSummariesRequest(after: nil), as: SessionSummariesReply.self) else { return }
        let entries = r.sessions.map { s in
            HistoryEntry(id: s.id, profileID: s.profileID, profileName: profiles.profile(s.profileID)?.name ?? "—", start: s.start,
                         end: s.end, rxBytes: s.rxBytes, txBytes: s.txBytes, endReason: .init(summary: s.endReason))
        }
        await appendHistory(entries)
    }

    func clearHistory() async {
        history = []
        await files?.save(history: [])
    }

    // MARK: Onboarding and migration (§11.1, §13)

    private func startOnboardingIfNeeded() async {
        guard !settings.value.onboardingComplete else { return }
        ui.onboarding.step = .welcome
        ui.onboarding.isPresented = true
        if let offer = await migrator.detect() {
            ui.onboarding.migration = offer
            ui.onboarding.migrationSelection = Set(offer.profileNames)
        }
        ui.actions.openMainWindow()
    }

    /// §6.8: the locked view offers "Import from old LockPlus" when the Go app's data exists. Forced past the
    /// migration marker: a restore brings the marker along with the locked files it described.
    func offerMigrationWhileLocked() async {
        guard profiles.locked != nil, ui.onboarding.migration == nil else { return }
        if let offer = await migrator.detect(force: true) {
            ui.onboarding.migration = offer
            ui.onboarding.migrationSelection = Set(offer.profileNames)
        }
    }

    /// E2E-5 F4: an earlier migration didn't finish (the app was killed during it) and onboarding is done: the main
    /// window's banner offers to finish it. (Before onboarding is done, onboarding's step 4 offers it.)
    /// Pre-release review M3: migration.json is read first; the Go data (and the keychain listing) only when it records
    /// an import that didn't finish, and a discarded offer keeps no plan.
    func offerToFinishMigration() async {
        guard settings.value.onboardingComplete, profiles.locked == nil, ui.onboarding.migration == nil,
              await migrator.hasUnfinishedMigration() else { return }
        guard let offer = await migrator.detect(), offer.finishesEarlierImport else {
            migrator.discardPlan()
            return
        }
        ui.onboarding.migration = offer
        ui.onboarding.migrationSelection = Set(offer.profileNames)
        ui.onboarding.migrationResumePending = true
    }

    func recordMenuOpened() {
        guard !menuOpenedThisLaunch else { return }
        menuOpenedThisLaunch = true
        settings.update { $0.menuOpenedLaunches = Array(($0.menuOpenedLaunches + [Date()]).suffix(5)) }
    }

    #if DEBUG
    private func seedPreviewProfiles() async {
        guard profiles.profiles.isEmpty else { return }
        for (name, text) in PreviewSeed.files {
            let a = await ImportCoordinator.analyse(fileName: name, bytes: Array(text.utf8), service: service, probe: NoRouteProbe())
            guard let d = importer.draft(a, name: a.displayName, killSwitch: a.summary.isFullTunnel, allowLAN: false) else {
                log.error("preview seed \(name, privacy: .public) was rejected")
                continue
            }
            _ = try? await profiles.create(d)
        }
        await profiles.load()
        if let nas = profiles.profiles.first(where: { $0.name == "Home NAS" }) {
            settings.update {
                $0.autoConnect.profileID = nas.id
                $0.autoConnect.trustedSSIDs = ["Home-5G"]
            }
        }
        if let desk = profiles.profiles.first(where: { $0.name == "Office" }), let m = (managers as? SerializedVPNManager)?.inner as? PreviewManagerStore {
            m.challengeOnStart.insert(desk.id)      // shows the CRV1 sign-in inside the first connect (draft 9)
        }
    }
    #endif
}

/// RouteProbe stand-in for preview mode (no routing-table reads, no name resolution).
struct NoRouteProbe: EndpointRouteProbing {
    func nonPrimaryInterface(for endpoint: ImportEndpoint) async -> String? { nil }
}
