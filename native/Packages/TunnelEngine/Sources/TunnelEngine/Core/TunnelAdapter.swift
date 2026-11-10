import Foundation
import LPModel
import LPWire
import Synchronization

public enum ReconnectReason: String, Sendable, Equatable, Codable { case pathChanged, noNetwork, wake, deadPeer, engine, auth }

public enum Liveness: Sendable, Equatable { case healthy, stale(Duration), dead }

/// Data-plane mode (DESIGN §7.3): the runtime switch; the leak harness runs once per mode.
public enum DataPlane: String, Sendable, Codable { case utunFD, packetFlow }

/// Stored credentials loaded from the extension store (§6.5: `SecretBytes` from keychain read to engine call).
public struct CredentialSecrets: Sendable {
    public var username: SecretBytes?
    public var password: SecretBytes?
    public var keyPassphrase: SecretBytes?
    /// openvpn3 `Config.proxyUsername/proxyPassword` (§8.2 Proxy, inline `<http-proxy-user-pass>` extracted at import).
    public var proxyUsername: SecretBytes?
    public var proxyPassword: SecretBytes?
    public init(username: SecretBytes? = nil, password: SecretBytes? = nil, keyPassphrase: SecretBytes? = nil,
                proxyUsername: SecretBytes? = nil, proxyPassword: SecretBytes? = nil) {
        self.username = username; self.password = password; self.keyPassphrase = keyPassphrase
        self.proxyUsername = proxyUsername; self.proxyPassword = proxyPassword
    }
}

/// A user's answer (from `answerAuth`), engine side. `password` is the base password (or base+OTP, concatenated by the app).
public struct AuthAnswerSecrets: Sendable {
    public var username: SecretBytes?
    public var password: SecretBytes?
    public var response: SecretBytes?
    public var save: Bool
    public init(username: SecretBytes? = nil, password: SecretBytes? = nil, response: SecretBytes? = nil, save: Bool = false) {
        self.username = username; self.password = password; self.response = response; self.save = save
    }
}

/// What openvpn3 hands to `provide_creds` (ref/openvpn3 §3.1), assembled by the adapter at provide_creds time.
public struct EngineCredentials: Sendable {
    public var username: SecretBytes?
    public var password: SecretBytes?
    public var response: SecretBytes?
    public var dynamicChallengeCookie: SecretBytes?
    /// True when username/password came from a consumed stash answer (not the store): the CRV1 retry keeps them (§6.5).
    public var fromAnswer: Bool
    public init(username: SecretBytes? = nil, password: SecretBytes? = nil, response: SecretBytes? = nil,
                dynamicChallengeCookie: SecretBytes? = nil, fromAnswer: Bool = false) {
        self.username = username; self.password = password; self.response = response
        self.dynamicChallengeCookie = dynamicChallengeCookie; self.fromAnswer = fromAnswer
    }
}

/// A prompt the engine needs, before the controller mints an `AuthPrompt` (it holds secrets the prompt must not).
public struct AuthChallenge: Sendable {
    public var kind: AuthKind
    public var reason: AuthReason
    public var challengeText: String?       // server-controlled, ≤ 1 KiB, plain text only
    public var echo: Bool
    public var lockedUsername: String?      // CRV1: the cookie's username
    public var cookie: SecretBytes?         // CRV1 cookie (server state ID + username)
    /// Username/base password that came from a consumed answer; the next client of the SAME start gets them back
    /// (a CRV1 answer needs the base credentials, §8.4), so the user is not asked twice.
    public var carriedUsername: SecretBytes?
    public var carriedPassword: SecretBytes?
    /// True when the engine rejected stored credentials (AUTH_FAILED with store creds): clear the stored password.
    public var rejectedStoredCredentials: Bool
    public init(kind: AuthKind, reason: AuthReason, challengeText: String? = nil, echo: Bool = false, lockedUsername: String? = nil,
                cookie: SecretBytes? = nil, carriedUsername: SecretBytes? = nil, carriedPassword: SecretBytes? = nil,
                rejectedStoredCredentials: Bool = false) {
        self.kind = kind; self.reason = reason; self.challengeText = challengeText.map { String($0.prefix(1024)) }
        self.echo = echo; self.lockedUsername = lockedUsername; self.cookie = cookie
        self.carriedUsername = carriedUsername; self.carriedPassword = carriedPassword
        self.rejectedStoredCredentials = rejectedStoredCredentials
    }
}

/// How `adapter.start` fails. `.auth` is a prompt (CRV1, AUTH_FAILED, NEED_CREDS, SESSION_EXPIRED) before Connected:
/// draft 9 keeps the start pending in `awaitingAuth` and answers into it with a new client (§7.2, §8.4). Everything
/// else is `.failed`.
public enum AdapterStartError: Error, Sendable {
    case failed(LPTunnelError)
    case auth(AuthChallenge)
}

