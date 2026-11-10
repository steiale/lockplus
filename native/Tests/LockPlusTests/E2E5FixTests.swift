import Carbon.OpenScripting
import Foundation
import LPModel
import LPParsing
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// A §4.5 system whose files and helper answer change during a test (the old tunnel goes down, the helper is removed).
final class SwitchableLegacySystem: LegacySystemReading {
    struct State { var files: Set<String>; var probe: HelperProbe; var probes = 0; var guiRunning = false }
    let state: Mutex<State>
    init(files: Set<String> = [LegacyAppDetector.helperPlist], probe: HelperProbe) { state = Mutex(State(files: files, probe: probe)) }
    func set(_ probe: HelperProbe) { state.withLock { $0.probe = probe } }
    func setFiles(_ files: Set<String>) { state.withLock { $0.files = files } }
    var probes: Int { state.withLock { $0.probes } }
    func fileExists(_ path: String) -> Bool { state.withLock { $0.files.contains(path) } }
    func probeHelper() async -> HelperProbe { state.withLock { $0.probes += 1; return $0.probe } }
    @MainActor func goGUIRunning() -> Bool { state.withLock { $0.guiRunning } }
    func setGUIRunning(_ on: Bool) { state.withLock { $0.guiRunning = on } }
}

/// An in-memory Go app directory (tunnels and data files by name). Fixtures only: never the Go app's real data.
struct GoDirFixture: GoAppDataSource {
    var tunnels: [String: String]
    var data: [String: String] = [:]
    var sourceDescription: String { "test fixture" }
    func tunnelEntries() throws -> [GoAppEntry] { tunnels.keys.sorted().map { GoAppEntry(name: $0, kind: .regular) } }
    func readTunnelFile(_ name: String, maxBytes: Int) throws -> [UInt8] {
        guard let t = tunnels[name] else { throw CocoaError(.fileNoSuchFile) }
        return Array(t.utf8)
    }
    func readDataFile(_ name: String, maxBytes: Int) throws -> [UInt8]? { data[name].map { Array($0.utf8) } }

