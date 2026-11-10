import AppKit
import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// Reviews H5, L2, L3 and Fable H1: the master key is never regenerated over existing profiles (§6.8 locked state),
/// never replaced when malformed, and only deleted together with the profiles after a successful deactivation.
@MainActor @Suite("Uninstall and the master key (H5, Fable H1)", .serialized)
struct UninstallAndKeyTests {
    /// Counts saves, to prove a single key creation.
    final class CountingKeychain: SecretItemStore {
        let inner = InMemoryKeychain()
        let saves = Mutex(0)
        func load(service: String, account: String) async throws(KeychainError) -> SecretBytes? { try await inner.load(service: service, account: account) }
        func save(service: String, account: String, _ value: SecretBytes) async throws(KeychainError) {
            saves.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(20))
            try await inner.save(service: service, account: account, value)
        }
        func delete(service: String, account: String) async throws(KeychainError) { try await inner.delete(service: service, account: account) }
        func accounts(service: String) async throws(KeychainError) -> [String] { try await inner.accounts(service: service) }
    }

    func masterKey(_ h: Harness) async throws -> SecretBytes? {
        try await h.keychain.load(service: KeychainServices.payloadKey, account: "v1")
    }

    @Test func aFailedDeactivationDeletesNothingAndKeepsTheApp() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        try await h.add("Work.conf", Harness.wgConf)
        h.ext.deactivateError = LPError(.extensionUnavailable, detail: "deactivation failed")
        await Uninstaller(env: h.env, deleteProfilesAndHistory: true).run()
        #expect(h.env.ui.settings.uninstallPhase == .componentStillInstalled)
        #expect(!h.hooks.calls.contains("finishUninstall"))
        #expect(try await masterKey(h) != nil)
        #expect(FileManager.default.fileExists(atPath: h.dir.data.profiles.path))
    }

    @Test func residualsAreReportedNotSwallowed() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        try await h.add("Work.conf", Harness.wgConf)
        h.service.state.withLock { $0.failAll = LPError(.extensionUnavailable) }
        h.managers.removeError = LPError(.extensionUnavailable, detail: "remove")
        let r = await Uninstaller(env: h.env).run()
        #expect(r.secrets && r.vpnConfigurations == 1)
        #expect(h.hooks.residualMessages.count == 1)
        #expect(h.hooks.residualMessages.first?.contains("LockPlus tunnel secret") == true)
        #expect(h.hooks.calls.contains("finishUninstall"))
    }

    @Test func keepingProfilesKeepsTheKeySoAReinstallOpensThem() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        await Uninstaller(env: h.env, deleteProfilesAndHistory: false).run()
        #expect(try await masterKey(h) != nil)
        // "Reinstall": a fresh repository over the same files and keychain.
        let repo = ProfileRepository(directory: h.dir.data.profiles, keys: h.keychain)
        let r = try await repo.list()
        #expect(r.profiles.map(\.id) == [p.id] && r.tampered.isEmpty)
    }

    @Test func deletingProfilesDeletesTheKeyAfterDeactivation() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        try await h.add("Work.conf", Harness.wgConf)
        await Uninstaller(env: h.env, deleteProfilesAndHistory: true).run()
        #expect(try await masterKey(h) == nil)
        #expect(!FileManager.default.fileExists(atPath: h.dir.data.root.path))
    }

    @Test func missingKeyWithFilesIsLockedAndCreatesNothing() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        try await h.add("Work.conf", Harness.wgConf)
        try await h.keychain.delete(service: KeychainServices.payloadKey, account: "v1")
        let before = try FileManager.default.contentsOfDirectory(atPath: h.dir.data.profiles.path).sorted()
        let repo = ProfileRepository(directory: h.dir.data.profiles, keys: h.keychain)
        let profiles = ProfilesStore(repository: repo, credentialStore: CredentialStore(items: h.keychain), managers: h.env.managers,
                                     service: h.service, settings: h.env.settings)
        await profiles.load()
        #expect(profiles.locked == ["Work"])
        #expect(profiles.profiles.isEmpty)
        #expect(try await masterKey(h) == nil)                                  // no key over existing files
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.dir.data.profiles.path).sorted() == before)   // nothing quarantined
        await profiles.reconcile()
        #expect(h.service.calls(.removeProfile) == 0)                          // M2: a failed load never reconciles
        await profiles.removeLockedProfiles()
        #expect(profiles.locked == nil)
        _ = try await repo.list()                                               // now a fresh key may be created
        #expect(try await masterKey(h) != nil)
    }

    @Test func aWrongSizeKeyIsNeverReplaced() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        try await h.keychain.save(service: KeychainServices.payloadKey, account: "v1", SecretBytes(copying: [UInt8](repeating: 1, count: 16)))
        let repo = ProfileRepository(directory: h.dir.data.profiles, keys: h.keychain)
        await #expect(throws: LPError.self) { _ = try await repo.list() }
        #expect(try await masterKey(h)?.count == 16)
    }

    @Test func concurrentFirstUseCreatesOneKey() async throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let kc = CountingKeychain()
        let repo = ProfileRepository(directory: dir.data.profiles, keys: kc)
        async let a = repo.list()
        async let b = repo.list()
        _ = try await (a, b)
        #expect(kc.saves.withLock { $0 } == 1)
    }

    /// §6.8 Re-import while locked: import fails until the user confirms "start over"; then the locked files are
    /// kept in a side folder, a fresh key is created and the original file imports.
    @Test func reimportWhileLockedNeedsAnExplicitStartOver() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let old = try await h.add("Work.conf", Harness.wgConf)
        try await h.keychain.delete(service: KeychainServices.payloadKey, account: "v1")
        await h.env.profiles.repository.resetKeyCache()                // a relaunch: the key is gone
        await h.env.profiles.load()
        #expect(h.env.profiles.locked == ["Work"])
        await #expect(throws: LPError.self) { try await h.add("Work.conf", Harness.wgConf) }   // never silently
        #expect(try await masterKey(h) == nil)
        let aside = try await h.env.profiles.startOverMovingLockedAside()
        #expect(h.env.profiles.locked == nil)
        let kept = try FileManager.default.contentsOfDirectory(atPath: aside.path)
        #expect(kept.contains("\(old.id.uuidString).json") && kept.contains { $0.hasSuffix(".sealed") })
        let p = try await h.add("Work.conf", Harness.wgConf)
        #expect(try await masterKey(h) != nil)
        #expect(h.env.profiles.profiles.map(\.id) == [p.id])
        try? FileManager.default.removeItem(at: aside)
    }

    /// §6.8 third action: while locked, Go data yields an offer (past the marker); "Import from old LockPlus" starts
    /// over (files kept aside, no key over them) and opens the existing migration flow, whose run then imports.
    @Test func importFromOldLockPlusWhileLocked() async throws {
        let h = Harness(goSource: { PreviewSeed.GoFixture() })
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf)
        try await h.keychain.delete(service: KeychainServices.payloadKey, account: "v1")
        await h.env.profiles.repository.resetKeyCache()
        await h.env.profiles.load()
        #expect(h.env.profiles.locked == ["Work"])
        await h.env.offerMigrationWhileLocked()
        let offer = try #require(h.env.ui.onboarding.migration)
        #expect(offer.profileNames == ["old-office"])
        #expect(try await masterKey(h) == nil)                          // offering creates nothing
        h.env.ui.actions.startOverAndImportFromOldApp()
        #expect(await eventually { h.env.ui.onboarding.isPresented })
        #expect(h.env.ui.onboarding.step == .profiles)
        #expect(h.env.profiles.locked == nil)
        let report = await h.env.migrator.run(selected: Set(offer.profileNames))
        #expect(report.imported + report.needsAttention == ["old-office"])
        #expect(try await masterKey(h) != nil)
        let parent = h.dir.data.profiles.deletingLastPathComponent()
        for f in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix("profiles-locked-") { try? FileManager.default.removeItem(at: f) }
    }

    @Test func languagesAreEnglishAndGermanOnly() throws {
        let s = try AtomicFile.decoder().decode(AppSettings.self, from: Data(#"{"language":"ko"}"#.utf8))
        #expect(s.language == .system)
    }

    @Test func appearanceDefaultsToSystemAndRoundTrips() throws {
        let old = try AtomicFile.decoder().decode(AppSettings.self, from: Data(#"{"language":"de"}"#.utf8))
        #expect(old.appearance == .system)                                                  // a file without the key stays valid
        let junk = try AtomicFile.decoder().decode(AppSettings.self, from: Data(#"{"appearance":"sepia"}"#.utf8))
        #expect(junk.appearance == .system)
        for a in [AppSettings.Appearance.light, .dark] {
            var s = AppSettings()
            s.appearance = a
            let back = try AtomicFile.decoder().decode(AppSettings.self, from: try AtomicFile.encoder().encode(s))
            #expect(back.appearance == a)
        }
    }

    /// E2E-1 (both VMs, 2.0.0 (200001)): after a successful uninstall the app stayed running, because AppKit refused
    /// to terminate while the Settings uninstall sheet was attached ("App termination blocked by modal sheet").
    /// finishUninstall ends every attached sheet first.
    @Test func finishUninstallEndsAttachedSheets() async {
        func window() -> NSWindow { NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false) }
        let host = window(), sheet = window()
        host.orderFront(nil)
        host.beginSheet(sheet, completionHandler: nil)
        _ = await eventually { host.attachedSheet === sheet }
        #expect(host.attachedSheet === sheet)
        #expect(LiveSystemHooks.endAttachedSheets([host]))
        #expect(host.attachedSheet == nil)
        host.orderOut(nil)
    }

    /// Review PF-R6: one bounded loop. Past `cap` steps it stops (and says so) instead of spinning; nested sheets end
    /// innermost first.
    @Test func endAttachedSheetsIsBounded() async {
        func window() -> NSWindow { NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false) }
        let a = window(), b = window(), sa = window(), sb = window()
        for (w, s) in [(a, sa), (b, sb)] { w.orderFront(nil); w.beginSheet(s, completionHandler: nil) }
        _ = await eventually { a.attachedSheet === sa && b.attachedSheet === sb }
        #expect(!LiveSystemHooks.endAttachedSheets([a, b], cap: 1))     // one step: one sheet ended, one left
        #expect([a.attachedSheet, b.attachedSheet].compactMap { $0 }.count == 1)
        #expect(LiveSystemHooks.endAttachedSheets([a, b]))
        #expect(a.attachedSheet == nil && b.attachedSheet == nil)
        // Nested: the inner sheet first, then the outer one.
        let inner = window()
        a.beginSheet(sa, completionHandler: nil)
        _ = await eventually { a.attachedSheet === sa }
        sa.beginSheet(inner, completionHandler: nil)
        _ = await eventually { sa.attachedSheet === inner }
        #expect(LiveSystemHooks.endAttachedSheets([a]))
        #expect(a.attachedSheet == nil && sa.attachedSheet == nil)
        a.orderOut(nil); b.orderOut(nil)
    }
}
