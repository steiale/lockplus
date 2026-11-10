import LPModel
import AppKit
import SwiftUI

/// The auth prompt (UI-CONCEPT §6.5, DESIGN §8.4): a sheet on the main window, or a non-activating panel opened
/// from a user gesture (`AuthPanelController`). Never opened by LockPlus on its own. One prompt at a time, keyed by
/// promptID. Secure fields are cleared on submit and on dismiss; the window is excluded from capture.
struct AuthPromptView: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let prompt: AuthPromptState
    /// The panel host closes itself through this; the sheet host uses `dismiss`.
    var onClose: (() -> Void)?

    @State private var username = ""
    @State private var password = ""
    @State private var response = ""
    @State private var savePassword = false
    @State private var expired = false
    @FocusState private var focus: Field?
    private enum Field: Hashable { case username, password, response }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if expired || env.auth.expired {
                Text("The sign-in request expired. Connect again.", comment: "Auth sheet, expired (§6.5)")
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button(String(localized: "OK", comment: "Button")) { close(cancelled: true) }.keyboardShortcut(.defaultAction) }
            } else {
                if let error = env.auth.error {
                    // M5: the last answer didn't arrive; the same prompt is back, still valid.
                    InlineStrip(severity: .critical, message: error)
                }
                form
                buttons
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(WindowCaptureExclusion())
        .onAppear {
            username = prompt.username
            focus = initialFocus
        }
        .onDisappear(perform: clearSecrets)
        .task(id: prompt.id) {
            guard let expiresAt = prompt.expiresAt else { return }
            let wait = expiresAt.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { clearSecrets(); expired = true }
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        switch prompt.kind {
        case .rejected(let reason, _):
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The server rejected the sign-in for \(prompt.profileName).", comment: "Auth sheet, rejected").font(.headline)
                    if let reason { ServerText(text: reason) }
                }
            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.softAmber) }
        case .dynamicChallenge:
            Label { Text("Verification required", comment: "Auth sheet, CRV1 title").font(.headline) } icon: { Image(systemName: "key.fill").foregroundStyle(Color.lp.softSage) }
        case .keyPassphrase:
            Label { Text("Unlock the key for \(prompt.profileName)", comment: "Auth sheet, key passphrase").font(.headline) } icon: { Image(systemName: "key.fill").foregroundStyle(Color.lp.softSage) }
        default:
            Label { Text("Sign in to \(prompt.profileName)", comment: "Auth sheet title").font(.headline) } icon: { Image(systemName: "key.fill").foregroundStyle(Color.lp.softSage) }
        }
    }

    // MARK: Form

    @ViewBuilder private var form: some View {
        switch prompt.kind {
        case .password(let otp), .rejected(_, let otp):
            LPFormGrid {
                credentialRows
                if otp { responseRow(String(localized: "One-time code", comment: "Field"), echo: true) }
            }
            saveToggle(otp: otp)
        case .staticChallenge(let challenge):
            LPFormGrid {
                credentialRows
                GridRow { ServerText(text: challenge.text).gridCellColumns(2) }
                responseRow(String(localized: "Response", comment: "Field"), echo: challenge.echo)
            }
            saveToggle(otp: false)
        case .dynamicChallenge(let text, let echo):
            if prompt.notice == .codeExpiredFreshChallenge {
                InlineStrip(severity: .attention, message: String(localized: "The code was not accepted or has expired. Enter the new code.", comment: "CRV1 fresh challenge (§6.5)"))
            }
            if !prompt.username.isEmpty {
                Text("Signed in as \(prompt.username)", comment: "CRV1 read-only username").foregroundStyle(.secondary)
            }
            ServerText(text: text)
            LPFormGrid { responseRow(String(localized: "Response", comment: "Field"), echo: echo) }
            Text("This code is valid for 5 minutes.", comment: "CRV1 validity (§6.5, S8)").font(.caption).foregroundStyle(.secondary)
        case .keyPassphrase:
            LPFormGrid {
                LPFormRow(label: String(localized: "Passphrase", comment: "Field")) {
                    SecureField(String(localized: "Passphrase", comment: "Field"), text: $password).labelsHidden().focused($focus, equals: .password).lpField()
                }
            }
            Toggle(String(localized: "Save passphrase in Keychain", comment: "Checkbox"), isOn: $savePassword)
        case .waitingForApproval(let tooLate):
            if tooLate {
                Text("Approval took too long. Try again to get a new request.", comment: "AUTH_PENDING timed out (§6.5)")
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in approval…", comment: "AUTH_PENDING (§6.5)")
                }
                Text("Approve the request on your phone or authenticator.", comment: "AUTH_PENDING hint").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Username and Password rows (inside an `LPFormGrid`, so every field in the sheet shares one leading edge).
    @ViewBuilder private var credentialRows: some View {
        LPFormRow(label: String(localized: "Username", comment: "Field")) {
            TextField(String(localized: "Username", comment: "Field"), text: $username)
                .labelsHidden()
                .textContentType(.username)
                .focused($focus, equals: .username)
                .lpField()
        }
        LPFormRow(label: String(localized: "Password", comment: "Field")) {
            SecureField(String(localized: "Password", comment: "Field"), text: $password)
                .labelsHidden()
                .textContentType(.password)
                .focused($focus, equals: .password)
                .lpField()
        }
    }

    @ViewBuilder private func responseRow(_ label: String, echo: Bool) -> some View {
        LPFormRow(label: label) {
            Group {
                if echo { TextField(label, text: $response) } else { SecureField(label, text: $response) }
            }
            .labelsHidden()
            .textContentType(.oneTimeCode)
            .focused($focus, equals: .response)
            .lpField()
        }
    }

    @ViewBuilder private func saveToggle(otp: Bool) -> some View {
        if prompt.canSavePassword {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(String(localized: "Save password in Keychain", comment: "Checkbox"), isOn: $savePassword)
                if otp {
                    Text("The code is never saved.", comment: "OTP note (§6.5)").font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                }
            }
        }
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel", comment: "Button")) { close(cancelled: true) }
                .keyboardShortcut(.cancelAction)
            switch prompt.kind {
            case .waitingForApproval(let tooLate):
                if tooLate {
                    Button(String(localized: "Try Again", comment: "Button")) { env.actions.retryAuthApproval(prompt.id) }
                        .keyboardShortcut(.defaultAction)
                }
            case .dynamicChallenge:
                Button(String(localized: "Verify", comment: "Button")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(response.isEmpty)
            case .rejected:
                Button(String(localized: "Try Again", comment: "Button")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            default:
                Button(String(localized: "Connect", comment: "Button")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
    }

    private var canSubmit: Bool {
        switch prompt.kind {
        case .password(let otp): !password.isEmpty && (!otp || !response.isEmpty)
        case .staticChallenge: !password.isEmpty && !response.isEmpty
        case .keyPassphrase: !password.isEmpty
        default: true
        }
    }

    private var initialFocus: Field {
        switch prompt.kind {
        case .dynamicChallenge: .response
        case .keyPassphrase: .password
        default: prompt.username.isEmpty ? .username : .password
        }
    }

    private func submit() {
        env.actions.submitAuth(AuthAnswer(promptID: prompt.id, username: username, password: password,
                                          response: response, savePassword: savePassword))
        clearSecrets()
        dismiss()
        onClose?()
    }

    private func close(cancelled: Bool) {
        if cancelled { env.actions.cancelAuth(prompt.id) }
        clearSecrets()
        dismiss()
        onClose?()
    }

    private func clearSecrets() {
        password = ""
        response = ""
    }
}

/// The server's own text, verbatim, in quotes and marked as coming from the server (§8.3).
struct ServerText: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "“\(Self.sanitize(text))”").italic()
                .lineLimit(4)
                .layoutPriority(-1)                 // the marker never gets squeezed out
            Text("(server)", comment: "Marks server-provided text").font(.caption).foregroundStyle(.secondary)
                .fixedSize()
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// Server-controlled text (Fable L8): no C0/C1 controls, no bidi overrides/isolates/marks, newlines collapsed to
    /// spaces, at most 256 characters, so it can't spoof the dialog's own wording or hide the "(server)" marker.
    static let maxLength = 256
    static func sanitize(_ raw: String) -> String {
        let bidi: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let isNewlineLike = scalar == "\n" || scalar == "\r" || v == 0x2028 || v == 0x2029 || v == 0x85
            if isNewlineLike || scalar == "\t" || scalar == " " {
                if !lastWasSpace, !out.isEmpty { out.append(" ") }
                lastWasSpace = true
                continue
            }
            if v < 0x20 || (0x7F...0x9F).contains(v) || bidi.contains(v) { continue }
            out.append(scalar)
            lastWasSpace = false
        }
        var s = String(out).trimmingCharacters(in: .whitespaces)
        if s.count > maxLength { s = String(s.prefix(maxLength - 1)) + "…" }
        return s
    }
}

/// Excludes the hosting window from window-server capture (`sharingType = .none`, DESIGN §11.4 F-7).
struct WindowCaptureExclusion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CaptureExcludingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class CaptureExcludingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.sharingType = .none
        }
    }
}

