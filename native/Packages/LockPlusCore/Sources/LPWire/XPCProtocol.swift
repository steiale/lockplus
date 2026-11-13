import Foundation

/// Bumps only on an incompatible change; additive fields are optional (DESIGN §5.2 "Versioning").
public let LPWireVersion: UInt16 = 1

/// Encoded `LPError?` (nil = success).
public typealias LPReply1 = @Sendable (Data?) -> Void
/// (encoded result, encoded `LPError?`).
public typealias LPReply2 = @Sendable (Data?, Data?) -> Void

// Rules (DESIGN §5.2; ref/xpc-servicemanagement C8, ref/swift-concurrency SC2/SC3):
// - Data-only parameters: no collections, NSError or custom classes, so no setClasses calls exist.
// - Every reply closure is @escaping @Sendable. No `async` members (a failed connection would hang the call).
// - Exported objects on both sides are nonisolated NSObject subclasses, never @MainActor
//   (XPC delivers on a non-main queue; a main-actor @objc witness traps under SE-0423).

/// Exported by the extension; called by the app over `NSXPCConnection(machServiceName:options: .privileged)`.
@objc public protocol LPTunnelServiceXPC: NSObjectProtocol {
    /// ClientHello → ServerHello. Always the first call on a connection; carries no secret.
    func hello(_ req: Data, reply: @escaping LPReply2)
    /// ProvisionRequest; only after a validated hello.
    func provisionProfile(_ req: Data, reply: @escaping LPReply1)
    /// Only after a validated hello.
    func updateCredentials(_ req: Data, reply: @escaping LPReply1)
    func removeProfile(_ req: Data, reply: @escaping LPReply1)
    func listProvisioned(_ req: Data, reply: @escaping LPReply2)
    func wipeAllSecrets(_ req: Data, reply: @escaping LPReply1)
    /// Engine-side re-check ([7]).
    func validateProfile(_ req: Data, reply: @escaping LPReply2)
    func tunnelSnapshot(_ req: Data, reply: @escaping LPReply2)
    func statistics(_ req: Data, reply: @escaping LPReply2)
    /// The awaitingAuth prompt (pending start or reasserting), or an unanswered `prepareStartAuth` prompt (§7.2).
    func pendingAuthPrompt(_ req: Data, reply: @escaping LPReply2)
    /// PrepareStartAuth → AuthPrompt(nextStart: true); no secret. The answer is used by the next manual start (§8.4).
    func prepareStartAuth(_ req: Data, reply: @escaping LPReply2)
    /// Only after a validated hello.
    func answerAuth(_ req: Data, reply: @escaping LPReply1)
    func cancelAuth(_ req: Data, reply: @escaping LPReply1)
    func sessionSummaries(_ req: Data, reply: @escaping LPReply2)
    /// Profile endpoints only.
    func measureLatency(_ req: Data, reply: @escaping LPReply2)
    /// PushEndpointsRequest → PushEndpointsReply (PENDING-FOLD 50, §20 risk 25): fresh endpoint IPs the app resolved,
    /// for the caller's own start that is held before Connected on a resolution or reachability failure. No secret.
    func pushEndpoints(_ req: Data, reply: @escaping LPReply2)
    /// ArmStartRequest → ArmStartReply (2.0.2, PLAN-2.0.2 §3): the caller's next manual start of its own profile carries
    /// this nonce. Ordinary hello gate; no secret.
    func armStart(_ req: Data, reply: @escaping LPReply2)
    /// RevokeUnattendedRequest → error only (2.0.2 round 1, Codex 4; round 2, L1/L3): the caller's profiles whose
    /// unattended-start consent stands; every other recorded unattended admission of the caller whose session NE never
    /// restarts (no kill switch) goes, except the running session's and one whose start waits in the guard. A kill-switch
    /// session's record is never revoked (NE's own restart stays honoured: Fable H1b, Codex r2 #2). Round 3: a keep set
    /// above one request goes as the pages of one batch (applied once complete, Codex r3 #8), and the request names the
    /// profiles the user stopped in LockPlus, whose whole record ends unless their session runs here (Fable L1). No secret.
    func revokeUnattended(_ req: Data, reply: @escaping LPReply1)
}

/// Exported by the app on the same connection. One event in flight per connection: the extension sends the next only
/// after `done`; newer events coalesce, so a hung app can't make the extension queue without bound.
@objc public protocol LPAppCallbackXPC: NSObjectProtocol {
    func tunnelEvent(_ event: Data, done: @escaping @Sendable () -> Void)
}

public extension NSXPCInterface {
    /// The two interfaces, built in one place so both ends agree.
    static var lpTunnelService: NSXPCInterface { NSXPCInterface(with: LPTunnelServiceXPC.self) }
    static var lpAppCallback: NSXPCInterface { NSXPCInterface(with: LPAppCallbackXPC.self) }
}

public extension Bundle {
    /// `NetworkExtension.NEMachServiceName` of this bundle's Info.plist (§2.5). The app reads it from the EMBEDDED
    /// extension bundle; there is no duplicated constant.
    var lpMachServiceName: String? {
        (object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any])?["NEMachServiceName"] as? String
    }
}
