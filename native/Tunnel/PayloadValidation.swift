import Foundation
import LPOptionsParser
import LPModel
import LPParsing
import LPWire
import TunnelEngine

/// The extension's re-validation of a payload (DESIGN §6.4 step 2, §8.1, §9.1), 2.0.2 (PLAN §1.5). The extension is a root
/// process, so it runs only what is memory-safe at PROVISION; the checks that need openvpn3 (`eval_config`, [7]) live in the
/// app's validator service, and the one parser differential the extension still needs runs at START, on the session's own
/// payload, right before its engine parses it. No `evaluate`, no `evaluateBytes` here (lint.sh enforces it).
///
/// OpenVPN
/// - provision: `OVPNImporter.importProfile(payload)` with no [6] parser, any Not-supported item rejects; no inline
///   credentials (extracted at import, §8.1 [5]); and the payload is a canonical fixed point (the normaliser would emit
///   it unchanged), which is what lets the differential stay out of provisioning: the app compared that exact stream
///   with openvpn3 at import.
/// - start: the provision checks + the [6] differential of the payload bytes: our tokenizer's stream equals openvpn3's
///   OptionList of the same bytes (`ShimOptionsParser`, from LPOptionsParser; round 1 Fable N5: the extension links no part of LPEngineCheck).
/// WireGuard: `WGImporter` (size cap, parse, validate); any Not-supported item rejects. Both moments are the same.
struct ExtensionPayloadValidator: PayloadValidator {
    func validateForProvision(kind: VPNProtocolKind, payload: SecretBytes) throws(LPTunnelError) {
        switch kind {
        case .wireGuard: try wireGuard(payload)
        case .openVPN: try openVPN(payload, differential: false)
        }
    }

    func validateForStart(kind: VPNProtocolKind, payload: SecretBytes) throws(LPTunnelError) {
        switch kind {
        case .wireGuard: try wireGuard(payload)
        case .openVPN: try openVPN(payload, differential: true)
        }
    }

    private func wireGuard(_ payload: SecretBytes) throws(LPTunnelError) {
        let r = payload.withUnsafeBytes { WGImporter.importProfile($0) }
        if let e = ProfileCheckRules.firstBlocking(r.report) { throw LPTunnelError(e.code, detail: e.detail) }
    }

    private func openVPN(_ payload: SecretBytes, differential: Bool) throws(LPTunnelError) {
        // [1]–[5]: no [6] parser, so nothing here touches openvpn3.
        let imp = payload.withUnsafeBytes { OVPNImporter.importProfile($0) }
        if let e = ProfileCheckRules.firstBlocking(imp.report) { throw LPTunnelError(e.code, detail: e.detail) }
        guard imp.credentials.isEmpty else { throw LPTunnelError(.profileInvalid, detail: "inline credentials in the payload") }
        guard payload.withUnsafeBytes({ OVPNImporter.isCanonicalFixedPoint($0) }) else {
            throw LPTunnelError(.profileInvalid, detail: "payload is not canonical")
        }
        guard differential else { return }
        // [6] on the payload bytes themselves, at start only.
        let ours: [[String]]
        switch payload.withUnsafeBytes({ OVPNTokenizer.parse($0) }) {
        case .success(let ds): ours = OVPNCanonical.stream(of: ds)
        case .failure: throw LPTunnelError(.profileInvalid, detail: "syntax")
        }
        guard let theirs = try? payload.withUnsafeBytes({ try ShimOptionsParser.parse(bytes: $0) }), theirs == ours else {
            throw LPTunnelError(.profileInvalid, detail: "parser disagreement")
        }
    }
}
