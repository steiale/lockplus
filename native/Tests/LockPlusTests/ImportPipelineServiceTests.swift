import Foundation
import LPModel
import LPParsing
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// PLAN-2.0.2 §1.8: import, editor, migrator and launch re-verify use the injected validator (the sandboxed validator
/// service in the live app) and the injected archive reader; nothing here talks to the tunnel component.
@MainActor @Suite("Import pipeline through the validator service", .serialized)
struct ImportPipelineServiceTests {
    @Test func zipReadGoesThroughTheService() async throws {
        let reader = FakeZipArchiveReader(.success(ZipProfiles(entries: [("Work.conf", Array(Harness.wgConf.utf8))], issues: [])))
        let h = Harness(zipReader: reader)
        defer { h.dir.cleanup() }
        let env = h.env
        let url = h.dir.url.appending(path: "VPN.zip")
        try Data("PK".utf8).write(to: url)
        env.importer.importFiles([url])
        await env.importer.idle()
        #expect(reader.reads == 1)
        #expect(env.ui.importer.batch?.items.map(\.fileName) == ["Work.conf"])
    }

    @Test func aServiceThatCannotReadTheArchiveSaysSo() async throws {
        let h = Harness(zipReader: FakeZipArchiveReader(.failure(.checkUnavailable)))
        defer { h.dir.cleanup() }
        let env = h.env
        let url = h.dir.url.appending(path: "VPN.zip")
        try Data("PK".utf8).write(to: url)
        env.importer.importFiles([url])
        await env.importer.idle()
        #expect(env.ui.importer.errorMessage == ZipArchiveError.checkUnavailable.message(archive: "VPN.zip"))
        #expect(env.ui.importer.batch == nil)
    }

    @Test func checkCrashedRejectsTheFile() async throws {
        let v = FakeProfileValidator(.checkCrashed)
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        #expect(a.verdict == .rejected)
        #expect(a.report.items.contains { $0.reason == .checkCrashed })
        #expect(!a.report.items.contains { if case .engineValidationFailed = $0.reason { true } else { false } })
        #expect(v.checked.count == 1)
    }

    @Test func serviceUnavailableSavesNotYetVerified() async throws {
        let v = FakeProfileValidator(.fails(LPError(.extensionUnavailable)))
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        #expect(a.verdict != .rejected)
        #expect(!a.engineVerified)
        #expect(a.canonical != nil)
    }

    @Test func anAcceptedCheckIsVerified() async throws {
        let v = FakeProfileValidator(.accepted(autologin: true))
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        #expect(a.engineVerified)
        // WireGuard never asks the service.
        let w = FakeProfileValidator()
        _ = await ImportCoordinator.analyse(fileName: "Work.conf", bytes: Array(Harness.wgConf.utf8), validator: w, probe: NullProbe())
        #expect(w.checked.isEmpty)
    }

    @Test func editorUsesInjectedValidator() async throws {
        let v = FakeProfileValidator()
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        let env = h.env
        // Even with the tunnel component not ready: the service is independent of it.
        #expect(env.editorBackend.openVPNValidator != nil)
        let id = try await env.editorBackend.save(.new(.openVPN), name: "Office", text: PreviewSeed.officeOvpn, mode: .saveOnly)
        #expect(env.profiles.profile(id)?.engineVerified == true)
        #expect(v.checked.count == 1)
        #expect(h.service.calls(.validateProfile) == 0)
    }

    @Test func launchReVerifiesNotYetVerifiedProfilesThroughTheService() async throws {
        let v = FakeProfileValidator(.fails(LPError(.extensionUnavailable)))
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        let env = h.env
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        let d = try #require(env.importer.draft(a, name: "Office", killSwitch: false, allowLAN: false))
        let p = try await env.profiles.create(d)
        #expect(env.profiles.profile(p.id)?.engineVerified == false)
        v.outcome = .accepted(autologin: true)
        await env.profiles.verifyPending()
        #expect(env.profiles.profile(p.id)?.engineVerified == true)
        #expect(h.service.calls(.validateProfile) == 0)
    }

