import AppKit
import Foundation
import LPModel
import LPWire
import Observation

/// Store → UI mapping (DESIGN §11.2). Pure functions, unit-tested; the derived-state TABLE itself lives in App/UI
/// (`DerivedStateInputs.condition`). This file only fills its inputs.
@MainActor enum UIMapping {
    static func phase(_ p: TunnelPhase) -> TunnelPhaseUI { TunnelPhaseUI(rawValue: p.rawValue) ?? .idle }

    static func hold(_ h: HoldReason?) -> HoldReasonUI? {
        switch h {
        case .blockedAfterFailure(let c)?: .blockedAfterFailure(c)
        case .nonRetryable(let c)?: .nonRetryable(c)
        case nil: nil
        }
    }

    static func snapshotFacts(_ s: TunnelSnapshot?, profileID: UUID?) -> SnapshotFacts {
        guard let s, s.profileID == profileID else { return SnapshotFacts() }
        return SnapshotFacts(phase: phase(s.phase), attempt: s.attempt, nextRetryAt: s.nextRetryAt, holdReason: hold(s.holdReason),
                             holdBeforeConnected: s.holdBeforeConnected,
                             startLatch: s.startLatch.map { StartLatchUI(code: $0.code, kind: $0.kind == .hard ? .hard : .backoff) })
    }

    /// Everything the §6.6 table reads, for the condition's profile.
    static func inputs(profile: Profile?, fallbackName: String, status: TunnelStatus, observedError: ObservedError?,
                       userStoppedSinceError: Bool, snapshot: TunnelSnapshot?, awaitingApproval: Bool,
                       pausedUntil: Date?, readiness: ExtensionReadiness, link: XPCLinkState, switchingTo: String?,
                       startHold: StartHoldUI? = nil,
                       dns: DNSVerdict = .pending, protectionMismatch: Bool = false, now: Date) -> DerivedStateInputs {
        var i = DerivedStateInputs(profileName: profile?.name ?? fallbackName)
        i.status = status
        // E2E-1: while the NE configuration's flags disagree with the profile, nothing may claim the kill switch.
        i.killSwitch = (profile?.policy.killSwitch ?? false) && !protectionMismatch
        i.lastError = observedError
        i.userStoppedSinceError = userStoppedSinceError
        i.snapshot = snapshotFacts(snapshot, profileID: profile?.id)
        i.awaitingApproval = awaitingApproval
        i.pausedUntil = pausedUntil
        i.extensionReadiness = readiness
        i.link = link
        i.switchingTo = switchingTo
        i.startHold = startHold
        i.dns = dns
        i.now = now
        return i
    }

    static func item(_ p: Profile, credentials c: CredentialFacts?, autoProfileID: UUID?,
                     snapshot: TunnelSnapshot?, history: [HistoryEntry], protectionMismatch: Bool = false) -> ProfileItem {
        let mine = snapshot?.profileID == p.id ? snapshot : nil
        let last = history.last { $0.profileID == p.id && $0.end != nil }
        let hasV6 = p.summary.addresses.contains { $0.contains(":") }
        var creds: ProfileItem.Credentials?
        if p.kind == .openVPN, let a = p.auth, a.needsUserPass || a.staticChallenge != nil || a.needsKeyPassphrase {
            let otp: ProfileItem.Credentials.OneTimeCode = a.staticChallenge != nil ? .staticChallenge : (a.appendOTP || p.dynamicChallengeSeen) ? .everyConnect : .none
            creds = .init(username: c?.username, passwordSaved: c?.passwordSaved ?? false, oneTimeCode: otp)
        }
        var item = ProfileItem(
            id: p.id, name: p.name, kind: p.kind, endpoint: p.summary.endpoints.first ?? "", resolvedEndpoint: mine?.endpoint,
            place: nil, transport: p.summary.transport.uppercased(), addresses: mine.map { $0.localAddresses.isEmpty ? p.summary.addresses : $0.localAddresses } ?? p.summary.addresses,
            dns: p.summary.dnsServers, routes: p.summary.isFullTunnel ? .allTraffic : .split([]), mtu: p.policy.mtuOverride,
            cipher: mine?.cipher, killSwitch: p.policy.killSwitch, allowLocalNetwork: p.policy.allowLAN,
            blockIPv6WithoutKillSwitch: p.policy.blockIPv6WithoutKillSwitch,
            isIPv4OnlyFullTunnel: p.kind == .wireGuard && p.summary.isFullTunnel && !hasV6,
            isAutoConnectProfile: autoProfileID == p.id, credentials: creds, notes: p.notes,
            ignoredDirectives: (p.importReport?.items(in: .ignored) ?? []).compactMap { i in i.directive.map { IgnoredDirective(name: $0, reason: i.localizedMessage(), harmless: i.isHarmlessIgnored) } },
            lastSessionEnded: last?.end, lastSessionDuration: last.flatMap { e in e.end.map { $0.timeIntervalSince(e.start) } })
        item.notYetVerified = !p.engineVerified           // OpenVPN step [7] hasn't run yet (§8.1)
        item.protectionRepairing = protectionMismatch     // E2E-1: NE flags differ from the profile
        return item
    }

