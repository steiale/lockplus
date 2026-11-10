import Foundation
import LPModel
import os

/// The GUI instance lock (§10.4): `flock(LOCK_EX|LOCK_NB)` on `instance.lock` in the data directory, held by every
/// GUI instance for its lifetime. The headless agent takes it non-blocking and exits when a GUI owns expiry.
/// (`NSRunningApplication` can't tell: the agent *is* that bundle, and a launchd-spawned process isn't an LS app.)
final class InstanceLock: Sendable {
    let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// nil = another process holds it (or the file can't be opened).
    static func tryAcquire(at url: URL) -> InstanceLock? {
        try? AtomicFile.ensureDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return InstanceLock(fd: fd)
    }

    deinit { close(fd) }      // closing the descriptor releases the lock
}

/// `LockPlus --resume-protection` (§10.4), handled in `main.swift` before the app starts. Headless, no UI, exits within
/// 5 s:
/// 1. take the GUI instance lock non-blocking; if a GUI holds it, that GUI owns expiry → exit 0;
/// 2. `pausedUntil` in the future → exit 0;
/// 3. otherwise restore on-demand and restart the paused profile, write settings.json atomically with the pause
///    cleared, THEN unregister the agent. That call kills this process, so nothing may follow it (C11).
///    E2E-4 200011: a recorded `networkRestartHold` whose session is live leaves everything as it is (next run); one that
///    is still coming is stopped first (unless it is the profile restarted here).
///
/// The restart goes through the same `ProfilesStore.prepareForStart` as the GUI's (review F11): the manager is
/// brought up to date and, for a kill-switch profile, read back and verified. If that can't be done (the profile
/// can't be read here, or the flags don't hold) nothing starts, and every on-demand configuration paused for the
/// pause comes back: the same fail-closed outcome as a failed start.
enum HeadlessResume {
    static let argument = "--resume-protection"
    static let budget: Duration = .seconds(5)
    /// Review N8: what the run keeps for the start, the final settings write and the unregister after its settle.
    static let reserve: Duration = .seconds(1)

    enum Outcome: Sendable, Equatable {
        case guiOwnsExpiry
        case notExpired
        /// No pause recorded: a stale registration; unregistered.
        case nothingPaused
        case resumed(restarted: UUID?, onDemand: [UUID])
        /// The NE configurations couldn't be read: the pause stays, the next run (a minute later) retries (review L12).
        case managersUnavailable
        /// settings.json exists but couldn't be read or decoded (E2E-4): nothing changes, the file stays where it is
        /// (the GUI moves it aside and says so), and the agent stays registered for the next run.
        case settingsUnreadable
        /// E2E-4 200011: the GUI was waiting for NE's own restart of a kill-switch session after "No network available"
        /// (`networkRestartHold`), and that session is live now (restarting or running): nothing changes beside it (no
        /// on-demand, no start); the pause stays and the next run (a minute later) looks again.
        case networkRestartPending
    }

