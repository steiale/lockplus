import Foundation
import LPModel
import LPWire
import SystemExtensions
import Testing
@testable import LockPlus

/// The activation `.ignore` paths and the activation watchdog (Fable verification). The submitter is a recorder, so no
/// request ever reaches sysextd.
@MainActor @Suite struct SystemExtensionManagerTests {
    final class Recorder { var requests: [OSSystemExtensionRequest] = [] }

    func make(watchdog: Duration = .seconds(60)) -> (SystemExtensionManager, Recorder) {
        let rec = Recorder()
        let m = SystemExtensionManager(bundle: .main, quiescer: NoTunnelsQuiescer(),
                                       submitter: { rec.requests.append($0) },
                                       propertiesTimeout: .milliseconds(50), activationWatchdog: watchdog, openSettings: {})
        return (m, rec)
    }

    func error(_ code: SystemExtensionErrorCode) -> NSError { NSError(domain: OSSystemExtensionErrorDomain, code: code.rawValue) }

    @Test func canceledWithNoSuccessorRestoresThePriorState() async {
        let (m, rec) = make()
        await m.activate()
        #expect(m.state == .activating)
        #expect(rec.requests.count == 2)               // properties preflight (timed out) + activation
        m.request(rec.requests[1], didFailWithError: error(.requestCanceled))
        #expect(m.state == .unknown)
        #expect(m.activationEndedWithoutResult)
    }

    @Test func canceledAfterApprovalPromptAlsoRestores() async {
        let (m, rec) = make()
        await m.activate()
        m.requestNeedsUserApproval(rec.requests[1])
        #expect(m.state == .needsUserApproval)
        m.request(rec.requests[1], didFailWithError: error(.requestCanceled))
        #expect(m.state == .unknown)
    }

    @Test func supersededByOurNewerRequestLeavesTheState() async {
        let (m, rec) = make()
        await m.activate()
        _ = m.submitSecondActivationForTesting()
        m.request(rec.requests[1], didFailWithError: error(.requestSuperseded))
        #expect(m.state == .activating)                // the newer request owns it
        #expect(!m.activationEndedWithoutResult)
    }

    @Test func watchdogFailsAStaleActivation() async throws {
        let (m, _) = make(watchdog: .milliseconds(100))
        await m.activate()
        #expect(await eventually { m.state == .failed(.broken(code: 0)) })
    }

    @Test func anyCallbackDisarmsTheWatchdog() async throws {
        let (m, rec) = make(watchdog: .milliseconds(100))
        await m.activate()
        m.requestNeedsUserApproval(rec.requests[1])
        // Negative check: the (disarmed) watchdog would have fired after 100 ms; 4× that is ample on a slow runner,
        // and a slow runner can only make this pass, never fail spuriously.
        try await Task.sleep(for: .milliseconds(400))
        #expect(m.state == .needsUserApproval)
    }

    // MARK: Deactivation (review: tests were missing)

    func readyManager() async -> (SystemExtensionManager, Recorder) {
        let (m, rec) = make()
        await m.activate()
        m.request(rec.requests[1], didFinishWithResult: .completed)
        return (m, rec)
    }

    @Test func deactivationCompletes() async throws {
        let (m, rec) = await readyManager()
        let n = rec.requests.count
        let t = Task { @MainActor () -> LPError? in do throws(LPError) { try await m.deactivate(); return nil } catch { return error } }
        #expect(await eventually { rec.requests.count == n + 1 && m.state == .deactivating })
        m.request(rec.requests[n], didFinishWithResult: .completed)
        #expect(await t.value == nil)
        #expect(m.state == .uninstalled)
    }

    @Test func aCancelledDeactivationThrowsAndRestores() async throws {
        let (m, rec) = await readyManager()
        let n = rec.requests.count
        let t = Task { @MainActor () -> LPError? in do throws(LPError) { try await m.deactivate(); return nil } catch { return error } }
        #expect(await eventually { rec.requests.count == n + 1 })
        m.request(rec.requests[n], didFailWithError: error(.requestCanceled))
        #expect(await t.value?.code == .cancelled)
        if case .ready = m.state {} else { Issue.record("state \(m.state)") }
    }

    @Test func extensionNotFoundGoesToGuidedRemoval() async throws {
        let (m, rec) = await readyManager()
        let n = rec.requests.count
        let t = Task { @MainActor () -> LPError? in do throws(LPError) { try await m.deactivate(); return nil } catch { return error } }
        #expect(await eventually { rec.requests.count == n + 1 })
        m.request(rec.requests[n], didFailWithError: error(.extensionNotFound))
        #expect(await eventually { m.guidedRemovalActive })
        // L6: the switch-off we asked for isn't "disabled by the user".
        m.systemExtensionWillBecomeDisabled(Self.info(m))
        m.systemExtensionWillBecomeInactive(Self.info(m))
        #expect(await t.value == nil)
        #expect(m.state == .uninstalled)
    }

    static func info(_ m: SystemExtensionManager) -> OSSystemExtensionInfo {
        TestExtensionInfo(id: m.extensionIdentifier)
    }

    @Test func restoredStateNeverRestoresActivating() {
        #expect(SystemExtensionManager.restoredState(after: .activating) == .unknown)
        #expect(SystemExtensionManager.restoredState(after: .disabledByUser) == .disabledByUser)
    }
}

/// An `OSSystemExtensionInfo` for the workspace-observer callbacks (no system involved).
final class TestExtensionInfo: OSSystemExtensionInfo, @unchecked Sendable {   // SAFETY: immutable test value
    private let id: String
    init(id: String) { self.id = id; super.init() }
    override var bundleIdentifier: String { id }
}
