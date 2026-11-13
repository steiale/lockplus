import Foundation
import LPModel
import LPWire
@testable import LPXPCClient
import Security
import Synchronization
import Testing

private let selfRequirement: String = {
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

/// SAFETY (test only): the endpoint is only used to create connections, which NSXPC allows from any thread.
private final class Endpoint: @unchecked Sendable {
    let value: NSXPCListenerEndpoint
    init(_ v: NSXPCListenerEndpoint) { value = v }
}

/// A scripted validator service. `evaluate` is consulted per `evaluateProfile` call (1-based); `.die` closes the
/// server end of the connection the way a crashing service process does (the client sees an interruption/invalidation).
private final class ScriptedService: NSObject, LPValidatorXPC, NSXPCListenerDelegate, @unchecked Sendable {
    /// `watchdog`: the reply the real service's watchdog sends (`.timeout`, detail "watchdog").
    /// `watchdogThenExit`: the watchdog's reply, then the whole "process" exits `exitDelay` later (every connection it
    /// serves then, a reconnect made meanwhile included, is cut), as the real service's `exitAfterReply` does.
    enum Action: Sendable { case answer, die, silent, watchdog, watchdogThenExit }
    var exitDelay: Duration = .milliseconds(500)
    private let liveLock = NSLock()
    private var liveConnections: [NSXPCConnection] = []
    let build: String
    let evaluate: @Sendable (Int) -> Action
    /// Per `hello` call (1-based): `.answer` or `.silent` (a service slow to launch).
    let helloAction: @Sendable (Int) -> Action
    let calls = Mutex(0)
    let hellos = Mutex(0)
    let connections = Mutex(0)

    init(build: String = "200026", hello: @escaping @Sendable (Int) -> Action = { _ in .answer },
         evaluate: @escaping @Sendable (Int) -> Action = { _ in .answer }) {
        self.build = build; self.evaluate = evaluate; self.helloAction = hello
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        connections.withLock { $0 += 1 }
        liveLock.withLock { liveConnections.append(c) }
        c.exportedInterface = .lpValidator
        c.exportedObject = self
        c.activate()
        return true
    }

    func hello(_ req: Data, reply: @escaping LPReply2) {
        let n = hellos.withLock { $0 += 1; return $0 }
        guard helloAction(n) == .answer else { return }
        reply(try? LPWire.encode(ValidatorHello(build: build)), nil)
    }

    func evaluateProfile(_ req: Data, reply: @escaping LPReply2) {
        let n = calls.withLock { $0 += 1; return $0 }
        switch evaluate(n) {
        case .answer: reply(try? LPWire.encode(ValidateProfileReply(error: nil)), nil)
        case .die: NSXPCConnection.current()?.invalidate()
        case .silent: break
        case .watchdog: reply(nil, LPWire.encodeError(LPError(.timeout, detail: "watchdog")))
        case .watchdogThenExit:
            reply(nil, LPWire.encodeError(LPError(.timeout, detail: "watchdog")))
            let ms = Int(exitDelay / .milliseconds(1))
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) { @Sendable [self] in
                let all = liveLock.withLock { () -> [NSXPCConnection] in defer { liveConnections = [] }; return liveConnections }
                for c in all { c.invalidate() }
            }
        }
    }

    func readArchive(_ req: Data, reply: @escaping LPReply2) {
        reply(try? LPWire.encode(ReadArchiveReply(entries: [ArchiveEntry(name: "a.conf", bytes: Data("x".utf8))])), nil)
    }
}

/// NSXPCListener holds its delegate weakly: keep every scripted service alive for the test run.
private let keepAlive = Mutex<[ScriptedService]>([])

@Suite("ValidatorClient (PLAN-2.0.2 §1.4)")
struct ValidatorClientTests {
    private func rig(_ service: ScriptedService, build: String = "200026", timeout: Duration = .seconds(5))
        -> (ValidatorClient, NSXPCListener) {
        keepAlive.withLock { $0.append(service) }
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.activate()
        let box = Endpoint(listener.endpoint)
        let client = ValidatorClient(peerRequirement: selfRequirement, expectedBuild: build, timeout: { _ in timeout },
                                     makeConnection: { NSXPCConnection(listenerEndpoint: box.value) })
        return (client, listener)
    }

