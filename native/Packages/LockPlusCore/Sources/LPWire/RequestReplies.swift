import Foundation
import LPModel

// Request and reply bodies for the §5.2 methods beyond hello/provision/auth. Caps: LPMethod.requestLimit/replyLimit
// (bytes) plus the per-message counts below. Every profile-scoped request carries `profileID`; the extension checks
// ownerUID against the peer's EUID (`.notOwner`, §5.4).

/// `updateCredentials` (secret-bearing: only after a validated hello).
public struct UpdateCredentialsRequest: Codable, Sendable {
    public var profileID: UUID
    public var credentials: CredentialRecord
    public init(profileID: UUID, credentials: CredentialRecord) { self.profileID = profileID; self.credentials = credentials }
}

/// `cancelAuth`.
public struct CancelAuthRequest: Codable, Sendable, Equatable {
    public var promptID: UUID
    public init(promptID: UUID) { self.promptID = promptID }
}

/// `pendingAuthPrompt` reply: the awaitingAuth prompt or a stashed next-start prompt; nil = none.
/// (Request: `ProfileRequest`.)
public struct PendingAuthPromptReply: Codable, Sendable, Equatable {
    public var prompt: AuthPrompt?
    public init(prompt: AuthPrompt?) { self.prompt = prompt }
}

/// One provisioned profile of the calling uid (`listProvisioned` reply; request: `EmptyRequest`).
public struct ProvisionedEntry: Codable, Sendable, Equatable {
    public var id: UUID
    public var revision: UInt64
    /// hex SHA-256 of the canonical payload, as in Profile.payloadDigest (§3.1)
    public var digest: String
    public init(id: UUID, revision: UInt64, digest: String) { self.id = id; self.revision = revision; self.digest = digest }
}

public struct ListProvisionedReply: Codable, Sendable, Equatable {
    public static let maxEntries = 500
    public var entries: [ProvisionedEntry]
    public init(entries: [ProvisionedEntry]) { self.entries = entries }
}

/// The [1]–[7] check of canonical text (§8.1 [7a] `eval_config` + [7b] `ClientOptions` construction). 2.0.2: sent to
/// the sandboxed validator service as `evaluateProfile` (`OpenVPN3ProfileValidating` in the app: import, editor,
/// migrator, re-verify); the extension's `validateProfile` answers `.extensionBusy`.
public struct ValidateProfileRequest: Codable, Sendable {
    public var kind: VPNProtocolKind
    /// Canonical text, ≤ 256 KiB by openvpn3 accounting.
    public var payload: Data
    /// Mirrors the shim rule `disableClientCert = externalPki` (ref/openvpn3 §1.5).
    public var disableClientCert: Bool
    public init(kind: VPNProtocolKind, payload: Data, disableClientCert: Bool = false) {
        self.kind = kind; self.payload = payload; self.disableClientCert = disableClientCert
    }
}

public struct ValidateProfileReply: Codable, Sendable, Equatable {
    /// nil = accepted. Otherwise .profileInvalid / .unsupportedDirective / .legacyCryptoUnavailable with a non-secret detail.
    public var error: LPError?
    /// For a rejection by openvpn3: its category text ("Unused ignored meta options", …), mapped to "Not supported" (§8.3).
    public var rejectedCategory: String?
    /// [7a] EvalConfig fields the import needs (OpenVPN only; false/nil for WireGuard).
    public var autologin: Bool
    public var staticChallenge: String?
    public var staticChallengeEcho: Bool
    public var privateKeyPasswordRequired: Bool
    /// Non-fatal notes for the import report (never echo profile lines; ≤ 50, ≤ 512 chars each).
    public var warnings: [String]

    public init(error: LPError?, rejectedCategory: String? = nil, autologin: Bool = false, staticChallenge: String? = nil,
                staticChallengeEcho: Bool = false, privateKeyPasswordRequired: Bool = false, warnings: [String] = []) {
        self.error = error; self.rejectedCategory = rejectedCategory; self.autologin = autologin
        self.staticChallenge = staticChallenge; self.staticChallengeEcho = staticChallengeEcho
        self.privateKeyPasswordRequired = privateKeyPasswordRequired; self.warnings = warnings
    }
    public var isValid: Bool { error == nil }
}

/// `statistics` reply (request: `ProfileRequest`). §7.7: no keys, ever (invariant 10).
public struct TunnelStatistics: Codable, Sendable, Equatable {
    public var profileID: UUID
    public var sessionID: UUID?
    public var sessionStart: Date?
    public var rxBytes: UInt64
    public var txBytes: UInt64
    /// WG: newest peer handshake; OVPN: nil.
    public var lastHandshakeAt: Date?
    /// When the extension sampled the counters (it caches for 250 ms); the app's RateMeter uses it as the baseline.
    public var sampledAt: Date
    public init(profileID: UUID, sessionID: UUID?, sessionStart: Date?, rxBytes: UInt64, txBytes: UInt64,
                lastHandshakeAt: Date?, sampledAt: Date) {
        self.profileID = profileID; self.sessionID = sessionID; self.sessionStart = sessionStart
        self.rxBytes = rxBytes; self.txBytes = txBytes; self.lastHandshakeAt = lastHandshakeAt; self.sampledAt = sampledAt
    }
}

