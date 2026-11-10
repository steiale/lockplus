import Foundation
import LPModel
import LPParsing
import LPWire

/// §8.1 [7]: the extension's `validateProfile` (openvpn3 `eval_config` + `ClientOptions` construction) as the
/// importer's `OpenVPN3ProfileValidating`. Transport failures throw, so the importer records "Not yet verified"
/// (`EngineCheck.notChecked`) and Connect stays disabled until [7] passes.
struct XPCProfileValidator: OpenVPN3ProfileValidating {
    let service: any TunnelServicing

    func validate(canonical: String, disableClientCert: Bool) async throws -> OVPNEngineEvaluation {
        let req = ValidateProfileRequest(kind: .openVPN, payload: Data(canonical.utf8), disableClientCert: disableClientCert)
        let r = try await service.call(.validateProfile, req, as: ValidateProfileReply.self)
        let verdict: OVPNEngineEvaluation.Verdict = r.isValid
            ? .accepted
            : .rejected(category: r.rejectedCategory ?? r.error?.detail ?? "Not supported")
        return OVPNEngineEvaluation(verdict: verdict, autologin: r.autologin, staticChallenge: r.staticChallenge,
                                   staticChallengeEcho: r.staticChallengeEcho,
                                   privateKeyPasswordRequired: r.privateKeyPasswordRequired)
    }
}
