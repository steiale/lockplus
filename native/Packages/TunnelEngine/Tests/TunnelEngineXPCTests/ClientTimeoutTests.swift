import Foundation
import LPModel
import LPWire
@testable import LPXPCClient
import Testing

/// A service that answers hello and never replies to anything else (the extension wedged). Test only: it
/// deliberately breaks the reply-once rule to exercise the client's timer.
final class SilentService: NSObject, LPTunnelServiceXPC, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = .lpTunnelService
        c.exportedObject = self
        c.activate()
        return true
    }
    func hello(_ req: Data, reply: @escaping LPReply2) {
        reply(try? LPWire.encode(ServerHello(extVersion: "2.0.0", extBuild: "200000", capabilities: [])), nil)
    }
    func provisionProfile(_ req: Data, reply: @escaping LPReply1) {}
    func updateCredentials(_ req: Data, reply: @escaping LPReply1) {}
    func removeProfile(_ req: Data, reply: @escaping LPReply1) {}
    func listProvisioned(_ req: Data, reply: @escaping LPReply2) {}
    func wipeAllSecrets(_ req: Data, reply: @escaping LPReply1) {}
    func validateProfile(_ req: Data, reply: @escaping LPReply2) {}
    func tunnelSnapshot(_ req: Data, reply: @escaping LPReply2) {}
    func statistics(_ req: Data, reply: @escaping LPReply2) {}
    func pendingAuthPrompt(_ req: Data, reply: @escaping LPReply2) {}
    func prepareStartAuth(_ req: Data, reply: @escaping LPReply2) {}
    func answerAuth(_ req: Data, reply: @escaping LPReply1) {}
    func cancelAuth(_ req: Data, reply: @escaping LPReply1) {}
    func sessionSummaries(_ req: Data, reply: @escaping LPReply2) {}
    func measureLatency(_ req: Data, reply: @escaping LPReply2) {}
    func pushEndpoints(_ req: Data, reply: @escaping LPReply2) {}
}

@Suite struct ClientTimeoutTests {
    /// A timeout throws `.timeout(method)`, never invalidates the connection, and 3 consecutive timeouts raise the
    /// non-blocking busy flag (§5.4 liveness rule). Task cancellation resumes the call once with `.cancelled`.
    @Test func timeoutsKeepConnectionAndRaiseBusy() async throws {
        let service = SilentService()
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.activate()
        defer { listener.invalidate() }
        let box = EndpointBox(listener.endpoint)
        let client = TunnelServiceClient(peerRequirement: selfReq, appVersion: "2", appBuild: "1", retryPolicy: .standard,
                                         makeConnection: { NSXPCConnection(listenerEndpoint: box.endpoint) })
        _ = try await client.hello()

        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<TunnelServiceClient.busyAfterConsecutiveTimeouts {
                g.addTask {
                    await #expect(throws: LPError(.extensionBusy, detail: "statistics")) {
                        let _: TunnelSnapshot = try await client.call(.statistics, ProfileRequest(profileID: UUID()))
                    }
                }
            }
            try await g.waitForAll()
        }
        #expect(await client.currentStatus.busy)
        guard case .validated = await client.currentStatus.link else { Issue.record("timeout dropped the link"); return }
        _ = try await client.hello()            // same connection still answers

        let t = Task {
            let _: TunnelSnapshot = try await client.call(.statistics, ProfileRequest(profileID: UUID()))
        }
        try await Task.sleep(for: .milliseconds(100))
        t.cancel()
        await #expect(throws: LPError(.cancelled)) { try await t.value }
    }
}
