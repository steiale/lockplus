import Foundation
import Security
import LPModel
import LPWire
@testable import LPXPCClient
import Synchronization
import Testing
@testable import TunnelEngine

// End-to-end over NSXPCListener.anonymous() in this process. Both ends apply real code-signing requirements; the
// "peer" is this test process (xctest / swiftpm-testing-helper, ad hoc signed), so its own designated requirement
// (a cdhash) is satisfied and our team requirement is not. That makes 4102 and listener-side rejection testable
// without any LockPlus signing identity.

let selfReq: String = {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var req: SecRequirement?
    var text: CFString?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess, let req,
          SecRequirementCopyString(req, [], &text) == errSecSuccess, let text else { return "anchor apple" }
    return text as String
}()
let foreignReq = SigningRequirements.extReq(signer: SigningRequirements.releaseSigner)

/// SAFETY (test only): the endpoint is only used to create connections, which NSXPC allows from any thread.
final class EndpointBox: @unchecked Sendable {
    let endpoint: NSXPCListenerEndpoint
    init(_ e: NSXPCListenerEndpoint) { endpoint = e }
}

final class RecordingBackend: TunnelServiceBackend {
    let calls = Mutex<[(LPMethod, uid_t)]>([])
    let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    var capabilities: Set<Capability> { [.wireGuard, .openVPN] }
    func handle(_ method: LPMethod, request: Data, peer: PeerContext) async -> Result<Data?, LPError> {
        calls.withLock { $0.append((method, peer.uid)) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if method.repliesErrorOnly { return .success(nil) }
        return Result { () throws(LPError) in try LPWire.encode(TunnelSnapshot(phase: .idle, epoch: 7)) }
    }
}

struct Harness {
    let listener: TunnelServiceListener
    let client: TunnelServiceClient
    let backend: RecordingBackend

    init(listenerReq: String = selfReq, clientReq: String = selfReq, backend: RecordingBackend = RecordingBackend(),
         retry: HelloRetryPolicy = .standard) {
        let l = TunnelServiceListener(listener: .anonymous(), peerRequirement: listenerReq, backend: backend,
                                      registry: ConnectionRegistry(), extVersion: "2.0.0", extBuild: "200000")
        l.start()
        let box = EndpointBox(l.endpoint)
        listener = l
        self.backend = backend
        client = TunnelServiceClient(peerRequirement: clientReq, appVersion: "2.0.0", appBuild: "200000",
                                     retryPolicy: retry,
                                     makeConnection: { NSXPCConnection(listenerEndpoint: box.endpoint) })
    }
}

@Suite(.serialized) struct XPCEndToEndTests {
    @Test func helloRoundTrip() async throws {
        let h = Harness()
        let hello = try await h.client.hello()
        #expect(hello.wire == LPWireVersion)
        #expect(hello.extBuild == "200000")
        #expect(hello.capabilities == [.wireGuard, .openVPN])
        guard case .validated = await h.client.currentStatus.link else { Issue.record("not validated"); return }
    }

    @Test func callForwardsWithPeerUID() async throws {
        let h = Harness()
        let s: TunnelSnapshot = try await h.client.call(.tunnelSnapshot, ProfileRequest(profileID: UUID()))
        #expect(s.epoch == 7)
        try await h.client.callVoid(.cancelAuth, ProfileRequest(profileID: UUID()))
        let calls = h.backend.calls.withLock { $0 }
        #expect(calls.map(\.0) == [.tunnelSnapshot, .cancelAuth])
        #expect(calls.allSatisfy { $0.1 == geteuid() })
    }

    /// 4102: the reply failed EXT_REQ. `.unauthorizedPeer`, connection dropped, nothing further sent, no retry.
    @Test func wrongExtensionSignatureIsUnauthorizedAndSticky() async throws {
        let h = Harness(clientReq: foreignReq)
        await #expect(throws: LPError(.unauthorizedPeer)) { try await h.client.hello() }
        await #expect(throws: LPError(.unauthorizedPeer)) {
            let _: TunnelSnapshot = try await h.client.call(.tunnelSnapshot, ProfileRequest(profileID: UUID()))
        }
        #expect(h.backend.calls.withLock { $0.isEmpty })
        #expect(await h.client.currentStatus.link == .unavailable(LPError(.unauthorizedPeer)))
    }

