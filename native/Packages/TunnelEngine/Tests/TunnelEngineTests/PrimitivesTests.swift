import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

@Suite struct PrimitivesTests {
    @Test func completionOnceCallsExactlyOnce() {
        let count = Mutex(0)
        let once = CompletionOnce<Int> { _ in count.withLock { $0 += 1 } }
        #expect(once(1))
        #expect(!once(2))
        #expect(count.withLock { $0 } == 1)
        #expect(!once.isPending)
    }

    @Test func backoffCapsJittersAndResets() {
        var rng = SplitMix64(seed: 42)
        var b = Backoff(base: .seconds(1), cap: .seconds(60))
        var last: Duration = .zero
        for i in 0..<12 {
            let d = b.next(using: &rng)
            let nominal = min(60.0, pow(2.0, Double(i)))
            #expect(d >= .seconds(nominal * 0.8) && d <= .seconds(nominal * 1.2))
            last = d
        }
        #expect(last <= .seconds(72))
        b.reset()
        #expect(b.attempt == 0)
        let first = b.next(using: &rng)
        #expect(first >= .milliseconds(800) && first <= .milliseconds(1200))
    }

    /// T1: 200 attempts (an ~80 min kill-switch outage and far beyond) never trap and stay within the jittered cap.
    @Test func backoffSurvives200Attempts() {
        var b = Backoff()
        var rng = SplitMix64(seed: 3)
        for _ in 0..<200 {
            let d = b.next(using: &rng)
            #expect(d > .zero && d <= .seconds(72))
        }
        #expect(b.attempt == 200)
    }

