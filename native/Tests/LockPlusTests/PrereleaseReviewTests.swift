import AppKit
import Foundation
import LPModel
import LPParsing
import LPWire
import Security
import Synchronization
import SwiftUI
import Testing
@testable import LockPlus

/// The pre-release review of 2.0 (docs/native/reviews/2026-11-09-opus-prerelease.md): M1–M4, M6 and the migration
/// resume LOWs. Fixtures and fakes only: never the Go app's real data, never a privileged command.
@MainActor @Suite("Pre-release review", .serialized, .timeLimit(.minutes(1)))
struct PrereleaseReviewTests {
    /// A Go source that counts how often it is opened (M3: no Go data is read without an unfinished migration).
    final class CountingSource: Sendable {
        let opened = Mutex(0)
        let fixture: GoDirFixture
        init(_ fixture: GoDirFixture) { self.fixture = fixture }
        var source: @Sendable () -> (any GoAppDataSource)? { { [self] in opened.withLock { $0 += 1 }; return fixture } }
        var count: Int { opened.withLock { $0 } }
    }

    // MARK: M1 one migration at a time

    @Test("M1: two runs at once create every profile once; the second run does nothing")
    func twoRunsAtOnceImportOnce() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        let names = Set(offer.profileNames)
        let first = Task { await h.env.migrator.run(selected: names) }
        let second = Task { await h.env.migrator.run(selected: names) }
        let (a, b) = await (first.value, second.value)
        #expect(h.env.profiles.profiles.map(\.name).sorted() == ["home", "office"])
        let reported = [a, b].map { ($0.imported + $0.needsAttention).count }
        #expect(reported.sorted() == [0, 2], "\(reported)")
        #expect(!h.env.migrator.isRunning)
    }

    @Test("M1: Import is ignored while a run is in flight, and the Settings re-scan waits for it")
    func importAndRescanAreBlockedWhileRunning() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        h.env.settings.update { $0.onboardingComplete = true }
        let offer = try #require(await h.env.migrator.detect())
        let ob = h.env.ui.onboarding
        h.env.ui.actions.importMigration(Set(offer.profileNames), includingSavedPasswords: false)
        #expect(ob.migrationRunning)                                       // set before the run's first await
        h.env.ui.actions.importMigration(Set(offer.profileNames), includingSavedPasswords: false)   // the double-click
        h.env.ui.actions.findOldLockPlusData()
        #expect(!ob.migrationChecking)                                     // bailed out: no re-scan replaces the running plan
        #expect(await eventually { ob.migrationReport != nil && !ob.migrationRunning })
        #expect(h.env.profiles.profiles.count == 2)
        #expect(await h.env.migrator.detect(force: true) == nil)            // nothing left: no "Work 2"
    }

    // MARK: M2 a run where profiles failed doesn't complete

    @Test("M2: every create failed: no settings, Wi-Fi rules or history, the marker stays incomplete; Finish applies them once")
    func failedCreatesLeaveTheMigrationIncomplete() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        h.keychain.failure.withLock { $0 = errSecInteractionNotAllowed }   // every profile write fails
        let r = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(r.notMigrated.sorted() == ["home", "office"])
        #expect(r.notes.contains { $0.contains("Finish Import") })
        #expect(h.env.profiles.profiles.isEmpty)
        #expect(h.env.settings.value.autoConnect.profileID == nil && h.env.settings.value.autoConnect.trustedSSIDs.isEmpty)
        #expect(h.env.history.isEmpty)
        let marker = try #require(await h.env.files?.loadMigrationMarker())
        #expect(!marker.complete && !marker.did(.settings) && !marker.did(.history))
        // The cause is gone; "Finish Import" retries the profiles, then applies everything.
        h.keychain.failure.withLock { $0 = nil }
        let resume = try #require(await h.env.migrator.detect())
        #expect(resume.finishesEarlierImport && Set(resume.profileNames) == ["home", "office"])
        _ = await h.env.migrator.run(selected: Set(resume.profileNames))
        let home = try #require(h.env.profiles.profiles.first { $0.name == "home" })
        #expect(h.env.profiles.profiles.count == 2)
        #expect(h.env.settings.value.autoConnect.profileID == home.id && h.env.settings.value.autoConnect.trustedSSIDs == ["HomeNet"])
        #expect(await eventually { h.env.history.count == 1 })
        let done = try #require(await h.env.files?.loadMigrationMarker())
        #expect(done.complete)
        // Review LOW: the retried tunnels replaced their "error:…" items instead of adding a second item each.
        #expect(done.items.map(\.oldName).sorted() == ["home", "office"], "\(done.items)")
        #expect(!done.items.contains { $0.result.hasPrefix("error:") })
    }

    @Test("M2: the Settings import doesn't scan while the profiles are locked")
    func noRescanWhileLocked() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf)
        try await h.keychain.delete(service: KeychainServices.payloadKey, account: "v1")
        await h.env.profiles.repository.resetKeyCache()
        await h.env.profiles.load()
        #expect(h.env.profiles.locked == ["Work"])
        h.env.ui.actions.findOldLockPlusData()
        #expect(!h.env.ui.onboarding.migrationChecking && h.env.ui.onboarding.migration == nil)
        let parent = h.dir.data.profiles.deletingLastPathComponent()
        for f in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix("profiles-locked-") { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: M3 no launch-time scan, no kept plan

    @Test("M3: at launch the Go data is read only for an unfinished migration")
    func launchReadsGoDataOnlyForAnUnfinishedMigration() async throws {
        let src = CountingSource(GoDirFixture.mixed)
        let h = Harness(goSource: src.source)
        defer { h.dir.cleanup() }
        h.env.settings.update { $0.onboardingComplete = true }
        await h.env.offerToFinishMigration()                               // no marker: the user skipped the import
        #expect(src.count == 0 && h.env.migrator.plan == nil)
        await h.env.files?.save(marker: MigrationMarker(completedAt: Date(), source: "~/x", items: []))
        await h.env.offerToFinishMigration()                               // a complete marker
        #expect(src.count == 0 && h.env.migrator.plan == nil)
        await h.env.files?.save(marker: MigrationMarker(completedAt: Date(), source: "~/x", items: [], complete: false))
        await h.env.offerToFinishMigration()
        #expect(src.count == 1 && h.env.ui.onboarding.migrationResumePending)
    }

    @Test("M3: closing the sheet drops the plan (private keys); importing the kept offer reads the data again")
    func closingDropsThePlan() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        h.env.ui.onboarding.migration = offer
        #expect(h.env.migrator.plan != nil)
        h.env.ui.actions.closeMigration()                                  // Cancel: the offer stays for the banner
        #expect(h.env.migrator.plan == nil && h.env.migrator.legacyListing == LegacyKeychainListing())
        #expect(h.env.ui.onboarding.migration == offer)
        h.env.ui.actions.importMigration(Set(offer.profileNames), includingSavedPasswords: false)
        #expect(await eventually { h.env.ui.onboarding.migrationReport != nil })
        #expect(h.env.profiles.profiles.count == 2)
        #expect(h.env.migrator.plan == nil)                                // and dropped after the run
    }

    // MARK: M4 one removal at a time

    /// A helper probe that suspends like the real socket read (the fixture answers without suspending).
    struct SuspendingLegacySystem: LegacySystemReading {
        let inner: SwitchableLegacySystem
        func fileExists(_ path: String) -> Bool { inner.fileExists(path) }
        func probeHelper() async -> HelperProbe { await Task.yield(); return await inner.probeHelper() }
        @MainActor func goGUIRunning() -> Bool { inner.goGUIRunning() }
    }

    @Test("M4: a double-click on Remove Old Helper asks for the administrator password once")
    func removeHelperRunsOnce() async {
        let sys = SwitchableLegacySystem(files: [LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary],
                                         probe: .reachable(active: false, killSwitchBlocked: false))
        let runner = FakePrivilegedRunner(answer: .finished(output: "LP_RESULT=removed\n")) { sys.setFiles([]) }
        let h = Harness(legacySystem: SuspendingLegacySystem(inner: sys), legacyHelperRunner: runner)
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        // The second click is queued while the first awaits its re-read (before its administrator prompt).
        let second = Task { await h.env.legacy.removeHelper() }
        await h.env.legacy.removeHelper()
        await second.value
        #expect(runner.runs == 1)
        #expect(h.env.legacy.removal == .removed(leftNetworkState: false))
        await h.env.legacy.removeHelper()                                  // the guard was reset: a later call runs again
        #expect(runner.runs == 1)                                          // (nothing left to remove: no prompt)
    }

    @Test("Review LOW: with no helper left, Remove doesn't claim it removed one")
    func noHelperIsNotRemoved() async {
        let (h, sys, runner) = E2E5FixTests().removalHarness(answer: .finished(output: "LP_RESULT=removed\n"))
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        sys.setFiles([])                                                   // the Go 1.2 "Farewell" removed it meanwhile
        await h.env.legacy.removeHelper()
        #expect(h.env.legacy.removal == nil && runner.runs == 0)
        #expect(h.env.legacy.finding == LegacyFinding.none)
    }

    // MARK: Gate LOWs

    @Test("Review LOW: the crashed-helper warning clears when the finding ends; a deleted profile's strip goes too")
    func theWarnGateClears() async throws {
        let sys = SwitchableLegacySystem(files: [LegacyAppDetector.helperPlist, LegacyAppDetector.pfWasEnabled], probe: .unreachable)
        let h = Harness(legacySystem: sys)
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        UIBinder.bind(h.env)
        h.env.ui.gatedConnect(p.id)
        #expect(await eventually { h.env.ui.connection.connectGate == .warn(p.id) })
        sys.setFiles([])                                                   // the leftovers are gone
        await h.env.legacy.refresh()
        #expect(await eventually { h.env.ui.connection.connectGate == nil })
        // A warning for a profile that is then deleted: no Connect Anyway with a dead id.
        sys.setFiles([LegacyAppDetector.helperPlist, LegacyAppDetector.pfWasEnabled])
        h.env.ui.gatedConnect(p.id)
        #expect(await eventually { h.env.ui.connection.connectGate == .warn(p.id) })
        try await h.env.profiles.delete(p.id)
        #expect(await eventually { h.env.ui.connection.connectGate == nil })
    }

    @Test("Review LOW: each new gate is announced (the strip's announcement follows the gate, not its appearance)")
    func gateAnnouncements() {
        #expect(ConnectGateStrip.announcement(.refused(UUID())) == LegacyHelperCopy.refuseTitle)
        #expect(ConnectGateStrip.announcement(.warn(UUID())) == LegacyHelperCopy.warnTitle)
    }

    // MARK: Migration resume LOWs

    @Test("Resume LOW: language, log level and icon style arrive on resume while they are still LockPlus's defaults")
    func resumeFillsDefaultedSettings() async throws {
        var fixture = GoDirFixture.mixed
        fixture.data["config.json"] = #"{"language":"de","log_level":"debug","tray_icon_style":"mono","auto_start":false}"#
        let h = Harness(goSource: { [fixture] in fixture })
        defer { h.dir.cleanup() }
        await h.env.files?.save(marker: MigrationMarker(completedAt: Date(), source: "~/x", items: [], complete: false))
        let offer = try #require(await h.env.migrator.detect())
        #expect(offer.finishesEarlierImport)
        h.env.settings.update { $0.logLevel = .error }                     // changed by the user since: kept
        _ = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(h.env.settings.value.language == .de)
        #expect(h.env.settings.value.menuBarIconStyle == .monochrome)
        #expect(h.env.settings.value.logLevel == .error)
    }

    @Test("Appearance: the old theme arrives on resume only while the appearance is still the default")
    func resumeFillsAppearanceOnlyOverTheDefault() async throws {
        var fixture = GoDirFixture.mixed
        fixture.data["config.json"] = #"{"theme":"dark","auto_start":false}"#
        for (changed, expected) in [(false, AppSettings.Appearance.dark), (true, .light)] {
            let h = Harness(goSource: { [fixture] in fixture })
            defer { h.dir.cleanup() }
            await h.env.files?.save(marker: MigrationMarker(completedAt: Date(), source: "~/x", items: [], complete: false))
            let offer = try #require(await h.env.migrator.detect())
            if changed { h.env.settings.update { $0.appearance = .light } }
            _ = await h.env.migrator.run(selected: Set(offer.profileNames))
            #expect(h.env.settings.value.appearance == expected)
        }
    }

    @Test("Resume LOW: a profile the earlier run created and the user edited since isn't imported again")
    func anEditedProfileIsNotDuplicated() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        let home = try await h.add("home.conf", PreviewSeed.nasConf)
        await h.env.files?.save(marker: MigrationMarker(completedAt: Date(), source: "~/x", items: [.init(oldName: "home", newID: home.id, digest: home.payloadDigest, result: "imported")],
                                                        complete: false))
        // The user edits it (a new payload, so another digest).
        let edited = PreviewSeed.nasConf.replacingOccurrences(of: "Address = 10.9.0.2/32", with: "Address = 10.9.0.3/32")
        #expect(edited != PreviewSeed.nasConf)
        let a = await ImportCoordinator.analyse(fileName: "home.conf", bytes: Array(edited.utf8), service: h.service, probe: NullProbe())
        let d = try #require(h.env.importer.draft(a, name: "home", killSwitch: home.policy.killSwitch, allowLAN: false))
        _ = try await h.env.profiles.replacePayload(home.id, with: d)
        #expect(h.env.profiles.profile(home.id)?.payloadDigest != home.payloadDigest)
        let offer = try #require(await h.env.migrator.detect())
        #expect(offer.profileNames == ["office"])                          // "home" is the earlier run's, by its marker item
        _ = await h.env.migrator.run(selected: ["home", "office"])
        #expect(h.env.profiles.profiles.map(\.name).sorted() == ["home", "office"])
        #expect(h.env.settings.value.autoConnect.profileID == home.id)     // mapped to the edited profile
    }

    @Test("Resume LOW: a kill after the history was appended (before the marker) doesn't duplicate it")
    func historyIsNotDuplicatedOnResume() async throws {
        let h = Harness(goSource: { GoDirFixture.mixed })
        defer { h.dir.cleanup() }
        let offer = try #require(await h.env.migrator.detect())
        _ = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(await eventually { h.env.history.count == 1 })
        // As if the app had died between the history append and the marker save.
        var marker = try #require(await h.env.files?.loadMigrationMarker())
        marker.complete = false
        marker.steps = ["credentials", "settings"]
        await h.env.files?.save(marker: marker)
        let resume = try #require(await h.env.migrator.detect())
        #expect(resume.finishesEarlierImport)
        _ = await h.env.migrator.run(selected: Set(resume.profileNames))
        #expect(h.env.history.count == 1)
        #expect(await h.env.files?.loadMigrationMarker()?.complete == true)
        // Stable: the same Go entry always gets the same ID; another entry another one.
        let plan = try GoMigrationReader.read(GoDirFixture.mixed, existingDigests: [], digest: PayloadDigest.sha256Hex)
        let s = try #require(plan.history.first)
        var t = s
        t.rxBytes = 3
        #expect(GoAppMigrator.stableID(s) == GoAppMigrator.stableID(s) && GoAppMigrator.stableID(s) != GoAppMigrator.stableID(t))
    }

    @Test("Resume LOW: a profile created by the resumed run still gets its saved sign-in")
    func credentialsReachProfilesCreatedOnResume() async throws {
        let item = LegacyKeychainItem(service: LegacyKeychain.serviceNames[0], account: "office")
        var kc = FixtureLegacyKeychain(listing: LegacyKeychainListing(items: [item]))
        kc.values[item] = .success(Array(("b64:" + Data("alice\npw".utf8).base64EncodedString()).utf8))
        let h = Harness(goSource: { GoDirFixture.mixed }, legacyKeychain: kc)
        defer { h.dir.cleanup() }
        let home = try await h.add("home.conf", PreviewSeed.nasConf)
        // The earlier run created "home" and finished the sign-in step; "office" was never created.
        await h.env.files?.save(marker: MigrationMarker(completedAt: Date(), source: "~/x", items: [.init(oldName: "home", newID: home.id, digest: home.payloadDigest, result: "imported")],
                                                        complete: false, steps: ["credentials"]))
        let offer = try #require(await h.env.migrator.detect())
        #expect(offer.finishesEarlierImport && offer.profileNames == ["office"])
        _ = await h.env.migrator.run(selected: ["office"], includeSavedPasswords: true)
        let office = try #require(h.env.profiles.profiles.first { $0.name == "office" })
        let rec = await h.env.profiles.credentialRecord(office.id)
        #expect(rec?.username == Data("alice".utf8) && rec?.password == Data("pw".utf8))
    }

    // MARK: Launch at login offer

    @Test("Review LOW: the launch-at-login offer is persisted until answered")
    func theLaunchAtLoginOfferPersists() throws {
        let dir = TestDir()
        let home = try E2E5FixTests.home(dir, agent: E2E5FixTests.goAgent())
        let h = Harness(dir: dir, agentHome: home)
        defer { h.dir.cleanup() }
        #expect(h.env.retireGoLaunchAgent())
        #expect(h.env.settings.value.launchAtLoginOffer)                  // in settings.json, not only in memory
        // A relaunch reads it back into the UI.
        let s = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(h.env.settings.value))
        #expect(s.launchAtLoginOffer)
        let m = SettingsUIModel()
        UIMapping.apply(s, to: m)
        #expect(m.launchAtLoginOffer)
        // Answering clears it.
        m.launchAtLoginOffer = false
        var back = s
        UIMapping.read(m, into: &back)
        #expect(!back.launchAtLoginOffer)
    }

    // MARK: Sidebar and strips

    @Test("Review LOW: the sidebar selection ink applies only on the emphasised selection in our own accent")
    func sidebarInk() throws {
        #expect(SidebarInk.usesAccentInk(prominence: .increased, active: .key, selectionIsAppAccent: true))
        #expect(!SidebarInk.usesAccentInk(prominence: .increased, active: .key, selectionIsAppAccent: false))   // the user's accent: system text
        #expect(!SidebarInk.usesAccentInk(prominence: .standard, active: .key, selectionIsAppAccent: true))
        #expect(!SidebarInk.usesAccentInk(prominence: .increased, active: .inactive, selectionIsAppAccent: true))   // grey unfocused selection
        let accent = try #require(NSColor(named: "AccentColor"))
        #expect(SelectionAppearance.sameColor(accent, accent))
        #expect(!SelectionAppearance.sameColor(.systemBlue, accent))
        #expect(!SelectionAppearance.sameColor(.systemGray, accent))
    }

    @Test("Review LOW: the full-name tooltip only when the name is truncated")
    func tooltipOnlyWhenTruncated() {
        #expect(HelpWhenTruncated.isTruncated(full: 180, shown: 120))
        #expect(!HelpWhenTruncated.isTruncated(full: 80, shown: 80))
        #expect(!HelpWhenTruncated.isTruncated(full: 80.3, shown: 80))
    }

    @Test("Review LOW: a strip whose conditional actions are empty has no actions row (no 8 pt gap)")
    func emptyActionsLeaveNoGap() {
        func height(_ show: Bool) -> CGFloat {
            let v = NSHostingController(rootView: InlineStrip(severity: .info, message: String(repeating: "A long message that wraps. ", count: 8)) {
                if show { Button("OK") {} }
            }.frame(width: 300))
            return v.sizeThatFits(in: CGSize(width: 300, height: 2000)).height
        }
        let plain = NSHostingController(rootView: InlineStrip(severity: .info, message: String(repeating: "A long message that wraps. ", count: 8)).frame(width: 300))
            .sizeThatFits(in: CGSize(width: 300, height: 2000)).height
        #expect(abs(height(false) - plain) < 0.5, "empty \(height(false)) vs none \(plain)")
        #expect(height(true) > plain + 8)
    }

    @Test("Review LOW: the strip keeps its button views when a resize switches between one row and two (focus stays)")
    func stripLayoutKeepsItsViews() {
        // One layout over the same subviews: the plan changes, the views don't (ViewThatFits rebuilt them).
        let l = StripActionsLayout(trailing: true, header: true)
        #expect(l.header && l.trailing)
        #expect(StripActionsLayout.stripButtonGap == 8 && StripActionsLayout.rowButtonGap == 10)
    }

    // MARK: Menu

    @Test("Review LOW: the menu's bold item is matched by identity, not by title")
    func boldByIdentity() throws {
        let menu = NSMenu()
        let enter = NSMenuItem(title: "Enter Code for Work…", action: nil, keyEquivalent: "")
        let twin = NSMenuItem(title: "Enter Code for Work…", action: nil, keyEquivalent: "")   // a profile named like it
        menu.addItem(twin)
        menu.addItem(enter)
        MenuBarController.setMonospaced(menu, bold: enter)
        func weight(_ i: NSMenuItem) -> CGFloat? {
            guard let f = i.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return nil }
            return (f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        }
        let bold = try #require(weight(enter)), regular = try #require(weight(twin))
        #expect(bold > regular)
    }

    // MARK: M6 one focus ring, programmatic focus still works

    @Observable final class FocusBox {
        var target: FocusProbe.Field?
        var reported: FocusProbe.Field?
    }

    struct FocusProbe: View {
        enum Field: Hashable { case name, secret, response }
        let box: FocusBox
        let echo: Bool
        @FocusState private var focus: Field?
        @State private var a = "alpha"
        @State private var b = "bravo"
        @State private var c = "charlie"
        var body: some View {
            VStack {
                TextField("A", text: $a).focused($focus, equals: .name).lpField()
                SecureField("B", text: $b).focused($focus, equals: .secret).lpField()
                // AuthPromptView.responseRow: a TextField or a SecureField in a Group, focused through the Group.
                Group { if echo { TextField("C", text: $c) } else { SecureField("C", text: $c) } }
                    .labelsHidden()
                    .focused($focus, equals: .response)
                    .lpField()
            }
            .padding()
            .onChange(of: box.target) { focus = box.target }
            .onChange(of: focus) { box.reported = focus }
        }
    }

    /// The field whose editor is first responder, by its text.
    static func focusedText(_ window: NSWindow) -> String? {
        guard let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField else { return nil }
        return field.stringValue
    }

    @Test("M6: lpField draws no system focus ring, and `.focused($focus, equals:)` still moves focus", arguments: [true, false])
    func programmaticFocusStillWorks(echo: Bool) async throws {
        let box = FocusBox()
        let host = NSHostingView(rootView: FocusProbe(box: box, echo: echo).frame(width: 320, height: 200))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        for (target, text) in [(FocusProbe.Field.secret, "bravo"), (.response, "charlie"), (.name, "alpha")] {
            box.target = target
            #expect(await eventually { Self.focusedText(window) == text }, "\(target): \(String(describing: Self.focusedText(window)))")
            #expect(await eventually { box.reported == target })
        }
        // No system focus ring on any field (ours is the only one).
        var fields: [NSTextField] = []
        func collect(_ v: NSView) { if let f = v as? NSTextField, f.isEditable { fields.append(f) }; v.subviews.forEach(collect) }
        collect(host)
        #expect(fields.count == 3)
        #expect(fields.allSatisfy { $0.focusRingType == .none }, "\(fields.map(\.focusRingType.rawValue))")
    }

    // MARK: Fable pre-release review, part A (docs/native/reviews/2026-11-09-fable-prerelease.md)

    static func run(_ exe: String, _ args: [String], env: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("A-1: the root script runs under env -i: no SHELLOPTS, BASH_ENV or other inherited variable reaches it")
    func theRootShellGetsACleanEnvironment() throws {
        #expect(LegacyHelperRemoval.script == LegacyHelperRemoval.wrapped(LegacyHelperRemoval.body))
        #expect(LegacyHelperRemoval.script.hasPrefix("exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c '"))
        // Fable follow-up LOW-2: one quoted argument, no here-document anywhere (no temp file), quotes escaped exactly.
        #expect(!LegacyHelperRemoval.script.contains("<<"))
        #expect(LegacyHelperRemoval.wrapped("echo 'a'") == #"exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c 'echo '\''a'\'''"# + "\n")
        #expect(InProcessAppleScriptRunner.shellEnvironment.contains("TMPDIR"))
        // The same wrapper around a probe body, started like `do shell script` does (`/bin/sh -c`), from a hostile env.
        let probe = LegacyHelperRemoval.wrapped("set -o | grep -E '^(xtrace|noexec)'; env | sort; echo \"x=$x\"")
        let out = try Self.run("/bin/sh", ["-c", probe],
                               env: ["SHELLOPTS": "xtrace", "BASH_ENV": "/nonexistent", "ENV": "/nonexistent", "CDPATH": "/",
                                     "x": "leak", "PATH": "/usr/bin:/bin"])
        #expect(out.contains("xtrace         \toff") || out.contains("xtrace\toff") || out.range(of: #"xtrace\s+off"#, options: .regularExpression) != nil, "\(out)")
        #expect(!out.contains("SHELLOPTS=") && !out.contains("BASH_ENV=") && !out.contains("CDPATH=") && out.contains("x=\n"), "\(out)")
        #expect(out.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(InProcessAppleScriptRunner.shellEnvironment.contains("SHELLOPTS") && InProcessAppleScriptRunner.shellEnvironment.contains("BASH_XTRACEFD"))
    }

    @Test("A-2: every in-process execution error is the answer; only a cancel is a cancel")
    func everyExecutionErrorIsTheAnswer() {
        #expect(InProcessAppleScriptRunner.result(nil, error: [NSAppleScript.errorNumber: -128]) == .cancelled)
        #expect(InProcessAppleScriptRunner.result(nil, error: [NSAppleScript.errorNumber: -1743, NSAppleScript.errorMessage: "not allowed"]) == .failed("not allowed"))
        #expect(InProcessAppleScriptRunner.result(nil, error: [NSAppleScript.errorNumber: 1]) == .failed("AppleScript error 1"))   // the root script's exit status
        #expect(InProcessAppleScriptRunner.result(nil, error: [NSAppleScript.errorNumber: -60005, NSAppleScript.errorMessage: "denied"]) == .failed("denied"))
    }

    @Test("A-3: as root the script refuses while the old app runs; the result maps to Quit the old LockPlus first")
    func oldAppRunningIsRefusedAsRoot() async throws {
        let s = LegacyHelperRemoval.script
        let check = try #require(s.range(of: "result old-app-running")).lowerBound
        #expect(check < (try #require(s.range(of: "launchctl bootout"))).lowerBound)
        #expect(LegacyHelperRemoval.outcome(of: "LP_RESULT=old-app-running") == .oldAppRunning)
        let (h, _, runner) = E2E5FixTests().removalHarness(answer: .finished(output: "LP_RESULT=old-app-running\n"), leaves: [LegacyAppDetector.helperPlist, LegacyAppDetector.helperBinary])
        defer { h.dir.cleanup() }
        await h.env.legacy.refresh()
        await h.env.legacy.removeHelper()
        #expect(runner.runs == 1 && h.env.legacy.removal == .failed(.oldAppRunning))
        // The pattern matches the Go executable (`lockplus`) and WireGuide+'s, never native 2.0's `LockPlus`.
        let dir = TestDir()
        defer { dir.cleanup() }
        func spawn(_ app: String, _ exe: String) throws -> Process {
            let macos = dir.url.appending(path: "\(app)/Contents/MacOS", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let bin = macos.appending(path: exe)
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: bin.path)
            let p = Process()
            p.executableURL = bin
            p.arguments = ["30"]
            try p.run()
            return p
        }
        let go = try spawn("LockPlus.app", "lockplus"), wgp = try spawn("WireGuide+.app", "wireguide-plus")
        let native = try spawn("Native.app", "LockPlus")
        defer { for p in [go, wgp, native] { p.terminate() } }
        let pids = try Self.run("/usr/bin/pgrep", ["-f", LegacyHelperRemoval.oldAppPattern], env: [:])
            .split(separator: "\n").compactMap { Int32($0) }
        #expect(pids.contains(go.processIdentifier) && pids.contains(wgp.processIdentifier), "\(pids)")
        #expect(!pids.contains(native.processIdentifier))
    }

    @Test("A-4: a helper binary without its plist is its own finding and removable; it isn't called busy")
    func anOrphanBinaryIsRemovable() async {
        let (h, sys, runner) = E2E5FixTests().removalHarness(answer: .finished(output: "LP_RESULT=removed\n"))
        defer { h.dir.cleanup() }
        sys.setFiles([LegacyAppDetector.helperBinary])
        await h.env.legacy.refresh()
        UIBinder.bind(h.env)
        #expect(h.env.legacy.finding == .orphanBinary && h.env.legacy.canRemoveHelper)
        #expect(h.env.ui.connection.legacyHelper?.canRemoveHelper == true)
        #expect(LegacyFinding.orphanBinary.message?.contains("A file of the old LockPlus helper") == true)
        #expect(!LegacyFinding.orphanBinary.blocksConnect && !LegacyFinding.orphanBinary.warnsBeforeConnect)
        await h.env.legacy.removeHelper()
        #expect(runner.runs == 1 && h.env.legacy.removal == .removed(leftNetworkState: false))
        #expect(h.env.legacy.finding == LegacyFinding.none)
        // With an un-replayed DNS journal next to it: removable; root judges the journal (E2E-6 N1), and its refusal
        // says so, not "busy".
        let (h2, sys2, runner2) = E2E5FixTests().removalHarness(answer: .finished(output: "LP_RESULT=dns-unrestored\n"))
        defer { h2.dir.cleanup() }
        sys2.setFiles([LegacyAppDetector.helperBinary, LegacyAppDetector.dnsJournal])
        await h2.env.legacy.refresh()
        #expect(h2.env.legacy.finding == .leftoverState && h2.env.legacy.refusal == nil)
        await h2.env.legacy.removeHelper()
        #expect(runner2.runs == 1 && h2.env.legacy.removal == .failed(.dnsNotRestored))
    }
}
