import Foundation
import LPModel
import os

/// The Sparkle-independent half of DESIGN §12.3 (variant B, draft 4). Unit-tested without Sparkle: `UpdateController`
/// forwards the delegate callbacks here.
///
/// Variant B: the postpone hook only records intent (`expectedUpdate`); the new app's §4.2 launch preflight
/// (`SystemExtensionManager.activate()` + `ManagerQuiescer`) does all quiescing, so install-on-quit, brew and
/// drag-replace take the same path. `ManagerQuiescer.resumeAfterUpdate()` clears the marker after `.completed`.
@MainActor final class UpdateCoordinator {
    private let settings: SettingsStore
    private let extensionStore: () -> (any ExtensionControlling)?
    private let currentBuild: String
    private(set) var preparedForInstall = false
    /// UI hook: the gentle-reminder state ("Update Available…" in the menu, §12.1).
    var onUpdateAvailableChange: ((Bool) -> Void)?
    /// Review 4 #2: ends the hand-over `prepareForInstall` began (`AppEnvironment`: `ConnectionStore.endExtensionHandOver`,
    /// which also restores what a save held off meanwhile). nil: the marker is only cleared.
    var onInstallDidNotHappen: (@MainActor () async -> Void)?
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "update")

    init(settings: SettingsStore, extensionStore: @escaping () -> (any ExtensionControlling)?,
         currentBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") {
        self.settings = settings
        self.extensionStore = extensionStore
        self.currentBuild = currentBuild
    }

    /// `allowedChannels(for:)` (§12.1): `["rc"]` while "Receive release candidates" is on; the default channel is
    /// always included by Sparkle.
    var allowedChannels: Set<String> { settings.value.receiveReleaseCandidates ? ["rc"] : [] }

    /// §12.3 step 8: no new update session while a replacement or a resume is in progress. nil = allowed.
    var refusalReason: String? {
        // E2E-4 review L3: before settings.json was read, the `expectedUpdate` marker can't be written (every write
        // refuses until then), and an install without it loses the hand-over after the relaunch.
        guard settings.loadedFromDisk else {
            log.error("update refused: settings.json hasn't been read yet, so the install marker can't be recorded")
            return String(localized: "LockPlus is still starting. Try again in a moment.", comment: "Sparkle refused an update session: settings not read yet (E2E-4 review L3)")
        }
        let x = extensionStore()
        let busy = (x?.updateInProgress ?? false) || x?.state == .activating || settings.value.pendingResume != nil
        return busy ? String(localized: "LockPlus is finishing a tunnel component update. Try again in a moment.",
                             comment: "Sparkle refused an update session (§12.3 step 8)") : nil
    }

    /// §12.3 step 2 (variant B): record `expectedUpdate` durably. Nothing is stopped: the tunnel keeps protecting the
    /// user during the install. (Quit confirmation only ever runs for our own menu, so no intent flag is needed.)
    func prepareForInstall(toVersion version: String) {
        if !settings.loadedFromDisk { log.fault("prepareForInstall before settings.json was read: the install marker is NOT recorded") }
        preparedForInstall = true
        settings.update { $0.expectedUpdate = ExpectedUpdate(from: currentBuild, to: version) }
        settings.writeSynchronously()          // Sparkle quits the app next; the async writer may not get to run
        log.notice("prepared for install \(self.currentBuild, privacy: .public) -> \(version, privacy: .public)")
    }

    /// §12.3 step 7: an abort or a failed cycle after `prepareForInstall`. Variant B stopped nothing, so only the
    /// markers are cleared.
    func installDidNotHappen() {
        guard preparedForInstall else { return }
        preparedForInstall = false
        // Review 5 #6: logged once the hand-over has really ended (the hook is async).
        let log = self.log
        guard let onInstallDidNotHappen else {
            settings.update { $0.expectedUpdate = nil }
            log.notice("install did not happen; expectedUpdate cleared")
            return
        }
        Task {
            await onInstallDidNotHappen()
            log.notice("install did not happen; expectedUpdate cleared")
        }
    }

    func updateAvailable(_ available: Bool) { onUpdateAvailableChange?(available) }
}
