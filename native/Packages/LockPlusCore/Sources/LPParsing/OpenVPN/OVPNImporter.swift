import LPModel
// The OpenVPN import pipeline, steps [1]–[6] (DESIGN §8.1), plus the seams for [7] and the RouteProbe (§9.3).
//
//   untrusted bytes → [1] size cap, NUL → [2] tokenizer → [3] allowlist → [4] EngineSupport → [5] normalizer
//   → [6] OpenVPN3Options.parse(canonical) must equal our stream → (app) [7] validateProfile XPC
//
// [6] needs openvpn3's `OptionList` parser, which lives in P2a's OpenVPN3Shim package (module `OpenVPN3Options`,
// C++). LockPlusCore must not depend on it (§2.2), so the call goes through `OpenVPN3OptionsParsing`; the app and
// the extension pass their adapter. Without one, the result is `.notChecked` and must not be saved as verified.

/// [6]: openvpn3's own option parser over the canonical text (`OpenVPN3Options.parse`).
public protocol OpenVPN3OptionsParsing: Sendable {
    /// One entry per option, as `OptionList` holds them: `[name] + args`, or `[name, body]` for an inline block
    /// (body lines each followed by "\n"). Throws when openvpn3 refuses the text (size, line length, syntax).
    func parse(canonical: String) throws -> [[String]]
}

/// [7]: the extension's `validateProfile` (`eval_config` + `ClientOptions` construction, §8.1 [7a]/[7b]).
/// The app implements this over XPC (LPWire); tests use a fake.
public protocol OpenVPN3ProfileValidating: Sendable {
    func validate(canonical: String, disableClientCert: Bool) async throws -> OVPNEngineEvaluation
}

/// The [7a] `EvalConfig` fields the app needs, and the [7b] verdict.
public struct OVPNEngineEvaluation: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case accepted
        /// [7a] error, any [7b] exception, or a rejecting log category ("Unused ignored meta options", "probably
        /// specified multiple times"). `category` is openvpn3's category text, mapped to "Not supported" (§8.3).
        case rejected(category: String)
    }
    public var verdict: Verdict
    public var autologin: Bool
    public var staticChallenge: String?
    public var staticChallengeEcho: Bool
    public var privateKeyPasswordRequired: Bool

    public init(verdict: Verdict, autologin: Bool = false, staticChallenge: String? = nil, staticChallengeEcho: Bool = false,
                privateKeyPasswordRequired: Bool = false) {
        self.verdict = verdict
        self.autologin = autologin
        self.staticChallenge = staticChallenge
        self.staticChallengeEcho = staticChallengeEcho
        self.privateKeyPasswordRequired = privateKeyPasswordRequired
    }
}

/// RouteProbe (§9.3): compares an endpoint's route interface with the default route's. The implementation (Darwin
/// PF_ROUTE RTM_GET, name resolution) lives outside LPParsing; import only consumes its verdict.
public protocol EndpointRouteProbing: Sendable {
    /// The BSD name of the non-primary interface the endpoint is routed through, or nil when it uses the primary one
    /// (or can't be resolved now: the topology may differ later, so that is never a finding).
    func nonPrimaryInterface(for endpoint: ImportEndpoint) async -> String?
}

/// Where the profile stands after [6]/[7].
public enum EngineCheck: Sendable, Equatable {
    /// No openvpn3 parser/validator was available (e.g. the extension isn't running): saved as "Not yet verified",
    /// Connect disabled until [7] passes (§8.1).
    case notChecked
    case passed
    case failed
}

public struct OVPNImportResult: Sendable {
    public var verdict: ImportVerdict
    public var report: ImportReport
    /// The canonical payload (nil when rejected). This is what gets sealed and provisioned.
    public var canonicalText: String?
    public var stream: [[String]]?
    public var summary: ProfileSummary
    public var auth: AuthPolicy
    /// Secrets split off the payload (§6): stored in the credential store, never in the payload.
    public var credentials: ExtractedCredentials
    public var endpoints: [ImportEndpoint]
    public var legacyCrypto: Bool
    public var otpClass: Bool
    public var disableClientCert: Bool
    /// [6]
    public var differential: EngineCheck
    /// [7]
    public var engineValidation: EngineCheck
}