    /// One OpenVPN tunnel (saved sign-in) and one WireGuard tunnel, auto-connect with the WireGuard one, a history entry.
    static let mixed = GoDirFixture(
        tunnels: ["office.ovpn": PreviewSeed.officeOvpn, "home.conf": PreviewSeed.nasConf],
        data: ["config.json": #"{"kill_switch":false,"dns_protection":false,"auto_start":true,"theme":"dark"}"#,
               "wifi_rules.json": #"{"enabled":true,"default_tunnel":"home","auto_connect_untrusted":true,"trusted_ssids":["HomeNet"],"ssid_tunnel_map":{"CafeNet":"office"}}"#,
               "history.json": #"[{"tunnel_name":"home","start_time":"2026-11-01T10:00:00Z","end_time":"2026-11-01T11:00:00Z","rx_bytes":10,"tx_bytes":20,"disconnect_reason":"user"}]"#])

    /// Two WireGuard tunnels; Wi-Fi auto-connect on untrusted networks with "home", trusted HomeNet.
    static let autoConnect = GoDirFixture(
        tunnels: ["home.conf": PreviewSeed.nasConf, "work.conf": PreviewSeed.workConf],
        data: ["config.json": #"{"kill_switch":true,"dns_protection":true}"#,
               "wifi_rules.json": #"{"enabled":true,"default_tunnel":"home","auto_connect_untrusted":true,"trusted_ssids":["HomeNet"]}"#])
}

/// E2E-5 (native/e2e/RESULTS-E2E-5.md): the upgrade from the Go app. Fixtures and fakes only.
@MainActor @Suite("E2E-5 upgrade fixes", .serialized)
struct E2E5FixTests {
    // MARK: F2 auto-connect after the migration

    @Test("F2: the migrated auto-connect profile ends with on-demand enabled in its NE configuration")
    func migratedAutoConnectTurnsOnDemandOn() async throws {
        let h = Harness(goSource: { GoDirFixture.autoConnect })
        defer { h.dir.cleanup() }
        UIBinder.bind(h.env)
        let offer = try #require(await h.env.migrator.detect())
        _ = await h.env.migrator.run(selected: Set(offer.profileNames))
        let home = try #require(h.env.profiles.profiles.first { $0.name == "home" })
        #expect(h.env.settings.value.autoConnect.enabled && h.env.settings.value.autoConnect.profileID == home.id)
        #expect(await eventually { h.managers.entries[home.id]?.onDemand == true })
        #expect(h.managers.entries[home.id]?.cfg.onDemand?.enabled == true)
        let work = try #require(h.env.profiles.profiles.first { $0.name == "work" })
        #expect(h.managers.entries[work.id]?.onDemand != true)
        #expect(await eventually { !h.env.uiResaving })
        #expect(UIBinder.autoConnectStatusLine(h.env) == nil)            // not "couldn't turn it back on"
    }

    @Test("F2: while the profile is busy the re-save is deferred by the store's mutation rules, not forced")
    func migratedAutoConnectWaitsWhileBusy() async throws {
        let h = Harness(goSource: { GoDirFixture.autoConnect })
        defer { h.dir.cleanup() }
        UIBinder.bind(h.env)
        let offer = try #require(await h.env.migrator.detect())
        h.env.profiles.mutationBlocked = { _ in true }
        _ = await h.env.migrator.run(selected: Set(offer.profileNames))
        let home = try #require(h.env.profiles.profiles.first { $0.name == "home" })
        #expect(await eventually { !h.env.uiResaving })
        #expect(h.managers.entries[home.id]?.onDemand != true)
        #expect(h.env.profiles.hasDeferredSync)
    }

    // MARK: F3 a refusal is re-checked on every Connect

    @Test("F3: after a refusal, Connect works as soon as the old tunnel is down, without a relaunch")
    func aRefusalIsReCheckedOnTheNextConnect() async throws {
        let sys = SwitchableLegacySystem(probe: .reachable(active: true, killSwitchBlocked: true))
        let h = Harness(legacySystem: sys)
        defer { h.dir.cleanup() }
        h.env.legacy.pollInterval = .seconds(3600)                       // no poll: only the Connect re-reads
        let p = try await h.add("Work.conf", Harness.wgConf)
        await h.env.legacy.refresh()
        h.env.connection.start()
        UIBinder.bind(h.env)
        h.env.ui.gatedConnect(p.id)
        #expect(await eventually { h.env.ui.connection.connectGate == .refused(p.id) })
        #expect(h.managers.starts.isEmpty)
        let probes = sys.probes
        sys.set(.reachable(active: false, killSwitchBlocked: false))      // the Go tunnel and its kill switch are down
        h.env.ui.gatedConnect(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(sys.probes > probes)                                       // re-read, not decided from the cached notice
        #expect(h.env.ui.connection.connectGate == nil)
    }

    @Test("F3: while refusing, the notice is re-read and clears when the old tunnel goes down")
    func theRefusalNoticeRefreshesWhenTheOldTunnelGoesDown() async throws {
        let sys = SwitchableLegacySystem(probe: .reachable(active: true, killSwitchBlocked: false))
        let h = Harness(legacySystem: sys)
        defer { h.dir.cleanup() }
        h.env.legacy.pollInterval = .milliseconds(20)
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        UIBinder.bind(h.env)
        await h.env.legacy.refresh()
        #expect(await eventually { h.env.ui.connection.legacyHelper?.blocksConnect == true })
        h.env.ui.gatedConnect(p.id)
        #expect(await eventually { h.env.ui.connection.connectGate == .refused(p.id) })
        sys.set(.reachable(active: false, killSwitchBlocked: false))
        #expect(await eventually { h.env.legacy.finding == .helperIdle })
        #expect(await eventually { h.env.ui.connection.legacyHelper?.blocksConnect == false })
        #expect(await eventually { h.env.ui.connection.connectGate == nil })   // the refusal is over
        // Polling stops once idle: the poll loop has ended (deterministic; it was a 100 ms negative sleep).
        #expect(await eventually { !h.env.legacy.isWatching })
    }

    @Test("F3: the crashed-helper warning is re-checked too; Connect Anyway starts")
    func theWarningIsReCheckedAndConnectAnywayStarts() async throws {
        let sys = SwitchableLegacySystem(files: [LegacyAppDetector.helperPlist, LegacyAppDetector.pfWasEnabled], probe: .unreachable)
        let h = Harness(legacySystem: sys)
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        h.env.ui.gatedConnect(p.id)
        #expect(await eventually { h.env.ui.connection.connectGate == .warn(p.id) })
        #expect(h.managers.starts.isEmpty)
        h.env.ui.actions.connectAnyway(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
    }

    // MARK: F8 the refusal doesn't block Quit; "Open the old LockPlus" closes it and needs the old app

    @Test("F8: the refusal is a strip (no sheet that blocks Quit); Open the old LockPlus ends it")
    func theRefusalIsAStripAndOpeningTheOldAppEndsIt() {
        let env = UIEnvironment.preview(row: "15")
        let actions = env.actions as! PreviewUIActions
        env.connection.legacyHelper = LegacyHelperNotice(message: "m", blocksConnect: true, warnsBeforeConnect: false, oldAppInstalled: true)
        env.gatedConnect(PreviewData.workID)
        #expect(env.connection.connectGate == .refused(PreviewData.workID))
        #expect(MainAlert.active(in: env) == nil && MainSheet.active(in: env) == nil)
        ConnectGateStrip.openOldApp(env)
        #expect(env.connection.connectGate == nil)
        #expect(actions.log.last == "openOldLockPlus")
        env.connection.legacyHelper = LegacyHelperNotice(message: "m", blocksConnect: false, warnsBeforeConnect: true)
        env.gatedConnect(PreviewData.workID)
        #expect(env.connection.connectGate == .warn(PreviewData.workID))
        ConnectGateStrip.connectAnyway(PreviewData.workID, env)
        #expect(env.connection.connectGate == nil)
        #expect(actions.log.last == "connect")
    }

    @Test("F8: the notice knows whether the old app is still installed (after a Finder Replace it isn't)", arguments: [false, true])
    func theNoticeKnowsWhetherTheOldAppIsInstalled(_ installed: Bool) async {
        let h = Harness(legacySystem: FixtureLegacySystem(files: [LegacyAppDetector.helperPlist], probe: .reachable(active: true, killSwitchBlocked: false),
                                                          appInstalled: installed))
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        UIBinder.bind(h.env)
        #expect(h.env.legacy.facts.goAppInstalled == installed)
        #expect(h.env.ui.connection.legacyHelper?.oldAppInstalled == installed)
    }

    // MARK: F1 native removal of the old helper (fake runner only: the privileged command never runs in tests)

    @Test("F1: the removal script is a fixed constant: exact paths, checks before removing, valid sh, one result line")
    func theRemovalScriptIsFixedAndChecksBeforeRemoving() throws {
        let s = LegacyHelperRemoval.script
        for path in ["/Library/LaunchDaemons/io.github.steiale.lockplus.helper.plist",
                     "/Library/PrivilegedHelperTools/io.github.steiale.lockplus.helper", "/Library/PrivilegedHelperTools/openvpn",
                     "'/Library/Application Support/lockplus'", "/var/run/lockplus", "/var/log/lockplus-helper.log"] {
            #expect(s.contains(path), "\(path)")
        }
        #expect(s.contains(#"leaf[subject.OU] = "M53GHX9FAY""#))           // the Go installer's team pin
        #expect(s.contains("signedas \"$B\" lockplus-helper") && s.contains("signedas \"$O\" openvpn"))
        #expect(s.contains("pfctl -a com.apple/wireguide -s rules"))       // §4.5: refuse while the kill switch is up
        #expect(s.contains("pfctl -a com.apple/wireguide/dns -s rules"))   // review F1-3: the legacy sub-anchor too
        // Review F1-2: an un-replayed DNS journal refuses before the bootout; F1-5: ovpn-run/tunnel-states go in both branches.
        #expect(try #require(s.range(of: "result dns-unrestored")).lowerBound < (try #require(s.range(of: "launchctl bootout"))).lowerBound)
        #expect(try #require(s.range(of: "for x in tunnel-states ovpn-run")).lowerBound < (try #require(s.range(of: "left=yes\n"))).lowerBound)
        #expect(LegacyHelperRemoval.outcome(of: "LP_RESULT=dns-unrestored") == .dnsUnrestored)
        // Every removal comes after the busy, identity and signature checks and after the bootout.
        let firstRemoval = try #require(s.range(of: "rm -f")).lowerBound
        for check in ["result busy", "result not-go-plist", "result not-go-binary", "result dns-unrestored", "result old-app-running", "launchctl bootout"] {
            #expect(try #require(s.range(of: check)).lowerBound < firstRemoval, "\(check)")
        }
        // Nothing but these commands substitutes output; no argument of the app, the user or the Go app is ever read.
        let substitutions = s.components(separatedBy: "$(").dropFirst().map { String($0.prefix(while: { $0 != " " })) }
        #expect(Set(substitutions).isSubset(of: ["stat", "find", "pfctl", "/usr/libexec/PlistBuddy", "(n", "(i", "plutil", "networksetup", "ifconfig"]), "\(substitutions)")
        #expect(!s.contains("$1/") && !s.contains("eval") && !s.contains("rm -rf /") && !s.contains("rm -rf \"$D\""))
        // Syntax only (`sh -n` parses, runs nothing).
        // E2E-7 F3 review M1: `sh -n` of the wrapper doesn't look inside its quoted body, so both are parsed.
        #expect(try E2E7FixTests.parses(s) && E2E7FixTests.parses(LegacyHelperRemoval.body))
        #expect(LegacyHelperRemoval.outcome(of: "noise\nLP_RESULT=busy\n") == .busy)
        #expect(LegacyHelperRemoval.outcome(of: "LP_RESULT=removed\rLP_RESULT=removed-left-state") == .removedLeftState)
        #expect(LegacyHelperRemoval.outcome(of: "nothing") == nil)
    }

    @Test("F1: osascript gets the script and the prompt as argv of a constant handler; cancel and errors map")
    func theLiveRunnerPassesArgumentsAndMapsResults() {
        let h = OsascriptPrivilegedRunner.handler
        #expect(h.joined(separator: " ").contains("do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges"))
        #expect(!h.joined().contains("io.github"))                         // the script is data, never AppleScript source
        #expect(OsascriptPrivilegedRunner.result(status: 0, output: "LP_RESULT=removed\n", error: "") == .finished(output: "LP_RESULT=removed\n"))
        #expect(OsascriptPrivilegedRunner.result(status: 1, output: "", error: "0:84: execution error: User canceled. (-128)") == .cancelled)
        #expect(OsascriptPrivilegedRunner.result(status: 1, output: "", error: "execution error: boom (-60005)\n") == .failed("execution error: boom (-60005)"))
    }

    /// An idle old helper and a fake runner whose "root side" deletes the given files.
    func removalHarness(answer: PrivilegedRunResult, probe: HelperProbe = .reachable(active: false, killSwitchBlocked: false),
                        leaves: Set<String> = []) -> (Harness, SwitchableLegacySystem, FakePrivilegedRunner) {
        let sys = SwitchableLegacySystem(files: [LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary], probe: probe)
        let runner = FakePrivilegedRunner(answer: answer) { sys.setFiles(leaves) }
        return (Harness(legacySystem: sys, legacyHelperRunner: runner), sys, runner)
    }

    @Test("F1: an idle helper is removed with one privileged run; the banner then says so")
    func anIdleHelperIsRemoved() async {
        let (h, sys, runner) = removalHarness(answer: .finished(output: "LP_RESULT=removed\n"))
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        UIBinder.bind(h.env)
        #expect(h.env.ui.connection.legacyHelper?.canRemoveHelper == true)
        #expect(h.env.ui.connection.legacyHelper?.message.contains("Run its uninstaller") == false)
        h.env.ui.actions.removeOldHelper()
        #expect(await eventually { h.env.legacy.removal == .removed(leftNetworkState: false) })
        #expect(runner.runs == 1)
        #expect(runner.lastScript == LegacyHelperRemoval.script)
        #expect(runner.lastPrompt == LegacyHelperRemoval.prompt)
        #expect(h.env.legacy.finding == LegacyFinding.none)
        #expect(await eventually { h.env.ui.connection.legacyHelperRemoval == .removed(leftNetworkState: false) && h.env.ui.connection.legacyHelper == nil })
        h.env.ui.actions.dismissOldHelperRemoval()
        #expect(await eventually { h.env.ui.connection.legacyHelperRemoval == nil })
        // Idempotent: nothing left to remove, no second administrator prompt.
        await h.env.legacy.removeHelper()
        #expect(runner.runs == 1)
        #expect(!sys.fileExists(LegacyAppDetector.helperPlist))
    }

    @Test("F1: never while the old helper has a live tunnel (§4.5): refused before any prompt")
    func theRemovalIsRefusedWhileTheOldTunnelIsUp() async {
        let (h, _, runner) = removalHarness(answer: .finished(output: "LP_RESULT=removed"), probe: .reachable(active: true, killSwitchBlocked: true))
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        #expect(!h.env.legacy.canRemoveHelper)
        await h.env.legacy.removeHelper()
        #expect(h.env.legacy.removal == .failed(.busy))
        #expect(runner.runs == 0)
        #expect(LegacyHelperCopy.removalProblem(.failed(.busy)).contains("Disconnect in the old LockPlus"))
    }

    @Test("F1: cancelled, refused as root, not the Go helper, incomplete, failed to run: each says so; the helper stays")
    func everyFailureIsReported() async {
        let cases: [(PrivilegedRunResult, Set<String>?, LegacyHelperRemovalState)] = [
            (.cancelled, nil, .cancelled),
            (.finished(output: "LP_RESULT=busy"), nil, .failed(.busy)),
            (.finished(output: "LP_RESULT=not-go-binary"), nil, .failed(.notTheOldHelper)),
            (.finished(output: "LP_RESULT=not-go-plist"), nil, .failed(.notTheOldHelper)),
            (.finished(output: "LP_RESULT=still-running"), nil, .failed(.incomplete)),
            (.finished(output: "garbage"), nil, .failed(.incomplete)),
            (.finished(output: "LP_RESULT=removed"), [LegacyAppDetector.helperPlist], .failed(.incomplete)),   // verified, not trusted
            (.failed("execution error (-60005)"), nil, .failed(.couldNotRun("execution error (-60005)"))),
        ]
        for (answer, leaves, expected) in cases {
            let (h, _, runner) = removalHarness(answer: answer, leaves: leaves ?? [LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary])
            await h.env.legacy.refresh()
            await h.env.legacy.removeHelper()
            #expect(h.env.legacy.removal == expected, "\(answer)")
            #expect(runner.runs == 1)
            #expect(h.env.legacy.finding == .helperIdle)                 // still installed: the banner offers Try Again
            #expect(!LegacyHelperCopy.removalProblem(expected).isEmpty)
            h.dir.cleanup()
        }
    }

    @Test("F1: removed, but the helper left its DNS journal or pf marker: restart to clear")
    func aRemovalThatLeftNetworkStateSaysRestart() async {
        let (h, _, _) = removalHarness(answer: .finished(output: "LP_RESULT=removed-left-state"), leaves: [LegacyAppDetector.dnsJournal])
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        await h.env.legacy.removeHelper()
        #expect(h.env.legacy.removal == .removed(leftNetworkState: true))
        #expect(h.env.legacy.finding == .leftoverState)
        #expect(LegacyHelperCopy.removed(leftNetworkState: true).contains("restart your Mac"))
        #expect(LegacyFinding.leftoverState.message?.contains("uninstaller") == false)
    }

    // MARK: F4 an interrupted migration is resumed; the import is reachable any time

    /// A login keychain whose read is where E2E-5 killed the app: it records migration.json at that moment.
    final class ProbingKeychain: LegacyKeychainReading {
        let marker: URL
        let seen = Mutex<[MigrationMarker?]>([])
        init(marker: URL) { self.marker = marker }
        func list() async -> LegacyKeychainListing {
            LegacyKeychainListing(items: [LegacyKeychainItem(service: LegacyKeychain.serviceNames[0], account: "office")])
        }
        func read(_ item: LegacyKeychainItem) async -> Result<[UInt8], LegacyKeychainReadError> {
            let m = AtomicFile.loadJSON(MigrationMarker.self, from: marker)
            seen.withLock { $0.append(m) }
            return .success(Array(("b64:" + Data("alice\npw".utf8).base64EncodedString()).utf8))
        }
    }

    @Test("F4: while the saved-password prompt is up, migration.json already records the profiles (incomplete)")
    func progressIsPersistedBeforeThePasswordPrompt() async throws {
        let dir = TestDir()
        let kc = ProbingKeychain(marker: dir.data.migration)
        let h = Harness(goSource: { GoDirFixture.mixed }, legacyKeychain: kc, dir: dir)
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        _ = await h.env.migrator.run(selected: Set(offer.profileNames), includeSavedPasswords: true)
        let atPrompt = try #require(kc.seen.withLock { $0.first } ?? nil)
        #expect(atPrompt.complete == false)
        #expect(Set(atPrompt.items.compactMap(\.newID)) == Set(h.env.profiles.profiles.map(\.id)))
        let done = try #require(await h.env.files?.loadMigrationMarker())
        #expect(done.complete && done.steps.isEmpty)
    }

    @Test("Review F4-1: the incomplete marker is on disk before the first profile is created")
    func theMarkerPrecedesTheFirstProfile() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        let url = h.env.dataDirectory.migration
        final class Box { var seen = false; var marker: MigrationMarker? }
        let box = Box()
        h.managers.onSave = { _ in
            if !box.seen { box.seen = true; box.marker = AtomicFile.loadJSON(MigrationMarker.self, from: url) }
        }
        _ = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(box.seen)
        let m = try #require(box.marker)
        #expect(m.complete == false && m.items.isEmpty)
    }

    @Test("Review F4-1: profiles imported by hand (no marker) are not an interrupted migration")
    func handImportedProfilesAreNotAResume() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        try await h.add("home.conf", PreviewSeed.nasConf)
        let offer = try #require(await h.env.migrator.detect())
        #expect(!offer.finishesEarlierImport && offer.profileNames == ["office"])
        h.env.settings.update { $0.onboardingComplete = true }
        h.env.ui.onboarding.migration = nil
        await h.env.offerToFinishMigration()
        #expect(!h.env.ui.onboarding.migrationResumePending)            // no "finish" banner
    }

    @Test("Review F4-1: finishing adds what's missing and overwrites no setting")
    func finishingDoesNotOverwriteSettings() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        let home = try await h.add("home.conf", PreviewSeed.nasConf)
        let office = try await h.add("office.ovpn", PreviewSeed.officeOvpn)
        await h.env.files?.save(marker: MigrationMarker(completedAt: Date(), source: "~/x", items: [.init(oldName: "home", newID: home.id, digest: home.payloadDigest, result: "imported")],
                                                        complete: false))
        h.env.settings.update {
            $0.language = .de
            $0.menuBarIconStyle = .monochrome
            $0.autoConnect.profileID = office.id
            $0.autoConnect.trustedSSIDs = ["Mine"]
        }
        let offer = try #require(await h.env.migrator.detect())
        #expect(offer.finishesEarlierImport)
        _ = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(h.env.settings.value.language == .de && h.env.settings.value.menuBarIconStyle == .monochrome)
        #expect(h.env.settings.value.autoConnect.profileID == office.id)
        #expect(h.env.settings.value.autoConnect.trustedSSIDs == ["Mine", "HomeNet"])
        #expect(await eventually { h.env.history.contains { $0.profileID == home.id } })
        #expect(await h.env.files?.loadMigrationMarker()?.complete == true)
    }

    @Test("F4: an incomplete marker resumes: the missing profile, then the steps that never ran, once")
    func anIncompleteMarkerResumes() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        let home = try await h.add("home.conf", PreviewSeed.nasConf)
        await h.env.files?.save(marker: MigrationMarker(completedAt: Date(), source: "~/x", items: [.init(oldName: "home", newID: home.id, digest: home.payloadDigest, result: "imported")],
                                                        complete: false, steps: ["history"]))
        let offer = try #require(await h.env.migrator.detect())
        #expect(offer.finishesEarlierImport && offer.profileNames == ["office"])
        _ = await h.env.migrator.run(selected: ["office"])
        #expect(h.env.profiles.profiles.count == 2)
        #expect(h.env.settings.value.autoConnect.profileID == home.id)
        #expect(h.env.history.isEmpty)                                     // the history step had run: not appended twice
        #expect(await h.env.files?.loadMigrationMarker()?.complete == true)
    }

    @Test("F4: a manual re-run after a finished migration imports profiles only; settings changed since stay")
    func aManualReRunDoesNotOverwriteSettings() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        let first = try #require(await h.env.migrator.detect())
        _ = await h.env.migrator.run(selected: ["home"])                  // office skipped the first time
        h.env.settings.update { $0.autoConnect.enabled = false; $0.autoConnect.trustedSSIDs = [] }
        let again = try #require(await h.env.migrator.detect(force: true))
        #expect(!again.finishesEarlierImport && again.profileNames == ["office"])
        _ = await h.env.migrator.run(selected: ["office"])
        #expect(h.env.profiles.profiles.count == 2)
        #expect(!h.env.settings.value.autoConnect.enabled && h.env.settings.value.autoConnect.trustedSSIDs.isEmpty)
        _ = first
    }

    @Test("F4: skipping in onboarding isn't final: Settings › Advanced finds the offer any time")
    func theImportIsReachableFromSettings() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        h.env.settings.update { $0.onboardingComplete = true }
        h.env.ui.actions.findOldLockPlusData()
        #expect(await eventually { h.env.ui.onboarding.migration?.profileNames.sorted() == ["home", "office"] })
        #expect(!h.env.ui.onboarding.migrationChecking)
        h.env.ui.actions.importMigration(["home", "office"], includingSavedPasswords: false)
        #expect(await eventually { h.env.ui.onboarding.migrationReport != nil })
        h.env.ui.actions.closeMigration()
        #expect(h.env.ui.onboarding.migration == nil && h.env.ui.onboarding.migrationReport == nil)
        h.env.ui.actions.findOldLockPlusData()                             // everything imported: nothing to offer
        #expect(await eventually { !h.env.ui.onboarding.migrationChecking })
        #expect(h.env.ui.onboarding.migration == nil)
    }

