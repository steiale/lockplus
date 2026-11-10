import Foundation
import LPModel
import LPRouteProbe
import LPWire
import NetworkExtension
import os
import Synchronization
import TunnelEngine

/// Creates one adapter per start, binding libwg-go and OpenVPN3Shim (TunnelEngine's `TunnelAdapterFactory`).
/// Both adapters sleep on the strict clock too (draft 9, S2): the WG resolve deadline and handshake cadence and the OVPN
/// wake-reconnect coalesce are deadlines, and `SuspendingClock` sleeps carry ~10 % leeway.
struct EngineAdapterFactory: TunnelAdapterFactory {
    let guiVersion: String

    func makeAdapter(kind: VPNProtocolKind) -> any TunnelAdapter {
        switch kind {
        case .wireGuard:
            WireGuardAdapter(backend: WireGuardGoBackend(), parser: LPWGConfigParser(), clock: StrictSuspendingClock())
        case .openVPN:
            OpenVPNAdapter(factory: OpenVPN3ShimFactory(), clock: StrictSuspendingClock(), guiVersion: guiVersion)
        }
    }
}

/// The §9.3 start-time endpoint interface check over LPRouteProbe (PF_ROUTE RTM_GET, IP literals only, no DNS).
/// Residual: it runs on the IPs known at start (start options or the cached resolution); the IPs the adapters resolve
/// afterwards are not re-probed (TunnelEngine's adapters own resolution and are frozen; noted for the fold-in).
struct RouteProbeEndpointCheck: EndpointInterfaceCheck {
    func nonPrimaryInterface(for endpointIPs: [String]) -> String? {
        RouteProbe.nonPrimaryInterface(forIPs: endpointIPs)
    }
}

/// The process-scope view of "the current provider" (DESIGN §5.1: the XPC listener and the controller belong to the
/// process, not to a provider instance; pending prompts and latches must survive from one provider instance to the
/// next). `PacketTunnelProvider` binds itself in `startTunnel` and unbinds after `stopTunnel` completes.
/// C20 (never `setTunnelNetworkSettings(nil)`) is enforced by `ProviderHost.apply`'s non-optional type.
// SAFETY: @unchecked Sendable: the only mutable state is `current`, guarded by its Mutex; RealProviderHost is
// Sendable and the provider itself is documented thread safe [NEProvider.h:77].
final class ProcessProviderHost: ProviderHost, @unchecked Sendable {
    static let shared = ProcessProviderHost()

    private let current = Mutex<(id: ObjectIdentifier, host: RealProviderHost)?>(nil)
    let packetFlow: any PacketFlowSource

    private init() { packetFlow = ForwardingPacketFlow() }

    func bind(_ provider: NEPacketTunnelProvider) {
        let host = RealProviderHost(provider)
        current.withLock { $0 = (ObjectIdentifier(provider), host) }
        (packetFlow as? ForwardingPacketFlow)?.set(host.packetFlow)
    }

    /// Unbinds only if `provider` is still the bound one (a newer provider may have bound meanwhile).
    func unbind(_ provider: NEPacketTunnelProvider) {
        let was = current.withLock { c -> Bool in
            guard c?.id == ObjectIdentifier(provider) else { return false }
            c = nil
            return true
        }
        if was { (packetFlow as? ForwardingPacketFlow)?.set(nil) }
    }

    private var host: RealProviderHost? { current.withLock { $0?.host } }

    func apply(_ settings: TunnelSettingsSpec) async throws(LPTunnelError) {
        guard let h = host else { throw LPTunnelError(.networkSettingsFailed, detail: "no provider") }
        try await h.apply(settings)
    }

    func setReasserting(_ on: Bool) { host?.setReasserting(on) }
    func cancel(with error: LPTunnelError) { host?.cancel(with: error) }
    func tunnelFileDescriptor(matching address: String?) -> Int32? { host?.tunnelFileDescriptor(matching: address) }
}

/// Forwards to the bound provider's `NEPacketTunnelFlow`; without one, reads never complete (nothing to pump).
// SAFETY: @unchecked Sendable: `flow` is guarded by its Mutex; the wrapped NEPacketFlowSource is thread safe.
final class ForwardingPacketFlow: PacketFlowSource, @unchecked Sendable {
    private let flow = Mutex<(any PacketFlowSource)?>(nil)
    func set(_ f: (any PacketFlowSource)?) { flow.withLock { $0 = f } }
    func readPackets(_ handler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        flow.withLock { $0 }?.readPackets(handler)
    }
    @discardableResult func writePackets(_ packets: [Data], protocols: [NSNumber]) -> Bool {
        flow.withLock { $0 }?.writePackets(packets, protocols: protocols) ?? false
    }
}

/// Everything process-scope the engine needs, built once (lazily, on first use by the listener or a provider).
final class TunnelEngineAssembly: Sendable {
    static let shared = TunnelEngineAssembly()

    let registry = ConnectionRegistry()
    let controller: ProductionTunnelController
    let backend: EngineServiceBackend<StrictSuspendingClock>

    private init() {
        let secrets = TunnelSecretStore.make()
        let validator = ExtensionPayloadValidator()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        controller = ProductionTunnelController(
            host: ProcessProviderHost.shared, secrets: secrets, stateStore: PlistTunnelStateStore(url: PlistTunnelStateStore.defaultURL),
            adapters: EngineAdapterFactory(guiVersion: "LockPlus \(version)"), validator: validator,
            clock: StrictSuspendingClock(),
            pathSource: NWPathSource(), endpointCheck: RouteProbeEndpointCheck(),
            sink: RegistryEventSink(registry: registry))
        backend = EngineServiceBackend(controller: controller, secrets: secrets, validator: validator)
    }
}