/// Hosts the prompt in a small non-activating panel anchored to the user's gesture (§6.5), for when the main
/// window isn't visible. Call only from a user action (menu item, notification click, Dock).
@MainActor final class AuthPanelController {
    private var panel: NSPanel?

    func show(prompt: AuthPromptState, env: UIEnvironment, near point: NSPoint? = nil) {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentViewController = NSHostingController(rootView: AuthPromptView(prompt: prompt, onClose: { [weak self] in self?.close() }).environment(env).lpTypography())
        if let point {
            panel.setFrameTopLeftPoint(NSPoint(x: point.x - 210, y: point.y - 8))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private extension UIEnvironment {
    static func previewPrompt(_ kind: AuthPromptState.Kind, username: String = "j.appleseed", notice: AuthPromptState.Notice? = nil) -> UIEnvironment {
        .preview(row: "13b", profile: PreviewData.acme,
                 prompt: AuthPromptState(id: UUID(), profileName: "Acme", kind: kind, username: username, notice: notice))
    }
}

#Preview("Auth — password + OTP") {
    let env = UIEnvironment.previewPrompt(.password(oneTimeCode: true))
    return AuthPromptView(prompt: env.auth.prompt!).environment(env)
}

#Preview("Auth — static challenge") {
    let env = UIEnvironment.previewPrompt(.staticChallenge(StaticChallenge(text: "Enter your Authenticator code", echo: true, concat: false)))
    return AuthPromptView(prompt: env.auth.prompt!).environment(env)
}

#Preview("Auth — CRV1") {
    let env = UIEnvironment.previewPrompt(.dynamicChallenge(text: "Enter the code sent to ••42", echo: false))
    return AuthPromptView(prompt: env.auth.prompt!).environment(env)
}

