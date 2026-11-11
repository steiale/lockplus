import AppKit
import Foundation
import LPModel
import LPParsing
import LPWire
import os
import UniformTypeIdentifiers

/// The app's `LPUIActions` (App/UI/Models/UIActions.swift): every UI intent mapped onto the stores. Main-actor;
/// work goes to actors/XPC with Sendable values.
@MainActor final class AppActions: LPUIActions {
    weak var env: AppEnvironment?
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "actions")

    private func with(_ body: (AppEnvironment) -> Void) { if let env { body(env) } }

    // MARK: Connection

    /// `startVPNTunnel(options:)` with `lp.manual = 1` (StartOptionsBuilder); known-interactive profiles prompt first.
    /// Every UI Connect arrives here through `UIEnvironment.gatedConnect`. §4.5: while the old helper may be installed
    /// (cached fact or a fresh `lstat` of its plist), its state is re-read (≤ 2 s) right before EVERY start (M9; E2E-5
    /// F3: a refusal is never repeated from the cached notice), then the attempt is refused, warned about, or started.
    func connect(_ profileID: ProfileItem.ID) { gatedStart(profileID, acceptingWarning: false) }

    /// "Connect Anyway" (§4.5 crashed-helper warning): re-checked like `connect`; only the warning is accepted.
    func connectAnyway(_ profileID: ProfileItem.ID) { gatedStart(profileID, acceptingWarning: true) }

    private func gatedStart(_ profileID: ProfileItem.ID, acceptingWarning: Bool) {
        guard let env else { return }
        guard env.legacy.helperMayBePresent else { env.auth.connect(profileID); return }
        Task { @MainActor in
            await env.legacy.refresh()
            if env.legacy.finding.blocksConnect {
                env.ui.connection.connectGate = .refused(profileID)
                return
            }
            if env.legacy.finding.warnsBeforeConnect && !acceptingWarning {
                env.ui.connection.connectGate = .warn(profileID)
                return
            }
            env.auth.connect(profileID)
        }
    }

    /// §6.8 "Remove locked profiles" (UI: the locked state reads `ProfilesStore.locked`). Confirmation is the UI's.
    func removeLockedProfiles() { with { env in Task { await env.profiles.removeLockedProfiles() } } }

    /// §6.8 "Re-import…" while locked: after the UI's confirmation ("Start over? The locked profiles are moved to a
    /// folder next to your profiles; LockPlus creates a new key"), move them aside, then show the import panel.
    func startOverAndReimport() {
        with { env in
            Task { @MainActor in
                do throws(LPError) {
                    try await env.profiles.startOverMovingLockedAside()
                    ImportPanel.run(env.ui)
                } catch {
                    env.ui.importer.errorMessage = error.code.message(detail: error.detail)
                }
            }
        }
    }

    /// §6.8 "Import from old LockPlus" while locked: the same confirmed start over as Re-import (no key is ever created
    /// over the locked files), then the existing migration UI, onboarding's profiles step, whose button runs
    /// `importMigration` with the offer `GoAppMigrator.detect` prepared.
    func startOverAndImportFromOldApp() {
        with { env in
            Task { @MainActor in
                do throws(LPError) {
                    try await env.profiles.startOverMovingLockedAside()
                    env.ui.onboarding.migrationReport = nil
                    env.ui.onboarding.step = .profiles
                    env.ui.onboarding.isPresented = true
                } catch {
                    env.ui.importer.errorMessage = error.code.message(detail: error.detail)
                }
            }
        }
    }

    /// "Open the old LockPlus" (§4.5 refusal strip).
    func openOldLockPlus() { env?.legacy.openOldApp() }

    /// E2E-5 F1: "Remove Old Helper…" (one administrator authentication; DESIGN §13.3a).
    func removeOldHelper() { with { env in Task { await env.legacy.removeHelper() } } }
    func dismissOldHelperRemoval() { env?.legacy.clearRemoval() }
    func trashOldWireGuidePlusApp() { with { env in Task { await env.legacy.trashOldApp() } } }

    /// The "What's inside" preview (§14.2): the same redacted files the export writes.
    func prepareDiagnosticsPreview() async -> [DiagnosticsPreviewFile] {
        guard let env else { return [] }
        return await env.prepareDiagnostics().map { DiagnosticsPreviewFile(name: $0.name, text: $0.text) }
    }

    func disconnect() {
        with { env in
            if let p = env.auth.prompt, p.profileID == env.connection.currentID { env.auth.cancelForDisconnect(p.promptID) }
            env.connection.disconnect()
        }
    }

    func perform(_ action: StateAction) {
        guard let env else { return }
        switch action {
        case .connect:
            if let id = env.connection.currentID ?? env.profiles.ordered.first?.id { env.ui.gatedConnect(id) }   // §4.5 gate
        case .disconnect, .disconnectAndRestoreInternet, .cancel:
            disconnect()
        case .enterCode, .signIn:
            // A user gesture: open the main window; its sheet shows the prompt (§8.4, never focus-stealing).
            openMainWindow()
            if env.auth.prompt == nil, let id = env.connection.currentID {
                switch action {
                case .signIn where env.connection.currentStatus.isActive:
                    // Rows 3b, 8: a held session with an auth error. A manual connect (which prompts as needed) needs
                    // the held one to end first (NE drops a start while it is still stopping).
                    Task { @MainActor in
                        await env.connection.disconnectAndWait(timeout: .seconds(22))
                        self.connect(id)
                    }
                case .signIn:
                    connect(id)                               // row 13a: a latched auth error
                default:
                    Task { await env.auth.pullPending(id) }   // Enter Code… (rows 3, 9): the running session's prompt
                }
            }
        case .pause:
            pause(minutes: 15)
        case .resumeNow:
            resume()
        case .details:
            openMainWindow()
        case .runDiagnostics:
            NavigationRequest.post(.diagnostics)
        case .openSystemSettings:
            env.extensionStore.openExtensionSettings()
        case .showSwitchAgain:
            // UI-L20 (UI worker's minimal edit): a fresh activation request makes macOS show the switch again,
            // then the pane opens; "Open System Settings" only opens the pane.
            installExtension()
            env.extensionStore.openExtensionSettings()
        case .restartMac:
            SystemRestart.request()         // UI-L19: row 1 "Restart your Mac to finish" (UI worker's minimal edit)
        case .approve:
            installExtension()
        case .reinstall:
            reinstallExtension()
        }
    }

    func pause(minutes: Int) { with { env in Task { await env.connection.pause(minutes: minutes) } } }
    func resume() { with { $0.connection.resume() } }

    /// Waits for `task`, at most `limit`.
    static func bounded(_ limit: Duration, _ task: Task<Void, Never>) async {
        final class Once { var done = false }
        let once = Once()
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await task.value
                if !once.done { once.done = true; k.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if !once.done { once.done = true; k.resume() }
            }
        }
    }

    // MARK: Auth (§6.5)

    func submitAuth(_ answer: AuthAnswer) { with { $0.auth.submit(answer) } }
    func cancelAuth(_ promptID: UUID) { with { $0.auth.cancel(promptID) } }
    func retryAuthApproval(_ promptID: UUID) { with { $0.auth.retryApproval(promptID) } }

    // MARK: Profiles

    func newProfile(_ kind: ProfileKindChoice) {
        AppActivation.becomeRegular()
        SceneBridge.requestEditor(.new(kind == .wireGuard ? .wireGuard : .openVPN))
    }

    /// RevealGate (A6): an existing profile's editor shows its keys, so LAContext first.
    func editConfig(_ profileID: ProfileItem.ID) {
        guard let env, let p = env.profiles.profile(profileID) else { return }
        Task { @MainActor in
            guard await env.hooks.authenticate(reason: String(localized: "edit the profile “\(p.name)”", comment: "LAContext reason")) else { return }
            AppActivation.becomeRegular()
            SceneBridge.requestEditor(.existing(profileID))
        }
    }

    func export(_ profileID: ProfileItem.ID) {
        guard let env, let p = env.profiles.profile(profileID) else { return }
        Task { @MainActor in
            guard await env.hooks.authenticate(reason: String(localized: "export the profile “\(p.name)”", comment: "LAContext reason")) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = p.name + (p.kind == .wireGuard ? ".conf" : ".ovpn")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do throws(LPError) {
                let payload = try await env.profiles.payload(profileID)
                do { try AtomicFile.writeUserFile(payload.withUnsafeBytes { Data($0) }, to: url) } catch {
                    env.ui.importer.errorMessage = Self.exportFailed(url)       // L1: never reported as success
                    return
                }
                env.ui.importer.exportResult = ExportResult(count: 1, folderName: url.deletingLastPathComponent().lastPathComponent,
                                                            folderURL: url.deletingLastPathComponent())
            } catch {
                env.ui.importer.errorMessage = error.code.message(detail: error.detail)
            }
        }
    }

    /// UI-CONCEPT §6.15: Export All is one zip (in memory, ZIPFoundation; 0600 / O_NOFOLLOW via `writeUserFile`).
    func exportAll() {
        guard let env, !env.profiles.profiles.isEmpty else { return }
        Task { @MainActor in
            guard await env.hooks.authenticate(reason: String(localized: "export all profiles", comment: "LAContext reason")) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = String(localized: "LockPlus Profiles", comment: "Export All zip file name") + ".zip"
            panel.allowedContentTypes = [.zip]
            AppActivation.becomeRegular()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            var entries: [(path: String, data: Data)] = [], failed: [String] = []
            for p in env.profiles.ordered {
                do throws(LPError) {
                    let payload = try await env.profiles.payload(p.id)
                    let path = Self.uniqueEntryName(Self.exportFileName(p.name), ext: p.kind == .wireGuard ? "conf" : "ovpn",
                                                    taken: entries.map(\.path))
                    entries.append((path, payload.withUnsafeBytes { Data($0) }))
                } catch { failed.append(p.name) }
            }
            if !failed.isEmpty {
                env.ui.importer.errorMessage = String(localized: "These profiles weren't exported: \(failed.joined(separator: ", ")).", comment: "Export error")
            }
            guard !entries.isEmpty else { return }
            do {
                let zipped = entries
                let data = try await Blocking.run { () -> Result<Data, CocoaError> in
                    do { return .success(try ProfileZipWriter.archive(zipped)) } catch { return .failure(CocoaError(.fileWriteUnknown)) }
                }.get()
                try AtomicFile.writeUserFile(data, to: url)
            } catch {
                env.ui.importer.errorMessage = Self.exportFailed(url)       // L1: never reported as success
                return
            }
            let dir = url.deletingLastPathComponent()
            env.ui.importer.exportResult = ExportResult(count: entries.count, folderName: dir.lastPathComponent, folderURL: dir)
        }
    }

    /// "Work.conf", then "Work 2.conf"…; compared case-insensitively, because Finder unpacks onto a case-insensitive volume.
    static func uniqueEntryName(_ base: String, ext: String, taken: [String]) -> String {
        let used = Set(taken.map { $0.lowercased() })
        var candidate = "\(base).\(ext)", n = 2
        while used.contains(candidate.lowercased()) { candidate = "\(base) \(n).\(ext)"; n += 1 }
        return candidate
    }

    /// ⌘D copies the payload, so it goes through the same gate as export (§11.4).
    func duplicate(_ profileID: ProfileItem.ID) {
        guard let env, let p = env.profiles.profile(profileID) else { return }
        Task { @MainActor in
            guard await env.hooks.authenticate(reason: String(localized: "duplicate the profile “\(p.name)”", comment: "LAContext reason")) else { return }
            do throws(LPError) {
                let payload = try await env.profiles.payload(profileID)
                let creds = await env.profiles.credentialRecord(profileID)
                let copy = try await env.profiles.create(ProfileDraft(
                    name: p.name, kind: p.kind, payload: payload, summary: p.summary, auth: p.auth, report: p.importReport ?? ImportReport(),
                    policy: p.policy, credentials: creds, engineVerified: p.engineVerified, origin: p.origin, notes: p.notes))
                env.ui.profiles.selection = copy.id
            } catch {
                env.ui.importer.errorMessage = error.code.message(detail: error.detail)
            }
        }
    }

    func delete(_ profileID: ProfileItem.ID) { with { env in Task { await env.profiles.delete(profileID) } } }

    func rename(_ profileID: ProfileItem.ID, to name: String) {
        with { env in
            Task { @MainActor in
                do throws(LPError) { try await env.profiles.rename(profileID, to: name) } catch {
                    env.ui.importer.errorMessage = String(localized: "That name can't be used. Choose another one.", comment: "Rename error")
                }
            }
        }
    }

    /// L-KS-2: policy toggles apply only while disconnected (the UI disables them while connected).
    private func updatePolicy(_ id: UUID, _ change: @escaping (inout NetworkPolicy) -> Void) {
        with { env in
            Task { @MainActor in
                do throws(LPError) { try await env.profiles.updatePolicy(id, change) } catch {
                    // Only the L-KS-2 guard means "disconnect first"; anything else is shown as what it is (H1).
                    env.ui.importer.errorMessage = error.detail == "mustBeDisconnected"
                        ? String(localized: "Disconnect first to change protection settings.", comment: "Policy change while connected")
                        : error.code.message(detail: error.detail)
                }
            }
        }
    }

    func setKillSwitch(_ on: Bool, for profileID: ProfileItem.ID) { updatePolicy(profileID) { $0.killSwitch = on } }
    func setAllowLocalNetwork(_ on: Bool, for profileID: ProfileItem.ID) { updatePolicy(profileID) { $0.allowLAN = on } }
    func setBlockIPv6(_ on: Bool, for profileID: ProfileItem.ID) { updatePolicy(profileID) { $0.blockIPv6WithoutKillSwitch = on } }

    func setNotes(_ notes: String, for profileID: ProfileItem.ID) {
        with { env in
            let clipped = String(notes.utf8.prefix(Profile.maxNotesBytes)) ?? ""
            Task { try? await env.profiles.updateMetadata(profileID) { $0.notes = clipped } }
        }
    }

    /// "Change…" (§6.4): the sheet returns username, password and "save in Keychain". Without saving, only the user
    /// name is kept and any saved password is removed (the next connect asks).
    func changePassword(_ profileID: ProfileItem.ID) {
        guard let env, let p = env.profiles.profile(profileID) else { return }
        let canSave = p.auth?.saveCredentials ?? true
        env.ui.profiles.passwordChange = PasswordChangeRequest(
            profileID: profileID, profileName: p.name, username: env.profiles.credentials[profileID]?.username ?? "",
            canSaveInKeychain: canSave,
            onSave: { [weak env] username, password, save in
                guard let env else { return }
                Task { @MainActor in
                    do throws(LPError) {
                        // L10: a failed read aborts instead of overwriting the passphrase/proxy credentials.
                        var rec = try await env.profiles.loadCredentials(profileID) ?? CredentialRecord()
                        rec.username = username.isEmpty ? nil : Data(username.utf8)
                        rec.password = save && canSave && !password.isEmpty ? Data(password.utf8) : nil
                        try await env.profiles.saveCredentials(profileID, rec)
                    } catch {
                        env.ui.importer.errorMessage = error.code.message(detail: error.detail)
                    }
                }
            })
    }

    func forgetPassword(_ profileID: ProfileItem.ID) { with { env in Task { await env.profiles.forgetPassword(profileID) } } }

    /// "Show" (RevealGate, §6.4/F-10): LAContext, then the capture-excluded sheet.
    func showPassword(_ profileID: ProfileItem.ID) {
        guard let env, let p = env.profiles.profile(profileID) else { return }
        Task { @MainActor in
            guard await env.hooks.authenticate(reason: String(localized: "show the password for “\(p.name)”", comment: "LAContext reason")),
                  let rec = await env.profiles.credentialRecord(profileID), let pw = rec.password else { return }
            env.ui.profiles.passwordReveal = PasswordReveal(profileName: p.name, username: rec.username.map { String(decoding: $0, as: UTF8.self) },
                                                            password: String(decoding: pw, as: UTF8.self))
        }
    }

    // MARK: Import (§6.8)

    func importFiles(_ urls: [URL]) { with { $0.importer.importFiles(urls) } }
    func importFromClipboard() { with { $0.importer.importFromClipboard() } }
    func confirmImport(_ preview: ImportPreview) { with { $0.importer.confirm(preview) } }
    func confirmBatch(_ batch: BatchImport) { with { $0.importer.confirm(batch) } }
    func cancelImport() { with { $0.importer.cancel() } }

    // MARK: Windows

    func openMainWindow() { SceneBridge.requestMainWindow() }
    func openSettings() { SceneBridge.requestSettings() }

    /// Quit from our own menu (§11.3): ask only when a tunnel is up or protection is paused.
    func quitFromMenu() {
        guard let env else { NSApp.terminate(nil); return }
        if env.connection.pausedUntil != nil {
            let a = NSAlert()
            a.messageText = String(localized: "Protection is paused", comment: "Quit alert")
            a.informativeText = String(localized: "Resume protection before quitting?", comment: "Quit alert")
            a.addButton(withTitle: String(localized: "Resume Protection and Quit", comment: "Button"))
            a.addButton(withTitle: String(localized: "Quit and Stay Paused", comment: "Button"))
            a.addButton(withTitle: String(localized: "Cancel", comment: "Button"))
            switch a.runModal() {
            case .alertFirstButtonReturn:
                // H4: quit only after protection is actually restored (bounded, so a hung NE call can't block quit).
                let restore = env.connection.resume()
                Task { @MainActor in
                    await Self.bounded(.seconds(10), restore)
                    NSApp.terminate(nil)
                }
            case .alertSecondButtonReturn: NSApp.terminate(nil)
            default: return
            }
            return
        }
        if env.connection.currentStatus.isActive {
            let a = NSAlert()
            a.messageText = String(localized: "The tunnel stays connected after quitting.", comment: "Quit alert")
            a.informativeText = String(localized: "Disconnect before quitting?", comment: "Quit alert")
            a.addButton(withTitle: String(localized: "Keep Connected", comment: "Button"))
            a.addButton(withTitle: String(localized: "Disconnect", comment: "Button"))
            a.addButton(withTitle: String(localized: "Cancel", comment: "Button"))
            switch a.runModal() {
            case .alertFirstButtonReturn: NSApp.terminate(nil)
            case .alertSecondButtonReturn:
                Task { @MainActor in
                    await env.connection.disconnectAndWait()      // H4: wait for .disconnected (≤ 5 s), then quit
                    NSApp.terminate(nil)
                }
            default: return
            }
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: System extension and configuration (§6.14)

    /// Onboarding Install/Try Again and "Approve…": ExtensionStore.retryAfterUserAction() (clears 4102 first).
    func installExtension() { with { env in Task { await env.extensionStore.retryAfterUserAction() } } }

    func reloadProfiles() { with { env in Task { await env.profiles.load() } } }

    /// "Reinstall…" (§4.6): LAContext, then ExtensionStore.reinstall().
    func reinstallExtension() {
        with { env in
            Task { @MainActor in
                guard await env.hooks.authenticate(reason: String(localized: "reinstall the tunnel component", comment: "LAContext reason")) else { return }
                do throws(LPError) { try await env.extensionStore.reinstall() } catch {
                    log.error("reinstall: \(error.code.rawValue, privacy: .public)")
                }
            }
        }
    }

    /// The first saveToPreferences triggers the system's "add VPN configurations" prompt (§11.1 step 3).
    func allowVPNConfiguration() {
        guard let env else { return }
        env.ui.onboarding.configurationStep = .requesting
        Task { @MainActor in
            // Review L5 (2.0.1): this is also the main window banner's "Allow…" action, and it runs after the system alert
            // however long that stays up: only onboarding's own step 3, still showing, moves on.
            let advance = { if env.ui.onboarding.isPresented, env.ui.onboarding.step == .allowConfiguration { env.ui.onboarding.step = .profiles } }
            guard let p = env.profiles.profiles.first else {
                // macOS asks at the first import instead: one click moves on (owner test 2026-11-10: it took two clicks
                // with nothing happening in between).
                env.ui.onboarding.configurationStep = .done
                advance()
                return
            }
            do throws(LPError) {
                // Review 4 #8: deferred while a start or session is under way (configurations exist then: allowed).
                // Review 5 #5: said as it is, not "done".
                if try await env.profiles.saveManagerUnlessBlocked(p) {
                    env.ui.onboarding.configurationStep = .done
                    // Review N2: allowed now, so the "VPN configurations not allowed" banner goes.
                    env.ui.connection.vpnConfigurationDenied = false
                    env.connection.configurationAllowed()
                    advance()                                         // allowed: on to the profiles, no second click
                } else {
                    env.ui.onboarding.configurationStep = .deferred(message: Self.deferredFirstSaveLine(p, busy: env.connection.busyReason, profiles: env.profiles))
                }
            } catch {
                env.ui.onboarding.configurationStep = .denied
                env.ui.connection.vpnConfigurationDenied = true
            }
        }
    }

    /// Onboarding step 3 while the first save waits (review 5; E2E-4 L1: another user's or an unaddressable session says so).
    static func deferredFirstSaveLine(_ p: Profile, busy: ConnectionStore.BusyReason?, profiles: ProfilesStore) -> String {
        switch busy {
        case .profile(let id)? where profiles.profile(id) != nil:
            let other = profiles.profile(id)?.name ?? ""
            return String(localized: "LockPlus adds the VPN configuration for \(p.name) when \(other) disconnects.",
                          comment: "Onboarding step 3: the first save waits for the running VPN (review 5); the second argument is a profile name")
        case .anotherUser?:
            return String(localized: "LockPlus adds the VPN configuration for \(p.name) when another user's VPN connection ends.",
                          comment: "Onboarding step 3: the first save waits for another user's VPN connection (E2E-4 L1)")
        case .unaddressable?:
            return String(localized: "LockPlus adds the VPN configuration for \(p.name) when the active VPN configuration LockPlus can't address disconnects.",
                          comment: "Onboarding step 3: the first save waits for a configuration LockPlus can't address (E2E-4 L1)")
        default:
            return String(localized: "LockPlus adds the VPN configuration for \(p.name) when the current VPN connection ends.",
                          comment: "Onboarding step 3: the first save waits for a VPN connection LockPlus doesn't own (review 5)")
        }
    }

    func finishOnboarding() {
        with { env in
            env.settings.update { $0.onboardingComplete = true }
            env.ui.onboarding.isPresented = false
            env.migrator.discardPlan()            // review M3: a skipped offer keeps no private keys
        }
    }

    func importMigration(_ names: Set<String>) { importMigration(names, includingSavedPasswords: false) }

    /// §6.7 opt-in ("Import saved OpenVPN passwords"; macOS asks once per item, announced by the UI first).
    /// Pre-release review M1: one run at a time; Import is disabled while `migrationRunning` (set before the Task, so
    /// a double-click can't start a second run).
    func importMigration(_ names: Set<String>, includingSavedPasswords: Bool) {
        with { env in
            let ob = env.ui.onboarding
            guard !ob.migrationRunning, !env.migrator.isRunning else { return }
            ob.migrationRunning = true
            Task { @MainActor in
                let report = await env.migrator.run(selected: names, includeSavedPasswords: includingSavedPasswords)
                ob.migrationRunning = false
                ob.migrationReport = report
                ob.migrationResumePending = false
                env.ui.activity.sessions = env.history.reversed().map(UIMapping.session)
            }
        }
    }

    /// E2E-5 F4: Settings › Advanced "Import from Old LockPlus…" (and the sheet the "finish" banner opens): the offer
    /// is looked for again every time, past a complete marker (deduped by digest).
    /// Pre-release review M1/M2: never while a migration runs (it would replace the running offer), and never while the
    /// profiles are locked (every create would fail; the locked view offers its own start-over import).
    func findOldLockPlusData() {
        guard let env else { return }
        let ob = env.ui.onboarding
        guard !ob.migrationChecking, !ob.migrationRunning, !env.migrator.isRunning, env.profiles.locked == nil else { return }
        ob.migrationChecking = true
        ob.migrationReport = nil
        Task { @MainActor in
            let offer = await env.migrator.detect(force: true)
            ob.migration = offer
            ob.migrationSelection = Set(offer?.profileNames ?? [])
            ob.migrationChecking = false
        }
    }

    /// Review M3: the sheet closed: the plan (the old profiles' private keys) isn't kept; an offer that stays for the
    /// "finish" banner reads the data again when it is imported.
    func closeMigration() {
        guard let env else { return }
        env.ui.onboarding.closeMigration()
        env.migrator.discardPlan()
    }

    /// The `/etc/wireguard` scan (port of scanner.go): readable `*.conf` files go through the normal import.
    func addEtcWireGuardProfiles() {
        with { env in
            let dir = URL(fileURLWithPath: "/etc/wireguard", isDirectory: true)
            let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "conf" && FileManager.default.isReadableFile(atPath: $0.path) }
            if urls.isEmpty {
                env.ui.importer.errorMessage = String(localized: "No readable profiles in /etc/wireguard.", comment: "Import error")
            } else {
                env.importer.importFiles(urls)
            }
        }
    }

    /// Onboarding's last step (§11.7): asks once, only while undecided; never again on its own.
    func requestNotificationPermission() {
        with { env in
            Task { @MainActor in
                guard await env.hooks.notificationAuthorization() == .notDetermined else { return }
                await env.hooks.requestNotificationPermission()
                env.ui.settings.notificationsDeniedBySystem = await env.hooks.notificationsDenied()
            }
        }
    }

    // MARK: Settings

    func setLaunchAtLogin(_ on: Bool) {
        with { env in
            env.ui.settings.launchAtLogin = env.hooks.setLaunchAtLogin(on)
            if env.ui.settings.launchAtLogin != .disabled { env.ui.settings.launchAtLoginOffer = false }   // answered
        }
    }

    func settingsDidAppear() {
        with { env in
            env.ui.settings.launchAtLogin = env.hooks.loginItemState()
            env.ui.settings.clipboardDenied = NSPasteboard.general.accessBehavior == .alwaysDeny
            Task { @MainActor in env.ui.settings.notificationsDeniedBySystem = await env.hooks.notificationsDenied() }
        }
    }

    func showInMenuBar() { with { $0.ui.settings.showInMenuBar = true } }
    /// "Check for Updates…" and the gentle reminder's "Update Available…" (§12.1): user-initiated only.
    func checkForUpdates() { with { $0.updater.checkForUpdates() } }

    /// §4.4. A cancelled administrator dialog leaves the component installed (`.componentStillInstalled`).
    func uninstall() { uninstall(deletingProfilesAndHistory: false) }

    func uninstall(deletingProfilesAndHistory: Bool) {
        guard let env else { return }
        Task { @MainActor in
            guard await env.hooks.authenticate(reason: String(localized: "uninstall LockPlus", comment: "LAContext reason")) else { return }
            await Uninstaller(env: env, deleteProfilesAndHistory: deletingProfilesAndHistory).run()
        }
    }

    // MARK: Diagnostics, logs, activity

    func runDiagnostics() { with { env in Task { await env.runDiagnostics() } } }
    func reloadRoutes() { with { env in Task { await env.reloadRoutes() } } }

    /// §14.2 "Export diagnostics…" (Help menu now; Settings › Advanced with the "What's inside" preview is UI work).
    func exportDiagnostics() { env?.exportDiagnostics() }

    func copyLogs() {
        guard let env else { return }
        let text = env.ui.logs.entries.map { "\($0.date.ISO8601Format()) \($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func saveLogs() {
        guard let env else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LockPlus Log.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = env.ui.logs.entries.map { "\($0.date.ISO8601Format()) \($0.message)" }.joined(separator: "\n")
        do { try AtomicFile.writeUserFile(Data(text.utf8), to: url) } catch { env.ui.importer.errorMessage = Self.exportFailed(url) }
    }

    /// A file name for an exported profile: the import sanitizer's rules, no path separators, never hidden.
    static func exportFileName(_ name: String) -> String {
        var s = ProfileNameSanitizer.sanitize(name).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "Profile" : s
    }

    static func exportFailed(_ url: URL) -> String {
        String(localized: "“\(url.lastPathComponent)” couldn't be saved. Check the folder's permissions and free space.", comment: "Export error")
    }

    func clearLogs() { with { $0.logs.clear() } }

    func clearHistory() {
        with { env in
            Task { @MainActor in
                await env.clearHistory()
                env.ui.activity.sessions = []
            }
        }
    }

    func showLogs(around date: Date) { NavigationRequest.post(.logs) }

    // MARK: Auto-Connect (§6.7)

    /// "Add Current Network" (§10.4): authorized → add the SSID at once; undecided → the system prompt (the UI shows
    /// its pre-prompt sheet first and then calls this or `requestLocationAccess`); denied/restricted → nothing (the
    /// UI shows the matching caption).
    func addCurrentNetwork() { with { env in Task { await env.addCurrentNetwork() } } }

    func requestLocationAccess() {
        with { env in
            Task { @MainActor in
                env.ui.autoConnect.location = await env.wifi.requestAuthorization()
                env.ui.autoConnect.currentSSID = env.wifi.currentSSID()
            }
        }
    }
}

/// §4.4 in-app uninstall (reviews H5, L3, Fable H1). Steps 2–4 and 6 first; nothing local is deleted and the app
/// isn't trashed unless the tunnel component was really deactivated. The data-protection keychain (master key and
/// saved passwords) goes only TOGETHER with the profile files (step 7 = Yes): keeping profiles keeps the key that
/// opens them, so a reinstall finds them intact.
@MainActor struct Uninstaller {
    let env: AppEnvironment
    var deleteProfilesAndHistory = false

    /// What stayed behind, for the final sheet (§4.4 step 3 residual).
    struct Residuals: Equatable {
        var secrets = false
        var vpnConfigurations = 0
        var localData = false
    }

    @discardableResult
    func run() async -> Residuals {
        let ui = env.ui.settings
        ui.uninstallPhase = .uninstalling
        var residual = Residuals()
        let ids = env.managers.managers.map(\.profileID)
        // 2. on-demand off, stop, wait for .disconnected (10 s)
        for id in ids {
            try? await env.managers.setOnDemandEnabled(false, for: id)
            env.managers.stop(id)
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, ids.contains(where: { env.managers.status($0) != .disconnected && env.managers.status($0) != .invalid }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        // 3. the extension deletes this uid's secrets; a failure is a residual the final sheet names
        do throws(LPError) { try await env.service.callVoid(.wipeAllSecrets, EmptyRequest()) } catch { residual.secrets = true }
        // 4. NE configurations (failures counted, not swallowed)
        for id in ids {
            do throws(LPError) { try await env.managers.remove(id) } catch { residual.vpnConfigurations += 1 }
        }
        // 6. deactivation (asks for an administrator password on 27). Any failure stops here: nothing local is
        //    deleted and the app stays, so the user can try again.
        do throws(LPError) {
            try await env.extensionStore.deactivate()
        } catch {
            ui.uninstallPhase = .componentStillInstalled
            if residual != Residuals() { await env.hooks.showUninstallResidual(Self.message(residual)) }
            return residual
        }
        // 7. only with "Also delete your profiles and history": the DP keychain (saved passwords, then the master key)
        //    together with the app data directory. The Go app's data is never touched (§13.1).
        if deleteProfilesAndHistory {
            for id in (try? await env.profiles.credentialStore.ids()) ?? [] {
                do throws(KeychainError) { try await env.profiles.credentialStore.delete(id) } catch { residual.localData = true }
            }
            do throws(KeychainError) {
                try await env.profiles.credentialStore.items.delete(service: KeychainServices.payloadKey, account: "v1")
            } catch { residual.localData = true }
            await env.deleteAppData()
        }
        if residual != Residuals() { await env.hooks.showUninstallResidual(Self.message(residual)) }
        // 8–9: login item and resume agent unregistered, app to the Trash, quit
        await env.connection.resumeAgent.unregister()
        await env.hooks.finishUninstall()
        return residual
    }

    static func message(_ r: Residuals) -> String {
        var parts: [String] = []
        if r.secrets {
            parts.append(String(localized: "Some tunnel secrets could not be removed. Reinstall LockPlus and run Uninstall again, or remove the System keychain items labelled “LockPlus tunnel secret” in Keychain Access (administrator password required).", comment: "§4.4 residual"))
        }
        if r.vpnConfigurations > 0 {
            parts.append(String(localized: "Some VPN configurations could not be removed. Remove the LockPlus entries in System Settings › VPN.", comment: "§4.4 residual"))
        }
        if r.localData {
            parts.append(String(localized: "Some saved passwords could not be removed from your keychain.", comment: "§4.4 residual"))
        }
        return parts.joined(separator: "\n\n")
    }
}
