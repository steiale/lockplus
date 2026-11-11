import Foundation
import LPModel

/// Localized copy per `LPErrorCode` (DESIGN §11.6: error codes map to localized strings in the app only).
/// `message` is a full sentence for strips and alerts; `reason` is the lower-case fragment used after a colon
/// ("Work stopped: the server's certificate is not trusted."). `detail` is LPError's non-secret detail, used only by
/// the codes whose copy names a thing (the rejected option, the unusable interface).
extension LPErrorCode {
    /// Review L2: the app's own `detail` for `.anotherTunnelActive` when no session this user can see is active (another
    /// user's, or one LockPlus can't address): "Disconnect it first" would ask for something this user can't do.
    static let unseenSessionDetail = "lp.app.unseen-session"

    func message(detail: String? = nil) -> String {
        switch self {
        case .timeout: String(localized: "The tunnel component didn't answer in time.", comment: "Error message")
        case .extensionUnavailable: String(localized: "The tunnel component isn't running.", comment: "Error message")
        case .extensionBusy: String(localized: "The tunnel component is busy. Try again in a moment.", comment: "Error message")
        case .versionMismatch: String(localized: "The tunnel component is out of date. LockPlus is updating it.", comment: "Error message")
        case .unauthorizedPeer: String(localized: "The tunnel component refused this copy of LockPlus.", comment: "Error message")
        case .payloadTooLarge: String(localized: "The profile is too large.", comment: "Error message")
        case .malformedRequest: String(localized: "The tunnel component didn't understand a request from LockPlus.", comment: "Error message")
        case .rateLimited: String(localized: "Too many requests. Try again in a moment.", comment: "Error message")
        case .notOwner: String(localized: "This profile belongs to another user on this Mac.", comment: "Error message")
        case .cancelled: String(localized: "The request was cancelled.", comment: "Error message")
        case .staleAnswer: String(localized: "The sign-in request expired. Connect again.", comment: "Error message (§6.5)")
        case .profileNotProvisioned: String(localized: "The profile isn't installed in the tunnel component yet.", comment: "Error message")
        case .profileInvalid: String(localized: "The profile is invalid.", comment: "Error message")
        case .profileRevisionStale: String(localized: "The profile changed while connecting. Connect again.", comment: "Error message")
        case .unsupportedDirective: String(localized: "The profile uses a setting LockPlus doesn't support.", comment: "Error message")
        case .killSwitchNotApplied: String(localized: "Couldn't apply the kill switch. LockPlus won't connect unprotected.", comment: "Error message (E2E-1: the system dropped the kill switch from the VPN configuration)")
        case .authFailed: String(localized: "The server rejected the sign-in.", comment: "Error message")
        case .authRequired: String(localized: "The server asks you to sign in.", comment: "Error message")
        case .authTimedOut: String(localized: "Sign-in took too long.", comment: "Error message")
        case .webAuthUnsupported: String(localized: "This server uses web sign-in, which LockPlus doesn't support yet.", comment: "Error message (§6.5)")
        case .keyPassphraseRequired: String(localized: "The private key needs its passphrase.", comment: "Error message")
        case .connectTimeout: String(localized: "The server didn't answer.", comment: "Error message")
        case .peerUnreachable: String(localized: "The server can't be reached.", comment: "Error message")
        case .dnsResolutionFailed: String(localized: "The server's name couldn't be found.", comment: "Error message")
        case .engineFatal: String(localized: "The VPN engine stopped with an error.", comment: "Error message")
        case .tunDeviceFailed: String(localized: "macOS couldn't create the tunnel interface.", comment: "Error message")
        case .networkSettingsFailed: String(localized: "macOS refused the tunnel's network settings.", comment: "Error message")
        case .legacyCryptoUnavailable: String(localized: "This server needs an outdated cipher LockPlus doesn't support.", comment: "Error message (§6.15)")
        case .serverIdentityMismatch: String(localized: "The server's certificate is not trusted.", comment: "Error message")
        case .conflictingVPN: String(localized: "Another VPN is active.", comment: "Error message")
        case .secretStoreUnavailable: String(localized: "The saved credentials can't be read until you log in.", comment: "Error message")
        case .blockedAfterFailure: String(localized: "The tunnel stopped after an error.", comment: "Error message")
        case .startCancelled: String(localized: "The connection was cancelled.", comment: "Error message")
        case .engineDied: String(localized: "LockPlus's tunnel process stopped unexpectedly.", comment: "Error message (§6.15, also NE pluginFailed)")
        case .dnsPlanMissing: String(localized: "The tunnel's DNS settings are missing.", comment: "Error message")
        case .pushedOptionRejected:
            if let detail {
                String(localized: "The server sent a setting this profile refuses (\(detail)). Edit the profile or ask the server's operator.", comment: "Error message (§6.15). The argument is an OpenVPN option name such as redirect-gateway.")
            } else {
                String(localized: "The server sent a setting this profile refuses. Edit the profile or ask the server's operator.", comment: "Error message (§6.15)")
            }
        case .noNetwork: String(localized: "Your Mac isn't connected to a network.", comment: "Error message (E2E-4 200011: macOS ended the VPN session because there was no network)")
        case .anotherTunnelActive:
            if detail == Self.unseenSessionDetail {
                String(localized: "Another LockPlus connection is active: another user's on this Mac, or one LockPlus can't show. It has to end first.", comment: "Error message (2.0.1 review L2: a start refused beside a LockPlus session this user can't see)")
            } else {
                String(localized: "Another LockPlus profile is connected. Disconnect it first.", comment: "Error message (2.0.1: a start, e.g. from System Settings, refused while another LockPlus profile is connected)")
            }
        case .supersededByKillSwitch: String(localized: "Another LockPlus profile with the kill switch took over, so this one was disconnected.", comment: "Error message (2.0.1 review H1: a profile without the kill switch was ended for a kill-switch profile's start)")
        case .sessionInterrupted: String(localized: "Another LockPlus start interrupted the connection, then didn't go ahead.", comment: "Error message (2.0.1 round 5: a session torn down for another configuration's kill-switch start, kept and held because it became protected meanwhile)")
        case .endpointInterfaceUnusable:
            if let detail {
                String(localized: "This server is only reachable via \(detail), a network LockPlus's tunnel can't use. Connect the server to your main network (Wi-Fi or Ethernet).", comment: "Error message (§6.15). The argument is an interface name such as bridge100.")
            } else {
                String(localized: "This server is only reachable via a network LockPlus's tunnel can't use. Connect the server to your main network (Wi-Fi or Ethernet).", comment: "Error message (§6.15)")
            }
        }
    }

