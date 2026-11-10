import LPModel
import SwiftUI

/// Profile detail (UI-CONCEPT §6.4): the hero, then grouped sections. Rows are selectable text. The private key is
/// never shown here. Section titles carry the heading trait.
struct ProfileDetailView: View {
    @Environment(UIEnvironment.self) private var env
    let profile: ProfileItem
    @State private var notes = ""
    /// Which profile `notes` belongs to: saved to THAT profile on switch (UI-M7).
    @State private var notesProfileID: ProfileItem.ID?
    @State private var confirmAllowLAN = false
    @State private var showIgnored: Bool
    @State private var showNotApplied: Bool

    /// `ignoredExpanded`: only the screenshot tests open the import report; in the app it starts collapsed.
    init(profile: ProfileItem, ignoredExpanded: Bool = false) {
        self.profile = profile
        _showIgnored = State(initialValue: ignoredExpanded)
        _showNotApplied = State(initialValue: ignoredExpanded)
    }

    var body: some View {
        let isCurrent = profile.id == env.connection.profileID
        let connected = isCurrent && env.connection.condition.isActive
        Form {
            Section {
                ProtectionHero(profile: profile)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                row(String(localized: "Endpoint", comment: "Detail row")) {
                    if let ip = profile.resolvedEndpoint { Text(verbatim: "\(profile.endpoint)  (\(ip))") } else { Text(verbatim: profile.endpoint) }
                }
                if !profile.addresses.isEmpty {
                    row(String(localized: "Address", comment: "Detail row")) { Text(verbatim: profile.addresses.joined(separator: ", ")) }
                }
                if !profile.dns.isEmpty {
                    row(String(localized: "DNS", comment: "Detail row")) { Text(verbatim: profile.dns.joined(separator: ", ")) }
                }
                row(String(localized: "Routes", comment: "Detail row")) {
                    switch profile.routes {
                    case .allTraffic: Text("All traffic (0.0.0.0/0, ::/0)", comment: "Detail, full tunnel routes")
                    case .split(let r): Text(verbatim: r.joined(separator: ", "))
                    }
                }
                if let mtu = profile.mtu {
                    row(String(localized: "MTU", comment: "Detail row")) { Text(mtu, format: .number.grouping(.never)) }
                }
                if let cipher = profile.cipher {
                    row(String(localized: "Cipher", comment: "Detail row")) { Text(verbatim: cipher) }
                }
                if connected {
                    row(String(localized: "Received / Sent", comment: "Detail row")) {
                        Text("\(ByteFormat.text(env.stats.sessionReceived)) / \(ByteFormat.text(env.stats.sessionSent)) this session", comment: "Detail, session transfer")
                            .monospacedDigit()
                    }
                }
            } header: {
                SectionHeading("Connection")
            }

            Section {
                Toggle(isOn: Binding(get: { profile.killSwitch }, set: { env.actions.setKillSwitch($0, for: profile.id) })) {
                    Text(profile.isFullTunnel ? String(localized: "Kill switch", comment: "Policy toggle (full tunnel)")
                                              : String(localized: "Route protection", comment: "Policy toggle (split tunnel, §6.4)"))
                    Text(killSwitchFooter)
                }
                Toggle(isOn: Binding(get: { profile.allowLocalNetwork }, set: { on in
                    if on { confirmAllowLAN = true } else { env.actions.setAllowLocalNetwork(false, for: profile.id) }
                })) {
                    Text("Allow local network (printers, NAS)", comment: "Policy toggle")
                    if profile.allowLocalNetwork {
                        Text("Devices on this network (printers, NAS, AirPlay) can be reached outside the VPN. A hostile Wi-Fi network can abuse this.", comment: "Allow LAN warning (§6.4)")
                    }
                }
                .disabled(!profile.killSwitch)
                if profile.isIPv4OnlyFullTunnel && !profile.killSwitch {
                    Toggle(isOn: Binding(get: { profile.blockIPv6WithoutKillSwitch }, set: { env.actions.setBlockIPv6($0, for: profile.id) })) {
                        Text("Block IPv6 without kill switch", comment: "Policy toggle")
                    }
                }
            } header: {
                SectionHeading("Protection")
            } footer: {
                if connected {
                    Text("Disconnect to change.", comment: "Protection section footer while connected")
                }
            }
            .disabled(connected)

            Section {
                if profile.isAutoConnectProfile {
                    Text("This is the auto-connect profile. Edit its rules in Auto-Connect (⌘3).", comment: "Detail, auto-connect")
                } else {
                    Text("Not used for auto-connect.", comment: "Detail, auto-connect")
                        .foregroundStyle(.secondary)
                }
            } header: {
                SectionHeading("Auto-Connect")
            }

            if let creds = profile.credentials {
                Section {
                    if let user = creds.username {
                        row(String(localized: "Username", comment: "Detail row")) { Text(verbatim: user) }
                    }
                    LabeledContent(String(localized: "Password", comment: "Detail row")) {
                        HStack {
                            Text(creds.passwordSaved ? String(localized: "Saved in Keychain", comment: "Password state")
                                                     : String(localized: "Asked on connect", comment: "Password state"))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)     // wraps instead of "Saved in Keych…"
                            if creds.passwordSaved {
                                Button { env.actions.showPassword(profile.id) } label: {
                                    Label(String(localized: "Show", comment: "Button, behind Touch ID"), systemImage: "touchid")
                                }
                                Button(String(localized: "Change…", comment: "Button")) { env.actions.changePassword(profile.id) }
                                Button(String(localized: "Forget", comment: "Button")) { env.actions.forgetPassword(profile.id) }
                            }
                        }
                    }
                    if creds.oneTimeCode != .none {
                        row(String(localized: "One-time code", comment: "Detail row")) {
                            Text(creds.oneTimeCode == .staticChallenge ? String(localized: "Server challenge on every connect", comment: "OTP state")
                                                                       : String(localized: "Asked on every connect", comment: "OTP state"))
                        }
                    }
                } header: {
                    SectionHeading("Credentials")
                }
            }

            Section {
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(Text("Notes", comment: "Accessibility label"))
                    .onAppear { notes = profile.notes; notesProfileID = profile.id }
                    .onChange(of: profile.id) { old, new in
                        saveNotes(for: old)
                        notes = profile.notes
                        notesProfileID = new
                    }
                    .task(id: notes) {                      // debounced save while typing
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { saveNotes(for: notesProfileID) }
                    }
                    .onDisappear { saveNotes(for: notesProfileID) }
            } header: {
                SectionHeading("Notes")
            }

            if !profile.ignoredDirectives.isEmpty {
                let notApplied = profile.ignoredDirectives.filter { !$0.harmless }
                let harmless = profile.ignoredDirectives.filter(\.harmless)
                Section {
                    if !notApplied.isEmpty {
                        DisclosureGroup(isExpanded: $showNotApplied) {
                            // Offsets, not the values: a repeated name and reason pair is a legitimate report.
                            ForEach(Array(notApplied.enumerated()), id: \.offset) { _, d in directiveRow(d) }
                        } label: {
                            Label {
                                Text("^[\(notApplied.count) directive](inflect: true) not applied", comment: "Import report summary; directives whose behaviour LockPlus does not apply (scripts, certificate pin, web sign-in, WireGuard settings)")
                            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.softAmber) }
                        }
                    }
                    if !harmless.isEmpty {
                        // Informational, not a warning: the usual OpenVPN housekeeping lines LockPlus handles itself. One-line
                        // label so the chevron sits by the heading; the explanation follows it, collapsed or not.
                        DisclosureGroup(isExpanded: $showIgnored) {
                            notNeededExplanation
                            ForEach(Array(harmless.enumerated()), id: \.offset) { _, d in directiveRow(d) }
                        } label: {
                            Label {
                                Text("^[\(harmless.count) directive](inflect: true) not needed", comment: "Import report summary; harmless directives LockPlus doesn't need")
                            } icon: { Image(systemName: "info.circle.fill").foregroundStyle(Color.secondary) }
                        }
                        if !showIgnored { notNeededExplanation }
                    }
                } header: {
                    SectionHeading("Import Report")
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button { env.actions.editConfig(profile.id) } label: {
                        Label(String(localized: "Edit Config…", comment: "Button, behind Touch ID"), systemImage: "touchid")
                    }
                    Button(String(localized: "Export…", comment: "Button")) { env.actions.export(profile.id) }
                }
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert(Text("Allow local network?", comment: "Alert title"), isPresented: $confirmAllowLAN) {
            Button(String(localized: "Allow", comment: "Button")) { env.actions.setAllowLocalNetwork(true, for: profile.id) }
            Button(String(localized: "Cancel", comment: "Button"), role: .cancel) { }
        } message: {
            Text("Devices on this network (printers, NAS, AirPlay) can be reached outside the VPN. A hostile Wi-Fi network can abuse this.", comment: "Allow LAN warning (§6.4)")
        }
    }