    @Test func backoffIsDeterministicWithASeed() {
        var r1 = SplitMix64(seed: 7), r2 = SplitMix64(seed: 7)
        var a = Backoff(), b = Backoff()
        for _ in 0..<5 { #expect(a.next(using: &r1) == b.next(using: &r2)) }
    }

    @Test func latchBackoffDoublesFrom5sTo5min() {
        var i: TimeInterval? = nil
        var seen: [TimeInterval] = []
        for _ in 0..<9 { i = LatchBackoff.next(after: i); seen.append(i!) }
        #expect(seen == [5, 10, 20, 40, 80, 160, 300, 300, 300])
    }

    @Test func establishTicketFirstAnswerWins() async {
        let t = EstablishTicket()
        #expect(t.answer(.fd(9)))
        #expect(!t.answer(.failed(.startCancelled)))
        #expect(await t.value() == .fd(9))
        #expect(t.wait(timeout: .now()) == .fd(9))
    }

    @Test func establishTicketTimeoutAnswersFailure() {
        let t = EstablishTicket()
        #expect(t.wait(timeout: .now() + 0.01) == .failed(.tunDeviceFailed))
        #expect(!t.answer(.fd(3)))
    }

    @Test func establishTicketAsyncWaiterIsResumedByStopAnswer() async {
        let t = EstablishTicket()
        async let v = t.value()
        try? await Task.sleep(for: .milliseconds(5))
        t.answer(.failed(.startCancelled))
        #expect(await v == .failed(.startCancelled))
    }

    @Test func logRingIsBoundedAndIndexed() {
        let r = LogRing(capacity: 3)
        for i in 0..<5 { r.append("l\(i)") }
        let (lines, next) = r.lines(since: 0)
        #expect(lines == ["l2", "l3", "l4"])
        #expect(next == 5)
        #expect(r.lines(since: 4).lines == ["l4"])
    }

    @Test func manualClockFiresOnlyDueSleepers() async throws {
        let c = ManualClock()
        let fired = Mutex<[Int]>([])
        let t1 = Task { try await c.sleep(for: .seconds(1)); fired.withLock { $0.append(1) } }
        let t2 = Task { try await c.sleep(for: .seconds(5)); fired.withLock { $0.append(5) } }
        await c.waitForSleepers(2)
        c.advance(by: .seconds(2))
        try await t1.value
        #expect(fired.withLock { $0 } == [1])
        t2.cancel()
        await #expect(throws: CancellationError.self) { try await t2.value }
        #expect(c.sleeperCount == 0)
    }

    @Test func nonRetryableMatchesTheC16List() {
        for c in [LPErrorCode.authFailed, .authRequired, .profileInvalid, .profileNotProvisioned, .secretStoreUnavailable,
                  .legacyCryptoUnavailable, .serverIdentityMismatch, .pushedOptionRejected] {
            #expect(c.isNonRetryable)
        }
        for c in [LPErrorCode.connectTimeout, .peerUnreachable, .engineFatal, .engineDied, .tunDeviceFailed, .dnsResolutionFailed] {
            #expect(!c.isNonRetryable)
        }
    }

    @Test func startOptionsManualMarker() {
        let o = StartOptions(["lp.manual": NSNumber(value: 1),
                              "lp.endpoints": ["VPN.Example.com": ["192.0.2.1", "nope", "2001:db8::1"], "": ["192.0.2.9"],
                                               "x": "not a list"] as NSDictionary])
        #expect(o.isManual && o.endpoints == ["vpn.example.com": ["192.0.2.1", "2001:db8::1"]])
        #expect(!StartOptions(nil).isManual)
        // T9: the marker decides, not the presence of a dictionary; a foreign caller's endpoints are ignored
        let foreign = StartOptions(["lp.endpoints": ["h": ["192.0.2.1"]] as NSDictionary])
        #expect(!foreign.isManual && foreign.endpoints.isEmpty)
        #expect(!StartOptions(["lp.manual": NSNumber(value: 0)]).isManual)
    }

    /// Draft 9 (S2 E1): NE replays the original options on its own restart, so they carry nothing one-shot. The parser
    /// knows exactly three keys (2.0.2: the start nonce, which is what NE's replay is matched against; it is not secret
    /// from the extension and a replay with it is the point); a promptID (or anything else) in the options has no effect.
    @Test func startOptionsCarryNoOneShotValues() {
        let o = StartOptions(["lp.manual": NSNumber(value: 1), "lp.promptID": UUID().uuidString as NSString,
                              "lp.otp": "123456" as NSString])
        #expect(o == StartOptions(isManual: true))
        #expect(Mirror(reflecting: o).children.compactMap(\.label).sorted() == ["endpoints", "isManual", "nonce"])
    }

    @Test func startOptionsBoundTheEndpointMap() {
        var d: [String: [String]] = [:]
        for i in 0..<20 { d["h\(i).example"] = (0..<40).map { "192.0.2.\($0)" } }
        let o = StartOptions(["lp.manual": NSNumber(value: 1), "lp.endpoints": d as NSDictionary])
        #expect(o.endpoints.count == StartOptionKey.maxEndpointHosts)
        #expect(o.endpoints.values.allSatisfy { $0.count == StartOptionKey.maxIPsPerHost })
    }

    @Test func providerConfigurationParsesSection33() throws {
        let id = UUID()
        let pc: [String: Any] = ["v": 1, "profileID": id.uuidString, "kind": "ovpn", "revision": NSNumber(value: 7),
                                 "ownerUID": NSNumber(value: 501), "dnsMode": "split", "mtu": NSNumber(value: 1400),
                                 "blockIPv6": true, "onDemand": true, "auth": ["interactive": true, "kind": "staticChallenge"]]
        let c = try #require(ProviderConfiguration(providerConfiguration: pc, includeAllNetworks: true, enforceRoutes: false, excludeLocalNetworks: true))
        #expect(c.profileID == id && c.kind == .openVPN && c.revision == 7 && c.ownerUID == 501)
        #expect(c.policy.killSwitch && c.policy.allowLAN && c.policy.dnsMode == .split && c.policy.mtuOverride == 1400)
        #expect(c.policy.blockIPv6WithoutKillSwitch && c.hasOnDemandRules && c.interactiveKind == .staticChallenge)
        #expect(c.includeAllNetworks)
        let split = try #require(ProviderConfiguration(providerConfiguration: pc, includeAllNetworks: false, enforceRoutes: true, excludeLocalNetworks: true))
        #expect(split.policy.killSwitch && !split.includeAllNetworks)          // route protection: no withhold, provider DNS allowed
        #expect(ProviderConfiguration(providerConfiguration: ["v": 2], includeAllNetworks: false, enforceRoutes: false, excludeLocalNetworks: false) == nil)
    }
}

