import Foundation
import LPModel
import LPWire
import os
import Security
import Synchronization

/// The extension's XPC listener (DESIGN §5.1, §5.3; ref/xpc-servicemanagement §5.2). It belongs to the PROCESS, not to
/// a provider instance: `main.swift` creates it right after `startSystemExtensionMode()` and keeps it in a global.
///
/// - `setConnectionCodeSigningRequirement(peerRequirement)` (= APP_REQ, injected; §2.2) then `activate()`. That is the
///   only peer check: a failing peer is rejected on its first message, before the delegate is consulted, and leaves
///   no trace in our logs (Console: `xpc_support_check_token … -67050`).
/// - No second `setCodeSigningRequirement` on accepted connections: calling it more than once is an XPC error (C2).
///
/// SAFETY: `@unchecked Sendable` — immutable after init (`let` references to the NSXPCListener, a Sendable registry
/// and a Sendable backend). NSXPCListener calls the delegate on its own queue; nothing here is main-actor isolated.
public final class TunnelServiceListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac.tunnel", category: "xpc")

    private let listener: NSXPCListener
    private let backend: any TunnelServiceBackend
    private let extVersion: String
    private let extBuild: String
    public let registry: ConnectionRegistry

    /// - Parameters:
    ///   - machServiceName: `NEMachServiceName` from the extension's Info.plist (`Bundle.main.lpMachServiceName`).
    ///   - peerRequirement: APP_REQ from the extension target's ActiveRequirements.swift. No default, by design.
    public convenience init(machServiceName: String, peerRequirement: String, backend: any TunnelServiceBackend,
                            registry: ConnectionRegistry = ConnectionRegistry(),
                            bundle: Bundle = .main) {
        self.init(listener: NSXPCListener(machServiceName: machServiceName), peerRequirement: peerRequirement,
                  backend: backend, registry: registry,
                  extVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                  extBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
    }

    /// Test seam: any listener (e.g. `NSXPCListener.anonymous()`).
    init(listener: NSXPCListener, peerRequirement: String, backend: any TunnelServiceBackend,
         registry: ConnectionRegistry, extVersion: String, extBuild: String) {
        // A malformed requirement raises an ObjC exception inside setConnectionCodeSigningRequirement, which Swift
        // can't catch; fail here with a readable message instead. RequirementTests make this unreachable.
        precondition(Self.isValidRequirement(peerRequirement), "malformed peer requirement")
        self.listener = listener
        self.backend = backend
        self.registry = registry
        self.extVersion = extVersion
        self.extBuild = extBuild
        super.init()
        listener.setConnectionCodeSigningRequirement(peerRequirement)   // before activate
        listener.delegate = self                                         // weak: the caller keeps `self` alive
    }

    public func start() {
        listener.activate()
        Self.log.notice("listener active")
    }

    /// For tests with an anonymous listener.
    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    public static func isValidRequirement(_ text: String) -> Bool {
        var req: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess && req != nil
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Reached only by peers whose first message satisfied APP_REQ.
        let peer = PeerContext(uid: c.effectiveUserIdentifier, pid: c.processIdentifier)
        let registry = self.registry
        let id = peer.connectionID
        c.exportedInterface = .lpTunnelService
        c.exportedObject = TunnelServiceHandler(peer: peer, backend: backend,
                                                extVersion: extVersion, extBuild: extBuild)
        c.remoteObjectInterface = .lpAppCallback
        // @Sendable: XPC calls it on its own queue (§0 MUST).
        c.invalidationHandler = { @Sendable in
            registry.remove(id)
            Self.log.notice("peer gone uid=\(peer.uid, privacy: .public) pid=\(peer.pid, privacy: .public)")
        }
        registry.add(peer, ConnectionBox(c))
        c.activate()
        Self.log.notice("accept peer uid=\(peer.uid, privacy: .public) pid=\(peer.pid, privacy: .public)")
        return true
    }
}

/// Per-connection exported object. Every handler replies EXACTLY ONCE on every path, within the method's server
/// deadline (a reply block that is never called leaks memory and Mach resources; §5.4).
///
/// SAFETY: `@unchecked Sendable` — only `let` references to Sendable values plus a `Mutex`. Nonisolated by design:
/// XPC delivers on a non-main queue and a main-actor @objc witness traps (SE-0423).
final class TunnelServiceHandler: NSObject, LPTunnelServiceXPC, @unchecked Sendable {
    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac.tunnel", category: "xpc")

    let peer: PeerContext
    private let backend: any TunnelServiceBackend
    private let extVersion: String
    private let extBuild: String
    private let helloDone = Mutex(false)
    /// Requests of this connection whose reply is still owed (review L6).
    private let inFlight = Mutex(0)
    /// Per-connection cap: a peer can't pile up unbounded handler tasks; the excess is answered `.extensionBusy`.
    static let maxInFlight = 8

