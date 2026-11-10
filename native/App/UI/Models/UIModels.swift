import Foundation
import LPModel
import Observation

// View models the UI reads. They are plain `@MainActor @Observable` containers: the app's stores
// (ConnectionStore, StatsStore, ProfilesStore, AuthCoordinator, …; DESIGN §11.2) write into them, previews fill them
// with fixtures. Views never talk to NE or XPC. Split per concern so 1 Hz rate ticks never re-render forms
// (ref/swiftui-appkit §8).

// MARK: - Profiles

/// One ignored directive of an import report with its short reason (localised in the App target). `harmless`: LockPlus
/// handles it itself (info, "not needed"); otherwise its behaviour is NOT applied (warning, "not applied").
struct IgnoredDirective: Hashable, Sendable {
    var name: String
    var reason: String
    var harmless: Bool = true
}

struct ProfileItem: Identifiable, Sendable, Equatable {
    enum Routes: Sendable, Equatable {
        case allTraffic
        case split([String])
    }

    struct Credentials: Sendable, Equatable {
        enum OneTimeCode: Sendable, Equatable { case none, everyConnect, staticChallenge }
        var username: String?
        var passwordSaved: Bool
        var oneTimeCode: OneTimeCode
    }

    let id: UUID
    var name: String
    var kind: VPNProtocolKind
    /// "vpn.example.de:51820"
    var endpoint: String
    /// "198.51.100.7"
    var resolvedEndpoint: String?
    /// "Frankfurt"; nil falls back to the endpoint host in copy.
    var place: String?
    var transport: String?
    var addresses: [String] = []
    var dns: [String] = []
    var routes: Routes = .allTraffic
    var mtu: Int?
    var cipher: String?
    var killSwitch = true
    var allowLocalNetwork = false
    var blockIPv6WithoutKillSwitch = false
    /// IPv4-only full tunnel: the only case where "Block IPv6 without kill switch" applies (§6.4).
    var isIPv4OnlyFullTunnel = false
    var isAutoConnectProfile = false
    var credentials: Credentials?
    var notes = ""
    /// Directives LockPlus doesn't need (import report): the name and why, never an argument.
    var ignoredDirectives: [IgnoredDirective] = []
    /// OpenVPN step [7] hasn't run (the extension wasn't available at import): Connect stays disabled until the
    /// engine accepts the profile (DESIGN §8.1, `EngineCheck.notChecked`).
    var notYetVerified = false
    /// E2E-1: the system's VPN configuration doesn't carry this profile's protection settings right now; LockPlus is
    /// restoring them (and refuses to connect until they are verified).
    var protectionRepairing = false
    /// Review 5 §3: a Connect of this profile would be ignored now (another start, a switch or a crash restart is under
    /// way): why, shown as help on every disabled Connect. nil: Connect is available.
    var connectHeld: String?
    var lastSessionEnded: Date?
    var lastSessionDuration: TimeInterval?

    var isFullTunnel: Bool { routes == .allTraffic }

    /// Shown wherever Connect would be offered for a not-yet-verified profile.
    static var protectionRepairingExplanation: String {
        String(localized: "Restoring this profile's protection settings in macOS. The kill switch isn't active until they're verified, and LockPlus won't connect before that.", comment: "Protection settings being repaired (E2E-1)")
    }
    static var notYetVerifiedExplanation: String {
        String(localized: "LockPlus hasn't checked this profile with its OpenVPN engine yet. It's checked as soon as the tunnel component is running; until then it can't connect.", comment: "Not yet verified explanation (§8.1)")
    }
    var protocolName: String {
        switch kind {
        case .wireGuard: String(localized: "WireGuard", comment: "Protocol name")
        case .openVPN: String(localized: "OpenVPN", comment: "Protocol name")
        }
    }
    var protocolTag: String {
        switch kind {
        case .wireGuard: "WG"
        case .openVPN: "OVPN"
        }
    }
    var host: String {
        if let colon = endpoint.lastIndex(of: ":"), !endpoint.hasPrefix("[") { return String(endpoint[..<colon]) }
        return endpoint
    }
    var needsOneTimeCode: Bool {
        guard let c = credentials else { return false }
        return c.oneTimeCode != .none
    }

