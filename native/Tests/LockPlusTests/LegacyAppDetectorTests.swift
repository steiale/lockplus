import Foundation
import Testing
@testable import LockPlus

/// §4.5 Go helper coexistence: the policy table, the read-only Go IPC frame, and the connect gate. Fixtures only:
/// no socket, no root paths.
@MainActor @Suite("Go helper coexistence (§4.5)", .serialized)
struct LegacyAppDetectorTests {
    func settle(_ ms: Int = 50) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    @Test func policyTable() {
        func f(_ installed: Bool, _ reachable: Bool?, active: Bool = false, blocked: Bool = false, journal: Bool = false, pf: Bool = false) -> LegacyFinding {
            LegacyFinding.evaluate(LegacyFacts(helperInstalled: installed, helperReachable: reachable, helperActive: active,
                                               killSwitchBlocked: blocked, dnsJournal: journal, pfWasEnabled: pf))
        }
        #expect(f(false, nil) == .none)
        #expect(f(true, true, active: true) == .refuseConnect)
        #expect(f(true, true, blocked: true) == .refuseConnect)
        #expect(f(true, true) == .helperIdle)
        #expect(f(true, false, pf: true) == .helperCrashedWithFirewall)
        #expect(f(true, false) == .helperIdle)
        #expect(f(false, nil, journal: true) == .leftoverState)
        #expect(f(false, nil, pf: true) == .leftoverState)
        #expect(LegacyFinding.refuseConnect.blocksConnect && !LegacyFinding.helperIdle.blocksConnect)
    }

    @Test func goIPCFrameAndReply() throws {
        let frame = LegacyAppDetector.statusRequestFrame()
        let n = Int(frame[0]) << 24 | Int(frame[1]) << 16 | Int(frame[2]) << 8 | Int(frame[3])
        #expect(n == frame.count - 4)
        let req = try #require(JSONSerialization.jsonObject(with: Data(frame.dropFirst(4))) as? [String: Any])
        #expect(req["method"] as? String == "Tunnel.Status")        // read-only; never Connect/Disconnect/Uninstall
        #expect(req["params"] == nil)
        let reply = Array(#"{"jsonrpc":"2.0","id":1,"result":{"state":"connected","tunnel_name":"x","rx_bytes":0,"tx_bytes":0,"has_handshake":true}}"#.utf8)
        #expect(LegacyAppDetector.parseStatusReply(reply) == .reachable(active: true, killSwitchBlocked: false))
        let blocked = Array(#"{"jsonrpc":"2.0","id":1,"result":{"state":"error","kill_switch_blocked":true}}"#.utf8)
        #expect(LegacyAppDetector.parseStatusReply(blocked) == .reachable(active: false, killSwitchBlocked: true))
        #expect(LegacyAppDetector.parseStatusReply(Array(#"{"jsonrpc":"2.0","method":"Event.Status","params":{}}"#.utf8)) == nil)
    }

    @Test func factsFromFixtures() async {
        let sys = FixtureLegacySystem(files: [LegacyAppDetector.helperPlist, LegacyAppDetector.pfWasEnabled], probe: .unreachable, guiRunning: true)
        let f = await LegacyAppDetector.facts(sys)
        #expect(f.helperInstalled && f.helperReachable == false && f.pfWasEnabled && f.goGUIRunning)
        #expect(LegacyFinding.evaluate(f) == .helperCrashedWithFirewall)
    }

    @Test func anActiveOldTunnelRefusesTheConnect() async throws {
        let h = Harness(legacySystem: FixtureLegacySystem(files: [LegacyAppDetector.helperPlist], probe: .reachable(active: true, killSwitchBlocked: false)))
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        await h.env.legacy.refresh()
        h.env.connection.start()
        UIBinder.bind(h.env)
        #expect(h.env.ui.connection.legacyHelper == LegacyHelperNotice(message: LegacyFinding.refuseConnect.message!,
                                                                     blocksConnect: true, warnsBeforeConnect: false))
        h.env.ui.gatedConnect(p.id)
        try await settle()
        #expect(h.managers.starts.isEmpty)
        #expect(h.env.ui.connection.connectGate == .refused(p.id))
        #expect(h.env.ui.importer.errorMessage == nil)                 // no interim alert any more
        await h.env.runDiagnostics()
        #expect(h.env.ui.diagnostics.checks.last?.result == .fail)
        #expect(await h.env.legacyFindingsJSON()?.contains("\"helperActive\" : true") == true)
    }

    @Test func anIdleHelperAllowsTheConnect() async throws {
        let h = Harness(legacySystem: FixtureLegacySystem(files: [LegacyAppDetector.helperPlist], probe: .reachable(active: false, killSwitchBlocked: false)))
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        await h.env.legacy.refresh()
        h.env.connection.start()
        UIBinder.bind(h.env)
        #expect(h.env.ui.connection.legacyHelper?.blocksConnect == false)
        h.env.ui.gatedConnect(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.env.legacy.finding == .helperIdle)
    }
}

extension LegacyAppDetectorTests {
    /// Review M9: a stale "idle" notice doesn't let a connect through once the helper reports a tunnel.
    @Test func theGateReReadsTheHelperBeforeStarting() async throws {
        final class Box: @unchecked Sendable { var probe: HelperProbe = .reachable(active: false, killSwitchBlocked: false) }   // SAFETY: test-only
        struct Switchable: LegacySystemReading {
            let box: Box
            func fileExists(_ path: String) -> Bool { path == LegacyAppDetector.helperPlist }
            func probeHelper() async -> HelperProbe { box.probe }
            @MainActor func goGUIRunning() -> Bool { false }
        }
        let box = Box()
        let h = Harness(legacySystem: Switchable(box: box))
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        await h.env.legacy.refresh()
        h.env.connection.start()
        box.probe = .reachable(active: true, killSwitchBlocked: false)    // the old app connected meanwhile
        h.env.ui.actions.connect(p.id)
        #expect(await eventually { h.env.ui.connection.connectGate == .refused(p.id) })
        #expect(h.managers.starts.isEmpty)
    }
}
