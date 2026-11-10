import Foundation
import LPModel
import LPParsing
import Observation
import SwiftUI

// The profile editor (UI-CONCEPT §6.9, DESIGN §11.4). The scene is
//   WindowGroup("Edit Profile", for: EditorTarget.self) { $t in EditorWindow(target: t) }
//       .restorationBehavior(.disabled)
// with `.environment(\.profileEditorBackend, backend)` and `.environment(env)`. Opening an EXISTING profile's
// editor goes through RevealGate first (the caller's job, before `openWindow`); new profiles don't.

/// What an editor window edits. Codable/Hashable for `WindowGroup(for:)`.
struct EditorTarget: Codable, Hashable, Sendable {
    var profileID: UUID?
    var newKind: VPNProtocolKind?

    static func existing(_ id: UUID) -> EditorTarget { EditorTarget(profileID: id, newKind: nil) }
    static func new(_ kind: VPNProtocolKind) -> EditorTarget { EditorTarget(profileID: nil, newKind: kind) }
}

/// A loaded config. The text holds secrets (WG keys, OVPN inline keys): it lives only in this window.
struct EditorDocument: Sendable {
    var name: String
    var kind: VPNProtocolKind
    var text: String
}

enum EditorSaveMode: Sendable { case saveOnly, saveAndReconnect }

/// The app side of the editor: load and save through ProfilesStore / the extension (DESIGN §3.4, §8.1 [7]).
@MainActor protocol ProfileEditorBackend: AnyObject, Sendable {
    /// The config of an existing profile, or a template for a new one (`EditorTemplates`; the app may fill a fresh
    /// WireGuard private key).
    func load(_ target: EditorTarget) async throws -> EditorDocument
    /// Saves the edited text (the importer re-runs on it, DESIGN §8.1) and returns the profile ID (new for a new
    /// profile). `saveAndReconnect` restarts the tunnel when it is connected. Errors are shown in the window.
    func save(_ target: EditorTarget, name: String, text: String, mode: EditorSaveMode) async throws -> UUID
    /// Step [7] for OpenVPN (`XPCProfileValidator`); nil while the extension isn't available.
    var openVPNValidator: (any OpenVPN3ProfileValidating)? { get }
}

extension EnvironmentValues {
    @Entry var profileEditorBackend: (any ProfileEditorBackend)? = nil
}

/// Starting text for new profiles. Nothing secret: the private key is empty unless the backend fills one in.
enum EditorTemplates {
    static func text(for kind: VPNProtocolKind) -> String {
        switch kind {
        case .wireGuard:
            """
            [Interface]
            PrivateKey =
            Address = 10.0.0.2/32
            DNS = 10.0.0.1

            [Peer]
            PublicKey =
            Endpoint = vpn.example.com:51820
            AllowedIPs = 0.0.0.0/0, ::/0
            PersistentKeepalive = 25

            """
        case .openVPN:
            """
            client
            dev tun
            proto udp
            remote vpn.example.com 1194
            nobind
            remote-cert-tls server
            cipher AES-256-GCM
            auth-user-pass

            <ca>
            </ca>

            """
        }
    }
}

// MARK: - Analysis

/// One finding, attached to a 1-based line when known.
struct EditorIssue: Identifiable, Sendable, Equatable {
    enum Severity: Int, Sendable, Comparable {
        case info, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    var id: Int
    var line: Int?
    var severity: Severity
    var message: String
}

/// A syntax span, as a UTF-16 range into the text (NSString/TextKit offsets).
struct HighlightSpan: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case section, key, value, number, comment, ignoredKey, forbiddenKey, inlineTag }
    var location: Int
    var length: Int
    var kind: Kind
}

/// Everything derived from the text, computed off the main actor with our own parsers (DESIGN §11.4).
struct EditorAnalysis: Sendable, Equatable {
    var issues: [EditorIssue] = []
    var spans: [HighlightSpan] = []
    /// UTF-16 offset where each line starts (index 0 = line 1).
    var lineStarts: [Int] = [0]
    /// Secret lines (0-based) and where the secret starts in each line (UTF-16 offset within the line).
    var secretLines: [Int: Int] = [:]
    var summary: ProfileSummary?
    var generation = 0

