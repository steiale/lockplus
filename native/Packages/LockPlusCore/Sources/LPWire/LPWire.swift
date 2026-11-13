import Foundation
import LPModel

/// Encode/decode for every XPC payload (DESIGN §5.2). Size checks happen BEFORE decoding; oversized messages are
/// rejected with `.payloadTooLarge` and never decoded. These are our limits: NSXPC has already materialised the Data,
/// so the caps protect the plist decoder and the engine, not the XPC allocation.
public enum LPWire {
    public static let KiB = 1024

    public static func encode<T: Encodable>(_ value: T) throws(LPError) -> Data {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        do { return try e.encode(value) } catch { throw LPError(.malformedRequest, detail: "encode \(T.self)") }
    }

    /// Size cap BEFORE decoding; after decoding, `LPWireValidating` types must pass their own range/count/size
    /// checks (review S5), so a decoded value is always within the §5.2 limits.
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data, max: Int) throws(LPError) -> T {
        guard data.count <= max else { throw LPError(.payloadTooLarge, detail: "\(T.self) \(data.count) > \(max)") }
        let v: T
        do { v = try PropertyListDecoder().decode(type, from: data) } catch {
            // Never echo the payload: it may hold secrets (invariant 1).
            throw LPError(.malformedRequest, detail: "decode \(T.self)")
        }
        if let c = v as? any LPWireValidating, !c.isWireValid { throw LPError(.malformedRequest, detail: "limits \(T.self)") }
        return v
    }

    /// The error half of a reply (`LPReply1`, second `Data?` of `LPReply2`). Never fails: a broken encoder still
    /// yields a well-formed error so a handler can always reply exactly once.
    public static func encodeError(_ error: LPError) -> Data {
        (try? encode(error)) ?? Data()
    }

    /// Decodes the error half of a reply; nil means success. An undecodable error blob is itself an error.
    public static func decodeError(_ data: Data?) -> LPError? {
        guard let data else { return nil }
        return (try? decode(LPError.self, data, max: 4 * KiB)) ?? LPError(.malformedRequest, detail: "reply error")
    }

    /// Decodes an `LPReply2` pair into the result, applying the method's reply cap.
    public static func decodeReply<T: Decodable>(_ type: T.Type, result: Data?, error: Data?, max: Int) throws(LPError) -> T {
        if let e = decodeError(error) { throw e }
        guard let result else { throw LPError(.malformedRequest, detail: "empty reply") }
        return try decode(type, result, max: max)
    }
}

/// Every XPC method, with its request cap, reply cap and client timeout (DESIGN §5.2 limits, §5.4 timeouts).
public enum LPMethod: String, Sendable, CaseIterable {
    case hello, provisionProfile, updateCredentials, removeProfile, listProvisioned, wipeAllSecrets, validateProfile,
         tunnelSnapshot, statistics, pendingAuthPrompt, prepareStartAuth, answerAuth, cancelAuth,
         sessionSummaries, measureLatency, pushEndpoints,
         armStart,           // 2.0.2 (PLAN-2.0.2 §3): owner-authorised starts
         revokeUnattended    // 2.0.2 round 1 (Codex 4): the owner withdrew unattended-start consent
    // recentLogs/setLogLevel were removed in v2.0 (review M1): not uid-scoped. Logs go to the owner's diagnostics bundle.

    /// Request size cap, checked before decoding.
    public var requestLimit: Int {
        switch self {
        case .hello: 4 * LPWire.KiB
        case .provisionProfile, .validateProfile: 300 * LPWire.KiB
        case .answerAuth: 8 * LPWire.KiB
        case .revokeUnattended: 32 * LPWire.KiB           // round 2 (L3), round 3: ≤ 500 UUIDs and the page fields, or ≤ 16 user stops (test-asserted)
        default: 16 * LPWire.KiB
        }
    }

    /// Reply size cap, checked by the client before decoding.
    public var replyLimit: Int {
        switch self {
        case .hello: 4 * LPWire.KiB
        case .sessionSummaries: 64 * LPWire.KiB           // ≤ 100 entries
        case .listProvisioned: 160 * LPWire.KiB           // ≤ 500 entries (~170 B each encoded; test-asserted headroom)
        default: 16 * LPWire.KiB
        }
    }

    /// Client-side timeout (§5.4). The extension's internal deadline is 1 s below it.
    public var timeout: Duration {
        switch self {
        case .hello: .seconds(3)
        case .tunnelSnapshot, .statistics, .pendingAuthPrompt, .prepareStartAuth, .cancelAuth, .pushEndpoints, .armStart,
             .revokeUnattended: .seconds(2)
        case .provisionProfile, .updateCredentials, .removeProfile, .wipeAllSecrets, .listProvisioned: .seconds(10)
        case .validateProfile, .answerAuth: .seconds(5)
        case .sessionSummaries: .seconds(3)
        case .measureLatency: .seconds(6)
        }
    }

