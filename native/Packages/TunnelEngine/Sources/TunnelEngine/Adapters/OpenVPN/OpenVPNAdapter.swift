import Foundation
import LPModel
import LPWire
import Synchronization

/// Profile facts the shim config needs (§8.4): cert+key presence and the §8.6 `legacyCrypto` flag.
/// LPParsing knows these at import; the default scans the canonical bytes without making a `String` of them.
public protocol OVPNProfileFacts: Sendable {
    func hasCertAndKey(_ payload: SecretBytes) -> Bool
    func needsNonPreferredDC(_ payload: SecretBytes) -> Bool
}

public struct CanonicalProfileFacts: OVPNProfileFacts {
    public init() {}
    public func hasCertAndKey(_ p: SecretBytes) -> Bool { Self.hasLine(p, "<cert>") && Self.hasLine(p, "<key>") }
    /// `cipher` names a 128-bit-block CBC cipher (canonical text quotes arguments: `cipher "AES-256-CBC"`).
    public func needsNonPreferredDC(_ p: SecretBytes) -> Bool {
        Self.lines(p).contains { l in
            let s = l.lowercased()
            return s.hasPrefix("cipher ") && s.contains("-cbc")
        }
    }
    static func hasLine(_ p: SecretBytes, _ tag: String) -> Bool { lines(p).contains { $0 == tag } }
    /// Only the directive lines' first 64 bytes are decoded, never inline bodies past a tag.
    static func lines(_ p: SecretBytes) -> [String] {
        p.withUnsafeBytes { b in
            var out: [String] = []
            var start = 0
            for i in 0...b.count {
                if i == b.count || b[i] == 0x0A {
                    let len = min(64, i - start)
                    if len > 0 { out.append(String(decoding: UnsafeRawBufferPointer(rebasing: b[start..<(start + len)]), as: UTF8.self)) }
                    start = i + 1
                }
            }
            return out.filter { $0.hasPrefix("cipher ") || $0.hasPrefix("<") }
        }
    }
}

/// DESIGN §7.3/§8.4/§8.5: the OpenVPN engine over `OpenVPNClientFactory`. One client per attempt, each on a dedicated
/// `Thread` (`lockplus.openvpn3.connect`, `.userInitiated`, 8 MB stack); `establish` blocks on an `EstablishTicket`
/// on that thread only; every stop path answers the ticket with -1 BEFORE `client.stop()`.
// SAFETY: mutable state is in `m`; the client of an attempt is used by its connect thread and (thread-safe calls only)
// by stop/reconnect/stats; it is released only after its thread finished.
public final class OpenVPNAdapter<C: Clock>: TunnelAdapter, @unchecked Sendable where C.Duration == Duration {
    public let kind: VPNProtocolKind = .openVPN

    static var establishTimeout: TimeInterval { 10 }
    static var wakeReconnectAfter: Duration { .seconds(5) }
    static var deadAfterMs: Int { 120_000 }

    private let factory: any OpenVPNClientFactory
    private let facts: any OVPNProfileFacts
    private let clock: C
    private let guiVersion: String
    private let log: LogRing

    enum Outcome: Sendable {
        case connected
        case challenge(SecretBytes)
        case authFailed(String)
        case needCreds
        case sessionExpired
        case failed(LPTunnelError)
        case superseded
    }

    /// One client + its thread.
    // SAFETY: mutable state is in `st`; `adapter` is weak and only read; delegate calls arrive on the connect thread.
    final class Attempt: OpenVPNClientDelegate, @unchecked Sendable {
        weak var adapter: OpenVPNAdapter?
        let afterConnected: Bool
        struct St {
            var client: (any OpenVPNClient)?
            var outcome: Outcome?
            var waiter: CheckedContinuation<Outcome, Never>?
            var connected = false
            var terminalReported = false
            var threadDone = false
            var finishWaiters: [CheckedContinuation<Void, Never>] = []
        }
        let st = Mutex(St())
        init(adapter: OpenVPNAdapter, afterConnected: Bool) { self.adapter = adapter; self.afterConnected = afterConnected }

