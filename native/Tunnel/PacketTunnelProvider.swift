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

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let done = CompletionOnce<(any Error)?>(completionHandler)
        // FaultInjection builds only (LP_FAULT_INJECTION): the leak harness may force the packetFlow data plane;
        // in Debug and Release `forcesPacketFlow` is constant false and its key string isn't compiled (§7.3).
        let forcePacketFlow = FaultInjectionSwitches.forcesPacketFlow(
            providerConfiguration: (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration, startOptions: options)
        let req = StartRequest(options: StartOptions(options), configuration: ProviderConfiguration(protocolConfiguration),
                               dataPlaneOverride: forcePacketFlow ? .packetFlow : nil)
        log.notice("startTunnel manual=\(req.options.isManual, privacy: .public) kind=\(req.configuration?.kind.rawValue ?? "-", privacy: .public)")
        ProcessProviderHost.shared.bind(self)
        let controller = TunnelEngineAssembly.shared.controller
        Task(name: "startTunnel") { @Sendable in
            do throws(LPTunnelError) {
                try await controller.start(req)
                done(nil)
            } catch {
                done(error as NSError)                    // CustomNSError keeps domain, code and detail (§5.5)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void) {
        log.notice("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        let controller = TunnelEngineAssembly.shared.controller
        let stopReason = StopReason(reason)
        let unbind = ProviderUnbinder(self)
        Task(name: "stopTunnel") { @Sendable in
            await controller.stop(reason: stopReason)    // the controller caps the adapter stop at 5 s
            unbind.run()
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping @Sendable () -> Void) {
        let controller = TunnelEngineAssembly.shared.controller
        Task(name: "sleep") { @Sendable in
            await controller.sleep()                     // capped at 2 s by the controller (§7.4)
            completionHandler()
        }
    }

    override func wake() {
        let controller = TunnelEngineAssembly.shared.controller
        Task(name: "wake") { @Sendable in await controller.wake() }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: (@Sendable (Data?) -> Void)?) {
        // Debug-only `ping` to triage "XPC unreachable but tunnel up" (§5.1); nothing else uses this channel, and it
        // never returns configuration (§9.2 "do not carry").
        #if DEBUG
        completionHandler?(Data("pong".utf8))
        #else
        completionHandler?(nil)
        #endif
    }

    deinit { ProcessProviderHost.shared.unbind(self) }
}

/// Unbinds a provider from the process host after its stop completed, without the Task capturing the
/// (non-Sendable) provider itself.
// SAFETY: @unchecked Sendable: holds the provider weakly and only passes it to ProcessProviderHost.unbind, which
// compares identities under a lock; NEProvider instances are documented thread safe [NEProvider.h:77].
private final class ProviderUnbinder: @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?
    init(_ p: NEPacketTunnelProvider) { provider = p }
    func run() { if let p = provider { ProcessProviderHost.shared.unbind(p) } }
}
