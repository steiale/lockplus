import SwiftUI

/// The migration from LockPlus 1.x (UI-CONCEPT §6.14 step 4, DESIGN §13.1): the offer, the report, and the sheet that
/// Settings › Advanced "Import from Old LockPlus…" and the main window's "finish" banner open (E2E-5 F4), so the
/// migration is reachable any time, not only from onboarding.

/// The offer: the profiles found, the saved-password opt-in, and Import (or Finish Import for an earlier run that
/// didn't finish).
struct MigrationOfferView: View {
    @Environment(UIEnvironment.self) private var env
    let offer: OnboardingUIModel.MigrationOffer
    @State private var includePasswords = false

    var body: some View {
        @Bindable var ob = env.onboarding
        VStack(alignment: .leading, spacing: 6) {
            if offer.finishesEarlierImport {
                Text("Finish importing from LockPlus 1.x", comment: "Migration offer title when an earlier import didn't finish (E2E-5 F4)").font(.headline)
                Text("An earlier import didn't finish. LockPlus adds what's missing: the remaining profiles, settings, Wi-Fi rules, history and saved logins.",
                     comment: "Migration offer when an earlier import didn't finish (E2E-5 F4)")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Found LockPlus 1.x", comment: "Onboarding migration").font(.headline)
            }
            if !offer.profileNames.isEmpty {
                // E2E-5 F7: a Go item may hold only a username ("Save username"), so it is a saved login, not a password ("sign-in" inflects wrongly).
                Text("^[\(offer.profileNames.count) profile](inflect: true) · ^[\(offer.savedPasswords) saved login](inflect: true)", comment: "Onboarding migration counts (E2E-5 F7)")
                    .foregroundStyle(.secondary)
                // Wraps instead of scrolling sideways (UI-L24).
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading) {
                    ForEach(offer.profileNames, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { ob.migrationSelection.contains(name) },
                                                   set: { if $0 { ob.migrationSelection.insert(name) } else { ob.migrationSelection.remove(name) } }))
                            .toggleStyle(.checkbox)
                    }
                }
                Text("LockPlus copies them. The old LockPlus's files stay as they are.", comment: "Onboarding migration (E2E-5 F7: after a Finder Replace the old app is gone, so it can't \"keep working\")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if offer.savedPasswords > 0 {
                Toggle(isOn: $includePasswords) {
                    Text("Import saved OpenVPN logins", comment: "Onboarding migration opt-in (§6.7, E2E-5 F7)")
                    Text("macOS asks for your login keychain password, usually your Mac login password, once for each: ^[\(offer.savedPasswords) prompt](inflect: true). You can also skip this and enter them on first connect.",
                         comment: "Onboarding migration opt-in explanation (§6.7, E2E-5 F7: the prompt asks for the login keychain password, not just a click)")
                }
                .toggleStyle(.checkbox)
            }
            Button(buttonTitle(selected: ob.migrationSelection.count)) {
                env.actions.importMigration(ob.migrationSelection, includingSavedPasswords: includePasswords)
            }
            .buttonStyle(.lpConnect)
            .disabled((ob.migrationSelection.isEmpty && !offer.finishesEarlierImport) || ob.migrationRunning)   // review M1
            VPNConfigurationHint(includesSavedLogins: includePasswords && offer.savedPasswords > 0)
        }
    }

    private func buttonTitle(selected: Int) -> String {
        if offer.finishesEarlierImport && selected == 0 {
            return String(localized: "Finish Import", comment: "Button: finish an earlier migration with no profiles left to copy (E2E-5 F4)")
        }
        return String(AttributedString(localized: "Import ^[\(selected) Profile](inflect: true)", comment: "Button").characters)
    }
}

