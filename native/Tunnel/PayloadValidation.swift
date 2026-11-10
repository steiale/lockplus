import Foundation
import LPModel
import LPParsing
import LPWire
import OpenVPN3Shim
import TunnelEngine

/// LPParsing's [6] seam (`OpenVPN3OptionsParsing`) over the shim's OptionList parser, in the extension
/// (DESIGN §8.1). The shim applies openvpn3's client profile limits (size, line length, directive size).
struct ShimOptionsParser: OpenVPN3OptionsParsing {
    struct Refused: Error, Sendable { let reason: String }

    func parse(canonical: String) throws -> [[String]] {
        try Self.parse(bytes: Array(canonical.utf8))
    }

    static func parse(bytes: some ContiguousBytes) throws -> [[String]] {
        var err: NSString?
        let r = bytes.withUnsafeBytes { b -> [[String]]? in
            guard let base = b.baseAddress else { return [] }
            return LPOpenVPN3Profile.parseOptionsBytes(base, length: b.count, error: &err)
        }
        guard let r else { throw Refused(reason: (err as String?) ?? "refused") }
        return r
    }
}

/// The extension's re-validation (DESIGN §6.4 step 2, §8.1 "the extension repeats [1]–[7] in provisionProfile and
/// [1]–[6] before every startTunnel", §9.1). One implementation for provision, `validateProfile` and every start.
///
/// OpenVPN:
/// - [1]–[6]: `OVPNImporter.importProfile` with the shim as the [6] parser; any Not-supported item rejects.
/// - The payload itself must be a stream both parsers agree on: our tokenizer's stream of the PAYLOAD bytes equals
///   openvpn3's OptionList of the same bytes (so the engine only ever sees text the two parsers agree on, even if
///   re-normalizing would change it), and it carries no inline credentials (they are extracted at import, §8.1 [5]).
/// - [7a]/[7b]: `eval_config` + `ClientOptions` construction, `disableClientCert` = !(cert && key); rejected on an
///   EvalConfig error, any [7b] exception, or a rejecting log category.
/// WireGuard: `WGImporter` (size cap, parse, validate); any Not-supported item rejects.
struct ExtensionPayloadValidator: PayloadValidator {
    /// openvpn3's non-fatal log categories that still reject (§8.1 [7b]).
    static let rejectingCategories = ["Unused ignored meta options", "Unused options, probably specified multiple times"]

    func validate(kind: VPNProtocolKind, payload: SecretBytes) throws(LPTunnelError) {
        let r = evaluate(kind: kind, payload: payload, disableClientCert: nil)
        if let e = r.error { throw LPTunnelError(e.code, detail: e.detail) }
    }

    /// The full verdict for `validateProfile` (and `validate`). `disableClientCert` nil = derived from the payload.
    func evaluate(kind: VPNProtocolKind, payload: SecretBytes, disableClientCert: Bool?) -> ValidateProfileReply {
        switch kind {
        case .wireGuard: return wireGuard(payload)
        case .openVPN: return openVPN(payload, disableClientCert: disableClientCert)
        }
    }

    private func wireGuard(_ payload: SecretBytes) -> ValidateProfileReply {
        let r = payload.withUnsafeBytes { WGImporter.importProfile($0) }
        if let e = Self.firstBlocking(r.report) { return ValidateProfileReply(error: e) }
        return ValidateProfileReply(error: nil, warnings: Self.warnings(r.report))
    }

