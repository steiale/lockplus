import Foundation
import LPModel
import NetworkExtension
import os
import TunnelEngine

/// NEProviderClasses → LockPlusTunnel.PacketTunnelProvider (Info.plist). No logic (DESIGN §7.1): every entry point
/// copies its inputs into Sendable values on the provider queue and hands them to the process-scope
/// TunnelController (TunnelEngineAssembly), whose state (pending prompts, latches) outlives this instance.
///
/// Rules (ref/swift-concurrency §4.2): override the completion-handler forms, spell the handler @Sendable as the
/// SDK imports it, call it exactly once (CompletionOnce), never block the provider queue, never `exit(`.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac.tunnel", category: "provider")
    /// This instance's side of the 2.0.1 start guard (TunnelEngine `ProviderSeat`, tested there): macOS runs several
    /// LockPlus configurations at once in this process (phase 0), and a start never displaces another live instance's
    /// session except by the kill-switch priority rule (DESIGN §7.2).
    private let seat = ProviderSeat(controller: TunnelEngineAssembly.shared.controller, gate: ProcessProviderHost.shared)
    /// Round 3 N1: NE updates `protocolConfiguration` when the configuration is saved (`NETunnelProvider.h`, KVO): a
    /// start waiting on this session re-checks against its new protection.
    private var protectionObservation: NSKeyValueObservation?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let done = CompletionOnce<(any Error)?>(completionHandler)
        // FaultInjection builds only (LP_FAULT_INJECTION): the leak harness may force the packetFlow data plane;
        // in Debug and Release `forcesPacketFlow` is constant false and its key string isn't compiled (§7.3).
        let forcePacketFlow = FaultInjectionSwitches.forcesPacketFlow(
            providerConfiguration: (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration, startOptions: options)
        let req = StartRequest(options: StartOptions(options), protocolConfiguration: protocolConfiguration,
                               dataPlaneOverride: forcePacketFlow ? .packetFlow : nil)
        log.notice("startTunnel manual=\(req.options.isManual, privacy: .public) kind=\(req.configuration?.kind.rawValue ?? "-", privacy: .public)")
        // Bound only when the controller accepts the start: a refused start leaves the running session's provider and
        // packet flow bound.
        let ref = ProviderRef(self)
        if protectionObservation == nil {
            let seat = seat
            protectionObservation = observe(\.protocolConfiguration, options: [.new]) { _, _ in seat.protectionChanged() }
        }
        seat.startTunnel(req, bind: { ref.bind($0) }) { error in
            done(error.map { $0 as NSError })            // CustomNSError keeps domain, code and detail (§5.5)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void) {
        log.notice("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        let ref = ProviderRef(self)
        seat.stopTunnel(reason: StopReason(reason), unbind: { ref.unbind($0) }, completion: completionHandler)
    }

    override func sleep(completionHandler: @escaping @Sendable () -> Void) {
        seat.sleep(completion: completionHandler)
    }

    override func wake() { seat.wake() }

    override func handleAppMessage(_ messageData: Data, completionHandler: (@Sendable (Data?) -> Void)?) {
        // Debug-only `ping` to triage "XPC unreachable but tunnel up" (§5.1); nothing else uses this channel, and it
        // never returns configuration (§9.2 "do not carry").
        #if DEBUG
        completionHandler?(Data("pong".utf8))
        #else
        completionHandler?(nil)
        #endif
    }

    deinit {
        seat.released()
        ProcessProviderHost.shared.release(self, token: seat.token)
    }
}

/// Binds a provider to the process host when the controller accepts its start, and unbinds it after its stop
/// completed, without the Task capturing the (non-Sendable) provider itself.
// SAFETY: @unchecked Sendable: holds the provider weakly and only passes it to ProcessProviderHost.bind/unbind, which
// work under a lock; NEProvider instances are documented thread safe [NEProvider.h:77].
private final class ProviderRef: @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?
    init(_ p: NEPacketTunnelProvider) { provider = p }
    /// False: the provider is gone (review M3: the start then fails instead of running unbound).
    func bind(_ lease: ProviderLease) -> Bool {
        guard let p = provider else { return false }
        return ProcessProviderHost.shared.bind(p, lease: lease)       // false below the instance's watermark (r3 2)
    }
    /// Re-check L2: only `lease`'s own binding, never a newer start of this instance.
    func unbind(_ lease: ProviderLease) { if let p = provider { ProcessProviderHost.shared.unbind(p, lease: lease) } }
}