public enum OVPNImporter {
    /// Steps [1]–[6]. Synchronous and pure apart from the injected [6] parser.
    public static func importProfile(_ bytes: some Collection<UInt8>, options: OVPNNormalizerOptions = .init(),
                                     optionsParser: (any OpenVPN3OptionsParsing)? = nil) -> OVPNImportResult {
        var report = ImportReport()
        func rejected(_ r: ImportReport) -> OVPNImportResult {
            OVPNImportResult(verdict: .rejected, report: r, canonicalText: nil, stream: nil, summary: ProfileSummary(),
                             auth: AuthPolicy(), credentials: ExtractedCredentials(), endpoints: [], legacyCrypto: false,
                             otpClass: false, disableClientCert: true, differential: .notChecked, engineValidation: .notChecked)
        }
        // [1]
        if bytes.count > OVPNImportLimits.maxRawBytes {
            report.add(.notSupported, .fileTooLarge(limitBytes: OVPNImportLimits.maxRawBytes))
            return rejected(report)
        }
        // [2]
        let ds: [OVPNDirective]
        switch OVPNTokenizer.parse(bytes) {
        case .success(let x): ds = x
        case .failure(let e):
            report.add(.notSupported, line: e.line, e.message.contains("NUL byte") ? .containsNULByte : .syntax(detail: e.message))
            return rejected(report)
        }
        // [3]–[5]
        let n = OVPNNormalizer.normalize(ds, options: options)
        var result = OVPNImportResult(verdict: ImportVerdict(report: n.report), report: n.report, canonicalText: n.canonicalText,
                                      stream: n.stream, summary: n.summary, auth: n.auth, credentials: n.credentials,
                                      endpoints: n.endpoints, legacyCrypto: n.legacyCrypto, otpClass: n.otpClass,
                                      disableClientCert: n.disableClientCert, differential: .notChecked,
                                      engineValidation: .notChecked)
        guard let text = n.canonicalText, let stream = n.stream else { return result }
        // Self-check: the canonical text must re-tokenize to the stream it was emitted from (§15.4).
        guard case .success(let again) = OVPNTokenizer.parse(Array(text.utf8)), OVPNCanonical.stream(of: again) == stream else {
            result.report.add(.notSupported, .parserDisagreement)
            return withoutPayload(result)
        }
        // [6]
        if let parser = optionsParser {
            let theirs = try? parser.parse(canonical: text)
            if theirs == stream {
                result.differential = .passed
            } else {
                result.differential = .failed
                result.report.add(.notSupported, .parserDisagreement)
                return withoutPayload(result)
            }
        }
        return result
    }

    /// Step [7] (app side, via the extension's `validateProfile`). Call after `importProfile` passed.
    public static func validateWithEngine(_ result: OVPNImportResult, validator: any OpenVPN3ProfileValidating) async -> OVPNImportResult {
        guard let text = result.canonicalText, result.verdict != .rejected else { return result }
        var r = result
        do {
            let ev = try await validator.validate(canonical: text, disableClientCert: r.disableClientCert)
            switch ev.verdict {
            case .accepted:
                r.engineValidation = .passed
                if ev.privateKeyPasswordRequired { r.auth.needsKeyPassphrase = true }
                if !ev.autologin && r.credentials.password == nil { r.auth.needsUserPass = true }
            case .rejected(let category):
                r.engineValidation = .failed
                r.report.add(.notSupported, .engineValidationFailed(category: category))
                r = withoutPayload(r)
            }
        } catch {
            r.engineValidation = .notChecked
        }
        return r
    }

    /// Adds the §9.3 warning for endpoints routed through a non-primary interface. Never a rejection.
    public static func probeRoutes(_ result: OVPNImportResult, probe: any EndpointRouteProbing) async -> OVPNImportResult {
        var r = result
        var seen = Set<ImportEndpoint>()
        let unique = result.endpoints.filter { seen.insert($0).inserted }
        // Concurrent (a slow resolver costs one deadline, not one per endpoint); warnings are added in endpoint order.
        let found = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, e) in unique.enumerated() {
                group.addTask { @Sendable in (i, await probe.nonPrimaryInterface(for: e)) }
            }
            var out: [Int: String] = [:]
            for await (i, iface) in group { if let iface { out[i] = iface } }
            return out
        }
        for i in found.keys.sorted() {
            r.report.add(.securityWarning, directive: "remote", .serverOnOtherNetwork(interface: found[i]!))
        }
        r.verdict = ImportVerdict(report: r.report)
        return r
    }

    static func withoutPayload(_ r: OVPNImportResult) -> OVPNImportResult {
        var r = r
        r.verdict = .rejected
        r.canonicalText = nil
        r.stream = nil
        r.credentials = ExtractedCredentials()
        return r
    }
}
