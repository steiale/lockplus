import AppKit
import SwiftUI

/// "Change…" for a saved OpenVPN password (§6.4). Secure fields are cleared on save and on dismiss; the window is
/// excluded from capture.
struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: PasswordChangeRequest
    @State private var username = ""
    @State private var password = ""
    @State private var save = true
    @FocusState private var focusPassword: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text("Change the password for \(request.profileName)", comment: "Change password sheet title").font(.headline) }
                icon: { Image(systemName: "key.fill").foregroundStyle(Color.lp.softSage) }
            LPFormGrid {
                LPFormRow(label: String(localized: "Username", comment: "Field")) {
                    TextField(String(localized: "Username", comment: "Field"), text: $username).labelsHidden().textContentType(.username).lpField()
                }
                LPFormRow(label: String(localized: "Password", comment: "Field")) {
                    SecureField(String(localized: "Password", comment: "Field"), text: $password).labelsHidden()
                        .textContentType(.password).focused($focusPassword).lpField()
                }
            }
            if request.canSaveInKeychain {
                Toggle(String(localized: "Save password in Keychain", comment: "Checkbox"), isOn: $save)
            } else {
                Text("This profile asks LockPlus not to store passwords, so you'll be asked on every connect.", comment: "auth-nocache note")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Button")) { close() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", comment: "Button")) {
                    request.onSave(username, password, request.canSaveInKeychain && save)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(WindowCaptureExclusion())
        .onAppear { username = request.username; focusPassword = true }
        .onDisappear { password = "" }
    }

    private func close() {
        password = ""
        dismiss()
    }
}

/// The revealed password (§6.4 "Show", RevealGate F-10). Shown only after the app's LAContext check; excluded from
/// window capture; closes after 60 s. Copy marks the item concealed and transient and clears it after 60 s.
struct RevealPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let reveal: PasswordReveal
    @State private var secondsLeft = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label { Text("Password for \(reveal.profileName)", comment: "Reveal password sheet title").font(.headline) }
                icon: { Image(systemName: "touchid").foregroundStyle(Color.lp.softSage) }
            LPFormGrid {
                if let user = reveal.username {
                    LPFormRow(label: String(localized: "Username", comment: "Field")) { Text(verbatim: user).textSelection(.enabled) }
                }
                LPFormRow(label: String(localized: "Password", comment: "Field")) {
                    Text(verbatim: reveal.password).font(.body).textSelection(.disabled)
                }
            }
            Text("Closes in \(DurationFormat.seconds(TimeInterval(secondsLeft)))", comment: "Reveal sheet countdown; the argument is like '60 sec'").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            HStack {
                Button(String(localized: "Copy", comment: "Button")) { ConcealedPasteboard.copy(reveal.password) }
                Spacer()
                Button(String(localized: "Done", comment: "Button")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(WindowCaptureExclusion())
        .task {
            while secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                secondsLeft -= 1
            }
            dismiss()
        }
    }
}

/// Copies a secret as concealed + transient (clipboard managers skip it) and clears it after 60 s if unchanged
/// (DESIGN §11.4, F-7).
enum ConcealedPasteboard {
    @MainActor static func copy(_ secret: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(secret, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let count = pb.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}

#Preview("Change password") {
    ChangePasswordSheet(request: PasswordChangeRequest(profileID: PreviewData.acmeID, profileName: "Acme", username: "j.appleseed",
                                                       onSave: { _, _, _ in }))
}

#Preview("Reveal password") {
    RevealPasswordSheet(reveal: PasswordReveal(profileName: "Acme", username: "j.appleseed", password: "correct horse battery"))
}
