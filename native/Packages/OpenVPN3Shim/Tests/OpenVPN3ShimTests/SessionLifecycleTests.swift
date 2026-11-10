import Foundation
import OpenVPN3Shim
import Synchronization
import Testing

/// DESIGN §15.1 shim tests (D73-3: the Stop outlives the client; run them under ASan too): create → stop → destroy,
/// destroy without connect, connect → stop → destroy; plus [6] options, [7] evaluation and CRV1 parsing.
/// Serialized: openvpn3 keeps the data-channel cipher set process-wide and every session's connect sets it, so a
/// test that reads it must not overlap another session's connect.
@Suite(.serialized) struct SessionLifecycleTests {
    // An unroutable-in-practice local remote: connect() starts its event loop and keeps retrying until stopped.
    static let profile = """
        client
        dev tun
        proto udp
        remote 127.0.0.1 9
        cipher AES-256-GCM
        <ca>
        -----BEGIN CERTIFICATE-----
        MIIBajCCARCgAwIBAgIUYUlItjXyq/oPL323+UEfBRJHLrwwCgYIKoZIzj0EAwIw
        GzEZMBcGA1UEAwwQTG9ja1BsdXMgVGVzdCBDQTAeFw0yNjEwMjYxOTM0NTJaFw0z
        NjEwMjMxOTM0NTJaMBsxGTAXBgNVBAMMEExvY2tQbHVzIFRlc3QgQ0EwWTATBgcq
        hkjOPQIBBggqhkjOPQMBBwNCAARoBBdY4LSBETF3ZgvNNdg211FfXa971sRwBcHX
        uV+z54nec1GHb3XE+zsrJwlYpWhs0AnjBCNn/MiQeVV9I7HDozIwMDAdBgNVHQ4E
        FgQUBaAoiF6fizNSQckXGQDf4aenn2EwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjO
        PQQDAgNIADBFAiA/I69WY2zd31DaPMtwK3IyTM4ArJUV3LTEzmErrYOzawIhAOqx
        Ck64Jlgvlq+x8bH9Q60GAgImzeskvCqh2UoX93af
        -----END CERTIFICATE-----
        </ca>

        """

    final class Recorder: NSObject, LPOpenVPN3SessionDelegate, @unchecked Sendable {
        // SAFETY: all state behind `m`.
        let m = Mutex<[String]>([])
        func sessionEvent(_ name: String, info: String, error: Bool, fatal: Bool) { m.withLock { $0.append(name) } }
        func sessionLog(_ line: String) {}
        func sessionEstablish(_ plan: LPOpenVPN3TunPlan) -> Int32 { -1 }
        var events: [String] { m.withLock { $0 } }
    }

    typealias ConnectStatus = (error: Bool, status: String, message: String)

    /// Starts `connect()` on its own thread (as the extension does); the stream yields its status once it returns.
    static func startConnect(_ s: LPOpenVPN3Session) -> AsyncStream<ConnectStatus> {
        let (ended, k) = AsyncStream<ConnectStatus>.makeStream()
        let t = Thread { @Sendable in
            let st = s.connect()
            k.yield((st.error, st.status, st.message))
            k.finish()
        }
        t.stackSize = 8 << 20
        t.start()
        return ended
    }

    static func ended(_ run: AsyncStream<ConnectStatus>) async -> ConnectStatus {
        for await st in run { return st }
        return (true, "no status", "")
    }

