import Foundation
import LPModel
import NetworkExtension
import os

/// DESIGN §7.1. The controller's only view of the provider.
/// Deviation (reported): `apply` takes the builder's `TunnelSettingsSpec` instead of a raw `NetworkPlan`, so the §10
/// policy (DNS rows, blackhole, MTU) runs in the controller where the policy lives, and `FakeHost` compares specs.
public protocol ProviderHost: AnyObject, Sendable {
    /// Non-optional by design: `setTunnelNetworkSettings(nil)` is never issued (C20; v2.0 never removes settings), and the
    /// type makes that unrepresentable instead of guarding it at runtime.
    func apply(_ settings: TunnelSettingsSpec) async throws(LPTunnelError)
    /// No effect unless NE status is Connected [NETunnelProvider.h:104-108].
    func setReasserting(_ on: Bool)
    /// cancelTunnelWithError.
    func cancel(with error: LPTunnelError)
    /// §7.3 selection rule.
    func tunnelFileDescriptor(matching address: String?) -> Int32?
    /// The packet flow, for the `packetFlow` data plane.
    var packetFlow: any PacketFlowSource { get }
}

/// Wraps the real provider. NEProvider/NETunnelProvider "Instances of this class are thread safe"
/// [NEProvider.h:77, NETunnelProvider.h:65].
// SAFETY: the provider is thread safe per its headers; nothing else is mutable.
public final class RealProviderHost: ProviderHost, @unchecked Sendable {
    private unowned let provider: NEPacketTunnelProvider
    private let utun: DarwinUtunSystem
    public let packetFlow: any PacketFlowSource

    public init(_ provider: NEPacketTunnelProvider) {
        self.provider = provider
        utun = DarwinUtunSystem()
        packetFlow = NEPacketFlowSource(provider.packetFlow)
    }

    public func apply(_ settings: TunnelSettingsSpec) async throws(LPTunnelError) {
        let ns = NetworkSettingsBuilder.makeSettings(settings)
        let r: (any Error)? = await withCheckedContinuation { (k: CheckedContinuation<(any Error)?, Never>) in
            provider.setTunnelNetworkSettings(ns) { @Sendable e in k.resume(returning: e) }
        }
        if let r { throw .of(.networkSettingsFailed, "\((r as NSError).domain) \((r as NSError).code)") }
    }

    public func setReasserting(_ on: Bool) { provider.reasserting = on }

    public func cancel(with error: LPTunnelError) { provider.cancelTunnelWithError(error as NSError) }

    public func tunnelFileDescriptor(matching address: String?) -> Int32? {
        do { return try UtunSelector.select(matching: address, system: utun).fd } catch {
            engineLog.error("utun selection failed: \(error.detail ?? "", privacy: .public)")
            return nil
        }
    }
}