    /// Review 5 §3: the store's hold with profile names (a profile that vanished meanwhile reads as "").
    static func startHold(_ h: ConnectionStore.StartHold?, name: (UUID) -> String?) -> StartHoldUI? {
        guard let h else { return nil }
        let reason: StartHoldUI.Reason = switch h.reason {
        case .preparing: .preparing
        case .waitingForStop(let old): .waitingForStop(of: name(old) ?? "")
        case .awaitingRestart: .awaitingRestart
        case .mayRestart: .mayRestart
        case .startEndedEarly: .startEndedEarly
        case .readingDisconnect: .readingDisconnect
        case .waitingForNetwork: .waitingForNetwork
        case .awaitingNetwork: .awaitingNetwork
        }
        return StartHoldUI(name: name(h.profile) ?? "", reason: reason)
    }

    static func session(_ h: HistoryEntry) -> SessionRow {
        let ended: SessionRow.EndReason = switch h.endReason {
        case .user: .user
        case .error: .error
        case .sleep, .replaced, .onDemand: .system
        case .other: .network
        }
        return SessionRow(id: h.id, profileName: h.profileName, started: h.start, duration: h.end.map { $0.timeIntervalSince(h.start) },
                          received: h.rxBytes, sent: h.txBytes, ended: h.end == nil ? .active : ended)
    }

    static func legacyNotice(_ f: LegacyFinding, facts: LegacyFacts = LegacyFacts(), canRemove: Bool = false) -> LegacyHelperNotice? {
        guard var message = f.message else { return nil }
        // Review E2E-5 F1-1: while the old app runs, the removal waits for it to quit.
        if (f == .helperIdle || f == .orphanBinary) && facts.goGUIRunning {
            message = String(localized: "The old LockPlus helper is still installed. Quit the old LockPlus first; then LockPlus can remove its helper.",
                             comment: "§4.5 banner while the Go app runs (review E2E-5 F1-1)")
        } else if f == .helperIdle && facts.helperNotResponding {
            message = LegacyHelperCopy.removalProblem(.failed(.notResponding))
        } else if f == .helperIdle && facts.helperReachable == false && facts.dnsJournal {
            message = LegacyHelperCopy.removalProblem(.failed(.dnsNotRestored), oldAppInstalled: facts.goAppInstalled)
        }
        return LegacyHelperNotice(message: message, blocksConnect: f.blocksConnect, warnsBeforeConnect: f.warnsBeforeConnect,
                                  oldAppInstalled: facts.goAppInstalled, canRemoveHelper: canRemove)
    }

    // Settings ⇄ UI