    /// Lower-case fragment for "<profile> stopped: <reason>." and the VoiceOver announcements.
    func reason(detail: String? = nil) -> String {
        switch self {
        case .timeout: String(localized: "the tunnel component didn't answer in time", comment: "Error reason fragment, used after a colon")
        case .extensionUnavailable: String(localized: "the tunnel component isn't running", comment: "Error reason fragment")
        case .extensionBusy: String(localized: "the tunnel component is busy", comment: "Error reason fragment")
        case .versionMismatch: String(localized: "the tunnel component is out of date", comment: "Error reason fragment")
        case .unauthorizedPeer: String(localized: "the tunnel component refused this copy of LockPlus", comment: "Error reason fragment")
        case .payloadTooLarge: String(localized: "the profile is too large", comment: "Error reason fragment")
        case .malformedRequest: String(localized: "the tunnel component didn't understand a request", comment: "Error reason fragment")
        case .rateLimited: String(localized: "too many requests", comment: "Error reason fragment")
        case .notOwner: String(localized: "the profile belongs to another user", comment: "Error reason fragment")
        case .cancelled: String(localized: "the request was cancelled", comment: "Error reason fragment")
        case .staleAnswer: String(localized: "the sign-in request expired", comment: "Error reason fragment")
        case .profileNotProvisioned: String(localized: "the profile isn't installed yet", comment: "Error reason fragment")
        case .profileInvalid: String(localized: "the profile is invalid", comment: "Error reason fragment")
        case .profileRevisionStale: String(localized: "the profile changed while connecting", comment: "Error reason fragment")
        case .unsupportedDirective: String(localized: "the profile uses an unsupported setting", comment: "Error reason fragment")
        case .killSwitchNotApplied: String(localized: "the kill switch couldn't be applied", comment: "Error reason fragment")
        case .authFailed: String(localized: "the server rejected the sign-in", comment: "Error reason fragment")
        case .authRequired: String(localized: "the server asks you to sign in", comment: "Error reason fragment")
        case .authTimedOut: String(localized: "sign-in took too long", comment: "Error reason fragment")
        case .webAuthUnsupported: String(localized: "the server uses web sign-in", comment: "Error reason fragment")
        case .keyPassphraseRequired: String(localized: "the private key needs its passphrase", comment: "Error reason fragment")
        case .connectTimeout: String(localized: "the server didn't answer", comment: "Error reason fragment")
        case .peerUnreachable: String(localized: "the server can't be reached", comment: "Error reason fragment")
        case .dnsResolutionFailed: String(localized: "the server's name couldn't be found", comment: "Error reason fragment")
        case .engineFatal: String(localized: "the VPN engine stopped with an error", comment: "Error reason fragment")
        case .tunDeviceFailed: String(localized: "macOS couldn't create the tunnel interface", comment: "Error reason fragment")
        case .networkSettingsFailed: String(localized: "macOS refused the tunnel's network settings", comment: "Error reason fragment")
        case .legacyCryptoUnavailable: String(localized: "the server needs an outdated cipher", comment: "Error reason fragment")
        case .serverIdentityMismatch: String(localized: "the server's certificate is not trusted", comment: "Error reason fragment (§6.6 drawing)")
        case .conflictingVPN: String(localized: "another VPN is active", comment: "Error reason fragment")
        case .secretStoreUnavailable: String(localized: "the saved credentials can't be read until you log in", comment: "Error reason fragment")
        case .blockedAfterFailure: String(localized: "the tunnel stopped after an error", comment: "Error reason fragment")
        case .startCancelled: String(localized: "the connection was cancelled", comment: "Error reason fragment")
        case .engineDied: String(localized: "the tunnel process stopped unexpectedly", comment: "Error reason fragment")
        case .dnsPlanMissing: String(localized: "the tunnel's DNS settings are missing", comment: "Error reason fragment")
        case .pushedOptionRejected:
            if let detail {
                String(localized: "the server sent a setting this profile refuses (\(detail))", comment: "Error reason fragment; the argument is an option name")
            } else {
                String(localized: "the server sent a setting this profile refuses", comment: "Error reason fragment")
            }
        case .noNetwork: String(localized: "your Mac isn't connected to a network", comment: "Error reason fragment")
        case .anotherTunnelActive:
            if detail == Self.unseenSessionDetail {
                String(localized: "another LockPlus connection is active (another user's, or one LockPlus can't show)", comment: "Error reason fragment")
            } else {
                String(localized: "another LockPlus profile is connected", comment: "Error reason fragment")
            }
        case .supersededByKillSwitch: String(localized: "another LockPlus profile with the kill switch took over", comment: "Error reason fragment")
        case .sessionInterrupted: String(localized: "another LockPlus start interrupted its connection", comment: "Error reason fragment")
        case .endpointInterfaceUnusable:
            if let detail {
                String(localized: "the server is only reachable via \(detail)", comment: "Error reason fragment; the argument is an interface name")
            } else {
                String(localized: "the server is only reachable via another network", comment: "Error reason fragment")
            }
        }
    }

