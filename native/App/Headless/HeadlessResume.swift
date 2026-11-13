import Foundation
import LPModel
import LPWire
import LPXPCClient
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
/// 2.0.2: the restart of a manual profile is armed over XPC first (`StartArming`; the extension refuses a manual start
/// without its owner's arm, 225). A profile with on-demand rules is admitted as an unattended start instead, so if the
/// arm fails it starts with `StartOptionsBuilder.crashRestart` (no `lp.manual`); any other profile ends as
/// `.armUnavailable` and the next run retries. The arm lapses after 15 s and this run lives 5 s, so arming before the
/// run's own saves is safe, and a failed arm leaves everything as it found it.
///
/// The restart goes through the same `ProfilesStore.prepareForStart` as the GUI's (review F11): the manager is
/// brought up to date and, for a kill-switch profile, read back and verified. If that can't be done (the profile
/// can't be read here, or the flags don't hold) nothing starts, and every on-demand configuration paused for the
/// pause comes back: the same fail-closed outcome as a failed start.
///
/// 2.0.2 RC review: running out of time is never such a failure (`.outOfTime`, Fable M1/L1): nothing is spent, the
/// pause stays and the next run retries. The pause's one-time value is spent after the start is issued (Codex fix
/// MEDIUM), so a run ended by the hard deadline before that leaves the value for the next run, and one ended after it
/// leaves the target active, which the next run takes as the restart (Fable L2).
///
/// RC review 2: "the target is active" is decided once per run and never leads to a start; only an established
/// session counts as restarted (anything coming up, going down or changing mid-run is `.targetInTransition`, retried);
/// no start without a verified intent; running out of time is always a retry (2.0.2 limit: unbounded, bounded only by the 7-day intent age; 2.1 item).
enum HeadlessResume {
    static let argument = "--resume-protection"
    static let budget: Duration = .seconds(5)
    /// Review N8: what the run keeps for the start, the final settings write and the unregister after its settle.
    static let reserve: Duration = .seconds(1)
    /// 2.0.2 RC review (Fable L1): the least time to the hard deadline in which this run still starts, spends the pause's
    /// one-time value and writes the pause's end. With less, the run ends `.outOfTime` and the next run starts instead
    /// (a run cut off after its start is completed by the next one anyway; this keeps that the exception).
    static let minimumForStart: Duration = .milliseconds(500)
    /// 2.0.2 RC review (N2): the exit status of a run ended by the hard deadline (`EX_TEMPFAIL`), so `launchctl print`
    /// shows that the last run timed out. The agent has no KeepAlive: launchd doesn't start it again for this.
    static let timedOutExitStatus: Int32 = 75

    /// Where a run ran out of time (`Outcome.outOfTime`).
    enum Stage: String, Sendable, Equatable, CustomStringConvertible {
        /// No time left to arm the start.
        case arm
        /// No time left for the settle, or the configuration didn't settle within what was left (at most 2 s).
        case settle
        /// Settled, but less than `minimumForStart` to the hard deadline (Fable L1).
        case start
        var description: String { rawValue }
    }

    enum Outcome: Sendable, Equatable {
        case guiOwnsExpiry
        case notExpired
        /// No pause recorded: a stale registration; unregistered (round 5, Codex r5 #5: after the pause's one-time value
        /// went; if it can't be deleted now, `.keychainUnavailable` and the next run retries).
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
        /// 2.0.2 (PLAN-2.0.2 §3): the restart of a manual profile needs the extension's `armStart` and the extension
        /// didn't answer (or in time). Nothing changes (no start, no settings write); the pause stays and the agent stays
        /// registered, so the next run (a minute later) tries again, as for `.managersUnavailable`.
        case armUnavailable
        /// Round 2 (L5): the pause record's intent couldn't be checked (the keychain is unavailable). Nothing changes; the
        /// next run retries, as for `.armUnavailable`.
        case keychainUnavailable
        /// 2.0.2 RC review (Fable M1, L1): the run ran out of time before its start (a slow run, typically the coalesced
        /// one right after a wake). Returned before the pause's one-time value is spent: the pause stays, the agent stays
        /// registered, and the next minute's run retries, finding this run's on-demand saves done and the configuration
        /// settled. Only a definite failure (the profile can't be read, the kill-switch flags still disagree after the
        /// repair) ends the pause without its restart.
        case outOfTime(Stage)
        /// 2.0.2 RC review 2 (Fable M1, L2, N3): the paused profile's session was coming up (`.connecting`), going down
        /// (`.disconnecting`), or changed between this run's look at it and the start (the status it has now). Nothing is
        /// spent, armed or started; the pause stays and the agent stays registered, so the next minute's run looks again
        /// (and checks the record's intent before any start).
        case targetInTransition(TunnelStatus)
        /// Fault injection only (tests): the run stopped at `checkpoint`, as the hard deadline's `_exit` would stop it there.
        /// Never returned by the live run (`main()` passes no checkpoint hook).
        case stopped(at: Checkpoint)
    }

