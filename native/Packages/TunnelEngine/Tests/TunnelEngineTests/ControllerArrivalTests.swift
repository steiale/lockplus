import Foundation
import LPModel
import LPWire
import Testing
@testable import TunnelEngine
import TunnelEngineTestSupport

/// Residual 2 (review 2026-10-30): the path watcher runs from the START. Arriving at a network during a pending start
/// retries it at once (push-on-arrival semantics of 8d7d7f5: on arriving, never while there is none).
@Suite struct ControllerArrivalTests {
    static let wifi = PathSnapshot(status: .satisfied, interfaces: ["en0:wifi"], gateways: ["192.168.1.1"])
    static let ethernet = PathSnapshot(status: .satisfied, interfaces: ["en7:wiredEthernet"], gateways: ["10.0.0.1"])
    static let none = PathSnapshot(status: .unsatisfied)
    /// Our own kill-switch start: en0 is still listed, the status is unsatisfied.
    static let ownStart = PathSnapshot(status: .unsatisfied, interfaces: ["en0:wifi"], gateways: ["192.168.1.1"])

    func settle(_ h: Harness, _ p: PathSnapshot) async {
        _ = await waitUntil { h.paths.subscribed }
        h.paths.send(p)
        _ = await waitUntil { h.clock.sleeperCount >= 2 }
        try? await Task.sleep(for: .milliseconds(5))
        h.clock.advance(by: .milliseconds(500))
        _ = await waitUntil { await !h.controller.pathState.pending }
    }

    /// The reported case: a WireGuard start begun with no interface; arriving on Wi-Fi replaces the attempt in flight
    /// (it would wait out its 45 s deadline), the new attempt connects.
    @Test func arrivingDuringAWireGuardAttemptRetriesAtOnce() async {
        let h = Harness(kind: .wireGuard, killSwitch: true)
        await h.provision()
        let t = h.start(endpoints: ["vpn.example": ["192.0.2.1"]])
        let a = await h.adapter()
        await settle(h, Self.none)                                   // the baseline: no network
        #expect(await h.controller.pathState.settled == Self.none)
        #expect(h.factory.adapters.count == 1)
        await settle(h, Self.wifi)                                   // arrival
        let b = await h.adapter(1)
        #expect(b.request?.endpoints == ["vpn.example": ["192.0.2.1"]])
        #expect(await waitUntil { a.stopCount == 1 })
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        #expect(h.code(await t.value) == nil)
        #expect(await h.waitPhase(.connected))
    }

    /// Never while there is none, and never for a status flip alone (our own kill-switch start).
    @Test func leavingANetworkOrAStatusFlipRetriesNothing() async {
        let h = Harness(kind: .wireGuard, killSwitch: true)
        await h.provision()
        let t = h.start()
        _ = await h.adapter()
        await settle(h, Self.wifi)
        await settle(h, Self.ownStart)                               // en0 still listed, unsatisfied: a status flip only
        await settle(h, Self.wifi)
        await settle(h, Self.none)                                   // leaving
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.count == 1)
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// A retryable hold retries on arrival instead of waiting out its backoff; a hold that waits for the user
    /// (`.dnsResolutionFailed`) does not.
    @Test func arrivingInARetryableHoldRetriesNow() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start(endpoints: ["vpn.example": ["192.0.2.1"]])
        (await h.adapter()).finishStart(.failure(.failed(LPTunnelError(.connectTimeout))))
        #expect(await h.waitPhase(.held(.blockedAfterFailure(.connectTimeout))))
        await settle(h, Self.none)
        #expect(h.factory.adapters.count == 1)
        await settle(h, Self.wifi)
        let b = await h.adapter(1)                                    // at once, not after the backoff
        _ = await b.requestSettings(Harness.plan).value()
        b.finishStart()
        #expect(h.code(await t.value) == nil)

        let d = Harness(killSwitch: true)
        await d.provision()
        let t2 = d.start()
        (await d.adapter()).finishStart(.failure(.failed(LPTunnelError(.dnsResolutionFailed, detail: "no endpoint IPs"))))
        #expect(await d.waitPhase(.held(.blockedAfterFailure(.dnsResolutionFailed))))
        await settle(d, Self.none)
        await settle(d, Self.wifi)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(d.factory.adapters.count == 1)
        await d.controller.stop(reason: .userInitiated)
        _ = await t2.value
    }

    /// An OpenVPN attempt in flight is never replaced (the server may already be answering), a prompt neither.
    @Test func anOpenVPNAttemptInFlightIsNotReplaced() async {
        let h = Harness(killSwitch: true)
        await h.provision()
        let t = h.start()
        _ = await h.adapter()
        await settle(h, Self.none)
        await settle(h, Self.wifi)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.count == 1)
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// Bounded per session.
    @Test func arrivalRetriesAreBounded() async {
        let h = Harness(kind: .wireGuard, killSwitch: true, configure: { $0.maxArrivalRetriesPerSession = 1 })
        await h.provision()
        let t = h.start()
        _ = await h.adapter()
        await settle(h, Self.none)
        await settle(h, Self.wifi)
        _ = await h.adapter(1)
        await settle(h, Self.none)
        await settle(h, Self.ethernet)                               // a second arrival: over the limit
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.count == 2)
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// The pending start's baseline (no network, or our own start's path) never reads as a change once connected.
    @Test func connectedStartsAFreshBaseline() async {
        let h = Harness(kind: .wireGuard, killSwitch: true)
        await h.provision()
        let t = h.start()
        let a = await h.adapter()
        await settle(h, Self.none)
        _ = await a.requestSettings(Harness.plan).value()
        a.finishStart()
        #expect(h.code(await t.value) == nil)
        #expect(await h.waitPhase(.connected))
        await settle(h, Self.wifi)                                   // the first path of the connected session
        #expect(await h.phase == .connected)
        #expect(await h.controller.pathState.settled == Self.wifi)
    }

    /// Review R12: a type-label change of the same interface is not an arrival.
    @Test func aTypeLabelChangeOfTheSameInterfaceIsNotAnArrival() async {
        let h = Harness(kind: .wireGuard, killSwitch: true)
        await h.provision()
        let t = h.start()
        _ = await h.adapter()
        await settle(h, Self.wifi)
        await settle(h, PathSnapshot(status: .satisfied, interfaces: ["en0:wiredEthernet"], gateways: ["192.168.1.1"]))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.count == 1)
        await h.controller.stop(reason: .userInitiated)
        _ = await t.value
    }

    /// Review R12: each start begins with a fresh path baseline: the first path of a new start is never an arrival.
    @Test func aNewStartBeginsWithAFreshPathBaseline() async {
        let h = Harness(kind: .wireGuard, killSwitch: true)
        await h.provision()
        let t1 = h.start()
        _ = await h.adapter()
        await settle(h, Self.wifi)
        await h.controller.stop(reason: .userInitiated)
        _ = await t1.value
        let t2 = h.start()
        _ = await h.adapter(1)
        try? await Task.sleep(for: .milliseconds(20))
        await settle(h, Self.ethernet)                               // the new start's first path
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.factory.adapters.count == 2)
        await h.controller.stop(reason: .userInitiated)
        _ = await t2.value
    }
}
