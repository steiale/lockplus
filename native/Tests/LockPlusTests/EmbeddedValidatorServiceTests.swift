import Darwin
import Foundation
import Security
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// 200026 E2E (release blocker): the real LockPlusValidator.xpc crashed at every launch (SIGSEGV in
/// `-[NSXPCListener setConnectionCodeSigningRequirement:]` on its service listener), and no package test could see it:
/// they all run the delegate on an anonymous listener. This one starts the service embedded in the test host's bundle
/// (Debug, as built for the Unit plan) and connects to it the way the app does.
///
/// The Unit plan's host is built with CODE_SIGNING_ALLOWED=NO (ad hoc), so it doesn't satisfy APP_REQ: the service
/// refuses its messages ("forbidden due to code signing requirement") and the client sees the connection end. What
/// tells a working service from the crash is the service PROCESS: it is alive after refusing (the crashed one was gone
/// before its first message, and launchd starts it again only for the next one). A host signed with a development
/// identity (Xcode's own test run) gets a real hello reply instead, which is checked too.
///
/// 2.0.2 RC review (Fable L3): the test knows which of the two to expect. It checks the host itself against APP_REQ
/// (the requirement the service applies, compiled with the same configuration) and requires a reply if and only if the
/// host satisfies it, so a service that stopped enforcing APP_REQ fails here too.
@Suite("Embedded validator service (200026)", .serialized)
struct EmbeddedValidatorServiceTests {
    static var serviceExecutable: URL {
        Bundle.main.bundleURL.appending(path: "Contents/XPCServices/LockPlusValidator.xpc/Contents/MacOS/LockPlusValidator")
    }

    /// The pids of running processes whose executable is `path`.
    static func pids(running path: URL) -> [pid_t] {
        let want = path.resolvingSymlinksInPath().path
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = buf.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var out: [pid_t] = []
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in buf.prefix(Int(got)) where pid > 0 {
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            guard len > 0 else { continue }
            let p = String(decoding: pathBuf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if URL(fileURLWithPath: p).resolvingSymlinksInPath().path == want { out.append(pid) }
        }
        return out
    }

    /// Whether this process (the test host) satisfies `requirement`: `SecCodeCopySelf` + `SecCodeCheckValidity`.
    static func hostSatisfies(_ requirement: String) throws -> Bool {
        var code: SecCode?
        var req: SecRequirement?
        try #require(SecCodeCopySelf([], &code) == errSecSuccess)
        try #require(SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, "APP_REQ doesn't compile")
        return SecCodeCheckValidity(try #require(code), [], try #require(req)) == errSecSuccess
    }

    @Test func theEmbeddedServiceSurvivesItsFirstConnection() async throws {
        let exe = Self.serviceExecutable
        try #require(FileManager.default.isExecutableFile(atPath: exe.path), "no LockPlusValidator.xpc in the test host")
        let entitled = try Self.hostSatisfies(APP_REQ)
        // N4 (2.0.2 RC review): something in this host may have connected to the service before this test; then that
        // process is the one this connection reaches (one instance per host), and "a process of this executable" is the check.
        let before = Self.pids(running: exe).count

        let c = NSXPCConnection(serviceName: SigningRequirements.validatorIdentifier)
        c.remoteObjectInterface = .lpValidator
        let done = Mutex<String?>(nil)
        c.interruptionHandler = { @Sendable in done.withLock { $0 = $0 ?? "interrupted" } }
        c.invalidationHandler = { @Sendable in done.withLock { $0 = $0 ?? "invalidated" } }
        c.activate()
        defer { c.invalidate() }
        let reply = Mutex<ValidatorHello?>(nil)
        let proxy = try #require(c.remoteObjectProxyWithErrorHandler({ @Sendable e in
            done.withLock { $0 = $0 ?? "error \((e as NSError).code)" }
        }) as? any LPValidatorXPC)
        proxy.hello(try LPWire.encode(ValidatorHello(build: "1"))) { @Sendable d, e in
            let h = try? LPWire.decodeReply(ValidatorHello.self, result: d, error: e, max: 4096)
            reply.withLock { $0 = h }
            done.withLock { $0 = $0 ?? "reply" }
        }
        let end = ContinuousClock.now + .seconds(10)
        while done.withLock({ $0 }) == nil, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        let outcome = try #require(done.withLock { $0 }, "the service neither answered nor ended the connection")

        let hello = reply.withLock { $0 }
        // L3: a reply exactly when the host satisfies APP_REQ (development-signed); otherwise refused, never answered.
        #expect((hello != nil) == entitled, "host satisfies APP_REQ: \(entitled); outcome: \(outcome)")
        if let hello {
            #expect(hello.wire == LPValidatorWireVersion)
            #expect(hello.build == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        }
        // Alive after its first connection, and still alive a moment later (a crash at launch leaves no process).
        try await Task.sleep(for: .milliseconds(300))
        // N4: every process of this executable; with none before, the one this connection started.
        let first = Set(Self.pids(running: exe))
        #expect(!first.isEmpty, "LockPlusValidator isn't running after its first connection (\(outcome), \(before) before): it crashed at launch")
        try await Task.sleep(for: .milliseconds(700))
        let alive = first.filter { kill($0, 0) == 0 }
        #expect(!alive.isEmpty, "LockPlusValidator died within a second of its first connection (\(outcome))")
    }
}