    var errorCount: Int { issues.filter { $0.severity == .error }.count }

    /// Forbidden directives per line (0-based), as (start within the line, length) in UTF-16: drawn with a red
    /// dotted underline by the layout fragment (rendering attributes don't draw underlines in TextKit 2).
    var forbiddenRanges: [Int: [Range<Int>]] {
        var out: [Int: [Range<Int>]] = [:]
        for s in spans where s.kind == .forbiddenKey {
            let line = line(forOffset: s.location)
            let start = s.location - lineStarts[line]
            out[line, default: []].append(start..<(start + s.length))
        }
        return out
    }

    func line(forOffset offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

enum EditorAnalyzer {
    @concurrent static func analyze(_ text: String, kind: VPNProtocolKind, generation: Int) async -> EditorAnalysis {
        analyzeSync(text, kind: kind, generation: generation)
    }

    static func analyzeSync(_ text: String, kind: VPNProtocolKind, generation: Int = 0) -> EditorAnalysis {
        let lines = splitLines(text)
        var a = EditorAnalysis()
        a.generation = generation
        a.lineStarts = lines.map(\.start)
        switch kind {
        case .wireGuard: analyzeWG(text, lines: lines, into: &a)
        case .openVPN: analyzeOVPN(text, lines: lines, into: &a)
        }
        a.issues.sort { ($0.severity, -($0.line ?? 0)) > ($1.severity, -($1.line ?? 0)) }
        for i in a.issues.indices { a.issues[i].id = i }
        return a
    }

    struct Line { var start: Int; var text: Substring }

    static func splitLines(_ text: String) -> [Line] {
        var out: [Line] = []
        var offset = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append(Line(start: offset, text: raw))
            offset += raw.utf16.count + 1
        }
        return out
    }

    static func severity(_ g: ImportReportGroup) -> EditorIssue.Severity {
        switch g {
        case .notSupported: .error
        case .securityWarning: .warning
        case .ignored, .note: .info
        }
    }

    // MARK: Secrets (synchronous, fail-closed masking)

    /// Secret lines of `text`, computed synchronously on every edit so masking never lags the text (UI-H3).
    struct SecretScan: Sendable, Equatable {
        var lineStarts: [Int] = [0]
        /// 0-based line → UTF-16 offset within the line where the secret starts.
        var secretLines: [Int: Int] = [:]

        func line(forOffset offset: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }
    }

    static func scanSecrets(_ text: String, kind: VPNProtocolKind) -> SecretScan {
        let lines = splitLines(text)
        var scan = SecretScan(lineStarts: lines.map(\.start))
        var inBlock: String?
        for (i, line) in lines.enumerated() {
            switch kind {
            case .wireGuard:
                if let from = wgSecretValueOffset(line.text) { scan.secretLines[i] = from }
            case .openVPN:
                let trimmed = line.text.drop { $0 == " " || $0 == "\t" }
                let lead = line.text.utf16.count - trimmed.utf16.count
                let t = trimmed.trimmingCharacters(in: .whitespaces).lowercased()
                if let block = inBlock {
                    if t.hasPrefix("</\(block)") { inBlock = nil } else if secretBlocks.contains(block), !t.isEmpty { scan.secretLines[i] = lead }
                } else if t.hasPrefix("<"), t.hasSuffix(">"), !t.hasPrefix("</") {
                    inBlock = String(t.dropFirst().dropLast())
                }
            }
        }
        return scan
    }

    /// `PrivateKey = …` / `PresharedKey = …` (any case, any spacing): where the value starts, else nil.
    static func wgSecretValueOffset(_ line: Substring) -> Int? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        guard key == "privatekey" || key == "presharedkey" else { return nil }
        let lead = line.utf16.count - trimmed.utf16.count
        let afterEq = trimmed[trimmed.index(after: eq)...]
        let spaces = afterEq.utf16.count - afterEq.drop { $0 == " " || $0 == "\t" }.utf16.count
        return lead + trimmed[..<eq].utf16.count + 1 + spaces
    }