    @Test("F4: after onboarding, an unfinished migration shows the Finish banner, which opens the sheet")
    func theFinishBannerAppearsAtLaunch() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        let home = try await h.add("home.conf", PreviewSeed.nasConf)
        await h.env.files?.save(marker: MigrationMarker(completedAt: Date(), source: "~/x", items: [.init(oldName: "home", newID: home.id, digest: home.payloadDigest, result: "imported")],
                                                        complete: false))
        h.env.settings.update { $0.onboardingComplete = true }
        await h.env.offerToFinishMigration()
        #expect(h.env.ui.onboarding.migrationResumePending)
        #expect(h.env.ui.onboarding.migration?.finishesEarlierImport == true)
        h.env.ui.onboarding.migrationSheetPresented = true
        #expect(MainSheet.active(in: h.env.ui)?.id == "migration")
    }

    @Test("F4: migration.json from before (no complete flag) still counts as complete")
    func anOldMarkerIsComplete() throws {
        let json = #"{"completedAt":"2026-11-01T10:00:00Z","source":"~/Library/Application Support/lockplus","items":[]}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let m = try d.decode(MigrationMarker.self, from: Data(json.utf8))
        #expect(m.complete && m.steps.isEmpty)
    }

    // MARK: F5 LockPlus 1.0.x's LaunchAgent; a second instance at login quits silently

    static func goAgent(label: String = LegacyLaunchAgent.label, program: String = "/Applications/LockPlus.app/Contents/MacOS/lockplus") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Label</key><string>\(label)</string><key>ProgramArguments</key><array><string>\(program)</string></array>
        <key>RunAtLoad</key><true/></dict></plist>
        """.utf8)
    }

    /// A home folder with `Library/LaunchAgents` (under the test directory, never the real home).
    static func home(_ dir: TestDir, agent: Data?) throws -> String {
        let home = dir.url.appending(path: "home", directoryHint: .isDirectory)
        let agents = home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        if let agent { try agent.write(to: LegacyLaunchAgent.url(home: home.path)) }
        return home.path
    }

    @Test("F5: only the Go agent (its label, a …/Contents/MacOS/lockplus program, a regular file) is removed")
    func onlyTheGoAgentIsRetired() throws {
        #expect(LegacyLaunchAgent.isGoAgent(Self.goAgent()))
        #expect(!LegacyLaunchAgent.isGoAgent(Self.goAgent(label: "com.example.other")))
        #expect(!LegacyLaunchAgent.isGoAgent(Self.goAgent(program: "/usr/local/bin/lockplus")))
        #expect(!LegacyLaunchAgent.isGoAgent(Data("not a plist".utf8)))
        let dir = TestDir()
        defer { dir.cleanup() }
        let home = try Self.home(dir, agent: Self.goAgent())
        #expect(LegacyLaunchAgent.retire(home: home))
        #expect(!FileManager.default.fileExists(atPath: LegacyLaunchAgent.url(home: home).path))
        #expect(!LegacyLaunchAgent.retire(home: home))                     // idempotent
        let other = try Self.home(TestDir(), agent: Self.goAgent(label: "com.example.other"))
        #expect(!LegacyLaunchAgent.retire(home: other))
        #expect(FileManager.default.fileExists(atPath: LegacyLaunchAgent.url(home: other).path))
        try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: other).deletingLastPathComponent().path)
        // A symlink is never followed or removed.
        let linkHome = try Self.home(dir, agent: nil)
        let target = dir.url.appending(path: "target.plist")
        try Self.goAgent().write(to: target)
        try FileManager.default.createSymbolicLink(at: LegacyLaunchAgent.url(home: linkHome), withDestinationURL: target)
        #expect(!LegacyLaunchAgent.retire(home: linkHome))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("F5: at launch the old agent is retired and LockPlus's own launch at login is offered, never registered")
    func theOldAgentIsRetiredAtLaunchWithAnOffer() throws {
        let dir = TestDir()
        let home = try Self.home(dir, agent: Self.goAgent())
        let h = Harness(dir: dir, agentHome: home)
        defer { h.dir.cleanup() }
        #expect(h.env.retireGoLaunchAgent())
        #expect(!FileManager.default.fileExists(atPath: LegacyLaunchAgent.url(home: home).path))
        #expect(h.env.ui.settings.launchAtLoginOffer)
        #expect(!h.hooks.calls.contains { $0.hasPrefix("launchAtLogin") })   // offered, not registered
    }

    @Test("F5: a second instance started by the old agent or as a login item quits silently; otherwise it says so")
    func aSecondInstanceAtLoginQuitsSilently() async throws {
        for quiet in [LaunchContext(byGoLaunchAgent: true), LaunchContext(asLoginItem: true), LaunchContext()] {
            let dir = TestDir()
            let home = try Self.home(dir, agent: Self.goAgent())
            let h = Harness(dir: dir, agentHome: home)
            try FileManager.default.createDirectory(at: h.env.dataDirectory.root, withIntermediateDirectories: true)
            let held = try #require(InstanceLock.tryAcquire(at: h.env.dataDirectory.instanceLock))   // the first instance
            h.env.launchContext = quiet
            await h.env.acquireInstanceLock(attempts: 1, interval: .zero)
            if quiet.quietIfAlreadyRunning {
                #expect(h.hooks.calls.contains("quitSilently") && !h.hooks.calls.contains("alreadyRunning"))
                #expect(!FileManager.default.fileExists(atPath: LegacyLaunchAgent.url(home: home).path))
            } else {
                #expect(h.hooks.calls.contains("alreadyRunning") && !h.hooks.calls.contains("quitSilently"))
            }
            _ = held
            h.dir.cleanup()
        }
    }

    @Test("F5: the migration report offers launch at login; Go 1.1's login item gets an explanation")
    func theReportOffersLaunchAtLogin() async throws {
        // auto_start on and no agent (Go 1.1: SMAppService): offer + the Login Items note.
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        _ = try #require(await h.env.migrator.detect())
        let r = await h.env.migrator.run(selected: ["home", "office"])
        #expect(r.offerLaunchAtLogin)
        #expect(r.notes.contains { $0.contains("Login Items") })
        // Go 1.0.x: the agent existed (retired now): offer, no Login Items note.
        let dir = TestDir()
        let home = try Self.home(dir, agent: Self.goAgent())
        let h2 = Harness(goSource: { GoDirFixture.mixed }, dir: dir, agentHome: home)
        defer { h2.dir.cleanup() }
        _ = try #require(await h2.env.migrator.detect())
        let r2 = await h2.env.migrator.run(selected: ["home"])
        #expect(r2.offerLaunchAtLogin)
        #expect(!r2.notes.contains { $0.contains("Login Items") })
        #expect(!FileManager.default.fileExists(atPath: LegacyLaunchAgent.url(home: home).path))
    }

    @Test("E2E-6 N5: the login-item line only when 2.0 can't know the item is gone")
    func loginItemLineOnlyWhenUnknown() async throws {
        let cases: [(String?, Bool)] = [(nil, true), (#"{"choice":"later"}"#, true), ("not json", true), (#"{"choice":7}"#, true),
                                        (#"{"choice":""}"#, true), (#"{"choice":"moved","updated_at":"2026-11-09T10:00:00Z"}"#, false),
                                        (#"{"choice":"moved"}"#, false)]
        for (farewell, expectLine) in cases {
            var data = GoDirFixture.mixed
            if let farewell { data.data["farewell.json"] = farewell }
            let fx = data
            let h = Harness(goSource: { fx })
            defer { h.dir.cleanup() }
            _ = try #require(await h.env.migrator.detect())
            let r = await h.env.migrator.run(selected: ["home", "office"])
            #expect(r.offerLaunchAtLogin)
            #expect(r.notes.contains { $0.contains("Login Items") } == expectLine, "farewell: \(farewell ?? "none")")
        }
        #expect(!GoAppMigrator.farewellMoved([]))
    }

    // MARK: F6 the whole migration report

    @Test("F6: harmless ignored lines are information, a behaviour change needs attention with its reason")
    func harmlessIgnoredLinesAreInformation() {
        let harmless = ImportReport(items: [ImportReportItem(.ignored, line: 4, directive: "nobind", .localBindingNotUsed),
                                            ImportReportItem(.ignored, line: 9, directive: "verb", .loggingManaged)])
        let a = GoAppMigrator.classify(harmless, engineVerified: true, name: "ovpn-tcp")
        #expect(a.concern == nil)
        #expect(a.info == ["ovpn-tcp: nobind, verb ignored; LockPlus doesn't need these lines."])
        var script = harmless
        script.items.append(ImportReportItem(.ignored, line: 12, directive: "up", .scriptsNeverRun))
        script.items.append(ImportReportItem(.securityWarning, .compressionEnabled))
        let b = GoAppMigrator.classify(script, engineVerified: true, name: "lab")
        #expect(b.concern?.hasPrefix("lab: Line 12, up: scripts never run in LockPlus") == true)
        #expect(b.concern?.contains("1 more") == true)
        let c = GoAppMigrator.classify(ImportReport(), engineVerified: false, name: "x")
        #expect(c.concern == "x: " + ProfileItem.notYetVerifiedExplanation)
    }

    @Test("F6: the report shows the global notes: DNS, the per-network map; OpenVPN with only `verb` is imported")
    func theReportShowsEverything() async throws {
        var fixture = GoDirFixture.mixed
        fixture.tunnels["office.ovpn"] = PreviewSeed.officeOvpn.replacingOccurrences(of: "verb 3", with: "verb 3\nnobind")
        let h = Harness(goSource: { [fixture] in fixture })
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        let r = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(r.imported.sorted() == ["home", "office"])                // not under "Needs attention" for verb/nobind
        #expect(r.needsAttention.isEmpty)
        #expect(r.info.contains { $0.hasPrefix("office: ") && $0.contains("verb") && $0.contains("nobind") })
        #expect(h.env.settings.value.appearance == .dark)                 // the fixture's Go theme
        #expect(r.notes.contains { $0.contains("DNS now always goes through the tunnel") })
        #expect(r.notes.contains { $0.contains("CafeNet → office") })
    }

    // MARK: F7 copy that matches what happens

    @Test("F7: a Go item with the username only imports the username and says the password is asked on connect")
    func aUsernameOnlyItemIsReportedAsSuch() async throws {
        let item = LegacyKeychainItem(service: LegacyKeychain.serviceNames[0], account: "office")
        var kc = FixtureLegacyKeychain(listing: LegacyKeychainListing(items: [item]))
        kc.values[item] = .success(Array(("b64:" + Data("alice".utf8).base64EncodedString()).utf8))     // "Save username"
        let h = Harness(goSource: { GoDirFixture.mixed }, legacyKeychain: kc)
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        #expect(offer.savedPasswords == 1)                                  // counted as a saved sign-in (the UI says so)
        let r = await h.env.migrator.run(selected: Set(offer.profileNames), includeSavedPasswords: true)
        let office = try #require(h.env.profiles.profiles.first { $0.name == "office" })
        let rec = await h.env.profiles.credentialRecord(office.id)
        #expect(rec?.username == Data("alice".utf8) && rec?.password == nil)
        #expect(r.info.contains { $0.hasPrefix("office: the saved username was imported") })
        #expect(!r.needsAttention.contains { $0.contains("office") })
    }

    @Test("F7: no copy promises an uninstaller or the old app's last update")
    func theHelperCopyIsTrue() {
        for f in [LegacyFinding.helperIdle, .leftoverState, .helperCrashedWithFirewall] {
            #expect(f.message?.contains("uninstaller") == false)
        }
        #expect(LegacyFinding.helperIdle.message?.contains("LockPlus can remove it") == true)
    }

    // MARK: Fable review of the E2E-5 fixes (docs/native/reviews/2026-11-09-fable-e2e5.md)

    @Test("Review F1-1: no removal while the old app runs (it would reinstall the helper); offered again once it quits")
    func noRemovalWhileTheOldAppRuns() async {
        let (h, sys, runner) = removalHarness(answer: .finished(output: "LP_RESULT=removed"))
        defer { h.dir.cleanup() }
        sys.setGUIRunning(true)
        h.env.legacy.pollInterval = .milliseconds(20)
        await h.env.legacy.refresh()
        UIBinder.bind(h.env)
        #expect(!h.env.legacy.canRemoveHelper)
        #expect(h.env.ui.connection.legacyHelper?.canRemoveHelper == false)
        #expect(h.env.ui.connection.legacyHelper?.message.contains("Quit the old LockPlus first") == true)
        await h.env.legacy.removeHelper()
        #expect(h.env.legacy.removal == .failed(.oldAppRunning) && runner.runs == 0)
        sys.setGUIRunning(false)                                             // the user quits the old app: the poll notices
        #expect(await eventually { h.env.ui.connection.legacyHelper?.canRemoveHelper == true })
    }

    @Test("Review F1-2 / E2E-6 N1: an unreachable helper's DNS journal is judged as root (stale goes, live refuses)")
    func anUnreplayedDNSJournalRefuses() async {
        let (h, sys, runner) = removalHarness(answer: .finished(output: "LP_RESULT=dns-unrestored"), probe: .unreachable)
        defer { h.dir.cleanup() }
        sys.setFiles([LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary, LegacyAppDetector.dnsJournal])
        await h.env.legacy.refresh()
        // E2E-6 N1: only root can read the journal, so the app no longer refuses on the file alone.
        #expect(h.env.legacy.finding == .helperIdle && h.env.legacy.canRemoveHelper && h.env.legacy.dnsJournalUnreplayed)
        await h.env.legacy.removeHelper()
        #expect(h.env.legacy.removal == .failed(.dnsNotRestored) && runner.runs == 1)
        let copy = LegacyHelperCopy.removalProblem(.failed(.dnsNotRestored), oldAppInstalled: true)
        #expect(copy.contains("System Settings › Network") && copy.contains("Open the old LockPlus once") && copy.contains("restart your Mac"))
        let noApp = LegacyHelperCopy.removalProblem(.failed(.dnsNotRestored), oldAppInstalled: false)
        #expect(!noApp.contains("Open the old LockPlus") && noApp.contains("try again") && noApp.contains("restart your Mac"))
        #expect(LegacyHelperCopy.removed(leftNetworkState: true).contains("System Settings › Network"))
        // The script's own refusal maps the same way.
        let (h2, _, _) = removalHarness(answer: .finished(output: "LP_RESULT=dns-unrestored"))
        defer { h2.dir.cleanup() }
        await h2.env.legacy.refresh()
        await h2.env.legacy.removeHelper()
        #expect(h2.env.legacy.removal == .failed(.dnsNotRestored))
    }

    @Test("Review F1-6: removeHelper enforces the button's rule (crashed helper with its firewall: refused)")
    func removeHelperEnforcesTheRule() async {
        let (h, sys, runner) = removalHarness(answer: .finished(output: "LP_RESULT=removed"), probe: .unreachable)
        defer { h.dir.cleanup() }
        sys.setFiles([LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary, LegacyAppDetector.pfWasEnabled])
        await h.env.legacy.refresh()
        #expect(h.env.legacy.finding == .helperCrashedWithFirewall)
        await h.env.legacy.removeHelper()
        #expect(h.env.legacy.removal == .failed(.busy) && runner.runs == 0)
    }

    @Test("Review F1-4: the in-process runner passes script and prompt as event parameters of a constant handler")
    func theInProcessRunnerUsesEventParameters() throws {
        let src = InProcessAppleScriptRunner.source
        #expect(!src.contains("io.github") && !src.contains("\\("))         // no script text, no interpolation in the source
        #expect(src.contains("do shell script theScript with prompt thePrompt with administrator privileges"))
        let e = InProcessAppleScriptRunner.event(script: "S", prompt: "P")
        #expect(e.eventClass == AEEventClass(kASAppleScriptSuite) && e.eventID == AEEventID(kASSubroutineEvent))
        #expect(e.paramDescriptor(forKeyword: AEKeyword(keyASSubroutineName))?.stringValue == InProcessAppleScriptRunner.handlerName)
        let params = try #require(e.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        #expect(params.numberOfItems == 2 && params.atIndex(1)?.stringValue == "S" && params.atIndex(2)?.stringValue == "P")
        #expect(NSAppleScript(source: src)?.compileAndReturnError(nil) == true)   // compiles; never executed in tests
        #expect(InProcessAppleScriptRunner.result(nil, error: [NSAppleScript.errorNumber: -128]) == .cancelled)
        #expect(InProcessAppleScriptRunner.result(nil, error: [NSAppleScript.errorNumber: -60005, NSAppleScript.errorMessage: "denied"]) == .failed("denied"))
        // Fable pre-release A-2: every execution error is the answer (no osascript fallback, no second dialog).
        #expect(InProcessAppleScriptRunner.result(nil, error: [NSAppleScript.errorNumber: -1708]) == .failed("AppleScript error -1708"))
        #expect(InProcessAppleScriptRunner.result(NSAppleEventDescriptor(string: "LP_RESULT=removed"), error: nil) == .finished(output: "LP_RESULT=removed"))
    }
}
