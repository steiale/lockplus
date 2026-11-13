import Foundation
import LPEngineCheck
import LPModel
import LPParsing
import LPWire
import os
import Synchronization

/// Limits of the exported object (PLAN-2.0.2 §1.2).
public struct ValidatorLimits: Sendable {
    /// Requests accepted and not yet answered (the running one included); the rest is answered `.extensionBusy`.
    public var maxInFlight = 4
    /// Tests: one watchdog for every method. nil: each method's own (`LPValidatorMethod.watchdog`).
    public var watchdogOverride: Duration?
    public init(maxInFlight: Int = 4, watchdog: Duration? = nil) {
        self.maxInFlight = maxInFlight; self.watchdogOverride = watchdog
    }
    /// A request still running after this long is answered `.timeout` and the service exits (launchd relaunches it on
    /// the next message).
    public func watchdog(for m: LPValidatorMethod) -> Duration { watchdogOverride ?? m.watchdog ?? .seconds(10) }
}

/// The validator service's exported object (PLAN-2.0.2 §1.2). The service is sandboxed and network-less; every
/// request is bytes in, fixed-shape data out.
///
/// - One request runs at a time (`SerialWorker`); at most `limits.maxInFlight` are accepted.
/// - Caps are checked before decoding (`LPWire.decode(_:max:)`), post-decode range checks run through
///   `LPWireValidating`; every reply is sent exactly once (`ReplyOnce`).
/// - Watchdog: a running request older than its method's watchdog is answered `.timeout` (detail "watchdog"; round 1,
///   Fable M1: a slow file is not a crash, the client must not record it as one), then `onWatchdog` runs (default: exit
///   after a short delay that lets the reply leave).
/// - Never logs payload bytes, names or categories beyond `.private`.
///
/// SAFETY: `@unchecked Sendable` — immutable after init except `Mutex`-guarded state. NSXPC delivers on its own queue:
/// nonisolated, never @MainActor (a main-actor @objc witness traps, SE-0423).
public final class ValidatorServiceHandler: NSObject, LPValidatorXPC, @unchecked Sendable {
    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac.validator", category: "service")

    private let build: String
    private let limits: ValidatorLimits
    private let onWatchdog: @Sendable () -> Void
    private let worker = SerialWorker(name: "lockplus.validator.work")
    private let inFlight = Mutex(0)
    /// The job that is running now (0 = none); the watchdog fires only for the job it was armed for.
    private let running = RunningJob()
    private let nextJob = Mutex<UInt64>(0)
    /// Tests only (package access: not part of the service's interface): runs on the worker thread inside the watchdog
    /// window, before the request's own work.
    private let beforeWork = Mutex<(@Sendable () -> Void)?>(nil)
    package func setTestHookBeforeWork(_ f: (@Sendable () -> Void)?) { beforeWork.withLock { $0 = f } }

    /// The default watchdog action: the `.timeout` reply was just handed to XPC; give it a moment to leave, then exit.
    public static let exitAfterReply: @Sendable () -> Void = {
        usleep(250_000)
        exit(0)
    }

    public init(build: String, limits: ValidatorLimits = .init(), onWatchdog: @escaping @Sendable () -> Void = ValidatorServiceHandler.exitAfterReply) {
        self.build = build
        self.limits = limits
        self.onWatchdog = onWatchdog
        super.init()
    }

    deinit { worker.stop() }

    // MARK: hello

    public func hello(_ req: Data, reply: @escaping LPReply2) {
        let reply = ReplyOnce(reply)
        let h: ValidatorHello
        do { h = try LPWire.decode(ValidatorHello.self, req, max: LPValidatorMethod.hello.requestLimit) } catch {
            reply.fail(error); return
        }
        guard h.wire == LPValidatorWireVersion else {
            reply.fail(LPError(.versionMismatch, detail: "validator wire \(h.wire)")); return
        }
        reply.succeed(ValidatorHello(build: build))
    }

    // MARK: evaluateProfile

    public func evaluateProfile(_ req: Data, reply: @escaping LPReply2) {
        let reply = ReplyOnce(reply)
        let method = LPValidatorMethod.evaluateProfile
        guard let r = decode(ValidateProfileRequest.self, req, method, reply) else { return }
        enqueue(reply, method) {
            let payload = SecretBytes(copying: r.payload)
            switch r.kind {
            case .wireGuard: return WireGuardEngineCheck.evaluate(payload: payload)
            case .openVPN: return OpenVPNEngineCheck.evaluate(payload: payload, disableClientCert: r.disableClientCert)
            }
        }
    }

