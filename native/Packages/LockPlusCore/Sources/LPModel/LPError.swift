import Foundation

/// The one error type that crosses XPC and the UI (DESIGN §5.5).
/// `detail` is ≤ 512 characters and never contains secrets or server-controlled text.
public struct LPError: Error, Codable, Sendable, Equatable, Hashable {
    public static let maxDetailLength = 512

    public var code: LPErrorCode
    public var detail: String?

    public init(_ code: LPErrorCode, detail: String? = nil) {
        self.code = code
        self.detail = detail.map { String($0.prefix(Self.maxDetailLength)) }
    }
}

/// Raw values are stable: they are persisted and used as NSError codes (§5.5).
public enum LPErrorCode: Int, Codable, Sendable, CaseIterable {
    // transport
    case timeout = 1, extensionUnavailable, extensionBusy, versionMismatch, unauthorizedPeer,
         payloadTooLarge, malformedRequest, rateLimited /* reserved */, notOwner, cancelled, staleAnswer
    // profile
    case profileNotProvisioned = 100, profileInvalid, profileRevisionStale, unsupportedDirective,
         killSwitchNotApplied,       // E2E-1: the NE configuration's protocol flags don't carry the kill switch (app-side, never on the wire)
         profileCheckCrashed         // 2.0.2: the validator service died twice on the same profile check (app-side, never on the wire)
    // tunnel (also NSError codes for cancelTunnelWithError, domain LPTunnelError.errorDomain)
    case authFailed = 200, authRequired, authTimedOut, webAuthUnsupported, keyPassphraseRequired,
         connectTimeout, peerUnreachable, dnsResolutionFailed, engineFatal, tunDeviceFailed,
         networkSettingsFailed, legacyCryptoUnavailable, serverIdentityMismatch, conflictingVPN,
         secretStoreUnavailable, blockedAfterFailure, startCancelled, engineDied, dnsPlanMissing,
         pushedOptionRejected,       // draft 7: a pull-filter `reject` matched a pushed option (§8.5)
         endpointInterfaceUnusable,  // draft 7.3: server reachable only via a non-primary interface (§9.3)
         noNetwork,                  // E2E-4 200011: NE ended the session for want of a network (NEVPNConnectionError 2; app-side, never on the wire)
         anotherTunnelActive,        // 2.0.1: a start refused while another LockPlus configuration's session runs in the extension
         supersededByKillSwitch,     // 2.0.1 (review H1): a session without the kill switch ended for a kill-switch profile's start
         sessionInterrupted,         // 2.0.1 round 5: a session torn down for a kill-switch start, then kept (protected meanwhile) and held
         startNotAuthorised          // 2.0.2: a start the profile's owner didn't authorise (no LockPlus arm, no replay, no auto-connect)
}

/// The tunnel error keeps its code across `fetchLastDisconnectError` (CustomNSError, §5.5).
public struct LPTunnelError: Error, CustomNSError, Sendable {
    public static let errorDomain = "io.github.steiale.lockplus.tunnel"
    public static let detailKey = "lp.detail"

    public var code: LPErrorCode
    public var detail: String?

    public init(_ code: LPErrorCode, detail: String? = nil) {
        self.code = code
        self.detail = detail.map { String($0.prefix(LPError.maxDetailLength)) }
    }

    public var errorCode: Int { code.rawValue }
    /// Plist types only, so the error survives the trip through nesessionmanager.
    public var errorUserInfo: [String: Any] { detail.map { [Self.detailKey: $0] } ?? [:] }
}

/// Tunnel protocol of a profile.
public enum VPNProtocolKind: String, Codable, Sendable, CaseIterable {
    case wireGuard = "wg", openVPN = "ovpn"     // §3.1 raw values
}