    /// Last-resort check on a paragraph's own text when no scan entry matches: anything that looks like key
    /// material is masked (fail closed).
    static func looksSecret(_ paragraph: Substring, kind: VPNProtocolKind) -> Int? {
        if kind == .wireGuard, let from = wgSecretValueOffset(paragraph) { return from }
        let t = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("-----") && !t.contains("CERTIFICATE") { return 0 }
        if t.count >= 20, !t.contains(" "), t.allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) }) {
            let lead = paragraph.utf16.count - paragraph.drop { $0 == " " || $0 == "\t" }.utf16.count
            return lead
        }
        return nil
    }

    // MARK: WireGuard

    static let wgKnownKeys: Set<String> = ["privatekey", "address", "dns", "mtu", "listenport", "publickey", "presharedkey",
                                           "endpoint", "allowedips", "persistentkeepalive"]
    static let wgIgnoredKeys: Set<String> = ["preup", "postup", "predown", "postdown", "table", "fwmark", "saveconfig"]

    static func analyzeWG(_ text: String, lines: [Line], into a: inout EditorAnalysis) {
        // Syntax spans and the line of each "Section[i].Key" for issue placement.
        var section = "", peerIndex = -1
        var fieldLines: [String: Int] = [:]
        for (i, line) in lines.enumerated() {
            let s = line.text
            let trimmed = s.drop { $0 == " " || $0 == "\t" }
            let lead = s.utf16.count - trimmed.utf16.count
            if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                a.spans.append(.init(location: line.start + lead, length: trimmed.utf16.count, kind: .comment))
                continue
            }
            if trimmed.hasPrefix("[") {
                a.spans.append(.init(location: line.start + lead, length: trimmed.utf16.count, kind: .section))
                let name = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t")).lowercased()
                section = name == "peer" ? "Peer" : "Interface"
                if name == "peer" { peerIndex += 1 }
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let keyPart = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let keyLen = trimmed[..<eq].utf16.count
            let lk = keyPart.lowercased()
            let kind: HighlightSpan.Kind = wgKnownKeys.contains(lk) ? .key : .ignoredKey
            a.spans.append(.init(location: line.start + lead, length: keyLen, kind: kind))
            let valueStart = trimmed.index(after: eq)
            let value = trimmed[valueStart...]
            let valueLead = value.utf16.count - value.drop { $0 == " " }.utf16.count
            let valueOffset = lead + keyLen + 1 + valueLead
            let valueText = value.trimmingCharacters(in: .whitespaces)
            if !valueText.isEmpty {
                let isNumber = Int(valueText) != nil
                a.spans.append(.init(location: line.start + valueOffset, length: valueText.utf16.count, kind: isNumber ? .number : .value))
            }
            if lk == "privatekey" || lk == "presharedkey" { a.secretLines[i] = valueOffset }
            let field = section == "Peer" ? "Peer[\(peerIndex)].\(keyPart)" : "Interface.\(keyPart)"
            fieldLines[field.lowercased()] = fieldLines[field.lowercased()] ?? (i + 1)
            fieldLines[keyPart.lowercased()] = fieldLines[keyPart.lowercased()] ?? (i + 1)
        }
        func lineFor(_ directive: String?) -> Int? {
            guard let d = directive?.lowercased() else { return nil }
            if let l = fieldLines[d] { return l }
            if let dot = d.lastIndex(of: ".") { return fieldLines[String(d[d.index(after: dot)...])] }
            return nil
        }
        let result = WGImporter.importProfile(Array(text.utf8))
        for item in result.report.items {
            a.issues.append(EditorIssue(id: 0, line: item.line ?? lineFor(item.directive), severity: severity(item.group),
                                        message: item.message(profileName: nil)))
        }
        a.summary = result.verdict == .rejected ? nil : result.summary
    }

    // MARK: OpenVPN

    /// Inline blocks whose body is a secret: masked until "Show".
    static let secretBlocks: Set<String> = ["key", "tls-auth", "tls-crypt", "tls-crypt-v2", "secret", "pkcs12",
                                            "auth-user-pass", "http-proxy-user-pass"]

    static func analyzeOVPN(_ text: String, lines: [Line], into a: inout EditorAnalysis) {
        var inBlock: String?
        for (i, line) in lines.enumerated() {
            let s = line.text
            let trimmed = s.drop { $0 == " " || $0 == "\t" }
            let lead = s.utf16.count - trimmed.utf16.count
            let t = trimmed.trimmingCharacters(in: .whitespaces)
            if let block = inBlock {
                if t.lowercased().hasPrefix("</\(block)") {
                    a.spans.append(.init(location: line.start + lead, length: trimmed.utf16.count, kind: .inlineTag))
                    inBlock = nil
                } else if secretBlocks.contains(block), !t.isEmpty {
                    a.secretLines[i] = lead
                }
                continue
            }
            if t.hasPrefix("#") || t.hasPrefix(";") {
                a.spans.append(.init(location: line.start + lead, length: trimmed.utf16.count, kind: .comment))
                continue
            }
            if t.hasPrefix("<"), t.hasSuffix(">"), !t.hasPrefix("</") {
                inBlock = String(t.dropFirst().dropLast()).lowercased()
                a.spans.append(.init(location: line.start + lead, length: trimmed.utf16.count, kind: .inlineTag))
                continue
            }
            guard !t.isEmpty else { continue }
            // Directive name, then arguments, scanned in UTF-16 offsets.
            var offset = line.start + lead, tokenStart = 0, token = "", isFirst = true
            func emit() {
                guard !token.isEmpty else { return }
                let length = token.utf16.count
                if isFirst {
                    let lname = token.lowercased().replacingOccurrences(of: "--", with: "")
                    let kind: HighlightSpan.Kind = switch OVPNEngineSupport.classify(lname) {
                    case .mapped: .key
                    case .ignoredWarn, .ignoredSilent, .dropped: .ignoredKey
                    case .unsupported, nil: .forbiddenKey
                    }
                    a.spans.append(.init(location: tokenStart, length: length, kind: kind))
                    isFirst = false
                } else {
                    a.spans.append(.init(location: tokenStart, length: length, kind: Int(token) != nil ? .number : .value))
                }
                token = ""
            }
            for ch in trimmed {
                if ch == " " || ch == "\t" { emit() } else {
                    if token.isEmpty { tokenStart = offset }
                    token.append(ch)
                }
                offset += String(ch).utf16.count
            }
            emit()
        }
        let result = OVPNImporter.importProfile(Array(text.utf8))
        for item in result.report.items {
            a.issues.append(EditorIssue(id: 0, line: item.line, severity: severity(item.group), message: item.message(profileName: nil)))
        }
        a.summary = result.verdict == .rejected ? nil : result.summary
    }
}

