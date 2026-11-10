import Foundation
import Testing
@testable import LockPlus

/// §10.4 / UI-CONCEPT §6.7 "Add Current Network": Location just in time, never on launch; fixtures only.
@MainActor @Suite("Add Current Network (§10.4)", .serialized)
struct AddCurrentNetworkTests {
    func harness(_ wifi: FixtureWiFiLocator) -> Harness {
        Harness(makeWiFi: { wifi })
    }

    @Test func undecidedAsksOnceThenAddsAndSaves() async throws {
        let wifi = FixtureWiFiLocator(authorization: .notDetermined, afterRequest: .authorized, ssid: "Cafe-Guest")
        let h = harness(wifi)
        defer { h.dir.cleanup() }
        await h.env.start()
        #expect(wifi.requests == 0)                                    // launch reads the state, never prompts
        #expect(h.env.ui.autoConnect.location == .notDetermined)
        await h.env.addCurrentNetwork()
        #expect(wifi.requests == 1)
        #expect(h.env.ui.autoConnect.location == .authorized)
        #expect(h.env.ui.autoConnect.currentSSID == "Cafe-Guest")
        #expect(h.env.ui.autoConnect.trustedNetworks.contains("Cafe-Guest"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.env.settings.value.autoConnect.trustedSSIDs.contains("Cafe-Guest"))   // two-way binding saved it
        await h.env.addCurrentNetwork()                                // no duplicate, no second prompt
        #expect(h.env.ui.autoConnect.trustedNetworks.filter { $0 == "Cafe-Guest" }.count == 1)
        #expect(wifi.requests == 1)
        h.env.stop()
    }

    @Test func deniedAddsNothing() async {
        let wifi = FixtureWiFiLocator(authorization: .denied)
        let h = harness(wifi)
        defer { h.dir.cleanup() }
        await h.env.addCurrentNetwork()
        #expect(h.env.ui.autoConnect.location == .denied)
        #expect(h.env.ui.autoConnect.trustedNetworks.isEmpty)
        #expect(wifi.requests == 0)
    }

    @Test func notOnWiFiAddsNothing() async {
        let wifi = FixtureWiFiLocator(authorization: .authorized, ssid: nil)
        let h = harness(wifi)
        defer { h.dir.cleanup() }
        await h.env.addCurrentNetwork()
        #expect(h.env.ui.autoConnect.trustedNetworks.isEmpty)
        #expect(h.env.ui.autoConnect.currentSSID == nil)
    }

    @Test func oversizedSSIDIsRejectedByTheCaps() async {
        let wifi = FixtureWiFiLocator(authorization: .authorized, ssid: String(repeating: "x", count: 33))
        let h = harness(wifi)
        defer { h.dir.cleanup() }
        await h.env.addCurrentNetwork()
        #expect(h.env.ui.autoConnect.trustedNetworks.isEmpty)          // §3.2: ≤ 32 bytes
    }
}
