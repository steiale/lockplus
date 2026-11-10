import AppKit
import LPModel
import SwiftUI

/// The editor window content (UI-CONCEPT §6.9): buffer with gutter, inspector with Issues and Reference, Revert and
/// Save ⌘S. Save is disabled while errors exist (the tooltip says why). Closing with edits asks first; saving a
/// connected profile asks "Save and reconnect?". The window is excluded from capture and never restored.
struct EditorWindow: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.profileEditorBackend) private var backend
    @Environment(\.dismiss) private var dismiss
    @State private var model: EditorModel
    @State private var showInspector = true
    @State private var confirmReconnect = false
    @State private var confirmRevert = false

    init(target: EditorTarget?) {
        _model = State(initialValue: EditorModel(target: target ?? .new(.wireGuard)))
    }

    /// Previews and tests: start from a document without a backend.
    init(model: EditorModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label(String(localized: "Can't Open the Profile", comment: "Editor load error"), systemImage: "exclamationmark.triangle")
                } description: { Text(message) }
            case .ready:
                editor
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(title)
        .background(EditorWindowConfigurator(model: model, saveForClose: {
            // Closing never needs the reconnect question: save only; the user reconnects when ready.
            await model.save(mode: .saveOnly, using: backend)
        }))
        .task(id: model.target.profileID) {
            if model.phase == .loading { await model.load(using: backend) }
        }
        .onAppear { EditorRegistry.shared.register(model) }
        .onDisappear {
            EditorRegistry.shared.unregister(model)
            model.discard()
        }
    }

    private var title: String {
        let proto = model.kind == .wireGuard ? String(localized: "WireGuard", comment: "Protocol name") : String(localized: "OpenVPN", comment: "Protocol name")
        let name = model.name.isEmpty ? String(localized: "New Profile", comment: "Editor title for a new profile") : model.name
        return String(localized: "\(name) — \(proto)", comment: "Editor window title, e.g. 'Work — WireGuard'")
    }

    private var isConnected: Bool {
        guard let id = model.target.profileID else { return false }
        return env.connection.profileID == id && env.connection.condition.isActive
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if model.isNew {
                LPFormGrid {
                    LPFormRow(label: String(localized: "Name", comment: "Field")) {
                        TextField(String(localized: "Name", comment: "Field"), text: $model.name).labelsHidden().lpField()
                    }
                }
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
            }
            if let error = model.saveError {
                InlineStrip(severity: .critical, message: error).padding(8)
            }
            if case .rejected(let reason) = model.engine {
                InlineStrip(severity: .critical, message: reason).padding(8)
            }
            ConfigTextView(model: model)
        }
        .inspector(isPresented: $showInspector) {
            EditorInspector(model: model)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .toolbar {
            ToolbarItem {
                Button(model.keyRevealed ? String(localized: "Hide Keys", comment: "Editor toolbar") : String(localized: "Show Keys", comment: "Editor toolbar")) {
                    model.keyRevealed.toggle()
                }
                .help(String(localized: "Keys are masked against shoulder surfing.", comment: "Tooltip"))
                .disabled(model.analysis.secretLines.isEmpty)
            }
            ToolbarItem {
                Button(String(localized: "Revert", comment: "Editor toolbar")) { confirmRevert = true }
                    .disabled(!model.isDirty)
            }
            ToolbarItem {
                Button { showInspector.toggle() } label: {
                    Label(String(localized: "Inspector", comment: "Editor toolbar"), systemImage: "sidebar.right")
                }
                .help(String(localized: "Show or hide issues and reference", comment: "Tooltip"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Save", comment: "Editor toolbar")) { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave)
                    .help(model.saveDisabledReason ?? "")
            }
        }
        .confirmationDialog(Text("Revert to the saved version?", comment: "Editor revert confirmation"), isPresented: $confirmRevert) {
            Button(String(localized: "Revert", comment: "Button"), role: .destructive) { model.revert() }
        } message: {
            Text("Your changes are replaced by the saved version. You can undo this with ⌘Z.", comment: "Editor revert confirmation message")
        }
        .confirmationDialog(Text("\(model.name) is connected. Save and reconnect?", comment: "Editor save confirmation (§6.9)"),
                            isPresented: $confirmReconnect) {
            Button(String(localized: "Save and Reconnect", comment: "Button")) { Task { await model.save(mode: .saveAndReconnect, using: backend) } }
            Button(String(localized: "Save Only", comment: "Button")) { Task { await model.save(mode: .saveOnly, using: backend) } }
            Button(String(localized: "Cancel", comment: "Button"), role: .cancel) {}
        }
    }

    private func save() {
        guard model.canSave else { return }
        if isConnected { confirmReconnect = true } else { Task { await model.save(mode: .saveOnly, using: backend) } }
    }
}

/// Issues (click to jump) and Reference for the key under the caret (§6.9). Issues also get a VoiceOver rotor.
struct EditorInspector: View {
    let model: EditorModel

    var body: some View {
        List {
            Section {
                if model.analysis.issues.isEmpty {
                    Label { Text("No issues", comment: "Editor inspector") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.lp.softSage) }
                }
                ForEach(model.analysis.issues) { issue in
                    Button {
                        if let l = issue.line { model.jumpRequest = l }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            IssueGlyph(severity: issue.severity)
                            VStack(alignment: .leading, spacing: 2) {
                                if let l = issue.line { Text("Line \(l)", comment: "Editor issue line").font(.caption).foregroundStyle(.secondary) }
                                Text(issue.message).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .id(issue.id)
                }
            } header: {
                Text("Issues (\(model.analysis.issues.filter { $0.severity >= .warning }.count))", comment: "Editor inspector section")
            }
            .accessibilityRotor(Text("Issues", comment: "VoiceOver rotor")) {
                ForEach(model.analysis.issues) { issue in
                    AccessibilityRotorEntry(Text(issue.message), id: issue.id)
                }
            }

            Section {
                if model.kind == .openVPN {
                    EngineCheckRow(state: model.engine)
                }
                if let key = model.referenceKey, let entry = EditorReference.entry(for: key, kind: model.kind) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: key).font(.headline)
                        Text(entry).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Move the caret to a key to see what it does.", comment: "Editor reference placeholder").foregroundStyle(.secondary)
                }
            } header: {
                Text("Reference", comment: "Editor inspector section")
            }
        }
    }
}

