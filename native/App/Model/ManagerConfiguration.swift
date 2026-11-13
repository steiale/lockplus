import Foundation
import LPModel
import LPWire

// What the app saves into one NETunnelProviderManager (DESIGN §3.3, §10.1, §10.4; PENDING-FOLD item 1). Pure and
// Sendable, so it is built and unit-tested without NetworkExtension; `NEManagerStore` turns it into NE objects.

/// `NETunnelProviderProtocol` flags, all written explicitly on every save (§10.1: macOS defaults differ from iOS).
struct ProtocolFlags: Sendable, Equatable {
    var includeAllNetworks: Bool
    var enforceRoutes: Bool
    var excludeLocalNetworks: Bool
    var excludeAPNs: Bool
    var excludeCellularServices: Bool
    var excludeDeviceCommunication: Bool

    /// §10.1 table: full tunnel + kill switch → includeAllNetworks; split + kill switch → enforceRoutes ("route
    /// protection"); kill switch off → none, and excludeLocalNetworks false (it has no effect without one of the two).
    init(policy: NetworkPolicy, isFullTunnel: Bool) {
        let ks = policy.killSwitch
        includeAllNetworks = ks && isFullTunnel
        enforceRoutes = ks && !isFullTunnel
        excludeLocalNetworks = ks ? policy.allowLAN : false
        excludeAPNs = policy.excludeAPNs
        excludeCellularServices = policy.excludeCellularServices
        excludeDeviceCommunication = policy.excludeDeviceCommunication
    }

    /// E2E-4 (U7): these flags protect LESS than `plan` in at least one respect: a protection the plan has is off
    /// (`includeAllNetworks`, `enforceRoutes`), or an exclusion the plan doesn't have is on (`excludeLocalNetworks`,
    /// `excludeAPNs`, `excludeCellularServices`, `excludeDeviceCommunication`). Only this direction is healed on a
    /// connected session; a drift that only adds protection waits for the session to end (L-KS-2).
    func isWeaker(than plan: ProtocolFlags) -> Bool {
        (plan.includeAllNetworks && !includeAllNetworks) || (plan.enforceRoutes && !enforceRoutes)
            || (excludeLocalNetworks && !plan.excludeLocalNetworks) || (excludeAPNs && !plan.excludeAPNs)
            || (excludeCellularServices && !plan.excludeCellularServices)
            || (excludeDeviceCommunication && !plan.excludeDeviceCommunication)
    }
}

/// One on-demand rule, as plain data (`NEOnDemandRule` is built from it on the main actor).
struct OnDemandRuleSpec: Sendable, Equatable {
    enum Action: Sendable, Equatable { case connect, disconnect, ignore }
    enum Interface: Sendable, Equatable { case any, wiFi, ethernet }
    var action: Action
    var interface: Interface
    var ssids: [String]? = nil
    var probeURL: URL? = nil
}

/// The on-demand part of a manager (§10.4).
struct OnDemandPlan: Sendable, Equatable {
    var rules: [OnDemandRuleSpec]
    var enabled: Bool

    /// Probe hosts (§10.4, N7), in rule order: our own static file on the Pages host (§2.5, returns 200 "ok"), then
    /// Apple's HTTPS success page as the independent fallback (a different operator), so one host being down or
    /// blocked doesn't make auto-connect fail open. Both HTTPS: a portal's hijacked plain-HTTP 200 must not match.
    static let ownProbeURL = URL(string: "https://steiale.github.io/lockplus-updates/probe.txt")!
    static let fallbackProbeURL = URL(string: "https://www.apple.com/library/test/success.html")!
    static let probeURLs: [URL] = [ownProbeURL, fallbackProbeURL]

    /// One connect rule per probe host, in `probeURLs` order (rules are evaluated in order; the first that matches wins).
    static func connect(_ i: OnDemandRuleSpec.Interface) -> [OnDemandRuleSpec] {
        probeURLs.map { OnDemandRuleSpec(action: .connect, interface: i, probeURL: $0) }
    }

    static let portalIgnore = OnDemandRuleSpec(action: .ignore, interface: .any)

    /// The auto profile: trusted SSIDs disconnect, untrusted Wi-Fi (and optionally Ethernet) connect with probes,
    /// everything else (a portal that failed both probes) is ignored.
    static func autoConnect(_ rules: AutoConnectRules, paused: Bool) -> OnDemandPlan {
        var r: [OnDemandRuleSpec] = []
        if !rules.trustedSSIDs.isEmpty {
            r.append(OnDemandRuleSpec(action: .disconnect, interface: .wiFi, ssids: rules.trustedSSIDs))
        }
        r += rules.connectOnUntrustedWiFi ? connect(.wiFi) : [OnDemandRuleSpec(action: .ignore, interface: .wiFi)]
        r += rules.connectOnEthernet ? connect(.ethernet) : [OnDemandRuleSpec(action: .ignore, interface: .ethernet)]
        r.append(portalIgnore)
        return OnDemandPlan(rules: r, enabled: rules.enabled && !paused)
    }

