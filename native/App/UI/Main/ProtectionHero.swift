import LPModel
import SwiftUI

/// The protection hero (UI-CONCEPT §6.4, §6.6, §7.3): an opaque `lp.card` with a 12 % state tint (never Liquid
/// Glass), the glyph at 44 pt, the state word in `.title`, one line of "through what", then live numbers, the
/// 5-minute chart, the DNS line, the error strip and the actions the derived state allows.
struct ProtectionHero: View {
    @Environment(UIEnvironment.self) private var env
    let profile: ProfileItem

    var body: some View {
        let isCurrent = profile.id == env.connection.profileID
        // Another profile's hero shows its resting state; Connect then switches (§6.2).
        let condition: ConnectionCondition = isCurrent ? env.connection.condition : .unprotected
        let needsClock = { if case .paused = condition { true } else if case .blockedReconnecting = condition { true } else { false } }()
        Group {
            if needsClock {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in content(condition, now: ctx.date) }
            } else {
                content(condition, now: Date())
            }
        }
    }

    private var isCurrentProfile: Bool { profile.id == env.connection.profileID }

    @ViewBuilder private func content(_ condition: ConnectionCondition, now: Date) -> some View {
        let ctx = profile.context(errorDetail: env.connection.lastErrorDetail, now: now)
        let copy = condition.copy(for: ctx, now: now)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                LockGlyph(state: condition.glyph, size: 44, ringOnConnect: true)
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.title)
                        .font(.title)
                        .foregroundStyle(condition.glyph.textColor == .primary ? Color.lp.label : condition.glyph.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let message = copy.message {
                        DotSeparatedText(text: message)
                            .foregroundStyle(Color.lp.label2)
                            .textSelection(.enabled)
                    }
                    // While connected the DNS line below carries row 5's detail.
                    if let detail = copy.detail, !condition.showsRateLabel {
                        Text(detail)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(condition.glyph.textColor == .primary ? Color.lp.label2 : condition.glyph.textColor)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if condition.showsRateLabel {
                HeroStats()
                LiveThroughputChart(samples: env.stats.samples)
                    .frame(height: 90)
                DNSLine(verdict: env.connection.inputs.dns)
            }

            // 2.0.1 E2E F2: why this (non-current) profile ended or couldn't start: refused beside another LockPlus
            // session (222), or ended for a kill-switch profile's start (223). The current profile's hero isn't touched.
            if !isCurrentProfile, let note = env.connection.endNotes[profile.id] {
                InlineStrip(severity: .attention, message: note)
            }
            if isCurrentProfile && env.connection.reconnectedAfterRestart {
                InlineStrip(severity: .info, message: ConnectionUIModel.reconnectedAfterRestartText)
            }
            if profile.notYetVerified && !condition.isActive {
                InlineStrip(severity: .info, message: ProfileItem.notYetVerifiedExplanation)
            }
            if profile.protectionRepairing && profile.killSwitch {
                InlineStrip(severity: .attention, message: ProfileItem.protectionRepairingExplanation)
            }

            actionRow(condition)

            if let hint = copy.hint {
                Text(hint).font(.callout).foregroundStyle(Color.lp.label2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lpSurface(.heroCard, tint: condition.heroTint.color)
    }

    @ViewBuilder private func actionRow(_ condition: ConnectionCondition) -> some View {
        let actions = condition.actions
        ActionRow {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                button(for: action, primary: index == 0)
            }
        }
    }

    @ViewBuilder private func button(for action: StateAction, primary: Bool) -> some View {
        switch action {
        case .connect:
            Button(action.title) { env.gatedConnect(profile.id) }
                .buttonStyle(.lpConnect)
                .disabled(profile.notYetVerified || profile.connectHeld != nil)
                .help(profile.connectHeld ?? "")
        case .pause:
            Menu(action.title) {
                ForEach(PauseChoice.all, id: \.self) { m in
                    Button(PauseChoice.title(m)) { env.presentation.pauseMinutes = m }
                }
            }
            .fixedSize()
        case .details:
            Button(action.title) { env.presentation.showErrorDetails = true }
        case .runDiagnostics:
            Button(action.title) { env.actions.runDiagnostics() }
        default:
            if primary {
                Button(action.title) { env.actions.perform(action) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button(action.title) { env.actions.perform(action) }
                    .controlSize(.large)
            }
        }
    }
}

/// The pause confirmation (§6.6, UI-CONCEPT §9 `PauseConfirmSheet`), with the resume-agent note when macOS hasn't
/// allowed the login item yet (§10.4).
struct PauseConfirmSheet: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let minutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text("Pause protection?", comment: "Pause confirmation title").font(.headline) }
                icon: { Image(GlyphState.paused.symbolName).foregroundStyle(Color.lp.softAmber) }
            Text(PauseChoice.confirmation(minutes)).fixedSize(horizontal: false, vertical: true)
            if env.connection.resumeAgentNeedsApproval {
                InlineStrip(severity: .attention, message: PauseChoice.approvalNote) {
                    Button(PauseChoice.openLoginItems) { SystemSettingsLink.open(SystemSettingsLink.loginItems) }
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Button")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Pause", comment: "Button")) { env.actions.pause(minutes: minutes); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// "↓ 1.2 MB/s   ↑ 30 KB/s   02:14:07   Handshake 21 s" in monospaced digits. One row when it fits; in a narrow
/// detail (minimum window width) the time and handshake move to a second row instead of breaking mid-word
/// (owner review 2026-11-10: "Handsh / ake 1 / sec" at 720 pt).
private struct HeroStats: View {
    @Environment(UIEnvironment.self) private var env

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    RatePair(rate: env.stats.current, font: .body, columnWidth: 110)
                    facts(ctx.date)
                }
                VStack(alignment: .leading, spacing: 6) {
                    RatePair(rate: env.stats.current, font: .body, columnWidth: 110)
                    HStack(spacing: 18) { facts(ctx.date) }
                }
            }
            .foregroundStyle(Color.lp.label)
        }
    }

    @ViewBuilder private func facts(_ now: Date) -> some View {
        if let since = env.connection.connectedSince {
            Text(verbatim: DurationFormat.clock(now.timeIntervalSince(since)))
                .monospacedDigit()
                .fixedSize()
                .accessibilityLabel(Text("Connected for \(DurationFormat.spoken(now.timeIntervalSince(since)))", comment: "Accessibility"))
        }
        if let hs = env.stats.lastHandshake {
            Text("Handshake \(DurationFormat.seconds(now.timeIntervalSince(hs)))", comment: "Hero, WireGuard last handshake age; the argument is like '21 sec'")
                .monospacedDigit()
                .fixedSize()
        } else if let ms = env.stats.latencyMilliseconds {
            Text(Measurement(value: Double(ms), unit: UnitDuration.milliseconds).formatted(.measurement(width: .abbreviated, usage: .asProvided)))
                .monospacedDigit()
                .fixedSize()
        }
    }
}