    static func apply(_ s: AppSettings, to m: SettingsUIModel) {
        set(&m.language, AppLanguage(rawValue: s.language.rawValue) ?? .system)
        set(&m.appearance, AppAppearance(rawValue: s.appearance.rawValue) ?? .system)
        set(&m.notifications, s.notifications == .problemsOnly ? .problemsOnly : s.notifications == .off ? .off : .connectAndDisconnect)
        set(&m.rateLabel, RateLabelMode(rawValue: s.menuBarRateLabel.rawValue) ?? .both)
        set(&m.iconStyle, IconStyle(rawValue: s.menuBarIconStyle.rawValue) ?? .color)
        set(&m.logLevel, LogLevel(rawValue: s.logLevel.rawValue) ?? .info)
        set(&m.receiveReleaseCandidates, s.receiveReleaseCandidates)
        set(&m.openWindowAtLogin, s.openWindowAtLogin)
        set(&m.defaultKillSwitchForFullTunnels, s.newProfileDefaults.killSwitch)
        set(&m.defaultAllowLocalNetwork, s.newProfileDefaults.allowLAN)
        set(&m.iconMayBeHidden, s.iconMayBeHidden)
        set(&m.launchAtLoginOffer, s.launchAtLoginOffer)
    }

    static func read(_ m: SettingsUIModel, into s: inout AppSettings) {
        s.language = AppSettings.Language(rawValue: m.language.rawValue) ?? .system
        s.appearance = AppSettings.Appearance(rawValue: m.appearance.rawValue) ?? .system
        s.notifications = switch m.notifications {
        case .problemsOnly: .problemsOnly
        case .connectAndDisconnect: .connectDisconnect
        case .off: .off
        }
        s.menuBarRateLabel = AppSettings.RateLabel(rawValue: m.rateLabel.rawValue) ?? .both
        s.menuBarIconStyle = AppSettings.IconStyle(rawValue: m.iconStyle.rawValue) ?? .color
        s.logLevel = AppSettings.Level(rawValue: m.logLevel.rawValue) ?? .info
        s.receiveReleaseCandidates = m.receiveReleaseCandidates
        s.openWindowAtLogin = m.openWindowAtLogin
        s.newProfileDefaults.killSwitch = m.defaultKillSwitchForFullTunnels
        s.newProfileDefaults.allowLAN = m.defaultAllowLocalNetwork
        s.launchAtLoginOffer = m.launchAtLoginOffer
    }

    static func apply(_ r: AutoConnectRules, to m: AutoConnectUIModel) {
        set(&m.enabled, r.enabled)
        set(&m.profileID, r.profileID)
        set(&m.onUntrustedWiFi, r.connectOnUntrustedWiFi)
        set(&m.onEthernet, r.connectOnEthernet)
        set(&m.trustedNetworks, r.trustedSSIDs)
    }

    static func read(_ m: AutoConnectUIModel, into r: inout AutoConnectRules) {
        r.enabled = m.enabled
        r.profileID = m.profileID
        r.connectOnUntrustedWiFi = m.onUntrustedWiFi
        r.connectOnEthernet = m.onEthernet
        r.trustedSSIDs = AutoConnectRules.sanitizedSSIDs(m.trustedNetworks)
    }

    /// Assign only on change, so two-way bindings never ping-pong.
    static func set<T: Equatable>(_ x: inout T, _ v: T) { if x != v { x = v } }
}

/// Keeps the `UIEnvironment` in step with the stores (and the user-editable settings models in step with
/// settings.json) through Observation, re-armed on the main actor after each change.
@MainActor enum UIBinder {
    static func bind(_ env: AppEnvironment) {
        UIMapping.apply(env.settings.value, to: env.ui.settings)
        UIMapping.apply(env.settings.value.autoConnect, to: env.ui.autoConnect)
        env.uiAppliedSettings = env.settings.value
        env.ui.settings.launchAtLogin = env.hooks.loginItemState()
        env.ui.activity.sessions = env.history.reversed().map(UIMapping.session)
        storeToUI(env)
        settingsFromUI(env)
        autoConnectFromUI(env)
    }

    private static func storeToUI(_ env: AppEnvironment) {
        withObservationTracking {
            render(env)
        } onChange: { [weak env] in
            Task { @MainActor in if let env { storeToUI(env) } }
        }
    }

    private static var shownPromptID: UUID?
    private static var shownReshow = 0