    /// `stayConnected` profiles: connect on any interface, portal ignore.
    static func stayConnected(paused: Bool) -> OnDemandPlan {
        OnDemandPlan(rules: connect(.any) + [portalIgnore], enabled: !paused)
    }

    /// The plan for one profile, or nil (no on-demand rules at all). `paused` also covers "suspended until the next
    /// network change". A profile that would need the user (a one-time code, or a password that isn't saved) can't
    /// start on demand (§8.4, review L8).
    static func plan(for profile: Profile, rules: AutoConnectRules, paused: Bool, hasSavedPassword: Bool = true) -> OnDemandPlan? {
        // Round 1 (Fable L1): an unverified profile ("Not yet verified") is never started by NE on its own: its start
        // would ask for a provision of bytes the sandboxed check never passed.
        guard profile.engineVerified else { return nil }
        let interactive = profile.needsOneTimeCode || (profile.auth?.needsUserPass == true && !hasSavedPassword)
        guard !interactive else { return nil }
        // Round 1 (Codex 4): a profile picked for Auto-Connect while the toggle is off has no plan: rules on the
        // configuration (`onDemand` in its provider configuration) are the user's consent to unattended starts, which the
        // extension admits without an arm. A pause keeps the plan (disabled): the consent stands, only the rules rest.
        if rules.profileID == profile.id { return rules.enabled ? autoConnect(rules, paused: paused) : nil }
        if profile.policy.stayConnected { return stayConnected(paused: paused) }
        return nil
    }
}

/// Everything one manager save writes.
struct ManagerConfiguration: Sendable, Equatable {
    var profileID: UUID
    var name: String
    var serverAddress: String
    var flags: ProtocolFlags
    var provider: ProviderConfigurationValues
    var onDemand: OnDemandPlan?

    init(profile: Profile, onDemand: OnDemandPlan?) {
        profileID = profile.id
        name = profile.name
        serverAddress = profile.serverAddress
        flags = ProtocolFlags(policy: profile.policy, isFullTunnel: profile.summary.isFullTunnel)
        provider = ProviderConfigurationValues(profile: profile, hasOnDemandRules: onDemand != nil)
        self.onDemand = onDemand
    }
}

/// `providerConfiguration` (§3.3, ≤ 2 KiB; PENDING-FOLD 1: `onDemand` and `auth.kind`). Mirrors exactly what
/// TunnelEngine's `ProviderConfiguration(providerConfiguration:…)` parses.
struct ProviderConfigurationValues: Sendable, Equatable {
    var profileID: UUID
    var kind: VPNProtocolKind
    var revision: UInt64
    var metaRev: UInt64
    var ownerUID: uid_t
    var dnsMode: DNSMode
    var mtu: Int?
    var blockIPv6: Bool
    var onDemand: Bool
    /// nil for WireGuard; `interactive` + the NEED_CREDS prompt kind for OpenVPN.
    var authKind: AuthKind?
    var interactive: Bool

    static let maxEncodedBytes = 2048

    init(profile p: Profile, hasOnDemandRules: Bool) {
        profileID = p.id
        kind = p.kind
        revision = p.payloadRevision
        metaRev = p.metaRevision
        ownerUID = p.ownerUID
        dnsMode = p.policy.dnsMode
        mtu = p.policy.mtuOverride
        blockIPv6 = p.policy.blockIPv6WithoutKillSwitch
        onDemand = hasOnDemandRules
        if let a = p.auth {
            interactive = a.needsUserPass || a.staticChallenge != nil || a.needsKeyPassphrase || p.dynamicChallengeSeen
            authKind = a.staticChallenge != nil ? .staticChallenge : a.needsKeyPassphrase && !a.needsUserPass ? .keyPassphrase : .userPass
        } else {
            interactive = false
            authKind = nil
        }
    }

    /// Plist types only.
    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "v": 1,
            "profileID": profileID.uuidString,
            "kind": kind.rawValue,
            "revision": NSNumber(value: revision),
            "metaRev": NSNumber(value: metaRev),
            "ownerUID": NSNumber(value: ownerUID),
            "dnsMode": dnsMode.rawValue,
            "blockIPv6": blockIPv6,
            "onDemand": onDemand,
        ]
        if let mtu { d["mtu"] = NSNumber(value: mtu) }
        if let authKind { d["auth"] = ["interactive": interactive, "kind": authKind.rawValue] as [String: Any] }
        return d
    }

    /// Read back from a saved manager (replay check, §3.4 N6).
    struct Stored: Sendable, Equatable {
        var revision: UInt64
        var metaRev: UInt64
        var ownerUID: uid_t?
        /// The configuration's `onDemand` (unattended-start consent as the extension reads it).
        var onDemand: Bool = false
    }

    static func stored(_ d: [String: Any]?) -> Stored? {
        guard let d, (d["v"] as? Int) == 1,
              let rev = (d["revision"] as? NSNumber)?.uint64Value,
              let meta = (d["metaRev"] as? NSNumber)?.uint64Value else { return nil }
        return Stored(revision: rev, metaRev: meta, ownerUID: ownerUID(d), onDemand: (d["onDemand"] as? Bool) ?? false)
    }

    /// The owner of a saved configuration, readable even when the rest of its dictionary isn't (E2E-4: another user's
    /// or an older build's configuration is still removable only by its owner).
    static func ownerUID(_ d: [String: Any]?) -> uid_t? { (d?["ownerUID"] as? NSNumber)?.uint32Value }
}