    /// Polls until the session reported an event: connect() is past connect_setup and in its event loop.
    static func waitForFirstEvent(_ rec: Recorder) async -> Bool {
        for _ in 0..<3_000 {
            if !rec.events.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    static func config(_ text: String = profile) -> LPOpenVPN3SessionConfig {
        let c = LPOpenVPN3SessionConfig()
        let b = Array(text.utf8)
        b.withUnsafeBytes { c.setSecret(.profile, bytes: $0.baseAddress!, length: $0.count) }
        c.disableClientCert = true
        c.connTimeout = 0
        return c
    }

    @Test func createStopDestroyWithoutConnect() throws {
        LPOpenVPN3Core.initializeCrypto()
        var err: NSString?
        var s: LPOpenVPN3Session? = LPOpenVPN3Session(config: Self.config(), delegate: Recorder(), error: &err)
        #expect(s != nil, "\(err ?? "")")
        s?.stop()
        s = nil
        var s2: LPOpenVPN3Session? = LPOpenVPN3Session(config: Self.config(), delegate: Recorder(), error: &err)
        #expect(s2 != nil)
        s2 = nil
    }

    @Test func evalErrorFailsCreation() {
        var err: NSString?
        let s = LPOpenVPN3Session(config: Self.config("client\nremote\n<ca>\n"), delegate: Recorder(), error: &err)
        #expect(s == nil)
        #expect((err as String?)?.hasPrefix("eval_config") == true)
    }

    /// Stop before connect is sticky (ref/openvpn3 §1 item 2): connect() returns instead of looping. Returning at all
    /// is the proof (connTimeout 0: an ignored stop retries the unreachable remote forever), so no elapsed-time bound.
    @Test func stopBeforeConnectIsHonoured() throws {
        var err: NSString?
        let rec = Recorder()
        let s = try #require(LPOpenVPN3Session(config: Self.config(), delegate: rec, error: &err))
        s.stop()
        _ = s.connect()
        #expect(!rec.events.contains("CONNECTED"))
    }

    @Test func connectStopDestroyFromAnotherThread() async throws {
        var err: NSString?
        let rec = Recorder()
        let s = try #require(LPOpenVPN3Session(config: Self.config(), delegate: rec, error: &err))
        let creds = LPOpenVPN3Credentials()
        Array("alice".utf8).withUnsafeBytes { creds.setSecret(.username, bytes: $0.baseAddress!, length: $0.count) }
        Array("pw".utf8).withUnsafeBytes { creds.setSecret(.password, bytes: $0.baseAddress!, length: $0.count) }
        #expect(s.provideCredentials(creds))
        let run = Self.startConnect(s)
        // Stop from another thread once the event loop runs (its first event), not after a wall-clock delay.
        #expect(await Self.waitForFirstEvent(rec))
        s.stop()
        let st0 = await Self.ended(run)
        #expect(!st0.error, "\(st0.status) \(st0.message)")      // the event loop ran until stop()
        #expect(s.connectionInfo() == nil)
        let st = s.transportStats()
        #expect(st.bytesIn >= 0)
    }

    /// Vendor/patches/openvpn3/0001: a profile evaluation in the extension, while a session runs, must neither race
    /// nor rewrite openvpn3's process-wide state. Before the patch the evaluations reset the data-channel ciphers to
    /// AEAD only (the live session would drop its CBC cipher from IV_CIPHERS and legal_dc_cipher on its next
    /// handshake), and the nightly TSan job reported the writes against the session's connect.
    @Test func evaluationsBesideALiveSessionLeaveItsCiphersAlone() async throws {
        var err: NSString?
        let rec = Recorder()
        let c = Self.config()
        c.enableNonPreferredDCAlgorithms = true                    // the Acme case: a non-AEAD 128-bit-block cipher
        let s = try #require(LPOpenVPN3Session(config: c, delegate: rec, error: &err))
        let run = Self.startConnect(s)
        #expect(await Self.waitForFirstEvent(rec))                 // connect_setup applied the session's settings
        #expect(LPOpenVPN3Core.dataChannelCiphers.contains("AES-256-CBC"))

        let text = Array((Self.profile + "auth-user-pass\n").utf8)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in      // evaluations on several threads at once
            let ev = text.withUnsafeBytes { LPOpenVPN3Profile.evaluateBytes($0.baseAddress!, length: $0.count, disableClientCert: true) }
            #expect(ev.optionsOk, Comment(rawValue: ev.optionsError))
        }
        #expect(LPOpenVPN3Core.dataChannelCiphers.contains("AES-256-CBC"), "\(LPOpenVPN3Core.dataChannelCiphers)")

        s.stop()
        let st = await Self.ended(run)
        #expect(!st.error, "\(st.status) \(st.message)")
    }

    /// For the nightly TSan job: evaluations overlapping several sessions' connect_setup (the attempts of a reconnect
    /// overlap the same way: a new attempt starts while the superseded one is still stopping). Before the patch TSan
    /// reported allow_dc/set_log_level against eval_config and ClientOptions here.
    @Test func evaluationsDuringConcurrentConnects() async throws {
        var err: NSString?
        var sessions: [LPOpenVPN3Session] = []
        var runs: [AsyncStream<ConnectStatus>] = []
        var recorders: [Recorder] = []
        for i in 0..<3 {
            let rec = Recorder()
            let c = Self.config()
            c.enableNonPreferredDCAlgorithms = i % 2 == 0
            let s = try #require(LPOpenVPN3Session(config: c, delegate: rec, error: &err))
            sessions.append(s); recorders.append(rec)
            runs.append(Self.startConnect(s))
        }
        let text = Array(Self.profile.utf8)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let ev = text.withUnsafeBytes { LPOpenVPN3Profile.evaluateBytes($0.baseAddress!, length: $0.count, disableClientCert: true) }
            #expect(ev.optionsOk, Comment(rawValue: ev.optionsError))
            _ = LPOpenVPN3Core.dataChannelCiphers
        }
        for rec in recorders { #expect(await Self.waitForFirstEvent(rec)) }
        for s in sessions { s.stop() }
        for run in runs { #expect(!(await Self.ended(run)).error) }
    }

    /// A session with the default settings allows AEAD ciphers only (§8.6), and an evaluation doesn't widen that.
    @Test func defaultSessionAllowsAEADOnly() async throws {
        var err: NSString?
        let rec = Recorder()
        let s = try #require(LPOpenVPN3Session(config: Self.config(), delegate: rec, error: &err))
        let run = Self.startConnect(s)
        #expect(await Self.waitForFirstEvent(rec))
        let cbc = Array((Self.profile.replacingOccurrences(of: "AES-256-GCM", with: "AES-256-CBC")).utf8)
        _ = cbc.withUnsafeBytes { LPOpenVPN3Profile.evaluateBytes($0.baseAddress!, length: $0.count, disableClientCert: true) }
        let ciphers = LPOpenVPN3Core.dataChannelCiphers
        #expect(ciphers.contains("AES-256-GCM") && !ciphers.contains { $0.hasSuffix("-CBC") }, "\(ciphers)")
        s.stop()
        _ = await Self.ended(run)
    }

    @Test func parseOptionsMatchesTheStreamShape() throws {
        let text = "client\nremote \"vpn.example\" \"1194\"\n<ca>\nAAA\nBBB\n</ca>\n"
        var err: NSString?
        let opts = Array(text.utf8).withUnsafeBytes { LPOpenVPN3Profile.parseOptionsBytes($0.baseAddress!, length: $0.count, error: &err) }
        #expect(opts == [["client"], ["remote", "vpn.example", "1194"], ["ca", "AAA\nBBB\n"]])
    }

    @Test func parseOptionsRefusesOverlongLines() {
        let text = "client\nsetenv X \"" + String(repeating: "a", count: 600) + "\"\n"
        var err: NSString?
        let opts = Array(text.utf8).withUnsafeBytes { LPOpenVPN3Profile.parseOptionsBytes($0.baseAddress!, length: $0.count, error: &err) }
        #expect(opts == nil && err != nil)
    }

    @Test func evaluationReportsAuthNeeds() {
        let text = Self.profile + "auth-user-pass\nstatic-challenge \"Enter PIN\" 1\n"
        let ev = Array(text.utf8).withUnsafeBytes { LPOpenVPN3Profile.evaluateBytes($0.baseAddress!, length: $0.count, disableClientCert: true) }
        #expect(!ev.evalError)
        #expect(!ev.autologin && ev.staticChallenge == "Enter PIN" && ev.staticChallengeEcho)
        #expect(ev.optionsOk, Comment(rawValue: ev.optionsError + " " + ev.log.joined(separator: " | ")))
    }

    @Test func dynamicChallengeParsesUsername() throws {
        let cookie = "CRV1:R,E:Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l:Y3Ex:Please enter token PIN"
        let dc = try #require(Array(cookie.utf8).withUnsafeBytes { LPOpenVPN3Profile.parseDynamicChallengeBytes($0.baseAddress!, length: $0.count) })
        #expect(dc.challenge == "Please enter token PIN" && dc.echo && dc.responseRequired && dc.username == "cq1")
    }

    @Test func nonCookieIsNotAChallenge() {
        #expect(Array("not a cookie".utf8).withUnsafeBytes { LPOpenVPN3Profile.parseDynamicChallengeBytes($0.baseAddress!, length: $0.count) } == nil)
    }
}
