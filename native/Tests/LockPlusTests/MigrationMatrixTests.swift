import AppKit
import Foundation
import LPModel
import LPParsing
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// Migration matrix (2026-11-09, every 1.x version group): data from both Go directories, every helper generation, the
/// WireGuide+ login item and app, System keychain passwords. Fixtures and fakes only: no real data, no privileged run.
@MainActor @Suite("Migration matrix", .serialized, .timeLimit(.minutes(1)))
struct MigrationMatrixTests {
    /// A §4.5 system with files, signatures and the old WireGuide+ app under the test's control.
    final class MatrixSystem: LegacySystemReading {
        struct State {
            var files: Set<String>
            var signedByUs: Set<String> = []
            var wgpApp: URL?
            var wgpRunning = false
            var wg100Running = false
            var trashed: [URL] = []
            var trashWorks = true
        }
        let state: Mutex<State>
        init(files: Set<String>) { state = Mutex(State(files: files)) }
        func fileExists(_ path: String) -> Bool { state.withLock { $0.files.contains(path) } }
        func probeHelper() async -> HelperProbe { .reachable(active: false, killSwitchBlocked: false) }
        @MainActor func goGUIRunning() -> Bool { state.withLock { $0.wgpRunning } }
        func signedByOurTeam(_ path: String) -> Bool { state.withLock { $0.signedByUs.contains(path) } }
        @MainActor func wireGuidePlusAppURL() -> URL? { state.withLock { $0.wgpApp } }
        @MainActor func wireGuidePlusRunning() -> Bool { state.withLock { $0.wgpRunning } }
        @MainActor func wireGuide100Running() -> Bool { state.withLock { $0.wg100Running } }
        @MainActor func moveToTrash(_ url: URL) async -> Bool {
            state.withLock { s in
                s.trashed.append(url)
                if s.trashWorks { s.wgpApp = nil }
                return s.trashWorks
            }
        }
    }

    // MARK: Helpers of every generation

    @Test("A WireGuide+ helper alone (1.0.1–1.0.56) is found and removable; its files are in the script")
    func theWireGuidePlusHelperIsHandled() async throws {
        let wgp = LegacyHelperPaths.wireGuidePlus
        let sys = MatrixSystem(files: [wgp.plist, wgp.binary])
        let runner = FakePrivilegedRunner(answer: .finished(output: "LP_RESULT=removed\n")) { sys.state.withLock { $0.files = [] } }
        let h = Harness(legacySystem: sys, legacyHelperRunner: runner)
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        #expect(h.env.legacy.finding == .helperIdle && h.env.legacy.canRemoveHelper)
        #expect(h.env.legacy.helperMayBePresent)
        await h.env.legacy.removeHelper()
        #expect(runner.runs == 1 && h.env.legacy.removal == .removed(leftNetworkState: false))
        let s = LegacyHelperRemoval.script
        for path in ["io.github.steiale.wireguide-plus.helper", "/Library/LaunchDaemons/io.github.steiale.wireguide-plus.helper.plist",
                     "/Library/PrivilegedHelperTools/io.github.steiale.wireguide-plus.helper", "/var/run/wireguide-plus",
                     "/var/log/wireguide-plus-helper.log", "'/Library/Application Support/wireguide-plus'"] {
            #expect(s.contains(path), "\(path)")
        }
        // Identified by label, program path and root owner; never by the lockplus-helper signature (early builds weren't signed).
        #expect(s.contains(#"plistis "$P2" "$L2" "$B2""#) && s.contains(#"rootfile "$B2" || result not-go-binary"#))
        #expect(!s.contains(#"signedas "$B2""#))
        // Its tunnels and DNS journal refuse like LockPlus's.
        #expect(s.contains(#"tunnelcheck "$D2" "$L2" "$B2""#) && s.contains(#"[ -e "$D2/dns-journal.json" ] && ! known "$L2""#))
    }