    /// Testable core: every system dependency is injected (tests pass fakes and a scratch directory).
    @MainActor static func perform(dir: AppDataDirectory, managers: any VPNManaging, agent: any ResumeAgentControlling,
                                   keychain: any SecretItemStore = DataProtectionKeychain(), now: Date = Date(),
                                   budget: Duration = budget) async -> Outcome {
        let deadline = ContinuousClock.now + budget - reserve
        guard let lock = InstanceLock.tryAcquire(at: dir.instanceLock) else { return .guiOwnsExpiry }
        defer { withExtendedLifetime(lock) {} }
        var settings: AppSettings
        switch AtomicFile.readResult(dir.settings, maxBytes: 1 << 20) {
        case .failure(.missing): settings = AppSettings()
        case .failure(.unreadable): return .settingsUnreadable
        case .success(let d):
            guard let s = try? AtomicFile.decoder().decode(AppSettings.self, from: d) else { return .settingsUnreadable }
            settings = s
        }
        guard let until = settings.autoConnect.pausedUntil else {
            await agent.unregister()
            return .nothingPaused
        }
        guard until <= now else { return .notExpired }
        let state = settings.pausedState
        do throws(LPError) { try await managers.loadAll() } catch { return .managersUnavailable }
        let known = Set(managers.managers.map(\.profileID))
        let all = (state?.onDemandEnabledIDs ?? []).filter(known.contains)
        let target = state?.profileID.flatMap { known.contains($0) ? $0 : nil }
        // E2E-4 200011: NE restarts a kill-switch session it refused with "No network available" by itself once a network
        // returns. While that restart is live nothing is restored or started beside it; while it is still coming, it is
        // stopped first as the user would (`stopVPNTunnel` on the disconnected session cancels it, measured), unless it is
        // the very profile this run restarts (NE's restart and this start are the same session). The record ends below.
        let held = settings.networkRestartHold.flatMap { known.contains($0) ? $0 : nil }
        if let held {
            if managers.status(held).isLive, held != target { return .networkRestartPending }   // review b47da1c L-5
            if held != target { managers.stop(held) }
        }
        settings.networkRestartHold = nil
        // E2E-3: no OTHER configuration's on-demand while a profile starts (a network change would leave it blocked).
        // The GUI restores those when the restarted profile ends, or at its next launch.
        var onDemand = all.filter { target == nil || $0 == target }
        // Review N8: what stays off while the target runs is on disk BEFORE anything that can outlast the 5 s watchdog
        // (whose exit leaves the pause set, so the next run retries; the GUI restores the record when the target ends).
        // Simplification 3 (review 4): computed once; the final write records it only if the target runs.
        let owed = all.filter { !onDemand.contains($0) }
        if !owed.isEmpty {
            var early = settings
            for id in owed where !early.onDemandPausedByStart.contains(id) { early.onDemandPausedByStart.append(id) }
            try? AtomicFile.saveJSON(early, to: dir.settings)
        }
        var failedRestores: [UUID] = []           // never `try?`: a failure stays recorded for the GUI's retry (review F4)
        for id in onDemand {
            do throws(LPError) { try await managers.setOnDemandEnabled(true, for: id) } catch { failedRestores.append(id) }
        }
        var restarted: UUID?
        if let id = target {
            do throws(LPError) {
                // Review 4 #6: a previous run that the watchdog ended after its start finds the target live: it runs, so
                // nothing is verified (`prepareForStart` could save a live manager, L-KS-2) and nothing is started again.
                if !managers.status(id).isActive {
                    try await verifyForStart(id, settings: settings, dir: dir, managers: managers, keychain: keychain, deadline: deadline)
                    try managers.start(id, options: StartOptionsBuilder.options())
                }
                restarted = id
            } catch {
                // E2E-4 200011: the target's own restart by NE is still coming: stopped before anything is restored.
                if held == id { managers.stop(id) }
                for id in owed {
                    do throws(LPError) { try await managers.setOnDemandEnabled(true, for: id) } catch { failedRestores.append(id) }
                }
                onDemand = all
            }
        }
        // E2E-3: what stays off while the restarted profile runs is recorded for the GUI (it restores when that profile
        // ends, or at its next launch), together with anything that couldn't be turned back on.
        for id in (restarted == nil ? [] : owed) + failedRestores where !settings.onDemandPausedByStart.contains(id) {
            settings.onDemandPausedByStart.append(id)
        }
        settings.autoConnect.pausedUntil = nil
        settings.pausedState = nil
        try? AtomicFile.saveJSON(settings, to: dir.settings)     // fsync + rename, BEFORE the self-unregister
        let outcome = Outcome.resumed(restarted: restarted, onDemand: onDemand)
        await agent.unregister()                                // kills this process when it's the agent
        return outcome
    }

    /// Review F11: the GUI's `prepareForStart` on a `ProfilesStore` built over the same data directory (profiles,
    /// settings, keychain) with no tunnel service. Throws when the profile can't be read or isn't verified, or the
    /// kill-switch flags still disagree with it after the repair attempt.
    @MainActor private static func verifyForStart(_ id: UUID, settings: AppSettings, dir: AppDataDirectory, managers: any VPNManaging,
                                                  keychain: any SecretItemStore, deadline: ContinuousClock.Instant) async throws(LPError) {
        let store = ProfilesStore(repository: ProfileRepository(directory: dir.profiles, keys: keychain),
                                  credentialStore: CredentialStore(items: keychain), managers: managers,
                                  service: UnavailableTunnelService(), settings: SettingsStore(value: settings, files: nil),
                                  factsFile: dir.credentialFacts)
        store.mutationBlocked = { _ in true }       // reading only: another configuration is never saved while a start is pending (F5)
        store.readsCredentialFacts = false          // and no keychain scan to rebuild the facts file (nothing here shows them)
        await store.load()
        guard store.loaded, let p = store.profile(id), p.engineVerified else {
            throw LPError(.profileNotProvisioned, detail: "profile not readable or not verified")
        }
        try await store.prepareForStart(p)
        // Review R6: the same settle as the GUI's (`ConnectionStore.startNow`) after this run's own saves (the target's
        // on-demand, a repair). Review N8: capped by what is left of the watchdog's budget (at most 2 s), so the run
        // always gets to its settings write; a configuration that doesn't settle in time is no start (fail closed).
        let cap = min(.seconds(2), deadline - ContinuousClock.now)
        guard cap > .zero, await managers.waitUntilSettled(store.settleBeforeStart, cap: cap) else {
            throw LPError(.killSwitchNotApplied, detail: "configuration not settled")
        }
    }

    /// The live entry point (from `main.swift`). Never returns.
    @MainActor static func main() -> Never {
        let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "lifecycle")
        let ext = Bundle.main.object(forInfoDictionaryKey: "LPTunnelBundleIdentifier") as? String ?? "io.github.steiale.lockplus.mac.tunnel"
        Task { @MainActor in
            let outcome = await perform(dir: .standard(), managers: SerializedVPNManager(inner: NEManagerStore(providerBundleIdentifier: ext)),
                                        agent: SMResumeAgent())
            log.notice("resume agent: \(String(describing: outcome), privacy: .public)")
            exit(0)
        }
        scheduleWatchdog()
        dispatchMain()
    }

    /// The 5 s budget: the agent never lingers (a hung NE call ends with the process; the next minute retries).
    private nonisolated static func scheduleWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5)) { @Sendable in exit(0) }
    }
}