    private func openVPN(_ payload: SecretBytes, disableClientCert: Bool?) -> ValidateProfileReply {
        // [1]–[6]
        let imp = payload.withUnsafeBytes { OVPNImporter.importProfile($0, optionsParser: ShimOptionsParser()) }
        if let e = Self.firstBlocking(imp.report) { return ValidateProfileReply(error: e) }
        guard imp.differential == .passed else {
            return ValidateProfileReply(error: LPError(.profileInvalid, detail: "parser disagreement"))
        }
        guard imp.credentials.isEmpty else {
            return ValidateProfileReply(error: LPError(.profileInvalid, detail: "inline credentials in the payload"))
        }
        // [6] on the payload bytes themselves.
        let ours: [[String]]
        switch payload.withUnsafeBytes({ OVPNTokenizer.parse($0) }) {
        case .success(let ds): ours = OVPNCanonical.stream(of: ds)
        case .failure: return ValidateProfileReply(error: LPError(.profileInvalid, detail: "syntax"))
        }
        guard let theirs = try? payload.withUnsafeBytes({ try ShimOptionsParser.parse(bytes: $0) }), theirs == ours else {
            return ValidateProfileReply(error: LPError(.profileInvalid, detail: "parser disagreement"))
        }
        // [7]
        let dcc = disableClientCert ?? !CanonicalProfileFacts().hasCertAndKey(payload)
        let evaluated = payload.withUnsafeBytes { b -> LPOpenVPN3Evaluation? in
            b.baseAddress.map { LPOpenVPN3Profile.evaluateBytes($0, length: b.count, disableClientCert: dcc) }
        }
        guard let ev = evaluated else { return ValidateProfileReply(error: LPError(.profileInvalid, detail: "empty")) }
        var reply = ValidateProfileReply(error: nil, autologin: ev.autologin,
                                         staticChallenge: ev.staticChallenge.isEmpty ? nil : ev.staticChallenge,
                                         staticChallengeEcho: ev.staticChallengeEcho,
                                         privateKeyPasswordRequired: ev.privateKeyPasswordRequired,
                                         warnings: Self.warnings(imp.report))
        if let category = Self.engineRejection(ev) {
            reply.error = LPError(.unsupportedDirective, detail: category)
            reply.rejectedCategory = category
        }
        return reply
    }

    /// The openvpn3 category text of a [7] rejection, or nil when accepted.
    static func engineRejection(_ ev: LPOpenVPN3Evaluation) -> String? {
        if ev.evalError { return category(ev.evalMessage) }
        if !ev.optionsOk { return category(ev.optionsError) }
        for c in rejectingCategories where ev.log.contains(where: { $0.contains(c) }) { return c }
        return nil
    }

    /// openvpn3's message up to the first ':' (its category, e.g. "UNUSED_OPTIONS"), ≤ 120 chars. The rest can
    /// quote option arguments, which may be secrets.
    static func category(_ message: String) -> String {
        let head = message.split(separator: ":", maxSplits: 1).first.map(String.init) ?? message
        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "rejected by openvpn3" : String(t.prefix(120))
    }

    /// The first Not-supported item as an error: crypto → .legacyCryptoUnavailable, file/syntax → .profileInvalid,
    /// everything else → .unsupportedDirective. Detail = line, directive and reason text (never an argument).
    static func firstBlocking(_ report: ImportReport) -> LPError? {
        guard let item = report.items(in: .notSupported).first else { return nil }
        let code: LPErrorCode
        switch item.reason {
        case .outdatedCipher, .weakDigest, .cipherNone: code = .legacyCryptoUnavailable
        case .fileTooLarge, .containsNULByte, .syntax, .invalidUTF8, .controlCharacters, .parserDisagreement,
             .notAClientProfile, .noRemote, .limitExceeded:
            code = .profileInvalid
        default: code = .unsupportedDirective
        }
        var d = ""
        if let l = item.line { d += "line \(l) " }
        if let n = item.directive { d += "\(n): " }
        d += item.message()
        return LPError(code, detail: String(d.prefix(LPError.maxDetailLength)))
    }

    /// Security warnings and ignored items for the import report (≤ 50, ≤ 512 chars each).
    static func warnings(_ report: ImportReport) -> [String] {
        report.items.filter { $0.group == .securityWarning || $0.group == .ignored }.prefix(50).map { item in
            var d = ""
            if let n = item.directive { d += "\(n): " }
            d += item.message()
            return String(d.prefix(512))
        }
    }
}
