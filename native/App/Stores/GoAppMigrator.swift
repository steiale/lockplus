import CryptoKit
import Foundation
import LPModel
import LPParsing
import LPRouteProbe
import LPWire

/// `GoAppMigrator` (DESIGN §13.1): copy-only. Reads the Go app's data with LPParsing's `GoMigrationReader`
/// (O_NOFOLLOW, regular files only), creates profiles through the normal pipeline, maps settings, Wi-Fi rules and
/// history, and writes `migration.json`. Nothing in the Go directories is ever written, moved or deleted.
///
/// Legacy keychain credentials (§6.7) are opt-in (`includeSavedPasswords`): the listing is attributes-only (no
/// prompt) and gives the offer's count; each data read may show one system prompt, announced up front by the UI.
/// Legacy items are never written or deleted.
@MainActor final class GoAppMigrator {
    private let source: @Sendable () -> (any GoAppDataSource)?
    private let profiles: ProfilesStore
    private let settings: SettingsStore
    private let files: SettingsFileStore?
    private let service: any TunnelServicing
    private let probe: any EndpointRouteProbing
    private let keychain: (any LegacyKeychainReading)?
    /// Migration matrix: upstream WireGuide's `…/wireguide` has tunnels (never imported automatically; the report says how).
    var upstreamWireGuide: @Sendable () -> Bool = { false }
    private(set) var plan: GoMigrationPlan?
    /// Attributes-only listing from `detect` (no prompt).
    private(set) var legacyListing = LegacyKeychainListing()
    var history: (([HistoryEntry]) async -> Void)?
    /// E2E-5 F2: the migration changed the Auto-Connect rules. The app runs the same on-demand re-save a UI change
    /// does (`UIBinder.requestOnDemandResave`: one pass at a time, through `ProfilesStore.resaveOnDemand`, whose
    /// mutation rules defer a profile that is busy), so the NE configuration gets `OnDemandEnabled`.
    var onAutoConnectChanged: (@MainActor () -> Void)?
    /// E2E-5 F5: the old app's launch at login. `retireGoAgent` removes LockPlus 1.0.x's LaunchAgent (true: it existed);
    /// `nativeEnabled` is LockPlus's own login item state.
    struct LaunchAtLoginHooks {
        var retireGoAgent: @MainActor () -> Bool = { false }
        var nativeEnabled: @MainActor () -> Bool = { false }
    }
    var launchAtLogin = LaunchAtLoginHooks()
    /// Pre-release review M1: one run at a time (a second Import while the first waits on keychain prompts created
    /// every profile twice). The UI disables Import and the Settings re-scan while it is set.
    private(set) var isRunning = false

    init(source: @escaping @Sendable () -> (any GoAppDataSource)?, profiles: ProfilesStore, settings: SettingsStore,
         files: SettingsFileStore?, service: any TunnelServicing, probe: any EndpointRouteProbing = RouteProbe(),
         keychain: (any LegacyKeychainReading)? = nil) {
        self.source = source
        self.profiles = profiles
        self.settings = settings
        self.files = files
        self.service = service
        self.probe = probe
        self.keychain = keychain
    }

