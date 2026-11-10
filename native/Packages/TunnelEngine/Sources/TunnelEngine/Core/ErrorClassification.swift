import Foundation
import LPModel

/// Error-code policy used by the §7.2 rows (codes themselves are LPModel's, §5.5).
extension LPErrorCode {
    /// §7.2 C16 list: never retried by a system restart (auth and profile errors).
    public var isNonRetryable: Bool {
        switch self {
        case .authFailed, .authRequired, .profileInvalid, .profileNotProvisioned, .secretStoreUnavailable,
             .legacyCryptoUnavailable, .serverIdentityMismatch, .pushedOptionRejected,
             // Not in the §7.2 list but of the same class (draft 7: never fixed by retrying): see report.
             .webAuthUnsupported, .profileRevisionStale, .keyPassphraseRequired, .dnsPlanMissing, .authTimedOut:
            return true
        default:
            return false
        }
    }
}

extension LPTunnelError {
    static func of(_ code: LPErrorCode, _ detail: String? = nil) -> LPTunnelError { LPTunnelError(code, detail: detail) }
    var asLPError: LPError { LPError(code, detail: detail) }
}

/// Detail strings the secret stores attach to `.secretStoreUnavailable` (non-secret, local).
public enum SecretStoreDetail {
    /// -25308 / kIOReturnNotPermitted before the first login after boot (§6.3): arms a `.backoff` latch, never `.hard`.
    public static let lockedBeforeLogin = "locked-before-login"
    /// An item exists but can't be read back as what its address says (corrupt or moved). Provisioning overwrites it.
    public static let unreadableItem = "unreadable-item"
}
