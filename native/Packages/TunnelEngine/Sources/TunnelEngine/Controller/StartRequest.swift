import Foundation
import LPModel
import LPWire
import NetworkExtension

/// `startVPNTunnel(options:)`, copied into a Sendable value on the provider queue (DESIGN §5.2).
/// The app ALWAYS passes `lp.manual = 1`; on-demand starts and `scutil --nc start` give `nil` options.
/// Draft 9 (S2 E1): NE replays these options verbatim when it restarts a crashed provider, so they carry nothing
/// one-shot: no OTP, no answer, no promptID. Only the manual marker and the app-resolved endpoint IPs.
public struct StartOptions: Sendable, Equatable {
    public var isManual: Bool
    /// `[hostname: [IP literal]]` the app resolved before the start (§9.3, S2 E10).
    public var endpoints: [String: [String]]

    public init(isManual: Bool, endpoints: [String: [String]] = [:]) {
        self.isManual = isManual; self.endpoints = endpoints
    }

    /// A manual start is one carrying the app's `lp.manual = 1` marker (§5.2). Any other options dictionary (a foreign
    /// caller) is treated like an on-demand start: the start latch applies and its endpoint IPs are ignored.
    public init(_ options: [String: NSObject]?) {
        guard let o = options, (o[StartOptionKey.manual] as? NSNumber)?.intValue == 1 else { self.init(isManual: false); return }
        self.init(isManual: true, endpoints: Self.endpoints(o[StartOptionKey.endpoints]))
    }

    /// Bounded and validated: ≤ 8 hostnames of ≤ 253 bytes, ≤ 16 IP literals each; anything else is dropped.
    static func endpoints(_ raw: NSObject?) -> [String: [String]] {
        guard let d = raw as? [String: Any] else { return [:] }
        var out: [String: [String]] = [:]
        for host in d.keys.sorted() where out.count < StartOptionKey.maxEndpointHosts {
            guard !host.isEmpty, host.utf8.count <= 253, let list = d[host] as? [String] else { continue }
            let ips = list.filter { IPAddress.isV4($0) || IPAddress.isV6($0) }.prefix(StartOptionKey.maxIPsPerHost)
            if !ips.isEmpty { out[host.lowercased()] = Array(ips) }
        }
        return out
    }
}

/// `providerConfiguration` + protocol-level flags of the session's `NETunnelProviderProtocol` (§3.3, §10.1).
public struct ProviderConfiguration: Sendable, Equatable {
    public var profileID: UUID
    public var kind: VPNProtocolKind
    public var revision: UInt64
    public var ownerUID: uid_t
    public var policy: NetworkPolicy
    /// Whether the manager has any on-demand rule (C16 condition). Needs the app to mirror it into
    /// `providerConfiguration["onDemand"]`: the provider can't see the manager's rules (reported as a spec gap).
    public var hasOnDemandRules: Bool
    /// `auth.interactive`, and which prompt NEED_CREDS maps to.
    public var interactiveKind: AuthKind
    /// The protocol's `includeAllNetworks` (a full-tunnel kill switch). Draft 9: it selects the S2 rows (withhold
    /// before Connected, no provider DNS); `policy.killSwitch` also covers split-tunnel route protection.
    public var includeAllNetworks: Bool

    /// `includeAllNetworks` defaults to the kill switch (the full-tunnel case).
    public init(profileID: UUID, kind: VPNProtocolKind, revision: UInt64, ownerUID: uid_t, policy: NetworkPolicy,
                hasOnDemandRules: Bool = false, interactiveKind: AuthKind = .userPass, includeAllNetworks: Bool? = nil) {
        self.profileID = profileID; self.kind = kind; self.revision = revision; self.ownerUID = ownerUID
        self.policy = policy; self.hasOnDemandRules = hasOnDemandRules; self.interactiveKind = interactiveKind
        self.includeAllNetworks = includeAllNetworks ?? policy.killSwitch
    }

