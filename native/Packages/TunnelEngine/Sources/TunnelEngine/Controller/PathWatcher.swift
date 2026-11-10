import Foundation
import Network

/// What the controller compares (§7.4): status, interface names+types, gateways, isExpensive.
public struct PathSnapshot: Sendable, Equatable {
    public enum Status: String, Sendable { case satisfied, unsatisfied, requiresConnection }
    public var status: Status
    public var interfaces: [String]       // "en0:wifi"
    public var gateways: [String]
    public var isExpensive: Bool
    public init(status: Status, interfaces: [String] = [], gateways: [String] = [], isExpensive: Bool = false) {
        self.status = status; self.interfaces = interfaces; self.gateways = gateways; self.isExpensive = isExpensive
    }
}

/// One path source per controller; `.bufferingNewest(1)` (only the latest path matters). The controller debounces.
public protocol PathSource: Sendable {
    func paths() -> AsyncStream<PathSnapshot>
}

/// One unrestricted `NWPathMonitor` (§7.4). Draft 9 (S2 E12): inside the provider, while connected, the monitor's
/// `availableInterfaces` is `[en0, en0, utunN]`: the provider's OWN tunnel interface is listed (and en0 twice), while
/// status, gateways and `usesInterfaceType` describe the physical path. Path changes are therefore decided on the
/// physical interfaces only: every tunnel interface is dropped and duplicates are collapsed, so our own utun coming
/// or going (or being listed twice) is never a "network change".
public struct NWPathSource: PathSource {
    public init() {}
    public func paths() -> AsyncStream<PathSnapshot> {
        let (stream, cont) = AsyncStream.makeStream(of: PathSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable p in cont.yield(Self.snapshot(p)) }
        cont.onTermination = { @Sendable _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "lockplus.path"))
        return stream
    }

    static func snapshot(_ p: NWPath) -> PathSnapshot {
        let status: PathSnapshot.Status = switch p.status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        default: .unsatisfied
        }
        let ifs = physicalInterfaces(p.availableInterfaces.map { (name: $0.name, type: "\($0.type)") })
        let gws = p.gateways.map { "\($0)" }.sorted()
        return PathSnapshot(status: status, interfaces: ifs, gateways: gws, isExpensive: p.isExpensive)
    }

    /// Tunnel interface name prefixes (the provider's own utun, and any other VPN's) never count as the path.
    static let tunnelPrefixes = ["utun", "ipsec", "tun", "tap", "gif", "stf"]     // not ppp: PPPoE is a real path

    /// `name:type` of the physical interfaces, in order, without duplicates and without tunnel interfaces (E12).
    static func physicalInterfaces(_ list: [(name: String, type: String)]) -> [String] {
        var out: [String] = []
        for i in list where !tunnelPrefixes.contains(where: { i.name.hasPrefix($0) }) {
            let s = "\(i.name):\(i.type)"
            if !out.contains(s) { out.append(s) }
        }
        return out
    }
}

/// Optional start-time endpoint interface check (§9.3 `RouteProbe`, which DESIGN places in LockPlusCore).
/// Returns the BSD name of a non-primary interface the endpoint routes through, or nil when it is fine.
public protocol EndpointInterfaceCheck: Sendable {
    func nonPrimaryInterface(for endpointIPs: [String]) -> String?
}
