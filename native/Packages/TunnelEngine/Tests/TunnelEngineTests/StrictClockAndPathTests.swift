import Foundation
import Network
import Synchronization
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// Draft 9 (S2): strict deadline timers (S2 saw `asyncAfter` fire 3–5 s late at 50–300 s) and the E12 path filter.
@Suite struct StrictClockTests {
    /// The production controller's only clock is the strict one: every connect, prompt, hold-retry, backoff and stop
    /// deadline of the extension sleeps on it.
    @Test func productionControllerUsesTheStrictClock() {
        #expect(ProductionTunnelController.self == TunnelController<StrictSuspendingClock>.self)
        #expect(EngineServiceBackend<StrictSuspendingClock>.self is any TunnelServiceBackend.Type)
    }

    @Test func firesOnTimeWithoutLeeway() async throws {
        let c = StrictSuspendingClock()
        let start = ContinuousClock.now
        try await c.sleep(for: .milliseconds(200))
        let took = ContinuousClock.now - start
        #expect(took >= .milliseconds(200))
        #expect(took < .milliseconds(700))                            // generous: CI load, not leeway, is the noise here
    }

    /// An hour in the past: a clock that waited at all (e.g. for the absolute distance) would take an hour, so the
    /// bound has a margin no CI load reaches (it was 50 ms against a 1 s past deadline).
    @Test func pastDeadlineReturnsAtOnce() async throws {
        let c = StrictSuspendingClock()
        let start = ContinuousClock.now
        try await c.sleep(until: c.now.advanced(by: .seconds(-3600)))
        #expect(ContinuousClock.now - start < .seconds(30))
    }

    @Test func cancellationEndsTheSleepWithCancellationError() async {
        let c = StrictSuspendingClock()
        let t = Task { () -> Bool in
            do { try await c.sleep(for: .seconds(3600)); return false } catch is CancellationError { return true } catch { return false }
        }
        try? await Task.sleep(for: .milliseconds(20))
        t.cancel()
        #expect(await t.value)
    }

    @Test func cancelledBeforeSleepingNeverWaits() async {
        let t = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await StrictSuspendingClock().sleep(for: .seconds(3600)); return false } catch { return error is CancellationError }
        }
        #expect(await t.value)
    }

    @Test func nanosecondConversion() {
        #expect(StrictSuspendingClock.nanoseconds(.seconds(50)) == 50_000_000_000)
        #expect(StrictSuspendingClock.nanoseconds(.milliseconds(1)) == 1_000_000)
        #expect(StrictSuspendingClock.nanoseconds(.seconds(-1)) == 0)
    }
}

@Suite struct PathFilterTests {
    /// S2 E12: inside the provider, `availableInterfaces` was `[en0, en0, utun4]`. The snapshot keeps the physical
    /// path only: no utun (ours or another VPN's), no duplicates.
    @Test func ownUtunAndDuplicatesAreIgnored() {
        let seen = NWPathSource.physicalInterfaces([("en0", "wired"), ("en0", "wired"), ("utun4", "other")])
        #expect(seen == ["en0:wired"])
    }

    @Test func ourUtunComingOrGoingIsNoPathChange() {
        let before = NWPathSource.physicalInterfaces([("en0", "wifi")])
        let after = NWPathSource.physicalInterfaces([("en0", "wifi"), ("utun7", "other"), ("ipsec0", "other")])
        #expect(before == after)
        let a = PathSnapshot(status: .satisfied, interfaces: before, gateways: ["192.168.64.1"])
        let b = PathSnapshot(status: .satisfied, interfaces: after, gateways: ["192.168.64.1"])
        #expect(a == b)
    }

    @Test func physicalChangesStillCount() {
        #expect(NWPathSource.physicalInterfaces([("en0", "wifi")]) != NWPathSource.physicalInterfaces([("en1", "wired")]))
        #expect(NWPathSource.physicalInterfaces([("ppp0", "other"), ("utun1", "other")]) == ["ppp0:other"])   // PPPoE is a path
    }

    /// End to end through the controller: a path that differs only by our utun does not reassert a connected session.
    @Test func controllerIgnoresAUtunOnlyDifference() async {
        let h = Harness()
        await h.provision()
        _ = await h.connect()
        #expect(await waitUntil { h.paths.subscribed })
        let base = PathSnapshot(status: .satisfied, interfaces: NWPathSource.physicalInterfaces([("en0", "wired")]), gateways: ["gw"])
        h.paths.send(base)
        await h.advance(h.clock, by: .milliseconds(500), sleepers: 2)
        #expect(await waitUntil { await h.controller.pathState.settled == base })
        h.paths.send(PathSnapshot(status: .satisfied,
                                  interfaces: NWPathSource.physicalInterfaces([("en0", "wired"), ("en0", "wired"), ("utun4", "other")]),
                                  gateways: ["gw"]))
        await h.advance(h.clock, by: .milliseconds(500), sleepers: 2)
        #expect(await waitUntil { await h.controller.pathState.pending == false })
        #expect(await h.phase == .connected)
    }
}