/// `startVPNTunnel(options:)` (§5.2, PENDING-FOLD 42). ALWAYS non-nil with `lp.manual = 1` as an NSNumber: only that
/// makes a start manual in the extension; anything else is treated as an on-demand start.
/// Draft 9 (S2 E1): NE replays these options verbatim when it restarts a crashed provider, so they NEVER carry an OTP,
/// an answer, a promptID or anything else one-shot. (S2 E10) `lp.endpoints`: the hostnames the app resolved just
/// before the start, so the provider never resolves under `includeAllNetworks`.
enum StartOptionsBuilder {
    /// PF 52: the app's restart after a tunnel-process crash stands in for the restart NE would have made, so it has
    /// on-demand semantics in the extension (no `lp.manual`: the start latch applies, no prompt, no prepared answer;
    /// endpoints from the extension's cache). Non-nil (NE would replay it on a later restart of its own).
    static var crashRestart: [String: NSObject] { [:] }

    /// 2.0.2 (PLAN-2.0.2 §3): `nonce` is the one this start's `armStart` announced (`StartArming`); the extension honours
    /// a manual start only with a matching arm of the profile's owner. A UUID string, never anything else. nil only for
    /// an extension that predates start authorisation (`StartArming.Outcome.legacyExtension`).
    static func options(endpoints: [String: [String]] = [:], nonce: UUID? = nil) -> [String: NSObject] {
        var o: [String: NSObject] = [StartOptionKey.manual: NSNumber(value: 1)]
        if let nonce { o[StartOptionKey.startNonce] = nonce.uuidString as NSString }
        let bounded = endpoints.keys.sorted().prefix(StartOptionKey.maxEndpointHosts).reduce(into: [String: [String]]()) { d, h in
            let ips = Array((endpoints[h] ?? []).prefix(StartOptionKey.maxIPsPerHost))
            if !ips.isEmpty { d[h] = ips }
        }
        if !bounded.isEmpty {
            o[StartOptionKey.endpoints] = bounded.mapValues { $0.map { $0 as NSString } as NSArray } as NSDictionary
        }
        return o
    }
}

/// 2.0.2 (PLAN-2.0.2 §3, D-1): every start the app makes of a manual profile is announced to the extension first
/// (`armStart`, over the kernel-authenticated XPC connection), and the start carries the same nonce. Without that the
/// extension refuses it (225): a System Settings toggle or `scutil --nc start` of a manual profile is not an authorised start.
/// Unattended starts (PF 52 crash restart `StartOptionsBuilder.crashRestart`, on-demand) are not armed: the extension
/// admits them by the profile's on-demand rules.
enum StartArming {
    enum Outcome: Sendable, Equatable {
        /// Armed: start with this nonce.
        case armed(UUID)
        /// The extension predates start authorisation (its hello lacks `.startAuthorisation`, e.g. the 2.0.1 extension is
        /// still running until its replacement is approved): it enforces nothing and ignores the option. The start goes
        /// ahead without a nonce. Only ever chosen when the hello itself succeeded and says so (never on a timeout).
        case legacyExtension
        case failed(LPError)
    }

    /// Round 2 (Fable L6): on `.legacyExtension` a kill-switch start is refused, in the GUI and the headless agent alike:
    /// it would carry no nonce, and NE's restart of it into the replacement extension would be refused (an open Mac).
    static func refusesKillSwitchStart(onLegacyExtension killSwitch: Bool) -> Bool { killSwitch }

    /// Whether a failure is the extension's definite answer about this profile (not a transport problem): the profile
    /// isn't provisioned in the caller's namespace, or the request was refused. A retry would not help.
    static func isDefinite(_ e: LPError) -> Bool {
        switch e.code {
        case .profileNotProvisioned, .profileRevisionStale, .malformedRequest, .unauthorizedPeer, .notOwner: true
        default: false
        }
    }

    /// `cap`: an upper bound for the whole exchange (the wire timeout of `armStart` is 2 s already).
    static func arm(_ id: UUID, service: any TunnelServicing, cap: Duration = .seconds(2)) async -> Outcome {
        let nonce = UUID()
        let attempt: Result<Void, LPError> = await withDeadline(cap, onTimeout: .failure(LPError(.timeout, detail: "armStart"))) {
            do throws(LPError) {
                _ = try await service.call(.armStart, ArmStartRequest(profileID: id, nonce: nonce), as: ArmStartReply.self)
                return .success(())
            } catch { return .failure(error) }
        }
        switch attempt {
        case .success: return .armed(nonce)
        case .failure(let e):
            guard !isDefinite(e), e.code != .timeout else { return .failed(e) }
            // An older extension answers an unknown method with a transport error. Only its own hello can say it is older.
            if let h = try? await service.hello(), !h.capabilities.contains(.startAuthorisation) { return .legacyExtension }
            return .failed(e)
        }
    }
}
