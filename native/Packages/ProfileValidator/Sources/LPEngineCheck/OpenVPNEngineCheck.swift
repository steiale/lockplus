import Foundation
import LPModel
import LPParsing
import LPOptionsParser
import LPWire
import OpenVPN3Shim

/// The profile checks [1]–[7] (DESIGN §8.1) as pure functions of the payload bytes. They run in the validator service
/// (PLAN-2.0.2 §1.1); the extension runs only [1]–[5] (+ [6] at start) and never `evaluate`.
///
/// OpenVPN:
/// - [1]–[6]: `OVPNImporter.importProfile` with the shim as the [6] parser; any Not-supported item rejects.
/// - The payload itself must be a stream both parsers agree on: our tokenizer's stream of the PAYLOAD bytes equals
///   openvpn3's OptionList of the same bytes, and it carries no inline credentials (extracted at import, §8.1 [5]).
/// - [7a]/[7b]: `eval_config` + `ClientOptions` construction, `disableClientCert` = !(cert && key); rejected on an
///   EvalConfig error, any [7b] exception, or a rejecting log category.
public enum OpenVPNEngineCheck {
    /// openvpn3's non-fatal log categories that still reject (§8.1 [7b]).
    public static let rejectingCategories = ["Unused ignored meta options", "Unused options, probably specified multiple times"]

    /// [1]–[6] on the payload + the payload-stream differential + [7a]/[7b]. `disableClientCert` nil = derived from the
    /// payload (cert and key present). Pure function of the bytes; never throws.
    public static func evaluate(payload: SecretBytes, disableClientCert: Bool?) -> ValidateProfileReply {
        // [1]–[6]
        let imp = payload.withUnsafeBytes { OVPNImporter.importProfile($0, optionsParser: ShimOptionsParser()) }
        if let e = firstBlocking(imp.report) { return ValidateProfileReply(error: e) }
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
        let dcc = disableClientCert ?? !hasCertAndKey(payload)
        let evaluated = payload.withUnsafeBytes { b -> LPOpenVPN3Evaluation? in
            b.baseAddress.map { LPOpenVPN3Profile.evaluateBytes($0, length: b.count, disableClientCert: dcc) }
        }
        guard let ev = evaluated else { return ValidateProfileReply(error: LPError(.profileInvalid, detail: "empty")) }
        var reply = ValidateProfileReply(error: nil, autologin: ev.autologin,
                                         staticChallenge: ev.staticChallenge.isEmpty ? nil : clip(ev.staticChallenge, ValidateProfileReply.maxStaticChallenge),
                                         staticChallengeEcho: ev.staticChallengeEcho,
                                         privateKeyPasswordRequired: ev.privateKeyPasswordRequired,
                                         warnings: warnings(imp.report))
        if let category = engineRejection(ev) {
            reply.error = LPError(.unsupportedDirective, detail: category)
            reply.rejectedCategory = category
        }
        return reply
    }

    /// Round 1 (Fable N2): whole characters up to `max` UTF-8 bytes, so the reply always passes the wire's caps.
    static func clip(_ s: String, _ max: Int) -> String {
        var out = "", n = 0
        for ch in s {
            let c = String(ch).utf8.count
            if n + c > max { break }
            out.append(ch); n += c
        }
        return out
    }

    /// The openvpn3 category text of a [7] rejection, or nil when accepted.
    public static func engineRejection(_ ev: LPOpenVPN3Evaluation) -> String? {
        if ev.evalError { return category(ev.evalMessage) }
        if !ev.optionsOk { return category(ev.optionsError) }
        for c in rejectingCategories where ev.log.contains(where: { $0.contains(c) }) { return c }
        return nil
    }

    // Round 1 (Fable N5): the rules the extension needs too live in LPOptionsParser (`ProfileCheckRules`), so the
    // extension links no part of this target; these forward for the service and the tests.
    public static func category(_ message: String) -> String { ProfileCheckRules.category(message) }
    public static func firstBlocking(_ report: ImportReport) -> LPError? { ProfileCheckRules.firstBlocking(report) }
    public static func warnings(_ report: ImportReport) -> [String] { ProfileCheckRules.warnings(report) }

    /// Both `<cert>` and `<key>` blocks present. Only the directive lines' first 64 bytes are decoded, never inline
    /// bodies past a tag (same rule as the engine's `CanonicalProfileFacts`).
    static func hasCertAndKey(_ p: SecretBytes) -> Bool {
        let tags = p.withUnsafeBytes { b -> Set<String> in
            var found: Set<String> = []
            var start = 0
            for i in 0...b.count where i == b.count || b[i] == 0x0A {
                let len = min(64, i - start)
                if len > 0 {
                    let line = String(decoding: UnsafeRawBufferPointer(rebasing: b[start..<(start + len)]), as: UTF8.self)
                    if line == "<cert>" || line == "<key>" { found.insert(line) }
                }
                start = i + 1
            }
            return found
        }
        return tags.contains("<cert>") && tags.contains("<key>")
    }
}

public enum WireGuardEngineCheck {
    /// `WGImporter` (size cap, parse, validate); any Not-supported item rejects.
    public static func evaluate(payload: SecretBytes) -> ValidateProfileReply {
        let r = payload.withUnsafeBytes { WGImporter.importProfile($0) }
        if let e = OpenVPNEngineCheck.firstBlocking(r.report) { return ValidateProfileReply(error: e) }
        return ValidateProfileReply(error: nil, warnings: OpenVPNEngineCheck.warnings(r.report))
    }
}
