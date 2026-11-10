import Foundation
import LPModel
import LPWire
import os

/// The app's XPC client (DESIGN §5.3, §5.4; ref/xpc-servicemanagement §4–§6).
///
/// - `.privileged` Mach lookup + `setCodeSigningRequirement(peerRequirement)` once, before `activate()`.
/// - **Hello gate:** nothing but `hello` is sent on a connection object until a `hello` reply has arrived on it
///   (the reply is the first received message, which is when XPC checks EXT_REQ). Re-run after every interruption.
/// - Every call: one fresh proxy on the hello-validated connection object only (M3), a `OneShot` gate for reply /
///   error handler / timer / cancellation. A timeout never invalidates the connection; our timer firing is
///   `.extensionBusy`, and 3 consecutive timeouts (ours or the extension's) raise `busy` (§5.4).
/// - 4097 interruption: keep the object, mark it unvalidated, retry hello for 12 s (respawn throttle).
///   4099 invalidation: drop the object; the next call builds a new one. 4102: drop, `.unauthorizedPeer`, `.fault`,
///   send nothing further and never retry until the user acts (`resetAfterUserAction()`).
public actor TunnelServiceClient {
    /// `ExtensionStore.link` (§11.2) is derived from this.
    public enum Link: Sendable, Equatable {
        case idle
        case validated(ServerHello)
        case reconnecting(since: Date)
        case unavailable(LPError)
    }

    public struct Status: Sendable, Equatable {
        public var link: Link
        /// 3 consecutive call timeouts: a non-blocking "busy" indicator, never a reinstall (L-LC-3).
        public var busy: Bool
    }

    public static let busyAfterConsecutiveTimeouts = 3
    static let eventLimit = 16 * LPWire.KiB

    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "xpc")

    private let makeConnection: @Sendable () -> NSXPCConnection
    private let peerRequirement: String
    private let clientHello: ClientHello
    private let retryPolicy: HelloRetryPolicy
    private let sink: AppCallbackSink

    private var connection: NSXPCConnection?          // non-Sendable; never leaves the actor
    private var generation: UInt64 = 0
    /// Bumped by every interruption: a hello is valid only for the (generation, interruptions) it was answered in.
    private var interruptions: UInt64 = 0
    /// The hello-validated connection state (review M3/S9). Non-hello messages go ONLY to `connection` while this
    /// matches the current (generation, interruptions).
    private var validated: (gen: UInt64, epoch: UInt64, hello: ServerHello)?
    private var helloTask: Task<Result<ServerHello, LPError>, Never>?
    private var interruptedSinceHello = false
    /// When the connection was last interrupted (the extension process exited), for the app's fresh-crash check.
    public private(set) var lastInterruption: Date?
    private var poisoned = false                      // after 4102, until the user acts
    private var consecutiveTimeouts = 0
    private var status = Status(link: .idle, busy: false)
    private let statusContinuation: AsyncStream<Status>.Continuation
    /// Tests only: runs between the hello gate and the validated-connection check of every call.
    private var afterHelloHook: (@Sendable () async -> Void)?

    /// Link and busy changes, newest first-come (bufferingNewest). One consumer: `ExtensionStore`.
    public nonisolated let statusUpdates: AsyncStream<Status>
    /// `tunnelEvent`s from the extension, `.bufferingNewest(64)` (§11.2). One consumer: `AppEnvironment`.
    public nonisolated let events: AsyncStream<TunnelEvent>

    /// - Parameters:
    ///   - machServiceName: read from the embedded extension's Info.plist (`NEMachServiceName`, §2.5).
    ///   - peerRequirement: EXT_REQ from the app target's ActiveRequirements.swift (§5.3). No default, by design.
    public init(machServiceName: String, peerRequirement: String, appVersion: String, appBuild: String) {
        self.init(peerRequirement: peerRequirement, appVersion: appVersion, appBuild: appBuild,
                  retryPolicy: .standard,
                  makeConnection: { NSXPCConnection(machServiceName: machServiceName, options: .privileged) })
    }

    /// Test seam: any connection (e.g. to an in-process anonymous listener).
    init(peerRequirement: String, appVersion: String, appBuild: String, retryPolicy: HelloRetryPolicy,
         makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.peerRequirement = peerRequirement
        self.clientHello = ClientHello(appVersion: appVersion, appBuild: appBuild)
        self.retryPolicy = retryPolicy
        self.makeConnection = makeConnection
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: Status.self, bufferingPolicy: .bufferingNewest(16))
        let (events, eventContinuation) = AsyncStream.makeStream(of: TunnelEvent.self, bufferingPolicy: .bufferingNewest(64))
        self.events = events
        self.sink = AppCallbackSink(eventContinuation, maxBytes: Self.eventLimit)
    }

    isolated deinit {
        connection?.invalidate()
        statusContinuation.finish()
        sink.finish()
    }

    // MARK: Public calls

    public var currentStatus: Status { status }

    /// Runs `hello` on the current connection object (joins one in flight). Always a round trip.
    public func hello() async throws(LPError) -> ServerHello {
        try await ensureHello(force: true).get()
    }

    /// A call with an `LPReply2` result.
    public func call<Req: Encodable & Sendable, Resp: Decodable & Sendable>(
        _ method: LPMethod, _ request: Req, as: Resp.Type = Resp.self
    ) async throws(LPError) -> Resp {
        precondition(method != .hello && !method.repliesErrorOnly, "use hello() / callVoid for \(method)")
        let (result, error) = try await perform(method, request)
        return try LPWire.decodeReply(Resp.self, result: result, error: error, max: method.replyLimit)
    }

    /// A call with an `LPReply1` (error-only) result.
    public func callVoid<Req: Encodable & Sendable>(_ method: LPMethod, _ request: Req) async throws(LPError) {
        precondition(method.repliesErrorOnly, "use call() for \(method)")
        let (_, error) = try await perform(method, request)
        if let e = LPWire.decodeError(error) { throw e }
    }

    /// The only way out of the 4102 state: an explicit user action (e.g. after reinstalling). Never automatic.
    public func resetAfterUserAction() {
        poisoned = false
        dropConnection()
        publish(.idle)
    }

    // MARK: Connection

    private var isValidated: Bool {
        connection != nil && validated?.gen == generation && validated?.epoch == interruptions
    }

    /// The only place a connection object is created. Called for `hello` only (M3).
    private func connectionForHello() -> NSXPCConnection {
        if let c = connection { return c }
        let c = makeConnection()
        c.remoteObjectInterface = .lpTunnelService
        c.exportedInterface = .lpAppCallback
        c.exportedObject = sink
        c.setCodeSigningRequirement(peerRequirement)     // once, before activate (§5.3)
        generation &+= 1
        let gen = generation
        // @Sendable: XPC calls these on its own queue; an actor-isolated closure would trap (§0 MUST, S5.2).
        c.interruptionHandler = { @Sendable [weak self] in Task { await self?.didInterrupt(gen) } }
        c.invalidationHandler = { @Sendable [weak self] in Task { await self?.didInvalidate(gen) } }
        c.activate()
        connection = c
        helloTask = nil
        validated = nil
        interruptedSinceHello = false
        return c
    }

    private func didInterrupt(_ gen: UInt64) {
        guard gen == generation, connection != nil else { return }
        Self.log.notice("XPC interrupted (gen \(gen, privacy: .public)); connection kept, unvalidated")
        interruptions &+= 1
        lastInterruption = Date()
        validated = nil
        helloTask = nil
        interruptedSinceHello = true
    }

    private func didInvalidate(_ gen: UInt64) {
        guard gen == generation else { return }
        Self.log.notice("XPC invalidated (gen \(gen, privacy: .public)); connection dropped")
        connection = nil            // already invalid; the next hello builds a new object
        validated = nil
        helloTask = nil
        interruptedSinceHello = false
    }

    private func dropConnection() {
        connection?.invalidate()
        connection = nil
        validated = nil
        helloTask = nil
        interruptedSinceHello = false
        generation &+= 1
    }

    // MARK: Hello gate

    private func ensureHello(force: Bool = false) async -> Result<ServerHello, LPError> {
        if poisoned { return .failure(LPError(.unauthorizedPeer)) }
        if !force, isValidated, let h = validated?.hello { return .success(h) }
        if let t = helloTask { return await t.value }
        let reconnecting = interruptedSinceHello
        let t = Task { await self.performHello(reconnecting: reconnecting) }   // shared by concurrent callers
        helloTask = t
        let r = await t.value
        if helloTask == t { helloTask = nil }     // validity lives in `validated`, not in the task
        return r
    }

    private func performHello(reconnecting: Bool) async -> Result<ServerHello, LPError> {
        if reconnecting { publish(.reconnecting(since: Date())) }
        let result: Result<ServerHello, LPError>
        if reconnecting {
            result = await retryPolicy.run(clock: ContinuousClock()) { await self.helloAttempt() }
        } else {
            switch await helloAttempt() {
            case .success(let h): result = .success(h)
            case .retryable(let e), .fatal(let e): result = .failure(e)
            }
        }
        switch result {
        case .success(let h): publish(.validated(h))
        case .failure(let e): publish(.unavailable(e))
        }
        return result
    }

    private func helloAttempt() async -> HelloRetryPolicy.Attempt {
        if poisoned { return .fatal(LPError(.unauthorizedPeer)) }
        let data: Data
        do { data = try LPWire.encode(clientHello) } catch { return .fatal(error) }
        let c = connectionForHello()
        let gen = generation, epoch = interruptions
        switch await send(.hello, data, on: c, timeout: LPMethod.hello.timeout) {
        case .reply(let result, let error):
            do {
                let h = try LPWire.decodeReply(ServerHello.self, result: result, error: error, max: LPMethod.hello.replyLimit)
                guard h.wire == LPWireVersion else { return .fatal(LPError(.versionMismatch, detail: "ext wire \(h.wire)")) }
                // S9: validated iff the same connection object answered with no interruption in between, even when
                // a retry loop saw (and survived) an earlier interruption.
                if gen == generation, epoch == interruptions, connection === c {
                    validated = (gen, epoch, h)
                    interruptedSinceHello = false
                }
                return .success(h)
            } catch { return .fatal(error) }
        case .transport(let f):
            handleTransport(f, gen: gen)
            switch f {
            case .interrupted: return .retryable(f.lpError)
            default: return .fatal(f.lpError)
            }
        case .timeout:
            return .retryable(LPError(.timeout, detail: LPMethod.hello.rawValue))
        case .cancelled:
            return .fatal(LPError(.cancelled))
        case .noProxy:
            return .fatal(LPError(.extensionUnavailable, detail: "no proxy"))
        }
    }

    // MARK: Calls

    func setAfterHelloHook(_ h: (@Sendable () async -> Void)?) { afterHelloHook = h }

    /// Tests only: what the invalidation handler does, synchronously.
    func simulateInvalidation() {
        connection?.invalidate()
        didInvalidate(generation)
    }

    private func perform<Req: Encodable & Sendable>(_ method: LPMethod, _ request: Req) async throws(LPError) -> (Data?, Data?) {
        let data = try LPWire.encode(request)
        // Our cap, checked before sending (the extension re-checks before decoding).
        guard data.count <= method.requestLimit else { throw LPError(.payloadTooLarge, detail: method.rawValue) }
        // M3: a non-hello message goes only to the connection object a hello reply validated, and this path never
        // creates a connection. If the validated one went away after the gate (actors are reentrant), re-run the
        // gate once; if it is gone again, fail instead of sending on an unvalidated object.
        var target: (c: NSXPCConnection, gen: UInt64)?
        for _ in 0..<2 {
            _ = try await ensureHello().get()        // nothing secret before a validated hello (§5.3)
            if let hook = afterHelloHook { await hook() }
            if poisoned { throw LPError(.unauthorizedPeer) }
            if isValidated, let c = connection { target = (c, generation); break }
        }
        guard let target else { throw LPError(.extensionUnavailable, detail: "connection changed") }
        let gen = target.gen
        switch await send(method, data, on: target.c, timeout: method.timeout) {
        case .reply(let a, let b):
            // S6: a server-side deadline is a timeout too (§5.4 busy rule); anything else is a live answer.
            if LPWire.decodeError(b)?.code == .timeout { noteTimeout() } else { noteSuccess() }
            return (a, b)
        case .transport(let f):
            handleTransport(f, gen: gen)
            throw f.lpError
        case .timeout:
            noteTimeout()
            throw LPError(.extensionBusy, detail: method.rawValue)      // §5.4: our timer → "busy", never a reinstall
        case .cancelled:
            throw LPError(.cancelled)
        case .noProxy:
            throw LPError(.extensionUnavailable, detail: "no proxy")
        }
    }

    private enum Outcome: Sendable {
        case reply(Data?, Data?)
        case transport(XPCTransportFailure)
        case timeout, cancelled, noProxy
    }

    /// One message on `c` with the one-shot gate. The continuation body runs synchronously in the actor's isolation,
    /// so the non-Sendable connection never escapes; only the Sendable gate goes into the handlers and the timer.
    /// The timer task is cancelled as soon as the call resolves.
    private func send(_ method: LPMethod, _ data: Data, on c: NSXPCConnection, timeout: Duration) async -> Outcome {
        let gate = OneShot<Outcome>()
        let timer = Task { @Sendable in                // the timer never invalidates the connection
            do { try await Task.sleep(for: timeout) } catch { return }
            gate.resume(.timeout)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (k: CheckedContinuation<Outcome, Never>) in
                gate.attach(k, ifCancelled: .cancelled)
                guard let proxy = c.remoteObjectProxyWithErrorHandler({ @Sendable error in
                    gate.resume(.transport(XPCTransportFailure(error as NSError)))
                }) as? any LPTunnelServiceXPC else {
                    gate.resume(.noProxy)
                    return
                }
                method.invoke(proxy, data) { @Sendable a, b in gate.resume(.reply(a, b)) }
            }
        } onCancel: {
            gate.cancel(.cancelled)
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
            // Whatever answered is not our extension, or our extension's signature is broken. Never retry/reinstall.
            Self.log.fault("XPC peer failed EXT_REQ (4102); connection dropped, no further messages")
            poisoned = true
            dropConnection()
            publish(.unavailable(LPError(.unauthorizedPeer)))
        case .replyInvalid, .other:
            break
        }
    }

    private func noteSuccess() {
        guard consecutiveTimeouts != 0 else { return }
        consecutiveTimeouts = 0
        publish(status.link)
    }

    private func noteTimeout() {
        consecutiveTimeouts += 1
        publish(status.link)
    }

    private func publish(_ link: Link) {
        let new = Status(link: link, busy: consecutiveTimeouts >= Self.busyAfterConsecutiveTimeouts)
        guard new != status else { return }
        status = new
        statusContinuation.yield(new)
    }
}

/// The app's exported callback object (§11.2). Nonisolated and Sendable, NEVER @MainActor: XPC calls it on a
/// non-main queue and a main-actor witness traps on the first event.
final class AppCallbackSink: NSObject, LPAppCallbackXPC, Sendable {
    private let continuation: AsyncStream<TunnelEvent>.Continuation
    private let maxBytes: Int

    init(_ continuation: AsyncStream<TunnelEvent>.Continuation, maxBytes: Int) {
        self.continuation = continuation
        self.maxBytes = maxBytes
    }

    func tunnelEvent(_ event: Data, done: @escaping @Sendable () -> Void) {
        defer { done() }                         // always acknowledge, or the extension stops sending to us
        guard let e = try? LPWire.decode(TunnelEvent.self, event, max: maxBytes) else { return }
        continuation.yield(e)
    }

    func finish() { continuation.finish() }
}
