import Foundation
import LPModel
import Testing
@testable import LockPlus

/// §10.2 L-DNS-3: the scutil parser, the rule (`.unknown` is never safe), and the store: 3 s after `.connected`, the
/// verdict feeds the derived-state input.
@MainActor @Suite("DNS verifier (§10.2)", .serialized)
struct DNSVerifierTests {
    static let otherVPN = """
        DNS configuration

        resolver #1
          search domain[0] : corp.example
          nameserver[0] : 172.16.0.53
          if_index : 31 (utun9)

        resolver #2
          domain   : vpn.example
          nameserver[0] : 10.8.0.1
          if_index : 23 (utun4)
        """

    static let lan = """
        DNS configuration

        resolver #1
          nameserver[0] : 192.168.1.1
          nameserver[1] : fe80::1%en0
          if_index : 6 (en0)
        """

    @Test func parsesTheUnscopedSectionOnly() {
        let r = DNSVerifier.parse(FixtureDNSSystem.preview.scutil!)
        #expect(r.count == 2)
        #expect(r[0] == DNSResolver(index: 1, domain: nil, searchDomains: [], nameservers: ["10.8.0.1"], interface: "utun4"))
        #expect(r[1].domain == "local")
        let o = DNSVerifier.parse(Self.otherVPN)
        #expect(o[0].searchDomains == ["corp.example"])
        #expect(DNSVerifier.parse(Self.lan)[0].nameservers == ["192.168.1.1", "fe80::1%en0"])
    }

    @Test func rule() {
        let ours = DNSVerifier.parse(FixtureDNSSystem.preview.scutil!)
        #expect(DNSVerifier.evaluate(resolvers: ours, globalServers: ["10.8.0.1"], expectedServers: ["10.8.0.1"], catchAll: true, probeCompleted: true) == .ok)
        // pushed servers the app doesn't know: the tunnel interface must own the default
        #expect(DNSVerifier.evaluate(resolvers: ours, globalServers: nil, expectedServers: [], catchAll: true, probeCompleted: true) == .ok)
        // another VPN took the default resolver
        if case .mismatch = DNSVerifier.evaluate(resolvers: DNSVerifier.parse(Self.otherVPN), globalServers: nil, expectedServers: ["10.8.0.1"],
                                                 catchAll: true, probeCompleted: true) {} else { Issue.record("expected a mismatch") }
        // our tunnel is down to the LAN resolver
        if case .mismatch = DNSVerifier.evaluate(resolvers: DNSVerifier.parse(Self.lan), globalServers: nil, expectedServers: [],
                                                 catchAll: true, probeCompleted: true) {} else { Issue.record("expected a mismatch") }
        // global state disagrees with resolver #1
        if case .mismatch = DNSVerifier.evaluate(resolvers: ours, globalServers: ["8.8.8.8"], expectedServers: ["10.8.0.1"],
                                                 catchAll: true, probeCompleted: true) {} else { Issue.record("expected a mismatch") }
        // never safe without evidence
        if case .unknown = DNSVerifier.evaluate(resolvers: ours, globalServers: nil, expectedServers: ["10.8.0.1"], catchAll: true,
                                                probeCompleted: false) {} else { Issue.record("expected unknown") }
        if case .unknown = DNSVerifier.evaluate(resolvers: [], globalServers: nil, expectedServers: [], catchAll: true,
                                                probeCompleted: true) {} else { Issue.record("expected unknown") }
        // split mode with known servers: the interface isn't required to own the default
        #expect(DNSVerifier.evaluate(resolvers: ours, globalServers: nil, expectedServers: ["10.8.0.1"], catchAll: false, probeCompleted: true) == .ok)
    }

    @Test func verdictsAndPorts() {
        #expect(DiagnosticsStore.verdict(.ok) == .verified)
        #expect(DiagnosticsStore.verdict(.mismatch("x")) == .overridden)
        #expect(DiagnosticsStore.verdict(.unknown("x")) == .unverified)
        #expect(DiagnosticsStore.stripPort("1.1.1.1:53") == "1.1.1.1")
        #expect(DiagnosticsStore.stripPort("[2001:db8::1]:53") == "2001:db8::1")
        #expect(DiagnosticsStore.stripPort("2001:db8::1") == "2001:db8::1")
        #expect(DNSVerifier.normalize("FE80::1%en0") == "fe80::1")
    }

    @Test func storeChecksAfterConnectedAndResetsOnDisconnect() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let store = DiagnosticsStore(system: FixtureDNSSystem(scutil: Self.lan, global: nil), profiles: h.env.profiles, delay: .milliseconds(20))
        store.statusChanged(p.id, .connected)
        #expect(store.dns == .pending)
        #expect(await eventually { store.dns != .pending })
        #expect(store.dns == .overridden)                           // the LAN resolver owns the default
        #expect(store.dnsCheck(connected: true).result == .fail)
        store.statusChanged(p.id, .disconnected)
        #expect(store.dns == .pending)
        #expect(store.dnsCheck(connected: false).result == .unknown)
    }

    @Test func theVerdictReachesTheDerivedStateInputs() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        try await h.env.managers.save(ManagerConfiguration(profile: p, onDemand: nil))
        h.env.connection.start()
        UIBinder.bind(h.env)
        h.managers.emit(p.id, .connecting)
        h.managers.emit(p.id, .connected)
        await h.env.diagnostics.verify(p.id)                       // on demand, instead of waiting 3 s
        #expect(await eventually { h.env.diagnostics.dns != .pending && h.env.ui.connection.inputs.dns == h.env.diagnostics.dns })
        // The preview fixture: utun4 with 10.8.0.1. The seed profile's DNS decides ok vs. mismatch; either way it's
        // no longer pending and is the same value the UI reads.
        #expect(h.env.diagnostics.dns != .pending)
        #expect(h.env.ui.connection.inputs.dns == h.env.diagnostics.dns)
        await h.env.runDiagnostics()
        #expect(h.env.ui.diagnostics.checks.map(\.kind) == [.tunnel, .dns, .ipv6, .otherVPNs, .oldHelper])
    }
}