    /// Parses the §3.3 dictionary. `kind` accepts both the §3.3 strings ("wg"/"ovpn") and LPModel's raw values.
    public init?(providerConfiguration pc: [String: Any], includeAllNetworks: Bool, enforceRoutes: Bool, excludeLocalNetworks: Bool,
                 excludeAPNs: Bool = true, excludeCellularServices: Bool = true, excludeDeviceCommunication: Bool = true) {
        guard (pc["v"] as? Int) == 1,
              let ids = pc["profileID"] as? String, let id = UUID(uuidString: ids),
              let ks = pc["kind"] as? String,
              let kind: VPNProtocolKind = (ks == "wg" ? .wireGuard : ks == "ovpn" ? .openVPN : VPNProtocolKind(rawValue: ks)),
              let rev = (pc["revision"] as? NSNumber)?.uint64Value,
              let uid = (pc["ownerUID"] as? NSNumber)?.uint32Value
        else { return nil }
        var p = NetworkPolicy(killSwitch: includeAllNetworks || enforceRoutes)
        p.allowLAN = excludeLocalNetworks
        p.excludeAPNs = excludeAPNs; p.excludeCellularServices = excludeCellularServices
        p.excludeDeviceCommunication = excludeDeviceCommunication
        p.dnsMode = DNSMode(rawValue: pc["dnsMode"] as? String ?? "") ?? .tunnelOnly
        p.mtuOverride = (pc["mtu"] as? NSNumber)?.intValue
        p.blockIPv6WithoutKillSwitch = (pc["blockIPv6"] as? Bool) ?? false
        let auth = pc["auth"] as? [String: Any]
        let ik = AuthKind(rawValue: auth?["kind"] as? String ?? "") ?? .userPass
        self.init(profileID: id, kind: kind, revision: rev, ownerUID: uid, policy: p,
                  hasOnDemandRules: (pc["onDemand"] as? Bool) ?? false, interactiveKind: ik, includeAllNetworks: includeAllNetworks)
    }

    public init?(_ proto: NEVPNProtocol?) {
        guard let p = proto as? NETunnelProviderProtocol, let pc = p.providerConfiguration else { return nil }
        self.init(providerConfiguration: pc, includeAllNetworks: p.includeAllNetworks, enforceRoutes: p.enforceRoutes,
                  excludeLocalNetworks: p.excludeLocalNetworks, excludeAPNs: p.excludeAPNs,
                  excludeCellularServices: p.excludeCellularServices, excludeDeviceCommunication: p.excludeDeviceCommunication)
    }
}

public struct StartRequest: Sendable {
    public var options: StartOptions
    public var configuration: ProviderConfiguration?
    /// Overrides `ControllerConfig.dataPlane` for this session. Only the Tunnel target's FaultInjection switch
    /// (`LP_FAULT_INJECTION`, for the leak harness's per-mode runs, §15.3) ever sets it; production starts pass nil.
    public var dataPlaneOverride: DataPlane?
    /// 2.0.1 re-check N3: the NE protocol's own flags, kept beside the optional `configuration`, so the kill-switch
    /// priority (§7.2 start guard) and the before-Connected hold hold even when `providerConfiguration` doesn't parse.
    public var protocolIncludeAllNetworks = false
    public var protocolEnforceRoutes = false
    public init(options: StartOptions, configuration: ProviderConfiguration?, dataPlaneOverride: DataPlane? = nil) {
        self.options = options; self.configuration = configuration; self.dataPlaneOverride = dataPlaneOverride
    }

    /// The provider's form: the configuration and the protocol's flags from the same `protocolConfiguration`.
    public init(options: StartOptions, protocolConfiguration proto: NEVPNProtocol?, dataPlaneOverride: DataPlane? = nil) {
        self.init(options: options, configuration: ProviderConfiguration(proto), dataPlaneOverride: dataPlaneOverride)
        let p = proto as? NETunnelProviderProtocol
        protocolIncludeAllNetworks = p?.includeAllNetworks ?? false
        protocolEnforceRoutes = p?.enforceRoutes ?? false
    }

    /// `includeAllNetworks` of this start: the configuration's, else the protocol's (N3).
    public var includeAllNetworks: Bool { configuration?.includeAllNetworks ?? protocolIncludeAllNetworks }
}

public enum StopReason: Sendable, Equatable {
    case userInitiated, providerFailed, noNetwork, sleep, configurationRemoved, superseded, appUpdate, other(Int)
    public init(_ r: NEProviderStopReason) {
        switch r {
        case .userInitiated: self = .userInitiated
        case .providerFailed: self = .providerFailed
        case .noNetworkAvailable: self = .noNetwork
        case .sleep: self = .sleep
        case .configurationRemoved, .configurationDisabled: self = .configurationRemoved
        case .superceded: self = .superseded
        case .appUpdate: self = .appUpdate
        default: self = .other(r.rawValue)
        }
    }
}