    /// The extension's handler deadline: 1 s below the client's timeout, so the extension always replies first.
    public var serverDeadline: Duration { timeout - .seconds(1) }

    /// Calls that carry secrets. They are sent only after hello's reply passed EXT_REQ on the same connection (§5.3).
    public var carriesSecrets: Bool {
        switch self {
        case .provisionProfile, .updateCredentials, .answerAuth: true
        default: false
        }
    }

    /// True for the `LPReply1` shape (error only).
    public var repliesErrorOnly: Bool {
        switch self {
        case .provisionProfile, .updateCredentials, .removeProfile, .wipeAllSecrets, .answerAuth, .cancelAuth, .revokeUnattended: true
        default: false
        }
    }

    /// Sends this method on `proxy`. `reply` receives (result, error) for both reply shapes.
    public func invoke(_ proxy: any LPTunnelServiceXPC, _ req: Data, _ reply: @escaping LPReply2) {
        let one: LPReply1 = { e in reply(nil, e) }
        switch self {
        case .hello: proxy.hello(req, reply: reply)
        case .provisionProfile: proxy.provisionProfile(req, reply: one)
        case .updateCredentials: proxy.updateCredentials(req, reply: one)
        case .removeProfile: proxy.removeProfile(req, reply: one)
        case .listProvisioned: proxy.listProvisioned(req, reply: reply)
        case .wipeAllSecrets: proxy.wipeAllSecrets(req, reply: one)
        case .validateProfile: proxy.validateProfile(req, reply: reply)
        case .tunnelSnapshot: proxy.tunnelSnapshot(req, reply: reply)
        case .statistics: proxy.statistics(req, reply: reply)
        case .pendingAuthPrompt: proxy.pendingAuthPrompt(req, reply: reply)
        case .prepareStartAuth: proxy.prepareStartAuth(req, reply: reply)
        case .answerAuth: proxy.answerAuth(req, reply: one)
        case .cancelAuth: proxy.cancelAuth(req, reply: one)
        case .sessionSummaries: proxy.sessionSummaries(req, reply: reply)
        case .measureLatency: proxy.measureLatency(req, reply: reply)
        case .pushEndpoints: proxy.pushEndpoints(req, reply: reply)
        case .armStart: proxy.armStart(req, reply: reply)
        case .revokeUnattended: proxy.revokeUnattended(req, reply: one)
        }
    }
}

/// How an NSXPC transport error is classified (NSCocoaErrorDomain 4097/4099/4101/4102; ref/xpc-servicemanagement §1.1).
public enum XPCTransportFailure: Sendable, Equatable {
    /// 4097: the extension died (crash, kill, replacement in progress) or a requirement-failed peer was cancelled.
    case interrupted
    /// 4099: the name is not reachable now (not approved/activated, replaced, deactivated) or invalidated.
    case invalid
    /// 4101: the reply failed to decode.
    case replyInvalid
    /// 4102: the peer failed our code-signing requirement.
    case codeSigningRequirementFailure
    case other(domain: String, code: Int)

    public static let interruptedCode = 4097       // NSXPCConnectionInterrupted
    public static let invalidCode = 4099           // NSXPCConnectionInvalid
    public static let replyInvalidCode = 4101      // NSXPCConnectionReplyInvalid
    public static let codeSigningCode = 4102       // NSXPCConnectionCodeSigningRequirementFailure

    public init(_ error: NSError) {
        guard error.domain == NSCocoaErrorDomain else { self = .other(domain: error.domain, code: error.code); return }
        switch error.code {
        case Self.interruptedCode: self = .interrupted
        case Self.invalidCode: self = .invalid
        case Self.replyInvalidCode: self = .replyInvalid
        case Self.codeSigningCode: self = .codeSigningRequirementFailure
        default: self = .other(domain: error.domain, code: error.code)
        }
    }

    /// §5.4 mapping. 4097/4099 → `.extensionUnavailable` (the UI derives the message from SystemExtensionManager.state),
    /// 4102 → `.unauthorizedPeer` (never retried), 4101 → `.malformedRequest`.
    public var lpError: LPError {
        switch self {
        case .interrupted: LPError(.extensionUnavailable, detail: "interrupted")
        case .invalid: LPError(.extensionUnavailable, detail: "invalid")
        case .replyInvalid: LPError(.malformedRequest, detail: "reply invalid")
        case .codeSigningRequirementFailure: LPError(.unauthorizedPeer)
        case .other(let d, let c): LPError(.extensionUnavailable, detail: "\(d) \(c)")
        }
    }
}