#Preview("Auth — CRV1 fresh challenge") {
    let env = UIEnvironment.previewPrompt(.dynamicChallenge(text: "Enter the code sent to ••42", echo: false), notice: .codeExpiredFreshChallenge)
    return AuthPromptView(prompt: env.auth.prompt!).environment(env)
}

#Preview("Auth — rejected") {
    let env = UIEnvironment.previewPrompt(.rejected(serverReason: "Invalid OTP", oneTimeCode: true))
    return AuthPromptView(prompt: env.auth.prompt!).environment(env)
}

#Preview("Auth — waiting for approval") {
    let env = UIEnvironment.previewPrompt(.waitingForApproval(tooLate: false))
    return AuthPromptView(prompt: env.auth.prompt!).environment(env)
}

#Preview("Auth — approval too late") {
    let env = UIEnvironment.previewPrompt(.waitingForApproval(tooLate: true))
    return AuthPromptView(prompt: env.auth.prompt!).environment(env)
}

#Preview("Auth — key passphrase") {
    let env = UIEnvironment.previewPrompt(.keyPassphrase)
    return AuthPromptView(prompt: env.auth.prompt!).environment(env)
}

#Preview("Auth — expired") {
    let env = UIEnvironment.previewPrompt(.dynamicChallenge(text: "Enter the code sent to ••42", echo: false))
    env.auth.expired = true
    return AuthPromptView(prompt: env.auth.prompt!).environment(env)
}