// MARK: - Model

@MainActor @Observable final class EditorModel {
    enum Phase: Equatable { case loading, ready, failed(String) }
    enum EngineState: Equatable { case notChecked, checking, passed, rejected(String) }

    private(set) var target: EditorTarget
    var phase: Phase = .loading
    var name = ""
    private(set) var savedName = ""
    var kind: VPNProtocolKind
    var text = "" { didSet { if text != oldValue { scheduleAnalysis() } } }
    private(set) var savedText = ""
    private(set) var analysis = EditorAnalysis()
    var keyRevealed = false
    /// 0-based line of the caret, for the Reference pane.
    var caretLine = 0
    /// A line (1-based) the text view should scroll to and select; cleared by the view.
    var jumpRequest: Int?
    var engine: EngineState = .notChecked
    var isSaving = false
    var saveError: String?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(target: EditorTarget) {
        self.target = target
        self.kind = target.newKind ?? .wireGuard
    }

    var isNew: Bool { target.profileID == nil }
    var isDirty: Bool { text != savedText || name != savedName }
    var errors: [EditorIssue] { analysis.issues.filter { $0.severity == .error } }
    var canSave: Bool { isDirty && errors.isEmpty && !isSaving && !name.trimmingCharacters(in: .whitespaces).isEmpty && phase == .ready }

