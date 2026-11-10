import LPModel
import SwiftUI

/// Import preview, single file (UI-CONCEPT §6.8). Driven by LPModel's `ImportReport`: any Not-supported item
/// disables Import and says why; security warnings (legacy CBC, a server on another network) keep it enabled.
struct ImportPreviewSheet: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ImportPreview
    @State private var showIgnored: Bool
    @State private var showNotApplied: Bool
    @State private var showNotes = false

    /// `ignoredExpanded`: only the screenshot tests open the section; in the app it starts collapsed.
    init(preview: ImportPreview, ignoredExpanded: Bool = false) {
        _draft = State(initialValue: preview)
        _showIgnored = State(initialValue: ignoredExpanded)
        _showNotApplied = State(initialValue: ignoredExpanded)
    }

    var body: some View {
        let report = draft.report
        let ignored = report.items.filter(\.isHarmlessIgnored)
        let notApplied = report.items.filter(\.isNotApplied)
        let unsupported = report.items(in: .notSupported)
        let warnings = report.items(in: .securityWarning)
        let notes = report.items(in: .note)
        VStack(alignment: .leading, spacing: 14) {
            Text("Import “\(draft.fileName)”", comment: "Import sheet title").font(.headline)

            LPFormGrid {
                LPFormRow(label: String(localized: "Name", comment: "Field")) {
                    TextField(String(localized: "Name", comment: "Field"), text: $draft.name).labelsHidden().lpField()
                }
                LPFormRow(label: String(localized: "Type", comment: "Field")) {
                    Text(verbatim: typeLine).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("^[\(report.supportedCount) directive](inflect: true) supported", comment: "Import summary")
                    } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.lp.softSage) }

                    if !notApplied.isEmpty {
                        DisclosureGroup(isExpanded: $showNotApplied) {
                            ReportItemList(items: notApplied, profileName: draft.fileName)
                        } label: {
                            Label {
                                Text("^[\(notApplied.count) directive](inflect: true) not applied", comment: "Import report summary; directives whose behaviour LockPlus does not apply (scripts, certificate pin, web sign-in, WireGuard settings)")
                            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.softAmber) }
                        }
                    }
                    if !ignored.isEmpty {
                        // One-line label so the chevron sits by the heading; the explanation follows it, collapsed or not.
                        DisclosureGroup(isExpanded: $showIgnored) {
                            notNeededExplanation
                            ReportItemList(items: ignored, profileName: draft.fileName)
                        } label: {
                            Label {
                                Text("^[\(ignored.count) directive](inflect: true) not needed", comment: "Import report summary; harmless directives LockPlus doesn't need")
                            } icon: { Image(systemName: "info.circle.fill").foregroundStyle(Color.secondary) }
                        }
                        if !showIgnored { notNeededExplanation }
                    }

                    Label {
                        Text("Not supported: \(unsupported.count)", comment: "Import summary; the argument is a count")
                    } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(unsupported.isEmpty ? Color.secondary : Color.lp.softRose) }
                    if !unsupported.isEmpty {
                        Text(ImportReportCopy.unsupportedAdvice).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(unsupported.enumerated()), id: \.offset) { _, item in
                        InlineStrip(severity: .critical, message: item.lineAnnotated(profileName: draft.fileName))
                    }
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, item in
                        InlineStrip(severity: .attention, message: item.lineAnnotated(profileName: draft.fileName))
                    }
                    if !notes.isEmpty {
                        DisclosureGroup(String(localized: "Changed by LockPlus", comment: "Import notes disclosure"), isExpanded: $showNotes) {
                            ReportItemList(items: notes, profileName: draft.fileName)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                Text("Protection", comment: "Import field")
                Toggle(draft.isFullTunnel ? String(localized: "Kill switch", comment: "Checkbox") : String(localized: "Route protection", comment: "Checkbox"),
                       isOn: $draft.killSwitch)
                Toggle(String(localized: "Allow local network", comment: "Checkbox"), isOn: $draft.allowLocalNetwork)
                    .disabled(!draft.killSwitch)
            }
            .toggleStyle(.checkbox)

            HStack {
                Button(String(localized: "Copy Report", comment: "Button")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.plainText(profileName: draft.fileName, title: ImportReportCopy.sectionTitle,
                                                                    message: { $0.localizedMessage(profileName: draft.fileName) }), forType: .string)
                }
                .disabled(report.items.isEmpty)
                Spacer()
                Button(String(localized: "Cancel", comment: "Button")) { env.actions.cancelImport(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Import", comment: "Button")) { env.actions.confirmImport(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canImport)
                    .help(report.blocksImport ? String(localized: "This profile uses something LockPlus doesn't support.", comment: "Tooltip") : "")
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var typeLine: String {
        let proto = draft.kind == .wireGuard ? String(localized: "WireGuard", comment: "Protocol name") : String(localized: "OpenVPN", comment: "Protocol name")
        return [proto, draft.summary.transport.uppercased(), draft.summary.endpoints.first].compactMap { $0 }.joined(separator: " · ")
    }

    private var notNeededExplanation: some View {
        Text(ImportReportCopy.notNeededExplanation).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The always-visible explanations of the import report (sheet and profile detail), so "ignored" doesn't read as an error.
enum ImportReportCopy {
    static var notNeededExplanation: String {
        String(localized: "These lines in the profile file aren't needed with LockPlus. Nothing to do: the profile works as it is.", comment: "Import report: explains the 'not needed' directives (informational, not a warning)")
    }
    /// Headings of "Copy Report" in the app's language.
    static func sectionTitle(_ s: PlainTextSection) -> String {
        switch s {
        case .notApplied: String(localized: "Not applied", comment: "Copy Report heading: ignored directives whose behaviour isn't applied")
        case .notNeeded: String(localized: "Not needed", comment: "Copy Report heading: harmless ignored directives")
        case .notSupported: String(localized: "Not supported", comment: "Batch item status and Copy Report heading")
        case .securityWarning: String(localized: "Security warnings", comment: "Copy Report heading")
        case .note: String(localized: "Changed by LockPlus", comment: "Import notes disclosure")
        }
    }
    static var unsupportedAdvice: String {
        String(localized: "LockPlus can't import this profile as it is. Remove or replace these lines in the profile file, then import it again.", comment: "Import sheet: what to do about unsupported directives")
    }
}

/// "Line 12: script-security — scripts never run in LockPlus".
private struct ReportItemList: View {
    let items: [ImportReportItem]
    let profileName: String
    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Text(item.lineAnnotated(profileName: profileName))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension ImportReportItem {
    /// The reason in the app's language for the "not needed" directives (the harmless ones LockPlus handles itself);
    /// everything else keeps the LPModel English text. Never carries an argument.
    func localizedMessage(profileName: String? = nil) -> String {
        switch reason {
        case .loggingManaged: String(localized: "logging is managed by LockPlus", comment: "Import reason, ignored directive")
        case .reconnectManaged: String(localized: "LockPlus handles reconnecting", comment: "Import reason, ignored directive")
        case .persistenceNotNeeded: String(localized: "not needed; LockPlus keeps the tunnel up itself", comment: "Import reason, ignored directive")
        case .localBindingNotUsed: String(localized: "local port binding isn't used", comment: "Import reason, ignored directive")
        case .cipherNegotiationAutomatic: String(localized: "ciphers are negotiated automatically", comment: "Import reason, ignored directive")
        case .scriptsNeverRun: String(localized: "scripts never run in LockPlus", comment: "Import reason, ignored directive")
        case .windowsOnly: String(localized: "Windows-only option", comment: "Import reason, ignored directive")
        case .unixAccountNotUsed: String(localized: "not used on macOS", comment: "Import reason, ignored directive")
        case .setByServer: String(localized: "set by the server", comment: "Import reason, ignored directive")
        case .serverOnlyOption: String(localized: "a server option; not needed by a client", comment: "Import reason, ignored directive")
        case .verifyHashNotSupported: String(localized: "not supported; the certificate chain is still verified, use peer-fingerprint to pin the server", comment: "Import reason, ignored directive")
        case .dnsManagedByLockPlus: String(localized: "DNS is managed by LockPlus", comment: "Import reason, ignored directive")
        case .compressionPolicyManaged: String(localized: "LockPlus decides compression itself", comment: "Import reason, ignored directive")
        case .legacyProvidersNeverLoaded: String(localized: "outdated algorithms are never enabled", comment: "Import reason, ignored directive")
        case .pingTimerRemNotNeeded: String(localized: "only matters for point-to-point setups", comment: "Import reason, ignored directive")
        case .engineIgnores: String(localized: "not used by LockPlus's OpenVPN engine", comment: "Import reason, ignored directive")
        case .cipherListNotApplied: String(localized: "your cipher list isn't applied; LockPlus's engine negotiates the cipher itself", comment: "Import reason, ignored directive")
        case .compressionNotEnforced: String(localized: "LockPlus accepts compressed data from the server (asym); “no” isn't enforced", comment: "Import reason, ignored directive")
        case .rekeyReplayTuningNotApplied: String(localized: "rekey/replay tuning isn't applied; LockPlus uses the engine's defaults", comment: "Import reason, ignored directive")
        case .routeGatewayManaged: String(localized: "LockPlus routes via the tunnel gateway", comment: "Import reason, ignored directive")
        case .mtuManaged: String(localized: "packet size is managed by LockPlus", comment: "Import reason, ignored directive")
        case .routingManaged: String(localized: "routes are managed by LockPlus", comment: "Import reason, ignored directive")
        case .engineManagesItself: String(localized: "the OpenVPN engine handles this itself", comment: "Import reason, ignored directive")
        case .obsoleteOption: String(localized: "obsolete; the server decides about IPv6", comment: "Import reason, ignored directive")
        case .tlsVersionCapIgnored: String(localized: "only caps the TLS version; the engine's own limits apply", comment: "Import reason, ignored directive")
        case .keepaliveTakesPrecedence: String(localized: "keepalive is set, which takes precedence", comment: "Import reason, ignored directive")
        case .webSignInNotSupported: String(localized: "web sign-in isn't supported; the setting is removed", comment: "Import reason, ignored directive")
        case .wgHookNeverRun: String(localized: "scripts never run in LockPlus", comment: "Import reason, ignored directive")
        case .wgSettingNotApplied: String(localized: "not applied on macOS", comment: "Import reason, ignored directive")
        case .wgUnknownKeyPreserved: String(localized: "unknown key; kept for export, not applied", comment: "Import reason, ignored directive")
        case .wgSemicolonLineSkipped: String(localized: "lines starting with ';' are skipped", comment: "Import reason, ignored directive")
        // Not ignored-group reasons: the LPModel English text, never carrying an argument.
        case .fileTooLarge, .containsNULByte, .syntax, .invalidUTF8, .controlCharacters, .notAClientProfile, .noRemote, .limitExceeded,
             .forbidden, .tapNotSupported, .outdatedCipher, .cipherNone, .unknownCipher, .weakDigest, .unknownDigest,
             .separateRemotePortNotSupported, .protoForceNotSupported, .socksProxyNotSupported, .fragmentNotSupported, .pkcs12NotSupported,
             .engineRejects, .notSupportedInsideConnection, .httpProxyNeedsTCPRemote, .proxyOptionWithoutProxy, .proxyAuthNeedsInlineCredentials,
             .tlsClientNeedsPull, .inlineBodyLineStartsWithCloseTag, .inlineCredentialsMalformed, .staticChallengeMalformed, .privilegedLocalPort,
             .parserDisagreement, .engineValidationFailed, .duplicateKeptLast, .devRewrittenToTun, .remoteCertEKUAppended, .keepaliveFloorAppended,
             .mssfixFloorAppended, .authNocacheAppended, .credentialsExtracted, .proxyCredentialsExtracted, .routeGatewayRewritten,
             .routeFormIgnoredByEngine, .setenvOptClassifiedAsDirective, .serverIdentityNotPinned, .legacyCBCEncryption, .compressionEnabled,
             .serverOnOtherNetwork, .proxyHostUnresolved, .wgHostBitsNormalized, .wgMTUAbove9000, .wgKeepaliveSuggested, .wgInvalid, .wgSyntax,
             .migrationAutoReconnectReplaced, .migrationPerNetworkProfilesNotSupported, .migrationDNSAlwaysTunnelled,
             .migrationSavedPasswordInSystemKeychain:
            message(profileName: profileName)
        }
    }

    /// The report text from LPModel (English source; see the report notes on localization), prefixed with line and
    /// directive. Never shows an argument: the report never carries one.
    func lineAnnotated(profileName: String?) -> String {
        let text = localizedMessage(profileName: profileName)
        switch (line, directive) {
        case let (l?, d?): return String(localized: "Line \(l), \(d): \(text)", comment: "Import report item with line and directive")
        case let (l?, nil): return String(localized: "Line \(l): \(text)", comment: "Import report item with line")
        case let (nil, d?): return String(localized: "\(d): \(text)", comment: "Import report item with directive")
        case (nil, nil): return text
        }
    }
}

/// Zip or multiple files (§6.8): checkboxes, a per-item verdict glyph (✓/⚠/✕) and a summary. Caps appear as errors.
struct BatchImportSheet: View {
    @Environment(UIEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BatchImport

    init(batch: BatchImport) {
        _draft = State(initialValue: batch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import “\(draft.archiveName)”", comment: "Batch import title").font(.headline)
            ForEach(draft.capErrors, id: \.self) { InlineStrip(severity: .critical, message: $0) }
            List {
                ForEach($draft.items) { $item in
                    HStack {
                        Toggle(isOn: $item.selected) { Text(verbatim: item.fileName) }
                            .disabled(!item.isImportable || draft.finished)
                            .layoutPriority(1)
                        Spacer()
                        BatchResultLabel(item: item)
                    }
                }
            }
            .frame(minHeight: 180)
            Text(summary).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if draft.finished {
                    Button(String(localized: "Done", comment: "Button")) { env.actions.cancelImport(); dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(String(localized: "Cancel", comment: "Button")) { env.actions.cancelImport(); dismiss() }.keyboardShortcut(.cancelAction)
                    Button(String(localized: "Import Selected", comment: "Button")) { env.actions.confirmBatch(draft) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.items.contains { $0.selected && $0.isImportable })
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    private var summary: String {
        if draft.finished {
            let imported = draft.items.filter { $0.state == .imported }.count
            let skipped = draft.items.count - imported
            return String(localized: "\(imported) imported, \(skipped) skipped", comment: "Batch import result (§6.8)")
        }
        let selected = draft.items.filter { $0.selected && $0.isImportable }.count
        return String(AttributedString(localized: "^[\(selected) profile](inflect: true) selected", comment: "Batch import selection").characters)
    }
}

struct BatchResultLabel: View {
    let item: BatchImportItem
    var body: some View {
        let first = item.report.items.first { $0.group == .notSupported } ?? item.report.items.first { $0.group == .securityWarning }
        HStack(spacing: 6) {
            if let first, item.state != .imported {
                Text(first.message(profileName: item.fileName)).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                    .help(first.message(profileName: item.fileName))
            }
            switch (item.state, item.verdict) {
            case (.imported, _):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.lp.softSage)
                    .accessibilityLabel(Text("Imported", comment: "Batch item"))
            case (.skipped, _), (_, .rejected):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.lp.softRose)
                    .accessibilityLabel(Text("Not supported", comment: "Batch item status and Copy Report heading"))
            case (_, .importedWithWarnings):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.softAmber)
                    .accessibilityLabel(Text("Ready, with warnings", comment: "Batch item"))
            case (_, .imported):
                Image(systemName: "checkmark.circle").foregroundStyle(Color.lp.softSage)
                    .accessibilityLabel(Text("Ready", comment: "Batch item"))
            }
        }
        .frame(maxWidth: 260, alignment: .trailing)
    }
}

/// Uninstall confirmation (§6.13): says up front that macOS asks for an administrator password, and what happens
/// if that dialog is cancelled.
struct UninstallConfirmSheet: View {
    typealias Phase = UninstallPhase
    @Environment(UIEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var phase: Phase = .confirm
    @State private var deleteProfiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .residual = phase {
                Label {
                    Text("LockPlus couldn't remove everything", comment: "§4.4 residual sheet title").font(.headline)
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lp.softAmber) }
            } else {
                Label {
                    Text("Uninstall LockPlus?", comment: "Uninstall title").font(.headline)
                } icon: { Image(systemName: "trash").foregroundStyle(Color.lp.softRose) }
            }
            switch phase {
            case .confirm, .uninstalling:
                // §4.4 step 7: saved passwords and the master key go only with "Also delete your profiles and history".
                Text("LockPlus removes its tunnel component and its VPN configurations. Your profiles and the passwords you saved stay on this Mac unless you choose otherwise below.", comment: "Uninstall explanation (DESIGN §4.4)")
                    .fixedSize(horizontal: false, vertical: true)
                Label {
                    Text("macOS will ask for an administrator password to remove the tunnel component.", comment: "Uninstall admin password notice (§6.13, S4/S5)")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "lock.shield").foregroundStyle(Color.lp.softAmber) }
                Toggle(isOn: $deleteProfiles) {
                    Text("Also delete your profiles and history", comment: "Uninstall checkbox (DESIGN §4.4 step 7)")
                    Text("On: your profiles, history and saved passwords are deleted, together with the key that opens your profiles. Off: all of it stays, so a reinstall finds it.", comment: "Uninstall checkbox footnote (DESIGN §4.4 step 7)")
                }
                .toggleStyle(.checkbox)
                .disabled(phase == .uninstalling)
                HStack {
                    if phase == .uninstalling { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(String(localized: "Cancel", comment: "Button")) { dismiss() }.keyboardShortcut(.cancelAction)
                    // Destructive: never the default button; Return does nothing here (UI-M16).
                    Button(String(localized: "Uninstall…", comment: "Button"), role: .destructive) { env.actions.uninstall(deletingProfilesAndHistory: deleteProfiles) }
                        .disabled(phase == .uninstalling)
                }
            case .residual(let message):
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button(String(localized: "OK", comment: "Button")) { env.settings.acknowledgeResidual() }.keyboardShortcut(.defaultAction)
                }
            case .componentStillInstalled:
                Text("The tunnel component couldn't be removed, for example because the administrator password dialog was cancelled. Your profiles and LockPlus itself were kept. Try again to finish uninstalling.", comment: "Uninstall, deactivation failed (§4.4 step 6, §6.13)")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(String(localized: "Close", comment: "Button")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(String(localized: "Try Again", comment: "Button")) { env.actions.uninstall(deletingProfilesAndHistory: deleteProfiles) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { env.settings.uninstallSheetVisible = true }
        .onDisappear {
            env.settings.uninstallSheetVisible = false
            env.settings.acknowledgeResidual()          // never leave the uninstaller waiting on a closed sheet
        }
    }
}

#Preview("Import — clean") {
    ImportPreviewSheet(preview: PreviewData.importPreview).environment(UIEnvironment.preview())
}

#Preview("Import — warnings (legacy cipher, other network)") {
    ImportPreviewSheet(preview: PreviewData.importPreviewWarnings).environment(UIEnvironment.preview())
}

#Preview("Import — unsupported cipher") {
    ImportPreviewSheet(preview: PreviewData.importPreviewUnsupported).environment(UIEnvironment.preview())
}

#Preview("Import — zip") {
    BatchImportSheet(batch: PreviewData.batch).environment(UIEnvironment.preview())
}

#Preview("Uninstall") {
    UninstallConfirmSheet().environment(UIEnvironment.preview())
}

#Preview("Uninstall — residuals (§4.4)") {
    UninstallConfirmSheet(phase: .residual(PreviewData.uninstallResidual)).environment(UIEnvironment.preview())
}

#Preview("Uninstall — component still installed") {
    UninstallConfirmSheet(phase: .componentStillInstalled).environment(UIEnvironment.preview())
}