private struct IssueGlyph: View {
    let severity: EditorIssue.Severity
    var body: some View {
        switch severity {
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.lp.softRose).accessibilityLabel(Text("Error", comment: "Issue severity"))
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.softAmber).accessibilityLabel(Text("Warning", comment: "Issue severity"))
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityLabel(Text("Note", comment: "Issue severity"))
        }
    }
}

private struct EngineCheckRow: View {
    let state: EditorModel.EngineState
    var body: some View {
        switch state {
        case .notChecked:
            Label { Text("The OpenVPN engine checks the profile when you save.", comment: "Editor engine check") } icon: { Image(systemName: "questionmark.circle") }
                .foregroundStyle(.secondary)
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking with the OpenVPN engine…", comment: "Editor engine check") }
        case .passed:
            Label { Text("Accepted by the OpenVPN engine", comment: "Editor engine check") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.lp.softSage) }
        case .rejected(let reason):
            Label { Text(reason) } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.lp.softRose) }
        }
    }
}

/// Window-level rules for the editor (§6.9, F-7): excluded from capture, not restorable, document-edited dot, and
/// the standard "save changes?" alert on close (UI-M13: Save saves and then closes; with errors, Save isn't offered).
struct EditorWindowConfigurator: NSViewRepresentable {
    let model: EditorModel
    let saveForClose: @MainActor () async -> Bool

    func makeNSView(context: Context) -> WindowHook {
        let v = WindowHook()
        v.model = model
        v.saveForClose = saveForClose
        return v
    }

    func updateNSView(_ v: WindowHook, context: Context) {
        v.model = model
        v.saveForClose = saveForClose
        guard let window = v.window else { return }
        window.isDocumentEdited = model.isDirty
        CloseGuard.install(on: window, hook: v)      // no-op unless SwiftUI replaced the delegate
    }