    /// Where a test may stop a run (`perform(checkpoint:)`), to check what the next run makes of what it left.
    enum Checkpoint: String, Sendable, Equatable, CustomStringConvertible {
        /// Verified and settled; the start not issued.
        case beforeStart
        /// The start issued (NE took it, or not); the pause's one-time value not spent yet.
        case afterStart
        /// The value spent; the final settings write (pause cleared) not done.
        case beforeFinalWrite
        var description: String { rawValue }
    }

    /// Testable core: every system dependency is injected (tests pass fakes and a scratch directory). Round 6 (Fable r6
    /// N3): `keychain` has no default, so a test can't reach the real data-protection keychain by leaving it out.
    /// `clock`: the monotonic time the run's deadlines are measured with (tests script it).
    ///
    /// 2.0.2 RC review (N1): the outcome is logged BEFORE the agent unregisters itself (that call kills this process).
    @MainActor static func perform(dir: AppDataDirectory, managers: any VPNManaging, agent: any ResumeAgentControlling,
                                   keychain: any SecretItemStore, now: Date = Date(),
                                   budget: Duration = budget, service: (any TunnelServicing)? = nil,
                                   clock: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
                                   checkpoint: @MainActor (Checkpoint) -> Bool = { _ in true }) async -> Outcome {
        let (outcome, unregister) = await run(dir: dir, managers: managers, keychain: keychain, now: now, budget: budget,
                                              service: service, clock: clock, checkpoint: checkpoint)
        Logger(subsystem: "io.github.steiale.lockplus.mac", category: "lifecycle")
            .notice("resume agent: \(String(describing: outcome), privacy: .public)")
        if unregister { await agent.unregister() }              // kills this process when it's the agent: nothing follows
        return outcome
    }