    static func render(_ env: AppEnvironment) {
        let ui = env.ui, c = env.connection, x = env.extensionStore
        let current = env.profiles.profile(c.currentID)
        let readiness = ExtensionMapping.readiness(x.state, endedWithoutResult: x.activationEndedWithoutResult)
        let updateFailedLine: String? = if case .updateFailed(_, let code) = x.state { ExtensionMapping.updateFailedMessage(code: code) } else { nil }
        let switching = c.switchingTo.flatMap { env.profiles.profile($0)?.name }
        let name: (UUID) -> String? = { env.profiles.profile($0)?.name }
        let hold = UIMapping.startHold(c.startHold, name: name)
        let inputs = UIMapping.inputs(
            profile: current, fallbackName: env.profiles.ordered.first?.name ?? "", status: c.currentStatus,
            observedError: c.observedError, userStoppedSinceError: c.userStoppedSinceError, snapshot: c.snapshot,
            awaitingApproval: c.awaitingApproval, pausedUntil: c.pausedUntil,
            readiness: readiness, link: ExtensionMapping.link(x.link.link), switchingTo: switching, startHold: hold,
            dns: env.diagnostics.dnsProfileID == current?.id ? env.diagnostics.dns : .pending,
            protectionMismatch: current.map { env.profiles.protectionMismatch($0.id) } ?? false, now: Date())
        UIMapping.set(&ui.connection.inputs, inputs)
        UIMapping.set(&ui.connection.profileID, current?.id)
        UIMapping.set(&ui.connection.connectedSince, c.connectedSince)
        UIMapping.set(&ui.connection.anyOnDemandEnabled, c.anyOnDemandEnabled)
        UIMapping.set(&ui.connection.lastErrorDetail, c.errorDetail)
        UIMapping.set(&ui.connection.lastErrorAt, c.errorAt)

        let items = env.profiles.ordered.map {
            var item = UIMapping.item($0, credentials: env.profiles.credentials[$0.id], autoProfileID: env.settings.value.autoConnect.profileID,
                                      snapshot: c.snapshot, history: env.history,
                                      protectionMismatch: env.profiles.protectionMismatch($0.id))
            // Review 5 §3: every Connect of this profile is disabled while the store would ignore it, with the reason.
            item.connectHeld = UIMapping.startHold(c.connectHold(for: $0.id), name: name)?.explanation
            return item
        }
        UIMapping.set(&ui.profiles.profiles, items)
        UIMapping.set(&ui.profiles.locked, env.profiles.locked)
        UIMapping.set(&ui.profiles.readError, env.profiles.loadError)
        // L6: macOS asked already once a LockPlus VPN configuration exists in the system (the manager store loads them all).
        UIMapping.set(&ui.connection.vpnConfigurationExists, !env.managers.managers.isEmpty)
        UIMapping.set(&ui.connection.extensionUpdateFailedMessage, updateFailedLine)
        if ui.profiles.selection == nil || ui.profiles.profile(ui.profiles.selection) == nil {
            UIMapping.set(&ui.profiles.selection, current?.id ?? items.first?.id)
        }

        // Auth: assign a prompt once per promptID, so a sheet the user dismissed isn't forced back.
        let prompt = env.auth.prompt
        let reshow = env.auth.reshowCount
        if prompt?.promptID != shownPromptID || reshow != shownReshow {
            shownPromptID = prompt?.promptID
            shownReshow = reshow
            ui.auth.prompt = prompt.map { AuthCoordinator.uiState($0, profile: env.profiles.profile($0.profileID)) }
        }
        UIMapping.set(&ui.auth.expired, env.auth.expired)
        // M5: the answer didn't arrive; the re-shown sheet carries the reason inline.
        // E2E-4 (U15): after a failed update the tunnel component is out of reach over XPC: an answer that couldn't be
        // delivered says why, in the same words as the banner, not "extension unavailable".
        UIMapping.set(&ui.auth.error, env.auth.lastError.flatMap {
            if $0.code == .staleAnswer { return nil }
            if let updateFailedLine, $0.code == .extensionUnavailable || $0.code == .timeout || $0.code == .extensionBusy { return updateFailedLine }
            return $0.code.message(detail: $0.detail)
        })
        UIMapping.set(&ui.connection.pendingPromptProfileName, prompt.flatMap { env.profiles.profile($0.profileID)?.name })

        // Onboarding step 2 follows the extension lifecycle.
        UIMapping.set(&ui.onboarding.extensionStep, ExtensionMapping.onboardingStep(x.state, endedWithoutResult: x.activationEndedWithoutResult))

        // Settings written by the app (migration, launch counters, a deleted auto profile): pushed into the editable
        // models only when they changed since the last push (E2E-2 bug 1). Pushing on every render overwrote a toggle
        // the user had just clicked before `…FromUI` persisted it: Auto-Connect clicks "bounced" on 26 and auto-connect
        // was never saved.
        if env.settings.value != env.uiAppliedSettings {
            // §6.14: a change made by the app itself (the Go migration carries the 1.x theme over) never comes through
            // `settingsFromUI` as a difference, so it is applied here.
            let appearanceChanged = env.settings.value.appearance != env.uiAppliedSettings?.appearance
            env.uiAppliedSettings = env.settings.value
            if appearanceChanged { AppAppearanceApplier.apply(env.settings.value.appearance) }
            UIMapping.apply(env.settings.value, to: ui.settings)
            UIMapping.apply(env.settings.value.autoConnect, to: ui.autoConnect)
        }
        UIMapping.set(&ui.autoConnect.requiresRunningApp, false)
        UIMapping.set(&ui.autoConnect.statusLine, autoConnectStatusLine(env))

        // §10.4 pause note, §4.5 old helper.
        UIMapping.set(&ui.connection.resumeAgentNeedsApproval, c.resumeAgentStatus == .requiresApproval)
        UIMapping.set(&ui.connection.reconnectedAfterRestart,
                      c.restartedAfterCrash != nil && c.restartedAfterCrash == c.currentID && c.currentStatus == .connected)
        if c.configurationDenied { UIMapping.set(&ui.connection.vpnConfigurationDenied, true) }
        UIMapping.set(&ui.connection.legacyHelper, UIMapping.legacyNotice(env.legacy.finding, facts: env.legacy.facts, canRemove: env.legacy.canRemoveHelper))
        UIMapping.set(&ui.connection.legacyHelperRemoval, env.legacy.removal)
        UIMapping.set(&ui.connection.oldWireGuidePlusApp, env.legacy.oldApp)
        UIMapping.set(&ui.connection.oldAppTrashFailed, env.legacy.oldAppTrashFailed)
        // E2E-5 F3: the old tunnel went down (re-read while refusing): the refusal is over, Connect works again.
        // Review LOW: the crashed-helper warning ends the same way when the finding no longer warns, and either strip
        // ends when its profile was deleted (Connect Anyway would otherwise pass a dead id).
        switch ui.connection.connectGate {
        case .refused(let id)?:
            if !env.legacy.finding.blocksConnect || env.profiles.profile(id) == nil { ui.connection.connectGate = nil }
        case .warn(let id)?:
            if !env.legacy.finding.warnsBeforeConnect || env.profiles.profile(id) == nil { ui.connection.connectGate = nil }
        case nil:
            break
        }

        UIMapping.set(&ui.diagnostics.problems, env.profiles.problems.map { ProblemRow(id: $0.id, date: $0.date, message: $0.message) })
        env.stats.reevaluate()
    }