    @MainActor final class WindowHook: NSView {
        var model: EditorModel?
        var saveForClose: (@MainActor () async -> Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.sharingType = .none
            window.isRestorable = false
            CloseGuard.install(on: window, hook: self)
        }

        func confirmClose(_ window: NSWindow) {
            guard let model else { return }
            CloseGuard.confirmClose(window, model: model, saveForClose: saveForClose)
        }
    }

    /// Forwards everything to SwiftUI's delegate and answers `windowShouldClose` itself.
    ///
    /// ONE guard per window, owned by the window (owner test, build 200018: no close path worked, even unedited).
    /// SwiftUI may rebuild this background view, so a window can see several hooks over its life. A guard per hook
    /// wrapped the previous hook's guard; when that hook went away, its guard died, the weak `original` chain broke,
    /// and SwiftUI's `AppKitWindowController` (the window controller, whose `windowShouldClose` does the scene's
    /// close) was never asked again, so the close button, ⌘W and File › Close did nothing. Now the newest hook just
    /// takes over the existing guard. `original` stays weak (the controller owns the window, so strong would be a
    /// cycle); SwiftUI keeps it alive as the window controller.
    ///
    /// Fail safe: the guard also remembers the model and the save closure of the newest hook, so when the hook is
    /// released while the editor still has unsaved edits the close still asks; it never closes a dirty editor silently.
    /// Only when there is provably nothing to lose (the model is clean, or gone) does the close go to SwiftUI's controller.
    /// Save and Don't Save finish with `performClose`, not `close()`: that goes through `windowShouldClose` again (the
    /// model is clean by then) and so through the controller's own close path.
    @MainActor final class CloseGuard: NSObject, NSWindowDelegate {
        weak var hook: WindowHook?
        weak var model: EditorModel?
        var saveForClose: (@MainActor () async -> Bool)?
        weak var original: (any NSWindowDelegate)?

        private override init() { super.init() }

        /// Associated-object key: the class object's address, unique and stable for the process.
        private static var key: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(CloseGuard.self as AnyObject).toOpaque()) }

        /// Idempotent: points the window's guard at `hook`, and re-inserts it if SwiftUI set its delegate again.
        static func install(on window: NSWindow, hook: WindowHook) {
            let g: CloseGuard
            if let existing = objc_getAssociatedObject(window, key) as? CloseGuard {
                g = existing
            } else {
                g = CloseGuard()
                objc_setAssociatedObject(window, key, g, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            g.hook = hook
            g.model = hook.model
            g.saveForClose = hook.saveForClose
            if window.delegate !== g {
                g.original = window.delegate
                window.delegate = g
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if let model = hook?.model ?? model, model.isDirty {
                Self.confirmClose(sender, model: model, saveForClose: hook?.saveForClose ?? saveForClose)
                return false
            }
            return original?.windowShouldClose?(sender) ?? true
        }

        /// Save / Cancel / Don't Save, or Cancel / Don't Save when the buffer has errors.
        static func confirmClose(_ window: NSWindow, model: EditorModel, saveForClose: (@MainActor () async -> Bool)?) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Do you want to save the changes to “\(model.name)”?", comment: "Editor close alert")
            let canSave = model.canSave
            if canSave {
                alert.informativeText = String(localized: "Your changes will be lost if you don't save them.", comment: "Editor close alert")
                alert.addButton(withTitle: String(localized: "Save", comment: "Button"))
            } else {
                alert.informativeText = String(localized: "The profile has errors, so it can't be saved. Fix them, or close without saving.", comment: "Editor close alert with errors")
            }
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Button"))
            alert.addButton(withTitle: String(localized: "Don't Save", comment: "Button")).hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak window, weak model] response in
                MainActor.assumeIsolated {                 // SAFETY: sheet completion runs on the main thread
                    let saveButton: NSApplication.ModalResponse? = canSave ? .alertFirstButtonReturn : nil
                    let dontSave: NSApplication.ModalResponse = canSave ? .alertThirdButtonReturn : .alertSecondButtonReturn
                    if response == saveButton {
                        Task { @MainActor in
                            if await saveForClose?() == true { window?.performClose(nil) }       // by now the sheet is gone
                        }
                    } else if response == dontSave {
                        model?.discardChanges()
                        Task { @MainActor in window?.performClose(nil) }       // after the sheet is gone, or the close is refused
                    }
                }
            }
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            original?.responds(to: aSelector) == true ? original : nil
        }
    }
}

