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
/// next). `PacketTunnelProvider` is bound when the controller accepts its start and unbinds after `stopTunnel` completes.
/// 2.0.1: macOS runs several LockPlus configurations at once, all in this process (phase 0); a start beside another
/// live instance's session is refused before `bind`, so the running session's provider and packet flow stay bound.
/// C20 (never `setTunnelNetworkSettings(nil)`) is enforced by `ProviderHost.apply`'s non-optional type.
/// Review M1: every bound instance keeps its own host until it unbinds, so a cancel goes to the session's own provider
/// (`cancel(with:owner:)`), never to whichever instance is bound by the time a teardown finishes.
/// The routing and bookkeeping live in TunnelEngine (`ProviderHostRouter`, `ProviderBindings`; tested there).
enum ProcessProviderHost {
    static let shared = ProviderHostRouter<RealProviderHost>()
}

extension ProviderHostRouter where Host == RealProviderHost {
    /// The controller accepted `lease`'s start of `provider`.
    func bind(_ provider: NEPacketTunnelProvider, lease: ProviderLease) -> Bool {
        bind(id: ObjectIdentifier(provider), lease: lease, host: RealProviderHost(provider))
    }

    /// `lease`'s stop completed: forgets that start's binding only (never a newer start of a reused instance).
    func unbind(_ provider: NEPacketTunnelProvider, lease: ProviderLease) { unbind(id: ObjectIdentifier(provider), lease: lease) }

    /// The provider is freed: every binding of it goes.
    func release(_ provider: NEPacketTunnelProvider, token: ProviderToken) { release(id: ObjectIdentifier(provider), token: token) }
}

/// Everything process-scope the engine needs, built once (lazily, on first use by the listener or a provider).
final class TunnelEngineAssembly: Sendable {
    static let shared = TunnelEngineAssembly()

    let registry = ConnectionRegistry()
    let controller: ProductionTunnelController
    let backend: EngineServiceBackend<StrictSuspendingClock>

    private init() {
        let secrets = TunnelSecretStore.make(backend: SecItemBackend())
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
