import Foundation
import LPModel

// Wire messages (DESIGN §5.2). Payloads are Codable structs encoded as binary property lists by `LPWire`.
// Public types are never inferred Sendable (SE-0302), so each one says so.

public struct ClientHello: Codable, Sendable, Equatable {
    public var wire: UInt16
    public var appVersion: String
    public var appBuild: String
    public init(wire: UInt16 = LPWireVersion, appVersion: String, appBuild: String) {
        self.wire = wire; self.appVersion = appVersion; self.appBuild = appBuild
    }
}

public struct ServerHello: Codable, Sendable, Equatable {
    public var wire: UInt16
    public var extVersion: String
    public var extBuild: String
    /// .openVPN, .wireGuard, .keyPassphrase (DoH/DoT: §21)
    public var capabilities: Set<Capability>
    public init(wire: UInt16 = LPWireVersion, extVersion: String, extBuild: String, capabilities: Set<Capability>) {
        self.wire = wire; self.extVersion = extVersion; self.extBuild = extBuild; self.capabilities = capabilities
    }
}

/// `.startAuthorisation` (2.0.2, PLAN-2.0.2 §3): the extension honours a manual start only with an `armStart` of the
/// profile's owner (`StartOptionKey.startNonce`).
public enum Capability: String, Codable, Sendable, CaseIterable { case openVPN, wireGuard, keyPassphrase, startAuthorisation }

/// Empty request body for calls that take no parameters (`listProvisioned`, `wipeAllSecrets` uses the peer's uid).
public struct EmptyRequest: Codable, Sendable, Equatable { public init() {} }

/// Request body for profile-scoped calls that need only the profile (snapshot, statistics, remove, …).
public struct ProfileRequest: Codable, Sendable, Equatable {
    public var profileID: UUID
    public init(profileID: UUID) { self.profileID = profileID }
}

public struct ProvisionRequest: Codable, Sendable {
    public var profileID: UUID
    public var kind: VPNProtocolKind
    public var revision: UInt64
    /// Canonical text, ≤ 256 KiB by openvpn3 accounting (§8.1).
    public var payload: Data
    /// ≤ 4 KiB encoded.
    public var credentials: CredentialRecord?
    public init(profileID: UUID, kind: VPNProtocolKind, revision: UInt64, payload: Data, credentials: CredentialRecord?) {
        self.profileID = profileID; self.kind = kind; self.revision = revision
        self.payload = payload; self.credentials = credentials
    }
}

/// username ≤ 512 B, password ≤ 1024 B, passphrase ≤ 1024 B; no CR/LF/NUL in username/password.
/// proxyUsername/proxyPassword: an inline `<http-proxy-user-pass>` extracted at import (§8.1 [5], §8.2 Proxy), handed to
/// openvpn3's `Config.proxyUsername/proxyPassword`; same caps as username/password. Additive optional fields, so the
/// wire version is unchanged. The extension copies every field into `SecretBytes` on receipt.
public struct CredentialRecord: Codable, Sendable {
    public static let maxUsername = 512
    public static let maxSecret = 1024
    public var v: UInt8 = 1
    public var username: Data?
    public var password: Data?
    public var keyPassphrase: Data?
    public var proxyUsername: Data?
    public var proxyPassword: Data?
    public init(username: Data? = nil, password: Data? = nil, keyPassphrase: Data? = nil,
                proxyUsername: Data? = nil, proxyPassword: Data? = nil) {
        self.username = username; self.password = password; self.keyPassphrase = keyPassphrase
        self.proxyUsername = proxyUsername; self.proxyPassword = proxyPassword
    }

    /// The §5.2 field caps. Checked by both ends; the extension never trusts the app's check (B1).
    public var isWithinLimits: Bool {
        func clean(_ d: Data?) -> Bool { !(d?.contains { $0 == 0x0A || $0 == 0x0D || $0 == 0x00 } ?? false) }
        return (username?.count ?? 0) <= Self.maxUsername && (password?.count ?? 0) <= Self.maxSecret
            && (keyPassphrase?.count ?? 0) <= Self.maxSecret
            && (proxyUsername?.count ?? 0) <= Self.maxUsername && (proxyPassword?.count ?? 0) <= Self.maxSecret
            && clean(username) && clean(password) && clean(proxyUsername) && clean(proxyPassword)
    }
}