/// What the migration did (§6.14 step 4; E2E-5 F6: the whole report): Imported, Needs attention (with the reason),
/// Not migrated, then "Good to know" (harmless ignored lines, appearance, DNS, the per-network map) and the
/// launch-at-login offer.
struct MigrationReportView: View {
    let report: OnboardingUIModel.MigrationReport
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                group(String(localized: "Imported", comment: "Migration report"), report.imported) { ResultGlyph(result: .pass) }
                group(String(localized: "Needs attention", comment: "Migration report"), report.needsAttention) { ResultGlyph(result: .warning) }
                group(String(localized: "Not migrated", comment: "Migration report"), report.notMigrated) { ResultGlyph(result: .unknown) }
                group(String(localized: "Good to know", comment: "Migration report: information, nothing to do (E2E-5 F6)"), report.info + report.notes) {
                    Image(systemName: "info.circle").foregroundStyle(Color.lp.softSage).accessibilityLabel(Text("Information", comment: "Accessibility"))
                }
                if report.offerLaunchAtLogin {
                    // E2E-5 F5: the old app opened at login; LockPlus never registers itself without asking.
                    LaunchAtLoginOfferToggle()
                }
                MigrationFinalNote()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func group<G: View>(_ title: String, _ items: [String], @ViewBuilder glyph: () -> G) -> some View {
        if !items.isEmpty {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            let g = glyph()
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline) { g; Text(item).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// The report's last line (E2E-5 F7): what happens to the old app and its helper, as it is now. The Go v1.2.0
/// "Farewell" removes its own helper when it is installed and opened; until a user has it, LockPlus offers the removal.
struct MigrationFinalNote: View {
    @Environment(UIEnvironment.self) private var env
    var body: some View {
        let helper = env.connection.legacyHelper
        Group {
            if helper != nil || env.connection.legacyHelperRemoval != nil {
                Text("The old LockPlus's helper is still installed. If the old LockPlus offers its update to 1.2, that update removes the helper; otherwise choose “Remove Old Helper…” in the LockPlus window.",
                     comment: "Migration report final note while the Go helper is installed (E2E-5 F7)")
            } else {
                Text("When you're happy, you can delete the old LockPlus if it's still in Applications.", comment: "Migration report final note without a Go helper (E2E-5 F7)")
            }
        }
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// "Open LockPlus at login", for a user whose old LockPlus opened at login (E2E-5 F5).
struct LaunchAtLoginOfferToggle: View {
    @Environment(UIEnvironment.self) private var env
    var body: some View {
        Toggle(isOn: Binding(get: { env.settings.launchAtLogin != .disabled }, set: { env.actions.setLaunchAtLogin($0) })) {
            Text("Open LockPlus at login", comment: "Migration report offer (E2E-5 F5)")
            Text("The old LockPlus opened at login.", comment: "Migration report offer explanation (E2E-5 F5)")
        }
        .toggleStyle(.checkbox)
    }
}

/// E2E-5 F5: LockPlus 1.0.x's LaunchAgent was retired at launch: the main window offers LockPlus's own launch at login.
struct LaunchAtLoginOfferBanner: View {
    @Environment(UIEnvironment.self) private var env
    var body: some View {
        InlineStrip(severity: .info, message: String(localized: "The old LockPlus opened at login. Open LockPlus at login instead?", comment: "Banner (E2E-5 F5)")) {
            Button(String(localized: "Not Now", comment: "Button")) { env.settings.launchAtLoginOffer = false }
            Button(String(localized: "Open at Login", comment: "Button, banner (E2E-5 F5)")) {
                env.actions.setLaunchAtLogin(true)
                env.settings.launchAtLoginOffer = false
            }
        }
    }
}

/// "Import from Old LockPlus" outside onboarding (E2E-5 F4): Settings › Advanced and the main window's banner.
struct MigrationSheet: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Settings › Advanced: always look again (instead of the button clearing the shared offer; pre-release review).
    var rescan = false

    var body: some View {
        let ob = env.onboarding
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Import from Old LockPlus", comment: "Migration sheet title (E2E-5 F4)").font(.title2.weight(.semibold))
            } icon: {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(Color.lp.softSage)
            }
            .accessibilityAddTraits(.isHeader)
            if let report = ob.migrationReport {
                MigrationReportView(report: report)
            } else if ob.migrationChecking {
                HStack { ProgressView().controlSize(.small); Text("Looking for LockPlus 1.x…", comment: "Migration sheet progress (E2E-5 F4)") }
            } else if let offer = ob.migration {
                MigrationOfferView(offer: offer)
            } else {
                Text("There's nothing to import: LockPlus 1.x's profiles aren't on this Mac, or they're all imported already.",
                     comment: "Migration sheet: nothing found (E2E-5 F4)")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(ob.migrationReport == nil ? String(localized: "Cancel", comment: "Button") : String(localized: "Done", comment: "Button")) {
                    env.actions.closeMigration()
                    dismiss()
                }
                .keyboardShortcut(ob.migrationReport == nil ? .cancelAction : .defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 360)
        .task { if rescan || (ob.migration == nil && ob.migrationReport == nil) { env.actions.findOldLockPlusData() } }
    }
}

/// E2E-5 F4: an earlier import didn't finish and onboarding is done: a banner above the detail offers to finish it.
struct MigrationResumeBanner: View {
    @Environment(UIEnvironment.self) private var env
    var body: some View {
        InlineStrip(severity: .info, message: String(localized: "Importing from LockPlus 1.x didn't finish.", comment: "Banner (E2E-5 F4)")) {
            Button(String(localized: "Not Now", comment: "Button")) { env.onboarding.migrationResumePending = false }   // review E2E-5 F4-1
            Button(String(localized: "Finish Import…", comment: "Button, banner (E2E-5 F4)")) { env.onboarding.migrationSheetPresented = true }
        }
    }
}

#Preview("Migration sheet — finish an earlier import") {
    let env = UIEnvironment.preview(row: "15")
    env.onboarding.migration = .init(profileNames: ["ovpn-tcp"], savedPasswords: 2, finishesEarlierImport: true)
    return MigrationSheet().environment(env)
}
