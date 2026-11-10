import SwiftUI

/// §6.8 "Profiles from another Mac are locked": the profile files are here, but the key that seals them isn't (a
/// restore or migration to another Mac). Shown in place of the empty library while `ProfilesUIModel.locked` is set.
/// The names come from unverified metadata: display only, never used to act on a profile.
struct LockedProfilesView: View {
    @Environment(UIEnvironment.self) private var env
    let names: [String]
    @State private var confirmRemove = false
    @State private var confirmStartOver = false
    @State private var confirmMigrate = false

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Profiles from another Mac are locked", comment: "Locked profiles title (§6.8)")
            } icon: {
                Image("lockplus.lock.closed").font(.system(size: 64)).foregroundStyle(Color.lp.softAmber)
            }
        } description: {
            VStack(spacing: 10) {
                Text("These profiles were sealed on another Mac and can't be opened here. Import the original profile files again, or remove the locked profiles.",
                     comment: "Locked profiles description (§6.8)")
                    .fixedSize(horizontal: false, vertical: true)
                if !names.isEmpty {
                    Text(names.formatted(.list(type: .and)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .accessibilityLabel(Text("Locked profiles: \(names.formatted(.list(type: .and)))", comment: "Accessibility label; the argument is a list of names"))
                }
            }
        } actions: {
            Button(String(localized: "Re-import…", comment: "Button, locked profiles (§6.8)")) { confirmStartOver = true }
                .buttonStyle(.lpConnect)
            // §6.8 third action: only when the old (Go) LockPlus left data to migrate (`OnboardingUIModel.migration`).
            if env.onboarding.migration != nil {
                Button(LockedProfilesCopy.migrateButton) { confirmMigrate = true }
            }
            Button(String(localized: "Remove Locked Profiles…", comment: "Button, locked profiles (§6.8)"), role: .destructive) {
                confirmRemove = true
            }
        }
        .confirmationDialog(Text(LockedProfilesCopy.startOverTitle), isPresented: $confirmStartOver) {
            Button(LockedProfilesCopy.startOverButton) { env.actions.startOverAndReimport() }
        } message: {
            Text(LockedProfilesCopy.startOverMessage)
        }
        .confirmationDialog(Text(LockedProfilesCopy.startOverTitle), isPresented: $confirmMigrate) {
            Button(LockedProfilesCopy.startOverMigrateButton) { env.actions.startOverAndImportFromOldApp() }
        } message: {
            Text(LockedProfilesCopy.startOverMigrateMessage)
        }
        .confirmationDialog(Text(LockedProfilesCopy.confirmTitle(count: names.count)), isPresented: $confirmRemove) {
            Button(String(localized: "Remove", comment: "Button, remove locked profiles"), role: .destructive) {
                env.actions.removeLockedProfiles()
            }
        } message: {
            Text("Their files and saved passwords are deleted from this Mac. This can't be undone.", comment: "Remove locked profiles confirmation message")
        }
    }
}

enum LockedProfilesCopy {
    static var startOverTitle: String { String(localized: "Start over?", comment: "Re-import confirmation title, locked profiles (§6.8)") }
    static var startOverMessage: String {
        String(localized: "The locked profiles are moved to a folder next to your profiles, and LockPlus creates a new key. Then choose the original profile files to import.",
               comment: "Re-import confirmation message, locked profiles (§6.8)")
    }
    static var startOverButton: String { String(localized: "Start Over and Import…", comment: "Button, re-import confirmation (§6.8)") }
    static var migrateButton: String { String(localized: "Import from Old LockPlus…", comment: "Button, locked profiles, shown when LockPlus 1.x data exists (§6.8, §13.1)") }
    static var startOverMigrateMessage: String {
        String(localized: "The locked profiles are moved to a folder next to your profiles, and LockPlus creates a new key. Then choose the profiles to import from the old LockPlus.",
               comment: "Import-from-old-LockPlus confirmation message, locked profiles (§6.8)")
    }
    static var startOverMigrateButton: String { String(localized: "Start Over and Import from Old LockPlus…", comment: "Button, import-from-old-LockPlus confirmation (§6.8)") }
    static func confirmTitle(count: Int) -> String {
        String(AttributedString(localized: "Remove ^[\(count) locked profile](inflect: true)?", comment: "Remove locked profiles confirmation title").characters)
    }
    /// Menu bar primary item while the library is locked (opens the main window).
    static var menuItem: String { String(localized: "Profiles Are Locked…", comment: "Menu item, locked profiles (§6.8)") }
}

#Preview("Locked profiles") {
    let env = UIEnvironment.preview(row: "15", profiles: [])
    env.profiles.locked = ["Work", "Home NAS", "Acme"]
    env.onboarding.migration = .init(profileNames: ["Work", "Home NAS"], savedPasswords: 1)
    return LockedProfilesView(names: ["Work", "Home NAS", "Acme"]).environment(env).frame(width: 600, height: 460)
}