public enum AuthKind: String, Codable, Sendable { case userPass, staticChallenge, dynamicChallenge, keyPassphrase, pendingApproval }
public enum AuthReason: String, Codable, Sendable { case initial, rejected, reconnect, sessionExpired }

public struct AuthPrompt: Codable, Sendable, Equatable {
    public var promptID: UUID
    public var profileID: UUID
    public var kind: AuthKind
    /// ≤ 1 KiB, server-controlled, rendered as plain text only.
    public var challengeText: String?
    public var echo: Bool
    public var lockedUsername: String?
    public var reason: AuthReason
    public var savedUsername: String?
    /// true = a `prepareStartAuth` prompt (a known-interactive profile, before any start): after `answerAuth` the app
    /// starts the tunnel and that start uses the answer. false = the answer goes into the running session: the pending
    /// start (draft 9: every first-connect prompt, §8.4) or a reasserting session.
    public var nextStart: Bool
    /// The prompt deadline: 10 min (CRV1: 5 min, the server's state lifetime); `AUTH_PENDING` and after-Connected
    /// prompts: the 10 min auth deadline.
    public var expiresAt: Date
    public init(promptID: UUID, profileID: UUID, kind: AuthKind, challengeText: String?, echo: Bool,
                lockedUsername: String?, reason: AuthReason, savedUsername: String?, nextStart: Bool, expiresAt: Date) {
        self.promptID = promptID; self.profileID = profileID; self.kind = kind; self.challengeText = challengeText
        self.echo = echo; self.lockedUsername = lockedUsername; self.reason = reason; self.savedUsername = savedUsername
        self.nextStart = nextStart; self.expiresAt = expiresAt
    }
}

/// Known-interactive profiles prompt BEFORE the first start (draft 6).
public struct PrepareStartAuth: Codable, Sendable {
    public var profileID: UUID
    /// .userPass (unsaved), .staticChallenge, .keyPassphrase (unsaved)
    public var kind: AuthKind
    public init(profileID: UUID, kind: AuthKind) { self.profileID = profileID; self.kind = kind }
}

public struct AuthAnswer: Codable, Sendable {
    public var promptID: UUID
    public var username: Data?
    public var password: Data?
    public var response: Data?
    public var save: Bool
    public init(promptID: UUID, username: Data?, password: Data?, response: Data?, save: Bool) {
        self.promptID = promptID; self.username = username; self.password = password
        self.response = response; self.save = save
    }
}

/// `AuthAnswer` under a name the app can reach: the app module has its own UI `AuthAnswer`, and `LPWire.AuthAnswer`
/// resolves to the `LPWire` enum, not this module.
public typealias WireAuthAnswer = AuthAnswer

/// Start option keys (`startVPNTunnel(options:)`, plist types only, nothing secret). The app ALWAYS passes a non-nil
/// dictionary containing `lp.manual = 1`, so a manual start is `options != nil`. On-demand starts and
/// `scutil --nc start` yield `options == nil` and are treated as on-demand (start latch applies; §7.2, §15.3).
/// Draft 9 (S2 E1): NE replays the ORIGINAL options when it restarts a crashed provider by itself, so options never
/// carry an OTP, a CRV1 answer, a promptID or any other one-shot value (`lp.promptID` is gone).
public enum StartOptionKey {
    public static let manual = "lp.manual"
    /// Draft 9 (S2 E10): the endpoint hostnames the app resolved before the start, `[host: [IP literal]]`
    /// (≤ 8 hosts, ≤ 16 IPs each). The provider never resolves under `includeAllNetworks`.
    public static let endpoints = "lp.endpoints"
    /// 2.0.2 (PLAN-2.0.2 §3): a manual start's nonce (a UUID string), the one the owner's app armed just before the start
    /// (`armStart`). Read only when `manual` is set; NE replays it with the original options, which is how its own
    /// restart of an authorised session is recognised. Not a secret: it only binds the start to an arm over XPC.
    public static let startNonce = "lp.startNonce"
    public static let maxEndpointHosts = 8
    public static let maxIPsPerHost = 16
}