/// `sessionSummaries(after:)`: summaries newer than the given session (nil = all in the ring).
public struct SessionSummariesRequest: Codable, Sendable, Equatable {
    public var after: UUID?
    public init(after: UUID?) { self.after = after }
}

public struct SessionSummariesReply: Codable, Sendable, Equatable {
    public static let maxEntries = 100
    public var sessions: [SessionSummary]
    public init(sessions: [SessionSummary]) { self.sessions = sessions }
}

/// `measureLatency` (request: `ProfileRequest`): profile endpoints only, measured in the extension (root is exempt
/// from local network privacy, §2.5).
public struct LatencyResult: Codable, Sendable, Equatable {
    /// "host:port" as in the profile
    public var endpoint: String
    public var rttMilliseconds: Double?
    public var error: LPErrorCode?
    public init(endpoint: String, rttMilliseconds: Double?, error: LPErrorCode?) {
        self.endpoint = endpoint; self.rttMilliseconds = rttMilliseconds; self.error = error
    }
}

public struct MeasureLatencyReply: Codable, Sendable, Equatable {
    public static let maxEndpoints = 32
    public var results: [LatencyResult]
    public init(results: [LatencyResult]) { self.results = results }
}

/// `pushEndpoints` (PENDING-FOLD 50; fixes §20 risk 25): endpoint IPs the app resolved for one of the caller's
/// profiles, pushed into that profile's start while it is HELD before Connected on `.dnsResolutionFailed` or an
/// endpoint-unreachable reason (`.connectTimeout`, `.peerUnreachable`, `.endpointInterfaceUnusable`). Under
/// `includeAllNetworks` the provider resolves nothing (S2 E10), and an on-demand start carries no app hints, so
/// without this a start whose cached IPs went stale stays held until the user acts.
/// Same shape and caps as the start option `lp.endpoints` (≤ 8 hostnames of ≤ 253 bytes, ≤ 16 IPs each), but strict:
/// one bad entry rejects the whole request (`.malformedRequest`), nothing is silently dropped. Nothing secret.
public struct PushEndpointsRequest: Codable, Sendable, Equatable {
    public var profileID: UUID
    /// `[hostname: [IP literal]]`, v4 first as resolved (Go `orderIPsV4First`).
    public var endpoints: [String: [String]]
    public init(profileID: UUID, endpoints: [String: [String]]) { self.profileID = profileID; self.endpoints = endpoints }

    /// The held reasons fresh IPs can fix (no IPs at all, or IPs that don't answer). The extension accepts a push only
    /// for `.blockedAfterFailure` of one of these; the app pushes only when its snapshot shows one. One list for both.
    public static let recoverableCodes: Set<LPErrorCode> = [.dnsResolutionFailed, .connectTimeout, .peerUnreachable,
                                                            .endpointInterfaceUnusable]

    /// The app side of the rule: `snapshot` is `profileID`'s start, held before Connected on a recoverable reason,
    /// waiting (`.held`) or in one of its retries (`.starting`/`.connecting`, still on the old IPs; E2E-2: also
    /// `.establishing`, where a WireGuard retry spends nearly all its time, settings applied before any handshake; the
    /// extension refuses it for OpenVPN, whose `.establishing` means the server answered).
    public static func appliesTo(_ snapshot: TunnelSnapshot, profileID: UUID) -> Bool {
        guard snapshot.profileID == profileID, snapshot.holdBeforeConnected,
              [.held, .starting, .connecting, .establishing].contains(snapshot.phase),
              case .blockedAfterFailure(let code)? = snapshot.holdReason else { return false }
        return recoverableCodes.contains(code)
    }
}

/// What the extension did with a `pushEndpoints` request.
public struct PushEndpointsReply: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// The held start took the IPs and is retrying now (the whole start sequence, §7.2 held row).
        case retrying
        /// The held start already has exactly these IPs: nothing retried (a repeated push can't loop the start).
        case unchanged
        /// No start of the caller's profile is held before Connected on a qualifying reason: nothing changed.
        case notHeld
    }
    public var outcome: Outcome
    public init(outcome: Outcome) { self.outcome = outcome }
}

