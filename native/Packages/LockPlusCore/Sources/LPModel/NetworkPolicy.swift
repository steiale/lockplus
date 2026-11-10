import Foundation

// DESIGN §3.1 (policy part of Profile) and §7.7 (sessions). Shared by the app's ProfileStore and the extension.

public enum DNSMode: String, Codable, Sendable { case tunnelOnly, split }

public struct NetworkPolicy: Codable, Sendable, Equatable {
    /// full tunnel: includeAllNetworks; split: enforceRoutes
    public var killSwitch: Bool
    /// excludeLocalNetworks; default OFF (TunnelCrack LocalNet, F-1)
    public var allowLAN: Bool
    public var excludeAPNs: Bool
    public var excludeCellularServices: Bool
    public var excludeDeviceCommunication: Bool
    public var dnsMode: DNSMode
    /// 576…9000
    public var mtuOverride: Int?
    /// on-demand "always" rule (replaces Go AutoReconnect)
    public var stayConnected: Bool
    /// v4-only full tunnels: §10.5 blackhole even with killSwitch off
    public var blockIPv6WithoutKillSwitch: Bool

    public init(killSwitch: Bool, allowLAN: Bool = false, excludeAPNs: Bool = true, excludeCellularServices: Bool = true,
                excludeDeviceCommunication: Bool = true, dnsMode: DNSMode = .tunnelOnly, mtuOverride: Int? = nil,
                stayConnected: Bool = false, blockIPv6WithoutKillSwitch: Bool = false) {
        self.killSwitch = killSwitch; self.allowLAN = allowLAN; self.excludeAPNs = excludeAPNs
        self.excludeCellularServices = excludeCellularServices; self.excludeDeviceCommunication = excludeDeviceCommunication
        self.dnsMode = dnsMode; self.mtuOverride = mtuOverride; self.stayConnected = stayConnected
        self.blockIPv6WithoutKillSwitch = blockIPv6WithoutKillSwitch
    }

    /// §3.1 default for new imports: kill switch follows full-tunnel, everything else at its default.
    public static func importDefault(isFullTunnel: Bool) -> NetworkPolicy { NetworkPolicy(killSwitch: isFullTunnel) }
}

/// §7.7 session record, appended to a 100-entry ring at `stopped`; merged into history by `id` (idempotent).
public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var profileID: UUID
    public var start: Date
    public var end: Date
    public var rxBytes: UInt64
    public var txBytes: UInt64
    /// "user", "error:<code>", "sleep", "onDemand", "replaced"
    public var endReason: String

    public init(id: UUID, profileID: UUID, start: Date, end: Date, rxBytes: UInt64, txBytes: UInt64, endReason: String) {
        self.id = id; self.profileID = profileID; self.start = start; self.end = end
        self.rxBytes = rxBytes; self.txBytes = txBytes; self.endReason = endReason
    }
}
