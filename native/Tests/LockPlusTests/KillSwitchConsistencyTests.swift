import Foundation
import LPModel
import LPWire
import Testing
@testable import LockPlus

/// Review H1: the NE manager (kill-switch flags) and the profile metadata never disagree.
@MainActor @Suite("Kill-switch consistency (H1)", .serialized)
struct KillSwitchConsistencyTests {
    func settle(_ ms: Int = 80) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    @Test func aFailedMetadataWriteRollsTheManagerBack() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        // The metadata file can't be replaced: a non-empty directory sits at its path.
        let meta = h.dir.data.profiles.appending(path: "\(p.id.uuidString).json")
        try FileManager.default.removeItem(at: meta)
        try FileManager.default.createDirectory(at: meta.appending(path: "x"), withIntermediateDirectories: true)
        await #expect(throws: LPError.self) { try await h.env.profiles.updatePolicy(p.id) { $0.killSwitch = false } }
        #expect(h.managers.entries[p.id]?.cfg.flags.includeAllNetworks == true)   // rolled back
        #expect(h.env.profiles.profile(p.id)?.policy.killSwitch == true)
    }

    @Test func aManagerBehindItsProfileIsResavedBeforeStart() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        var stale = ManagerConfiguration(profile: p, onDemand: nil)
        stale.flags.includeAllNetworks = false                          // a lost write: the manager lacks the kill switch
        h.managers.entries[p.id]?.cfg = stale
        try await h.env.managers.loadAll()
        h.env.connection.start()
        h.env.connection.connect(p.id)
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.entries[p.id]?.cfg.flags.includeAllNetworks == true)
    }

    @Test func onlyTheL_KS_2GuardSaysDisconnectFirst() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        h.managers.saveError = LPError(.extensionUnavailable, detail: "saveToPreferences: NEVPNErrorDomain 5")
        h.env.ui.actions.setKillSwitch(false, for: p.id)
        #expect(await eventually { h.env.ui.importer.errorMessage != nil })
        #expect(h.env.ui.importer.errorMessage != String(localized: "Disconnect first to change protection settings.", comment: "Policy change while connected"))
        #expect(h.env.profiles.profile(p.id)?.policy.killSwitch == true)
    }

    @Test func aDeniedConfigurationIsNotAnExtensionError() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.managers.entries[p.id] = nil
        try await h.env.managers.loadAll()
        h.managers.saveError = LPError(.extensionUnavailable, detail: "saveToPreferences: NEVPNErrorDomain 5")
        h.env.connection.start()
        h.env.connection.connect(p.id)
        #expect(await eventually { h.env.connection.configurationDenied })
    }
}