/// What the extension knows that NEVPNStatus doesn't. Detail only: the UI's state starts from NEVPNStatus and is
/// derived by one table (UI-CONCEPT §6.6, §11.2). F-4.
public struct TunnelSnapshot: Codable, Sendable, Equatable {
    public var profileID: UUID?
    public var phase: TunnelPhase
    /// Reconnect attempt in the current reasserting episode; 0 otherwise.
    public var attempt: UInt32
    /// Wall-clock estimate for the UI countdown; nil when not waiting.
    public var nextRetryAt: Date?
    public var holdReason: HoldReason?
    /// Draft 9 (S2 E14): the start completion is withheld; the session is held (or retrying) before Connected.
    public var holdBeforeConnected: Bool
    public var startLatch: StartLatch?
    public var lastError: LPError?
    public var lastErrorAt: Date?
    public var endpoint: String?
    public var localAddresses: [String]
    public var cipher: String?
    /// Controller epoch; lets the app drop stale snapshots. 0 in a snapshot of a profile that isn't the running session.
    public var epoch: UInt64

    public init(profileID: UUID? = nil, phase: TunnelPhase = .idle, attempt: UInt32 = 0, nextRetryAt: Date? = nil,
                holdReason: HoldReason? = nil, holdBeforeConnected: Bool = false, startLatch: StartLatch? = nil,
                lastError: LPError? = nil, lastErrorAt: Date? = nil, endpoint: String? = nil,
                localAddresses: [String] = [], cipher: String? = nil, epoch: UInt64 = 0) {
        self.profileID = profileID; self.phase = phase; self.attempt = attempt; self.nextRetryAt = nextRetryAt
        self.holdReason = holdReason; self.holdBeforeConnected = holdBeforeConnected; self.startLatch = startLatch
        self.lastError = lastError; self.lastErrorAt = lastErrorAt; self.endpoint = endpoint
        self.localAddresses = localAddresses; self.cipher = cipher; self.epoch = epoch
    }
}

public enum TunnelPhase: String, Codable, Sendable {
    case idle, starting, connecting, awaitingAuth, establishing, connected, reasserting, sleeping, held, stopping
}

/// Draft 6 (Conflicts ag): a before-Connected failure fails the start and may arm this latch (§7.2).
public struct StartLatch: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case hard, backoff }
    public var code: LPErrorCode
    public var kind: Kind
    public var notBefore: Date?
    public var revision: UInt64
    public init(code: LPErrorCode, kind: Kind, notBefore: Date?, revision: UInt64) {
        self.code = code; self.kind = kind; self.notBefore = notBefore; self.revision = revision
    }
}

public enum HoldReason: Codable, Sendable, Equatable {
    /// §7.2 holdBlocked after a fatal engine error (kill switch on)
    case blockedAfterFailure(LPErrorCode)
    /// §7.2 C16 rule: auth/profile errors under on-demand
    case nonRetryable(LPErrorCode)
}

/// One `tunnelEvent` payload (§5.2 "Event delivery"). Profile-scoped kinds reach only connections whose uid equals the
/// profile's ownerUID; every other connection gets `.anyTunnelStateChanged` with no profile, endpoint or address.
public struct TunnelEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Content-free: "a LockPlus tunnel changed state". The only kind non-owners ever see.
        case anyTunnelStateChanged
        case snapshotChanged, authRequired, promptResolved, sessionEnded
    }
    public var kind: Kind
    public var profileID: UUID?
    public var snapshot: TunnelSnapshot?
    public var prompt: AuthPrompt?
    public var promptID: UUID?

    public init(kind: Kind, profileID: UUID? = nil, snapshot: TunnelSnapshot? = nil, prompt: AuthPrompt? = nil,
                promptID: UUID? = nil) {
        self.kind = kind; self.profileID = profileID; self.snapshot = snapshot; self.prompt = prompt; self.promptID = promptID
    }

    public static let anyTunnelStateChanged = TunnelEvent(kind: .anyTunnelStateChanged)

    /// The view of this event a connection owned by another uid may see.
    public var redactedForNonOwner: TunnelEvent { .anyTunnelStateChanged }
}
