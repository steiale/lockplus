import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// Reviews M1, M3, M4: no orphan or duplicate when the NE save fails, the orphan sweep, crash-safe payload revisions.
@MainActor @Suite("Profile lifecycle (M1, M3, M4)", .serialized)
struct ProfileLifecycleTests {
    @Test func aFailedNESaveDoesNotFailTheImport() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        h.managers.saveError = LPError(.extensionUnavailable, detail: "saveToPreferences: NEVPNErrorDomain 5")
        let p = try await h.add("Work.conf", Harness.wgConf)               // no throw: no retry, no duplicate
        #expect(h.env.profiles.profiles.map(\.id) == [p.id])
        #expect(h.env.profiles.problems.contains { $0.message.contains("wasn't saved yet") })
        h.managers.saveError = nil
        h.env.connection.start()
        h.env.connection.connect(p.id)                                     // the first connect creates the manager
        #expect(await eventually { h.managers.starts.count == 1 })
        #expect(h.managers.entries[p.id] != nil)
    }

    @Test func orphanManagersAreSweptAndDeleteDisablesOnDemandFirst() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.managers.entries[p.id]?.onDemand = true
        try await h.env.managers.loadAll()
        h.managers.removeError = LPError(.extensionUnavailable, detail: "remove")
        await h.env.profiles.delete(p.id)
        #expect(h.managers.entries[p.id]?.onDemand == false)               // disabled before the (failed) remove
        h.managers.removeError = nil
        await h.env.profiles.load()                                        // the sweep removes the orphan
        #expect(await eventually { h.managers.entries[p.id] == nil })
    }

    @Test func anInterruptedPayloadReplaceLeavesTheProfileReadable() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        let repo = h.env.profiles.repository
        // Crash after the new sealed revision, before the metadata commit:
        var next = p
        next.payloadRevision += 1
        try await repo.savePayload(SecretBytes(copying: Array("[Interface]\n".utf8)), for: next)
        let old = try await repo.payload(for: p)                           // the committed revision still opens
        #expect(old.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }.contains("PrivateKey"))
        // A complete replace prunes the older revision.
        let a = await ImportCoordinator.analyse(fileName: "Work.conf", bytes: Array(Harness.wgConf.utf8), validator: h.validator, probe: NullProbe())
        let d = try #require(h.env.importer.draft(a, name: "Work", killSwitch: true, allowLAN: false))
        let after = try await h.env.profiles.replacePayload(p.id, with: d)
        let sealed = try FileManager.default.contentsOfDirectory(atPath: h.dir.data.profiles.path).filter { $0.hasSuffix(".sealed") }
        #expect(sealed == ["\(p.id.uuidString).\(after.payloadRevision).sealed"])
    }
}

/// Review M11: the content decides the protocol.
@Suite("Import kind sniffing (M11)")
struct ImportKindTests {
    @Test func contentWinsOverTheExtension() {
        #expect(ImportCoordinator.kind(fileName: "office.conf", bytes: Array(PreviewSeed.officeOvpn.utf8)) == .openVPN)
        #expect(ImportCoordinator.kind(fileName: "home.ovpn", bytes: Array(PreviewSeed.workConf.utf8)) == .wireGuard)
        #expect(ImportCoordinator.kind(fileName: "x.txt", bytes: Array("# [Interface]\nclient\n".utf8)) == .openVPN)
        #expect(ImportCoordinator.kind(fileName: "empty.ovpn", bytes: []) == .openVPN)
        #expect(ImportCoordinator.kind(fileName: "empty.conf", bytes: []) == .wireGuard)
    }
}

/// Reviews L5, L6, L7.
@MainActor @Suite("Small lifecycle fixes (L5-L7)", .serialized)
struct SmallLifecycleTests {
    @Test func aRejectedProfileIsNotRecheckedOnEveryHello() async throws {
        let h = Harness(validator: FakeProfileValidator(.fails(LPError(.extensionUnavailable))))
        defer { h.dir.cleanup() }
        h.service.state.withLock { $0.failAll = LPError(.extensionUnavailable) }
        let p = try await h.add("Office.ovpn", PreviewSeed.officeOvpn)
        #expect(h.env.profiles.profile(p.id)?.engineVerified == false)
        h.service.state.withLock { $0.failAll = nil }
        h.validator.outcome = .rejected(category: "UNUSED_OPTIONS")
        await h.env.profiles.load()                                  // reconcile runs only on a loaded store
        await h.env.profiles.reconcile()
        #expect(h.env.profiles.profile(p.id)?.importReport?.items.contains { $0.reason == .engineValidationFailed(category: "UNUSED_OPTIONS") } == true)
        let rev = try #require(h.env.profiles.profile(p.id)).metaRevision
        await h.env.profiles.reconcile()
        await h.env.profiles.reconcile()
        #expect(h.env.profiles.profile(p.id)?.metaRevision == rev)
        #expect(h.validator.checked.count == 2)       // the import, then one re-verify; a rejected file is not re-checked
        #expect(h.service.calls(.validateProfile) == 0)
    }

    @Test func retryApprovalStartsOnlyAfterTheOldAttemptIsDown() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let p = try await h.add("Work.conf", Harness.wgConf)
        h.env.connection.start()
        h.managers.emit(p.id, .connecting)
        // An AUTH_PENDING prompt is up.
        h.service.state.withLock {
            $0.prompt = AuthPrompt(promptID: UUID(), profileID: p.id, kind: .pendingApproval, challengeText: nil, echo: false,
                                   lockedUsername: nil, reason: .initial, savedUsername: nil, nextStart: false,
                                   expiresAt: Date().addingTimeInterval(600))
        }
        await h.env.auth.pullPending(p.id)
        let prompt = try #require(h.env.auth.prompt)
        h.env.auth.retryApproval(prompt.promptID)
        #expect(await eventually { h.managers.stops == [p.id] })
        #expect(await eventually { h.managers.starts.count == 1 })
    }
}