    private let req = ValidateProfileRequest(kind: .openVPN, payload: Data("client\n".utf8))

    @Test func evaluateAndReadArchiveRoundTrip() async throws {
        let (client, listener) = rig(ScriptedService())
        defer { listener.invalidate() }
        #expect(try await client.evaluate(req).isValid)
        let a = try await client.readArchive(Data("zip".utf8))
        #expect(a.entries.map(\.name) == ["a.conf"])
    }

    @Test func helloRunsOncePerConnectionObject() async throws {
        let service = ScriptedService()
        let (client, listener) = rig(service)
        defer { listener.invalidate() }
        for _ in 0..<3 { _ = try await client.evaluate(req) }
        #expect(service.hellos.withLock { $0 } == 1)
        #expect(service.connections.withLock { $0 } == 1)
    }

    @Test func buildMismatchIsVersionMismatch() async throws {
        let (client, listener) = rig(ScriptedService(build: "200025"), build: "200026")
        defer { listener.invalidate() }
        await #expect(throws: LPError.self) { _ = try await client.evaluate(req) }
        do { _ = try await client.evaluate(req); Issue.record("accepted") } catch {
            #expect(error.code == .versionMismatch)
        }
    }

    @Test func firstInterruptionRetriesOnce() async throws {
        let service = ScriptedService(evaluate: { $0 == 1 ? .die : .answer })
        let (client, listener) = rig(service)
        defer { listener.invalidate() }
        let r = try await client.evaluate(req)
        #expect(r.isValid)
        #expect(service.calls.withLock { $0 } == 2)
        // The retry used a new hello: the service saw the request twice.
        #expect(service.hellos.withLock { $0 } >= 1)
    }

    @Test func secondInterruptionOnSameRequestIsProfileCheckCrashed() async throws {
        let service = ScriptedService(evaluate: { $0 <= 2 ? .die : .answer })
        let (client, listener) = rig(service)
        defer { listener.invalidate() }
        do { _ = try await client.evaluate(req); Issue.record("accepted") } catch {
            #expect(error.code == .profileCheckCrashed)
        }
        #expect(service.calls.withLock { $0 } == 2)
        // The next, innocent request works again.
        #expect(try await client.evaluate(req).isValid)
    }

    /// Round 1 (Fable M1): a timeout drops the connection and retries once on a fresh one; the retry answers.
    @Test func aTimeoutIsRetriedOnceOnAFreshConnection() async throws {
        let service = ScriptedService(evaluate: { $0 == 1 ? .silent : .answer })
        let (client, listener) = rig(service, timeout: .milliseconds(300))
        defer { listener.invalidate() }
        #expect(try await client.evaluate(req).isValid)
        #expect(service.calls.withLock { $0 } == 2)
        #expect(service.connections.withLock { $0 } == 2)
    }

    /// A second timeout on the same request is `.timeout` (never `.profileCheckCrashed`), and the wedged request does
    /// not take the next, innocent one with it.
    @Test func aTimeoutFollowedByAnInnocentRequest() async throws {
        let service = ScriptedService(evaluate: { $0 <= 2 ? .silent : .answer })
        let (client, listener) = rig(service, timeout: .milliseconds(300))
        defer { listener.invalidate() }
        do { _ = try await client.evaluate(req); Issue.record("answered") } catch {
            #expect(error.code == .timeout)
        }
        #expect(service.calls.withLock { $0 } == 2)
        #expect(try await client.evaluate(req).isValid)
        #expect(service.connections.withLock { $0 } == 3)
    }

