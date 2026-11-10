import AppKit
import Foundation
import os
import Sparkle

/// What the app root needs from the updater. `UpdateController` is Sparkle; preview mode and tests use
/// `PreviewUpdater`/`InertUpdater`, which never touch the network.
@MainActor protocol Updating: AnyObject {
    /// §12.1: called once, after `SystemExtensionManager.activate()` has finished its preflight.
    func start()
    /// The "Check for Updates…" and "Update Available…" commands (user-initiated only).
    func checkForUpdates()
    /// Settings › Advanced › "Receive release candidates" changed.
    func channelsChanged()
    /// KVO mirror of `SPUUpdater.canCheckForUpdates`.
    var onCanCheckChange: ((Bool) -> Void)? { get set }
}

/// Sparkle 2.10.1 (DESIGN §12.1, ref/sparkle §2.5, §5): `SPUStandardUpdaterController(startingUpdater: false)`,
/// started after the activation preflight. One object is both delegates and is held strongly by `AppEnvironment`
/// (Sparkle holds delegates weakly since 2.8.1). All Sparkle API is main-thread only, so the class is `@MainActor`.
///
/// The feed URL and EdDSA public key come from Info.plist. Both are placeholders until the owner decides the Pages
/// host (§2.5) and runs `generate_keys --account lockplus-native` (§12.1); with a placeholder the updater is never
/// started (it would fail `SURequireSignedFeed` and show an error), and "Check for Updates…" stays disabled.
@MainActor final class UpdateController: NSObject, Updating, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let coordinator: UpdateCoordinator
    private var standard: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?
    private var started = false
    var onCanCheckChange: ((Bool) -> Void)?
    private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "update")

    init(coordinator: UpdateCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    /// Placeholder detection (pure, tested): an `.invalid` feed host or a public key that isn't 32 bytes of base64.
    nonisolated static func isConfigured(feedURL: String?, publicKey: String?) -> Bool {
        guard let feedURL, let url = URL(string: feedURL), url.scheme == "https", let host = url.host(), !host.hasSuffix(".invalid") else {
            return false
        }
        guard let publicKey, let key = Data(base64Encoded: publicKey), key.count == 32 else { return false }
        return true
    }

    func start() {
        guard !started else { return }
        started = true
        let info = Bundle.main.infoDictionary ?? [:]
        guard Self.isConfigured(feedURL: info["SUFeedURL"] as? String, publicKey: info["SUPublicEDKey"] as? String) else {
            log.notice("updater not started: SUFeedURL/SUPublicEDKey are placeholders (owner decision, DESIGN §2.5)")
            onCanCheckChange?(false)
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        standard = controller
        // KVO fires on the thread that changed the value (Sparkle: main). Sendable values only, then a main-actor hop.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { @Sendable [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.onCanCheckChange?(can) }
        }
        // Fable M4: Sparkle reads SUFeedURL and the automatic-update flags from user defaults first; a value planted
        // there (`defaults write`) must not win over the signed Info.plist decisions.
        controller.updater.clearFeedURLFromUserDefaults()
        controller.startUpdater()
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = false
        log.notice("updater started")
    }

    func checkForUpdates() {
        guard let standard else { return }
        coordinator.updateAvailable(false)
        standard.updater.checkForUpdates()          // never checkForUpdatesInBackground() (§12.1)
    }

    func channelsChanged() { standard?.updater.resetUpdateCycleAfterShortDelay() }

    // MARK: SPUUpdaterDelegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> { coordinator.allowedChannels }

    /// Fable M4: always the Info.plist feed, never a user-defaults override.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    /// §12.3 step 8.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if let reason = coordinator.refusalReason {
            throw NSError(domain: "io.github.steiale.lockplus.mac.update", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    /// §12.3 step 2 (variant B). Once per Install-and-Relaunch session; never for install-on-quit. Records the intent,
    /// then invokes the block on the next main-queue turn (review L9: never from inside the delegate call, which
    /// Sparkle documents as "delay … until installHandler is invoked").
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping @Sendable () -> Void) -> Bool {
        coordinator.prepareForInstall(toVersion: item.versionString)
        DispatchQueue.main.async { @Sendable in installHandler() }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        log.notice("Sparkle installing \(item.versionString, privacy: .public)")
    }

    /// §12.3 step 7.
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) { coordinator.installDidNotHappen() }

    /// L9: "no update found" (SUNoUpdateError) isn't a failed install.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard let error else { return }
        if Self.isNoUpdate(error as NSError) { return }
        coordinator.installDidNotHappen()
    }

    nonisolated static func isNoUpdate(_ e: NSError) -> Bool {
        e.domain == SUSparkleErrorDomain && e.code == Int(SUError.noUpdateError.rawValue)
    }
    // No bestValidUpdate(in:for:) override (§12.1, ref/sparkle C4).

    // MARK: SPUStandardUserDriverDelegate: gentle reminders (§12.1, ref/sparkle §5.6)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows the alert itself only in immediate focus (at launch); otherwise the menu gets "Update Available…".
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let userInitiated = state.userInitiated
        Task { @MainActor in if !userInitiated { self.coordinator.updateAvailable(true) } }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.coordinator.updateAvailable(false) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.coordinator.updateAvailable(false) }
    }
}

/// No updater (tests, and the default before `liveBackends` installs Sparkle). Never reports an update.
@MainActor final class InertUpdater: Updating {
    var onCanCheckChange: ((Bool) -> Void)?
    func start() {}
    func checkForUpdates() {}
    func channelsChanged() {}
}

#if DEBUG
/// Preview mode: no network, no Sparkle. After start it advertises an update, so the menu's "Update Available…" item
/// and Settings' "Check for Updates…" can be demonstrated.
@MainActor final class PreviewUpdater: Updating {
    private let coordinator: UpdateCoordinator
    var onCanCheckChange: ((Bool) -> Void)?
    private(set) var checks = 0

    init(coordinator: UpdateCoordinator) { self.coordinator = coordinator }

    func start() {
        onCanCheckChange?(true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            coordinator.updateAvailable(true)
        }
    }

    func checkForUpdates() {
        checks += 1
        coordinator.updateAvailable(false)
    }

    func channelsChanged() {}
}
#endif
