import SwiftUI

/// First-run onboarding (UI-CONCEPT §6.14, DESIGN §11.1): a 600×480 sheet, five steps, one primary button each.
/// The app skips steps that are already satisfied by setting `OnboardingUIModel.step`.
struct OnboardingSheet: View {
    @Environment(UIEnvironment.self) private var env

    var body: some View {
        let ob = env.onboarding
        VStack(spacing: 0) {
            Group {
                switch ob.step {
                case .welcome: WelcomeStep()
                case .installExtension: InstallExtensionStep()
                case .allowConfiguration: AllowConfigurationStep()
                case .profiles: ProfilesStep()
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            PageIndicator(current: ob.step.rawValue, count: OnboardingUIModel.Step.allCases.count)
                .padding(.bottom, 14)
        }
        // §6.14 size as the minimum; German copy may need more height (UI-M17).
        .frame(minWidth: 600, idealWidth: 600, maxWidth: 680, minHeight: 480)
        // 2.0.1 E2E F5: step 4's imports present their preview and errors on top of this sheet (the main window's
        // sheet and alert can't while onboarding is shown).
        .sheet(item: Binding(get: { MainSheet.nested(in: env) }, set: { new in
            if new == nil, let shown = MainSheet.nested(in: env) { shown.clear(in: env) }
        })) { sheet in sheet.content }
        .alert(Text("Can't Import", comment: "Import error alert title"),
               isPresented: Binding(get: { env.importer.errorMessage != nil }, set: { if !$0 { env.importer.errorMessage = nil } })) {
            Button(String(localized: "OK", comment: "Button")) {}
        } message: {
            Text(env.importer.errorMessage ?? "")
        }
    }
}

private struct PageIndicator: View {
    let current: Int
    let count: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.lp.softSage : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(current + 1) of \(count)", comment: "Onboarding page indicator"))
    }
}

private struct StepScaffold<Content: View, Buttons: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(title).font(.title2.weight(.semibold))
            } icon: {
                Image(systemName: symbol).foregroundStyle(Color.lp.softSage)
            }
            .accessibilityAddTraits(.isHeader)
            content()
            Spacer(minLength: 0)
            HStack { Spacer(); buttons() }
        }
    }
}

// MARK: 1 Welcome

private struct WelcomeStep: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var landed = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            // The app icon (§7.1): the tile springs in, then the padlock is set down on it and its shadow grows.
            // Reduce Motion: one plain fade, lock already in place.
            AppIconTile(size: 120, landed: landed || reduceMotion)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown || reduceMotion ? 1 : 0.85)
            Text("Welcome to LockPlus", comment: "Onboarding title").font(.largeTitle.weight(.semibold))
            Text("WireGuard and OpenVPN, native on your Mac.", comment: "Onboarding subtitle").font(.title3).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button(String(localized: "Get Started", comment: "Button")) { env.onboarding.step = .installExtension }
                    .buttonStyle(.lpConnect)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task {
            withAnimation(reduceMotion ? .linear(duration: 0.15) : .spring(duration: 0.45, bounce: 0.2)) { shown = true }
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.spring(duration: 0.55, bounce: 0.35)) { landed = true }
        }
    }
}

// MARK: 2 Install the tunnel component

private struct InstallExtensionStep: View {
    @Environment(UIEnvironment.self) private var env