    /// The same fragment for "…because <reason>" sentences (VoiceOver announcements), keyed separately so it can
    /// be translated for its own grammar (UI-M17: German needs different word order after "weil" than after ":").
    func causeReason(detail: String? = nil) -> String {
        switch self {
        case .timeout: String(localized: "because.timeout", defaultValue: "the tunnel component didn't answer in time", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .extensionUnavailable: String(localized: "because.extensionUnavailable", defaultValue: "the tunnel component isn't running", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .extensionBusy: String(localized: "because.extensionBusy", defaultValue: "the tunnel component is busy", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .versionMismatch: String(localized: "because.versionMismatch", defaultValue: "the tunnel component is out of date", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .unauthorizedPeer: String(localized: "because.unauthorizedPeer", defaultValue: "the tunnel component refused this copy of LockPlus", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .payloadTooLarge: String(localized: "because.payloadTooLarge", defaultValue: "the profile is too large", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .malformedRequest: String(localized: "because.malformedRequest", defaultValue: "the tunnel component didn't understand a request", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .rateLimited: String(localized: "because.rateLimited", defaultValue: "too many requests", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .notOwner: String(localized: "because.notOwner", defaultValue: "the profile belongs to another user", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .cancelled: String(localized: "because.cancelled", defaultValue: "the request was cancelled", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .staleAnswer: String(localized: "because.staleAnswer", defaultValue: "the sign-in request expired", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .profileNotProvisioned: String(localized: "because.profileNotProvisioned", defaultValue: "the profile isn't installed yet", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .profileInvalid: String(localized: "because.profileInvalid", defaultValue: "the profile is invalid", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .profileRevisionStale: String(localized: "because.profileRevisionStale", defaultValue: "the profile changed while connecting", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .unsupportedDirective: String(localized: "because.unsupportedDirective", defaultValue: "the profile uses an unsupported setting", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .killSwitchNotApplied: String(localized: "because.killSwitchNotApplied", defaultValue: "the kill switch couldn't be applied", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .authFailed: String(localized: "because.authFailed", defaultValue: "the server rejected the sign-in", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .authRequired: String(localized: "because.authRequired", defaultValue: "the server asks you to sign in", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .authTimedOut: String(localized: "because.authTimedOut", defaultValue: "sign-in took too long", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .webAuthUnsupported: String(localized: "because.webAuthUnsupported", defaultValue: "the server uses web sign-in", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .keyPassphraseRequired: String(localized: "because.keyPassphraseRequired", defaultValue: "the private key needs its passphrase", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .connectTimeout: String(localized: "because.connectTimeout", defaultValue: "the server didn't answer", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .peerUnreachable: String(localized: "because.peerUnreachable", defaultValue: "the server can't be reached", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .dnsResolutionFailed: String(localized: "because.dnsResolutionFailed", defaultValue: "the server's name couldn't be found", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .engineFatal: String(localized: "because.engineFatal", defaultValue: "the VPN engine stopped with an error", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .tunDeviceFailed: String(localized: "because.tunDeviceFailed", defaultValue: "macOS couldn't create the tunnel interface", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .networkSettingsFailed: String(localized: "because.networkSettingsFailed", defaultValue: "macOS refused the tunnel's network settings", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .legacyCryptoUnavailable: String(localized: "because.legacyCryptoUnavailable", defaultValue: "the server needs an outdated cipher", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .serverIdentityMismatch: String(localized: "because.serverIdentityMismatch", defaultValue: "the server's certificate is not trusted", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .conflictingVPN: String(localized: "because.conflictingVPN", defaultValue: "another VPN is active", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .secretStoreUnavailable: String(localized: "because.secretStoreUnavailable", defaultValue: "the saved credentials can't be read until you log in", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .blockedAfterFailure: String(localized: "because.blockedAfterFailure", defaultValue: "the tunnel stopped after an error", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .startCancelled: String(localized: "because.startCancelled", defaultValue: "the connection was cancelled", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .engineDied: String(localized: "because.engineDied", defaultValue: "the tunnel process stopped unexpectedly", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .dnsPlanMissing: String(localized: "because.dnsPlanMissing", defaultValue: "the tunnel's DNS settings are missing", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .pushedOptionRejected:
            if let detail {
                String(localized: "because.pushedOptionRejected.detail", defaultValue: "the server sent a setting this profile refuses (\(detail))", comment: "Error cause after \"because\"; the argument is an option name")
            } else {
                String(localized: "because.pushedOptionRejected", defaultValue: "the server sent a setting this profile refuses", comment: "Error cause after \"because\"")
            }
        case .noNetwork: String(localized: "because.noNetwork", defaultValue: "your Mac wasn't connected to a network", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .anotherTunnelActive:
            if detail == Self.unseenSessionDetail {
                String(localized: "because.anotherTunnelActive.unseen", defaultValue: "another LockPlus connection was active", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
            } else {
                String(localized: "because.anotherTunnelActive", defaultValue: "another LockPlus profile was connected", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
            }
        case .supersededByKillSwitch: String(localized: "because.supersededByKillSwitch", defaultValue: "another LockPlus profile with the kill switch took over", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .sessionInterrupted: String(localized: "because.sessionInterrupted", defaultValue: "another LockPlus start interrupted its connection", comment: "Error cause, used after \"because\" in a VoiceOver announcement")
        case .endpointInterfaceUnusable:
            if let detail {
                String(localized: "because.endpointInterfaceUnusable.detail", defaultValue: "the server is only reachable via \(detail)", comment: "Error cause after \"because\"; the argument is an interface name")
            } else {
                String(localized: "because.endpointInterfaceUnusable", defaultValue: "the server is only reachable via another network", comment: "Error cause after \"because\"")
            }
        }
    }
}