    /// The real Go directories: `~/Library/Application Support/lockplus` (or `wireguide-plus`).
    nonisolated static let liveSource: @Sendable () -> (any GoAppDataSource)? = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return GoAppDirectory.locate(applicationSupport: base)
    }

    nonisolated static let liveUpstreamWireGuide: @Sendable () -> Bool = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return GoAppDirectory.upstreamWireGuideHasTunnels(applicationSupport: base)
    }

    /// E2E-6 N5: Go 1.2.0's `farewell.json` (`{"choice":"moved",...}`) says the old app removed its login item. Any read
    /// or parse problem, a missing file or another choice is "unknown" (false).
    private func goAppMoved() -> Bool {
        guard let bytes = try? source()?.readDataFile("farewell.json", maxBytes: 4096) else { return false }
        return Self.farewellMoved(bytes)
    }

    nonisolated static func farewellMoved(_ bytes: [UInt8]) -> Bool {
        struct Farewell: Decodable { var choice: String }
        guard let f = try? JSONDecoder().decode(Farewell.self, from: Data(bytes)) else { return false }
        return f.choice == "moved"
    }

    /// Offers the migration (§13.1 step 9): automatically only while no COMPLETE marker exists; `force` (Settings ›
    /// Advanced, the locked view) also after one, deduped by digest. E2E-5 F4: an earlier run that didn't finish (an
    /// incomplete marker, or its profiles without any marker) is offered as "finish": the profiles that are missing,
    /// then the settings, Wi-Fi rules, history and saved sign-ins that never arrived.
    ///
    /// Pre-release review M3: the plan (it holds the old profiles' private keys) is kept only while an offer is shown;
    /// a discarded offer calls `discardPlan`, and `run` reads the data again if it has to.
    func detect(force: Bool = false) async -> OnboardingUIModel.MigrationOffer? {
        guard !isRunning else { return nil }
        return await scan(force: force)
    }

    private func scan(force: Bool) async -> OnboardingUIModel.MigrationOffer? {
        let marker = await files?.loadMigrationMarker()
        if !force, marker?.complete == true { return nil }
        let existing = Set(profiles.profiles.map(\.payloadDigest))
        let src = source
        let read: GoMigrationPlan? = await Blocking.run {
            guard let s = src() else { return nil }
            return try? GoMigrationReader.read(s, existingDigests: existing, digest: PayloadDigest.sha256Hex)
        }
        guard let read, !read.tunnels.isEmpty else { return nil }
        let usable = read.tunnels.filter { $0.verdict != .rejected }
        // Review LOW (resume): a profile an earlier run created is "imported" even after the user edited it (its digest
        // changed): matched by the marker's item, so it isn't offered (and created) twice.
        let names = usable.filter { !$0.alreadyImported && earlierProfile($0.oldName, in: marker) == nil }.map(\.displayName)
        let resumes = Self.resumes(marker, read)
        guard !names.isEmpty || resumes else { return nil }
        plan = read
        legacyListing = await keychain?.list() ?? LegacyKeychainListing()
        let ovpn = Set(usable.filter { $0.kind == .openVPN && (resumes || !$0.alreadyImported) }.map(\.oldName))
        let saved = Set(legacyListing.items.map(\.account)).intersection(ovpn).count
        return OnboardingUIModel.MigrationOffer(profileNames: names, savedPasswords: saved, finishesEarlierImport: resumes)
    }

    /// Review M3: an offer was closed or never shown: the old profiles' payloads (private keys) aren't kept.
    func discardPlan() {
        guard !isRunning else { return }
        plan = nil
        legacyListing = LegacyKeychainListing()
    }

    /// Review M3: whether migration.json records an import that didn't finish (no Go data is read for this).
    func hasUnfinishedMigration() async -> Bool {
        await files?.loadMigrationMarker().map { !$0.complete } ?? false
    }

    /// An earlier migration didn't finish: only an incomplete marker says so. `run()` writes one before it creates
    /// anything (review E2E-5 F4-1: matching profiles without a marker were imported by hand, not an interrupted run).
    static func resumes(_ marker: MigrationMarker?, _ plan: GoMigrationPlan) -> Bool {
        marker.map { !$0.complete } ?? false
    }

    /// Imports the chosen tunnels and applies the Go settings. Returns the report the onboarding sheet shows.
    /// E2E-5 F4: resumable. migration.json is written after every profile and step (`complete == false`) and marked
    /// complete at the end; a resumed run maps the profiles an earlier run created (by marker item or payload digest),
    /// so auto-connect, trusted networks, history and saved sign-ins reach them. A manual re-run after a COMPLETE
    /// migration imports profiles only: settings the user changed since aren't overwritten.
    ///
    /// Review M2: settings, Wi-Fi rules and history are applied, and the marker completed, only by a run in which no
    /// profile failed to be created (profiles locked, a save that failed); otherwise the marker stays incomplete and
    /// "Finish Import" retries the profiles, then applies them.
    func run(selected names: Set<String>, includeSavedPasswords: Bool = false) async -> OnboardingUIModel.MigrationReport {
        guard !isRunning else { return .init(imported: [], needsAttention: [], notMigrated: []) }
        isRunning = true
        defer { isRunning = false }
        // Review M3: the offer outlived its plan (a cancelled sheet, the "finish" banner): read the data again.
        if plan == nil { _ = await scan(force: true) }
        guard var plan else { return .init(imported: [], needsAttention: [], notMigrated: []) }
        plan = await GoMigrationReader.probeRoutes(plan, probe: probe)
        let earlierMarker = await files?.loadMigrationMarker()
        let resuming = Self.resumes(earlierMarker, plan)
        let applyGlobal = earlierMarker?.complete != true
        var marker = earlierMarker ?? MigrationMarker(completedAt: Date(), source: Self.homeRelative(plan.source), items: [])
        // Review E2E-5 F4-1: the incomplete marker exists before the first profile is created, so a kill at any point is
        // resumed. A re-run after a complete migration stays complete (a kill then leaves nothing to "finish").
        marker.complete = !applyGlobal
        await progress(&marker)
        var imported: [String] = [], attention: [String] = [], notMigrated: [String] = [], notes: [String] = [], info: [String] = []
        var idByOldName: [String: UUID] = [:]
        if applyGlobal {
            for i in marker.items { if let id = i.newID, profiles.profile(id) != nil { idByOldName[i.oldName] = id } }
        }
        var created: [String: UUID] = [:]
        var failed = 0
        for t in plan.tunnels {
            let earlierID = earlierProfile(t.oldName, in: marker)
            if t.alreadyImported || earlierID != nil {
                // The profile exists (an earlier run, possibly edited since, or imported by hand): map it so settings,
                // history and sign-ins reach it. Never imported twice.
                if applyGlobal, idByOldName[t.oldName] == nil, let id = earlierID ?? existingProfile(for: t) {
                    idByOldName[t.oldName] = id
                    marker.record(.init(oldName: t.oldName, newID: id, digest: profiles.profile(id)?.payloadDigest, result: "alreadyImported"))
                } else if names.contains(t.displayName), !marker.items.contains(where: { $0.oldName == t.oldName }) {
                    marker.record(.init(oldName: t.oldName, newID: nil, digest: nil, result: "alreadyImported"))
                }
                continue
            }
            guard names.contains(t.displayName) else { continue }
            guard let draft = await draft(t) else {
                notMigrated.append(t.displayName)
                marker.record(.init(oldName: t.oldName, newID: nil, digest: nil, result: "rejected"))
                continue
            }
            do throws(LPError) {
                let p = try await profiles.create(draft)
                idByOldName[t.oldName] = p.id
                created[t.oldName] = p.id
                // E2E-5 F6: "Needs attention" only for something that changes behaviour, with the reason; lines that
                // were harmless to drop (`nobind`, `verb`, …) and migration notes are listed as information.
                let c = Self.classify(draft.report, engineVerified: draft.engineVerified, name: p.name)
                if let concern = c.concern { attention.append(concern) } else { imported.append(p.name) }
                info += c.info
                // Review LOW (resume): a retried tunnel replaces its earlier "error:…" item instead of adding a second.
                marker.record(.init(oldName: t.oldName, newID: p.id, digest: p.payloadDigest,
                                    result: draft.engineVerified ? "imported" : "notYetVerified"))
            } catch {
                notMigrated.append(t.displayName)
                failed += 1
                marker.record(.init(oldName: t.oldName, newID: nil, digest: nil, result: "error:\(error.code.rawValue)"))
            }
            await progress(&marker)
        }
        // Migration matrix: passwords LockPlus 1.0.65 and older kept in the System keychain are named in the report,
        // with or without the opt-in (that offer counts only the login keychain's).
        notMigrated += systemKeychainLines(idByOldName: applyGlobal ? idByOldName : created)
        if includeSavedPasswords {
            // Review LOW (resume): once the step ran, a resumed run still reads the saved sign-ins of the profiles it
            // creates now (never again those of the earlier run: no second prompt for an item already read or denied).
            let targets = marker.did(.credentials) ? created : (applyGlobal ? idByOldName : created)
            if !targets.isEmpty || !marker.did(.credentials) {
                let r = await importSavedPasswords(idByOldName: targets)
                attention += r.attention
                notMigrated += r.notMigrated
                info += r.info
            }
            if !marker.did(.credentials) { marker.steps.append(MigrationMarker.Step.credentials.rawValue) }
            await progress(&marker)
        }
        // Review M2: a profile that failed (locked profiles, a failed save) would never receive the settings, Wi-Fi
        // rules and history: they wait for the run that creates it ("Finish Import").
        let finishing = applyGlobal && failed == 0
        if finishing && !marker.did(.settings) {
            applySettings(plan, idByOldName: idByOldName, fillOnly: resuming)
            marker.steps.append(MigrationMarker.Step.settings.rawValue)
            await progress(&marker)
        }
        if finishing && !marker.did(.history) {
            // Review LOW (resume): stable entry IDs, so a kill before the marker is saved can't duplicate the history.
            await history?(Self.history(plan.history, idByOldName: idByOldName))
            marker.steps.append(MigrationMarker.Step.history.rawValue)
            await progress(&marker)
        }
        // E2E-5 F5: the old app opened at login (1.0.x: a LaunchAgent that now starts this binary; 1.1: a login item).
        let agentRetired = launchAtLogin.retireGoAgent()
        let offerLogin = applyGlobal && (plan.settings.offerLaunchAtLogin || agentRetired) && !launchAtLogin.nativeEnabled()
        // E2E-6 N5: LockPlus 1.2.0's "Move to LockPlus 2" already unregistered the 1.1.0 login item and recorded
        // `farewell.json` "moved". Only when 2.0 can't know the item is gone does the note say it may still be listed.
        if applyGlobal && plan.settings.offerLaunchAtLogin && !agentRetired && !goAppMoved() {
            notes.append(String(localized: "System Settings › General › Login Items may still list the old LockPlus. Turn it off there; LockPlus has its own setting.",
                                comment: "Migration report: Go 1.1's login item can't be removed by LockPlus (E2E-5 F5)"))
        }
        if upstreamWireGuide() {
            notes.append(String(localized: "WireGuide's profiles (the separate app) are on this Mac too. LockPlus doesn't import them on its own: choose Import Profile… and pick them in ~/Library/Application Support/wireguide/tunnels.",
                                comment: "Migration report: upstream WireGuide's directory is never imported automatically (migration matrix)"))
        }
        if applyGlobal && !finishing {
            notes.append(String(localized: "Not every profile could be imported, so settings, Wi-Fi rules and history weren't imported yet. Choose Finish Import to try again.",
                                comment: "Migration report: a profile failed; the global steps wait for the retry (pre-release review M2)"))
            marker.completedAt = Date()
            await files?.save(marker: marker)
        } else {
            if applyGlobal { notes += Self.globalNotes(plan) }
            if resuming {
                notes.append(String(localized: "The earlier import was finished: settings, Wi-Fi rules and history are now in LockPlus too.",
                                    comment: "Migration report: a resumed migration (E2E-5 F4)"))
            }
            marker.complete = true
            marker.steps = []   // a finished migration needs no step list
            marker.completedAt = Date()
            await files?.save(marker: marker)
        }
        self.plan = nil
        legacyListing = LegacyKeychainListing()
        return .init(imported: imported, needsAttention: attention, notMigrated: notMigrated, info: info, notes: notes,
                     offerLaunchAtLogin: offerLogin)
    }

    // Harmless vs behaviour-changing ignored lines: `ImportReportItem.isHarmlessIgnored` / `isNotApplied` (LPModel), shared
    // with the import sheet and the profile detail. Scripts, web sign-in, `verify-hash` and WireGuard settings that aren't
    // applied DO change behaviour and stay under "Needs attention".

    /// One migrated profile's report lines: the first concern (with how many more), or information only.
    static func classify(_ report: ImportReport, engineVerified: Bool, name: String) -> (concern: String?, info: [String]) {
        let concerns = report.items.filter { $0.group == .securityWarning || $0.isNotApplied }
        var concern: String?
        if let first = concerns.first {
            let more = concerns.count - 1
            concern = more > 0
                ? String(localized: "\(name): \(first.lineAnnotated(profileName: name)) (and \(more) more in the profile's import report)",
                         comment: "Migration report, needs attention: profile name, the first reason, the number of further reasons (E2E-5 F6)")
                : String(localized: "\(name): \(first.lineAnnotated(profileName: name))", comment: "Migration report, needs attention: profile name and reason (E2E-5 F6)")
        } else if !engineVerified {
            concern = String(localized: "\(name): \(ProfileItem.notYetVerifiedExplanation)", comment: "Migration report, needs attention: not yet verified (E2E-5 F6)")
        }
        var info: [String] = []
        let harmless = report.items.filter(\.isHarmlessIgnored).compactMap(\.directive)
        if !harmless.isEmpty {
            var seen = Set<String>()
            let list = harmless.filter { seen.insert($0).inserted }.joined(separator: ", ")
            info.append(String(localized: "\(name): \(list) ignored; LockPlus doesn't need these lines.", comment: "Migration report, information: harmless ignored directives (E2E-5 F6)"))
        }
        for n in report.items where n.group == .note {
            if let text = migrationNoteText(n.reason) { info.append(String(localized: "\(name): \(text)", comment: "Migration report, information: profile name and a migration note (E2E-5 F6)")) }
        }
        return (concern, info)
    }

    /// The whole-app notes of §13.1 (per-network choices with the map itself, DNS).
    static func globalNotes(_ plan: GoMigrationPlan) -> [String] {
        var out: [String] = []
        for n in plan.notes {
            guard let text = migrationNoteText(n.reason) else { continue }
            if n.reason == .migrationPerNetworkProfilesNotSupported, !plan.wifi.perNetworkProfiles.isEmpty {
                let map = plan.wifi.perNetworkProfiles.map { "\($0.ssid) → \(ProfileNameSanitizer.sanitize($0.tunnelName))" }.joined(separator: ", ")
                out.append(String(localized: "\(text) The old LockPlus used: \(map). Auto-Connect uses one profile for every untrusted network.",
                                  comment: "Migration report: the per-network map that isn't migrated (E2E-5 F6); the second argument lists network → profile"))
            } else {
                out.append(text)
            }
        }
        return out
    }

    /// The localized text of the migration's own report reasons (§13.1); nil for any other reason.
    static func migrationNoteText(_ r: ImportReason) -> String? {
        switch r {
        case .migrationPerNetworkProfilesNotSupported:
            String(localized: "Per-network profile choices aren't supported yet.", comment: "Migration report note (§13.1 step 7)")
        case .migrationDNSAlwaysTunnelled:
            String(localized: "DNS now always goes through the tunnel; the old app's DNS protection setting isn't needed.", comment: "Migration report note (§13.1 step 4)")
        case .migrationAutoReconnectReplaced:
            String(localized: "Auto-reconnect is now built in.", comment: "Migration report note per profile (§13.1 step 4)")
        case .migrationSavedPasswordInSystemKeychain:
            String(localized: "A saved password from an older version can't be imported; enter it again on first connect.", comment: "Migration report note (§6.7)")
        default:
            nil
        }
    }

    /// One step done: migration.json says so before the next one starts (E2E-5 F4).
    private func progress(_ marker: inout MigrationMarker) async {
        marker.completedAt = Date()
        await files?.save(marker: marker)
    }

    /// The profile an earlier run created from this tunnel (its marker item), if it still exists: matched by ID, so a
    /// profile edited since (another digest) isn't imported again.
    private func earlierProfile(_ oldName: String, in marker: MigrationMarker?) -> UUID? {
        marker?.items.lazy.compactMap { $0.oldName == oldName ? $0.newID : nil }.first { self.profiles.profile($0) != nil }
    }

    /// The existing profile an earlier run (or a manual import) created from this tunnel's payload.
    private func existingProfile(for t: MigratedTunnel) -> UUID? {
        guard let payload = t.canonicalPayload else { return nil }
        let digest = PayloadDigest.sha256Hex(payload)
        return profiles.profiles.first { $0.payloadDigest == digest }?.id
    }

    /// §6.7 read path, steps 3–4: one data read per item (current service name first), decoded with
    /// `LegacyKeychainDecoder`, saved with `CredentialStore` and provisioned. Only OpenVPN profiles created by this
    /// run receive a password; a profile whose new import already carries credentials keeps them.
    /// E2E-5 F7: Go 1.x's "Save username" stores an item with the username only; importing it fills in the username
    /// and the report says the password is still asked on connect (`info`).
    func importSavedPasswords(idByOldName: [String: UUID]) async -> (attention: [String], notMigrated: [String], info: [String]) {
        var attention: [String] = [], notMigrated: [String] = [], info: [String] = []
        guard let keychain else { return ([], [], []) }
        var seen = Set<String>()
        for item in legacyListing.items.sorted(by: { LegacyKeychain.serviceNames.firstIndex(of: $0.service) ?? 9 < LegacyKeychain.serviceNames.firstIndex(of: $1.service) ?? 9 }) {
            guard !seen.contains(item.account), let id = idByOldName[item.account], let p = profiles.profile(id), p.kind == .openVPN else { continue }
            seen.insert(item.account)
            if let existing = await profiles.credentialRecord(id), existing.password != nil { continue }
            switch await keychain.read(item) {
            case .success(var raw):
                defer { raw.withUnsafeMutableBytes { if let b = $0.baseAddress { _ = memset_s(b, $0.count, 0, $0.count) } } }
                guard case .success(let d) = LegacyKeychainDecoder.decode(raw) else {
                    attention.append(String(localized: "The saved password for \(p.name) couldn't be read. Enter it on first connect.", comment: "Migration report"))
                    continue
                }
                let password = d.basePassword.flatMap { $0.count > 0 ? Data($0.copyBytes()) : nil }
                let rec = CredentialRecord(username: Data(d.username.copyBytes()), password: password)
                do throws(LPError) {
                    try await profiles.saveCredentials(id, rec)
                    if password == nil {
                        info.append(String(localized: "\(p.name): the saved username was imported; the old LockPlus kept no password, so LockPlus asks for it on connect.",
                                           comment: "Migration report: a Go item with the username only (E2E-5 F7)"))
                    }
                } catch {
                    attention.append(String(localized: "The saved password for \(p.name) couldn't be stored. Enter it on first connect.", comment: "Migration report"))
                }
            case .failure(.denied):
                attention.append(String(localized: "Access to the saved password for \(p.name) was denied. Enter it on first connect.", comment: "Migration report"))
            case .failure:
                attention.append(String(localized: "The saved password for \(p.name) couldn't be read. Enter it on first connect.", comment: "Migration report"))
            }
        }
        return (attention, notMigrated, info)
    }

    /// System keychain items (LockPlus 1.0.65 and older): one line per OpenVPN profile of this run, by name; the rest
    /// counted (§6.7 step 4, migration matrix).
    func systemKeychainLines(idByOldName: [String: UUID]) -> [String] {
        guard legacyListing.systemKeychainItems > 0 else { return [] }
        var out: [String] = [], named = Set<String>()
        for account in legacyListing.systemAccounts where !named.contains(account) {
            guard let id = idByOldName[account], let p = profiles.profile(id), p.kind == .openVPN else { continue }
            named.insert(account)
            out.append(String(localized: "\(p.name): the old LockPlus kept this password in the System keychain, which LockPlus can't read. Enter it again on first connect.",
                              comment: "Migration report: a System keychain item of LockPlus 1.0.65 and older (migration matrix)"))
        }
        let rest = legacyListing.systemKeychainItems - legacyListing.systemAccounts.filter { named.contains($0) }.count
        if rest > 0 {
            // Inflection needs AttributedString: `String(localized:)` would show the raw ^[…](inflect: true) markup.
            out.append(String(AttributedString(localized: "^[\(rest) saved password](inflect: true) from an older version can't be imported; enter it again on first connect.",
                                               comment: "Migration report (System keychain items, §6.7 step 4)").characters))
        }
        return out
    }

    private func draft(_ t: MigratedTunnel) async -> ProfileDraft? {
        var report = t.report
        for n in t.migrationNotes { report.items.append(n) }
        switch t.result {
        case .wireGuard(let r):
            guard let text = r.canonicalText, r.verdict != .rejected else { return nil }
            let policy = t.policy        // kill switch: includeAllNetworks if full, route protection if split (§10.1)
            return ProfileDraft(name: t.displayName, kind: .wireGuard, payload: SecretBytes(copying: Array(text.utf8)),
                                summary: r.summary, auth: nil, report: report, policy: policy, credentials: nil,
                                engineVerified: true, origin: .migratedGo(t.oldName), notes: t.notes)
        case .openVPN(let r0):
            guard r0.verdict != .rejected else { return nil }
            let r = await OVPNImporter.validateWithEngine(r0, validator: XPCProfileValidator(service: service))
            guard let text = r.canonicalText, r.verdict != .rejected else { return nil }
            let c = r.credentials
            let rec: CredentialRecord? = c.isEmpty ? nil : CredentialRecord(
                username: c.username.map { Data($0.copyBytes()) }, password: c.password.map { Data($0.copyBytes()) },
                proxyUsername: c.proxyUsername.map { Data($0.copyBytes()) }, proxyPassword: c.proxyPassword.map { Data($0.copyBytes()) })
            return ProfileDraft(name: t.displayName, kind: .openVPN, payload: SecretBytes(copying: Array(text.utf8)),
                                summary: r.summary, auth: r.auth, report: r.report.items.isEmpty ? report : mergeReports(report, r.report),
                                policy: t.policy, credentials: rec, engineVerified: r.engineValidation == .passed,
                                origin: .migratedGo(t.oldName), notes: t.notes)
        }
    }

    private func mergeReports(_ a: ImportReport, _ b: ImportReport) -> ImportReport {
        var out = b
        for i in a.items where !out.items.contains(i) { out.items.append(i) }
        return out
    }

    /// §13.1 steps 6–7.
    /// `fillOnly` (a resumed migration, review E2E-5 F4-1): adds what's missing and overwrites nothing the user may
    /// have set since: trusted networks are merged, the auto profile is set only when none is chosen; language, appearance, log
    /// level and icon style are taken from the old app only while they still have LockPlus's default (pre-release
    /// review LOW: a kill before this step used to drop them).
    private func applySettings(_ plan: GoMigrationPlan, idByOldName: [String: UUID], fillOnly: Bool = false) {
        let s = plan.settings, w = plan.wifi
        let before = settings.value.autoConnect
        settings.update {
            $0.supportNoteShown = $0.supportNoteShown || s.supportNoteShown
            $0.autoConnect.trustedSSIDs = AutoConnectRules.sanitizedSSIDs($0.autoConnect.trustedSSIDs + w.trustedSSIDs)
            let defaults = AppSettings()
            if fillOnly {
                if $0.language == defaults.language { $0.language = Self.language(s) }
                if $0.appearance == defaults.appearance { $0.appearance = Self.appearance(s) }
                if $0.logLevel == defaults.logLevel { $0.logLevel = Self.logLevel(s) }
                if $0.menuBarIconStyle == defaults.menuBarIconStyle { $0.menuBarIconStyle = Self.iconStyle(s) }
                if $0.autoConnect.profileID == nil, let name = w.autoProfileName, let id = idByOldName[name] {
                    $0.autoConnect.profileID = id
                    $0.autoConnect.enabled = w.enabled
                }
                if let id = AutoConnectRules.turnedOn(from: before, to: $0.autoConnect) { $0.endOnDemandSuspension([id]) }
                return
            }
            $0.language = Self.language(s)
            $0.appearance = Self.appearance(s)
            $0.logLevel = Self.logLevel(s)
            $0.menuBarIconStyle = Self.iconStyle(s)
            if let name = w.autoProfileName, let id = idByOldName[name] {
                $0.autoConnect.profileID = id
                $0.autoConnect.enabled = w.enabled
            }
            // Like a UI change: turning Auto-Connect on is fresh intent, so it ends a suspension of that profile.
            if let id = AutoConnectRules.turnedOn(from: before, to: $0.autoConnect) { $0.endOnDemandSuspension([id]) }
        }
        if settings.value.autoConnect != before { onAutoConnectChanged?() }
    }

    private static func language(_ s: MigratedSettings) -> AppSettings.Language { AppSettings.Language(rawValue: s.language.rawValue) ?? .system }
    private static func appearance(_ s: MigratedSettings) -> AppSettings.Appearance { AppSettings.Appearance(rawValue: s.appearance.rawValue) ?? .system }
    private static func iconStyle(_ s: MigratedSettings) -> AppSettings.IconStyle { s.menuBarIconStyle == .color ? .color : .monochrome }
    private static func logLevel(_ s: MigratedSettings) -> AppSettings.Level {
        switch s.logLevel {
        case .debug: .debug
        case .info: .info
        case .warn: .warning
        case .error: .error
        }
    }

    /// FA nit: migration.json names the Go directory relative to the home folder ("~/Library/…"), not with the
    /// absolute path (which carries the user name).
    nonisolated static func homeRelative(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A migrated session's history ID, derived from the session itself: the same Go entry always gets the same ID,
    /// so `appendHistory` (which skips known IDs) never adds it twice (pre-release review LOW: a kill between the
    /// history append and the marker save duplicated it on resume).
    static func stableID(_ s: MigratedSession) -> UUID {
        let key = "lockplus-go-history\u{0}\(s.tunnelName)\u{0}\(s.start.timeIntervalSince1970)\u{0}\(s.end?.timeIntervalSince1970 ?? -1)\u{0}\(s.rxBytes)\u{0}\(s.txBytes)"
        var b = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50          // RFC 9562 name-based layout (version 5 bits, SHA-256 truncated)
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// §13.1 step 8.
    static func history(_ sessions: [MigratedSession], idByOldName: [String: UUID]) -> [HistoryEntry] {
        sessions.map { s in
            let reason: HistoryEntry.EndReason = switch s.endReason {
            case .user, .appQuit: .user
            case .replaced: .replaced
            case .other: .other
            }
            return HistoryEntry(id: stableID(s), profileID: idByOldName[s.tunnelName], profileName: s.tunnelName, start: s.start,
                                end: s.end, rxBytes: s.rxBytes, txBytes: s.txBytes, endReason: reason)
        }
    }
}