    func context(errorDetail: String? = nil, now: Date = Date()) -> ProfileContext {
        ProfileContext(name: name, place: place ?? host, protocolName: protocolName, errorDetail: errorDetail,
                       lastSessionSummary: lastSessionSummary(now: now))
    }

    /// "Last connected yesterday, 1 hr, 29 min" (§6.4 hero, disconnected).
    func lastSessionSummary(now: Date = Date()) -> String? {
        guard let ended = lastSessionEnded else { return nil }
        let when = ended.formatted(.relative(presentation: .named, unitsStyle: .wide))
        if let d = lastSessionDuration {
            return String(localized: "Last connected \(when), \(DurationFormat.short(d))", comment: "Hero, last session summary")
        }
        return String(localized: "Last connected \(when)", comment: "Hero, last session summary")
    }
}

/// "Change…" on a saved password (§6.4). The app fills it and handles the result in `onSave`.
struct PasswordChangeRequest: Identifiable {
    let id = UUID()
    var profileID: ProfileItem.ID
    var profileName: String
    var username: String
    /// false when the profile has `auth-nocache` (nothing may be stored).
    var canSaveInKeychain = true
    /// username, password, save in Keychain. Called once; the sheet clears its fields afterwards.
    var onSave: @MainActor (String, String, Bool) -> Void
}

/// "Show" on a saved password, AFTER the app's LAContext check passed (RevealGate, §6.4/F-10). The sheet is
/// excluded from capture and closes itself after 60 s.
struct PasswordReveal: Identifiable {
    let id = UUID()
    var profileName: String
    var username: String?
    var password: String
}

@MainActor @Observable final class ProfilesUIModel {
    /// In the store's order (user-defined drag order, default alphabetical). The sidebar pins the active one on top.
    var profiles: [ProfileItem]
    var selection: ProfileItem.ID?
    /// Set by `changePassword`; presented by the main window.
    var passwordChange: PasswordChangeRequest?
    /// Set by `showPassword` after authentication; presented by the main window.
    var passwordReveal: PasswordReveal?
    /// §6.8 "Profiles from another Mac are locked": names read from unverified metadata (display only); nil = not locked.
    var locked: [String]?
    /// E2E-4: the profile files couldn't be read (not "locked", not empty): the reason. The empty library then says so
    /// instead of "No Profiles".
    var readError: String?

    init(profiles: [ProfileItem] = [], selection: ProfileItem.ID? = nil) {
        self.profiles = profiles
        self.selection = selection
    }

    func profile(_ id: ProfileItem.ID?) -> ProfileItem? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }
}

// MARK: - Connection

@MainActor @Observable final class ConnectionUIModel {
    /// The profile the derived state is about: the active one, else the last used.
    var profileID: ProfileItem.ID?
    var inputs: DerivedStateInputs
    var connectedSince: Date?
    /// Any owned manager has on-demand enabled (pause rule, §6.2).
    var anyOnDemandEnabled = false
    /// `LPError.detail` of `inputs.lastError`, for codes whose copy names a thing.
    var lastErrorDetail: String?
    /// Details… disclosure: code, time, the extension's non-secret detail (DESIGN §11.7).
    var lastErrorAt: Date?
    /// Another VPN app is active (§6.15 attention strip): its display name.
    var otherVPNName: String?
    /// macOS hasn't allowed LockPlus to add VPN configurations (§6.15 banner).
    var vpnConfigurationDenied = false
    /// A LockPlus VPN configuration exists in the system, so macOS has already asked (onboarding hints, L6).
    var vpnConfigurationExists = false
    /// Auth prompt waiting for a user gesture (§6.5): "Enter Code for Acme…" in the menu.
    var pendingPromptProfileName: String?
    /// `ConnectionStore.resumeAgentStatus == .requiresApproval`: a pause can't end on time while LockPlus is closed.
    var resumeAgentNeedsApproval = false
    /// §4.5 old Go helper finding; nil when none.
    var legacyHelper: LegacyHelperNotice?
    /// E2E-5 F1: "Remove Old Helper" in progress or its result; nil when not asked.
    var legacyHelperRemoval: LegacyHelperRemovalState?
    /// Migration matrix: the old WireGuide+ app is still installed; offered for the Trash.
    var oldWireGuidePlusApp: OldAppNotice?
    /// Its last move to the Trash failed.
    var oldAppTrashFailed = false
    /// "Not Now" on that offer (this launch only).
    var oldAppOfferDismissed = false
    /// A Connect held by the old-helper rule; the main window shows it as a strip (E2E-5 F8).
    var connectGate: ConnectGateRequest?
    /// PF 53 (RS2 1): the current session came back by itself after the tunnel process crashed.
    var reconnectedAfterRestart = false
    /// E2E-4 (U15): the extension update failed while the old one keeps running the profiles; the honest line for the
    /// banner and for everything that needs the (unreachable) tunnel component. nil otherwise.
    var extensionUpdateFailedMessage: String?