    // MARK: readArchive

    public func readArchive(_ req: Data, reply: @escaping LPReply2) {
        let reply = ReplyOnce(reply)
        guard let r = decode(ReadArchiveRequest.self, req, .readArchive, reply) else { return }
        enqueue(reply, .readArchive) { ArchiveReplyBuilder.reply(for: r.archive) }
    }

    // MARK: plumbing

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ method: LPValidatorMethod, _ reply: ReplyOnce) -> T? {
        do { return try LPWire.decode(type, data, max: method.requestLimit) } catch {
            reply.fail(error)
            return nil
        }
    }

    /// Admits the job (or answers busy) and runs it on the worker thread under the watchdog.
    private func enqueue<R: Encodable & Sendable>(_ reply: ReplyOnce, _ method: LPValidatorMethod, _ work: @escaping @Sendable () -> R) {
        let admitted = inFlight.withLock { n -> Bool in
            guard n < limits.maxInFlight else { return false }
            n += 1
            return true
        }
        guard admitted else { reply.fail(LPError(.extensionBusy, detail: "validator busy")); return }
        let id = nextJob.withLock { $0 &+= 1; return $0 }
        let watchdog = limits.watchdog(for: method)
        let onWatchdog = self.onWatchdog
        worker.submit { [self] in
            running.set(id)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "lockplus.validator.watchdog"))
            timer.schedule(deadline: .now() + watchdog.timeInterval, leeway: .milliseconds(10))
            timer.setEventHandler { @Sendable [running] in
                if running.current == id {
                    Self.log.fault("watchdog: request still running after \(watchdog.timeInterval, privacy: .public) s; exiting")
                    reply.fail(LPError(.timeout, detail: "watchdog"))
                    onWatchdog()
                }
            }
            timer.resume()
            beforeWork.withLock { $0 }?()
            let result = work()
            timer.cancel()
            running.set(0)
            inFlight.withLock { $0 -= 1 }
            reply.succeed(result)
        }
    }
}

/// The id of the job the worker is running (0 = none), shared with the watchdog timers.
final class RunningJob: Sendable {
    private let id = Mutex<UInt64>(0)
    var current: UInt64 { id.withLock { $0 } }
    func set(_ v: UInt64) { id.withLock { $0 = v } }
}

extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}

/// Sends the reply exactly once, whichever path gets there first.
// SAFETY: `@unchecked Sendable` — `sent` is a `Mutex`; `block` is a `@Sendable` closure.
final class ReplyOnce: @unchecked Sendable {
    private let block: LPReply2
    private let sent = Mutex(false)
    init(_ block: @escaping LPReply2) { self.block = block }

    private func claim() -> Bool { sent.withLock { s in if s { return false }; s = true; return true } }

    func fail(_ e: LPError) {
        guard claim() else { return }
        block(nil, LPWire.encodeError(e))
    }

    func succeed<T: Encodable>(_ value: T) {
        guard claim() else { return }
        do { block(try LPWire.encode(value), nil) } catch { block(nil, LPWire.encodeError(error)) }
    }
}

/// The exported object's listener delegate (PLAN-2.0.2 §1.2). It also applies the peer requirement (APP_REQ, injected),
/// per connection, before `activate()`.
///
/// 200026 E2E (release blocker): the service listener (`NSXPCListener.service()`) has no listener connection of its
/// own, so `setConnectionCodeSigningRequirement` on it crashed the service at every launch (SIGSEGV in
/// `xpc_connection_set_peer_code_signing_requirement(NULL)`). The SDK header: that API "will only work on
/// `anonymousListener` or `initWithMachServiceName` listener instances". `-[NSXPCConnection setCodeSigningRequirement:]`
/// on each accepted connection is the API for a service: a peer whose messages don't satisfy it is invalidated before
/// any message reaches the exported object. Set exactly once (a second call is an XPC error), before `activate()`.
public final class ValidatorListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let handler: ValidatorServiceHandler
    private let peerRequirement: String

    /// - Parameter peerRequirement: APP_REQ from the validator target's ActiveRequirements.swift. No default, by design.
    public init(handler: ValidatorServiceHandler, peerRequirement: String) {
        self.handler = handler
        self.peerRequirement = peerRequirement
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.setCodeSigningRequirement(peerRequirement)     // once, before activate (a malformed one raises: RequirementTests)
        c.exportedInterface = .lpValidator
        c.exportedObject = handler
        c.activate()
        return true
    }
}
