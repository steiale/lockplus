import Foundation
import LPModel
import LPParsing
import LPWire
import LPXPCClient

/// §8.1 [7] in the sandboxed validator service (PLAN-2.0.2 §1.4): `eval_config` + `ClientOptions` construction as the
/// importer's `OpenVPN3ProfileValidating`. Transport failures throw, so the importer records "Not yet verified"
/// (`EngineCheck.notChecked`) and Connect stays disabled until [7] passes.
///
/// Only a file the service died on twice (`.profileCheckCrashed`) is refused (`.checkCrashed`: "LockPlus couldn't
/// check this file safely."). Round 1 (Fable M1, Sonnet M1): a timeout (the service's watchdog or the client's, each
/// already retried once on a fresh process) and a `hello` that timed out throw like any unavailability: the file is
/// "not yet verified" and checked again later, never recorded as refused.
struct ServiceProfileValidator: OpenVPN3ProfileValidating {
    let client: ValidatorClient

    func validate(canonical: String, disableClientCert: Bool) async throws -> OVPNEngineEvaluation {
        let req = ValidateProfileRequest(kind: .openVPN, payload: Data(canonical.utf8), disableClientCert: disableClientCert)
        let r: ValidateProfileReply
        do { r = try await client.evaluate(req) } catch {
            if let v = Self.verdict(for: error) { return OVPNEngineEvaluation(verdict: v) }
            throw error
        }
        let verdict: OVPNEngineEvaluation.Verdict = r.isValid
            ? .accepted
            : .rejected(category: r.rejectedCategory ?? r.error?.detail ?? "Not supported")
        return OVPNEngineEvaluation(verdict: verdict, autologin: r.autologin, staticChallenge: r.staticChallenge,
                                    staticChallengeEcho: r.staticChallengeEcho,
                                    privateKeyPasswordRequired: r.privateKeyPasswordRequired)
    }

    /// The client errors that are a verdict on the file: only `.profileCheckCrashed`. Everything else (`.timeout`,
    /// `.extensionUnavailable`, `.versionMismatch`, …) is "not checked" and is rethrown.
    static func verdict(for error: LPError) -> OVPNEngineEvaluation.Verdict? {
        error.code == .profileCheckCrashed ? .checkCrashed : nil
    }
}

/// The zip read in the sandboxed service (§3.5). The app only sees fixed-shape entries and issues; a service that is
/// unavailable or died on the archive is `.checkUnavailable` ("couldn't read the archive").
struct ServiceZipArchiveReader: ZipArchiveReading {
    let client: ValidatorClient

    func read(_ data: Data) async throws(ZipArchiveError) -> ZipProfiles {
        let r: ReadArchiveReply
        do { r = try await client.readArchive(data) } catch {
            if error.code == .payloadTooLarge { throw .tooLarge }
            throw .checkUnavailable
        }
        if let e = r.archiveError { throw e }
        return ZipProfiles(entries: r.entries.map { ($0.name, Array($0.bytes)) }, issues: r.issues)
    }
}
