import Foundation
import LPModel
import Sparkle
import Testing
@testable import LockPlus

/// §12.1/§12.3 (variant B) without Sparkle: the coordinator, the placeholder guard and the §4.2 marker.
@MainActor @Suite("Updates (§12)", .serialized)
struct UpdateTests {
    func settle(_ ms: Int = 50) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    @Test func placeholdersNeverStartTheUpdater() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(UpdateController.isConfigured(feedURL: "https://example.org/appcast.xml", publicKey: key))
        #expect(!UpdateController.isConfigured(feedURL: "https://pages-host.invalid/appcast.xml", publicKey: key))
        #expect(!UpdateController.isConfigured(feedURL: "http://example.org/appcast.xml", publicKey: key))
        #expect(!UpdateController.isConfigured(feedURL: "https://example.org/appcast.xml", publicKey: "OWNER-PLACEHOLDER"))
        #expect(!UpdateController.isConfigured(feedURL: "https://example.org/appcast.xml",
                                               publicKey: Data(repeating: 7, count: 16).base64EncodedString()))
        #expect(!UpdateController.isConfigured(feedURL: nil, publicKey: key))
    }

    @Test func shippedInfoPlistKeepsTheDecidedSparkleKeys() throws {
        let info = try #require(Bundle(for: AppDelegate.self).infoDictionary)
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SUSignedFeedFailureExpirationInterval"] as? Int == 1_728_000)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        #expect(info.keys.allSatisfy { !($0.hasPrefix("SUEnable") && $0.hasSuffix("Service")) })
        #expect(info["NSUpdateSecurityPolicy"] == nil)
    }

    @Test func postponeHookRecordsIntentOnlyAndAFailedInstallClearsIt() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.managers.entries[p.id]?.status = .connected
        let c = UpdateCoordinator(settings: h.env.settings, extensionStore: { h.ext }, currentBuild: "41")
        c.installDidNotHappen()                                        // nothing prepared: no-op
        #expect(h.env.settings.value.expectedUpdate == nil)
        c.prepareForInstall(toVersion: "42")
        #expect(h.env.settings.value.expectedUpdate == ExpectedUpdate(from: "41", to: "42"))
        #expect(c.preparedForInstall)
        #expect(h.managers.stops.isEmpty)                              // variant B: the tunnel keeps protecting
        let onDisk = try #require(AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings))
        #expect(onDisk.expectedUpdate == ExpectedUpdate(from: "41", to: "42"))   // written before Sparkle quits us
        c.installDidNotHappen()
        #expect(h.env.settings.value.expectedUpdate == nil)
        #expect(!c.preparedForInstall)
    }

    @Test func updateSessionsAreRefusedDuringAReplacementOrResume() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let c = UpdateCoordinator(settings: h.env.settings, extensionStore: { h.ext })
        #expect(c.refusalReason == nil)
        h.ext.updateInProgress = true
        #expect(c.refusalReason != nil)
        h.ext.updateInProgress = false
        h.ext.state = .activating
        #expect(c.refusalReason != nil)
        h.ext.state = .ready(version: "2")
        h.env.settings.update { $0.pendingResume = PendingResume(profileID: nil, onDemandEnabledIDs: [], reason: .extensionUpdate) }
        #expect(c.refusalReason != nil)
    }

    @Test func releaseCandidateChannel() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let c = UpdateCoordinator(settings: h.env.settings, extensionStore: { h.ext })
        #expect(c.allowedChannels.isEmpty)
        h.env.settings.update { $0.receiveReleaseCandidates = true }
        #expect(c.allowedChannels == ["rc"])
    }

    /// §4.2: an expected update counts as a resume marker; `.completed` clears it even when nothing was quiesced.
    @Test func expectedUpdateIsAPreflightMarkerClearedAfterActivation() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let q = ManagerQuiescer()
        q.attach(managers: h.managers, settings: h.env.settings, connection: h.env.connection)
        #expect(await q.hasOnDemandOrResumeMarker() == false)
        h.env.settings.update { $0.expectedUpdate = ExpectedUpdate(from: "1", to: "2") }
        #expect(await q.hasOnDemandOrResumeMarker())
        await q.resumeAfterUpdate()
        #expect(h.env.settings.value.expectedUpdate == nil)
    }

    @Test func updaterStartsAfterThePreflightAndMirrorsIntoTheUI() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        #expect(h.env.ui.settings.canCheckForUpdates == false)
        await h.env.start()
        try await settle()
        #expect(h.env.ui.settings.canCheckForUpdates)                  // PreviewUpdater started by onPreflightFinished
        h.env.updates.updateAvailable(true)
        #expect(h.env.ui.settings.updateAvailable)
        h.env.ui.actions.checkForUpdates()
        #expect(h.env.ui.settings.updateAvailable == false)
        #expect((h.env.updater as? PreviewUpdater)?.checks == 1)
        h.env.stop()
    }

    @Test func expectedUpdateSurvivesASettingsRoundTrip() throws {
        var s = AppSettings()
        s.expectedUpdate = ExpectedUpdate(from: "7", to: "8")
        let back = try AtomicFile.decoder().decode(AppSettings.self, from: AtomicFile.encoder().encode(s))
        #expect(back.expectedUpdate == s.expectedUpdate)
    }

    /// Review UpdateTests:46: the real delegate hook (Sparkle objects, no network): it records the intent and calls
    /// Sparkle's block later, not inside the call (L9).
    @Test func thePostponeHookRecordsIntentThenInvokesTheBlockAsync() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let c = UpdateCoordinator(settings: h.env.settings, extensionStore: { h.ext }, currentBuild: "41")
        let controller = UpdateController(coordinator: c)
        let standard = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: controller, userDriverDelegate: nil)
        let item = try #require(Self.item(version: "42"))
        final class Flag: @unchecked Sendable { var called = false }   // SAFETY: main-queue only
        let flag = Flag()
        let postponed = controller.updater(standard.updater, shouldPostponeRelaunchForUpdate: item) { @Sendable in flag.called = true }
        #expect(postponed)
        #expect(!flag.called)                                          // not from inside the delegate call
        #expect(h.env.settings.value.expectedUpdate == ExpectedUpdate(from: "41", to: "42"))
        #expect(await eventually { flag.called })
        // "No update" ends a cycle with an error that isn't a failed install.
        controller.updater(standard.updater, didFinishUpdateCycleFor: .updates,
                           error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        #expect(h.env.settings.value.expectedUpdate != nil)
        controller.updater(standard.updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: 4005))
        #expect(h.env.settings.value.expectedUpdate == nil)
        #expect(controller.feedURLString(for: standard.updater) == Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
    }

    @available(macOS, deprecated: 10.0)
    nonisolated static func makeItem(version: String) -> SUAppcastItem? {
        SUAppcastItem(dictionary: ["sparkle:version": version, "title": "LockPlus \(version)",
                                   "enclosure": ["url": "https://example.org/LockPlus-\(version).zip", "sparkle:version": version, "length": "1"]])
    }

    /// The deprecated test-only initializer, reached through a protocol witness so no warning leaks.
    static func item(version: String) -> SUAppcastItem? { (ItemMaker() as any ItemMaking).make(version) }
}

private protocol ItemMaking { func make(_ v: String) -> SUAppcastItem? }
private struct ItemMaker: ItemMaking {
    @available(macOS, deprecated: 10.0)
    func make(_ v: String) -> SUAppcastItem? { UpdateTests.makeItem(version: v) }
}