    init(peer: PeerContext, backend: any TunnelServiceBackend, extVersion: String, extBuild: String) {
        self.peer = peer; self.backend = backend; self.extVersion = extVersion; self.extBuild = extBuild
    }

    // MARK: hello (handled here: version check + the server-side half of the hello gate)

    func hello(_ req: Data, reply: @escaping LPReply2) {
        let h: ClientHello
        do { h = try LPWire.decode(ClientHello.self, req, max: LPMethod.hello.requestLimit) } catch {
            reply(nil, LPWire.encodeError(error)); return
        }
        guard h.wire == LPWireVersion else {
            reply(nil, LPWire.encodeError(LPError(.versionMismatch, detail: "app wire \(h.wire)"))); return
        }
        let resp = ServerHello(extVersion: extVersion, extBuild: extBuild, capabilities: backend.capabilities)
        do {
            let data = try LPWire.encode(resp)
            helloDone.withLock { $0 = true }
            Self.log.notice("hello app=\(h.appVersion, privacy: .public)(\(h.appBuild, privacy: .public)) uid=\(self.peer.uid, privacy: .public)")
            reply(data, nil)
        } catch {
            reply(nil, LPWire.encodeError(error))
        }
    }

    // MARK: everything else → backend under the deadline

    private func forward(_ method: LPMethod, _ req: Data, _ reply: @escaping LPReply2) {
        guard helloDone.withLock({ $0 }) else {
            reply(nil, LPWire.encodeError(LPError(.malformedRequest, detail: "hello required"))); return
        }
        guard req.count <= method.requestLimit else {
            reply(nil, LPWire.encodeError(LPError(.payloadTooLarge, detail: method.rawValue))); return
        }
        let admitted = inFlight.withLock { n -> Bool in
            guard n < Self.maxInFlight else { return false }
            n += 1
            return true
        }
        guard admitted else {
            reply(nil, LPWire.encodeError(LPError(.extensionBusy, detail: "too many requests"))); return
        }
        let backend = self.backend
        let peer = self.peer
        Task { [self] in
            let r = await withDeadline(method.serverDeadline,
                                       onTimeout: Result<Data?, LPError>.failure(LPError(.timeout, detail: method.rawValue))) {
                // Released when the HANDLER finishes, not at the deadline: a wedged backend keeps its slot, so the cap
                // bounds the handler tasks a connection can have running.
                defer { self.inFlight.withLock { $0 -= 1 } }
                return await backend.handle(method, request: req, peer: peer)
            }
            switch r {
            case .success(let d): reply(d, nil)
            case .failure(let e): reply(nil, LPWire.encodeError(e))
            }
        }
    }

    private func forward1(_ method: LPMethod, _ req: Data, _ reply: @escaping LPReply1) {
        forward(method, req) { _, e in reply(e) }
    }

    func provisionProfile(_ req: Data, reply: @escaping LPReply1) { forward1(.provisionProfile, req, reply) }
    func updateCredentials(_ req: Data, reply: @escaping LPReply1) { forward1(.updateCredentials, req, reply) }
    func removeProfile(_ req: Data, reply: @escaping LPReply1) { forward1(.removeProfile, req, reply) }
    func listProvisioned(_ req: Data, reply: @escaping LPReply2) { forward(.listProvisioned, req, reply) }
    func wipeAllSecrets(_ req: Data, reply: @escaping LPReply1) { forward1(.wipeAllSecrets, req, reply) }
    func validateProfile(_ req: Data, reply: @escaping LPReply2) { forward(.validateProfile, req, reply) }
    func tunnelSnapshot(_ req: Data, reply: @escaping LPReply2) { forward(.tunnelSnapshot, req, reply) }
    func statistics(_ req: Data, reply: @escaping LPReply2) { forward(.statistics, req, reply) }
    func pendingAuthPrompt(_ req: Data, reply: @escaping LPReply2) { forward(.pendingAuthPrompt, req, reply) }
    func prepareStartAuth(_ req: Data, reply: @escaping LPReply2) { forward(.prepareStartAuth, req, reply) }
    func answerAuth(_ req: Data, reply: @escaping LPReply1) { forward1(.answerAuth, req, reply) }
    func cancelAuth(_ req: Data, reply: @escaping LPReply1) { forward1(.cancelAuth, req, reply) }
    func sessionSummaries(_ req: Data, reply: @escaping LPReply2) { forward(.sessionSummaries, req, reply) }
    func measureLatency(_ req: Data, reply: @escaping LPReply2) { forward(.measureLatency, req, reply) }
    func pushEndpoints(_ req: Data, reply: @escaping LPReply2) { forward(.pushEndpoints, req, reply) }
}