        /// First terminal outcome or CONNECTED; later calls are no-ops.
        func resolve(_ o: Outcome) {
            let w: CheckedContinuation<Outcome, Never>? = st.withLock { s in
                guard s.outcome == nil else { return nil }
                s.outcome = o
                defer { s.waiter = nil }
                return s.waiter
            }
            w?.resume(returning: o)
        }
        func firstOutcome() async -> Outcome {
            await withCheckedContinuation { (k: CheckedContinuation<Outcome, Never>) in
                let ready: Outcome? = st.withLock { s in if let o = s.outcome { return o }; s.waiter = k; return nil }
                if let ready { k.resume(returning: ready) }
            }
        }
        /// The connect thread ended — or never started (T11: the bail path before `Thread.start`).
        func markDone() {
            let waiters = st.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.threadDone = true
                defer { s.finishWaiters = [] }
                return s.finishWaiters
            }
            for w in waiters { w.resume() }
        }
        func finished() async {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                let done = st.withLock { s -> Bool in if s.threadDone { return true }; s.finishWaiters.append(k); return false }
                if done { k.resume() }
            }
        }
        var isDone: Bool { st.withLock { $0.threadDone } }
        var client: (any OpenVPNClient)? { st.withLock { $0.client } }

        // OpenVPNClientDelegate (connect thread)
        func event(name: String, info: String, error: Bool, fatal: Bool) { adapter?.onEvent(self, name, info, fatal) }
        func log(_ line: String) { adapter?.onLog(self, line) }
        func establish(_ plan: OVPNTunPlan) -> Int32 { adapter?.onEstablish(self, plan) ?? -1 }
    }

    private struct S {
        var stopping = false
        var events: AdapterEventSink?
        var epoch: UInt64 = 0
        var pump: PacketFlowPump?
        var pumpEnd: Int32 = -1          // the pump fd THIS adapter attached (stop retires only that one)
        var ticket: EstablishTicket?
        var current: Attempt?
        var config: OVPNClientConfig?
        var declaredBypass = DeclaredBypassRoutes()
        var stored: CredentialSecrets?
        var interactiveKind: AuthKind = .userPass
        var sessionUp = false
        var lastConnectedAt: C.Instant?
        var reconnecting = false
        /// The credentials the latest attempt was given (T2/T3: after Connected they are what the server judged).
        var lastCreds = EngineCredentials()
        /// A CRV1 cookie the server sent after Connected; the next answer returns it with the base credentials (T2).
        var pendingCookie: SecretBytes?
    }
    private let m = Mutex(S())

    public init(factory: any OpenVPNClientFactory, facts: any OVPNProfileFacts = CanonicalProfileFacts(), clock: C,
                guiVersion: String = "LockPlus", log: LogRing = .shared) {
        self.factory = factory; self.facts = facts; self.clock = clock; self.guiVersion = guiVersion; self.log = log
    }

    private var stopping: Bool { m.withLock { $0.stopping } }

    // MARK: start (the §8.4 auth logic of one engine attempt lives here; the controller owns the prompt)

    public func start(_ req: AdapterStart, events: AdapterEventSink, epoch: UInt64) async throws(AdapterStartError) {
        // §9.3 (draft 9, S2 E10): openvpn3 gets IP-literal remotes only, from the start's endpoint map. Under
        // includeAllNetworks a hostname without IPs is dropped; none left → `.dnsResolutionFailed` (never a 30 s hang).
        let rw = OVPNRemoteRewriter.rewrite(req.payload, endpoints: req.endpoints, dropUnresolved: !req.providerDNS)
        if !rw.unresolved.isEmpty { log.append("ovpn: \(rw.unresolved.count) remote hostname(s) without IPs\(req.providerDNS ? "" : ", dropped")") }
        guard rw.remotes > 0 else { throw .failed(.of(.dnsResolutionFailed, "no endpoint IPs")) }
        // PF 51: under the flag openvpn3 must not resolve the proxy either; without its IP the attempt fails (held).
        if rw.proxyUnresolved != nil, !req.providerDNS {
            log.append("ovpn: http-proxy hostname without IPs")
            throw .failed(.of(.dnsResolutionFailed, "proxy host not resolved"))
        }
        let cfg = OVPNClientConfig(content: rw.content, disableClientCert: !facts.hasCertAndKey(req.payload),
                                   enableNonPreferredDCAlgorithms: facts.needsNonPreferredDC(req.payload),
                                   privateKeyPassword: req.credentials?.keyPassphrase,
                                   proxyUsername: req.credentials?.proxyUsername, proxyPassword: req.credentials?.proxyPassword,
                                   guiVersion: guiVersion)
        m.withLock { s in
            s.events = events; s.epoch = epoch; s.pump = req.pump; s.config = cfg; s.stored = req.credentials
            s.declaredBypass = DeclaredBypassRoutes.parse(req.payload)
            s.interactiveKind = req.interactiveKind
        }
        // Credentials are assembled (and a bound in-start answer consumed) only when the client is about to get them.
        var used = EngineCredentials()
        var outcome = await runAttempt(afterConnected: false) {
            let c = Self.assemble(stored: req.credentials, stash: req.stash)
            used = c
            return c
        }
        var refetched = false
        while true {
            switch outcome {
            case .connected:
                m.withLock { $0.sessionUp = true }
                return
            case .superseded:
                guard let cur = m.withLock({ $0.current }) else { throw .failed(.of(.startCancelled)) }
                outcome = await cur.firstOutcome()
            case .challenge(let cookie):
                throw .auth(crv1Challenge(cookie, reason: refetched ? .rejected : .initial, used: used))
            case .authFailed(let reason):
                if used.dynamicChallengeCookie != nil && used.response != nil && !refetched {
                    // Draft 7: an expired/used CRV1 state comes back as a plain AUTH_FAILED. Fetch a fresh challenge
                    // inside the same start: new client, base credentials, no cookie.
                    refetched = true
                    let base = EngineCredentials(username: used.username, password: used.password, fromAnswer: used.fromAnswer)
                    outcome = await runAttempt(afterConnected: false) { base }
                    continue
                }
                throw .auth(AuthChallenge(kind: m.withLock { $0.interactiveKind } == .staticChallenge ? .staticChallenge : .userPass,
                                          reason: .rejected, challengeText: Self.sanitizeReason(reason),
                                          carriedUsername: used.fromAnswer ? used.username : nil,
                                          rejectedStoredCredentials: !used.fromAnswer && req.credentials?.password != nil))
            case .needCreds:
                throw .auth(AuthChallenge(kind: m.withLock { $0.interactiveKind }, reason: .initial,
                                          carriedUsername: used.fromAnswer ? used.username : nil))
            case .sessionExpired:
                throw .auth(AuthChallenge(kind: m.withLock { $0.interactiveKind }, reason: .sessionExpired,
                                          carriedUsername: used.fromAnswer ? used.username : nil))
            case .failed(let e):
                throw .failed(e)
            }
        }
    }

    /// §8.4 credential assembly at provide_creds time: answer > carried (in-start binding) > stored; the cookie only from the binding.
    static func assemble(stored: CredentialSecrets?, stash: StashBinding?) -> EngineCredentials {
        guard let b = stash?.consume() else {
            return EngineCredentials(username: stored?.username, password: stored?.password)
        }
        let fromAnswer = b.answer?.username != nil || b.answer?.password != nil || b.carriedUsername != nil || b.carriedPassword != nil
        return EngineCredentials(username: b.answer?.username ?? b.carriedUsername ?? stored?.username,
                                 password: b.answer?.password ?? b.carriedPassword ?? stored?.password,
                                 response: b.answer?.response, dynamicChallengeCookie: b.cookie, fromAnswer: fromAnswer)
    }

    private func crv1Challenge(_ cookie: SecretBytes, reason: AuthReason, used: EngineCredentials) -> AuthChallenge {
        let dc = factory.parseDynamicChallenge(cookie)
        // The base password is carried only if it came from an answer (the store still has its own copy).
        return AuthChallenge(kind: .dynamicChallenge, reason: reason, challengeText: dc.map { Self.clampUTF8($0.challenge, 1024) },
                             echo: dc?.echo ?? false, lockedUsername: dc?.username.map { Self.clampUTF8($0, CredentialRecord.maxUsername) },
                             cookie: cookie,
                             carriedUsername: used.fromAnswer ? used.username : nil,
                             carriedPassword: used.fromAnswer ? used.password : nil)
    }

    /// Server-controlled text cut to the wire's byte cap on a character boundary (AuthPrompt limits, §5.2).
    static func clampUTF8(_ s: String, _ maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var out = ""
        for ch in s {
            if out.utf8.count + ch.utf8.count > maxBytes { break }
            out.append(ch)
        }
        return out
    }

    /// Server reason text: control characters stripped, ≤ 200 chars (§8.4 AUTH_FAILED row).
    static func sanitizeReason(_ s: String) -> String? {
        let t = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200))
        return t.isEmpty ? nil : t
    }

    /// Creates a client, provides credentials, starts its connect thread, and returns the first outcome.
    private func runAttempt(afterConnected: Bool, creds: () -> EngineCredentials) async -> Outcome {
        guard let cfg = m.withLock({ $0.config }), !stopping else { return .failed(.of(.startCancelled)) }
        let att = Attempt(adapter: self, afterConnected: afterConnected)
        let client: any OpenVPNClient
        do throws(LPTunnelError) { client = try factory.makeClient(config: cfg, delegate: att) } catch { return .failed(error) }
        let c = creds()
        m.withLock { $0.lastCreds = c }
        _ = client.provideCredentials(OVPNProvideCreds(username: c.username, password: c.password, response: c.response,
                                                       dynamicChallengeCookie: c.dynamicChallengeCookie))
        let previous: Attempt? = m.withLock { s in
            defer { s.current = att }
            return s.current
        }
        att.st.withLock { $0.client = client }
        if let previous, !previous.isDone { previous.client?.stop() }
        previous?.resolve(.superseded)
        if stopping { client.stop(); att.markDone(); return .failed(.of(.startCancelled)) }
        let t = Thread { @Sendable [weak self] in
            let status = client.connect()
            self?.connectReturned(att, status)
        }
        t.name = "lockplus.openvpn3.connect"
        t.qualityOfService = .userInitiated
        t.stackSize = 8 << 20
        t.start()
        return await att.firstOutcome()
    }

    // MARK: connect-thread callbacks

    private func emit(_ e: (UInt64) -> AdapterEvent) {
        let (ev, ep) = m.withLock { ($0.events, $0.epoch) }
        ev?.yield(e(ep))
    }

    private func isCurrent(_ a: Attempt) -> Bool { m.withLock { $0.current === a } }

    /// A terminal engine outcome: before CONNECTED it resolves the attempt; after, it becomes an `AdapterEvent`.
    private func terminal(_ a: Attempt, _ o: Outcome) {
        let wasConnected = a.st.withLock { s -> Bool in
            defer { s.terminalReported = true }
            return s.connected
        }
        guard isCurrent(a), !stopping else { a.resolve(o); return }
        if !wasConnected { a.resolve(o); return }
        let (kind, last, stored) = m.withLock { ($0.interactiveKind, $0.lastCreds, $0.stored) }
        switch o {
        case .challenge(let cookie):
            m.withLock { $0.pendingCookie = cookie }                 // T2: returned with the answer
            emit { .authRequired(crv1Challenge(cookie, reason: .reconnect, used: EngineCredentials()), epoch: $0) }
        case .authFailed(let r):
            // T3: the server rejected what this session sent; if that was the STORED password, say so (the controller
            // clears it and arms the 60 s resend guard instead of resending it into a lockout).
            emit { .authRequired(AuthChallenge(kind: kind == .staticChallenge ? .staticChallenge : .userPass, reason: .rejected,
                                               challengeText: Self.sanitizeReason(r),
                                               rejectedStoredCredentials: !last.fromAnswer && stored?.password != nil), epoch: $0) }
        case .needCreds:
            emit { .authRequired(AuthChallenge(kind: kind, reason: .reconnect), epoch: $0) }
        case .sessionExpired:
            emit { .authRequired(AuthChallenge(kind: kind, reason: .sessionExpired), epoch: $0) }
        case .failed(let e):
            emit { .fatal(e, epoch: $0) }
        case .connected, .superseded:
            break
        }
    }

    func onEvent(_ a: Attempt, _ name: String, _ info: String, _ fatal: Bool) {
        log.append("ovpn event \(name)")
        switch name {
        case "CONNECTED":
            let first = a.st.withLock { s -> Bool in defer { s.connected = true }; return !s.connected }
            let now = clock.now
            m.withLock { s in s.reconnecting = false; s.lastConnectedAt = now }
            if first {
                if a.afterConnected { a.resolve(.connected); if isCurrent(a) { emit { .reconnected(epoch: $0) } } }
                else { a.resolve(.connected) }
            } else if isCurrent(a) {
                emit { .reconnected(epoch: $0) }      // RECONNECTING → CONNECTED, PUSH_UPDATE, resume
            }
        case "RECONNECTING":
            if a.st.withLock({ $0.connected }), isCurrent(a) {
                m.withLock { $0.reconnecting = true }
                emit { .reconnecting(.engine, epoch: $0) }
            }
        case "AUTH_PENDING":
            // Out-of-band approval: wait (the controller spends the start budget before Connected).
            if isCurrent(a) {
                let kind: AuthReason = a.st.withLock { $0.connected } || a.afterConnected ? .reconnect : .initial
                emit { .authRequired(AuthChallenge(kind: .pendingApproval, reason: kind), epoch: $0) }
            }
        case "INFO":
            // Web/SSO is detected and refused, even during an AUTH_PENDING wait and without IV_SSO (draft 7).
            if ["WEB_AUTH:", "OPEN_URL:", "CR_TEXT:"].contains(where: { info.hasPrefix($0) }) {
                terminal(a, .failed(.of(.webAuthUnsupported)))
                a.client?.stop()
            }
        case "CLIENT_RESTART":
            if info.contains("rejected pushed option") {
                // The first one is fatal (openvpn3 would loop every 5 s, S13). Detail: the option NAME only.
                terminal(a, .failed(.of(.pushedOptionRejected, Self.optionName(info))))
                a.client?.stop()
            }
        case "DYNAMIC_CHALLENGE":
            // Residual (like PENDING-FOLD 34): the CRV1 cookie reaches us as openvpn3's ClientAPI::Event `info`
            // std::string → the shim's NSString → this Swift String, none of which we can zero. It is moved into
            // SecretBytes here at the first Swift boundary; the String copies die with this callback. The cookie is a
            // server-issued one-time state token, not the user's password. Noted for the §6.5 fold-in.
            terminal(a, .challenge(SecretBytes(copying: Array(info.utf8))))
        case "AUTH_FAILED": terminal(a, .authFailed(info))
        case "NEED_CREDS": terminal(a, .needCreds)
        case "SESSION_EXPIRED": terminal(a, .sessionExpired)
        default:
            guard fatal else { return }
            terminal(a, .failed(Self.fatalError(name)))
        }
    }

    static func fatalError(_ name: String) -> LPTunnelError {
        switch name {
        case "CERT_VERIFY_FAIL": .of(.serverIdentityMismatch)
        case "TUN_SETUP_FAILED", "TUN_IFACE_CREATE", "TUN_HALT": .of(.tunDeviceFailed, name)
        case "CONNECTION_TIMEOUT": .of(.connectTimeout)
        default: .of(.engineFatal, name)       // TLS_*, CLIENT_HALT, PROXY_*, INACTIVE_TIMEOUT, EPKI_*, …
        }
    }

    /// "rejected pushed option: route-gateway 10.0.0.1" → "route-gateway" (a bare directive name or nil).
    static func optionName(_ info: String) -> String? {
        guard let r = info.range(of: "rejected pushed option") else { return nil }
        let rest = info[r.upperBound...].drop { $0 == ":" || $0 == " " }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return name.isEmpty || name.count > 64 ? nil : String(name)
    }

    func onLog(_ a: Attempt, _ line: String) {
        if EngineLogLevel.current == .debug, let red = OVPNLogRedactor.redact(line) { log.append(red) }
        // Non-NCP BF-CBC fallback: openvpn3 loops RECONNECTING every 2 s without a fatal event (S13) → fatal at once.
        if line.contains("BF-CBC: not usable") || (line.contains("openssl_cipher_error") && line.contains("not usable")) {
            terminal(a, .failed(.of(.legacyCryptoUnavailable)))
            a.client?.stop()
        }
    }

    /// `tun_builder_establish()` on the connect thread: post the plan, wait (10 s) for the controller, return a fresh
    /// `dup` of NE's utun fd (openvpn3 closes exactly that dup) or a socketpair end (packetFlow), or -1.
    func onEstablish(_ a: Attempt, _ tp: OVPNTunPlan) -> Int32 {
        let plan = OVPNPlanMapper.networkPlan(tp)
        do throws(LPTunnelError) {
            try ExcludedRouteGuard.check(plan, declared: m.withLock { $0.declaredBypass })     // M4, before any settings
        } catch {
            terminal(a, .failed(error))
            a.client?.stop()
            return -1
        }
        let t = EstablishTicket()
        let ok = m.withLock { s -> Bool in
            guard !s.stopping, s.current === a else { return false }
            s.ticket = t; return true
        }
        guard ok else { return -1 }
        emit { .networkSettings(plan, t, epoch: $0) }
        let answer = t.wait(timeout: .now() + Self.establishTimeout)
        let pump = m.withLock { s -> PacketFlowPump? in if s.ticket === t { s.ticket = nil }; return s.pump }
        guard !stopping else { return -1 }
        switch answer {
        case .fd(let fd):
            let d = dup(fd)
            if d >= 0 { _ = fcntl(d, F_SETFD, FD_CLOEXEC) }
            return d >= 0 ? d : -1
        case .applied:
            guard let pump, let pair = try? SocketPair.make() else { return -1 }
            m.withLock { $0.pumpEnd = pair.pumpEnd }
            pump.attach(pair.pumpEnd)
            return pair.engineEnd
        case .failed:
            return -1
        }
    }

    private func connectReturned(_ a: Attempt, _ status: OVPNConnectStatus) {
        let (connected, reported) = a.st.withLock { ($0.connected, $0.terminalReported) }
        if !connected {
            a.resolve(stopping ? .failed(.of(.startCancelled)) : .failed(.of(status.error ? .profileInvalid : .engineFatal, status.status.isEmpty ? nil : status.status)))
        } else if !reported, !stopping, isCurrent(a) {
            emit { .fatal(.of(.engineFatal, "disconnected"), epoch: $0) }
        }
        a.markDone()
    }

    // MARK: lifecycle

    public func stop() async {
        let (ticket, cur, pump, pumpEnd) = m.withLock { s -> (EstablishTicket?, Attempt?, PacketFlowPump?, Int32) in
            s.stopping = true
            defer { s.ticket = nil; s.events = nil; s.pumpEnd = -1 }
            return (s.ticket, s.current, s.pump, s.pumpEnd)
        }
        ticket?.answer(.failed(.startCancelled))          // BEFORE client.stop() (§7.3)
        cur?.resolve(.failed(.of(.startCancelled)))
        if let cur {
            cur.client?.stop()
            await cur.finished()                           // the client object is released after its thread ended
            cur.st.withLock { $0.client = nil }
        }
        if pumpEnd >= 0 { pump?.detach(pumpEnd) }
    }

    public func reconnect(reason: ReconnectReason) async {
        guard let c = m.withLock({ $0.current })?.client, !stopping else { return }
        c.reconnect(seconds: 0)                            // a new transport socket on the new interface (§7.4)
    }

    public func sleep() async {
        m.withLock { $0.current }?.client?.pause(reason: "sleep")
    }

    /// `resume()`, then `reconnect(0)` if not CONNECTED within 5 s (§7.4).
    public func wake() async {
        guard let cur = m.withLock({ $0.current }), let c = cur.client else { return }
        let before = m.withLock { $0.lastConnectedAt }
        c.resume()
        let clock = clock
        Task { [weak self] in
            do { try await clock.sleep(for: Self.wakeReconnectAfter) } catch { return }
            guard let self, !self.stopping else { return }
            let after = self.m.withLock { $0.lastConnectedAt }
            if after == before { c.reconnect(seconds: 0) }
        }
    }

    /// A new client for a prompt answer (mid-start AUTH_PENDING or after Connected), within the same session.
    public func provideAuth(_ answer: AuthAnswerSecrets) async throws(LPTunnelError) {
        guard !stopping else { throw .of(.startCancelled) }
        let (stored, up, last, cookie) = m.withLock { s in
            defer { s.pendingCookie = nil }
            return (s.stored, s.sessionUp, s.lastCreds, s.pendingCookie)
        }
        let creds: EngineCredentials
        if let cookie {
            // T2: a CRV1 answer after Connected: the response goes back with the cookie and the BASE credentials the
            // session authenticated with (the server checks both), not just the response.
            creds = EngineCredentials(username: last.username ?? stored?.username, password: last.password ?? stored?.password,
                                      response: answer.response, dynamicChallengeCookie: cookie, fromAnswer: last.fromAnswer)
        } else {
            creds = EngineCredentials(username: answer.username ?? stored?.username, password: answer.password ?? stored?.password,
                                      response: answer.response, fromAnswer: answer.username != nil || answer.password != nil)
        }
        if !up {
            // The pending start() awaits the new current attempt (`.superseded` hand-off).
            Task { _ = await self.runAttempt(afterConnected: false) { creds } }
            return
        }
        Task {
            let o = await self.runAttempt(afterConnected: true) { creds }
            guard let cur = self.m.withLock({ $0.current }) else { return }
            switch o {
            case .connected, .superseded: break
            default: self.terminalAfterConnected(cur, o)
            }
        }
    }

    /// An after-Connected attempt that never reached CONNECTED: report like a post-Connected terminal event.
    private func terminalAfterConnected(_ a: Attempt, _ o: Outcome) {
        a.st.withLock { $0.connected = true; $0.terminalReported = false }
        a.st.withLock { $0.outcome = nil }
        terminal(a, o)
    }

    public func statistics() async -> AdapterStats {
        guard let c = m.withLock({ $0.current })?.client else { return AdapterStats() }
        let t = c.transportStats()
        let info = c.connectionInfo()
        return AdapterStats(rxBytes: UInt64(max(0, t.bytesIn)), txBytes: UInt64(max(0, t.bytesOut)), lastHandshake: nil,
                            endpoint: info?.serverIP, localAddresses: [info?.vpnIPv4, info?.vpnIPv6].compactMap { $0 },
                            cipher: info?.cipher)
    }

    /// §7.5 floor: `lastPacketReceived` younger than 120 s; a finished connect thread is dead.
    public func liveness() async -> Liveness {
        guard let cur = m.withLock({ $0.current }) else { return .dead }
        if cur.isDone { return .dead }
        guard let c = cur.client else { return .dead }
        let ms = c.transportStats().lastPacketReceivedMs
        if ms > Self.deadAfterMs { return .stale(.milliseconds(ms)) }
        return .healthy
    }
}

/// §8.7: lines with auth-token / PUSH_REPLY / PUSH_UPDATE keep option names only; CRV1/SCRV1/password/private-key
/// lines are dropped.
public enum OVPNLogRedactor {
    public static func redact(_ line: String) -> String? {
        let l = line.lowercased()
        if l.contains("crv1") || l.contains("password") || l.contains("private key") { return nil }
        if l.contains("auth-token") || line.contains("PUSH_REPLY") || line.contains("PUSH_UPDATE") {
            let body = line.split(separator: ",").dropFirst()
            let names = body.compactMap { $0.split(separator: " ").first.map(String.init) }
            return "ovpn push: " + names.joined(separator: ",")
        }
        return "ovpn: " + line
    }
}
