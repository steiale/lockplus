import Foundation
import LPModel
import LPParsing

/// Round 1 (Fable N5): the rules both the validator service and the extension apply to a profile's import report and
/// to openvpn3's messages. In LPOptionsParser (with the [6] parser) so the extension needs no part of LPEngineCheck,
/// whose `OpenVPNEngineCheck.evaluate` is [7] (`eval_config`, the service's job only).
public enum ProfileCheckRules {
    /// openvpn3's message up to the first ':' (its category, e.g. "UNUSED_OPTIONS"), ≤ 120 chars. The rest can
    /// quote option arguments, which may be secrets.
    public static func category(_ message: String) -> String {
        let head = message.split(separator: ":", maxSplits: 1).first.map(String.init) ?? message
        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "rejected by openvpn3" : String(t.prefix(120))
    }

    /// The first Not-supported item as an error: crypto → .legacyCryptoUnavailable, file/syntax → .profileInvalid,
    /// everything else → .unsupportedDirective. Detail = line, directive and reason text (never an argument).
    public static func firstBlocking(_ report: ImportReport) -> LPError? {
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
    public static func warnings(_ report: ImportReport) -> [String] {
        report.items.filter { $0.group == .securityWarning || $0.group == .ignored }.prefix(50).map { item in
            var d = ""
            if let n = item.directive { d += "\(n): " }
            d += item.message()
            return String(d.prefix(512))
        }
    }

}