/// Open editors, so quitting can ask about unsaved changes (UI-M13). The app delegate's
/// `applicationShouldTerminate` returns `EditorRegistry.shared.terminateReply()`.
@MainActor final class EditorRegistry {
    static let shared = EditorRegistry()
    private var models: [ObjectIdentifier: WeakModel] = [:]
    private struct WeakModel { weak var model: EditorModel? }

    func register(_ m: EditorModel) { models[ObjectIdentifier(m)] = WeakModel(model: m) }
    func unregister(_ m: EditorModel) { models[ObjectIdentifier(m)] = nil }

    var unsavedNames: [String] { models.values.compactMap(\.model).filter(\.isDirty).map(\.name) }

    /// A user quit with unsaved editors asks first; Apple-event quits (logout, Homebrew) and nothing-dirty quit at once.
    func terminateReply() -> NSApplication.TerminateReply {
        let names = unsavedNames
        guard !names.isEmpty, NSAppleEventManager.shared().currentAppleEvent == nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(AttributedString(localized: "You have unsaved changes in ^[\(names.count) profile](inflect: true).", comment: "Quit with unsaved editors").characters)
        alert.informativeText = names.joined(separator: ", ")
        alert.addButton(withTitle: String(localized: "Review Changes", comment: "Button"))
        alert.addButton(withTitle: String(localized: "Quit Anyway", comment: "Button")).hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// Documentation for the key under the caret (§6.9 "Reference"), replacing CodeMirror autocomplete.
enum EditorReference {
    static func entry(for key: String, kind: VPNProtocolKind) -> String? {
        let k = key.lowercased()
        switch kind {
        case .wireGuard:
            switch k {
            case "interface": return String(localized: "This Mac's side of the tunnel: its key, addresses and DNS.", comment: "WG reference")
            case "peer": return String(localized: "The server (or another device) this Mac talks to.", comment: "WG reference")
            case "privatekey": return String(localized: "This Mac's private key, Base64. Never share it; LockPlus keeps it encrypted.", comment: "WG reference")
            case "address": return String(localized: "The tunnel addresses of this Mac, as CIDR (10.8.0.2/32, fd00::2/128).", comment: "WG reference")
            case "dns": return String(localized: "DNS servers used while connected, and optional search domains.", comment: "WG reference")
            case "mtu": return String(localized: "Largest packet size in the tunnel. Leave empty unless your provider says otherwise.", comment: "WG reference")
            case "listenport": return String(localized: "Local UDP port. Usually not needed on a client.", comment: "WG reference")
            case "publickey": return String(localized: "The peer's public key, Base64.", comment: "WG reference")
            case "presharedkey": return String(localized: "An optional extra symmetric key for post-quantum resistance. Secret.", comment: "WG reference")
            case "endpoint": return String(localized: "The peer's address as host:port.", comment: "WG reference")
            case "allowedips": return String(localized: "Routes sent into the tunnel. Use 0.0.0.0/0, ::/0 for all traffic.", comment: "WG reference")
            case "persistentkeepalive": return String(localized: "Seconds between keepalive packets. 25 keeps NAT open and lets the kill switch notice a dead connection.", comment: "WG reference")
            case "preup", "postup", "predown", "postdown": return String(localized: "Scripts. LockPlus never runs them; they are kept for export only.", comment: "WG reference")
            case "table", "fwmark", "saveconfig": return String(localized: "A wg-quick setting that doesn't apply on macOS. Kept for export, not applied.", comment: "WG reference")
            default: return nil
            }
        case .openVPN:
            switch k {
            case "client": return String(localized: "Client mode: pull settings from the server.", comment: "OVPN reference")
            case "dev": return String(localized: "The tunnel device. macOS supports tun only.", comment: "OVPN reference")
            case "proto": return String(localized: "udp or tcp for the connection to the server.", comment: "OVPN reference")
            case "remote": return String(localized: "Server host, port and optional protocol. Several lines are tried in order.", comment: "OVPN reference")
            case "cipher", "data-ciphers": return String(localized: "Data-channel ciphers. AES-GCM or ChaCha20-Poly1305; 64-bit ciphers (BF-CBC, DES) are not supported.", comment: "OVPN reference")
            case "auth": return String(localized: "HMAC digest for the control channel, e.g. SHA256.", comment: "OVPN reference")
            case "auth-user-pass": return String(localized: "The server asks for a username and password. LockPlus prompts, or uses the Keychain.", comment: "OVPN reference")
            case "remote-cert-tls": return String(localized: "Requires the server certificate to be marked as a server. Keep it: it stops impersonation by other clients.", comment: "OVPN reference")
            case "verify-x509-name": return String(localized: "Pins the server certificate's name.", comment: "OVPN reference")
            case "ca": return String(localized: "The certificate authority that signed the server's certificate.", comment: "OVPN reference")
            case "cert": return String(localized: "This Mac's client certificate.", comment: "OVPN reference")
            case "key": return String(localized: "This Mac's private key. Secret; masked until you show it.", comment: "OVPN reference")
            case "tls-auth", "tls-crypt", "tls-crypt-v2": return String(localized: "A shared key that protects the TLS handshake. Secret.", comment: "OVPN reference")
            case "redirect-gateway": return String(localized: "Send all traffic through the tunnel (full tunnel).", comment: "OVPN reference")
            case "route": return String(localized: "Adds one route into the tunnel (split tunnel).", comment: "OVPN reference")
            case "pull-filter": return String(localized: "Accept, ignore or reject options pushed by the server.", comment: "OVPN reference")
            case "static-challenge": return String(localized: "Asks for a one-time code with the given prompt on every connect.", comment: "OVPN reference")
            case "comp-lzo", "compress": return String(localized: "Compression. LockPlus only decompresses (VORACLE).", comment: "OVPN reference")
            case "up", "down", "script-security": return String(localized: "Scripts. LockPlus never runs them.", comment: "OVPN reference")
            case "nobind": return String(localized: "Don't bind a fixed local port. Recommended for clients.", comment: "OVPN reference")
            default: return nil
            }
        }
    }
}

// MARK: - Previews

extension EditorModel {
    static func preview(kind: VPNProtocolKind, text: String, name: String = "Work", revealed: Bool = false) -> EditorModel {
        let m = EditorModel(target: .existing(PreviewData.workID))
        m.apply(EditorDocument(name: name, kind: kind, text: text))
        m.keyRevealed = revealed
        return m
    }
}

enum EditorPreviewText {
    static let wireGuard = """
    [Interface]
    PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
    Address = 10.8.0.2/32
    DNS = 10.8.0.1
    PostUp = iptables -A FORWARD -i wg0 -j ACCEPT

    [Peer]
    PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
    Endpoint = vpn.example.de
    AllowedIPs = 0.0.0.0/0, ::/0

    """
    static let openVPN = """
    client
    dev tun
    proto udp
    remote vpn.example.com 1194
    cipher BF-CBC
    script-security 2
    up /etc/openvpn/up.sh
    auth-user-pass
    remote-cert-tls server
    <key>
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7
    -----END PRIVATE KEY-----
    </key>

    """
}

#Preview("Editor — WireGuard with an error") {
    EditorWindow(model: .preview(kind: .wireGuard, text: EditorPreviewText.wireGuard))
        .environment(UIEnvironment.preview(row: "15"))
        .frame(width: 900, height: 520)
}

#Preview("Editor — OpenVPN, unsupported cipher, dark") {
    EditorWindow(model: .preview(kind: .openVPN, text: EditorPreviewText.openVPN, name: "Office"))
        .environment(UIEnvironment.preview(row: "15"))
        .frame(width: 900, height: 520)
        .preferredColorScheme(.dark)
}

#Preview("Editor — new WireGuard profile") {
    EditorWindow(model: {
        let m = EditorModel(target: .new(.wireGuard))
        m.apply(EditorDocument(name: "", kind: .wireGuard, text: EditorTemplates.text(for: .wireGuard)))
        return m
    }())
    .environment(UIEnvironment.preview(row: "15"))
    .frame(width: 900, height: 520)
}