    /// The service's watchdog answer (`.timeout`) is a timeout too: one retry, then `.timeout`.
    @Test func theServicesWatchdogAnswerIsATimeoutNotACrash() async throws {
        let once = ScriptedService(evaluate: { $0 == 1 ? .watchdog : .answer })
        let (c1, l1) = rig(once)
        defer { l1.invalidate() }
        #expect(try await c1.evaluate(req).isValid)
        let always = ScriptedService(evaluate: { _ in .watchdog })
        let (c2, l2) = rig(always)
        defer { l2.invalidate() }
        do { _ = try await c2.evaluate(req); Issue.record("answered") } catch {
            #expect(error.code == .timeout)
        }
        #expect(always.calls.withLock { $0 } == 2)
    }

    /// Round 3 (Codex r3 #9, Fable N7): request A times out twice (the second watchdog answer), and the service exits a
    /// while later, after B already reconnected to it. That exit is A's, not a crash of B's input: B's one crash retry is
    /// still there for a real crash, and B ends valid.
    @Test func aWatchdogExitIsNeverCountedAgainstTheNextRequest() async throws {
        let service = ScriptedService(evaluate: { n in
            switch n {
            case 1: .watchdog                 // A, first try
            case 2: .watchdogThenExit         // A's retry: the final timeout; the "process" exits 500 ms later
            case 3: .silent                   // B, on the dying process: cut by that exit
            case 4: .die                      // B's retry: a real crash of B's input
            default: .answer
            }
        })
        let (client, listener) = rig(service)
        defer { listener.invalidate() }
        do { _ = try await client.evaluate(req); Issue.record("A answered") } catch {
            #expect(error.code == .timeout)
        }
        #expect(try await client.evaluate(req).isValid)
        #expect(service.calls.withLock { $0 } == 5)
    }

    /// A hello that times out (a slow first launch) is retried once, then is "unavailable": no file was evaluated, so
    /// nothing may be recorded as refused.
    @Test func aHelloTimeoutIsUnavailable() async throws {
        let slowOnce = ScriptedService(hello: { $0 == 1 ? .silent : .answer })
        let (c1, l1) = rig(slowOnce, timeout: .milliseconds(300))
        defer { l1.invalidate() }
        #expect(try await c1.evaluate(req).isValid)
        let dead = ScriptedService(hello: { _ in .silent })
        let (c2, l2) = rig(dead, timeout: .milliseconds(300))
        defer { l2.invalidate() }
        do { _ = try await c2.evaluate(req); Issue.record("answered") } catch {
            #expect(error.code == .extensionUnavailable)
        }
        #expect(dead.hellos.withLock { $0 } == 2 && dead.calls.withLock { $0 } == 0)
    }

    @Test func requestsAreSerialised() async throws {
        let service = ScriptedService()
        let (client, listener) = rig(service)
        defer { listener.invalidate() }
        try await withThrowingTaskGroup(of: Bool.self) { g in
            for _ in 0..<8 { g.addTask { try await client.evaluate(self.req).isValid } }
            for try await ok in g { #expect(ok) }
        }
        #expect(service.calls.withLock { $0 } == 8)
        #expect(service.hellos.withLock { $0 } == 1)
    }

    @Test func oversizeArchiveIsRefusedBeforeSending() async throws {
        let (client, listener) = rig(ScriptedService())
        defer { listener.invalidate() }
        do { _ = try await client.readArchive(Data(count: ReadArchiveRequest.maxArchiveBytes + 1)); Issue.record("sent") } catch {
            #expect(error.code == .payloadTooLarge)
        }
    }

    @Test func aPeerFailingTheRequirementIsUnauthorized() async throws {
        let service = ScriptedService()
        keepAlive.withLock { $0.append(service) }
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.activate()
        defer { listener.invalidate() }
        let box = Endpoint(listener.endpoint)
        let client = ValidatorClient(peerRequirement: SigningRequirements.validatorReq(signer: SigningRequirements.releaseSigner),
                                     expectedBuild: "200026", timeout: { _ in .seconds(5) },
                                     makeConnection: { NSXPCConnection(listenerEndpoint: box.value) })
        do { _ = try await client.evaluate(req); Issue.record("accepted a foreign peer") } catch {
            #expect(error.code == .unauthorizedPeer)
        }
    }
}