    /// `perform` up to the unregister: the outcome, and whether the agent unregisters now. `checkpoint` returning false
    /// stops the run there (fault injection, tests only).
    @MainActor private static func run(dir: AppDataDirectory, managers: any VPNManaging, keychain: any SecretItemStore, now: Date,
                                       budget: Duration, service: (any TunnelServicing)?,
                                       clock: @MainActor () -> ContinuousClock.Instant,
                                       checkpoint: @MainActor (Checkpoint) -> Bool) async -> (Outcome, unregister: Bool) {
        let hardDeadline = clock() + budget
        let deadline = hardDeadline - reserve
        guard let lock = InstanceLock.tryAcquire(at: dir.instanceLock) else { return (.guiOwnsExpiry, false) }
        defer { withExtendedLifetime(lock) {} }
        var settings: AppSettings
        switch AtomicFile.readResult(dir.settings, maxBytes: 1 << 20) {
        case .failure(.missing): settings = AppSettings()
        case .failure(.unreadable): return (.settingsUnreadable, false)
        case .success(let d):
            guard let s = try? AtomicFile.decoder().decode(AppSettings.self, from: d) else { return (.settingsUnreadable, false) }
            settings = s
        }
        let repository = ProfileRepository(directory: dir.profiles, keys: keychain)
        // Round 6 (Codex r6 #3, Fable r6 N4b): every spend of the pause's one-time value. One that fails is owed
        // (`pauseValueOwed`) and the agent stays registered until a run spends it. Round 7 (Codex r7 #2, Fable r7 N1):
        // a change of the debt is on disk before `spend()` returns, so no later return (`.networkRestartPending`,
        // `.armUnavailable`, …) and no watchdog exit loses it. Written over `onDisk`, what this run last wrote (or read),
        // so it never takes back the early on-demand write below.
        var owedNow = settings.pauseValueOwed
        var onDisk = settings
        @discardableResult func spend() async -> Bool {
            let ok = await repository.consumeRecord(.pause)
            owedNow = !ok
            if onDisk.pauseValueOwed != owedNow {
                onDisk.pauseValueOwed = owedNow
                settings.pauseValueOwed = owedNow
                try? AtomicFile.saveJSON(onDisk, to: dir.settings)
            }
            return ok
        }
        guard let until = settings.autoConnect.pausedUntil else {
            // Round 5 (Codex r5 #5): nothing is paused, so no pause can end later: its one-time value goes now (a genuine
            // record whose expiry was removed, written back with it later, never verifies). Kept registered until it went.
            let spent = await spend()
            guard spent else { return (.keychainUnavailable, false) }
            return (.nothingPaused, true)
        }
        guard until <= now else { return (.notExpired, false) }
        // Round 6 (Codex r6 #3): an owed value (a genuine record hidden while nothing was paused, written back since) goes
        // before anything is checked; until it can, nothing changes and the next run retries.
        if owedNow {
            guard await spend() else { return (.keychainUnavailable, false) }
        }
        let state = settings.pausedState
        do throws(LPError) { try await managers.loadAll() } catch { return (.managersUnavailable, false) }
        let known = Set(managers.managers.map(\.profileID))
        let all = (state?.onDemandEnabledIDs ?? []).filter(known.contains)
        var target = state?.profileID.flatMap { known.contains($0) ? $0 : nil }
        // Round 1 (Codex 3): settings.json is writable by any process of this user. Without the record's intent (HMAC
        // with the keychain-held metadata key, bound to the profile and the pause's end) this signed executable must not
        // become an `armStart` proxy: on-demand is restored as recorded, but nothing is armed or started.
        // Round 2 (L5): one shot, and a keychain that can't be read now is retried by the next run with nothing changed
        // (like `.armUnavailable`), never taken for a forged record.
        // 2.0.2 RC review (Codex fix MEDIUM, Fable L2): the hand-off is idempotent. The value is spent only AFTER the start
        // was issued, so a run ended at any point before that (the hard deadline's `_exit`) leaves the value for the next
        // run, which resumes once more. A run ended after its start leaves the target active; the next run takes that as
        // the restart (below: no arm, no second start, no other profile's on-demand beside it; the intent is checked for
        // the log only) and spends the value then. Once spent, no copy of the record restarts anything again.
        // Known 2.0.2 limit (Fable review 2 L1): a run stopped between its start and the spend leaves the value, so a
        // genuine record can start its profile once more per such stop (7 days at most); 2.1 seals a start marker instead.
        // 2.0.2 RC review 2 (Fable M1): whether the target is active is decided ONCE, here, and every later decision uses
        // it: a status that changes during the run's awaits never turns this path into a start without an intent check.
        let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "lifecycle")
        let alreadyActive = target.map { managers.status($0).isActive } ?? false
        var intentHolds = false                                 // set only on `.holds`; no start without it (M1)
        if let id = target, alreadyActive {
            // L2: only an established session is an earlier run's start; one still coming up (`scutil --nc start` would
            // show the same) is looked at again by the next run, which checks the intent if it is gone by then.
            let status = managers.status(id)
            guard status == .connected || status == .reasserting else { return (.targetInTransition(status), false) }
            // L2: no behaviour change, but a record that doesn't verify says so here too.
            let check = await ConnectionStore.checkResumeIntent(state, profileID: id, until: until, now: now, repository: repository)
            if check != .holds {
                log.fault("resume agent: pause record without a valid intent (\(String(describing: check), privacy: .public)) names an active profile")
            }
            log.notice("resume agent: the paused profile is active already (an earlier run started it); taken as restarted")
        } else if let id = target {
            // N3: a session still going down is no start now (NE would refuse it, ending the pause without its restart).
            if managers.status(id) == .disconnecting { return (.targetInTransition(.disconnecting), false) }
            let check = await ConnectionStore.checkResumeIntent(state, profileID: id, until: until, now: now, repository: repository)
            if check == .unavailable { return (.keychainUnavailable, false) }
            if check == .holds {
                intentHolds = true
            } else {
                await spend()                                   // round 3 (Fable L2): the pause ends here in every case
                log.fault("resume agent: pause record without a valid intent (\(String(describing: check), privacy: .public)); the paused profile is not restarted")
                target = nil
            }
        } else {
            // Round 3 (L2), round 4 (Codex r4 #4): the pause ends in this run, so its one-time value goes: a record naming
            // no known profile, naming none (a removed `profileID`), or no record at all. (Fable r5 N4: a later return that
            // keeps the pause, `.networkRestartPending`, `.armUnavailable`, then has no target to verify.)
            await spend()
        }
        // E2E-4 200011: NE restarts a kill-switch session it refused with "No network available" by itself once a network
        // returns. While that restart is live nothing is restored or started beside it; while it is still coming, it is
        // stopped first as the user would (`stopVPNTunnel` on the disconnected session cancels it, measured), unless it is
        // the very profile this run restarts (NE's restart and this start are the same session). The record ends below.
        let held = settings.networkRestartHold.flatMap { known.contains($0) ? $0 : nil }
        if let held {
            if managers.status(held).isLive, held != target { return (.networkRestartPending, false) }   // review b47da1c L-5
            if held != target { managers.stop(held) }
        }
        // 2.0.2: the arm (see the type's comment). Only where this run issues a start itself. `service == nil` is for tests
        // that don't exercise arming; `main()` always passes the live one.
        var startOptions = StartOptionsBuilder.options()
        var armFailure: LPError?
        // Out of time is always a retry (Fable fix-3 M1). Documented 2.0.2 limit: the retry is unbounded, bounded only by
        // the 7-day intent age; a first-seen anchor (with `.targetInTransition`, L1) is a 2.1 item.
        if let id = target, let service, !alreadyActive {
            let cap = min(.seconds(2), deadline - clock())
            if cap <= .zero {
                return (.outOfTime(.arm), false)     // Fable M1: retried, nothing spent or changed
            } else {
                switch await StartArming.arm(id, service: service, cap: cap) {
                case .armed(let nonce): startOptions = StartOptionsBuilder.options(nonce: nonce)
                case .legacyExtension:
                    // Round 2 (Fable L6): never a kill-switch start without a nonce (its restart into the replacement
                    // would be refused); fails closed below, like a definite arm failure. Review 2 (M1): every start of
                    // this run passes here (an active target is never started), so no path skips this refusal.
                    if StartArming.refusesKillSwitchStart(onLegacyExtension: managers.managers.first { $0.profileID == id }?.flags?.includeAllNetworks ?? true) {
                        armFailure = LPError(.versionMismatch, detail: "kill-switch start waits for the tunnel component update")
                    }
                case .failed(let e):
                    if (state?.onDemandEnabledIDs ?? []).contains(id) {
                        startOptions = StartOptionsBuilder.crashRestart   // unattended: the profile's on-demand rules admit it
                    } else if StartArming.isDefinite(e) {
                        armFailure = e                                      // not provisioned here: the fail-closed path below
                    } else {
                        return (.armUnavailable, false)
                    }
                }
            }
        }
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
            onDisk = early
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
                // Review 2 (M1): a target that was active at the run's first look is never started by this run, whatever
                // its status is now; (L2) only an established session counts as restarted, anything else is retried.
                let status = managers.status(id)
                if alreadyActive || status.isLive {
                    guard status == .connected || status == .reasserting else { return (.targetInTransition(status), false) }
                } else {
                    if let armFailure { throw armFailure }
                    // Fable M1, L1: out of time is no failure. Nothing is spent and the pause stays (the early write above
                    // kept it): the agent stays registered and the next minute's run retries.
                    if let stage = try await verifyForStart(id, settings: settings, dir: dir, managers: managers, keychain: keychain,
                                                            deadline: deadline, hardDeadline: hardDeadline, clock: clock) {
                        return (.outOfTime(stage), false)
                    }
                    // Review 2 (M1): no start is ever issued without the record's verified intent.
                    guard intentHolds else {
                        log.fault("resume agent: start without a verified intent refused")
                        throw LPError(.unauthorizedPeer, detail: "pause record intent not verified")
                    }
                    guard checkpoint(.beforeStart) else { return (.stopped(at: .beforeStart), false) }
                    try managers.start(id, options: startOptions)
                    guard checkpoint(.afterStart) else { return (.stopped(at: .afterStart), false) }
                }
                await spend()                                   // round 2 (L5), Codex fix MEDIUM: spent by the issued start
                restarted = id
            } catch {
                await spend()                                   // round 3 (L2): the pause ends without its start
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
        // Round 3 (Codex r3 #4): the hold's record ends with the pause, in this write (an earlier return leaves both).
        if settings.networkRestartHold != nil { await repository.consumeRecord(.networkRestartHold) }
        settings.networkRestartHold = nil
        settings.networkRestartHoldTag = nil
        settings.autoConnect.pausedUntil = nil
        settings.pausedState = nil
        settings.pauseValueOwed = owedNow
        guard checkpoint(.beforeFinalWrite) else { return (.stopped(at: .beforeFinalWrite), false) }
        try? AtomicFile.saveJSON(settings, to: dir.settings)     // fsync + rename, BEFORE the self-unregister
        // Round 6 (Codex r6 #3): kept registered while the value is owed (the next run, nothing paused, spends it).
        return (.resumed(restarted: restarted, onDemand: onDemand), !owedNow)
    }

    /// Review F11: the GUI's `prepareForStart` on a `ProfilesStore` built over the same data directory (profiles,
    /// settings, keychain) with no tunnel service. Throws when the profile can't be read or isn't verified, or the
    /// kill-switch flags still disagree with it after the repair attempt (definite: the pause ends without its start).
    /// Returns the stage that ran out of time (Fable M1, L1: retried by the next run), nil when the start may go ahead.
    @MainActor private static func verifyForStart(_ id: UUID, settings: AppSettings, dir: AppDataDirectory, managers: any VPNManaging,
                                                  keychain: any SecretItemStore, deadline: ContinuousClock.Instant,
                                                  hardDeadline: ContinuousClock.Instant,
                                                  clock: @MainActor () -> ContinuousClock.Instant) async throws(LPError) -> Stage? {
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
        // always gets to its settings write. Fable M1: a configuration that doesn't settle in what is left is no start
        // now (fail closed) and no failure either: the next run retries, with this run's saves long settled.
        let cap = min(.seconds(2), deadline - clock())
        guard cap > .zero, await managers.waitUntilSettled(store.settleBeforeStart, cap: cap) else { return .settle }
        // Fable L1: the start, the spend and the final write need time before the hard deadline.
        guard hardDeadline - clock() >= minimumForStart else { return .start }
        return nil
    }

    /// The live entry point (from `main.swift`). Never returns.
    ///
    /// 200026 E2E S9 (release blocker): driven by `HeadlessRunner`: the main thread runs its run loop (under the former
    /// `dispatchMain()` NE's first status notification deadlocked the main queue) and the 5 s budget is a hard deadline
    /// on its own queue (the former main-queue watchdog never fired while the main queue was stuck).
    @MainActor static func main() -> Never {
        let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "lifecycle")
        let ext = Bundle.main.object(forInfoDictionaryKey: "LPTunnelBundleIdentifier") as? String ?? "io.github.steiale.lockplus.mac.tunnel"
        HeadlessRunner.start(timeout: budget, work: { @MainActor @Sendable in
            _ = await perform(dir: .standard(), managers: SerializedVPNManager(inner: NEManagerStore(providerBundleIdentifier: ext)),
                              agent: SMResumeAgent(), keychain: DataProtectionKeychain(), service: liveService())
        }, end: { @Sendable end in finish(end, log: log) })
        HeadlessRunner.runMainLoop()
    }

    /// The process's end. A run that doesn't finish within the budget leaves what it hasn't done for the next run: the
    /// pause stays set (cleared only by the final write), the agent stays registered (unregistered only after it), and
    /// every change of the pause's one-time value debt is on disk already (`spend()`), so the next minute's run retries.
    /// `_exit`, not `exit`, for both ends (2.0.2 RC review, Fable L4): no atexit handler or static destructor may hold
    /// the process once it is done. A finished run logged its outcome and its settings writes are fsynced already.
    private nonisolated static func finish(_ end: HeadlessRunner.End, log: Logger) -> Never {
        if end == .timedOut {
            log.error("resume agent: no result within \(budget, privacy: .public); exiting, the next run retries")
        }
        _exit(exitStatus(end))
    }

    /// 0 for a finished run; `timedOutExitStatus` (75) for one ended by the hard deadline (N2).
    nonisolated static func exitStatus(_ end: HeadlessRunner.End) -> Int32 {
        end == .finished ? 0 : timedOutExitStatus
    }

    /// The live XPC service of the embedded extension (the Mach name from its Info.plist, `EXT_REQ`), as `AppEnvironment`
    /// builds it. A bundle without one gets the unavailable service (every arm fails: `.armUnavailable`).
    @MainActor private static func liveService(bundle: Bundle = .main) -> any TunnelServicing {
        // The same lookup as `SystemExtensionManager.machServiceName`, without building the manager (no UI, no observers).
        let id = bundle.object(forInfoDictionaryKey: "LPTunnelBundleIdentifier") as? String ?? "io.github.steiale.lockplus.mac.tunnel"
        let ext = Bundle(url: bundle.bundleURL.appending(path: "Contents/Library/SystemExtensions/\(id).systemextension"))
        guard let name = (ext?.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any])?["NEMachServiceName"] as? String else {
            return UnavailableTunnelService()
        }
        return XPCTunnelService(client: TunnelServiceClient(
            machServiceName: name, peerRequirement: EXT_REQ,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))
    }

}