    var body: some View {
        let state = env.onboarding.extensionStep
        StepScaffold(symbol: "puzzlepiece.extension", title: String(localized: "Install the tunnel component", comment: "Onboarding step 2")) {
            Text("LockPlus runs its VPN engine as a macOS system extension. macOS will ask you to allow it once.", comment: "Onboarding step 2")
                .fixedSize(horizontal: false, vertical: true)
            switch state {
            case .idle:
                EmptyView()
            case .requesting:
                HStack { ProgressView().controlSize(.small); Text("Installing…", comment: "Onboarding step 2 state") }
            case .needsApproval:
                VStack(alignment: .leading, spacing: 8) {
                    HStack { ProgressView().controlSize(.small); Text("Waiting for approval…", comment: "Onboarding step 2 state") }
                    Text("System Settings › General › Login Items & Extensions", comment: "Onboarding step 2 path").foregroundStyle(.secondary)
                    Text("If the switch turned itself off, turn it on again.", comment: "Onboarding step 2, macOS 27 hint (§6.14)").foregroundStyle(.secondary)
                }
            case .rebootRequired:
                InlineStrip(severity: .attention, message: String(localized: "Restart your Mac to finish.", comment: "Onboarding step 2, will complete after reboot"))
            case .failed(let message):
                InlineStrip(severity: .critical, message: message)
            case .done:
                Label { Text("Installed", comment: "Onboarding step 2 state") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.lp.softSage) }
            }
        } buttons: {
            switch state {
            case .idle, .requesting:
                Button(String(localized: "Install", comment: "Button")) { env.actions.installExtension() }
                    .buttonStyle(.lpConnect).keyboardShortcut(.defaultAction).disabled(state == .requesting)
            case .needsApproval:
                // Persistent secondary "Show the Switch Again" (§6.14): the first toggle may not stick on 27.
                Button(String(localized: "Show the Switch Again", comment: "Button (§6.14)")) { env.actions.perform(.showSwitchAgain) }   // re-requests activation, then opens the pane (UI-L20)
                Button(String(localized: "Open System Settings", comment: "Button")) { SystemSettingsLink.open(SystemSettingsLink.networkExtensions) }
                    .buttonStyle(.lpConnect).keyboardShortcut(.defaultAction)
            case .rebootRequired:
                Button(String(localized: "Restart Later", comment: "Button")) { env.onboarding.step = .allowConfiguration }
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button(String(localized: "Get Help", comment: "Button")) { NSWorkspace.shared.open(LockPlusLinks.issues) }
                Button(String(localized: "Try Again", comment: "Button")) { env.actions.installExtension() }
                    .buttonStyle(.lpConnect).keyboardShortcut(.defaultAction)
            case .done:
                Button(String(localized: "Continue", comment: "Button")) { env.onboarding.step = .allowConfiguration }
                    .buttonStyle(.lpConnect).keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: 3 Allow VPN configuration

private struct AllowConfigurationStep: View {
    @Environment(UIEnvironment.self) private var env

    var body: some View {
        let state = env.onboarding.configurationStep
        StepScaffold(symbol: "lock.shield", title: String(localized: "Allow VPN configuration", comment: "Onboarding step 3")) {
            // Explained BEFORE saveToPreferences triggers the system alert (§6.14).
            if OnboardingUIModel.asksAtFirstProfile(profileCount: env.profiles.profiles.count, configurationExists: env.connection.vpnConfigurationExists) {
                Text("macOS asks for this when LockPlus adds your first profile, in the next step. Choose “Allow” then.", comment: "Onboarding step 3 when there is no profile yet: the system alert comes with the first import")
                    .fixedSize(horizontal: false, vertical: true)
            } else if env.profiles.profiles.isEmpty {
                Text("macOS has already allowed LockPlus to add VPN configurations.", comment: "Onboarding step 3 with no profile but an existing VPN configuration: nothing more to allow")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Next, macOS asks whether LockPlus may add VPN configurations. Choose “Allow”.", comment: "Onboarding step 3")
                    .fixedSize(horizontal: false, vertical: true)
            }
            SystemAlertIllustration()
            if state == .denied {
                InlineStrip(severity: .attention, message: String(localized: "LockPlus can't connect without this.", comment: "Onboarding step 3, denied"))
            }
            if case .deferred(let message) = state {
                InlineStrip(severity: .info, message: message)
            }
        } buttons: {
            switch state {
            case .explain, .requesting:
                Button(String(localized: "Continue", comment: "Button")) { env.actions.allowVPNConfiguration() }
                    .buttonStyle(.lpConnect).keyboardShortcut(.defaultAction).disabled(state == .requesting)
            case .denied:
                Button(String(localized: "Try Again", comment: "Button")) { env.actions.allowVPNConfiguration() }
                    .buttonStyle(.lpConnect).keyboardShortcut(.defaultAction)
            case .done, .deferred:
                Button(String(localized: "Continue", comment: "Button")) { env.onboarding.step = .profiles }
                    .buttonStyle(.lpConnect).keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Next to an import button while no profile exists yet: the system's "add VPN configurations" alert comes with the
/// first import. With saved logins the keychain prompts follow (described by the opt-in above, not repeated).
struct VPNConfigurationHint: View {
    @Environment(UIEnvironment.self) private var env
    let includesSavedLogins: Bool

    static func isVisible(profileCount: Int, configurationExists: Bool = false) -> Bool {
        OnboardingUIModel.asksAtFirstProfile(profileCount: profileCount, configurationExists: configurationExists)
    }

    var body: some View {
        if Self.isVisible(profileCount: env.profiles.profiles.count, configurationExists: env.connection.vpnConfigurationExists) {
            Group {
                if includesSavedLogins {
                    Text("macOS will ask to add VPN configurations first: choose “Allow”. The keychain prompts follow.", comment: "Onboarding step 4 hint by the import button, with saved logins included")
                } else {
                    Text("macOS will ask to add VPN configurations: choose “Allow”.", comment: "Onboarding step 4 hint by the import button")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A drawn stand-in for the system alert, so the real one isn't a surprise.
private struct SystemAlertIllustration: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.badge.shield.half.filled").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("“LockPlus” Would Like to Add VPN Configurations", comment: "Illustration of the system alert").font(.callout.weight(.semibold)).multilineTextAlignment(.center)
            HStack {
                Text("Don't Allow", comment: "Illustration of the system alert button").padding(.horizontal, 10).padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Text("Allow", comment: "Illustration of the system alert button").padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.white)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Illustration of the macOS alert asking to add VPN configurations, with the Allow button", comment: "Accessibility"))
    }
}

// MARK: 4 Bring your profiles

private struct ProfilesStep: View {
    @Environment(UIEnvironment.self) private var env
    @State private var showTip = false

    var body: some View {
        @Bindable var ob = env.onboarding
        StepScaffold(symbol: "tray.and.arrow.down", title: String(localized: "Bring your profiles", comment: "Onboarding step 4")) {
            if let report = ob.migrationReport {
                MigrationReportView(report: report)
            } else {
                if let m = ob.migration {
                    MigrationOfferView(offer: m)
                    Text("You can also import from the old LockPlus later, in Settings › Advanced.", comment: "Onboarding migration: skipping isn't final (E2E-5 F4)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { VStack { Divider() }; Text("or", comment: "Separator").foregroundStyle(.secondary); VStack { Divider() } }
                }
                Button(String(localized: "Choose Files…", comment: "Button")) { ImportPanel.run(env) }
                if ob.migration == nil { VPNConfigurationHint(includesSavedLogins: false) }
                if ob.etcWireGuardCount > 0 {
                    HStack {
                        Text("Found ^[\(ob.etcWireGuardCount) profile](inflect: true) in /etc/wireguard", comment: "Onboarding scan result")
                        Button(String(localized: "Add", comment: "Button")) { env.actions.addEtcWireGuardProfiles() }
                    }
                }
                DisclosureGroup(String(localized: "Coming from the WireGuard app?", comment: "Disclosure"), isExpanded: $showTip) {
                    Text("In WireGuard, choose Export Tunnels to Zip, then choose that file here.", comment: "WireGuard App Store tip (§6.14)")
                        .foregroundStyle(.secondary)
                }
            }
        } buttons: {
            Button(String(localized: "Continue", comment: "Button")) { env.onboarding.step = .done }
                .buttonStyle(.lpConnect).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: 5 Done

private struct DoneStep: View {
    @Environment(UIEnvironment.self) private var env
    @State private var callout = StatusItemCallout()
    /// nil until checked; false when the status item can't be located (hidden, overflow, notch).
    @State private var located: Bool?

    var body: some View {
        StepScaffold(symbol: "menubar.arrow.up.rectangle", title: String(localized: "LockPlus lives in your menu bar", comment: "Onboarding step 5")) {
            HStack(alignment: .top, spacing: 16) {
                Image("lockplus.lock.open").font(.system(size: 36)).foregroundStyle(Color.lp.softSage)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Click the lock in the menu bar to connect, switch profiles or pause protection.", comment: "Onboarding step 5")
                    Text("LockPlus tells you when protection stops unexpectedly.", comment: "Notification permission explanation (§6.13)")
                        .foregroundStyle(.secondary)
                    if located == false {
                        InlineStrip(severity: .info, message: String(localized: "Can't see the lock? The menu bar may be full, or the icon is hidden. Open LockPlus from the Dock, or turn it on in System Settings › Menu Bar.", comment: "Onboarding step 5 fallback when the status item can't be located"))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { located = callout.show() }
            .onDisappear { callout.hide() }
        } buttons: {
            Button(String(localized: "Done", comment: "Button")) {
                // The one-time notification request comes last (§6.13).
                env.actions.requestNotificationPermission()
                env.actions.finishOnboarding()
            }
            .buttonStyle(.lpConnect).keyboardShortcut(.defaultAction)
        }
    }
}

private extension UIEnvironment {
    static func onboardingPreview(_ step: OnboardingUIModel.Step, _ configure: (OnboardingUIModel) -> Void = { _ in }) -> UIEnvironment {
        let env = UIEnvironment.preview(row: "1")
        env.onboarding.step = step
        configure(env.onboarding)
        return env
    }
}

#Preview("Onboarding 1 — welcome") { OnboardingSheet().environment(UIEnvironment.onboardingPreview(.welcome)) }
#Preview("Onboarding 2 — needs approval") {
    OnboardingSheet().environment(UIEnvironment.onboardingPreview(.installExtension) { $0.extensionStep = .needsApproval })
}
#Preview("Onboarding 2 — reboot") {
    OnboardingSheet().environment(UIEnvironment.onboardingPreview(.installExtension) { $0.extensionStep = .rebootRequired })
}
#Preview("Onboarding 2 — failed") {
    OnboardingSheet().environment(UIEnvironment.onboardingPreview(.installExtension) { $0.extensionStep = .failed("The extension couldn't be activated (code 4).") })
}
#Preview("Onboarding 3 — explain") { OnboardingSheet().environment(UIEnvironment.onboardingPreview(.allowConfiguration)) }
#Preview("Onboarding 3 — denied") {
    OnboardingSheet().environment(UIEnvironment.onboardingPreview(.allowConfiguration) { $0.configurationStep = .denied })
}
#Preview("Onboarding 4 — migration") {
    OnboardingSheet().environment(UIEnvironment.onboardingPreview(.profiles) {
        $0.migration = .init(profileNames: ["Work", "Home NAS", "Acme", "Globex", "Lab", "Test"], savedPasswords: 2)
        $0.migrationSelection = ["Work", "Home NAS", "Acme", "Globex", "Lab", "Test"]
        $0.etcWireGuardCount = 2
    })
}
#Preview("Onboarding 4 — report") {
    OnboardingSheet().environment(UIEnvironment.onboardingPreview(.profiles) {
        $0.migrationReport = .init(imported: ["Work", "Home NAS", "Acme"], needsAttention: ["Globex: OVPN profile uses `up` script: ignored"],
                                   notMigrated: ["Per-network profile map", "Global DNS protection"])
    })
}
#Preview("Onboarding 5 — done") { OnboardingSheet().environment(UIEnvironment.onboardingPreview(.done)) }