    @Test("com.wireguide.helper is upstream WireGuide's unless our team signed it: then it is ours (WireGuide+ 1.0.0)")
    func upstreamHelperIsLeftAlone() async throws {
        let up = LegacyHelperPaths.upstreamLabel
        let sys = MatrixSystem(files: [up.plist, up.binary, up.dnsJournal])
        let h = Harness(legacySystem: sys)
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        #expect(h.env.legacy.finding == LegacyFinding.none)                // upstream's: no banner, no removal
        #expect(!(await LegacyAppDetector.helpers(sys)).contains(up))
        sys.state.withLock { $0.signedByUs = [up.binary] }
        await h.env.legacy.refresh()
        #expect((await LegacyAppDetector.helpers(sys)).contains(up))
        #expect(h.env.legacy.finding == .helperIdle && h.env.legacy.facts.dnsJournal)
        // Fable follow-up INFO: WireGuide+ 1.0.0's GUI (upstream's bundle ID) counts as the old app only now.
        sys.state.withLock { $0.wg100Running = true }
        await h.env.legacy.refresh()
        #expect(h.env.legacy.facts.goGUIRunning && h.env.legacy.refusal == .oldAppRunning)
        sys.state.withLock { $0.signedByUs = [] }
        await h.env.legacy.refresh()
        #expect(!h.env.legacy.facts.goGUIRunning)                         // upstream WireGuide running never blocks
        #expect(LegacyHelperRemoval.body.contains(#"if [ "$U3" = yes ] && pgrep -f '/Contents/MacOS/wireguide( |$)'"#))
        // The script gates every com.wireguide.helper action on its signature (U3), as root.
        let s = LegacyHelperRemoval.script
        #expect(s.contains(#"if rootfile "$B3" && signedbyus "$B3"; then U3=yes; fi"#))
        #expect(s.components(separatedBy: #""$U3" = yes"#).count - 1 >= 8)
        let gate = try #require(s.range(of: "if [ \"$U3\" = yes ]; then\n  if present \"$P3\"; then rm -f \"$P3\"; fi\n  rm -f \"$B3\""))
        #expect(s.range(of: #"rm -f "$B3""#)?.lowerBound ?? s.startIndex > gate.lowerBound)
    }

    @Test("The removal script still parses with every helper block (sh -n), and refuses before it removes anything")
    func theScriptParses() throws {
        let s = LegacyHelperRemoval.script
        // E2E-7 F3 review M1: `sh -n` of the wrapper doesn't look inside its quoted body, so both are parsed.
        #expect(try E2E7FixTests.parses(s) && E2E7FixTests.parses(LegacyHelperRemoval.body))
        let firstRemoval = try #require(s.range(of: "rm -f")).lowerBound
        for check in [#"result not-go-plist"#, "result dns-unrestored", "result old-app-running", #"launchctl bootout "system/$L2""#] {
            #expect(try #require(s.range(of: check)).lowerBound < firstRemoval, "\(check)")
        }
    }

    // MARK: WireGuide+ login item and app