    /// The listener-level requirement rejects the app before the delegate runs (§5.3): no handler ever runs.
    @Test func wrongAppSignatureIsRejectedByListener() async throws {
        let h = Harness(listenerReq: SigningRequirements.appReq(signer: SigningRequirements.releaseSigner),
                        retry: HelloRetryPolicy(window: .milliseconds(300), base: .milliseconds(50), cap: .milliseconds(100)))
        do {
            _ = try await h.client.hello()
            Issue.record("hello succeeded against a rejecting listener")
        } catch {
            #expect(error.code == .extensionUnavailable || error.code == .timeout)
        }
        #expect(h.backend.calls.withLock { $0.isEmpty })
        #expect(h.listener.registry.peers.isEmpty)
    }

    /// The handler replies within its deadline (1 s below the client's), so a slow backend is a server-side timeout,
    /// and the connection stays usable.
    @Test func slowBackendTimesOutServerSideAndConnectionSurvives() async throws {
        let h = Harness(backend: RecordingBackend(delay: .seconds(3)))
        _ = try await h.client.hello()
        await #expect(throws: LPError(.timeout, detail: "tunnelSnapshot")) {
            let _: TunnelSnapshot = try await h.client.call(.tunnelSnapshot, ProfileRequest(profileID: UUID()))
        }
        _ = try await h.client.hello()
        guard case .validated = await h.client.currentStatus.link else { Issue.record("link lost"); return }
    }

    /// Oversized requests are rejected before decoding.
    @Test func oversizedRequestIsRejected() async throws {
        let h = Harness()
        let big = ProvisionRequest(profileID: UUID(), kind: .openVPN, revision: 1,
                                   payload: Data(count: 400 * 1024), credentials: nil)
        await #expect(throws: LPError(.payloadTooLarge, detail: "provisionProfile")) {
            try await h.client.callVoid(.provisionProfile, big)
        }
        #expect(h.backend.calls.withLock { $0.isEmpty })
    }

    /// uid filtering: the owner gets the full event, any other uid only the content-free one (§1.3 A2, §5.2).
    @Test func eventsAreFilteredByOwnerUID() async throws {
        let h = Harness()
        _ = try await h.client.hello()
        var it = h.client.events.makeAsyncIterator()
        let pid = UUID()
        let full = TunnelEvent(kind: .snapshotChanged, profileID: pid,
                               snapshot: TunnelSnapshot(profileID: pid, phase: .connected, endpoint: "198.51.100.7:51820"))

        try await waitForPeer(h)
        h.listener.registry.publish(full, ownerUID: geteuid())
        #expect(await it.next() == full)

        h.listener.registry.publish(full, ownerUID: geteuid() &+ 1)
        let other = await it.next()
        #expect(other == .anyTunnelStateChanged)
        #expect(other?.snapshot == nil && other?.profileID == nil)
    }

    /// One event in flight per connection; a burst coalesces and the newest always arrives.
    @Test func eventBurstCoalescesToNewest() async throws {
        let h = Harness()
        _ = try await h.client.hello()
        try await waitForPeer(h)
        var it = h.client.events.makeAsyncIterator()
        let id = UUID()
        for epoch in 1...50 {
            h.listener.registry.publish(TunnelEvent(kind: .snapshotChanged, profileID: id,
                                                    snapshot: TunnelSnapshot(epoch: UInt64(epoch))), ownerUID: geteuid())
        }
        var last: UInt64 = 0
        while last != 50, let e = await it.next() { last = e.snapshot?.epoch ?? 0 }
        #expect(last == 50)
    }

    /// T8: a snapshot burst coalesces, but authRequired and sessionEnded queued behind it are never dropped.
    @Test func burstNeverDropsPromptOrSessionEnd() async throws {
        let h = Harness()
        _ = try await h.client.hello()
        try await waitForPeer(h)
        var it = h.client.events.makeAsyncIterator()
        let id = UUID()
        for epoch in 1...20 {
            h.listener.registry.publish(TunnelEvent(kind: .snapshotChanged, profileID: id, snapshot: TunnelSnapshot(epoch: UInt64(epoch))),
                                        ownerUID: geteuid())
            if epoch == 5 { h.listener.registry.publish(TunnelEvent(kind: .authRequired, profileID: id), ownerUID: geteuid()) }
            if epoch == 10 { h.listener.registry.publish(TunnelEvent(kind: .sessionEnded, profileID: id), ownerUID: geteuid()) }
        }
        var kinds: [TunnelEvent.Kind] = [], last: UInt64 = 0
        while last != 20, let e = await it.next() { kinds.append(e.kind); if e.kind == .snapshotChanged { last = e.snapshot?.epoch ?? 0 } }
        #expect(kinds.contains(.authRequired) && kinds.contains(.sessionEnded))
        #expect(kinds.firstIndex(of: .authRequired)! < kinds.firstIndex(of: .sessionEnded)!)
    }

    /// The server-side half of the hello gate: a raw call before hello is refused.
    @Test func serverRefusesCallsBeforeHello() async throws {
        let h = Harness()
        let c = NSXPCConnection(listenerEndpoint: h.listener.endpoint)
        c.remoteObjectInterface = .lpTunnelService
        c.setCodeSigningRequirement(selfReq)
        c.activate()
        defer { c.invalidate() }
        let err: Data? = await withCheckedContinuation { k in
            let gate = OneShot<Data?>()
            gate.attach(k, ifCancelled: nil)
            let p = c.remoteObjectProxyWithErrorHandler { @Sendable _ in gate.resume(nil) } as! any LPTunnelServiceXPC
            p.tunnelSnapshot(Data()) { @Sendable _, e in gate.resume(e) }
        }
        #expect(LPWire.decodeError(err) == LPError(.malformedRequest, detail: "hello required"))
        #expect(h.backend.calls.withLock { $0.isEmpty })
    }

    /// M3: the connection is invalidated between the hello gate and a secret-bearing call. The client re-validates a
    /// new connection with hello before sending (the server-side gate would refuse anything else), never sends on an
    /// unvalidated object.
    @Test func invalidationBetweenHelloAndCallRevalidates() async throws {
        let h = Harness()
        _ = try await h.client.hello()
        let fired = Mutex(0)
        let client = h.client
        await client.setAfterHelloHook { @Sendable in
            if fired.withLock({ n in defer { n += 1 }; return n == 0 }) { await client.simulateInvalidation() }
        }
        let req = ProvisionRequest(profileID: UUID(), kind: .openVPN, revision: 1, payload: Data("client\n".utf8), credentials: nil)
        try await h.client.callVoid(.provisionProfile, req)
        #expect(h.backend.calls.withLock { $0.map(\.0) } == [.provisionProfile])
        #expect(fired.withLock { $0 } == 2)                 // the gate ran twice: the second hello validated the new object
    }

    /// M3: if the validated connection keeps disappearing after the gate, the call fails; nothing reaches the backend.
    @Test func persistentInvalidationNeverSendsUnvalidated() async throws {
        let h = Harness()
        let client = h.client
        await client.setAfterHelloHook { @Sendable in await client.simulateInvalidation() }
        let req = ProvisionRequest(profileID: UUID(), kind: .openVPN, revision: 1, payload: Data("client\n".utf8), credentials: nil)
        await #expect(throws: LPError(.extensionUnavailable, detail: "connection changed")) {
            try await h.client.callVoid(.provisionProfile, req)
        }
        #expect(h.backend.calls.withLock { $0.isEmpty })
    }

    /// L6: at most 8 handlers per connection; the 9th concurrent request is answered `.extensionBusy` at once.
    @Test func inFlightRequestsPerConnectionAreCapped() async throws {
        let h = Harness(backend: RecordingBackend(delay: .seconds(3)))
        _ = try await h.client.hello()
        let n = TunnelServiceHandler.maxInFlight + 1
        let codes = Mutex<[LPErrorCode]>([])
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<n {
                g.addTask {
                    do throws(LPError) {
                        let _: TunnelSnapshot = try await h.client.call(.tunnelSnapshot, ProfileRequest(profileID: UUID()))
                    } catch { codes.withLock { $0.append(error.code) } }
                }
            }
        }
        let c = codes.withLock { $0 }
        #expect(c.filter { $0 == .extensionBusy }.count == 1)
        #expect(c.filter { $0 == .timeout }.count == n - 1)        // server deadlines of the admitted ones
        #expect(h.backend.calls.withLock { $0.count } == n - 1)
    }

    private func waitForPeer(_ h: Harness) async throws {
        for _ in 0..<100 where h.listener.registry.peers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(h.listener.registry.peers.count == 1)
    }
}
