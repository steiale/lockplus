import Foundation
import LPModel
import LPWire
import os

/// The app's client of the validator service (`LockPlusValidator.xpc`, PLAN-2.0.2 §1.4).
///
/// - `NSXPCConnection(serviceName:)` + `setCodeSigningRequirement(peerRequirement)` once, before `activate()`; the
///   service is launched on the first message and, being an XPC service, belongs to this connection (one instance per
///   connection).
/// - `hello` first on every connection object and after every interruption (a new service process answers). A `build`
///   different from the app's is `.versionMismatch`: it happens only when the bundle is replaced under a running app.
/// - **One request at a time** (an async gate): a request that kills the service must not be confused with innocent
///   requests interrupted beside it.
/// - **Interruption (4097) during a call** = the service died on this input. Retry **once** on a fresh process; a
///   second death on the same request is `.profileCheckCrashed`. Invalidation (4099, e.g. no service in the bundle)
///   is `.extensionUnavailable`; a peer that fails the requirement (4102) is `.unauthorizedPeer`.
/// - Every call goes through a `OneShot` (reply, error handler, timer, cancellation).
/// - **Timeout** (round 1, Fable M1): the service's watchdog answers a request it couldn't finish with `.timeout` and
///   exits; the client's own timeout is longer and is the fallback when even that answer doesn't come. Either way the
///   connection is dropped (the wedged request must not eat the next one's budget) and the request is retried **once**
///   on a fresh process; a second timeout is `.timeout`, never `.profileCheckCrashed`: a slow file is "not checked",
///   not "this file crashed the check". A `hello` that times out (a cold launch of the service) is retried once the
///   same way and then is `.extensionUnavailable`.
public actor ValidatorClient {
    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "validator")

    private let makeConnection: @Sendable () -> NSXPCConnection
    private let peerRequirement: String
    private let expectedBuild: String
    private let timeout: @Sendable (LPValidatorMethod) -> Duration
    /// Round 2 (Fable N1): after the service's own `.timeout` answer it exits 250 ms later
    /// (`ValidatorServiceHandler.exitAfterReply`); the retry waits this long, so it lands on a fresh process instead of
    /// spending the request's one crash retry on the dying one.
    private let serviceExitGrace: Duration

    private var connection: NSXPCConnection?          // non-Sendable; never leaves the actor
    private var generation: UInt64 = 0
    /// Bumped by every interruption: a hello is valid only for the (generation, interruptions) it was answered in.
    private var interruptions: UInt64 = 0
    private var validated: (gen: UInt64, epoch: UInt64)?

    /// Round 3 (Codex r3 #9, Fable N7): until when an interruption is the expected exit of a service that answered
    /// `.timeout` (it exits `exitAfterReply` later). Kept across requests: the next request may meet that exit too, and it
    /// must not count as a crash of the next request's input.
    private var expectedExitUntil: ContinuousClock.Instant?

    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - serviceName: `io.github.steiale.lockplus.mac.validator`.
    ///   - peerRequirement: VALIDATOR_REQ from the app target's ActiveRequirements.swift. No default, by design.
    ///   - expectedBuild: the app's `CFBundleVersion` (same bundle → same build).
    public init(serviceName: String, peerRequirement: String, expectedBuild: String) {
        self.init(peerRequirement: peerRequirement, expectedBuild: expectedBuild, timeout: { $0.timeout },
                  makeConnection: { NSXPCConnection(serviceName: serviceName) })
    }

    /// Test seam: any connection (e.g. to an in-process anonymous listener) and shorter timeouts.
    init(peerRequirement: String, expectedBuild: String, timeout: @escaping @Sendable (LPValidatorMethod) -> Duration,
         serviceExitGrace: Duration = .milliseconds(300), makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.serviceExitGrace = serviceExitGrace
        self.peerRequirement = peerRequirement
        self.expectedBuild = expectedBuild
        self.timeout = timeout
        self.makeConnection = makeConnection
    }

    isolated deinit { connection?.invalidate() }

    // MARK: Public calls

    /// §8.1 [1]–[7] on canonical text, in the sandboxed service.
    public func evaluate(_ req: ValidateProfileRequest) async throws(LPError) -> ValidateProfileReply {
        let data = try await call(.evaluateProfile, try LPWire.encode(req))
        return try LPWire.decodeReply(ValidateProfileReply.self, result: data, error: nil, max: LPValidatorMethod.evaluateProfile.replyLimit)
    }

    /// The zip read (§3.5), in the sandboxed service. Archive-level refusals come back in `archiveError`.
    public func readArchive(_ archive: Data) async throws(LPError) -> ReadArchiveReply {
        guard archive.count <= ReadArchiveRequest.maxArchiveBytes else { throw LPError(.payloadTooLarge, detail: "archive") }
        let data = try await call(.readArchive, try LPWire.encode(ReadArchiveRequest(archive: archive)))
        return try LPWire.decodeReply(ReadArchiveReply.self, result: data, error: nil, max: LPValidatorMethod.readArchive.replyLimit)
    }

    /// Runs `hello` now (joins the gate). For tests and diagnostics (no production caller). Its timeout (5 s) includes
    /// the launch of the service process.
    public func hello() async throws(LPError) -> ValidatorHello {
        await acquire()
        defer { release() }
        let c = connectionForHello()
        return try await performHello(on: c)
    }

    // MARK: Serialisation

    private func acquire() async {
        if !gateBusy { gateBusy = true; return }
        await withCheckedContinuation { gateWaiters.append($0) }      // ownership is handed over in `release`
    }

    private func release() {
        if gateWaiters.isEmpty { gateBusy = false } else { gateWaiters.removeFirst().resume() }
    }

    // MARK: Call

    private func call(_ method: LPValidatorMethod, _ request: Data) async throws(LPError) -> Data {
        guard request.count <= method.requestLimit else { throw LPError(.payloadTooLarge, detail: method.rawValue) }
        await acquire()
        defer { release() }
        var diedOnThisRequest = false
        var timedOutOnThisRequest = false
        var helloRetried = false
        /// Round 2 (Codex r2 #9): when the service's own `.timeout` answer arrived; it exits 250 ms later.
        var serviceTimedOutAt: ContinuousClock.Instant?
        /// Round 1 (Fable M1): the connection goes, so the next try (or the next request) gets a fresh service process
        /// and its full time budget. One retry per request; then `.timeout`.
        func timedOut() throws(LPError) {
            dropConnection()
            Self.log.notice("validator timed out during \(method.rawValue, privacy: .public)")
            if timedOutOnThisRequest { throw LPError(.timeout, detail: method.rawValue) }
            timedOutOnThisRequest = true
        }
        while true {
            if Task.isCancelled { throw LPError(.cancelled) }
            let c = connectionForHello()
            let gen = generation
            if !isValidated {
                do {
                    _ = try await performHello(on: c)
                } catch where error.code == .extensionUnavailable && Self.helloRetryable(error.detail)
                                && (!helloRetried || expectedExitPending) {
                    // The service died or was slow to launch before answering: one more try. Round 3 (Codex r3 #9): an
                    // earlier request's watchdog exit landing here spends nothing.
                    if !consumeExpectedExit() { helloRetried = true }
                    continue
                }
            }
            guard isValidated, connection === c else {
                if consumeExpectedExit() { continue }          // round 3: that exit cut this hello's connection
                throw LPError(.extensionUnavailable, detail: "connection changed")
            }
            switch await send(method, request, on: c) {
            case .reply(let result, let error):
                if let e = LPWire.decodeError(error) {
                    if e.code == .timeout {                                  // the service's watchdog
                        serviceTimedOutAt = .now
                        expectedExitUntil = .now + Self.watchdogExitWindow
                        // Round 2 (N1), round 3 (Codex r3 #9): the service exits; nothing reconnects before that grace has
                        // passed (still holding the gate), on the final timeout too: the next request never meets the
                        // dying process because this one threw early.
                        dropConnection()
                        try? await Task.sleep(for: serviceExitGrace)
                        try timedOut()
                        continue
                    }
                    throw e
                }
                guard let result else { throw LPError(.malformedRequest, detail: "empty reply") }
                return result
            case .transport(let f):
                handleTransport(f, gen: gen)
                guard f == .interrupted else { throw f.lpError }
                // Round 2 (Codex r2 #9): the retry after the service's own timeout reached the process on its way out (one
                // service process per client): its expected exit is not a crash of this file; the outcome stays a timeout.
                if consumeExpectedExit() {
                    if serviceTimedOutAt != nil {
                        Self.log.notice("validator exited after its watchdog during the retry of \(method.rawValue, privacy: .public)")
                        throw LPError(.timeout, detail: method.rawValue)
                    }
                    // Round 3 (Codex r3 #9): the previous request's watchdog exit, not this input: retried, not counted.
                    Self.log.notice("validator exited after an earlier request's watchdog during \(method.rawValue, privacy: .public); retrying")
                    continue
                }
                // The service died while it held this request (or it was killed from outside).
                Self.log.notice("validator interrupted during \(method.rawValue, privacy: .public)")
                if diedOnThisRequest { throw LPError(.profileCheckCrashed, detail: method.rawValue) }
                diedOnThisRequest = true
            case .timeout:
                try timedOut()
            case .cancelled:
                throw LPError(.cancelled)
            case .noProxy:
                throw LPError(.extensionUnavailable, detail: "no proxy")
            }
        }
    }

    private var expectedExitPending: Bool { expectedExitUntil.map { ContinuousClock.now < $0 } ?? false }

    /// True (once) when an interruption now is the expected watchdog exit.
    private func consumeExpectedExit() -> Bool {
        guard expectedExitPending else { return false }
        expectedExitUntil = nil
        return true
    }

    /// Round 2 (Codex r2 #9): an interruption this soon after the service's `.timeout` answer is its watchdog exit.
    /// Round 3 (Fable N7): 1 s (the service exits 250 ms after that answer), so a real crash of a retry is misread as that
    /// exit only within this window (the profile then stays "Not yet verified", never refused).
    static let watchdogExitWindow: Duration = .seconds(1)

    static let helloInterrupted = "interrupted"
    static let helloTimedOut = "hello timed out"
    private static func helloRetryable(_ detail: String?) -> Bool { detail == helloInterrupted || detail == helloTimedOut }

    // MARK: Connection and hello

    private var isValidated: Bool {
        connection != nil && validated?.gen == generation && validated?.epoch == interruptions
    }

    /// The only place a connection object is created.
    private func connectionForHello() -> NSXPCConnection {
        if let c = connection { return c }
        let c = makeConnection()
        c.remoteObjectInterface = .lpValidator
        c.setCodeSigningRequirement(peerRequirement)      // once, before activate
        generation &+= 1
        let gen = generation
        // @Sendable: XPC calls these on its own queue; an actor-isolated closure would trap (§0 MUST).
        c.interruptionHandler = { @Sendable [weak self] in Task { await self?.didInterrupt(gen) } }
        c.invalidationHandler = { @Sendable [weak self] in Task { await self?.didInvalidate(gen) } }
        c.activate()
        connection = c
        validated = nil
        return c
    }

    private func didInterrupt(_ gen: UInt64) {
        guard gen == generation, connection != nil else { return }
        interruptions &+= 1
        validated = nil
    }

    private func didInvalidate(_ gen: UInt64) {
        guard gen == generation else { return }
        connection = nil
        validated = nil
    }

    private func dropConnection() {
        connection?.invalidate()
        connection = nil
        validated = nil
        generation &+= 1
    }

    private func performHello(on c: NSXPCConnection) async throws(LPError) -> ValidatorHello {
        let data = try LPWire.encode(ValidatorHello(build: expectedBuild))
        let gen = generation, epoch = interruptions
        switch await send(.hello, data, on: c) {
        case .reply(let result, let error):
            let h = try LPWire.decodeReply(ValidatorHello.self, result: result, error: error, max: LPValidatorMethod.hello.replyLimit)
            guard h.wire == LPValidatorWireVersion else { throw LPError(.versionMismatch, detail: "validator wire \(h.wire)") }
            guard h.build == expectedBuild else { throw LPError(.versionMismatch, detail: "validator build \(h.build)") }
            if gen == generation, epoch == interruptions, connection === c { validated = (gen, epoch) }
            return h
        case .transport(let f):
            handleTransport(f, gen: gen)
            if f == .interrupted { throw LPError(.extensionUnavailable, detail: Self.helloInterrupted) }
            throw f.lpError
        case .timeout:
            // Round 1 (Fable M1): no byte of any file was evaluated; the service is unavailable, not the file refused.
            if gen == generation { dropConnection() }
            throw LPError(.extensionUnavailable, detail: Self.helloTimedOut)
        case .cancelled:
            throw LPError(.cancelled)
        case .noProxy:
            throw LPError(.extensionUnavailable, detail: "no proxy")
        }
    }

    private func handleTransport(_ f: XPCTransportFailure, gen: UInt64) {
        guard gen == generation else { return }
        switch f {
        case .interrupted:
            didInterrupt(gen)
        case .invalid:
            dropConnection()
        case .codeSigningRequirementFailure:
            // Whatever answered is not our service, or its signature is broken. Never trust a byte of it.
            Self.log.fault("validator failed VALIDATOR_REQ (4102); connection dropped")
            dropConnection()
        case .replyInvalid, .other:
            break
        }
    }

    // MARK: Send

    private enum Outcome: Sendable {
        case reply(Data?, Data?)
        case transport(XPCTransportFailure)
        case timeout, cancelled, noProxy
    }

    /// One message on `c` with the one-shot gate. The continuation body runs synchronously in the actor's isolation, so
    /// the non-Sendable connection never escapes; only the Sendable gate goes into the handlers and the timer.
    private func send(_ method: LPValidatorMethod, _ data: Data, on c: NSXPCConnection) async -> Outcome {
        let gate = OneShot<Outcome>()
        let limit = timeout(method)
        let timer = Task { @Sendable in
            do { try await Task.sleep(for: limit) } catch { return }
            gate.resume(.timeout)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (k: CheckedContinuation<Outcome, Never>) in
                gate.attach(k, ifCancelled: .cancelled)
                guard let proxy = c.remoteObjectProxyWithErrorHandler({ @Sendable error in
                    gate.resume(.transport(XPCTransportFailure(error as NSError)))
                }) as? any LPValidatorXPC else {
                    gate.resume(.noProxy)
                    return
                }
                method.invoke(proxy, data) { @Sendable a, b in gate.resume(.reply(a, b)) }
            }
        } onCancel: {
            gate.cancel(.cancelled)
        }
    }
}