    @Test("WireGuide+'s LaunchAgent is removed like LockPlus 1.0.x's (exact label and program; others stay)")
    func theWireGuidePlusAgentIsRetired() throws {
        func agent(_ label: String, _ program: String, key: String = "ProgramArguments") -> Data {
            let value = key == "Program" ? "<string>\(program)</string>" : "<array><string>\(program)</string></array>"
            return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>Label</key><string>\(label)</string><key>\(key)</key>\(value)<key>RunAtLoad</key><true/></dict></plist>
            """.utf8)
        }
        let w = LegacyLaunchAgent.wireGuidePlus
        #expect(LegacyLaunchAgent.isGoAgent(agent(w.label, "/Applications/WireGuide+.app/Contents/MacOS/wireguide-plus"), agent: w))
        #expect(LegacyLaunchAgent.isGoAgent(agent(w.label, "/Applications/WireGuide+.app/Contents/MacOS/wireguide-plus", key: "Program"), agent: w))
        #expect(!LegacyLaunchAgent.isGoAgent(agent(w.label, "/usr/local/bin/wireguide-plus"), agent: w))
        #expect(!LegacyLaunchAgent.isGoAgent(agent("com.wireguide.gui", "/Applications/WireGuide.app/Contents/MacOS/wireguide"), agent: w))
        let dir = TestDir()
        defer { dir.cleanup() }
        let home = try E2E5FixTests.home(dir, agent: nil)
        try agent(w.label, "/Applications/WireGuide+.app/Contents/MacOS/wireguide-plus").write(to: LegacyLaunchAgent.url(home: home, agent: w))
        let upstream = URL(fileURLWithPath: home).appending(path: "Library/LaunchAgents/com.wireguide.gui.plist")
        try agent("com.wireguide.gui", "/Applications/WireGuide.app/Contents/MacOS/wireguide").write(to: upstream)
        #expect(LegacyLaunchAgent.retire(home: home))
        #expect(!FileManager.default.fileExists(atPath: LegacyLaunchAgent.url(home: home, agent: w).path))
        #expect(FileManager.default.fileExists(atPath: upstream.path))     // upstream WireGuide's is never touched
    }

    @Test("The old WireGuide+ app is offered for the Trash; never while it runs; a failure says so")
    func theOldAppIsOfferedForTheTrash() async throws {
        let sys = MatrixSystem(files: [])
        let app = URL(fileURLWithPath: "/Applications/WireGuide+.app")
        sys.state.withLock { $0.wgpApp = app; $0.wgpRunning = true }
        let h = Harness(legacySystem: sys)
        defer { h.dir.cleanup() }
        UIBinder.bind(h.env)
        await h.env.legacy.refresh()
        #expect(await eventually { h.env.ui.connection.oldWireGuidePlusApp == OldAppNotice(url: app, running: true) })
        await h.env.legacy.trashOldApp()
        #expect(sys.state.withLock { $0.trashed.isEmpty })                 // running: not moved
        sys.state.withLock { $0.wgpRunning = false; $0.trashWorks = false }
        await h.env.legacy.trashOldApp()
        #expect(sys.state.withLock { $0.trashed } == [app])
        #expect(await eventually { h.env.ui.connection.oldAppTrashFailed })
        sys.state.withLock { $0.trashWorks = true }
        h.env.ui.actions.trashOldWireGuidePlusApp()
        #expect(await eventually { h.env.ui.connection.oldWireGuidePlusApp == nil && !h.env.ui.connection.oldAppTrashFailed })
        #expect(!LegacyHelperCopy.oldAppInstalled.isEmpty && LegacyHelperCopy.oldAppRunning.contains("Quit"))
    }

    // MARK: Data from both directories; passwords in the System keychain

    @Test("Both Go directories: the union is imported once, lockplus wins, and wifi rules come from wireguide-plus")
    func bothDirectoriesImport() async throws {
        let lp = GoDirFixture(tunnels: ["home.conf": PreviewSeed.nasConf, "work.conf": PreviewSeed.workConf],
                              data: ["config.json": #"{"kill_switch":false}"#])
        let wgp = GoDirFixture(tunnels: ["home.conf": PreviewSeed.nasConf, "office.ovpn": PreviewSeed.officeOvpn],
                               data: ["wifi_rules.json": #"{"enabled":true,"default_tunnel":"office","auto_connect_untrusted":true,"trusted_ssids":["OldNet"]}"#])
        let h = Harness(goSource: { GoAppMergedSource(primary: lp, secondary: wgp) })
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        #expect(offer.profileNames.sorted() == ["home", "office", "work"])
        _ = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(h.env.profiles.profiles.map(\.name).sorted() == ["home", "office", "work"])
        let office = try #require(h.env.profiles.profiles.first { $0.name == "office" })
        #expect(h.env.settings.value.autoConnect.profileID == office.id && h.env.settings.value.autoConnect.trustedSSIDs == ["OldNet"])
    }

    @Test("System keychain passwords (1.0.65 and older) are named in the report, with or without the opt-in")
    func systemKeychainPasswordsAreNamed() async throws {
        let listing = LegacyKeychainListing(items: [], systemKeychainItems: 2, systemAccounts: ["office", "gone"])
        let h = Harness(goSource: { GoDirFixture.mixed }, legacyKeychain: FixtureLegacyKeychain(listing: listing))
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        #expect(offer.savedPasswords == 0)                                 // nothing to opt in to
        let r = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(r.notMigrated.contains { $0.hasPrefix("office: ") && $0.contains("System keychain") && $0.contains("Enter it again") })
        #expect(r.notMigrated.contains { $0.hasPrefix("1 saved password ") })   // "gone" has no profile here
    }

    @Test("Upstream WireGuide's profiles are never imported; the report says how to bring them over")
    func upstreamWireGuideGetsANote() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        h.env.migrator.upstreamWireGuide = { true }
        let offer = try #require(await h.env.migrator.detect())
        let r = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(r.notes.contains { $0.contains("WireGuide's profiles") && $0.contains("Import Profile…") })
        h.env.migrator.upstreamWireGuide = { false }
        let again = await h.env.migrator.run(selected: [])
        #expect(!again.notes.contains { $0.contains("WireGuide's profiles") })
    }
}
