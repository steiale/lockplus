import Foundation
import LPModel
import NetworkExtension
import os

/// DESIGN §7.1. The controller's only view of the provider.
/// Deviation (reported): `apply` takes the builder's `TunnelSettingsSpec` instead of a raw `NetworkPlan`, so the §10
/// policy (DNS rows, blackhole, MTU) runs in the controller where the policy lives, and `FakeHost` compares specs.
/// A provider's protection as NE enforces it: `includeAllNetworks` (full-tunnel kill switch) and `enforceRoutes`
/// (split-tunnel route protection). Either one makes a session "kill switch" (§7.2: held, never cancelled).
public struct ProviderProtection: Sendable, Equatable {
    public var includeAllNetworks: Bool
    public var enforceRoutes: Bool
    public init(includeAllNetworks: Bool, enforceRoutes: Bool) {
        self.includeAllNetworks = includeAllNetworks; self.enforceRoutes = enforceRoutes
    }
    public var killSwitch: Bool { includeAllNetworks || enforceRoutes }
}

public protocol ProviderHost: AnyObject, Sendable {
    /// Non-optional by design: `setTunnelNetworkSettings(nil)` is never issued (C20; v2.0 never removes settings), and the
    /// type makes that unrepresentable instead of guarding it at runtime.
    func apply(_ settings: TunnelSettingsSpec) async throws(LPTunnelError)
    /// No effect unless NE status is Connected [NETunnelProvider.h:104-108].
    func setReasserting(_ on: Bool)
    /// cancelTunnelWithError on `owner`'s provider (review M1: the session's own provider, never whichever is bound
    /// by the time a teardown finishes; nil: the bound one). A no-op when `owner`'s provider is gone.
    func cancel(with error: LPTunnelError, owner: ProviderLease?)
    /// §7.3 selection rule.
    func tunnelFileDescriptor(matching address: String?) -> Int32?
    /// 2.0.1 (Codex final 1, round 3 structure): `owner`'s provider's CURRENT protection flags. NE updates a running
    /// provider's `protocolConfiguration` when the configuration is saved (`NETunnelProvider.h`: "may change during the
    /// lifetime of the tunnel"), and a flag save on a connected session changes its enforcement at once (DESIGN §10.4,
    /// U7). nil: unknown (no such binding); the controller's `effectiveProtection` falls back to the start-time flags.
    func liveProtection(owner: ProviderLease?) -> ProviderProtection?
    /// A strong reference that keeps the native provider alive (Codex r3 3): the router holds it across a dispatch so
    /// the provider's `deinit` (which re-enters the router) can only run after the router's locks are released.
    func pin() -> AnyObject?
    /// The packet flow, for the `packetFlow` data plane.
    var packetFlow: any PacketFlowSource { get }
}

/// Wraps the real provider. NEProvider/NETunnelProvider "Instances of this class are thread safe"
/// [NEProvider.h:77, NETunnelProvider.h:65].
/// 2.0.1 re-check L5: the provider is held `weak` (it was `unowned`): a late cancel (review M1/H1, up to ~6 s after its
/// session ended) may find it already released by NE, and every call is then a no-op instead of a trap in the root
/// extension.
// SAFETY: the provider is thread safe per its headers; the weak reference is loaded atomically; nothing else is mutable.
public final class RealProviderHost: ProviderHost, @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?
    private let utun: DarwinUtunSystem
    public let packetFlow: any PacketFlowSource

    public init(_ provider: NEPacketTunnelProvider) {
        self.provider = provider
        utun = DarwinUtunSystem()
        packetFlow = NEPacketFlowSource(provider.packetFlow)
    }

    public func apply(_ settings: TunnelSettingsSpec) async throws(LPTunnelError) {
        guard let provider else { throw .of(.networkSettingsFailed, "no provider") }
        let ns = NetworkSettingsBuilder.makeSettings(settings)
        let r: (any Error)? = await withCheckedContinuation { (k: CheckedContinuation<(any Error)?, Never>) in
            provider.setTunnelNetworkSettings(ns) { @Sendable e in k.resume(returning: e) }
        }
        if let r { throw .of(.networkSettingsFailed, "\((r as NSError).domain) \((r as NSError).code)") }
    }

    public func setReasserting(_ on: Bool) { provider?.reasserting = on }

    public func cancel(with error: LPTunnelError, owner: ProviderLease?) { provider?.cancelTunnelWithError(error as NSError) }

    public func liveProtection(owner: ProviderLease?) -> ProviderProtection? {
        guard let p = provider?.protocolConfiguration as? NETunnelProviderProtocol else { return nil }
        return ProviderProtection(includeAllNetworks: p.includeAllNetworks, enforceRoutes: p.enforceRoutes)
    }

    public func pin() -> AnyObject? { provider }

    public func tunnelFileDescriptor(matching address: String?) -> Int32? {
        do { return try UtunSelector.select(matching: address, system: utun).fd } catch {
            engineLog.error("utun selection failed: \(error.detail ?? "", privacy: .public)")
            return nil
        }
    }
}
