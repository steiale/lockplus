import Darwin
import Foundation
import LPParsing
@testable import LPRouteProbe
import Testing

@Suite struct RouteProbeTests {
    @Test func resolvesLiteralsV4First() {
        let a = RouteProbe.resolve(host: "127.0.0.1", port: "51820")
        #expect(a.count == 1 && a[0].ss_family == sa_family_t(AF_INET))
        #expect(RouteProbe.resolve(host: "no-such-host.invalid", port: "1").isEmpty)
    }

    @Test func loopbackAndUnresolvableAreNeverFindings() async {
        #expect(await RouteProbe().nonPrimaryInterface(for: ImportEndpoint(host: "127.0.0.1", port: "1", transport: "udp")) == nil)
        #expect(await RouteProbe().nonPrimaryInterface(for: ImportEndpoint(host: "x.invalid", port: "1", transport: "udp")) == nil)
    }

    /// With a default route (any dev Mac or CI runner), a public address routes via the primary interface.
    @Test func publicAddressUsesThePrimaryInterface() async throws {
        try #require(RouteProbe.defaultInterfaceIndex(family: AF_INET) != nil, "no IPv4 default route on this host")
        let ext = RouteProbe.interfaceIndex(to: RouteProbe.resolve(host: "192.0.2.1", port: "1")[0])
        #expect(ext == RouteProbe.defaultInterfaceIndex(family: AF_INET))
        #expect(await RouteProbe().nonPrimaryInterface(for: ImportEndpoint(host: "192.0.2.1", port: "1", transport: "udp")) == nil)
    }

    @Test func ipLiteralsOnlyNoDNS() {
        #expect(RouteProbe.resolve(host: "example.com", port: "0", numericOnly: true).isEmpty)
        #expect(RouteProbe.nonPrimaryInterface(forIPs: ["127.0.0.1", "::1", "not-an-ip"]) == nil)
        #expect(RouteProbe.nonPrimaryInterface(forIPs: ["192.0.2.1"]) == nil)
    }

    /// A stuck resolver must not hold the caller: the deadline wins and the late result is dropped. The work blocks
    /// until the test releases it AFTER the race returned, so no elapsed-time bound is needed (a race that waited for
    /// its work would never return).
    @Test(.timeLimit(.minutes(1))) func deadlineBeatsSlowWork() async {
        let stuck = DispatchSemaphore(value: 0)
        let r = await RouteProbe.race(deadline: .milliseconds(100)) { @Sendable in
            stuck.wait()
            return "late0"
        }
        #expect(r == nil)
        stuck.signal()
        #expect(await RouteProbe.race(deadline: .seconds(30)) { @Sendable in "en0" } == "en0")
    }

    /// The probe queue is concurrent: work queued behind a stuck one still runs. `fast` completes while `slow` is still
    /// blocked; on a serial queue it could only end by its own (long) deadline, as nil.
    @Test(.timeLimit(.minutes(1))) func slowEndpointDoesNotDelayOthers() async {
        let stuck = DispatchSemaphore(value: 0)
        async let slow = RouteProbe.race(deadline: .milliseconds(300)) { @Sendable in stuck.wait(); return "slow" }
        let fast = await RouteProbe.race(deadline: .seconds(30)) { @Sendable in "fast" }
        #expect(fast == "fast")
        #expect(await slow == nil)
        stuck.signal()
    }
}

/// Draft 9 (S2 E10): the app resolves endpoint hostnames before the start; the provider never does under the flag.
@Suite struct StartEndpointResolverTests {
    @Test func hostnamesSkipLiteralsAndDuplicates() {
        let h = StartEndpointResolver.hostnames(["VPN.example.com:1194", "vpn.example.com:443", "192.0.2.1:51820", "[2001:db8::1]:51820",
                                                 "bare.example", "", "bad host:1"])
        #expect(h == ["vpn.example.com", "bare.example"])
    }

    @Test func resolvesEachHostConcurrentlyAndDropsFailures() async {
        let r = await StartEndpointResolver.resolve(["a.example:1", "b.example:2", "203.0.113.1:3"]) { @Sendable host in
            host == "a.example" ? ["192.0.2.1", "2001:db8::1"] : []
        }
        #expect(r == ["a.example": ["192.0.2.1", "2001:db8::1"]])
    }

    /// The stuck lookup is released only after `resolve` returned: the deadline, not the lookup, ended its slot.
    @Test(.timeLimit(.minutes(1))) func aStuckHostCostsOnlyTheDeadline() async {
        let stuck = DispatchSemaphore(value: 0)
        let r = await StartEndpointResolver.resolve(["slow.example:1", "fast.example:1"], deadline: .milliseconds(100)) { @Sendable host in
            if host == "slow.example" { stuck.wait() }
            return ["192.0.2.9"]
        }
        #expect(r == ["fast.example": ["192.0.2.9"]])
        stuck.signal()
    }

    @Test func lookupOfALiteralNeedsNoDNS() {
        #expect(StartEndpointResolver.lookupIPs("127.0.0.1") == ["127.0.0.1"])
    }
}