    /// The Auto-Connect pane's status (§10.4): the auto profile is suspended by a Disconnect (and why, and how to end
    /// it), it waits for another profile that started (a recorded pause: not for a session started elsewhere, where
    /// nothing was paused), it is held while the tunnel component is updated (review 4 #3), or LockPlus couldn't turn it
    /// back on (review F4).
    static func autoConnectStatusLine(_ env: AppEnvironment) -> String? {
        let s = env.settings.value, c = env.connection
        guard s.autoConnect.enabled, let id = s.autoConnect.profileID, let auto = env.profiles.profile(id) else { return nil }
        if s.onDemandSuspended.contains(id) {
            return String(localized: "Auto-connect for \(auto.name) is paused until you join another network, because you disconnected it. To resume now, turn Auto-Connect off and on again.",
                          comment: "Auto-connect status: suspended by the user's Disconnect (§10.4)")
        }
        if s.extensionHandOver {
            return String(localized: "Auto-connect is paused while the tunnel component is updated.",
                          comment: "Auto-connect status: every plan is held during an extension update or reinstall (review N2, review 4 #3)")
        }
        if let holder = c.holder(of: id), let name = env.profiles.profile(holder)?.name {
            return String(localized: "Auto-connect resumes when you disconnect \(name).", comment: "Auto-connect status (§10.4)")
        }
        if let line = c.busyReason?.explanation { return line }           // E2E-4 L1: another user's or an unaddressable session
        if !env.uiResaving, c.onDemandNeedsRestore(auto) {
            return String(localized: "Auto-connect is off; LockPlus couldn't turn it back on.", comment: "Auto-connect status: a restore failed and is retried (review F4)")
        }
        return nil
    }