    static var reconnectedAfterRestartText: String {
        String(localized: "Reconnected after a tunnel process restart.", comment: "Hero note (PF 53): the session came back by itself after the tunnel process crashed")
    }

    init(profileID: ProfileItem.ID? = nil, inputs: DerivedStateInputs) {
        self.profileID = profileID
        self.inputs = inputs
    }

    var condition: ConnectionCondition { inputs.condition }
}

// MARK: - Stats

struct RateSample: Identifiable, Sendable, Equatable {
    var id: Int
    var t: Date
    var rx: Double
    var tx: Double
}

/// `current` and `samples` are separate properties so the rate text and the chart invalidate independently (§11.2).
@MainActor @Observable final class StatsUIModel {
    var current: Rate?
    /// Up to 300 samples at 1 Hz (hero, Activity). The menu reads the last 60.
    var samples: [RateSample]
    var sessionReceived: UInt64 = 0
    var sessionSent: UInt64 = 0
    /// WireGuard last handshake age, OpenVPN keepalive RTT.
    var lastHandshake: Date?
    var latencyMilliseconds: Int?

    init(current: Rate? = nil, samples: [RateSample] = []) {
        self.current = current
        self.samples = samples
    }

    var menuSamples: ArraySlice<RateSample> { samples.suffix(60) }
}

// MARK: - Auth

/// One prompt at a time, keyed by promptID (DESIGN §8.4).
struct AuthPromptState: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Password (not saved); `oneTimeCode` adds the field for appendOTP profiles.
        case password(oneTimeCode: Bool)
        /// Static challenge: server text verbatim; echo per the SC flag (LPModel `StaticChallenge`).
        case staticChallenge(StaticChallenge)
        /// CRV1: read-only username, server text, response.
        case dynamicChallenge(text: String, echo: Bool)
        /// The server rejected the sign-in; its reason verbatim.
        case rejected(serverReason: String?, oneTimeCode: Bool)
        /// Private key passphrase (not saved).
        case keyPassphrase
        /// AUTH_PENDING push approval.
        case waitingForApproval(tooLate: Bool)
    }
    enum Notice: Sendable, Equatable {
        /// A dynamic-challenge code came back rejected or expired: a new challenge was fetched (§6.5, S8).
        case codeExpiredFreshChallenge
    }

    let id: UUID
    var profileName: String
    var kind: Kind
    var username: String = ""
    var canSavePassword = true
    /// 10 min, or 5 min for a dynamic challenge (§6.5).
    var expiresAt: Date?
    var notice: Notice?
}

struct AuthAnswer: Sendable {
    var promptID: UUID
    var username: String
    /// Secrets travel as String only until the coordinator wraps them in SecretBytes (DESIGN §6.5).
    var password: String
    var response: String
    var savePassword: Bool
}

@MainActor @Observable final class AuthUIModel {
    var prompt: AuthPromptState?
    /// The sign-in request expired (shown in place of the form, §6.5).
    var expired = false
    /// Why the last answer didn't arrive (busy, link down); the prompt is shown again with this line (M5).
    var error: String?
    init(prompt: AuthPromptState? = nil) { self.prompt = prompt }
}