/// An answer bound to ONE engine attempt of the pending start (§7.2, §8.4): an in-start answer (with the challenge's
/// cookie and carried base credentials) or a `prepareStartAuth` answer. Consumed exactly once, at `provide_creds`.
public final class StashBinding: Sendable {
    public let promptID: UUID
    private let state: Mutex<(answer: AuthAnswerSecrets?, carriedUsername: SecretBytes?, carriedPassword: SecretBytes?,
                               cookie: SecretBytes?, consumed: Bool)>
    public init(promptID: UUID, answer: AuthAnswerSecrets?, carriedUsername: SecretBytes?, carriedPassword: SecretBytes?, cookie: SecretBytes?) {
        self.promptID = promptID
        state = Mutex((answer, carriedUsername, carriedPassword, cookie, false))
    }
    /// Returns the bound secrets once; later calls return nil. The binding drops its references (zeroed on deinit).
    public func consume() -> (answer: AuthAnswerSecrets?, carriedUsername: SecretBytes?, carriedPassword: SecretBytes?, cookie: SecretBytes?)? {
        state.withLock { s in
            guard !s.consumed else { return nil }
            defer { s = (nil, nil, nil, nil, true) }
            return (s.answer, s.carriedUsername, s.carriedPassword, s.cookie)
        }
    }
    public var isConsumed: Bool { state.withLock { $0.consumed } }
}

public struct AdapterStart: Sendable {
    public let profileID: UUID
    public let payload: SecretBytes
    public let credentials: CredentialSecrets?
    public let stash: StashBinding?
    public let policy: NetworkPolicy
    public let connectTimeout: Duration
    /// hostname → IPs known before the start (the app's resolution, then the cache; §9.3).
    public let endpoints: [String: [String]]
    /// Draft 9 (S2 E10): false under `includeAllNetworks`: the adapter must not resolve anything (getaddrinfo in the
    /// provider blocks for 30 s and fails). True: it may resolve a hostname missing from `endpoints`, within 2 s.
    public let providerDNS: Bool
    public let dataPlane: DataPlane
    public let pump: PacketFlowPump?
    /// NEED_CREDS maps to this prompt kind (`providerConfiguration.auth`), default `.userPass`.
    public let interactiveKind: AuthKind
    public init(profileID: UUID, payload: SecretBytes, credentials: CredentialSecrets?, stash: StashBinding?, policy: NetworkPolicy,
                connectTimeout: Duration, endpoints: [String: [String]] = [:], providerDNS: Bool = false, dataPlane: DataPlane,
                pump: PacketFlowPump?, interactiveKind: AuthKind = .userPass) {
        self.profileID = profileID; self.payload = payload; self.credentials = credentials; self.stash = stash
        self.policy = policy; self.connectTimeout = connectTimeout; self.endpoints = endpoints; self.providerDNS = providerDNS
        self.dataPlane = dataPlane; self.pump = pump; self.interactiveKind = interactiveKind
    }
}

public enum AdapterEvent: Sendable {
    /// The adapter asks the controller to apply; it waits on the ticket (OVPN on its connect thread, WG async).
    case networkSettings(NetworkPlan, EstablishTicket, epoch: UInt64)
    case reconnecting(ReconnectReason, epoch: UInt64)
    case reconnected(epoch: UInt64)
    case authRequired(AuthChallenge, epoch: UInt64)
    case fatal(LPTunnelError, epoch: UInt64)
    // No `log` case: adapters append to LogRing synchronously (§7.1).
}

public typealias AdapterEventSink = AsyncStream<AdapterEvent>.Continuation

public struct AdapterStats: Sendable, Equatable {
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var lastHandshake: Date?
    public var endpoint: String?
    public var localAddresses: [String]
    public var cipher: String?
    /// hostname → IPs this session resolved itself (kill switch off only; persisted as the §9.3 fallback).
    public var resolvedEndpoints: [String: [String]]
    public init(rxBytes: UInt64 = 0, txBytes: UInt64 = 0, lastHandshake: Date? = nil, endpoint: String? = nil,
                localAddresses: [String] = [], cipher: String? = nil, resolvedEndpoints: [String: [String]] = [:]) {
        self.rxBytes = rxBytes; self.txBytes = txBytes; self.lastHandshake = lastHandshake; self.endpoint = endpoint
        self.localAddresses = localAddresses; self.cipher = cipher; self.resolvedEndpoints = resolvedEndpoints
    }
}

/// DESIGN §7.1. `start` returns only when the data plane is up (L-LC-2).
public protocol TunnelAdapter: AnyObject, Sendable {
    var kind: VPNProtocolKind { get }
    func start(_ req: AdapterStart, events: AdapterEventSink, epoch: UInt64) async throws(AdapterStartError)
    /// Safe in every phase; the controller caps it at 5 s.
    func stop() async
    func reconnect(reason: ReconnectReason) async
    func sleep() async
    func wake() async
    /// A matching answer for an `AUTH_PENDING` wait or an after-Connected prompt: a new engine client. (An answer to a
    /// prompt that ENDED `start` goes into a new `start` of the same pending NE start instead.)
    func provideAuth(_ answer: AuthAnswerSecrets) async throws(LPTunnelError)
    func statistics() async -> AdapterStats
    func liveness() async -> Liveness
}

/// Creates one adapter per start (the Tunnel target binds WireGuardKitGo / OpenVPN3Shim).
public protocol TunnelAdapterFactory: Sendable {
    func makeAdapter(kind: VPNProtocolKind) -> any TunnelAdapter
}