    private var notNeededExplanation: some View {
        Text(ImportReportCopy.notNeededExplanation).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func directiveRow(_ d: IgnoredDirective) -> some View {
        Text("\(d.name): \(d.reason)", comment: "Import report item with directive")
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveNotes(for id: ProfileItem.ID?) {
        guard let id, let p = env.profiles.profile(id), p.notes != notes else { return }
        env.actions.setNotes(notes, for: id)
    }

    private var killSwitchFooter: String {
        if !profile.killSwitch {
            return String(localized: "Without the kill switch, a malicious Wi-Fi network can route some traffic around the VPN (TunnelVision).", comment: "Kill switch off footer (§6.4)")
        }
        return profile.isFullTunnel
            ? String(localized: "Blocks all traffic outside the tunnel, including if it drops. If LockPlus's tunnel process crashes, macOS lets traffic through for under 2 seconds until it restarts it.", comment: "Kill switch footer (§6.4); the crash window is S2 E1 (DESIGN §20 risk 24)")
            : String(localized: "Keeps the tunnel's routes in place. Traffic to other destinations is not blocked.", comment: "Route protection footer (§6.4)")
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        LabeledContent(label) { value().textSelection(.enabled) }
    }
}

#Preview("Detail — Work, protected") {
    ProfileDetailView(profile: PreviewData.work)
        .environment(UIEnvironment.preview(row: "6"))
        .frame(width: 680, height: 900)
        .background(BrandCanvasBackground())
}

#Preview("Detail — Acme, OpenVPN, disconnected") {
    ProfileDetailView(profile: PreviewData.acme)
        .environment(UIEnvironment.preview(row: "15", profile: PreviewData.acme))
        .frame(width: 680, height: 900)
        .background(BrandCanvasBackground())
}

#Preview("Detail — Home NAS, split tunnel, dark") {
    ProfileDetailView(profile: PreviewData.nas)
        .environment(UIEnvironment.preview(row: "15", profile: PreviewData.nas))
        .frame(width: 680, height: 800)
        .background(BrandCanvasBackground())
        .preferredColorScheme(.dark)
}