/// From `DNSVerifier` (§6.4). `.unverified` never uses the check glyph.
struct DNSLine: View {
    let verdict: DNSVerdict
    var body: some View {
        switch verdict {
        case .verified:
            Label { Text("DNS through tunnel (verified)", comment: "DNS line") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.lp.sage) }
                .foregroundStyle(Color.lp.label)
        case .overridden:
            Label { Text("DNS overridden by another profile", comment: "DNS line") } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.attention) }
                .foregroundStyle(Color.lp.attentionText)
        case .unverified:
            Label { Text("Couldn't verify DNS", comment: "DNS line") } icon: { Image(systemName: "questionmark.circle").foregroundStyle(Color.lp.label2) }
                .foregroundStyle(Color.lp.label)
        case .pending:
            EmptyView()
        }
    }
}

extension StateAction {
    var title: String {
        switch self {
        case .connect: String(localized: "Connect", comment: "Button")
        case .disconnect: String(localized: "Disconnect", comment: "Button")
        case .disconnectAndRestoreInternet: String(localized: "Disconnect and Restore Internet", comment: "Button (§6.6)")
        case .cancel: String(localized: "Cancel", comment: "Button")
        case .enterCode: String(localized: "Enter Code…", comment: "Button")
        case .signIn: String(localized: "Sign In…", comment: "Button")
        case .pause: String(localized: "Pause", comment: "Button")
        case .resumeNow: String(localized: "Resume Now", comment: "Button")
        case .details: String(localized: "Details…", comment: "Button")
        case .runDiagnostics: String(localized: "Run Diagnostics", comment: "Button")
        case .openSystemSettings: String(localized: "Open System Settings", comment: "Button")
        case .showSwitchAgain: String(localized: "Show the Switch Again", comment: "Button (§6.14)")
        case .approve: String(localized: "Approve…", comment: "Button")
        case .reinstall: String(localized: "Reinstall…", comment: "Button")
        case .restartMac: String(localized: "Restart…", comment: "Button")
        }
    }
}

/// "Details…" for an error (DESIGN §11.7): code, time and the extension's non-secret detail.
struct ErrorDetailsSheet: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let c = env.connection
        VStack(alignment: .leading, spacing: 12) {
            Text("Error Details", comment: "Sheet title").font(.headline)
            Form {
                if let code = c.condition.error ?? c.inputs.lastError?.code {
                    LabeledContent(String(localized: "Message", comment: "Field")) { Text(code.message(detail: c.lastErrorDetail)) }
                    LabeledContent(String(localized: "Code", comment: "Field")) { Text(verbatim: "\(code) (\(code.rawValue))") }
                }
                if let at = c.lastErrorAt {
                    LabeledContent(String(localized: "Time", comment: "Field")) { Text(at, format: .dateTime) }
                }
                if let detail = c.lastErrorDetail {
                    LabeledContent(String(localized: "Detail", comment: "Field")) { Text(detail) }
                }
            }
            .textSelection(.enabled)
            HStack {
                Button(String(localized: "Show Logs", comment: "Button")) {
                    dismiss()
                    if let at = c.lastErrorAt { env.actions.showLogs(around: at) } else { NavigationRequest.post(.logs) }
                }
                Spacer()
                Button(String(localized: "Done", comment: "Button")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

#Preview("Hero — every §6.6 row", traits: .fixedLayout(width: 640, height: 4200)) {
    ScrollView {
        VStack(spacing: 16) {
            ForEach(PreviewData.allRows, id: \.self) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Row \(row)").font(.caption).foregroundStyle(.secondary)
                    ProtectionHero(profile: PreviewData.work).environment(UIEnvironment.preview(row: row))
                }
            }
        }
        .padding()
    }
    .background(BrandCanvasBackground())
}

#Preview("Pause sheet — resume agent needs approval") {
    let env = UIEnvironment.preview(row: "6")
    env.connection.resumeAgentNeedsApproval = true
    return PauseConfirmSheet(minutes: 15).environment(env)
}

#Preview("Hero — protected, dark") {
    ProtectionHero(profile: PreviewData.work)
        .environment(UIEnvironment.preview(row: "6"))
        .padding()
        .frame(width: 640)
        .background(BrandCanvasBackground())
        .preferredColorScheme(.dark)
}
