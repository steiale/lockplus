import Foundation
import LPModel
import LPWire
import Synchronization
import Testing
@testable import LockPlus

/// 2.0.2 RC review of the 200027 fixes (Fable M1, L1, L2, L4, N5; Codex fix MEDIUM): a headless run that runs out of
/// time is retried, never ends the pause; the pause's one-time value is spent only after the start was issued, so a run
/// stopped by the hard deadline at any point leaves a state the next run completes (no second start, no lost restart).
/// The run's deadlines are measured with a scripted clock (deterministic); "stopped" runs end at a checkpoint the way the
/// hard deadline's `_exit` ends them: nothing after it happens.
@MainActor @Suite("Headless resume: retry and idempotent hand-off (2.0.2 RC)", .serialized, .timeLimit(.minutes(1)))
struct HeadlessResumeRetryTests {
    /// Monotonic time for `perform(clock:)`: the n-th reading is `origin + offsets[n]` (the last offset repeats).
    final class ScriptedClock {
        let origin = ContinuousClock.now
        let offsets: [Duration]
        private(set) var readings = 0
        init(_ offsets: [Duration]) { self.offsets = offsets }
        func now() -> ContinuousClock.Instant {
            defer { readings += 1 }
            return origin + offsets[min(readings, offsets.count - 1)]
        }
    }

    func read(_ h: Harness) -> AppSettings? { AtomicFile.loadJSON(AppSettings.self, from: h.dir.data.settings) }

    /// An expired, genuinely sealed pause of `profile`, with `onDemand` paused for it.
    @discardableResult
    func pause(_ h: Harness, _ profile: UUID, onDemand: [UUID] = [], endedAgo: TimeInterval = 5) async throws -> AppSettings {
        var s = AppSettings()
        let until = ResumeIntent.wholeSeconds(Date().addingTimeInterval(-endedAgo))
        s.autoConnect.pausedUntil = until
        s.pausedState = PausedState(profileID: profile, onDemandEnabledIDs: onDemand, agentBuild: "1",
                                    intent: await resumeIntent(profile, until: until, keychain: h.keychain, dir: h.dir.data))
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        return s
    }

    func intent(_ h: Harness, _ s: AppSettings, _ profile: UUID) async -> ResumeIntent.Check {
        await ConnectionStore.checkResumeIntent(s.pausedState, profileID: profile, until: s.autoConnect.pausedUntil, now: Date(),
                                                repository: h.env.profiles.repository)
    }

    /// The pause is still there as written: the next run retries.
    func expectPauseKept(_ h: Harness, _ s: AppSettings, sourceLocation: SourceLocation = #_sourceLocation) {
        let disk = read(h)
        #expect(disk?.autoConnect.pausedUntil == s.autoConnect.pausedUntil, sourceLocation: sourceLocation)
        #expect(disk?.pausedState == s.pausedState, sourceLocation: sourceLocation)
        #expect(disk?.pauseValueOwed == false, sourceLocation: sourceLocation)
    }

    /// A settle clock for which every sleep is followed by another configuration change: it never settles.
    func streamingClock(_ inner: FakeVPNManager) -> SettleClock {
        let t = Mutex<Duration>(.zero)
        let managers = inner
        return SettleClock(now: { t.withLock { $0 } }, sleep: { d in
            t.withLock { $0 += d }
            await MainActor.run { managers.onConfigurationChange?() }
        })
    }

    // MARK: M1: out of time is retried

    /// A configuration that doesn't settle within what is left: no start, nothing spent, the pause and the agent stay;
    /// the next run (configuration settled) restarts the profile and spends the value.
    @Test func aSettleThatRunsOutOfTimeIsRetried() async throws {
        let inner = FakeVPNManager()
        let h = Harness(managers: inner)
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        // The target's own on-demand is restored through the serialized manager: the mutation the settle waits out.
        let s = try await pause(h, work.id, onDemand: [work.id, auto.id])
        let agent = ProbeResumeAgent()
        let streaming = SerializedVPNManager(inner: inner, settleClock: streamingClock(inner))
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: streaming, agent: agent, keychain: h.keychain)
        #expect(r == .outOfTime(.settle))
        #expect(inner.starts.isEmpty && agent.calls.isEmpty)
        expectPauseKept(h, s)
        #expect(await intent(h, s, work.id) == .holds)
        #expect(read(h)?.onDemandPausedByStart == [auto.id])             // on disk before the settle (review N8)