/// `armStart` (2.0.2, PLAN-2.0.2 §3): the owner's app announces its next manual start of `profileID` with `nonce`
/// (also passed as the start option `lp.startNonce`). The extension takes the owner from the connection's uid and
/// requires the profile in that uid's namespace. Not secret-bearing.
public struct ArmStartRequest: Codable, Sendable, Equatable {
    public var profileID: UUID
    public var nonce: UUID
    public init(profileID: UUID, nonce: UUID) { self.profileID = profileID; self.nonce = nonce }
}

/// How long an arm lives (round 1, Sonnet NIT: the one constant for the extension's `StartArms.ttl` and the app's
/// "armed recently" window).
public enum ArmLifetime { public static let seconds: TimeInterval = 15 }

/// When the arm lapses (the extension's clock; the start must reach the provider before then).
public struct ArmStartReply: Codable, Sendable, Equatable {
    public var expiresAt: Date
    public init(expiresAt: Date) { self.expiresAt = expiresAt }
}

/// `revokeUnattended` (2.0.2 round 1, Codex 4; round 2, Fable L3): the caller's profiles (its uid's namespace) whose
/// unattended-start consent STANDS: those with an on-demand plan, and those the app sees starting, running or awaiting
/// NE's restart. Every other unattended record of the caller is revoked. The complement keeps the request small (a
/// handful of IDs, however many profiles there are).
///
/// Round 3 (Codex r3 #8): a keep set larger than `maxProfiles` is sent as `pageCount` pages of one `batch`; the extension
/// applies the union only once every page of that batch has arrived (never one page's complement on its own, which would
/// revoke the other pages' entries). At most `maxPages` pages.
///
public struct RevokeUnattendedRequest: Codable, Sendable, Equatable {
    public static let maxProfiles = 500
    public static let maxPages = 20
    public var keepProfileIDs: [UUID]
    public var batch: UUID?
    public var page: Int
    public var pageCount: Int
    public init(keepProfileIDs: [UUID], batch: UUID? = nil, page: Int = 0, pageCount: Int = 1) {
        self.keepProfileIDs = keepProfileIDs
        self.batch = batch; self.page = page; self.pageCount = pageCount
    }
    private enum CodingKeys: String, CodingKey { case keepProfileIDs, batch, page, pageCount }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        keepProfileIDs = try c.decode([UUID].self, forKey: .keepProfileIDs)
        batch = try c.decodeIfPresent(UUID.self, forKey: .batch)
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 1
    }

    /// The pages of one keep set (sorted, so a retry sends the same pages).
    public static func pages(keeping keep: Set<UUID>, batch: UUID = UUID()) -> [RevokeUnattendedRequest]? {
        let sorted = keep.sorted { $0.uuidString < $1.uuidString }
        let count = max(1, (sorted.count + maxProfiles - 1) / maxProfiles)
        guard count <= maxPages else { return nil }
        return (0..<count).map { i in
            RevokeUnattendedRequest(keepProfileIDs: Array(sorted[min(sorted.count, i * maxProfiles)..<min(sorted.count, (i + 1) * maxProfiles)]),
                                    batch: count > 1 ? batch : nil, page: i, pageCount: count)
        }
    }

}

/// The rules for an app-resolved endpoint map on the wire (`pushEndpoints`).
public enum EndpointMapRules {
    public static let maxHosts = StartOptionKey.maxEndpointHosts
    public static let maxIPsPerHost = StartOptionKey.maxIPsPerHost
    public static let maxHostnameBytes = 253

    /// A DNS hostname as the app's resolver accepts it (letters, digits, `-`, `_`, `.`), not an IP literal.
    public static func isHostname(_ h: String) -> Bool {
        guard !h.isEmpty, h.utf8.count <= maxHostnameBytes, !isIPLiteral(h), !h.hasPrefix("."), !h.contains("..") else { return false }
        return h.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x2E || c == 0x5F
        }
    }

    /// A numeric IPv4 or IPv6 address (`inet_pton`; no zone, no brackets, no port).
    public static func isIPLiteral(_ s: String) -> Bool {
        // Darwin's inet_pton accepts a "%zone" suffix; a server address never has one.
        guard !s.isEmpty, s.utf8.count <= 45, !s.contains("%") else { return false }
        var a4 = in_addr(), a6 = in6_addr()
        return inet_pton(AF_INET, s, &a4) == 1 || inet_pton(AF_INET6, s, &a6) == 1
    }

    /// A resolver's (or a request's) map shaped to these rules: hostnames only (lowercased; the first in sorted order
    /// wins a case collision), IP literals only, no duplicates, ≤ `maxIPsPerHost` per host, ≤ `maxHosts` hosts, no host
    /// without IPs. The one filter both sides apply (the app before a push, the extension on receipt).
    public static func sanitized(_ m: [String: [String]]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for h in m.keys.sorted() where out.count < maxHosts && isHostname(h) && out[h.lowercased()] == nil {
            var ips: [String] = []
            for ip in m[h] ?? [] where ips.count < maxIPsPerHost && isIPLiteral(ip) && !ips.contains(ip) { ips.append(ip) }
            if !ips.isEmpty { out[h.lowercased()] = ips }
        }
        return out
    }

    /// Every rule at once: 1 … 8 hostnames, each with 1 … 16 IP literals and no duplicates.
    public static func isValid(_ m: [String: [String]]) -> Bool {
        guard !m.isEmpty, m.count <= maxHosts else { return false }
        return m.allSatisfy { h, ips in
            isHostname(h) && !ips.isEmpty && ips.count <= maxIPsPerHost && ips.allSatisfy(isIPLiteral) && Set(ips).count == ips.count
        }
    }
}