    /// Why Save is disabled (tooltip, §6.9).
    var saveDisabledReason: String? {
        if !errors.isEmpty {
            return String(AttributedString(localized: "Fix ^[\(errors.count) error](inflect: true) to save.", comment: "Editor Save tooltip").characters)
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter a name to save.", comment: "Editor Save tooltip") }
        if !isDirty { return String(localized: "No changes to save.", comment: "Editor Save tooltip") }
        return nil
    }

    /// Text of the caret's line, set by the text view (no whole-document split per caret move, UI-M14).
    var caretLineText = ""
    /// An undoable whole-buffer replacement for the text view to apply (Revert, UI-M12).
    var pendingReplacement: String?

    /// The key or directive under the caret.
    var referenceKey: String? {
        let t = caretLineText.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") || t.hasPrefix(";") || t.isEmpty { return nil }
        switch kind {
        case .wireGuard:
            if t.hasPrefix("[") { return t.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
            return t.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) }
        case .openVPN:
            if t.hasPrefix("<") { return t.trimmingCharacters(in: CharacterSet(charactersIn: "</>")) }
            return t.split(separator: " ").first.map(String.init)
        }
    }

    func load(using backend: (any ProfileEditorBackend)?) async {
        guard let backend else {
            apply(EditorDocument(name: "", kind: kind, text: EditorTemplates.text(for: kind)))
            return
        }
        do {
            apply(try await backend.load(target))
        } catch {
            phase = .failed((error as? LPError)?.code.message(detail: nil) ?? error.localizedDescription)
        }
    }

    func apply(_ doc: EditorDocument) {
        kind = doc.kind
        name = doc.name
        savedName = doc.name
        text = doc.text
        savedText = doc.text
        phase = .ready
        analyzeNow()
    }

    /// Back to the saved version as one undoable edit (⌘Z brings the changes back).
    func revert() {
        pendingReplacement = savedText
        name = savedName
        saveError = nil
    }

    /// Saves after the OpenVPN engine check [7] when a validator exists. Returns true on success.
    func save(mode: EditorSaveMode, using backend: (any ProfileEditorBackend)?) async -> Bool {
        guard canSave, let backend else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        if kind == .openVPN, let validator = backend.openVPNValidator {
            engine = .checking
            let imported = OVPNImporter.importProfile(Array(text.utf8))
            let checked = await OVPNImporter.validateWithEngine(imported, validator: validator)
            switch checked.engineValidation {
            case .passed: engine = .passed
            case .failed:
                let reason = checked.report.items(in: .notSupported).last?.message(profileName: nil)
                    ?? String(localized: "LockPlus's OpenVPN engine rejected the profile.", comment: "Editor engine check")
                engine = .rejected(reason)
                return false
            case .notChecked: engine = .notChecked
            }
        }
        do {
            let id = try await backend.save(target, name: name, text: text, mode: mode)
            target = .existing(id)
            savedText = text
            savedName = name
            return true
        } catch {
            saveError = (error as? LPError)?.code.message(detail: (error as? LPError)?.detail) ?? error.localizedDescription
            return false
        }
    }

    /// "Don't Save" on close: drop the edits now (not as an undoable replacement).
    func discardChanges() {
        text = savedText
        name = savedName
    }

    /// Clears the secret-bearing buffer when the window closes (§6.9: no autosave, nothing kept).
    func discard() {
        analysisTask?.cancel()
        text = ""
        savedText = ""
    }

    private func analyzeNow() {
        generation += 1
        analysis = EditorAnalyzer.analyzeSync(text, kind: kind, generation: generation)
    }

    /// 150 ms debounce, parsed off the main actor (DESIGN §11.4).
    private func scheduleAnalysis() {
        analysisTask?.cancel()
        generation += 1
        let gen = generation, snapshot = text, kind = kind
        analysisTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let result = await EditorAnalyzer.analyze(snapshot, kind: kind, generation: gen)
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.analysis = result
            if self.engine != .checking { self.engine = .notChecked }
        }
    }
}