        let again = await HeadlessResume.perform(dir: h.dir.data, managers: inner, agent: agent, keychain: h.keychain)
        #expect(again == .resumed(restarted: work.id, onDemand: [work.id]))
        #expect(inner.starts.count == 1)
        #expect(agent.calls.count == 1 && agent.calls[0].hasPrefix("unregister"))
        #expect(read(h)?.autoConnect.pausedUntil == nil)
        #expect(await intent(h, s, work.id) == .changedOutside)          // spent by the start
    }

    /// No time left for the settle at all (the soft deadline passed during the run's own saves): retried.
    @Test func noTimeLeftForTheSettleIsRetried() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let s = try await pause(h, work.id)
        let agent = ProbeResumeAgent()
        let clock = ScriptedClock([.zero, .milliseconds(4100)])           // start; then past budget − reserve (4 s)
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             clock: { clock.now() })
        #expect(r == .outOfTime(.settle))
        #expect(h.managers.starts.isEmpty && agent.calls.isEmpty)
        expectPauseKept(h, s)
        #expect(await intent(h, s, work.id) == .holds)
    }

    /// No time left to arm: nothing is armed, changed or spent.
    @Test func noTimeLeftToArmIsRetried() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let s = try await pause(h, work.id)
        let before = try Data(contentsOf: h.dir.data.settings)
        let agent = ProbeResumeAgent()
        let clock = ScriptedClock([.zero, .milliseconds(4200)])
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service, clock: { clock.now() })
        #expect(r == .outOfTime(.arm))
        #expect(h.service.state.withLock { $0.arms.isEmpty })
        #expect(h.managers.starts.isEmpty && agent.calls.isEmpty)
        #expect(try Data(contentsOf: h.dir.data.settings) == before)
        #expect(await intent(h, s, work.id) == .holds)
    }

    /// A definite failure still ends the pause (unchanged): the profile can't be read here.
    @Test func aDefiniteFailureStillEndsThePause() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        try await pause(h, work.id)
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: InMemoryKeychain())
        #expect(r == .resumed(restarted: nil, onDemand: []))
        #expect(h.managers.starts.isEmpty)
        #expect(read(h)?.autoConnect.pausedUntil == nil)
    }

    // MARK: L1: too close to the hard deadline to start

    @Test func lessThanHalfASecondToTheHardDeadlineIsRetried() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let s = try await pause(h, work.id)
        let agent = ProbeResumeAgent()
        // Readings: the run's start, the settle's cap, after the settle (0.4 s to the 5 s hard deadline).
        let late = ScriptedClock([.zero, .zero, .milliseconds(4600)])
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             clock: { late.now() }) == .outOfTime(.start))
        #expect(late.readings == 3)
        #expect(h.managers.starts.isEmpty && agent.calls.isEmpty)
        expectPauseKept(h, s)
        #expect(await intent(h, s, work.id) == .holds)                   // not spent: no tamper verdict next time
        // 0.6 s left: the start goes ahead.
        let inTime = ScriptedClock([.zero, .zero, .milliseconds(4400)])
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             clock: { inTime.now() }) == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.starts.count == 1)
    }

    // MARK: L2: the target is active already

    /// A previous run started the target and was ended before its final write, and the value is gone (a 2.0.2 RC run
    /// spent it before its start): taken as restarted, no tamper verdict, no arm, no second start, and no other
    /// profile's on-demand beside the running target (E2E-3).
    @Test func anActiveTargetIsTakenAsRestarted() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        try await pause(h, work.id, onDemand: [auto.id])
        await h.env.profiles.repository.consumeRecord(.pause)
        h.managers.entries[work.id]?.status = .connected
        h.managers.entries[auto.id]?.onDemand = false
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service)
        #expect(r == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.starts.isEmpty)
        #expect(h.service.state.withLock { $0.arms.isEmpty })
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        let disk = try #require(read(h))
        #expect(disk.onDemandPausedByStart == [auto.id])
        #expect(disk.autoConnect.pausedUntil == nil && disk.pausedState == nil)
        #expect(agent.calls.count == 1)
    }

    // MARK: Review 2 (M1): "already active" is decided once; no start without a verified intent

    /// A record whose intent doesn't verify (a forged copy of a genuine pause: same profile and end, another tag).
    func forge(_ h: Harness, _ s: AppSettings) throws {
        var f = s
        f.pausedState?.intent = String(repeating: "0", count: 64)
        try AtomicFile.saveJSON(f, to: h.dir.data.settings)
    }

    /// The reviewer's scenario: a forged record names a profile that `scutil --nc start` keeps in `.connecting`; the
    /// refused start ends while this run awaits its on-demand saves. Nothing is started or armed, and the genuine pause's
    /// value is not spent: the run doesn't count a session still coming up as restarted (L2) and returns before any save.
    @Test func aForgedRecordNamingAConnectingProfileStartsNothing() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let s = try await pause(h, work.id, onDemand: [work.id])
        try forge(h, s)
        let before = try Data(contentsOf: h.dir.data.settings)
        h.managers.entries[work.id]?.status = .connecting
        h.managers.onSetOnDemand = { id, _ in h.managers.entries[id]?.status = .disconnected }   // the refused start ends
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service)
        #expect(r == .targetInTransition(.connecting))
        #expect(h.managers.starts.isEmpty && agent.calls.isEmpty)
        #expect(h.service.state.withLock { $0.arms.isEmpty })
        #expect(try Data(contentsOf: h.dir.data.settings) == before)
        #expect(await intent(h, s, work.id) == .holds)                   // the genuine value is unspent
    }

    /// The same with an established session that ends during the on-demand save, against an extension that predates
    /// start authorisation and a kill-switch profile (the case where the start would be admitted): the run that took the
    /// target as active never starts it (retry, nothing spent); the next run checks the intent and starts nothing.
    @Test func aTargetThatStopsDuringTheRunIsNotStartedWithoutAnIntentCheck() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let s = try await pause(h, work.id, onDemand: [work.id])
        try forge(h, s)
        h.service.state.withLock { $0.armError = LPError(.extensionUnavailable); $0.startAuthorisation = false }
        h.managers.entries[work.id]?.status = .connected
        h.managers.onSetOnDemand = { id, _ in h.managers.entries[id]?.status = .disconnected }
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service)
        #expect(r == .targetInTransition(.disconnected))
        #expect(h.managers.starts.isEmpty && agent.calls.isEmpty)
        #expect(read(h)?.autoConnect.pausedUntil == s.autoConnect.pausedUntil)
        #expect(await intent(h, s, work.id) == .holds)                   // unspent
        h.managers.onSetOnDemand = nil
        let next = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                                service: h.service)
        #expect(next == .resumed(restarted: nil, onDemand: [work.id]))    // the intent check refuses the forged record
        #expect(h.managers.starts.isEmpty)
    }

    /// A genuine record in the same race: retried, then the next run (intent verified, armed) starts it exactly once.
    @Test func aGenuineTargetThatStopsDuringTheRunIsStartedByTheNextRun() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let s = try await pause(h, work.id, onDemand: [work.id])
        h.managers.entries[work.id]?.status = .connected
        h.managers.onSetOnDemand = { id, _ in h.managers.entries[id]?.status = .disconnected }
        let agent = ProbeResumeAgent()
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service) == .targetInTransition(.disconnected))
        #expect(h.managers.starts.isEmpty && h.service.state.withLock { $0.arms.isEmpty })
        #expect(await intent(h, s, work.id) == .holds)
        h.managers.onSetOnDemand = nil
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service) == .resumed(restarted: work.id, onDemand: [work.id]))
        #expect(h.managers.starts.count == 1 && h.service.state.withLock { $0.arms.count } == 1)
        #expect(await intent(h, s, work.id) == .changedOutside)
    }

    // MARK: Review 2 (L2, N3): only an established session counts as restarted

    /// `.connecting` (an earlier run's start NE hasn't finished, or someone's `scutil --nc start`): nothing changes, not
    /// even on disk; the next run looks again.
    @Test func aConnectingTargetIsLookedAtAgain() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        let s = try await pause(h, work.id, onDemand: [auto.id])
        let before = try Data(contentsOf: h.dir.data.settings)
        h.managers.entries[work.id]?.status = .connecting
        let agent = ProbeResumeAgent()
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service) == .targetInTransition(.connecting))
        #expect(try Data(contentsOf: h.dir.data.settings) == before)
        #expect(h.managers.starts.isEmpty && agent.calls.isEmpty && h.managers.onDemandChanges.isEmpty)
        #expect(await intent(h, s, work.id) == .holds)
        h.managers.entries[work.id]?.status = .reasserting
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service) == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.starts.isEmpty && h.service.state.withLock { $0.arms.isEmpty })
        #expect(await intent(h, s, work.id) == .changedOutside)
    }

    /// N3: a forged record naming an established session: as before (no arm, no start; the target's on-demand comes
    /// back, no other profile's beside it; the pause ends), now with a fault line (L2, not asserted: os_log).
    @Test func aForgedRecordNamingAnActiveProfileArmsAndStartsNothing() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        let s = try await pause(h, work.id, onDemand: [work.id, auto.id])
        try forge(h, s)
        h.managers.entries[work.id]?.status = .connected
        h.managers.entries[auto.id]?.onDemand = false
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service)
        #expect(r == .resumed(restarted: work.id, onDemand: [work.id]))
        #expect(h.managers.starts.isEmpty && h.service.state.withLock { $0.arms.isEmpty })
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(read(h)?.onDemandPausedByStart == [auto.id])
        #expect(read(h)?.autoConnect.pausedUntil == nil)
    }

    /// N3: a session still going down is no start now (NE would refuse it and the pause would end without its restart):
    /// nothing is checked, armed, spent or started; the next run, the session gone, restarts it once.
    @Test func aDisconnectingTargetIsLookedAtAgain() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let s = try await pause(h, work.id)
        let before = try Data(contentsOf: h.dir.data.settings)
        h.managers.entries[work.id]?.status = .disconnecting
        let agent = ProbeResumeAgent()
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service) == .targetInTransition(.disconnecting))
        #expect(try Data(contentsOf: h.dir.data.settings) == before)
        #expect(h.managers.starts.isEmpty && agent.calls.isEmpty && h.service.state.withLock { $0.arms.isEmpty })
        #expect(await intent(h, s, work.id) == .holds)
        h.managers.entries[work.id]?.status = .disconnected
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service) == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.starts.count == 1)
    }

    // MARK: Fable fix-3 M1: running out of time is always a retry, however late the run is

    /// Long after the pause's end (2 h, e.g. a Mac that slept through it), running out of time in the settle is still a
    /// retry: no start, nothing spent, the pause and every paused on-demand value kept. (Documented 2.0.2 limit: unbounded.)
    @Test func outOfTimeIsRetriedLongAfterThePauseEnded() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: true)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        let s = try await pause(h, work.id, onDemand: [work.id, auto.id], endedAgo: 2 * 3600)
        let agent = ProbeResumeAgent()
        let clock = ScriptedClock([.zero, .milliseconds(4100)])
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             clock: { clock.now() })
        #expect(r == .outOfTime(.settle))
        #expect(h.managers.starts.isEmpty)
        expectPauseKept(h, s)
        #expect(agent.calls.isEmpty)
        #expect(await intent(h, s, work.id) == .holds)
    }

    @Test func noTimeToArmLongAfterThePauseEndedIsRetried() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let s = try await pause(h, work.id, endedAgo: 2 * 3600)
        let agent = ProbeResumeAgent()
        let clock = ScriptedClock([.zero, .milliseconds(4200)])
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service, clock: { clock.now() })
        #expect(r == .outOfTime(.arm))
        #expect(h.service.state.withLock { $0.arms.isEmpty } && h.managers.starts.isEmpty && agent.calls.isEmpty)
        #expect(read(h)?.autoConnect.pausedUntil != nil)
        #expect(await intent(h, s, work.id) == .holds)
    }

    /// Fable fix-3 N1: a genuine record whose target is inactive at the first look and `.connecting` at the start gate
    /// (NE began the on-demand start during the on-demand saves): nothing is started and the value is not spent.
    @Test func aTargetThatIsConnectingAtTheStartGateIsNotStartedOrSpent() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let s = try await pause(h, work.id, onDemand: [work.id])
        h.managers.onSetOnDemand = { id, _ in h.managers.entries[id]?.status = .connecting }
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service)
        #expect(r == .targetInTransition(.connecting))
        #expect(h.managers.starts.isEmpty)
        #expect(h.service.state.withLock { $0.arms.count } == 1)
        #expect(await intent(h, s, work.id) == .holds)                   // the value is unspent
    }

    // MARK: Codex fix MEDIUM: a run stopped at any point is completed by the next one

    /// Stopped before the start: nothing spent; the next run restarts the profile once.
    @Test func stoppedBeforeTheStartTheNextRunRestarts() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let s = try await pause(h, work.id)
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service, checkpoint: { $0 != .beforeStart })
        #expect(r == .stopped(at: .beforeStart))
        #expect(h.managers.starts.isEmpty && agent.calls.isEmpty)
        expectPauseKept(h, s)
        #expect(await intent(h, s, work.id) == .holds)
        let next = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                                service: h.service)
        #expect(next == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.starts.count == 1)
        #expect(await intent(h, s, work.id) == .changedOutside)
    }

    /// Stopped right after the start was submitted, before the value was spent. NE took it (the session is active):
    /// the next run spends the value and starts nothing again. Then the same with a start NE never took (or that ended):
    /// the value is still there, so the next run resumes once more.
    @Test func stoppedDuringTheStartTheNextRunCompletesOrResumesOnce() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let auto = try await h.add("Home NAS.conf", Harness.splitConf)
        let s = try await pause(h, work.id, onDemand: [auto.id])
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service, checkpoint: { $0 != .afterStart })
        #expect(r == .stopped(at: .afterStart))
        #expect(h.managers.starts.count == 1 && agent.calls.isEmpty)
        expectPauseKept(h, s)
        #expect(await intent(h, s, work.id) == .holds)                   // not spent before NE had the start
        h.managers.entries[work.id]?.status = .connecting                // NE took it; still coming up (review 2 L2)
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service) == .targetInTransition(.connecting))
        #expect(await intent(h, s, work.id) == .holds && agent.calls.isEmpty)
        h.managers.entries[work.id]?.status = .connected
        let next = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                                service: h.service)
        #expect(next == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.starts.count == 1)                            // no second start
        #expect(h.managers.entries[auto.id]?.onDemand == false)
        #expect(await intent(h, s, work.id) == .changedOutside)
        #expect(read(h)?.autoConnect.pausedUntil == nil)

        // NE never took it.
        h.managers.starts.removeAll()
        h.managers.entries[work.id]?.status = .disconnected
        let s2 = try await pause(h, work.id, onDemand: [auto.id])
        #expect(await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service, checkpoint: { $0 != .afterStart }) == .stopped(at: .afterStart))
        let retry = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                                 service: h.service)
        #expect(retry == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.starts.count == 2)                            // resumed once more
        #expect(h.service.state.withLock { $0.arms.count } == 3)         // each start armed by its own run
        #expect(await intent(h, s2, work.id) == .changedOutside)
    }

    /// Stopped after the spend, before the final settings write (the rename): the target is active, so the next run
    /// takes it as the restart. A spent record never restarts anything again: with the session gone, it is refused.
    @Test func stoppedBeforeTheFinalWriteTheNextRunCompletesAndNeverStartsTwice() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        let work = try await h.add("Work.conf", Harness.wgConf, killSwitch: false)
        let s = try await pause(h, work.id)
        let agent = ProbeResumeAgent()
        let r = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                             service: h.service, checkpoint: { $0 != .beforeFinalWrite })
        #expect(r == .stopped(at: .beforeFinalWrite))
        #expect(h.managers.starts.count == 1 && agent.calls.isEmpty)
        #expect(read(h)?.autoConnect.pausedUntil == s.autoConnect.pausedUntil)
        #expect(await intent(h, s, work.id) == .changedOutside)          // spent after the start
        h.managers.entries[work.id]?.status = .connected
        let next = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                                service: h.service)
        #expect(next == .resumed(restarted: work.id, onDemand: []))
        #expect(h.managers.starts.count == 1)
        #expect(read(h)?.autoConnect.pausedUntil == nil)

        // The same genuine record written back after its session ended: refused, nothing armed or started.
        h.managers.entries[work.id]?.status = .disconnected
        try AtomicFile.saveJSON(s, to: h.dir.data.settings)
        let arms = h.service.state.withLock { $0.arms.count }
        let replay = await HeadlessResume.perform(dir: h.dir.data, managers: h.managers, agent: agent, keychain: h.keychain,
                                                  service: h.service)
        #expect(replay == .resumed(restarted: nil, onDemand: []))
        #expect(h.managers.starts.count == 1)
        #expect(h.service.state.withLock { $0.arms.count } == arms)
    }

    // MARK: L4, N2

    /// Both ends `_exit` (lint `lp_headless_underscore_exit` keeps `exit()` out of App/Headless); a timed-out run's
    /// status is EX_TEMPFAIL.
    @Test func theExitStatusTellsATimeoutApart() {
        #expect(HeadlessResume.exitStatus(.finished) == 0)
        #expect(HeadlessResume.exitStatus(.timedOut) == 75)
        #expect(HeadlessResume.minimumForStart < HeadlessResume.reserve)
    }

    // MARK: N5

    @Test func orphanTempFilesAreSweptAndNothingElse() throws {
        let dir = TestDir()
        defer { dir.cleanup() }
        let root = dir.data.root
        let now = Date()
        func file(_ name: String, age: TimeInterval) throws -> URL {
            let u = root.appending(path: name)
            try Data("x".utf8).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: u.path)
            return u
        }
        let orphan = try file(".settings.json.\(UUID().uuidString).tmp", age: 600)
        let fresh = try file(".settings.json.\(UUID().uuidString).tmp", age: 5)             // a write in flight
        let settings = try file("settings.json", age: 600)
        let other = try file(".settings.json.notauuid.tmp", age: 600)
        let plain = try file("x.tmp", age: 600)
        let dirLike = root.appending(path: ".history.json.\(UUID().uuidString).tmp")
        try FileManager.default.createDirectory(at: dirLike, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: dirLike.path)
        // Review 2 (N1): an old symlink named like a temp file, to an old regular file of the same shape elsewhere: the
        // link isn't a regular file (lstat), and nothing is ever deleted through it.
        let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        let target = elsewhere.appending(path: ".settings.json.\(UUID().uuidString).tmp")
        try Data("x".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: target.path)
        let link = root.appending(path: ".settings.json.\(UUID().uuidString).tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let old = timespec(tv_sec: Int(now.timeIntervalSince1970) - 600, tv_nsec: 0)
        var times = [old, old]
        #expect(utimensat(AT_FDCWD, link.path, &times, AT_SYMLINK_NOFOLLOW) == 0)       // the link itself is old too
        #expect(AtomicFile.sweepOrphanTempFiles(in: root, now: now) == 1)
        let exists = { (u: URL) in FileManager.default.fileExists(atPath: u.path) }
        #expect(!exists(orphan))
        #expect(exists(fresh) && exists(settings) && exists(other) && exists(plain) && exists(dirLike))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path)  // the link survives
        #expect(exists(target))
        #expect(AtomicFile.isTempFileName(".p.json.\(UUID().uuidString).tmp"))
        #expect(!AtomicFile.isTempFileName(".\(UUID().uuidString).tmp"))
    }
}