    @Test func aCrashedReVerifyIsRecordedAsCheckCrashed() async throws {
        let v = FakeProfileValidator(.fails(LPError(.extensionUnavailable)))
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        let env = h.env
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        let p = try await env.profiles.create(try #require(env.importer.draft(a, name: "Office", killSwitch: false, allowLAN: false)))
        v.outcome = .checkCrashed
        await env.profiles.verifyPending()
        let report = try #require(env.profiles.profile(p.id)?.importReport)
        #expect(report.items.contains { $0.reason == .checkCrashed })
        let rev = try #require(env.profiles.profile(p.id)).metaRevision
        await env.profiles.verifyPending()       // not re-checked on every pass
        #expect(env.profiles.profile(p.id)?.metaRevision == rev)
        #expect(v.checked.count == 2)         // the import, the first re-verify; a crashing file is not fed to the service again
    }

    /// Round 1 (Fable M1, Sonnet L2): only `.profileCheckCrashed` is a verdict on the file; a timeout, a hello that
    /// timed out and an unavailable service are "not checked" and rethrown.
    @Test func onlyACrashIsAVerdict() {
        #expect(ServiceProfileValidator.verdict(for: LPError(.profileCheckCrashed)) == .checkCrashed)
        for c in [LPErrorCode.timeout, .extensionUnavailable, .versionMismatch, .unauthorizedPeer, .cancelled, .malformedRequest] {
            #expect(ServiceProfileValidator.verdict(for: LPError(c)) == nil, "\(c)")
        }
    }

    @Test func aTimeoutAtImportIsNotYetVerifiedNotRefused() async throws {
        let v = FakeProfileValidator(.fails(LPError(.timeout, detail: "evaluateProfile")))
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        #expect(a.verdict != .rejected && !a.engineVerified && a.canonical != nil)
        #expect(!a.report.items.contains { $0.reason == .checkCrashed })
    }

    /// Round 1 (Fable M1, Sonnet M1): a timeout in the re-verify leaves the profile retryable (no report item, not
    /// verified), and stops being retried after `maxTimeoutsPerRun` in this run.
    @Test func aTimedOutReVerifyLeavesTheProfileRetryable() async throws {
        let v = FakeProfileValidator(.fails(LPError(.extensionUnavailable)))
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        let env = h.env
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        let p = try await env.profiles.create(try #require(env.importer.draft(a, name: "Office", killSwitch: false, allowLAN: false)))
        let rev = try #require(env.profiles.profile(p.id)).metaRevision
        v.outcome = .fails(LPError(.timeout, detail: "evaluateProfile"))
        for _ in 0..<4 { await env.profiles.verifyPending() }
        let after = try #require(env.profiles.profile(p.id))
        #expect(!after.engineVerified && after.metaRevision == rev)
        #expect(!(after.importReport?.items.contains { $0.reason == .checkCrashed } ?? false))
        #expect(v.checked.count == 1 + ProfilesStore.maxTimeoutsPerRun)      // the import, then two timed-out tries
        // Even once the service answers, a profile that timed out twice in this run waits for the next launch.
        v.outcome = .accepted(autologin: true)
        await env.profiles.verifyPending()
        #expect(env.profiles.profile(p.id)?.engineVerified == false)       // timed out twice: left for the next launch
    }

    @Test func aReVerifyRefusalIsALocalisedProblemLine() async throws {
        let v = FakeProfileValidator(.fails(LPError(.extensionUnavailable)))
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        let env = h.env
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        _ = try await env.profiles.create(try #require(env.importer.draft(a, name: "Office", killSwitch: false, allowLAN: false)))
        v.outcome = .rejected(category: "UNUSED_OPTIONS")
        await env.profiles.verifyPending()
        #expect(env.profiles.problems.last?.message == "LockPlus's file check refused Office: UNUSED_OPTIONS")
        #expect(!(env.profiles.problems.last?.message.contains("tunnel component") ?? true))
    }

    /// Round 1 (Codex 5): an editor save lands while the re-verify of the old bytes runs: the old verdict is not
    /// attached to the new bytes.
    @Test func aReVerifyVerdictIsBoundToTheCheckedRevision() async throws {
        let v = FakeProfileValidator(.fails(LPError(.extensionUnavailable)))
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        let env = h.env
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        let p = try await env.profiles.create(try #require(env.importer.draft(a, name: "Office", killSwitch: false, allowLAN: false)))
        v.outcome = .accepted(autologin: true)
        v.beforeAnswer.withLock { $0 = { @MainActor in
            v.beforeAnswer.withLock { $0 = nil }
            v.outcome = .fails(LPError(.extensionUnavailable))                // the editor's own check is unavailable
            _ = try? await env.editorBackend.save(.existing(p.id), name: "Office", text: PreviewSeed.officeOvpn + "\nverb 4\n", mode: .saveOnly)
            v.outcome = .accepted(autologin: true)
        } }
        await env.profiles.verifyPending()
        let after = try #require(env.profiles.profile(p.id))
        #expect(after.payloadRevision == p.payloadRevision + 1)
        #expect(!after.engineVerified)                                        // the old bytes' verdict didn't stick
    }

    /// Round 1 (Codex 5): Duplicate takes one snapshot after the authentication: an editor save during the prompt is
    /// duplicated with its own verdict, never as new bytes under the old one.
    @Test func duplicateTakesOneSnapshotAfterTheAuthentication() async throws {
        let v = FakeProfileValidator(.accepted(autologin: true))
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        let env = h.env
        let id = try await env.editorBackend.save(.new(.openVPN), name: "Office", text: PreviewSeed.officeOvpn, mode: .saveOnly)
        #expect(env.profiles.profile(id)?.engineVerified == true)
        h.hooks.duringAuthenticate = { @MainActor in
            v.outcome = .fails(LPError(.extensionUnavailable))
            _ = try? await env.editorBackend.save(.existing(id), name: "Office", text: PreviewSeed.officeOvpn + "\nverb 4\n", mode: .saveOnly)
        }
        let before = Set(env.profiles.profiles.map(\.id))
        env.ui.actions.duplicate(id)
        #expect(await eventually { env.profiles.profiles.count == before.count + 1 })
        let copy = try #require(env.profiles.profiles.first { !before.contains($0.id) })
        let source = try #require(env.profiles.profile(id))
        #expect(!source.engineVerified && !copy.engineVerified)
        #expect(copy.payloadDigest == source.payloadDigest)
    }

    /// Round 1 (Codex 8): a 2.0.1 payload of a profile with `link-mtu` (no mssfix floor) is not a fixed point; reconcile
    /// migrates it to a new revision, checks it through the service, and only then provisions it.
    @Test func aNonFixedPointStoredPayloadIsMigratedAndReVerified() async throws {
        let v = FakeProfileValidator(.accepted(autologin: true))
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        let env = h.env
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array((PreviewSeed.officeOvpn + "\nlink-mtu 1500\n").utf8),
                                                validator: v, probe: NullProbe())
        var d = try #require(env.importer.draft(a, name: "Office", killSwitch: false, allowLAN: false))
        let text = d.payload.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        let old = text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0 != "mssfix \"1300\"" }.joined(separator: "\n")
        #expect(old != text && !OVPNImporter.isCanonicalFixedPoint(Array(old.utf8)))
        d.payload = SecretBytes(copying: Array(old.utf8))                     // what 2.0.1 stored
        let p = try await env.profiles.create(d)
        await env.profiles.load()
        await env.profiles.reconcile()
        let after = try #require(env.profiles.profile(p.id))
        #expect(after.payloadRevision == p.payloadRevision + 1 && after.engineVerified)
        let stored = try await env.profiles.payload(p.id)
        #expect(stored.withUnsafeBytes { OVPNImporter.isCanonicalFixedPoint(Array($0)) })
        #expect(h.service.state.withLock { $0.provisioned[p.id]?.revision } == after.payloadRevision)
        // A fixed point is left alone.
        await env.profiles.reconcile()
        #expect(env.profiles.profile(p.id)?.payloadRevision == after.payloadRevision)
    }

    /// Round 1 (Fable L1, Codex 1): an unverified profile that NE starts (on-demand) and the extension answers "not
    /// provisioned" is never provisioned by the automatic retry, nor by reconcile, nor started again.
    @Test func anUnverifiedProfileIsNeverProvisionedByAutomaticRecovery() async throws {
        let v = FakeProfileValidator(.fails(LPError(.extensionUnavailable)))
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        let env = h.env
        let a = await ImportCoordinator.analyse(fileName: "Office.ovpn", bytes: Array(PreviewSeed.officeOvpn.utf8), validator: v, probe: NullProbe())
        let p = try await env.profiles.create(try #require(env.importer.draft(a, name: "Office", killSwitch: false, allowLAN: false)))
        #expect(env.profiles.profile(p.id)?.engineVerified == false)
        env.connection.start()
        let provisions = h.service.calls(.provisionProfile)
        h.managers.emit(p.id, .connecting)                                    // NE's own start
        h.managers.lastError = LPTunnelError(.profileNotProvisioned, detail: "x") as NSError
        h.managers.emit(p.id, .disconnecting)
        h.managers.emit(p.id, .disconnected)
        #expect(await eventually { env.connection.statuses[p.id] == .disconnected })
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.service.calls(.provisionProfile) == provisions && h.managers.starts.isEmpty)
        let current = try #require(env.profiles.profile(p.id))
        do throws(LPError) { try await env.profiles.provision(current); Issue.record("provisioned") } catch {
            #expect(error.code == .profileInvalid)                            // the one gate, for every caller
        }
        await env.profiles.reconcile()
        #expect(h.service.calls(.provisionProfile) == provisions)
    }

    @Test func migratorUsesInjectedValidator() async throws {
        let v = FakeProfileValidator(.rejected(category: "UNUSED_OPTIONS"))
        let h = Harness(validator: v)
        defer { h.dir.cleanup() }
        let env = h.env
        // The migrator was built with the same validator as the importer (one validator, four users).
        #expect(env.validator as AnyObject === v)
        _ = env.migrator
    }
}