    private static func settingsFromUI(_ env: AppEnvironment) {
        withObservationTracking {
            let m = env.ui.settings
            _ = (m.language, m.appearance, m.notifications, m.rateLabel, m.iconStyle, m.logLevel, m.receiveReleaseCandidates,
                 m.openWindowAtLogin, m.defaultKillSwitchForFullTunnels, m.defaultAllowLocalNetwork, m.launchAtLoginOffer)
        } onChange: { [weak env] in
            Task { @MainActor in
                guard let env else { return }
                settingsFromUI(env)                     // re-armed first: a change made meanwhile is never missed
                let before = env.settings.value
                env.settings.update { UIMapping.read(env.ui.settings, into: &$0) }
                let after = env.settings.value
                if env.uiAppliedSettings == before { env.uiAppliedSettings = after }        // the UI's own edit: nothing to push back
                if after.appearance != before.appearance { AppAppearanceApplier.apply(after.appearance) }              // §6.14: live
                if after.receiveReleaseCandidates != before.receiveReleaseCandidates { env.updater.channelsChanged() }   // §12.1
                if after.notifications != before.notifications { Task { await env.notificationModeChanged(to: after.notifications) } }
            }
        }
    }

    /// One re-save at a time; changes made while one runs are applied by one more pass after it (latest rules win).
    /// The Auto-Connect pane and the Go migration (E2E-5 F2) both come through here.
    static func requestOnDemandResave(_ env: AppEnvironment) {
        guard !env.uiResaving else { env.uiResaveAgain = true; return }
        env.uiResaving = true
        Task { @MainActor in
            repeat {
                env.uiResaveAgain = false
                await env.profiles.resaveOnDemand()
            } while env.uiResaveAgain
            env.uiResaving = false
        }
    }

    private static func autoConnectFromUI(_ env: AppEnvironment) {
        withObservationTracking {
            let m = env.ui.autoConnect
            _ = (m.enabled, m.profileID, m.onUntrustedWiFi, m.onEthernet, m.trustedNetworks)
        } onChange: { [weak env] in
            Task { @MainActor in
                guard let env else { return }
                // E2E-2 bug 1: re-armed BEFORE the (slow) re-save; re-arming after it lost every click made meanwhile.
                autoConnectFromUI(env)
                let before = env.settings.value
                env.settings.update {
                    UIMapping.read(env.ui.autoConnect, into: &$0.autoConnect)
                    // Turning Auto-Connect on for a profile ends its "suspended until the next network change".
                    if let id = AutoConnectRules.turnedOn(from: before.autoConnect, to: $0.autoConnect) { $0.endOnDemandSuspension([id]) }
                }
                if env.uiAppliedSettings == before { env.uiAppliedSettings = env.settings.value }
                if env.settings.value.autoConnect != before.autoConnect { requestOnDemandResave(env) }
            }
        }
    }
}

/// §6.14: the Appearance setting. `NSApp.appearance` is nil for System (windows follow macOS), Aqua for Light, Dark Aqua
/// for Dark. It applies to every window at once; the menu bar status item keeps following the menu bar.
@MainActor enum AppAppearanceApplier {
    static func apply(_ a: AppSettings.Appearance) {
        NSApp?.appearance = switch a {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