// MARK: - post-decode limits (review S5)

/// A wire type with range/count/size rules beyond its byte cap. `LPWire.decode` rejects a decoded value that fails
/// them (`.malformedRequest`), so handlers never see out-of-range input.
public protocol LPWireValidating {
    var isWireValid: Bool { get }
}

/// Canonical profile text cap (§8.1, openvpn3 accounting).
public let LPMaxPayloadBytes = 256 * LPWire.KiB

extension ClientHello: LPWireValidating {
    public var isWireValid: Bool { appVersion.utf8.count <= 64 && appBuild.utf8.count <= 64 }
}
extension ServerHello: LPWireValidating {
    public var isWireValid: Bool { extVersion.utf8.count <= 64 && extBuild.utf8.count <= 64 }
}
extension ProvisionRequest: LPWireValidating {
    public var isWireValid: Bool { payload.count <= LPMaxPayloadBytes && (credentials?.isWithinLimits ?? true) }
}
extension CredentialRecord: LPWireValidating {
    public var isWireValid: Bool { v == 1 && isWithinLimits }
}
extension UpdateCredentialsRequest: LPWireValidating {
    public var isWireValid: Bool { credentials.isWireValid }
}
extension ValidateProfileRequest: LPWireValidating {
    public var isWireValid: Bool { payload.count <= LPMaxPayloadBytes }
}
extension PrepareStartAuth: LPWireValidating {
    public var isWireValid: Bool { [.userPass, .staticChallenge, .keyPassphrase].contains(kind) }
}
extension AuthAnswer: LPWireValidating {
    public var isWireValid: Bool {
        CredentialRecord(username: username, password: password).isWithinLimits && (response?.count ?? 0) <= CredentialRecord.maxSecret
    }
}
extension AuthPrompt: LPWireValidating {
    public var isWireValid: Bool {
        (challengeText?.utf8.count ?? 0) <= 1024 && (lockedUsername?.utf8.count ?? 0) <= CredentialRecord.maxUsername
            && (savedUsername?.utf8.count ?? 0) <= CredentialRecord.maxUsername
    }
}
extension ListProvisionedReply: LPWireValidating {
    public var isWireValid: Bool { entries.count <= Self.maxEntries && entries.allSatisfy { $0.digest.utf8.count <= 64 } }
}
extension SessionSummariesReply: LPWireValidating {
    public var isWireValid: Bool { sessions.count <= Self.maxEntries }
}
extension MeasureLatencyReply: LPWireValidating {
    public var isWireValid: Bool { results.count <= Self.maxEndpoints }
}
extension ValidateProfileReply: LPWireValidating {
    /// Round 1 (Fable N2): the strings the app shows or stores have their own caps (beside the 64 KiB reply cap).
    public static let maxStaticChallenge = 1024
    public static let maxCategory = 256
    public static let maxDetail = 512
    public var isWireValid: Bool {
        warnings.count <= 50 && warnings.allSatisfy { $0.utf8.count <= 2048 }
            && (staticChallenge?.utf8.count ?? 0) <= Self.maxStaticChallenge
            && (rejectedCategory?.utf8.count ?? 0) <= Self.maxCategory
            && (error?.detail?.utf8.count ?? 0) <= Self.maxDetail
    }
}
extension TunnelSnapshot: LPWireValidating {
    public var isWireValid: Bool { localAddresses.count <= 64 }
}
extension PushEndpointsRequest: LPWireValidating {
    public var isWireValid: Bool { EndpointMapRules.isValid(endpoints) }
}
extension ArmStartRequest: LPWireValidating {
    /// Two UUIDs: nothing beyond the byte cap to check; listed so every request type is `LPWireValidating`.
    public var isWireValid: Bool { true }
}
extension RevokeUnattendedRequest: LPWireValidating {
    public var isWireValid: Bool {
        keepProfileIDs.count <= Self.maxProfiles
            && (1...Self.maxPages).contains(pageCount) && (0..<pageCount).contains(page) && (pageCount == 1 || batch != nil)
    }
}
extension TunnelEvent: LPWireValidating {
    public var isWireValid: Bool { (snapshot?.isWireValid ?? true) && (prompt?.isWireValid ?? true) }
}
