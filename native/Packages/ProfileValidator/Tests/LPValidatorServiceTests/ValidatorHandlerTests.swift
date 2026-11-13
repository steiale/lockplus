import Foundation
import LPEngineCheck
import LPModel
import LPWire
import Security
import Synchronization
import Testing
@testable import LPValidatorService

/// Collects replies and counts how often a reply block ran.
final class Replies: Sendable {
    private let state = Mutex<[(Data?, Data?)]>([])
    var count: Int { state.withLock { $0.count } }
    var all: [(Data?, Data?)] { state.withLock { $0 } }
    func block() -> LPReply2 { { [self] a, b in state.withLock { $0.append((a, b)) } } }

    func waitForCount(_ n: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let end = ContinuousClock.now + timeout
        while count < n {
            if ContinuousClock.now > end { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
    var firstError: LPError? { all.first.flatMap { LPWire.decodeError($0.1) } }
}

private func evalRequest(_ text: String, kind: VPNProtocolKind = .openVPN) throws -> Data {
    try LPWire.encode(ValidateProfileRequest(kind: kind, payload: Data(text.utf8), disableClientCert: true))
}

@Suite("Validator service handler (PLAN-2.0.2 §1.2)")
struct ValidatorHandlerTests {
    @Test func helloReportsBuild() throws {
        let h = ValidatorServiceHandler(build: "200026")
        let r = Replies()
        h.hello(try LPWire.encode(ValidatorHello(build: "200026")), reply: r.block())
        #expect(r.count == 1)
        let hello = try LPWire.decodeReply(ValidatorHello.self, result: r.all[0].0, error: r.all[0].1, max: 4096)
        #expect(hello.build == "200026" && hello.wire == LPValidatorWireVersion)
    }

    @Test func helloWithAnotherWireVersionIsVersionMismatch() throws {
        let h = ValidatorServiceHandler(build: "1")
        let r = Replies()
        h.hello(try LPWire.encode(ValidatorHello(wire: LPValidatorWireVersion + 1, build: "1")), reply: r.block())
        #expect(r.firstError?.code == .versionMismatch)
    }

    @Test func oversizeRequestRejectedBeforeDecode() {
        let h = ValidatorServiceHandler(build: "1")
        let r = Replies()
        // Not a plist: if it were decoded, the error would be malformedRequest.
        h.evaluateProfile(Data(count: LPValidatorMethod.evaluateProfile.requestLimit + 1), reply: r.block())
        h.hello(Data(count: LPValidatorMethod.hello.requestLimit + 1), reply: r.block())
        h.readArchive(Data(count: LPValidatorMethod.readArchive.requestLimit + 1), reply: r.block())
        #expect(r.count == 3)
        #expect(r.all.allSatisfy { LPWire.decodeError($0.1)?.code == .payloadTooLarge })
    }

    @Test func malformedRequestIsMalformed() {
        let h = ValidatorServiceHandler(build: "1")
        let r = Replies()
        h.hello(Data("nope".utf8), reply: r.block())
        h.evaluateProfile(Data("nope".utf8), reply: r.block())
        h.readArchive(Data("nope".utf8), reply: r.block())
        #expect(r.count == 3)
        #expect(r.all.allSatisfy { LPWire.decodeError($0.1)?.code == .malformedRequest })
    }

    @Test func evaluateAnswersForBothKinds() async throws {
        let h = ValidatorServiceHandler(build: "1")
        let r = Replies()
        h.evaluateProfile(try evalRequest("nonsense", kind: .wireGuard), reply: r.block())
        h.evaluateProfile(try evalRequest("client\n", kind: .openVPN), reply: r.block())
        #expect(await r.waitForCount(2))
        let a = try LPWire.decodeReply(ValidateProfileReply.self, result: r.all[0].0, error: r.all[0].1, max: 64 * 1024)
        let b = try LPWire.decodeReply(ValidateProfileReply.self, result: r.all[1].0, error: r.all[1].1, max: 64 * 1024)
        #expect(!a.isValid && !b.isValid)
    }

    @Test func fifthQueuedRequestIsBusy() async throws {
        let h = ValidatorServiceHandler(build: "1", limits: .init(maxInFlight: 4, watchdog: .seconds(60)))
        let release = DispatchSemaphore(value: 0)
        h.setTestHookBeforeWork { release.wait() }
        let r = Replies()
        for _ in 0..<5 { h.evaluateProfile(try evalRequest("client\n"), reply: r.block()) }
        // The fifth is answered at once (busy); the first four wait on the hook.
        #expect(await r.waitForCount(1))
        #expect(r.firstError?.code == .extensionBusy)
        #expect(r.count == 1)
        for _ in 0..<4 { release.signal() }
        #expect(await r.waitForCount(5))
        // Slots are free again.
        h.setTestHookBeforeWork(nil)
        h.evaluateProfile(try evalRequest("client\n"), reply: r.block())
        #expect(await r.waitForCount(6))
        #expect(r.all.last.flatMap { LPWire.decodeError($0.1) } == nil)
    }

    @Test func everyPathRepliesExactlyOnce() async throws {
        let h = ValidatorServiceHandler(build: "1", limits: .init(maxInFlight: 2, watchdog: .seconds(60)))
        let release = DispatchSemaphore(value: 0)
        h.setTestHookBeforeWork { release.wait() }
        let r = Replies()
        var expected = 0
        h.hello(Data("x".utf8), reply: r.block()); expected += 1                     // malformed
        h.hello(try LPWire.encode(ValidatorHello(build: "1")), reply: r.block()); expected += 1
        h.evaluateProfile(Data(count: 1 << 20), reply: r.block()); expected += 1     // too large
        h.readArchive(Data("x".utf8), reply: r.block()); expected += 1              // malformed
        for _ in 0..<4 { h.evaluateProfile(try evalRequest("client\n"), reply: r.block()); expected += 1 }   // 2 busy + 2 queued
        release.signal(); release.signal()
        #expect(await r.waitForCount(expected))
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.count == expected)       // nothing replied twice
    }

    @Test func eachMethodHasItsOwnWatchdog() {
        let l = ValidatorLimits()
        #expect(l.watchdog(for: .evaluateProfile) == .seconds(10) && l.watchdog(for: .readArchive) == .seconds(25))
        #expect(ValidatorLimits(watchdog: .milliseconds(5)).watchdog(for: .readArchive) == .milliseconds(5))
    }

    @Test func watchdogFiresOnAStuckRequestOnly() async throws {
        let fired = Mutex(0)
        let h = ValidatorServiceHandler(build: "1", limits: .init(maxInFlight: 4, watchdog: .milliseconds(150)),
                                        onWatchdog: { fired.withLock { $0 += 1 } })
        let release = DispatchSemaphore(value: 0)
        h.setTestHookBeforeWork { release.wait() }
        let r = Replies()
        h.evaluateProfile(try evalRequest("client\n"), reply: r.block())
        try await Task.sleep(for: .milliseconds(500))
        #expect(fired.withLock { $0 } == 1)
        // Round 1 (Fable M1): the stuck request is answered `.timeout` before the exit, so the client can tell a slow
        // file from a crash.
        #expect(r.count == 1 && r.firstError?.code == .timeout && r.firstError?.detail == "watchdog")
        release.signal()
        try await Task.sleep(for: .milliseconds(100))
        #expect(r.count == 1)                                       // the late result is not a second reply
        // A fast request after it does not fire the watchdog.
        h.setTestHookBeforeWork(nil)
        h.evaluateProfile(try evalRequest("client\n"), reply: r.block())
        #expect(await r.waitForCount(2))
        try await Task.sleep(for: .milliseconds(400))
        #expect(fired.withLock { $0 } == 1)
    }

    /// The real NSXPC path over an anonymous listener: interface, delegate (with its per-connection requirement, here
    /// this test process's own designated requirement), exported object.
    @Test func roundTripOverXPC() async throws {
        let h = ValidatorServiceHandler(build: "200026")
        let delegate = ValidatorListenerDelegate(handler: h, peerRequirement: selfRequirement)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.activate()
        defer { listener.invalidate() }
        let c = NSXPCConnection(listenerEndpoint: listener.endpoint)
        c.remoteObjectInterface = .lpValidator
        c.activate()
        defer { c.invalidate() }
        let proxy = try #require(c.remoteObjectProxyWithErrorHandler({ @Sendable _ in }) as? any LPValidatorXPC)
        let hello = try LPWire.encode(ValidatorHello(build: "200026"))
        let r = Replies()
        proxy.hello(hello, reply: r.block())
        #expect(await r.waitForCount(1))
        #expect(r.firstError == nil)
        proxy.evaluateProfile(try evalRequest("nonsense", kind: .wireGuard), reply: r.block())
        #expect(await r.waitForCount(2))
        let v = try LPWire.decodeReply(ValidateProfileReply.self, result: r.all[1].0, error: r.all[1].1, max: 64 * 1024)
        #expect(!v.isValid)
    }

    /// 200026 E2E blocker: the peer requirement is the delegate's, per connection (a service listener has none of its
    /// own). A peer that doesn't satisfy it (here: this unsigned test process against the Release APP_REQ) never reaches
    /// the exported object: no handler call, no reply, the connection ends with an error. 2.0.2 RC review (Codex fix
    /// LOW): on EVERY connection to the same delegate, so a requirement applied only to the first one is caught; the
    /// handler's work hook (run by every `evaluateProfile` that gets past decoding) never runs.
    @Test func aPeerFailingTheRequirementNeverReachesTheHandler() async throws {
        let h = ValidatorServiceHandler(build: "200026")
        let worked = Mutex(0)
        h.setTestHookBeforeWork { @Sendable in worked.withLock { $0 += 1 } }
        let delegate = ValidatorListenerDelegate(handler: h, peerRequirement: SigningRequirements.appReq(signer: SigningRequirements.releaseSigner))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.activate()
        defer { listener.invalidate() }
        for _ in 0..<3 {
            let c = NSXPCConnection(listenerEndpoint: listener.endpoint)
            c.remoteObjectInterface = .lpValidator
            c.activate()
            defer { c.invalidate() }
            let failed = Replies()
            let proxy = try #require(c.remoteObjectProxyWithErrorHandler({ @Sendable _ in failed.block()(nil, nil) }) as? any LPValidatorXPC)
            let r = Replies()
            proxy.hello(try LPWire.encode(ValidatorHello(build: "200026")), reply: r.block())
            proxy.evaluateProfile(try evalRequest("client\n"), reply: r.block())
            #expect(await failed.waitForCount(1, timeout: .seconds(5)))
            try await Task.sleep(for: .milliseconds(100))
            #expect(r.count == 0)
        }
        #expect(worked.withLock { $0 } == 0)
        // The same handler does work when called directly: the hook is live, so the zero above means "never reached".
        let direct = Replies()
        h.evaluateProfile(try evalRequest("client\n"), reply: direct.block())
        #expect(await direct.waitForCount(1))
        #expect(worked.withLock { $0 } == 1)
    }

    /// The setup the service process uses (`ValidatorProcess`): the requirement goes to every accepted connection,
    /// never to the listener (`setConnectionCodeSigningRequirement` on `NSXPCListener.service()` crashed it, 200026).
    @Test func theDelegateAppliesTheRequirementToEachConnection() async throws {
        let h = ValidatorServiceHandler(build: "200026")
        let delegate = ValidatorListenerDelegate(handler: h, peerRequirement: selfRequirement)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.activate()
        defer { listener.invalidate() }
        for _ in 0..<2 {                                      // two connections: each gets its own requirement, once
            let c = NSXPCConnection(listenerEndpoint: listener.endpoint)
            c.remoteObjectInterface = .lpValidator
            c.activate()
            let proxy = try #require(c.remoteObjectProxyWithErrorHandler({ @Sendable _ in }) as? any LPValidatorXPC)
            let r = Replies()
            proxy.hello(try LPWire.encode(ValidatorHello(build: "200026")), reply: r.block())
            #expect(await r.waitForCount(1))
            #expect(r.firstError == nil)
            c.invalidate()
        }
    }
}

/// This test process's own designated requirement (ad hoc: its cdhash), so a requirement it satisfies without any
/// LockPlus signing identity (as in TunnelEngineXPCTests).
let selfRequirement: String = {
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
