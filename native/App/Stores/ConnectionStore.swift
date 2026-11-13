import Foundation
import LPModel
import LPWire
import NetworkExtension
import Observation
import os

/// `ConnectionStore` (DESIGN §11.2): NEVPNStatus per manager (current connection objects only, S5), the tunnel
/// snapshot over XPC, `fetchLastDisconnectError` ONLY after a disconnect this instance observed (S12), pause/resume
/// (§10.4) and the connect/disconnect/switch intents. It never shows optimistic state: "Connecting…" appears only
/// because NEVPNStatus says `.connecting`.
///
/// On-demand pause and restore (E2E-3, DESIGN §10.4), one state machine per profile:
///
///     idle ── Connect ──▶ .starting(issued: false)
///     idle ── Connect while another profile is active (a switch: pause first, then stop it), or of a profile that is
///             still `.disconnecting` (N1b, S2), or while another profile is still `.disconnecting` (E2E-4)
///             ──▶ .waitingForStop(of: old)
///     .waitingForStop(of: old) ── `old` reports `.disconnected`, or the timer (`stopTimeout`) ──▶ .starting(issued: false)
///     .starting(issued: false) ── pause others, restore own, settle; managers.start ──▶ .starting(issued: true)
///     .starting(issued: false) ── another profile active after the settle (F6) ──▶ .waitingForStop(of: that one)
///     .starting(issued: false) ── a non-active status ──▶ unchanged (a stale report of the previous session, N1)
///     .starting(issued: true) ── any status ──▶ idle (active: the session runs; otherwise the start ended)
///     `.disconnecting` of a watched session (not a user stop; no entry of this profile) ──▶ .awaitingRestart (the
///             fetch phase, early: E2E-4, `holdTeardown`; the `.disconnected` below replaces it)
///     observed disconnect (not a user stop; nothing of this profile starting or waiting) ──▶ .awaitingRestart
///     .awaitingRestart ── no fresh crash / our restart skipped after the grace / timer / manager removed ──▶ idle
///     .awaitingRestart ── fresh crash: NE restarts it (re-armed, `systemRestartTimeout` 10 s from the decision, U8) ── active status ──▶ idle
///                         (also a `pluginFailed` with no interruption seen, U10: the crash may have hit a dead XPC link;
///                         `mayRestart`, hedged, Cancel ends it: review e321e10)
///     any entry of a session ── `.invalid` (its manager is gone, or it was `.disconnecting`), or its manager vanished
///             (two consecutive loads, or our own removal: `dropVanished` / `SerializedVPNManager`) ──▶ `sessionEnded`,
///             the one end path (e321e10, 385b6ea L-A/L-B/L-C). `.invalid` of a live session whose manager still exists
///             is logged and ignored (the session and its status stay)
///     user stop of a profile whose `.disconnecting` armed `.awaitingRestart` ── its `.disconnected` ──▶ idle (L-F)
///     user stop (Disconnect, Cancel, delete) then an active status of that profile within 2 s with no entry of its own
///             and its manager's on-demand OFF (NE's restart landing after the stop; with on-demand on it is the app's own
///             re-enabled on-demand start) ──▶ stopped again (L-E, 5c3a899/f18c0d6 L-1); `stopAndWait` also ends a pending
///             start (L-D) and AWAITS its Task (`startTasks`, M-1): a Delete during the profile's own prepare must not be
///             followed by the prepare re-creating the configuration (`ProfilesStore` refuses it while deleting)
///     a kill-switch session without on-demand rules that ends (not a user stop) from ANY live status, `.connecting` and
///             `.reasserting` too, or an issued start whose entry ends at `.disconnected` with no active status ever read
///             ──▶ .awaitingRestart(`.mayRestart`, 10 s fallback): NE restarts it even if it never reached `.connected`
///             (E2E-4, 200009; `holdForSystemRestart`. The issued-start case records no crash
///             (L-3): its `.disconnected` may be the old session's, so a later `.connected` is a normal connect, and the
///             hold's own copy is `.startEndedEarly` ("The start ended early"), never "stopped unexpectedly")
///     .awaitingRestart ── fresh crash: grace over, the app restarts it (`.restart`) ──▶ .starting(issued: true)
///     .awaitingRestart ── the user's Connect of the same profile ──▶ .starting(issued: false) (a newer entry)
///     .awaitingRestart or idle ── `profileNotProvisioned`/`profileRevisionStale`: re-provisioned, once ──▶ .starting(issued: false)
///     .starting, .waitingForStop ── failure (prepare, pause, settle, start threw) ──▶ idle
///     .starting(issued: false), .waitingForStop ── the user's Disconnect, Cancel or Pause ──▶ idle (`cancelPendingStarts`)
///     .starting, .awaitingRestart ── timer (`startingTimeout`; the fetch phase: `disconnectErrorTimeout` + 5 s) ──▶ idle
///
/// No network (E2E-4 200011: NE refuses a start with "No network available", code 2, and restarts a kill-switch session
/// without on-demand rules by itself when any interface returns, with no start command, beside whatever was restored):
///     any start (`startNow`, and again right before `startVPNTunnel`) while NWPathMonitor reports no interface
///             ──▶ .waitingForNetwork (nothing issued, nothing paused, NOT busy, no timer; what the start paused comes back)
///     .waitingForNetwork ── an interface again (after `endpointPushSettle`), and no other entry (review aad7527 #2: else
///             it waits on and tries again when that entry ends) ──▶ a Connect's start (`beginStart`, review b47da1c L-3:
///             a switch out of another active profile, a wait for a stopping one) ──▶ .starting(issued: false)
///     .waitingForNetwork ── the user's Disconnect, Cancel or Pause, a delete ──▶ idle. Other Connects are held (one start at a time)
///     an issued start whose first status is `.disconnecting` (the refusal: its `.connecting` is never delivered), or an
///             own session never seen active whose `.disconnecting` comes from a non-live status (f0c8c57 #3) and whose manager
///             has the kill switch and no on-demand (a System Settings start, review b47da1c L-1, aad7527 #4)
///             ── `.disconnecting` ──▶ .awaitingRestart (teardown, `holdTeardown`, L-2) ── `.disconnected` ──▶ the
///             issued-start hold (`.startEndedEarly`), then its error is read; a start waiting for that stop is dropped
///     a disconnect not caused by a stop of ours, never `.connected` (L-7: a code 2 after `.connected` is sticky), kill
///             switch as started, no on-demand rules, error code 2 ──▶ .awaitingNetworkRestart (`holdForNetworkRestart`:
///             busy; recorded durably BEFORE it is armed, L-6, `networkRestartHold`)
///     .awaitingNetworkRestart ── no interface ──▶ unchanged, no timer (no restore, however long)
///     .awaitingNetworkRestart ── an interface ──▶ NE's restart awaited: active status ──▶ idle; `systemRestartTimeout`
///             after the interface came ──▶ idle and the restore (an interface going away again disarms the fallback)
///     .awaitingNetworkRestart ── Cancel or Pause ──▶ idle after a user stop (`stopVPNTunnel` cancels NE's restart), then the restore
///     .awaitingNetworkRestart of X ── the user's Connect of another profile ──▶ X stopped as above, then that Connect proceeds
///     a user stop of a session never seen active (the Cancel above) whose `.disconnected` was read (`userStopSettled`):
///             `userStops` stays for L-E (NE's restart within 2 s is stopped again), but the NEXT `.disconnecting` out of a
///             non-live status is a NEW session: the stop's bookkeeping ends there, and its refusal is evaluated fresh,
///             held like the first (E2E-4 200012, the second System Settings start after a Cancel); a stop of an already-down session settles
///             after `stopReportGrace` whether or not NE reports a status for it (review 2518e93 #1)
///     a refusal NE won't restart (no kill switch, or on-demand rules) of an own session never seen active, out of a
///             non-live status, no stop of ours (`refusalStopping`) ── its `.disconnected` ──▶ the error is read
///             (`readRefusal`): nothing else active or pending: the hero follows that profile (row 14, like a held
///             refusal's `currentID`; only a code 2 while the network is down: a stop elsewhere of a down session carries a sticky
///             older error and shows nothing); else a Diagnostics problem ("X couldn't connect: …"); never silent (E2E-4 200012)
///     2.0.1: a start the extension refused beside another LockPlus session (`.anotherTunnelActive`) is read the same way
///             at the `.disconnected` of a never-active `.disconnecting`, and ends the issued-start hold of a kill-switch
///             profile at once (NE doesn't restart it). Review L1: only when the snapshot dates it to this attempt (never
///             after a connected session); review L2: the copy says so when the blocking session isn't one this user sees;
///             review L3: one Diagnostics line per profile per 5 min. No "disconnected unexpectedly"; a kill-switch profile's
///             refusal posts `.killSwitchStartRefused` instead (review H1). A session the extension ended for a kill-switch
///             start (`.supersededByKillSwitch`) is a disconnect like any other, plus a problem line when it isn't current
///     launch with `networkRestartHold` set (a pause's own write clears one that existed when it began; review aad7527
///             #1), its manager `.disconnected`, kill switch, no on-demand ──▶ .awaitingNetworkRestart (before the launch's restore and an expired pause's resume); the
///             headless resume doesn't restore beside it either
///
/// One start at a time (review 4 #1): a Connect while any entry exists is ignored, except over its own profile's
/// `.awaitingRestart`; a Connect of an active profile is ignored (#5). The UI disables every Connect while `startHold`
/// says why (review 5 §3); `connect` returns false when it ignored one, and logs why. Busy (`isBusy`) = any entry, or
/// any LIVE status (ours or the live manager's): every status but `.disconnected`/`.invalid`, so `.disconnecting` too
/// (a vanished manager's last status is dropped, and `SerializedVPNManager` reports `.invalid` for it: review e321e10)
/// (E2E-4, 200008: the restore ran at a crashed kill-switch session's `.disconnecting`, inside NE's restart; a session
/// ends only at a handled `.disconnected`, where a user stop or the crash decision takes over). The pause record
/// (`AppSettings.onDemandPausedByStart`) is written durably before each pause; `restoreIfIdle` restores the record
/// plus every plan that wants on-demand only while NOT busy and not quiesced for an extension update.
///
/// Invariant: no save of another own manager and no on-demand enabled on another own manager between the pause
/// (`pauseOtherOnDemand`) and the started session ending or failing. The running profile's own manager gets saves only
/// while it is `.connected` and nothing else is busy: on-demand/rule/name saves (S2 E9), and, E2E-4 (U7 reversal), the
/// PROTECTIVE flag heal (`ProfilesStore.healProtectiveDrift`: flags the system weakened are put back; NE applies them
/// to the live session at once). A weakening drift seen while `.connecting` is noted and healed at `.connected`. Any
/// other flag or revision change of a live session waits for it to end (L-KS-2). E2E-4 200011: a kill-switch session NE
/// refused for want of a network has not ended: NE restarts it when an interface returns (`.awaitingNetworkRestart`), so
/// nothing is restored until that restart is active, the user stops it, or the fallback after the network's return.
/// Auto-connect is never silently off: every hold that keeps it off has its row 12a line (and Cancel where one helps).
///
/// Busy also counts every other configuration's live session, another user's and an unaddressable one's included
/// (E2E-4, U2/U13): no non-essential mutation (orphan or stray removal, a `load()`/re-save heal, a delete's removal, a
/// metadata sync) runs beside it. Only the user's own Connect proceeds (its pause saves are the necessary ones).
@MainActor @Observable
final class ConnectionStore {
    private(set) var statuses: [UUID: TunnelStatus] = [:]
    /// The profile the derived state is about: the active one, else the last used.
    private(set) var currentID: UUID?
    private(set) var snapshot: TunnelSnapshot?
    private(set) var observedError: ObservedError?
    private(set) var errorDetail: String?
    private(set) var errorAt: Date?
    private(set) var userStoppedSinceError = false
    private(set) var switchingTo: UUID?
    private(set) var connectedSince: Date?
    /// Set by AuthCoordinator: an AUTH_PENDING wait.
    var awaitingApproval = false
    /// The last connect attempt couldn't even start (no configuration, not verified, start threw).
    private(set) var startFailure: LPError?
    /// PENDING-FOLD 53 (RS2 1): the session of this profile came back after a tunnel-process crash (NE's own restart
    /// or ours, PF 52) without the user acting. Cleared by the next disconnect or a user Connect/Disconnect.
    private(set) var restartedAfterCrash: UUID?
    /// The user declined "add VPN configurations" (the save failed with NEVPNErrorDomain 5), not an extension
    /// problem (review H1: errors were all mapped to "extension unavailable").
    private(set) var configurationDenied = false
    /// Review N2 (2.0.1): the user allowed VPN configurations (a save succeeded): a denial seen earlier is over.
    func configurationAllowed() { configurationDenied = false }
    /// §10.4: the resume agent's state after the last pause began. `.requiresApproval` → the pause sheet says "If
    /// LockPlus quits unexpectedly, protection resumes the next time it opens".
    private(set) var resumeAgentStatus: ResumeAgentStatus?
    /// Set by `AppEnvironment` (live: SMAppService; preview and tests: inert).
    @ObservationIgnored var resumeAgent: any ResumeAgentControlling = InertResumeAgent()
    /// Draft 9 (S2 E10): resolves the profile's endpoint hostnames right before `startVPNTunnel`; the result goes into
    /// `lp.endpoints`, so the provider never resolves under `includeAllNetworks`. Live: `StartEndpointResolver`
    /// (≤ 3 s per host, concurrent); previews and tests: nothing.
    @ObservationIgnored var resolveEndpoints: @Sendable ([String]) async -> [String: [String]] = { _ in [:] }
    /// PF 50: how long a network change settles before the held start's endpoints are resolved (DNS configuration
    /// follows the path change). Tests: zero.
    @ObservationIgnored var endpointPushSettle: Duration = .seconds(2)
    /// PF 52: wait this long after an observed `pluginFailed` before OUR OWN restart (a profile with on-demand rules,
    /// which NE doesn't restart), so an on-demand start that lands meanwhile is seen first. NE's restart of a profile
    /// without rules is not waited for with this: it comes ≈2.0–2.9 s after `.disconnected` (LK-02, E2E-1) and is
    /// expected instead (`CrashRestartPolicy.Decision.expectSystemRestart`). Tests: zero.
    @ObservationIgnored var crashRestartGrace: Duration = CrashRestartPolicy.grace
    /// Review F9/R1: a pending entry (a start that reports no status at all, NE silently dropped it; or NE's own restart
    /// after a crash that never comes) stops holding the auto profile back after this long. Tests: milliseconds.
    @ObservationIgnored var startingTimeout: Duration = .seconds(30)
    /// Review R9: how long `fetchLastDisconnectError` may take before the disconnect is treated as no crash (a wedged
    /// nesessionmanager must not hold `.awaitingRestart`, and with it every restore and `load()`, forever).
    @ObservationIgnored var disconnectErrorTimeout: Duration = .seconds(10)
    /// S2: a start issued while NE is still Stopping is silently dropped, and NE's Stopping budget is 20 s (+ ~1.2 s): a
    /// `.waitingForStop` entry whose old session never reports `.disconnected` starts after this long. Tests: milliseconds.
    @ObservationIgnored var stopTimeout: Duration = .seconds(22)
    /// Review R1 fallback, shrunk by E2E-4 (U8): NE's own restart of a crashed kill-switch profile without on-demand
    /// rules reports `.connecting` 0.98–1.04 s after `.disconnected` on 26 and 27. A restart still missing after this long
    /// is not coming; the restore then runs (≈10× the measured time). Tests: milliseconds.
    @ObservationIgnored var systemRestartTimeout: Duration = .seconds(10)
    /// How the pending-entry timer waits (`arm`). Tests inject a sleeper they release by hand instead of racing real time.
    @ObservationIgnored var timerSleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    @ObservationIgnored private let managers: any VPNManaging
    @ObservationIgnored private let service: any TunnelServicing
    @ObservationIgnored private let profiles: ProfilesStore
    /// Round 2 (M1a): the extension update's resume record is sealed and checked with the profiles' keys.
    var profileRepository: ProfileRepository { profiles.repository }
    /// A line in Diagnostics › Problems (the quiescer's).
    func noteProblem(_ message: String) { profiles.note(message) }
    @ObservationIgnored private let settings: SettingsStore
    /// The wall clock (settable for tests: round 3 freshness tests advance it).
    @ObservationIgnored var now: @MainActor () -> Date
    /// Observed `.connecting/.connected/.reasserting` in THIS instance since the last `.disconnected` (S12).
    @ObservationIgnored private var sawActive: Set<UUID> = []
    /// One entry per profile between "something will start it" and its outcome (the state machine above). Observed: the
    /// Auto-Connect pane shows the pause during the start window.
    private var pending: [UUID: Pending] = [:]
    /// Each `arm` takes the next token: a Task that outlives its entry (the timer, `startNow`, the crash grace) sees
    /// `pending[id]?.token` moved on and does nothing (review R7).
    @ObservationIgnored private var lastToken: UInt64 = 0
    /// Review N6: whether the session a profile runs (or last ran) was started with `includeAllNetworks`: verified at our
    /// own start, read from the manager when a session we didn't start appears. NE restarts a crashed session with its
    /// original options, so the crash decision reads this, not the manager's possibly drifted flags.
    @ObservationIgnored private var sessionKillSwitch: [UUID: Bool] = [:]
    /// One restore at a time; `pauseOtherOnDemand` waits for it (a start never overlaps a restore's save).
    private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var restoreAgain = false
    /// A restore is in flight (the status line doesn't claim a failure meanwhile).
    var restoring: Bool { restoreTask != nil }
    @ObservationIgnored private var reachedConnected: Set<UUID> = []
    /// Round 5 (Fable r5 L2, Codex r5 #2): profiles whose latest session this run either started itself (an issued start)
    /// or saw `.connected`. Only such a session, down in a crash gap or a network-restart hold, may become a pause's signed
    /// resume target (`signableHold`); a start made elsewhere that never connected (a refused outside start, held for
    /// a few seconds) never does. Set per session: a new attempt not issued by this app, or an unissued end, clears it.
    @ObservationIgnored private var resumableSession: Set<UUID> = []
    @ObservationIgnored private var userStops: Set<UUID> = []
    @ObservationIgnored private var userStopsAt: [UUID: Date] = [:]
    /// E2E-4 200012: a user stop of a session never seen active (the Cancel of a held refusal) whose `.disconnected` was
    /// read. `userStops` stays for L-E (NE's restart landing after the stop), but the NEXT `.disconnecting` out of a
    /// non-live status is a new session (a second refusal), evaluated fresh: it ends the stop's bookkeeping.
    @ObservationIgnored private var userStopSettled: Set<UUID> = []
    /// E2E-4 200012: an own session never seen active that began stopping straight out of a non-live status, with no stop
    /// of ours: a refusal (NE's `.disconnecting` → `.disconnected` only). Its end reads the error even when NE won't
    /// restart it (no kill switch); see `readRefusal`.
    @ObservationIgnored private var refusalStopping: Set<UUID> = []
    /// 2.0.1 review L1: when a never-active session's `.disconnecting` (a refusal's first status) was seen. Final review
    /// L1: cleared when the profile reports an active status or a start of it is issued (a newer attempt).
    @ObservationIgnored private var endSeenAt: [UUID: Date] = [:]
    /// Codex final 4: bumped for every new attempt of a profile (first active status, an issued start). An error read
    /// that began under an older value never touches UI state or delivers `onObservedDisconnect` (a newer attempt's
    /// prompt would be cleared).
    @ObservationIgnored private var attemptGeneration: [UUID: UInt64] = [:]
    /// Final review N3: when the app last issued its own start of a profile (a refusal of it can't predate that). Only
    /// a floor: an older issue time never widens the freshness window (round 3 Codex 6, round 4 N5).
    @ObservationIgnored private var startIssuedAt: [UUID: Date] = [:]
    /// Round 3 (Codex 5): when each profile last reached `.connected`, so a profile that becomes current later (a
    /// successor) shows its own session time.
    @ObservationIgnored private var connectedAt: [UUID: Date] = [:]
    /// Round 5: pending stray duplicates already noted in Diagnostics, per attempt. Round 6 (Codex L3, Fable L1): by
    /// owner and profile, which survive a reload (a stray's key is minted anew by every load); an entry goes when no
    /// stray of that profile is live any more (a restart after that is a new attempt).
    @ObservationIgnored private var strayNoted: Set<StrayIdentity> = []
    private struct StrayIdentity: Hashable { let ownerUID: uid_t?; let profileID: UUID }
    /// 2.0.1 review L3: when a refusal's Diagnostics line (and notice) was last posted, per profile, and beside which
    /// active profiles (re-check L4: a refusal beside a different set is a new one and is said again).
    @ObservationIgnored private var refusalNotedAt: [UUID: (at: Date, blockers: Set<UUID>)] = [:]
    /// 2.0.2: when this app last armed a start of the profile (`StartArming`). A 225 within `armWindow` of it is not a start
    /// "made outside LockPlus" (D-1 Diagnostics rule).
    @ObservationIgnored private var lastArmedAt: [UUID: Date] = [:]
    static let armWindow: TimeInterval = ArmLifetime.seconds
    /// E2E-4 200011: an issued start whose first reported status was `.disconnecting` (NE refused it); its `.disconnected`
    /// ends the start like an issued start's own `.disconnected`.
    @ObservationIgnored private var issuedEnding: Set<UUID> = []
    @ObservationIgnored private var attemptStartedAt: [UUID: Date] = [:]
    @ObservationIgnored private var retriedAfterProvision: Set<UUID> = []
    @ObservationIgnored private var launchSnapshotChecked = false
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var endpointPushTask: Task<Void, Never>?
    /// PF 52/53: connects, fresh crashes and our restarts per profile (`CrashRestartPolicy.Book`).
    @ObservationIgnored private var crashes = CrashRestartPolicy.Book()
    @ObservationIgnored private let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "connection")

    /// An observed disconnect with this error code (AuthCoordinator drops a prompt of the ended session).
    @ObservationIgnored var onObservedDisconnect: ((UUID, LPErrorCode?) -> Void)?
    /// Status changed to `.connecting`/`.reasserting` (the other prompt-pull trigger, §8.4) or `.connected`.
    @ObservationIgnored var onStatus: ((UUID, TunnelStatus) -> Void)?
    /// Every status transition, for the DNS verifier (§10.2); `onStatus` belongs to AuthCoordinator.
    @ObservationIgnored var onStatusForDiagnostics: ((UUID, TunnelStatus) -> Void)?
    /// User-notification events (§11.7); `AppEnvironment` applies the policy.
    @ObservationIgnored var onNotice: ((ConnectionNotice) -> Void)?

    init(managers: any VPNManaging, service: any TunnelServicing, profiles: ProfilesStore, settings: SettingsStore,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.managers = managers
        self.service = service
        self.profiles = profiles
        self.settings = settings
        self.now = now
        managers.onStatusChange = { [weak self] id, s in self?.handle(id, s) }
        profiles.onLoad = { [weak self] in self?.retryOwedPauseValue() }        // round 6 (Codex r6 #3)
        managers.onStrayStatusChange = { [weak self] in self?.strayStatusChanged() }
    }

    /// After `managers.loadAll()`: current statuses, the current profile, launch snapshot (with the S12 launch rule).
    func start() {
        for m in managers.managers { statuses[m.profileID] = m.status }
        currentID = Self.pickCurrent(statuses: statuses, lastUsed: settings.value.lastUsedProfileID,
                                     known: Set(profiles.profiles.map(\.id))) ?? profiles.ordered.first?.id
        // Review f0c8c57 #5: every own active session, not only the current one: we observe each one's end from now on
        // (its end then goes through the error read, never the unwatched-refusal arm).
        for (id, status) in statuses where status.isActive && isOwnProfile(id) {
            sawActive.insert(id)
            sessionKillSwitch[id] = managerKillSwitch(id)
            if status == .connected { reachedConnected.insert(id) }
            // Round 6 (Fable r6 L1): `.reasserting` was connected too (NE reconnects it).
            if status == .connected || status == .reasserting { resumableSession.insert(id) }
        }
        resumeNetworkRestartAtLaunch()        // E2E-4 200011: before the restore below, and before an expired pause resumes
        resumePauseAtLaunch()
        // E2E-3: what a start paused (or the headless resume left off) while LockPlus wasn't running comes back now,
        // unless something else is active.
        restoreIfIdle()
        refreshSnapshot()
        noteStrayDuplicates()                 // a duplicate already waiting at launch
    }

    static func pickCurrent(statuses: [UUID: TunnelStatus], lastUsed: UUID?, known: Set<UUID>) -> UUID? {
        if let active = statuses.first(where: { $0.value.isActive && known.contains($0.key) })?.key { return active }
        if let lastUsed, known.contains(lastUsed) { return lastUsed }
        return nil
    }

    var currentStatus: TunnelStatus { currentID.flatMap { statuses[$0] } ?? .disconnected }
    var anyOnDemandEnabled: Bool { managers.managers.contains { $0.onDemandEnabled } }

    // MARK: Status

    func handle(_ id: UUID, _ status: TunnelStatus) {
        // Our start, or NE's restart of a session we watched (N6); not a start still waiting for a stop (not issued).
        let ours = pending[id].map { !$0.isUnissuedWait } ?? false
        let hadEntry = pending[id] != nil
        // Review 385b6ea L-B: `.invalid` ends a session only when its manager is gone or the session was already
        // tearing down (NE reports `.invalid` for the configuration that went away mid-stop). For a live session of a
        // manager that is still there it is not known to mean anything (a save, a future NEVPNStatus case): logged,
        // and the session, its bookkeeping and its status stay as they were (a real removal is reported by the reload).
        if status == .invalid, let previous = statuses[id], previous.isLive, previous != .disconnecting, isKnown(id) {
            log.notice("\(id.uuidString.prefix(8), privacy: .public) reported .invalid while \(String(describing: previous), privacy: .public) and its configuration exists; the session is not treated as ended")
            return
        }
        let previous = statuses[id]
        // Round 7 (Fable r7 L1): NE's restart of a hold a Pause could sign an instant ago (a crash gap or a verified
        // network-restart hold of a session this run started or saw connected) stays signable while it is `.connecting`.
        let wasSignableHold = signableHold == id
        statuses[id] = status
        if status == .disconnecting, previous?.isLive != true, userStopSettled.remove(id) != nil {
            log.notice("\(id.uuidString.prefix(8), privacy: .public): a new session after the user's stop; the stop no longer applies")
            userStops.remove(id)
            userStopsAt[id] = nil
        }
        if status.isActive { userStopSettled.remove(id); refusalStopping.remove(id); endSeenAt[id] = nil; endNotes[id] = nil }
        // Re-check L4 / Codex 6: a session that really ran resets the refusal throttle (a refused start's `.connecting`
        // doesn't: repeated `scutil --nc start` attempts stay throttled).
        if status == .connected { refusalNotedAt[id] = nil }
        // Review N1: an active status ends any entry (the start runs; R1: NE's own restart is back). A non-active one
        // ends a start only once it was issued: before that it is a stale report of the previous session (a reload's
        // replay, the old session's `.disconnected`), and the start still holds everything back.
        // E2E-4 (200009, crash while connecting): an issued start that ends without ever reporting an active status
        // is a session that died before `.connecting` was read; NE restarts a kill-switch session without rules too.
        // E2E-4 200011: NE's refusal of a start ("No network available") is reported as `.disconnecting` → `.disconnected`
        // only (its 4 ms `.connecting` is never delivered): an issued start whose first status is `.disconnecting` ends
        // at the `.disconnected` that follows, just like one that reports `.disconnected` at once.
        let issued = pending[id]?.phase == .starting(issued: true)
        let wasEnding = issuedEnding.remove(id) != nil
        if status == .disconnecting, issued || wasEnding { issuedEnding.insert(id) }
        let issuedStartEnded = status == .disconnected && (issued || wasEnding)
        if status.isActive || issued { clearPending(id) }
        dropVanished()
        if status.isActive {
            // During a switch the old session may still report; only the target (or a lone session) is current.
            // 2.0.1 E2E F1: a start made elsewhere doesn't take the hero from a profile NE still reports active (the
            // extension refuses it beside that session, 222); it becomes current once it is `.connected` itself or
            // nothing else is active. A switch of ours names its target.
            let moves: Bool
            if let target = switchTarget { moves = target == id }
            else { moves = status == .connected || !anotherProfileActive(besides: id) }
            if currentID != id, moves {
                currentID = id
                connectedSince = nil                   // E2E F3: never the previous current profile's session time
            }
            if !sawActive.contains(id) {
                // A new attempt: the previous error belongs to the past.
                sawActive.insert(id)
                if !issued, !wasSignableHold { resumableSession.remove(id) }
                attemptGeneration[id, default: 0] &+= 1
                if !ours { sessionKillSwitch[id] = managerKillSwitch(id) }     // a session we didn't start (N6)
                resetSnapshotEpoch()
                attemptStartedAt[id] = now()
                // M8: a Disconnect that never produced a transition (already down) must not mark THIS attempt.
                if userStopsAt[id].map({ now().timeIntervalSince($0) > 2 }) ?? false { userStops.remove(id) }
                else if !hadEntry, userStops.contains(id), userStopsAt[id] != nil,
                        managers.managers.first(where: { $0.profileID == id })?.onDemandEnabled != true {
                    // Review 385b6ea L-E: NE's restart landed just after the user's Disconnect or Cancel (the `.mayRestart`
                    // wait): the user said stop, so stop it again. A Connect of the user's own has an entry and is left alone.
                    // Review 5c3a899/f18c0d6 L-1: only with on-demand OFF. NE never restarts a crashed session whose
                    // configuration has rules, so an active status with on-demand on is an on-demand start the app itself
                    // re-enabled (the restore after the stop); stopping that again would loop with it (each stop resets the 2 s).
                    log.notice("\(id.uuidString.prefix(8), privacy: .public) came back within 2 s of the user's stop and nothing of ours started it; stopping it again")
                    stop(id, suspending: false)
                }
                if id == currentID {
                    observedError = nil
                    errorDetail = nil
                    userStoppedSinceError = false
                    startFailure = nil
                }
            }
            if status == .connected {
                if !reachedConnected.contains(id) {
                    // PF 53: back without the user after a tunnel-process crash → say so (hero strip, notification).
                    if crashes.reconnected(id, at: now()) {
                        restartedAfterCrash = id
                        onNotice?(.reconnectedAfterRestart(id))
                    } else { onNotice?(.connected(id)) }
                }
                reachedConnected.insert(id)
                resumableSession.insert(id)
                if connectedAt[id] == nil || previous != .connected && previous != .reasserting { connectedAt[id] = now() }
                if id == currentID, connectedSince == nil { connectedSince = connectedAt[id] }
                crashes.connected(id, at: now())
                if switchingTo == id { switchingTo = nil }
                retriedAfterProvision.remove(id)
            }
            settings.update { $0.lastUsedProfileID = id }
        } else if status == .disconnecting {
            // Only while the network is down, and (`readRefusal`) only a code 2: a stop elsewhere of a session that is already down
            // (`scutil --nc stop`) looks the same and its error is the sticky older one (review 2518e93 #1).
            if !sawActive.contains(id), previous?.isLive != true, !userStops.contains(id), networkAvailable == false { refusalStopping.insert(id) }
            if !sawActive.contains(id), previous?.isLive != true { endSeenAt[id] = now() }
            holdTeardown(id, previous: previous)
        } else if status == .disconnected {
            if userStops.contains(id), !sawActive.contains(id) { userStopSettled.insert(id) }
            // Review b47da1c L-1: a start made elsewhere (System Settings, `scutil`) that NE refused for want of a network
            // reports the same `.disconnecting` → `.disconnected` and is never seen active either.
            let unwatchedEnd = previous == .disconnecting && pending[id]?.teardown == true
            let refusalEnd = refusalStopping.remove(id) != nil && previous == .disconnecting
            let neverActive = !sawActive.contains(id)
            if neverActive, !issuedStartEnded { resumableSession.remove(id) }      // round 5: a start made elsewhere
            var held = false
            if sawActive.remove(id) != nil { observedDisconnect(id) }
            else if issuedStartEnded || unwatchedEnd, !userStops.contains(id), mayBeRestartedByNE(id), isOwnProfile(id) {
                held = true
                // Review aad7527 #3: the hold's row and Cancel are about this profile (a start made elsewhere isn't current yet).
                if id != currentID, statuses.allSatisfy({ !$0.value.isActive }) { currentID = id }
                // Review 5c3a899/f18c0d6 L-3: not known to be a crash (the old session's `.disconnected` lands after
                // `managers.start` too, N1, S2): held, but no crash recorded, so a normal `.connected` is no "restart".
                // E2E-4 200011: the error then tells a "No network available" refusal (NE's restart waits for a network).
                checkNoNetworkRefusal(id, holdForSystemRestart(id, recordCrash: false))
            } else if pending[id]?.teardown == true {
                clearPending(id)             // the teardown hold of a session NE won't restart (a user stop, no kill switch)
            }
            // E2E-4 200012: a refusal NE won't restart (no kill switch, or on-demand rules) still says why, for any profile.
            if !held, refusalEnd, !userStops.contains(id), isOwnProfile(id) { readRefusal(id, offline: true) }
            // 2.0.1: the extension refuses a start (System Settings, `scutil`) beside another LockPlus session that runs
            // (`.anotherTunnelActive`); its `.connecting` may never be delivered either. Read like the refusal above
            // (review L2: whether or not the blocking session is one this app sees; freshness decides, L1).
            else if !held, !refusalEnd, neverActive, previous == .disconnecting, !userStops.contains(id), isOwnProfile(id) {
                readRefusal(id, offline: false)
            }
            // S2: a start issued while NE is still Stopping is silently dropped, so a waiting start begins only now.
            // Review b47da1c L-2: not inside a hold this `.disconnected` just began (NE's restart may follow): that start
            // ends, and Diagnostics says so.
            if let target = waiter(for: id) {
                // (The profile's own reconnect, N1b, is its own entry: it starts, as a newer entry over any hold.)
                // Review aad7527 #5: only beside a hold NE may end with a restart; another end's fetch doesn't drop it.
                if target != id, pending[id] != nil, mayBeRestartedByNE(id) { dropWaiter(target, heldBy: id) } else { startNow(target) }
            }
            resumeEndWaiters(id, ended: true)
            connectedAt[id] = nil
            // Round 4 (N5): the issue time is NOT cleared here: this `.disconnected` may be the previous session's, landing
            // after the new attempt's `managers.start`. It only ever raises a refusal's freshness floor (never widens the
            // window, round 3 Codex 6), and the next issued start replaces it.
            selectActiveSuccessor(after: id)
        } else if status == .invalid {
            sessionEnded(id)                 // here only for a gone manager or after `.disconnecting` (above)
            selectActiveSuccessor(after: id)
        }
        noteStrayDuplicates()
        onStatus?(id, status)
        onStatusForDiagnostics?(id, status)
        refreshSnapshot()
        // Review F4/R2: a restore that failed (or never got to run) and anything whose plan wants on-demand while its
        // manager is off are retried on every status event while idle (`restoreIfIdle` does nothing when there is none).
        restoreIfIdle()
    }

    /// E2E-4 (200008, restore at `.disconnecting`): NE stops a session we watched without the user's stop (a
    /// tunnel-process crash: NE reports `.disconnecting` ~5 s after the kill and restarts the session itself ~1 s after
    /// `.disconnected`; an on-demand disconnect; a stop elsewhere). The disconnect's entry (`.awaitingRestart`, the
    /// fetch phase: another profile's Connect is held, `readingDisconnect`) starts here, not only at `.disconnected`,
    /// so nothing (a Connect of another profile, its pause and `prepareForStart` saves) runs inside the teardown that
    /// NE's restart follows. Whether it was a crash is known only from `fetchLastDisconnectError` after `.disconnected`
    /// (`observedDisconnect` replaces this entry then; the crash decision's fallback counts from that decision, U8).
    /// The status itself already counts as busy (`isLive`); this entry is not what holds the restore back.
    /// Review b47da1c L-1/L-2: also a teardown never seen active, of an own kill-switch session without on-demand rules:
    /// our issued start's refusal (NE reports only `.disconnecting` → `.disconnected`) or one made elsewhere. NE may
    /// restart it when a network returns, so no other start's prepare and pause run inside it either.
    /// Review aad7527 #4: the unwatched arm only for a `.disconnecting` straight out of `.disconnected` (or no status yet),
    /// which is what a refusal looks like (a session already stopping at launch, or another live session we never marked,
    /// is not one), and with the manager's own kill switch: `sessionKillSwitch` may be a previous session's.
    private func holdTeardown(_ id: UUID, previous: TunnelStatus?) {
        guard !userStops.contains(id), pending[id] == nil else { return }
        // Review f0c8c57 #3: `.invalid` too (a known manager keeps it after an earlier `.disconnecting` → `.invalid`).
        let refusal = !sawActive.contains(id) && previous?.isLive != true && isOwnProfile(id)
            && managerKillSwitch(id) && managers.managers.first { $0.profileID == id }?.onDemandEnabled != true
        guard sawActive.contains(id) || refusal else { return }
        if refusal { sessionKillSwitch[id] = true }        // the session as NE runs it (N6), for the decisions that follow
        log.notice("\(id.uuidString.prefix(8), privacy: .public) is stopping without a user stop; nothing changes until its end is read")
        arm(id, .awaitingRestart, timeout: stopTimeout, teardown: true)
    }

    private func isOwnProfile(_ id: UUID) -> Bool { profiles.profile(id) != nil }

    /// Review b47da1c L-2: a start that waited for `old`'s stop, when `old`'s end began a hold instead (NE may restart
    /// it): the start ends rather than run its pause beside that restart, and Diagnostics says so.
    private func dropWaiter(_ target: UUID, heldBy old: UUID) {
        log.notice("start of \(target.uuidString.prefix(8), privacy: .public) dropped: \(old.uuidString.prefix(8), privacy: .public) may be restarted by NE")
        clearPending(target)
        if switchingTo == target { switchingTo = nil }
        let name = profiles.profile(target)?.name ?? "", oldName = profiles.profile(old)?.name ?? ""
        profiles.note(String(localized: "\(name) wasn't connected: macOS may restart \(oldName). Connect \(name) again if you need it.",
                             comment: "Problem: a Connect that waited for another profile's stop was dropped because macOS may restart that profile (review b47da1c L-2)"))
    }

    /// The hedged hold (`.mayRestart`: "Checking whether X restarts…", Cancel ends it), recorded as a crash so NE's
    /// restart reads as one (PF 53). It ends at an active status (`handle`) or after `systemRestartTimeout` with the
    /// status still `.disconnected` (the timer restores). User stops never get here. `recordCrash: false` for an issued
    /// start that ended with no status read (L-3): the hold, not a crash.
    @discardableResult
    private func holdForSystemRestart(_ id: UUID, recordCrash: Bool = true) -> UInt64 {
        if recordCrash { crashes.crashed(id, at: now()) }
        return arm(id, .awaitingRestart, timeout: systemRestartTimeout, expectsRestart: true, mayRestart: true,
                   startEndedEarly: !recordCrash)
    }

    // MARK: No network (E2E-4 200011)

    /// The network as NWPathMonitor last reported it: an interface other than a tunnel is available (`isArrival`). nil
    /// before the first report (a start then proceeds, as before).
    var networkAvailable: Bool? { networkSignature.map(Self.isArrival) }

    /// The `.awaitingNetworkRestart` hold, if any (one start at a time: at most one).
    var networkRestartHolder: UUID? { pending.first { $0.value.phase == .awaitingNetworkRestart }?.key }

    /// `NEVPNConnectionErrorDomain` 2 (`noNetworkAvailable`): NE refused or ended the session for want of a network.
    static func isNoNetwork(_ e: NSError) -> Bool { e.domain == NEVPNConnectionErrorDomain && e.code == 2 }

    /// A Connect while NWPathMonitor reports no interface (E2E-4 200011): `startVPNTunnel` is not called, since NE would
    /// refuse it ("No network available") and then restart the kill-switch session by itself when an interface returns,
    /// with no start of ours to hold the restore back. The start waits in our own state instead and runs, with the normal
    /// prepare, pause and settle, when the path has an interface again (`applyNetworkToHolds`).
    ///
    /// Nothing is paused while it waits (the pause happens at the actual start, as for every start): the wait has no time
    /// limit, and an app that quits or crashes meanwhile must not leave the auto profile off for it; NE's on-demand can't
    /// start anything without a network, and an on-demand start that lands as the network returns is handled by the
    /// start like any other active profile (F6: a switch). So the entry is not busy; whatever an earlier step of this
    /// start paused comes back now.
    private func waitForNetwork(_ id: UUID) {
        log.notice("\(id.uuidString.prefix(8), privacy: .public): no network; the start waits for one (nothing issued)")
        if switchingTo == id { switchingTo = nil }
        arm(id, .waitingForNetwork, untimed: true)
        restoreIfIdle()
    }

    /// The safety net (E2E-4 200011): a kill-switch session without on-demand rules ended with `noNetworkAvailable` and
    /// no stop of ours since. NE restarts it by itself when any interface returns (`.connecting` 1.1–1.3 s after the
    /// link is up, however long it was down, measured to ≥ 120 s), so nothing is restored while the path has no
    /// interface, without a time limit; once it has one, NE's restart is awaited (its active status ends the hold) with
    /// `systemRestartTimeout` as the fallback. Cancel (`disconnect`) is a user stop: `stopVPNTunnel` on the disconnected
    /// session cancels NE's restart (measured). Durable before anything can restore inside it: written like the pause
    /// record (`networkRestartHold`), re-entered at launch, and respected by the headless resume.
    /// Review b47da1c L-6: the record is on disk BEFORE the hold is armed (the caller's entry, `token`, holds the restore
    /// back meanwhile), so a crash at any point still knows. False: that entry ended during the write (NE's restart is
    /// active, Cancel, a newer start), and the record goes again.
    @discardableResult
    private func holdForNetworkRestart(_ id: UUID, replacing token: UInt64) async -> Bool {
        // Round 3 (Codex r3 #4): sealed, so a hold read at a later launch is known to be one this app recorded.
        let tag = await holdRecordOp { repo in
            do throws(LPError) { return try await repo.sealRecord(.networkRestartHold, AppSettings.networkRestartHoldMessage(id)) } catch {
                Logger(subsystem: "io.github.steiale.lockplus.mac", category: "connection")
                    .error("network-restart hold not sealed (\(error.code.rawValue, privacy: .public)); a relaunch drops it")
                return nil
            }
        }
        await settings.updateDurably { $0.networkRestartHold = id; $0.networkRestartHoldTag = tag }
        guard pending[id]?.token == token else {
            forgetNetworkRestartRecord(id)
            return false
        }
        log.notice("\(id.uuidString.prefix(8), privacy: .public) ended with \"No network available\"; NE restarts it when a network returns: waiting for it")
        crashes.forgetCrash(id)
        armNetworkRestart(id)
        if id != currentID, statuses.allSatisfy({ !$0.value.isActive }) { currentID = id }
        return true
    }

    /// (Re-)arms the network-restart hold for the current path: no timer without a network (or before the first
    /// reading), the fallback with one.
    private func armNetworkRestart(_ id: UUID) {
        let available = networkAvailable == true
        arm(id, .awaitingNetworkRestart, timeout: systemRestartTimeout, untimed: !available, fallbackArmed: available)
    }

    private func forgetNetworkRestartRecord(_ id: UUID) {
        if unverifiedHold == id { unverifiedHold = nil }
        guard settings.value.networkRestartHold == id else { return }
        settings.update { if $0.networkRestartHold == id { $0.networkRestartHold = nil; $0.networkRestartHoldTag = nil } }
        consumeHoldRecord()
    }

    /// Round 3 (Codex r3 #4): the hold's one-time value goes with the hold, so a copy of its record never verifies again.
    /// Round 4 (Fable N6): joins the chain synchronously, in call order (a hold sealed right after can't be overtaken).
    func consumeHoldRecord() {
        _ = enqueueHoldRecordOp { await $0.consumeRecord(.networkRestartHold); return nil }
    }

    /// Round 3 (Codex r3 #4): seals and consumes of the hold's record run one at a time, in call order (a consume that
    /// overtook the next hold's seal would invalidate it).
    @ObservationIgnored private var holdRecordChain: Task<String?, Never>?
    func holdRecordOp(_ op: @escaping @MainActor (ProfileRepository) async -> String?) async -> String? {
        await enqueueHoldRecordOp(op).value
    }
    private func enqueueHoldRecordOp(_ op: @escaping @MainActor (ProfileRepository) async -> String?) -> Task<String?, Never> {
        let previous = holdRecordChain, repo = profiles.repository
        let t = Task { @MainActor in
            _ = await previous?.value
            return await op(repo)
        }
        holdRecordChain = t
        return t
    }
    /// Tests (round 4, Fable N6): waits for every queued seal and consume of the hold's record.
    func awaitHoldRecordOps() async { _ = await holdRecordChain?.value }

    /// Round 3 (Codex r3 #4): the hold re-entered at launch until its tag verified. It holds the restore back (doing less
    /// is safe) but is never a pause's target: an unsigned hold never feeds a resume signature.
    @ObservationIgnored private(set) var unverifiedHold: UUID?

    /// The network-restart hold that may name a pause's target: one this run recorded, or one whose record verified.
    private var verifiedNetworkRestartHolder: UUID? { networkRestartHolder.flatMap { $0 == unverifiedHold ? nil : $0 } }

    /// Round 4 (Fable L2d, Codex r4 #3): an own session that ended without a user stop and whose end is being read or whose
    /// restart (NE's, or ours after the grace) is awaited: the crash gap (`.awaitingRestart`, the session down). A Pause stops it
    /// like a running session (cancelling that restart).
    var crashGapHolder: UUID? {
        pending.first { $0.value.phase == .awaitingRestart && statuses[$0.key]?.isLive != true && isOwnProfile($0.key) }?.key
    }

    /// Round 5 (Fable r5 L2, Codex r5 #2): the hold a Pause may sign as its resume target: a verified network-restart hold
    /// or a crash gap, and only of a session this run started itself or saw `.connected` (`resumableSession`). Any other
    /// hold (a refused start made elsewhere, a hold re-entered at launch) is still stopped by the Pause, unsigned.
    private var signableHold: UUID? {
        [verifiedNetworkRestartHolder, crashGapHolder].compactMap { $0 }.first { resumableSession.contains($0) }
    }

    /// Round 6 (Fable r6 L1): the live session a Pause may sign, by the same rule: one this run started itself or saw
    /// connected. A start made elsewhere while it is `.connecting` (a refused `scutil --nc start`) is stopped by the
    /// Pause like every live session (`pause`'s final stop), never signed.
    private var signableLive: UUID? {
        statuses.first { $0.value.isActive && resumableSession.contains($0.key) }?.key
    }

    /// An issued start that ended before any active status was read, now held as "the start ended early" (`token`): if
    /// NE refused it for want of a network, the hold becomes the network-restart hold (no time limit while there is no
    /// network). Bounded like every error read (`disconnectErrorTimeout`).
    private func checkNoNetworkRefusal(_ id: UUID, _ token: UInt64) {
        let fetching = managers, deadline = disconnectErrorTimeout, gen = attemptGeneration[id], issued = startIssuedAt[id]
        Task { @MainActor [weak self] in
            let fetched = await withDeadline(deadline, onTimeout: FetchedDisconnectError(error: nil, timedOut: true)) { @MainActor in
                FetchedDisconnectError(error: await fetching.fetchLastDisconnectError(id), timedOut: false)
            }
            guard let self, self.pending[id]?.token == token, !self.userStops.contains(id), let e = fetched.error else { return }
            // 2.0.1: the extension refused the start beside another LockPlus session that runs. Its own deliberate end,
            // which NE doesn't restart: the hold ends now and the refusal says why.
            let refusedCode = Self.observedError(e).0.code
            if refusedCode == .anotherTunnelActive || refusedCode == .startNotAuthorised {      // 2.0.2: 225 the same way
                guard await self.isFreshRefusal(id, since: self.endSeenAt[id], issued: issued, code: refusedCode) else { return }   // review L1: sticky otherwise
                guard self.pending[id]?.token == token, !self.userStops.contains(id), self.attemptGeneration[id] == gen else { return }
                log.notice("\(id.uuidString.prefix(8), privacy: .public): refused beside another LockPlus session; NE won't restart it")
                self.clearPending(id, token: token)
                self.surfaceRefusal(id, refusedCode, refusedCode == .anotherTunnelActive
                                    ? self.refusalDetail(id, e.userInfo[LPTunnelError.detailKey] as? String)
                                    : e.userInfo[LPTunnelError.detailKey] as? String)
                self.restoreIfIdle()
                return
            }
            guard Self.isNoNetwork(e) else { return }
            // Review aad7527 #7: the reason row 14 shows if NE's restart never comes (row 12a covers it until then).
            if id == self.currentID {
                let (observed, detail) = Self.observedError(e)
                self.observedError = ObservedError(code: observed.code, origin: .failedStart)
                self.errorDetail = detail
                self.errorAt = self.now()
                self.userStoppedSinceError = false
            }
            await self.holdForNetworkRestart(id, replacing: token)
        }
    }

    /// E2E-4 200012: the end of a refused start that NE won't restart (a System Settings start of a profile without the
    /// kill switch, ovpn-split-dns): its error is read like a failed start's, and surfaced. Where it shows follows the
    /// existing rule for a start made elsewhere (`holdForSystemRestart`, review aad7527 #3): when nothing else is active or
    /// starting, the hero follows that profile (row 14 is about the profile the user just tried); beside another active or
    /// pending session the hero stays and Diagnostics carries a problem line instead, so the failure is never silent.
    /// 2.0.1: also `.anotherTunnelActive` (the extension's start guard), only when the snapshot dates it to this attempt
    /// (review L1; else it is a sticky older one). `offline`: the `.disconnecting` was seen while the network was down
    /// (code 2 only then).
    private func readRefusal(_ id: UUID, offline: Bool) {
        let fetching = managers, deadline = disconnectErrorTimeout, gen = attemptGeneration[id], issued = startIssuedAt[id]
        let retrySleep = refusalReadSleep
        Task { @MainActor [weak self] in
            // Round 1 (E2E F6): NE may report `.disconnected` before it stores the refusal; read again while none is there.
            guard let me = self else { return }
            let fetched = await me.readDisconnectError(id, fetching: fetching, deadline: deadline, retry: true, untilRefusal: true,
                                                       sleep: retrySleep) { [weak self] in
                guard let self else { return false }
                return attemptGeneration[id] == gen && pending[id] == nil && statuses[id] == .disconnected
            }
            // A newer start or stop of this profile, or a session of it, has its own story.
            guard let self, let ns = fetched.error, pending[id] == nil, !userStops.contains(id),
                  statuses[id] == .disconnected, !sawActive.contains(id) else { return }
            let (observed, detail) = Self.observedError(ns)
            let stillThisAttempt = { [unowned self] in
                attemptGeneration[id] == gen && pending[id] == nil && !userStops.contains(id)
                    && statuses[id] == .disconnected && !sawActive.contains(id)
            }
            if Self.isNoNetwork(ns) {
                guard offline, attemptGeneration[id] == gen else { return }
                surfaceRefusal(id, observed.code, detail)
            } else if observed.code == .anotherTunnelActive {
                guard await isFreshRefusal(id, since: endSeenAt[id], issued: issued), stillThisAttempt() else { return }
                surfaceRefusal(id, observed.code, refusalDetail(id, detail))
            } else if observed.code == .startNotAuthorised {
                // 2.0.2: a start the owner's LockPlus didn't arm (System Settings, scutil, another app instance).
                guard await isFreshRefusal(id, since: endSeenAt[id], code: .startNotAuthorised), stillThisAttempt() else { return }
                surfaceRefusal(id, observed.code, detail)
            } else if observed.code == .supersededByKillSwitch {
                // Codex final 5: a pending start the extension ended for a kill-switch start, never seen active.
                guard await isFreshRefusal(id, since: endSeenAt[id], code: .supersededByKillSwitch, window: Self.supersededWindow),
                      stillThisAttempt() else { return }
                surfaceRefusal(id, observed.code, detail)
            }
        }
    }

    /// Round 1 (E2E F6, 26.6.2): NE can report `.disconnected` up to ~1 s before it stores the error (the first start
    /// made outside LockPlus after a launch then showed no reason anywhere). With `retry`, a missing error (or one that
    /// isn't a refusal) is read again after each of `refusalReadRetries`, while `still()` holds.
    /// `untilRefusal`: an error that isn't a refusal (or code 2) is read again too (a sticky older one may still be there).
    private func readDisconnectError(_ id: UUID, fetching: any VPNManaging, deadline: Duration, retry: Bool, untilRefusal: Bool = false,
                                     sleep: @Sendable (Duration) async -> Void,
                                     still: @MainActor () -> Bool) async -> FetchedDisconnectError {
        var fetched = FetchedDisconnectError(error: nil, timedOut: false)
        for (i, delay) in ([Duration.zero] + (retry ? Self.refusalReadRetries : [])).enumerated() {
            if i > 0 {
                await sleep(delay)
                guard still() else { return fetched }
            }
            fetched = await withDeadline(deadline, onTimeout: FetchedDisconnectError(error: nil, timedOut: true)) { @MainActor in
                FetchedDisconnectError(error: await fetching.fetchLastDisconnectError(id), timedOut: false)
            }
            if fetched.timedOut { return fetched }
            if let e = fetched.error {
                guard untilRefusal else { return fetched }
                let code = Self.observedError(e).0.code
                if Self.isNoNetwork(e) || [.anotherTunnelActive, .startNotAuthorised, .supersededByKillSwitch].contains(code) { return fetched }
            }
        }
        return fetched
    }

    /// Round 1 (E2E F6): the re-reads of a refusal NE hadn't stored yet when it reported `.disconnected` (≈3 s in all).
    static let refusalReadRetries: [Duration] = [.milliseconds(500), .milliseconds(1000), .milliseconds(1500)]
    @ObservationIgnored var refusalReadSleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// Review L1: a `.anotherTunnelActive` from `fetchLastDisconnectError` is sticky. It counts only when the extension's
    /// snapshot says it was recorded for this attempt: no earlier than `refusalWindow` before the attempt's first status
    /// (`since`; the refusal precedes NE's report by milliseconds). The extension keeps the time current for repeated
    /// refusals (its L3 coalescing writes the disk less often, never the snapshot).
    static let refusalWindow: TimeInterval = 10
    /// Re-check N4: a `.supersededByKillSwitch` is recorded before the session's teardown (≤ ~6 s) and NE's report.
    static let supersededWindow: TimeInterval = 30
    /// Round 3 (Codex 6, Fable L1): both bounds. A refusal of a start the app issued itself can't predate that issue
    /// (`issued`, captured for THIS attempt, final review N3), and no refusal is older than `window` before the attempt's
    /// first status (`since`): an old issue time never widens the window.
    private func isFreshRefusal(_ id: UUID, since: Date?, issued: Date? = nil, code: LPErrorCode = .anotherTunnelActive,
                                window: TimeInterval = ConnectionStore.refusalWindow) async -> Bool {
        guard let snap = try? await service.call(.tunnelSnapshot, ProfileRequest(profileID: id), as: TunnelSnapshot.self),
              snap.lastError?.code == code, let at = snap.lastErrorAt else { return false }
        var floor = (since ?? now()).addingTimeInterval(-window)
        if code == .anotherTunnelActive, let issued { floor = max(floor, issued.addingTimeInterval(-1)) }
        return at >= floor
    }

    /// Review L2: with no session this user can see active (another user's, or one LockPlus can't address), the copy
    /// can't say "Disconnect it first".
    private func refusalDetail(_ id: UUID, _ detail: String?) -> String? {
        visibleProfileActive(besides: id) ? detail : LPErrorCode.unseenSessionDetail
    }

    /// Where a refused start made elsewhere says why (E2E-4 200012, review aad7527 #3): when nothing else is active or
    /// starting, the hero follows that profile (row 14); beside another active or pending session the hero stays and
    /// Diagnostics carries a problem line.
    /// 2.0.1: a kill-switch profile's `.anotherTunnelActive` also posts `.killSwitchStartRefused` (review H1: its kill
    /// switch isn't protecting the Mac); the Diagnostics line and that notice at most once per profile per
    /// `refusalNoteInterval` (review L3: NE may retry an on-demand start beside the running session).
    static let refusalNoteInterval: TimeInterval = 300
    private func surfaceRefusal(_ id: UUID, _ code: LPErrorCode, _ detail: String?) {
        let repeated = (code == .anotherTunnelActive || code == .startNotAuthorised) && refusalRepeated(id)
        noteEnd(id, code, detail)
        // 2.0.1 E2E F1: the hero never leaves a profile NE still reports active for a refused one.
        if !anotherProfileActive(besides: id), id == currentID || pending.isEmpty {
            currentID = id
            observedError = ObservedError(code: code, origin: .failedStart)
            errorDetail = detail
            errorAt = now()
            userStoppedSinceError = false
        } else if !repeated, code != .startNotAuthorised {
            let name = profiles.profile(id)?.name ?? ""
            profiles.note(String(localized: "\(name) couldn't connect: \(code.reason(detail: detail)).",
                                 comment: "Problem: a start made elsewhere (System Settings) was refused while another profile is current (E2E-4 200012)"))
        }
        // 2.0.2 (D-1): a start outside LockPlus that the extension refused (225) is always said in Diagnostics (the hero may
        // be gone by the time anyone looks), unless this app armed a start of the profile itself just before (then it is
        // this app's own failure, not an outside start). Once per profile per `refusalNoteInterval` (the shared throttle).
        if code == .startNotAuthorised, !repeated, !armedRecently(id) {
            let name = profiles.profile(id)?.name ?? ""
            profiles.note(String(localized: "\(name) was started outside LockPlus and refused. Connect it from LockPlus.",
                                 comment: "Problem (2.0.2, D-1): a start of a profile that LockPlus didn't make (System Settings toggle, scutil) was refused with error 225"))
        }
        if code == .anotherTunnelActive, !repeated, managerKillSwitch(id) { onNotice?(.killSwitchStartRefused(id)) }
    }

    /// This app armed a start of the profile within `armWindow` (a 225 right after is its own failure, not an outside start).
    private func armedRecently(_ id: UUID) -> Bool {
        guard let at = lastArmedAt[id] else { return false }
        if now().timeIntervalSince(at) < Self.armWindow { return true }
        lastArmedAt[id] = nil                                 // round 1 (Sonnet NIT): an old arm is forgotten
        return false
    }

    /// 2.0.1 E2E F2: the last 222/223 end of a profile, shown in its own detail while it isn't the current one (the hero
    /// of the current profile is not replaced by it). Cleared when the profile is active again.
    private(set) var endNotes: [UUID: (code: LPErrorCode, detail: String?)] = [:]
    private func noteEnd(_ id: UUID, _ code: LPErrorCode, _ detail: String?) { endNotes[id] = (code, detail) }

    /// The shared refusal throttle (review L3, re-check L4, Codex 6): true when this profile's refusal was already said
    /// within `refusalNoteInterval` beside the same set of active profiles; otherwise records this one and says false.
    private func refusalRepeated(_ id: UUID) -> Bool {
        let blockers = Set(statuses.filter { $0.key != id && $0.value.isActive }.keys)
        if let n = refusalNotedAt[id], now().timeIntervalSince(n.at) < Self.refusalNoteInterval, n.blockers == blockers { return true }
        refusalNotedAt[id] = (now(), blockers)
        return false
    }

    /// Round 3 (Codex 5, final review N2): the current profile ended while another one is active (a kill-switch start
    /// made elsewhere that preempted it, connected or still pending/held): that one becomes current, so its state, its
    /// error and its Cancel are what the hero shows and targets. Not during a switch of ours (it names its target).
    private func selectActiveSuccessor(after id: UUID) {
        guard id == currentID, switchTarget == nil,
              let successor = statuses.first(where: { $0.key != id && $0.value.isActive && isOwnProfile($0.key) })?.key else { return }
        currentID = successor
        connectedSince = connectedAt[successor]
        observedError = nil; errorDetail = nil; errorAt = nil
    }

    /// A stray's status changed (round 5, Codex 3): it is noted if it waits, and the shared recovery runs, since a
    /// stray that ended may no longer hold a deferred heal or on-demand restore back (`restoreIfIdle`; the heal's save
    /// stays conditional, `healProtectiveDrift`).
    func strayStatusChanged() {
        noteStrayDuplicates()
        restoreIfIdle()
    }

    /// Round 5: this user's stray duplicate of an active profile (another configuration of it, started outside
    /// LockPlus, e.g. `scutil --nc start`), pending: the extension keeps it waiting beside that profile's kill-switch
    /// session, and its live status keeps the app busy (no configuration saves or heals) until it is stopped. LockPlus
    /// doesn't stop it: from the app side a waiter can't be told from a protective replacement (rounds 3 to 5, DESIGN
    /// §20 risk 27). Diagnostics says where to stop it, once per attempt.
    ///
    /// Round 6 (Fable L2): only where the extension does keep it waiting: the addressable configuration of the profile
    /// is `.connected` and its manager's flags carry `includeAllNetworks`. Beside a weakened live flag a kill-switch
    /// duplicate is the protective replacement, and a duplicate of a profile without the kill switch is refused (222).
    func noteStrayDuplicates() {
        let strays = managers.strays
        let live = Set(strays.filter { $0.status.isLive }.compactMap { s in s.profileID.map { StrayIdentity(ownerUID: s.ownerUID, profileID: $0) } })
        strayNoted.formIntersection(live)
        // Round 7 (Codex L6): only a duplicate WITH the kill switch is kept waiting (one without it is refused, 222).
        for s in strays where s.ownerUID == profiles.ownerUID && s.status == .connecting && s.includeAllNetworks == true {
            guard let pid = s.profileID, !strayNoted.contains(StrayIdentity(ownerUID: s.ownerUID, profileID: pid)),
                  managers.status(pid) == .connected, managerKillSwitch(pid),
                  let name = profiles.profile(pid)?.name else { continue }
            strayNoted.insert(StrayIdentity(ownerUID: s.ownerUID, profileID: pid))
            profiles.note(String(localized: "A second configuration of \(name) was started outside LockPlus and is waiting. Stop it in System Settings › VPN.",
                                 comment: "Diagnostics note (2.0.1 round 5): a duplicate VPN configuration of an active profile, started elsewhere, waits in the extension and keeps LockPlus from changing configurations"))
        }
    }

    /// An app-issued start of `id`: a newer attempt (Codex final 4, final review L1 and N3).
    private func newIssuedAttempt(_ id: UUID) {
        attemptGeneration[id, default: 0] &+= 1
        endSeenAt[id] = nil
        startIssuedAt[id] = now()
        resumableSession.insert(id)
    }

    /// 2.0.1: another configuration's session is active (the extension refuses a start beside it, `.anotherTunnelActive`).
    private func anotherProfileActive(besides id: UUID) -> Bool {
        statuses.contains { $0.key != id && $0.value.isActive }
    }

    /// Round 9 (Codex LOW): for the copy only ("Disconnect it first"): one of THIS user's profiles (in its list, so the
    /// user can see and disconnect it) is active. Another user's configuration is in `statuses` too.
    private func visibleProfileActive(besides id: UUID) -> Bool {
        statuses.contains { $0.key != id && $0.value.isActive && profiles.profile($0.key) != nil }
    }

    /// The user's stop of `id` while NE's restart after "No network available" is awaited (Cancel, a Connect of another
    /// profile, Pause, a delete): the hold and its record end, and `stopVPNTunnel` on the disconnected session cancels NE's
    /// restart (measured on 26 and 27: no restart in 60 s after the network returned). Synchronous, so the stop is issued
    /// before anything a caller restores or starts next. A user stop like any other (L-E re-stops a restart that lands
    /// within 2 s anyway).
    private func stopNetworkRestart(_ id: UUID) {
        guard pending[id]?.phase == .awaitingNetworkRestart else { return }
        log.notice("\(id.uuidString.prefix(8), privacy: .public): the user stopped it while NE's restart was awaited")
        clearPending(id)
        userStops.insert(id)
        userStopsAt[id] = now()
        userStopSettled.remove(id)
        userStoppedSinceError = true
        managers.stop(id)
        settleStopOfDownSession(id)
    }

    /// Round 4 (Fable L2d): the user's Pause while a watched session's restart is awaited (`crashGapHolder`): the entry
    /// ends, and `stopVPNTunnel` on the disconnected session cancels NE's restart (L-E re-stops one that lands within
    /// 2 s).
    private func stopAwaitedRestart(_ id: UUID) {
        guard pending[id]?.phase == .awaitingRestart else { return }
        log.notice("\(id.uuidString.prefix(8), privacy: .public): the user paused while its restart was awaited")
        clearPending(id)
        crashes.forgetCrash(id)
        userStops.insert(id)
        userStopsAt[id] = now()
        userStopSettled.remove(id)
        userStoppedSinceError = true
        managers.stop(id)
        settleStopOfDownSession(id)
    }

    /// Review 2518e93 #1: NE may report nothing for a stop of a session that is already down (measured nowhere; the fake's
    /// default), or `.disconnecting` → `.disconnected`. Either way the stop is complete after a short grace: a later
    /// `.disconnecting` out of a non-live status is a new session (`userStopSettled`). `userStops` stays for L-E. The
    /// grace lets the stop's own report (if any) pass first; `.disconnected` settles it too.
    static let stopReportGrace: Duration = .milliseconds(2500)
    private func settleStopOfDownSession(_ id: UUID) {
        guard !managers.status(id).isLive, !sawActive.contains(id) else { return }
        let at = userStopsAt[id], sleep = timerSleep
        Task { @MainActor [weak self] in
            await sleep(Self.stopReportGrace)
            guard let self, self.userStops.contains(id), self.userStopsAt[id] == at,
                  self.statuses[id]?.isLive != true, !self.sawActive.contains(id) else { return }
            self.userStopSettled.insert(id)
        }
    }

    /// Every NWPathMonitor report: a start waiting for a network starts once one is there (after `endpointPushSettle`,
    /// so DNS follows the path change before its endpoints are resolved); NE's awaited restart gets its fallback timer
    /// once there is a network, and loses it again when the network goes before NE's restart came.
    private func applyNetworkToHolds() {
        let available = networkAvailable == true
        for (id, e) in pending {
            switch e.phase {
            case .waitingForNetwork where available:
                let token = e.token, settle = endpointPushSettle
                Task { @MainActor [weak self] in
                    if settle > .zero { try? await Task.sleep(for: settle) }
                    guard let self, self.pending[id]?.token == token else { return }
                    // Review aad7527 #2: one start at a time, as for a Connect: while another entry exists (NE's restart
                    // of another profile after "No network available", a teardown) this one keeps waiting; the end of
                    // that entry runs this again (`clearPending`).
                    guard self.pending.allSatisfy({ $0.key == id }) else {
                        self.log.notice("\(id.uuidString.prefix(8), privacy: .public): a network is available, but another start or hold is in flight; still waiting")
                        return
                    }
                    // Review b47da1c L-3: the same checks as a Connect: NE's on-demand start of another profile that
                    // landed with the network is switched out first, a session still stopping is waited for.
                    if self.managers.status(id).isActive {
                        self.clearPending(id)       // it runs already (an on-demand or System Settings start)
                        return
                    }
                    self.log.notice("\(id.uuidString.prefix(8), privacy: .public): a network is available; starting")
                    self.beginStart(id)             // `startNow` checks the network again
                }
            case .awaitingNetworkRestart where available != e.fallbackArmed:
                armNetworkRestart(id)
            default: break
            }
        }
    }

    /// Launch: the network-restart hold recorded by the previous run (quit or crash while waiting) is entered again if
    /// it still applies: the configuration exists, is `.disconnected` and is a kill-switch one without on-demand rules.
    /// Otherwise (gone, NE's restart already live, changed) the record is dropped. Before the launch's restore.
    private func resumeNetworkRestartAtLaunch() {
        guard let id = settings.value.networkRestartHold else { return }
        // Review aad7527 #1: also while a pause is recorded. The pause's own write clears a hold that existed when it began;
        // one recorded now began during the pause (a Connect refused for want of a network), and its stop is still owed.
        guard let m = managers.managers.first(where: { $0.profileID == id }), m.status == .disconnected,
              m.flags?.includeAllNetworks == true, !m.onDemandEnabled else {
            log.notice("network-restart hold of \(id.uuidString.prefix(8), privacy: .public) no longer applies at launch; dropped")
            forgetNetworkRestartRecord(id)
            return
        }
        log.notice("\(id.uuidString.prefix(8), privacy: .public): NE's restart after \"No network available\" is still awaited at launch")
        sessionKillSwitch[id] = true
        if statuses.allSatisfy({ !$0.value.isActive }) { currentID = id }
        unverifiedHold = id
        armNetworkRestart(id)
        // Round 3 (Codex r3 #4): settings.json isn't authenticated. The hold counts as one only once its tag verified;
        // until then it holds the restore back but is no pause target. Invalid (forged, a copy of an ended hold, or one
        // written before 2.0.2): dropped.
        let tag = settings.value.networkRestartHoldTag
        Task { @MainActor [weak self] in
            guard let self else { return }
            let check = await self.holdRecordOp { repo in
                switch await repo.checkRecord(.networkRestartHold, tag: tag, AppSettings.networkRestartHoldMessage(id)) {
                case .valid: "valid"
                case .unavailable: "unavailable"
                case .invalid, .neverSealed: nil
                }
            }
            self.holdChecked(id, check)
        }
    }

    private func holdChecked(_ id: UUID, _ check: String?) {
        guard unverifiedHold == id else { return }
        switch check {
        case "valid":
            unverifiedHold = nil
        case "unavailable":
            log.error("network-restart hold of \(id.uuidString.prefix(8), privacy: .public) not checked (keychain unavailable): held, never a pause target")
        default:
            log.fault("network-restart hold of \(id.uuidString.prefix(8), privacy: .public) in settings.json doesn't verify; dropped")
            unverifiedHold = nil
            if pending[id]?.phase == .awaitingNetworkRestart { clearPending(id) }
            forgetNetworkRestartRecord(id)
            restoreIfIdle()
        }
    }

    /// Review e321e10 (HIGH, LOW 3): `.invalid` ends a session too (the configuration was removed or became unusable:
    /// `SerializedVPNManager` reports it for a live manager that vanished, whose `.disconnected` NE never delivers).
    /// No error is fetched and nothing is restarted (NE can't restart a configuration that is gone); every hold this
    /// session kept (its teardown entry, a start waiting for its stop, a `stopAndWait`) ends here.
    ///
    /// The one end path (review 385b6ea L-C): `dropVanished` and the `.invalid` branch both come here. A gone manager's
    /// last status and per-session facts go with it.
    private func sessionEnded(_ id: UUID) {
        if sawActive.remove(id) != nil {
            resetSnapshotEpoch()
            reachedConnected.remove(id)
            userStops.remove(id)
            if id == currentID { connectedSince = nil }
            if restartedAfterCrash == id { restartedAfterCrash = nil }
            onObservedDisconnect?(id, nil)
        }
        if !isKnown(id) {
            if statuses[id] != nil || sessionKillSwitch[id] != nil {
                log.notice("\(id.uuidString.prefix(8), privacy: .public)'s configuration is gone; its session counts as ended")
            }
            statuses[id] = nil
            sessionKillSwitch[id] = nil
            reachedConnected.remove(id)
            userStops.remove(id)
            if id == currentID { connectedSince = nil }
        }
        issuedEnding.remove(id)
        refusalStopping.remove(id)
        endSeenAt[id] = nil
        refusalNotedAt[id] = nil
        endNotes[id] = nil
        userStopSettled.remove(id)
        userStopsAt[id] = nil
        if pending[id]?.phase == .awaitingRestart || pending[id]?.phase == .awaitingNetworkRestart { clearPending(id) }
        if let target = waiter(for: id) { startNow(target) }
        resumeEndWaiters(id, ended: true)
    }

    // MARK: Stops the app makes for the user (review e321e10)

    /// Callers of `waitForSessionEnd`, resumed at the session's `.disconnected`/`.invalid`, when its manager vanished,
    /// or by their timer (false).
    @ObservationIgnored private var endWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    /// How long a delete waits for the session it stops to end before it removes the configuration anyway (the removal
    /// then reports `.invalid`). Tests: released by hand (`timerSleep`).
    @ObservationIgnored var removalStopTimeout: Duration = .seconds(10)

    private func resumeEndWaiters(_ id: UUID, ended: Bool) {
        for k in endWaiters.removeValue(forKey: id) ?? [] { k.resume(returning: ended) }
    }

    /// True once `id`'s session has ended (at once if it isn't live), false after `timeout`.
    func waitForSessionEnd(_ id: UUID, timeout: Duration) async -> Bool {
        guard managers.status(id).isLive || statuses[id]?.isLive == true else { return true }
        let sleep = timerSleep
        let timer = Task { @MainActor [weak self] in
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            self?.resumeEndWaiters(id, ended: false)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { endWaiters[id, default: []].append($0) }
    }

    /// A stop the app makes on the user's behalf (a delete, an extension update's quiesce): a user stop (`userStops`),
    /// so its teardown gets no `.awaitingRestart` entry, its end fetches no error and says nothing "stopped
    /// unexpectedly", and no crash restart is awaited. No on-demand suspension (the caller turned on-demand off).
    func stopAsUser(_ id: UUID) {
        crashes.forgetCrash(id)
        if restartedAfterCrash == id { restartedAfterCrash = nil }
        // E2E-4 200011: a start waiting for a network, and NE's awaited restart after "No network available" (the stop
        // below cancels it), end too.
        if switchingTo == id { switchingTo = nil }
        if pending[id]?.phase == .awaitingNetworkRestart {
            stopNetworkRestart(id)            // synchronous: NE's restart is cancelled before anything is restored
            restoreIfIdle()                   // no `.disconnected` follows (the session is down already)
            return
        }
        for (k, e) in pending where k == id && (e.isUnissuedWait || e.phase == .starting(issued: false)) { clearPending(k) }
        stop(id, suspending: false)
    }

    /// `stopAsUser`, then wait (≤ `timeout`) until the session has ended. True: it ended.
    func stopAndWait(_ id: UUID, timeout: Duration) async -> Bool {
        // Review 385b6ea L-D: a start that is pending but not live yet (its prepare, a switch waiting for another stop)
        // is ended too, so the caller's removal can't be followed by the start re-creating the configuration.
        guard managers.status(id).isLive || statuses[id]?.isLive == true || pending[id] != nil else { return true }
        let start = startTasks[id]?.task
        stopAsUser(id)
        // Not covered by `timeout`: the start's own steps are bounded (settles, loads, `resolveEndpoints` ≤ 3 s per host,
        // `waitUntilSettled` ≤ 5 s), so this wait ends within about 10 s; the session wait below then has its own `timeout`.
        // Review 5c3a899/f18c0d6 M-1: the start's Task itself is awaited (its `gone()` checks end it at its next await):
        // a prepare still running would re-create the configuration the caller's removal is about to delete.
        await start?.value
        let ended = await waitForSessionEnd(id, timeout: timeout)
        if !ended { log.error("\(id.uuidString.prefix(8), privacy: .public) didn't report its end within the wait; continuing") }
        return ended
    }

    private func observedDisconnect(_ id: UUID) {
        resetSnapshotEpoch()
        if restartedAfterCrash == id { restartedAfterCrash = nil }
        let wasConnected = reachedConnected.remove(id) != nil
        let disconnectedAt = now()
        if id == currentID { connectedSince = nil }
        if userStops.remove(id) != nil {
            // Our own Disconnect: fetchLastDisconnectError would return a sticky older error (S12); nothing to show.
            userStoppedSinceError = true
            if switchingTo == nil || switchingTo == id { switchingTo = nil }
            // Review 385b6ea L-F: the teardown hold armed before the stop (`holdTeardown`) ends with the stop, not 22 s later.
            if pending[id]?.phase == .awaitingRestart { clearPending(id) }
            if wasConnected { onNotice?(.disconnectedByUser(id)) }
            onObservedDisconnect?(id, nil)
            return                            // our own stop: NE restarts nothing (`handle` restores when idle)
        }
        // Review F1: whether NE restarts this session itself (a tunnel-process crash) is known only after the error is
        // read; until then nothing is restored. A start of this profile that is already pending or waits for exactly this
        // stop (a Connect while it was disconnecting, N1b) holds everything back itself and is not replaced (nil: no entry
        // of this disconnect; `handle` starts the waiting one right after this). Simplification 5: this entry's timer covers
        // the bounded fetch plus the XPC reads after it; a crash decision re-arms with `startingTimeout`.
        let keep = pending[id].map { $0.phase != .awaitingRestart } ?? false
        let token: UInt64? = keep ? nil : arm(id, .awaitingRestart, timeout: disconnectErrorTimeout + .seconds(5))
        let fetching = managers, gen = attemptGeneration[id], issued = startIssuedAt[id]
        Task { @MainActor in
            var crashed = false
            // Review R9: bounded; a wedged nesessionmanager must not hold the restore (and `load()`) forever.
            // Round 1 (E2E F6): a start that never connected and ended with no error stored yet (26.6.2 stores it up to
            // ~1 s after `.disconnected`) is read again before anything is decided from "no error".
            let fetched = await readDisconnectError(id, fetching: fetching, deadline: disconnectErrorTimeout, retry: !wasConnected,
                                                    sleep: refusalReadSleep) { [weak self] in
                guard let self else { return false }
                return attemptGeneration[id] == gen && !userStops.contains(id) && statuses[id] == .disconnected
            }
            if fetched.timedOut { log.error("fetchLastDisconnectError never answered; treating the disconnect as no crash") }
            let ns = fetched.error
            var mapped = ns.map(Self.observedError)
            // Review b47da1c L-7: a code 2 at the end of a session that was connected is a sticky older one (measured (e)).
            if wasConnected, let ns, Self.isNoNetwork(ns) { mapped = nil }
            if let ns, Self.isPluginFailed(ns) {
                // Review PF-R1: the 12 is sticky (a clean on-demand Disconnect or another stop after an earlier crash
                // reports it again). Only a crash THIS disconnect saw counts for PF 52/53.
                let interrupted = await service.lastLinkInterruption()
                if crashes.isFreshCrash(id, wasConnected: wasConnected, linkInterruptedAt: interrupted, disconnectedAt: disconnectedAt) {
                    crashes.crashed(id, at: now())
                    crashed = true
                    if let token { restartAfterCrashIfNeeded(id, token) }   // keeps `.awaitingRestart` until back or no
                } else {
                    if let token, pending[id]?.token == token, crashDecision(id) == .expectSystemRestart {
                        // E2E-4 (U10's no-live-link branch, not producible by timing in the VMs): a crash while the XPC
                        // link was down reads as a sticky 12, and NE restarts a kill-switch session without on-demand
                        // rules itself ~1 s later. The R1 wait (fallback included) costs a sticky-12 stop only the
                        // fallback's delay of the restore; a restore inside NE's restart is the E2E-3 failure.
                        // Review e321e10 LOW 1: a hedged hold (`.mayRestart`: "Checking whether X restarts…", Cancel ends
                        // it), recorded as a crash so NE's restart reads as one (PF 53). User stops never get here.
                        // E2E-4 (200009): also a session that died while `.connecting`/`.reasserting` (never `.connected`).
                        crashed = true
                        log.notice("pluginFailed without a seen crash on a kill-switch session NE may restart itself: waiting for it")
                        holdForSystemRestart(id)
                    } else {
                        crashes.forgetCrash(id)
                        log.notice("pluginFailed without a tunnel-process crash at this disconnect (sticky): no restart")
                    }
                }
            }
            // E2E-4 200011: "No network available" (code 2) on a kill-switch session without on-demand rules and no stop
            // of ours since (a start of NE's or System Settings', or ours refused despite the path check): NE restarts it
            // when an interface returns, however long that takes. Held without a time limit while there is no network.
            // Review b47da1c L-7: only for a session that never reached `.connected`: a connected session that loses the
            // network goes `.reasserting` and stays live (measured (e)), so a code 2 at its end is a sticky older one.
            var noNetwork = false
            if !crashed, !wasConnected, let ns, Self.isNoNetwork(ns), !userStops.contains(id), let token, pending[id]?.token == token,
               crashDecision(id) == .expectSystemRestart {
                noNetwork = await holdForNetworkRestart(id, replacing: token)
                crashed = noNetwork                  // review aad7527 #6: a hold that ended during the write is no hold
            }
            // E2E-4 (200009): a kill-switch session without on-demand rules that ended before it was ever `.connected`
            // (no error, or the 12) is restarted by NE just the same: the same hedged hold. An error the extension
            // recorded itself (connect timeout, auth, ...) is its own deliberate end, which NE doesn't restart.
            if !crashed, !wasConnected, fetched.error.map(Self.isPluginFailed) ?? true, let token, pending[id]?.token == token, crashDecision(id) == .expectSystemRestart {
                crashed = true
                log.notice("session ended before it was connected on a kill-switch session NE may restart itself: waiting for it")
                holdForSystemRestart(id)
            }
            // M8: fetchLastDisconnectError is sticky. A LockPlus error the extension recorded BEFORE this attempt
            // started is an old one, not this disconnect's.
            // Codex 5: not for `.anotherTunnelActive`, which has its own freshness rule below (a refusal is recorded before
            // NE reports the start, possibly more than 1 s before its `.connecting` reaches the app).
            // Round 8 (Codex L4): nor for `.supersededByKillSwitch`, which has its own (30 s) window below.
            // Round 9 (Fable L1): only for an attempt that never connected; a connected session's sticky 223 is filtered.
            if let ns, ns.domain == LPTunnelError.errorDomain, ns.code != LPErrorCode.anotherTunnelActive.rawValue,
               ns.code != LPErrorCode.startNotAuthorised.rawValue,           // 2.0.2: its own freshness rule below, like 222
               ns.code != LPErrorCode.supersededByKillSwitch.rawValue || wasConnected,
               let started = attemptStartedAt[id],
               let snap = try? await service.call(.tunnelSnapshot, ProfileRequest(profileID: id), as: TunnelSnapshot.self),
               let at = snap.lastErrorAt, at < started.addingTimeInterval(-1) {
                mapped = nil
            }
            // 2.0.1 review L1: a refusal is never the end of a session that was connected (a sticky older one), and counts
            // only when the snapshot dates it to this attempt. Review L2: the copy for a blocking session this user can't see.
            if mapped?.0.code == .anotherTunnelActive {
                let fresh = wasConnected ? false : await isFreshRefusal(id, since: attemptStartedAt[id], issued: issued)
                if !fresh { mapped = nil }
                else if !visibleProfileActive(besides: id) { mapped?.1 = LPErrorCode.unseenSessionDetail }
            } else if mapped?.0.code == .startNotAuthorised {
                // 2.0.2: never the end of a session that was connected (sticky older one); counts only when dated to this attempt.
                let fresh = wasConnected ? false : await isFreshRefusal(id, since: attemptStartedAt[id], code: .startNotAuthorised)
                if !fresh { mapped = nil }
            } else if mapped?.0.code == .supersededByKillSwitch,
                      !(await isFreshRefusal(id, since: disconnectedAt, code: .supersededByKillSwitch, window: Self.supersededWindow)) {
                mapped = nil                 // re-check N4: a sticky 223 read at a later, clean stop elsewhere
            }
            // Codex final 4: a newer attempt of this profile began during the reads above. This end's error copy, its
            // refusal lines and notices and `onObservedDisconnect` (which would clear the newer attempt's prompt) are
            // dropped; the generic "stopped unexpectedly" of the session that did end stays (Nit 6, aad7527).
            var stale = attemptGeneration[id] != gen
            if stale { log.notice("\(id.uuidString.prefix(8), privacy: .public): a newer attempt began while this disconnect was read; its error isn't shown") }
            if id == currentID, !stale {
                observedError = mapped.map { var e = $0.0; e.origin = wasConnected ? .providerCancel : .failedStart; return e }
                errorDetail = mapped?.1
                errorAt = mapped == nil ? nil : now()
                userStoppedSinceError = false
                if switchingTo == id { switchingTo = nil }
            }
            // Round 1 (Fable L1): never for a profile the sandboxed check hasn't passed (`provision` refuses it too).
            if let code = mapped?.0.code, code == .profileNotProvisioned || code == .profileRevisionStale,
               !retriedAfterProvision.contains(id), let p = profiles.profile(id), p.engineVerified {
                // §6.4: reconcile this profile and retry once.
                retriedAfterProvision.insert(id)
                let entryToken = pending[id]?.token
                do throws(LPError) {
                    try await profiles.provision(p)
                    // Only over this disconnect's own entry (or none): never beside a start that is already pending.
                    // Round 7 (Codex M1): and only for THIS attempt (no newer one, the same entry), and never beside
                    // another session: a background retry doesn't switch away from (or stop) anything.
                    if attemptGeneration[id] == gen, pending[id]?.token == entryToken,
                       pending[id].map({ $0.phase == .awaitingRestart }) ?? true {
                        if othersBusy(except: id) {
                            retriedAfterProvision.remove(id)                    // round 8 (Fable N2): not used up
                            log.notice("re-provisioned \(id.uuidString.prefix(8), privacy: .public); not retried: another connection is active")
                            profiles.note(String(localized: "LockPlus didn't retry \(p.name) automatically: another connection is active.",
                                                 comment: "Diagnostics note (2.0.1 round 7): the automatic retry after re-installing a profile was skipped because another VPN connection became active"))
                        } else {
                            startNow(id, automatic: true)
                        }
                    }
                } catch {
                    log.error("re-provision after \(code.rawValue, privacy: .public) failed: \(error.code.rawValue, privacy: .public)")
                }
                stale = stale || attemptGeneration[id] != gen          // Codex final 4: again after that await
            }
            // Sign-in codes are not "stopped": the prompt has its own notice (AuthCoordinator). Nor is a session NE connects
            // again when a network is available (row 12a says so).
            let code = mapped?.0.code
            if code == .anotherTunnelActive {
                // A start that never ran: no "disconnected unexpectedly"; a kill-switch profile's refusal says so (H1).
                // Codex 4: the configuration's current flag (this attempt's), never a previous session's cached one.
                // Codex 6: through the same throttle as the refusals whose `.connecting` was missed.
                // E2E F1: through `surfaceRefusal` (hero only with nothing else active, else Diagnostics; the throttle).
                if !stale { surfaceRefusal(id, .anotherTunnelActive, mapped?.1) }
            } else if code == .startNotAuthorised {
                // 2.0.2: a start that never ran (D-1): no "disconnected unexpectedly"; the refusal says what to do.
                if !stale { surfaceRefusal(id, .startNotAuthorised, mapped?.1) }
            } else if !noNetwork, (wasConnected || mapped != nil), code != .authRequired, code != .authFailed {
                onNotice?(.stoppedUnexpectedly(id))
            }
            if code == .supersededByKillSwitch, !stale { noteEnd(id, .supersededByKillSwitch, mapped?.1) }   // E2E F2
            if code == .supersededByKillSwitch, !stale, let name = profiles.profile(id)?.name {
                // Review H1: the extension ended it for a kill-switch profile's start (a Diagnostics line, and E2E F2: its detail).
                profiles.note(String(localized: "\(name) stopped: \(LPErrorCode.supersededByKillSwitch.reason()).",
                                     comment: "Problem (2.0.1 review H1): a profile was ended for another profile's kill-switch start"))
            }
            if !stale { onObservedDisconnect?(id, code) }
            refreshSnapshot()
            if !crashed, let token {
                clearPending(id, token: token)
                restoreIfIdle()
            }
        }
    }

    private struct FetchedDisconnectError: Sendable { var error: NSError?; var timedOut: Bool }

    /// `fetchLastDisconnectError` → (ObservedError, detail). LockPlus codes keep their code and `lp.detail` (A-ERR-1);
    /// `NEVPNConnectionErrorDomain` 12 (pluginFailed) is the extension dying, 14 (pluginDisabled) the component off.
    static func observedError(_ e: NSError) -> (ObservedError, String?) {
        if e.domain == LPTunnelError.errorDomain, let code = LPErrorCode(rawValue: e.code) {
            return (ObservedError(code: code), e.userInfo[LPTunnelError.detailKey] as? String)
        }
        if e.domain == NEVPNConnectionErrorDomain {
            switch e.code {
            case 2: return (ObservedError(code: .noNetwork), "NEVPNConnectionError 2")     // review b47da1c L-7
            case 12: return (ObservedError(code: .engineDied), "NEVPNConnectionError 12")
            case 14: return (ObservedError(code: .extensionUnavailable), "NEVPNConnectionError 14")
            default: return (ObservedError(code: .engineFatal), "NEVPNConnectionError \(e.code)")
            }
        }
        return (ObservedError(code: .engineFatal), "\(e.domain) \(e.code)")
    }

    // MARK: Snapshot

    func refreshSnapshot() {
        guard let id = currentID else { snapshot = nil; return }
        snapshotTask?.cancel()
        let service = self.service
        snapshotTask = Task { @MainActor [weak self] in
            let s = try? await service.call(.tunnelSnapshot, ProfileRequest(profileID: id), as: TunnelSnapshot.self)
            guard let self, !Task.isCancelled, self.currentID == id else { return }
            self.apply(snapshot: s, for: id)
        }
    }

    /// The newest non-zero epoch seen in the current session. Epoch 0 (an idle profile's latch/lastError) is never
    /// "older"; the floor resets on a new attempt and at session end (review H6).
    @ObservationIgnored private var epochFloor: (profile: UUID, epoch: UInt64)?

    func resetSnapshotEpoch() { epochFloor = nil }

    func apply(snapshot s: TunnelSnapshot?, for id: UUID) {
        if let s, s.epoch != 0, let f = epochFloor, f.profile == s.profileID, s.epoch < f.epoch { return }   // stale
        if let s, s.epoch != 0, let pid = s.profileID { epochFloor = (pid, s.epoch) }
        snapshot = s
        // L4: the launch rule needs a real snapshot; a failed read leaves it for the next one.
        guard !launchSnapshotChecked, s != nil else { return }
        launchSnapshotChecked = true
        // S12 launch rule: a sticky error is shown only with a latch, a pending prompt, or if newer than the last quit.
        if observedError == nil, statuses[id] != .connected, let s, let e = s.lastError,
           LastErrorPolicy.isShowable(source: .launchSnapshot(recordedAt: s.lastErrorAt), hasStartLatch: s.startLatch != nil,
                                      lastQuitAt: settings.value.lastQuitAt) {
            observedError = ObservedError(code: e.code, origin: .other)
            errorDetail = e.detail
            errorAt = s.lastErrorAt
        }
    }

    // MARK: Intents

    /// Starts `id` (switching away from another active profile first, §6.2). Draft 9: a sign-in the server asks for
    /// happens inside this start (AuthCoordinator answers into it); nothing is ever carried to another start.
    /// False: ignored (unknown profile, another start in flight, or `id` is active already); a refused start (not
    /// verified) is not "ignored", it shows its failure.
    @discardableResult
    func connect(_ id: UUID) -> Bool {
        // E2E-4 (n1b "now"): every Connect the store doesn't take says so in the log.
        guard let p = profiles.profile(id) else {
            log.notice("connect of \(id.uuidString.prefix(8), privacy: .public) ignored: no such profile")
            return false
        }
        // E2E-4 200011: the user's Connect of another profile while NE's restart of X after "No network available" is
        // awaited (and nothing else) stops X first (a user stop, which cancels NE's restart), then proceeds: X would
        // otherwise come back by itself beside this start. X's own Connect is held (the guard below; the UI doesn't offer
        // it). Review b47da1c L-8a: X is stopped only once every check below has passed.
        let held = networkRestartHolder.flatMap { $0 != id && pending.count == 1 ? $0 : nil }
        // Review F10d, review 4 #1: one start at a time, of ANY profile. A second start beside a pending one (its pause and
        // `prepareForStart` save other managers inside the first one's pending kill-switch start, E2E-3), or a start into
        // NE's Stopping (S2), is what the state machine exists to prevent: a Connect while any start, switch or restart is
        // in flight is ignored. Only this profile's own `.awaitingRestart` is taken over (a newer entry).
        guard pending.allSatisfy({ ($0.key == id && $0.value.phase == .awaitingRestart) || $0.key == held }) else {
            log.notice("connect of \(id.uuidString.prefix(8), privacy: .public) ignored: a start is in flight")
            return false
        }
        // Review 4 #5: a Connect of the running profile is no start (`prepareForStart` would save a live manager, L-KS-2,
        // and `startVPNTunnel` would hit a live session). The live status, not the last handled event: a Connect right
        // after a stop (the retry of an approval, the end of a pause) may come before the `.disconnected` notification.
        if managers.status(id).isActive {
            log.notice("connect of \(id.uuidString.prefix(8), privacy: .public) ignored: it is \(String(describing: self.managers.status(id)), privacy: .public) already")
            return false
        }
        restartedAfterCrash = nil
        crashes.forgetCrash(id)
        guard p.engineVerified else {
            fail(id, LPError(.profileInvalid, detail: "not yet verified by LockPlus's file check"))
            return true
        }
        if let held { stopNetworkRestart(held) }
        settings.update { $0.lastUsedProfileID = id }
        pending[id]?.automatic = false                      // round 8: the user's own Connect from here on
        beginStart(id)
        return true
    }

    /// The start part of a Connect, shared with the start that waited for a network (review b47da1c L-3): a switch when
    /// another profile is active, a wait when a session is still stopping (S2), else the start.
    private func beginStart(_ id: UUID) {
        // Round 8 (Codex M2, Fable L3): a background retry resumed after a wait for a network never switches.
        if isAutomatic(id), othersBusy(except: id) { abandonAutomaticRetry(id); return }
        if let active = statuses.first(where: { $0.value.isActive && $0.key != id })?.key {
            beginSwitch(to: id, stopping: active)
            return
        }
        currentID = id
        // Review N1(b), S2: a start issued while NE still stops this profile's session is silently dropped, and the
        // old session's `.disconnected` would arrive inside the new start. It starts at that `.disconnected`. Review 5
        // #2: the live status too (the active check above reads it): NE may already be Stopping while the handled
        // event still says `.connected`.
        // E2E-4: the same for another profile NE still stops (a Disconnect followed at once by a Connect of another
        // profile): the start (its pause and `prepareForStart` saves) begins at that session's `.disconnected`, never
        // inside its teardown. (A teardown the user didn't start has its own entry already: the guard above ignored it.)
        let stoppingSelf = managers.status(id) == .disconnecting || statuses[id] == .disconnecting
        if let stopping = stoppingSelf ? id : stoppingOther(except: id) {
            log.notice("connect of \(id.uuidString.prefix(8), privacy: .public) waits for \(stopping.uuidString.prefix(8), privacy: .public) to report .disconnected")
            arm(id, .waitingForStop(of: stopping), timeout: stopTimeout)
            return
        }
        startNow(id)
    }

    /// Another profile whose session NE is still stopping (the handled event or the live status).
    private func stoppingOther(except id: UUID) -> UUID? {
        statuses.first { $0.key != id && $0.value == .disconnecting }?.key
            ?? managers.managers.first { $0.profileID != id && $0.status == .disconnecting }?.profileID
    }

    /// §6.2: stop `active`, and start `id` once it has reported `.disconnected` (S2: a start issued while NE is still
    /// stopping is silently dropped). The auto profile is paused FIRST and the stop records no suspension (review
    /// F10a): the stop is part of the switch, so the auto profile comes back with the pause record when `id` ends.
    /// The entry holds everything back from the click on; its timer (NE's Stopping budget) counts from the stop.
    private func beginSwitch(to id: UUID, stopping active: UUID) {
        switchingTo = id
        currentID = id
        let token = arm(id, .waitingForStop(of: active), timeout: stopTimeout)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do throws(PauseFailure) { try await self.pauseOtherOnDemand(except: id, token: token) } catch {
                guard self.pending[id]?.token == token else { self.restoreIfIdle(); return }
                await self.failPause(id, token, error)
                return
            }
            guard self.pending[id]?.token == token else { return }      // started, cancelled or failed meanwhile
            self.stop(active, suspending: false)
            self.arm(id, .waitingForStop(of: active), timeout: self.stopTimeout)
        }
    }

    /// Review 5c3a899/f18c0d6 M-1: the Task of each profile's latest `startNow`, kept until it finishes, so a Delete
    /// can wait for it (`stopAndWait`).
    @ObservationIgnored private var startTasks: [UUID: (token: UInt64, task: Task<Void, Never>)] = [:]

    /// `automatic`: a background retry (round 7, Codex M1): it never switches away from another session (`runStart`).
    private func startNow(_ id: UUID, automatic: Bool = false) {
        // E2E-4 200011: no `startVPNTunnel` without a network (`waitForNetwork`).
        if networkAvailable == false {
            waitForNetwork(id)
            if automatic { pending[id]?.automatic = true }
            return
        }
        let token = arm(id, .starting(issued: false))
        if automatic { pending[id]?.automatic = true }
        let task = Task { @MainActor [weak self] in
            await self?.runStart(id, token)
            if self?.startTasks[id]?.token == token { self?.startTasks[id] = nil }
        }
        startTasks[id] = (token, task)
    }

    /// Round 7/8 (Codex M1/M2): a background retry that finds another session busy ends here, said in Diagnostics
    /// (it never switches away from it). Its one automatic repair isn't used up (Fable N2).
    private func abandonAutomaticRetry(_ id: UUID) {
        log.notice("automatic retry of \(id.uuidString.prefix(8), privacy: .public) abandoned: another connection is active")
        clearPending(id)
        retriedAfterProvision.remove(id)
        profiles.note(String(localized: "LockPlus didn't retry \(profiles.profile(id)?.name ?? "") automatically: another connection is active.",
                             comment: "Diagnostics note (2.0.1 round 7): the automatic retry after re-installing a profile was skipped because another VPN connection became active"))
        restoreIfIdle()
    }

    private var isAutomatic: (UUID) -> Bool { { [weak self] id in self?.pending[id]?.automatic == true } }

    private func runStart(_ id: UUID, _ token: UInt64) async {
        // Review R7: the timeout, a failure or a newer start ends this entry; nothing after an await may start it.
        @MainActor func gone() -> Bool { pending[id]?.token != token }
        // Never start a manager whose kill-switch flags or revision lag the profile (review H1), and never one
        // whose verified flags still lack the kill switch (E2E-1, fail closed).
        var endpoints: [String: [String]] = [:]
        if let p = profiles.profile(id) {
            do throws(LPError) {
                try await profiles.prepareForStart(p, admissible: startMutationAllowed(id, token))
                configurationDenied = false
            } catch {
                guard !gone() else { restoreIfIdle(); return }
                // 2.0.2 (Codex r9 MEDIUM): a background retry whose save was refused because another session became busy.
                if isAutomatic(id), othersBusy(except: id) { abandonAutomaticRetry(id); return }
                configurationDenied = NEManagerStore.isConfigurationDenied(error)
                fail(id, namingTheBlocker(error, id))
                return
            }
            guard !gone() else { restoreIfIdle(); return }
            // S2 E10: resolved here, before the start, while no tunnel of ours is up.
            endpoints = await resolveEndpoints(p.summary.resolvableEndpoints)     // remotes + http-proxy (PF 51)
            guard !gone() else { restoreIfIdle(); return }
        }
        // Round 8 (Fable N3): a background retry checks for another session before it pauses anyone's on-demand.
        if isAutomatic(id), othersBusy(except: id) { abandonAutomaticRetry(id); return }
        do throws(PauseFailure) { try await pauseOtherOnDemand(except: id, token: token) } catch {
            guard !gone() else { restoreIfIdle(); return }
            await failPause(id, token, error)
            return
        }
        guard !gone() else { restoreIfIdle(); return }
        await restoreOwnOnDemand(id, token)
        // E2E-3 (200003, review F5): the start waits until the last configuration change, whoever made it, is
        // `settleBeforeStart` old. Review R8: bounded; a configuration that never settles is no start (fail closed).
        let settled = await managers.waitUntilSettled(profiles.settleBeforeStart)
        guard !gone() else { restoreIfIdle(); return }
        guard settled else {
            log.error("configuration of \(id.uuidString.prefix(8), privacy: .public) never settled; start refused")
            profiles.note(String(localized: "The VPN configuration of \(profiles.profile(id)?.name ?? "") kept changing; not connecting. Try again in a moment.", comment: "Problem: a start was refused because configuration changes never stopped (E2E-3)"))
            fail(id, LPError(.killSwitchNotApplied, detail: "configuration not settled"))
            return
        }
        // Review F6: NE's own on-demand start of another profile may have landed meanwhile (the pause then turned
        // it off while it connects): this is a switch, not a start beside it.
        if let active = statuses.first(where: { $0.value.isActive && $0.key != id })?.key {
            // Round 7 (Codex M1): a background retry never stops another session (that would bypass the extension's
            // first-wins rule with a stop the app makes): it ends here, said in Diagnostics.
            if isAutomatic(id) { abandonAutomaticRetry(id); return }
            beginSwitch(to: id, stopping: active)           // replaces this entry
            return
        }
        // E2E-4 200011: the network went away during the prepare or the settle: still no `startVPNTunnel` without one.
        // The entry waits (not busy), so what this start paused comes back meanwhile; the start pauses again later.
        if networkAvailable == false {
            waitForNetwork(id)
            return
        }
        // 2.0.2 (PLAN-2.0.2 §3, D-1): the extension honours a manual start only with this owner's `armStart`, so the arm
        // comes last, right before `startVPNTunnel` (it lapses after 15 s). A failed arm is a failed start, never a start
        // without one (except for an extension that predates start authorisation, `StartArming.Outcome.legacyExtension`).
        let nonce: UUID?
        switch await StartArming.arm(id, service: service) {
        case .armed(let n): nonce = n; lastArmedAt[id] = now()
        case .legacyExtension:
            // Round 1 (Fable L4): the old extension is still running while its replacement (which authorises starts)
            // waits for approval. A kill-switch session started now carries no nonce; if NE restarts it into the new
            // extension, that restart is refused (225) and a failed includeAllNetworks start is open. Not started; the
            // copy says the tunnel component is being updated. Round 2 (L6): whatever settings.json says about an update
            // (its marker isn't authenticated and needn't span the whole hand-over): a 2.0.2 app never starts a kill-switch
            // session on an extension that can't authorise its restart.
            if StartArming.refusesKillSwitchStart(onLegacyExtension: managerKillSwitch(id)) {
                log.notice("kill-switch start of \(id.uuidString.prefix(8), privacy: .public) waits for the extension update")
                fail(id, LPError(.versionMismatch, detail: "kill-switch start waits for the tunnel component update"))
                return
            }
            nonce = nil
        case .failed(let e):
            guard !gone() else { restoreIfIdle(); return }
            log.error("armStart for \(id.uuidString.prefix(8), privacy: .public) failed: \(e.code.rawValue, privacy: .public)")
            fail(id, e)
            return
        }
        guard !gone() else { restoreIfIdle(); return }
        // The network may have gone during the arm: still no `startVPNTunnel` without one (the wait arms again).
        if networkAvailable == false {
            waitForNetwork(id)
            return
        }
        pending[id]?.phase = .starting(issued: true)
        sessionKillSwitch[id] = managerKillSwitch(id)          // as `prepareForStart` just verified it (N6)
        newIssuedAttempt(id)
        do throws(LPError) {
            try managers.start(id, options: StartOptionsBuilder.options(endpoints: endpoints, nonce: nonce))
            startFailure = nil
        } catch {
            fail(id, error)
        }
    }

    /// E2E-3: while another of our configurations has on-demand enabled, a network change leaves nesessionmanager
    /// (26.6.2) without the primary interface once it comes back ("(null) => en0" only after the session ends): the
    /// starting or connected kill-switch session's pass policies are never re-added and NECP marks every new socket of
    /// the tunnel process defunct, so it sends nothing until the user disconnects. So a start of any profile turns
    /// on-demand off on every OTHER configuration of this user first. Each ID is recorded (settings, written through)
    /// BEFORE its pause: `restoreIfIdle` restores exactly those when nothing else is active or starting ("Auto-connect
    /// resumes when you disconnect …", §10.4). Another user's configuration is not ours to change (review F7): its
    /// on-demand can still trigger the bug (fail-closed, not a leak; DESIGN §10.4 residual).
    /// A failed pause throws (review F3): the start must not run beside an enabled on-demand configuration.
    struct PauseFailure: Error { var profileID: UUID; var error: LPError }

    /// `token`: the start's attempt (2.0.2, Codex r9 MEDIUM): each pause re-checks `startMutationAllowed` inside the
    /// serialization, after every await before it (the restore, the record write, a queued mutation).
    @discardableResult
    private func pauseOtherOnDemand(except id: UUID, token: UInt64) async throws(PauseFailure) -> [UUID] {
        let allowed = startMutationAllowed(id, token)
        await restoreTask?.value                       // never overlap a restore's save (it would re-enable what we pause)
        var paused: [UUID] = []
        for m in managers.managers where m.profileID != id && m.onDemandEnabled && m.stored?.ownerUID == profiles.ownerUID {
            log.notice("on-demand of \(m.profileID.uuidString.prefix(8), privacy: .public) paused while \(id.uuidString.prefix(8), privacy: .public) starts")
            await addToPauseRecord([m.profileID])
            do throws(LPError) {
                // Round 7 (Fable L3): never inside another configuration's pending start (the one predicate).
                // This user's own profiles are excluded: a pending start of one of them is switched out by this start.
                guard try await managers.setOnDemandEnabled(false, for: m.profileID, onlyIf: { [weak self] in
                    allowed() && !(self?.foreignStartPending(except: id) ?? true)
                }) else {
                    throw LPError(.anotherTunnelActive, detail: "another configuration is starting")
                }
            } catch {
                log.error("couldn't pause on-demand of \(m.profileID.uuidString.prefix(8), privacy: .public) before a start: \(error.code.rawValue, privacy: .public)")
                throw PauseFailure(profileID: m.profileID, error: error)
            }
            paused.append(m.profileID)
        }
        return paused
    }

    /// Review F3: a pause that failed is a start failure, said in plain words; what was paused already comes back.
    /// `token`: the entry that paused; one that ended meanwhile (review 4 #7) is not failed again.
    private func failPause(_ id: UUID, _ token: UInt64, _ failure: PauseFailure) async {
        // Nit: a pause that failed left the manager ON; the record promised nothing then ("resumes when you disconnect").
        if managers.managers.first(where: { $0.profileID == failure.profileID })?.onDemandEnabled == true {
            await dropFromPauseRecord(failure.profileID)
        }
        // 2.0.2 (Codex r9 MEDIUM): a background retry's pause refused because another session became busy: the retry
        // ends as any other that finds a session busy (no "couldn't be paused" problem: nothing failed).
        if pending[id]?.token == token, isAutomatic(id), othersBusy(except: id) { abandonAutomaticRetry(id); return }
        let name = profiles.profile(failure.profileID)?.name ?? ""
        profiles.note(String(localized: "Auto-connect of \(name) couldn't be paused; not connecting.", comment: "Problem: a start was refused because on-demand of another profile couldn't be turned off (E2E-3)"))
        if pending[id]?.token == token { fail(id, namingTheBlocker(failure.error, id)) } else { restoreIfIdle() }
    }

    /// `id` is starting itself and its own on-demand was paused earlier (it is the auto profile and another profile ran
    /// before it): its own on-demand belongs to its own start (only OTHER configurations block a kill-switch session).
    ///
    /// Round 7 (Codex M4, Fable L3): only for this attempt (`token`), while its own session hasn't begun (a start made
    /// elsewhere of the same profile), and not inside another configuration's pending start (`otherStartPending`; a
    /// merely connected one doesn't block it). Skipped: the record stays, restored at idle.
    private func restoreOwnOnDemand(_ id: UUID, _ token: UInt64) async {
        guard settings.value.onDemandPausedByStart.contains(id) else { return }
        await restore(id, unlessBusy: { [weak self] in
            guard let self else { return true }
            return self.pending[id]?.token != token || self.managers.status(id).isLive || self.otherStartPending(except: id)
                || (self.isAutomatic(id) && self.othersBusy(except: id))          // 2.0.2 (Codex r9 MEDIUM)
        })
    }

    /// 2.0.2 (Codex r9 MEDIUM): the condition every configuration mutation of a start re-checks INSIDE the manager
    /// serialization (its `prepareForStart` saves, its pause of the others' on-demand), after any wait for an earlier
    /// mutation: the attempt (`token`) is still the current one, and an automatic retry still finds nothing else busy.
    /// A background retry never changes a manager during another start or session (a configuration change inside a
    /// `.connecting` kill-switch session leaves it passing no traffic, E2E-4 U2/U13); it only abandoned it afterwards.
    private func startMutationAllowed(_ id: UUID, _ token: UInt64) -> @MainActor () -> Bool {
        { [weak self] in
            guard let self, self.pending[id]?.token == token else { return false }
            return !(self.isAutomatic(id) && self.othersBusy(except: id))
        }
    }

    /// Round 7 (Fable L3): the one predicate for "a configuration mutation of a start must not land inside another
    /// pending start": another configuration (ours, any user's, a stray) is starting (`.connecting`), or another of our
    /// entries is under way (not a wait for a network). A connected (or reasserting) other session doesn't count: our
    /// start's own saves beside it are what any switch does (S2 E9), and the extension decides the start itself.
    /// Round 8 (Fable N1): the form a start's own saves use (`prepareForStart`, the pause): this user's own profiles are
    /// excluded (their pending start is switched out by this start).
    func foreignStartPending(except id: UUID) -> Bool {
        let ours = Set(managers.managers.filter { $0.stored?.ownerUID == profiles.ownerUID }.map(\.profileID))
        return otherStartPending(except: id, besides: ours)
    }

    /// `besides`: configurations this start replaces anyway (the one whose on-demand it pauses before switching it out).
    func otherStartPending(except id: UUID, besides: Set<UUID> = []) -> Bool {
        let skip = besides.union([id])
        return pending.contains { !skip.contains($0.key) && !$0.value.isWaitingForNetwork }
            || statuses.contains { !skip.contains($0.key) && $0.value == .connecting }
            || managers.managers.contains { !skip.contains($0.profileID) && $0.status == .connecting }
            || managers.strays.contains { $0.status == .connecting }
    }

    /// The single predicate for "another profile is starting, active, switching in, or about to be restarted by NE":
    /// it holds `id`'s on-demand back (`ProfilesStore.onDemandPlan`), and while it lasts nothing is restored. `nil`:
    /// any profile at all (`isBusy`).
    /// E2E-4 (200008, restore at `.disconnecting`): a session counts until it has ENDED (`isLive`: every status but
    /// `.disconnected`/`.invalid`), `.disconnecting` included. A crashed kill-switch session's `.disconnecting` comes
    /// ~1.4 s before `.disconnected` and NE's own restart follows; the restore saved the auto profile's on-demand
    /// 12 ms after it (6/6). Only a handled `.disconnected` (its entry: the crash decision, or a user stop) ends it.
    /// E2E-4 200011: a start waiting for a network is not busy: nothing was paused or issued for it, and NE starts nothing
    /// for it (its own wait is `startHold`). NE's coming restart after "No network available" is.
    private func othersBusy(except id: UUID?) -> Bool {
        pending.contains { $0.key != id && !$0.value.isWaitingForNetwork }
            || statuses.contains { $0.key != id && $0.value.isLive }
            // Review R4: the live manager statuses too, so launch order (`profiles.load()` before `start()`) and a
            // session started elsewhere (System Settings, the headless agent) count from the first moment.
            || managers.managers.contains { $0.profileID != id && $0.status.isLive }
            // E2E-4 (U2/U13): ANY configuration's live session counts, another user's and an unaddressable one's
            // included: a configuration change inside it (a save, a removal) breaks it like ours.
            || managers.strays.contains { $0.status.isLive }
    }

    /// E2E-3: another profile is starting or active, so `id`'s on-demand must stay off (`ProfilesStore.onDemandPlan`).
    func holdsBackOnDemand(of id: UUID) -> Bool { othersBusy(except: id) }

    /// Anything is starting, active, switching or about to restart.
    var isBusy: Bool { othersBusy(except: nil) }

    /// Round 2 (L2): `isBusy` at the last `restoreIfIdle` (the idle transition sends a revoke).
    @ObservationIgnored private var wasBusy = false

    /// Round 2 (Fable L1): profiles whose unattended record the extension must keep although they may have no plan: any
    /// pending entry (starting, a crash or network-restart hold, NE's restart awaited), the recorded network-restart
    /// hold, and every live session.
    func revocationHeld() -> Set<UUID> {
        // Round 3 (Codex r3 #4): the in-memory hold only (a pending entry): the record in settings.json is unauthenticated.
        var ids = Set(pending.keys)
        for (id, st) in statuses where st.isLive { ids.insert(id) }
        return ids
    }

    /// What makes `isBusy` true, for copy (E2E-4 review L1): one of this user's profiles (a pending entry first, then an
    /// active session), another user's VPN connection, or a configuration of ours that no profile can address. The
    /// last two can last indefinitely and hold everything non-essential back (U2/U13), so they are said, not hidden.
    enum BusyReason: Equatable {
        case profile(UUID)
        case anotherUser
        case unaddressable

        /// The Auto-Connect pane's line and the Diagnostics note; nil for one of this user's profiles.
        var explanation: String? {
            switch self {
            case .profile: nil
            case .anotherUser:
                String(localized: "Another user's VPN connection is active. LockPlus makes no VPN configuration changes, auto-connect included, until it ends.",
                       comment: "Auto-connect status and Diagnostics note: another user's VPN connection holds every configuration change back (E2E-4 review L1)")
            case .unaddressable:
                String(localized: "A VPN configuration LockPlus can't address is active. LockPlus makes no VPN configuration changes, auto-connect included, until it ends.",
                       comment: "Auto-connect status and Diagnostics note: a configuration without a usable profile ID is active (E2E-4 review L1)")
            }
        }
    }

    var busyReason: BusyReason? {
        if let id = pending.first(where: { !$0.value.isWaitingForNetwork })?.key { return .profile(id) }
        if let id = statuses.first(where: { $0.value.isLive })?.key ?? managers.managers.first(where: { $0.status.isLive })?.profileID {
            if profiles.profile(id) != nil { return .profile(id) }
            let owner = managers.managers.first { $0.profileID == id }?.stored?.ownerUID
            return owner.map { $0 != profiles.ownerUID } == true ? .anotherUser : .unaddressable
        }
        if let s = managers.strays.first(where: { $0.status.isLive }) {
            return s.ownerUID.map { $0 != profiles.ownerUID } == true ? .anotherUser : .unaddressable
        }
        return nil
    }

    /// The profile that makes `isBusy` true, when it is one of ours.
    var busyProfile: UUID? {
        if case .profile(let id) = busyReason { return id }
        return nil
    }

    /// Diagnostics: a foreign busy reason (L1) is noted once per appearance, so "why does nothing change" has an answer.
    @ObservationIgnored private var notedForeignBusy: BusyReason?
    private func noteForeignBusy() {
        guard let r = busyReason, let line = r.explanation else { notedForeignBusy = nil; return }
        guard notedForeignBusy != r else { return }
        notedForeignBusy = r
        profiles.note(line)
    }

    /// `ProfilesStore`'s one deferral question (review F5/R3): a mutation of `id`'s manager waits while anything is
    /// busy (any configuration's live session included, E2E-4). Except the CONNECTED profile's own manager while nothing
    /// else is (S2 E9: on-demand, rule and name saves of a connected manager are safe; E2E-4 U7: so is the protective
    /// flag heal, which NE applies at once); never a manager inside its own pending start (`.connecting`, NE's restart,
    /// a System Settings start). `ProfilesStore` changes a live manager's flags only in the protective direction.
    func mutationBlocked(_ id: UUID) -> Bool {
        isBusy && !(managers.status(id) == .connected && !othersBusy(except: id))
    }

    /// The profile whose start or session holds the auto profile's on-demand back, when the pause is real: recorded,
    /// or about to happen in this instance's own start window (review F10b/c). Not for a session started elsewhere
    /// (System Settings), where nothing was paused.
    func holder(of auto: UUID) -> UUID? {
        guard othersBusy(except: auto) else { return nil }
        // Or switching in, or NE's restart after "No network available"; never a start waiting for a network (it paused nothing).
        let starting = pending.first { $0.key != auto && $0.value.phase != .awaitingRestart && !$0.value.isWaitingForNetwork }?.key
        let recorded = settings.value.onDemandPausedByStart.contains(auto)
        // Review b47da1c L-8c: NE's restart after "No network available" pauses nothing that isn't recorded already.
        let aboutTo = starting.map { pending[$0]?.phase != .awaitingNetworkRestart } == true
            && managers.managers.first { $0.profileID == auto }?.onDemandEnabled == true
        guard recorded || aboutTo else { return nil }
        return starting ?? statuses.first { $0.key != auto && $0.value.isLive }?.key
    }

    /// Review F4: the profile's on-demand should be on (its plan, nothing holds it back) but the manager says off: a
    /// restore failed and waits for its retry. The Auto-Connect pane says so.
    func onDemandNeedsRestore(_ p: Profile) -> Bool { !isBusy && !restoring && wantsRestore(p) }

    /// The one "needs restore" predicate (review R2): the plan wants on-demand (nothing holds it back), the manager
    /// exists and says off. The restore, the pane and the `handle()` retry all read it.
    private func wantsRestore(_ p: Profile) -> Bool {
        guard let plan = profiles.onDemandPlan(for: p), plan.enabled,
              let m = managers.managers.first(where: { $0.profileID == p.id }) else { return false }
        return !m.onDemandEnabled
    }

    // MARK: Pending (the state machine at the top)

    struct Pending {
        enum Phase: Equatable {
            case starting(issued: Bool), awaitingRestart
            /// Starts once `old` has reported `.disconnected` (a switch, or a Connect while `old` itself still stops).
            case waitingForStop(of: UUID)
            /// E2E-4 200011: no usable interface at the start. Nothing is issued (NE would refuse it with "No network
            /// available" and restart it by itself later, beside whatever was restored); nothing is paused, and the entry
            /// is not busy. The start (prepare, pause, settle) runs when an interface returns. No timer.
            case waitingForNetwork
            /// E2E-4 200011: a kill-switch session without on-demand rules ended with `noNetworkAvailable` (code 2) and
            /// no stop of ours: NE restarts it by itself when an interface returns. Busy (nothing is restored); no timer
            /// while there is no network, `systemRestartTimeout` once there is (`fallbackArmed`). Persisted
            /// (`AppSettings.networkRestartHold`).
            case awaitingNetworkRestart
        }
        var phase: Phase
        let token: UInt64
        let timer: Task<Void, Never>
        /// `.awaitingRestart` after the crash decision (a restart is really awaited), not the fetch phase that reads why
        /// the session ended (`startHold` tells them apart).
        var expectsRestart = false
        /// Review e321e10 LOW 1: the restart is only possible (a `pluginFailed` with no interruption seen, U10), not a
        /// seen crash: the UI hedges and offers Cancel (`disconnect` ends it).
        var mayRestart = false
        /// Review 5c3a899/f18c0d6 L-3 copy: with `mayRestart`, the hold is for our own issued start that ended before any
        /// active status (not a stop of a running session): the UI says "the start ended early", never "stopped unexpectedly".
        var startEndedEarly = false
        /// `.awaitingNetworkRestart`: the network is back and the fallback timer runs.
        var fallbackArmed = false
        /// `.awaitingRestart` armed at a `.disconnecting` (`holdTeardown`), before its end is read.
        var teardown = false
        /// Round 8 (Codex M2, Fable L3): a background retry (`startNow(_:automatic:)`), carried through every phase of
        /// this attempt (a wait for a network included): it never switches away from or stops another session.
        var automatic = false
        var isStarting: Bool { if case .starting = phase { true } else { false } }
        var isWaitingForStop: Bool { if case .waitingForStop = phase { true } else { false } }
        /// A Connect the store took but did not start yet, for want of a network: holds nothing back (`othersBusy`).
        var isWaitingForNetwork: Bool { phase == .waitingForNetwork }
        /// The start of this entry is not ours to watch yet: nothing was issued (a stop or a network is awaited).
        var isUnissuedWait: Bool { isWaitingForStop || isWaitingForNetwork }
    }

    /// The start waiting for `old`'s `.disconnected`.
    private func waiter(for old: UUID) -> UUID? { pending.first { $0.value.phase == .waitingForStop(of: old) }?.key }

    /// The target of a switch (or reconnect) that waits for a stop.
    private var switchTarget: UUID? { pending.first { $0.value.isWaitingForStop }?.key }

    /// Enters `phase` for `id` (replacing its entry) with the one timer (default `startingTimeout`). When it fires, a
    /// start waiting for a stop starts anyway (NE's Stopping budget is over); any other entry ends and the restore runs
    /// (review F9: NE silently dropped the start, S2; R1: NE's own restart after a crash never came).
    /// `untimed`: no timer at all (E2E-4 200011: a wait for the network, which has no time limit).
    @discardableResult
    private func arm(_ id: UUID, _ phase: Pending.Phase, timeout: Duration? = nil, untimed: Bool = false, expectsRestart: Bool = false,
                     mayRestart: Bool = false, startEndedEarly: Bool = false, fallbackArmed: Bool = false,
                     teardown: Bool = false) -> UInt64 {
        let automatic = pending[id]?.automatic ?? false     // round 8: the same attempt keeps its origin
        pending[id]?.timer.cancel()
        lastToken &+= 1
        let token = lastToken, timeout = timeout ?? startingTimeout, sleep = timerSleep
        let timer = untimed ? Task {} : Task { @MainActor [weak self] in
            await sleep(timeout)
            guard !Task.isCancelled, let self, let entry = self.pending[id], entry.token == token else { return }
            if entry.isWaitingForStop {
                self.log.error("\(id.uuidString.prefix(8), privacy: .public): the old session never reported .disconnected; starting anyway")
                self.startNow(id)
                return
            }
            let what = entry.isStarting ? "no status after the start"
                : entry.phase == .awaitingNetworkRestart ? "NE's own restart after the network returned never came"
                : entry.expectsRestart ? "NE's own restart after the crash never came" : "the end of the session was never read"
            self.log.error("\(id.uuidString.prefix(8), privacy: .public): \(what, privacy: .public); not waiting for it")
            self.clearPending(id)
            self.restoreIfIdle()
        }
        pending[id] = Pending(phase: phase, token: token, timer: timer, expectsRestart: expectsRestart, mayRestart: mayRestart,
                             startEndedEarly: startEndedEarly, fallbackArmed: fallbackArmed, teardown: teardown,
                             automatic: automatic)
        return token
    }

    /// Why a Connect would be ignored now (review 5 §3): the UI disables Connect and says so. One start at a time, so
    /// at most one entry is a start or a wait; an `.awaitingRestart` beside it is reported only without one.
    struct StartHold: Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            /// `.starting`: prepare, pause, settle, or issued with no status yet.
            case preparing
            /// `.waitingForStop(of:)`: a switch, or a Connect of a profile that was still stopping (N1b).
            case waitingForStop(of: UUID)
            /// A fresh crash: NE's own restart or ours is awaited (≤ `startingTimeout`).
            case awaitingRestart
            /// Review e321e10 LOW 1: a `pluginFailed` with no interruption seen on a kill-switch session without rules
            /// (U10): NE may restart it (≤ `systemRestartTimeout`). Hedged copy; Cancel ends the wait.
            case mayRestart
            /// Review 5c3a899/f18c0d6 L-3 copy: our own issued start ended before any active status (no crash recorded);
            /// NE may still restart it. Hedged copy of its own; Cancel ends the wait.
            case startEndedEarly
            /// The fetch phase of an observed disconnect (≤ `disconnectErrorTimeout`): only another profile's Connect
            /// is ignored; the hero shows no row for it.
            case readingDisconnect
            /// E2E-4 200011: `.waitingForNetwork`: the Connect waits for an interface ("Waiting for a network to connect
            /// X…"); Cancel ends it. Every other Connect is held like any start.
            case waitingForNetwork
            /// E2E-4 200011: `.awaitingNetworkRestart`: NE connects X by itself when a network is available; Cancel stops
            /// it. Only X's own Connect is held: another profile's Connect stops X first, then proceeds.
            case awaitingNetwork
        }
        var profile: UUID
        var reason: Reason
    }

    var startHold: StartHold? {
        // Review f0c8c57 #1: deterministic and consistent with the hero: the current profile's own hold first (unless it
        // is only reading why its session ended), then the oldest entry (dictionary order is not stable).
        let ordered = pending.sorted { $0.value.token < $1.value.token }
        func reading(_ e: Pending) -> Bool { e.phase == .awaitingRestart && !e.expectsRestart }
        let current = currentID.flatMap { id in pending[id].map { (key: id, value: $0) } }.flatMap { reading($0.value) ? nil : $0 }
        if let current, current.value.phase == .awaitingRestart { return restartHold(current.key, current.value) }
        if let start = current ?? ordered.first(where: { $0.value.phase != .awaitingRestart }) {
            let reason: StartHold.Reason = switch start.value.phase {
            case .waitingForStop(let old): .waitingForStop(of: old)
            case .waitingForNetwork: .waitingForNetwork
            case .awaitingNetworkRestart: .awaitingNetwork
            case .starting, .awaitingRestart: .preparing
            }
            return StartHold(profile: start.key, reason: reason)
        }
        guard let restart = ordered.first else { return nil }
        return restartHold(restart.key, restart.value)
    }

    private func restartHold(_ id: UUID, _ e: Pending) -> StartHold {
        StartHold(profile: id, reason: e.startEndedEarly ? .startEndedEarly : e.mayRestart ? .mayRestart : e.expectsRestart ? .awaitingRestart : .readingDisconnect)
    }

    /// The hold that makes a Connect of `id` unavailable in the UI, if any. The UI is stricter than `connect` in one
    /// case: a Connect over the profile's own awaited crash restart is accepted by the store (a newer entry) but not
    /// offered, because its prepare and pause would save managers inside NE's pending restart (E2E-3).
    /// Review e321e10 LOW 2: also the teardown or fetch phase of a session NE may restart itself (kill switch, no
    /// on-demand rules): until the cause is read, its own Connect would run inside NE's restart window too.
    /// E2E-4 200011: NE's coming restart after "No network available" holds only that profile's own Connect (a Connect
    /// of another profile stops it first, `connect`).
    func connectHold(for id: UUID) -> StartHold? {
        guard let h = startHold else { return nil }
        if h.reason == .readingDisconnect && h.profile == id && !mayBeRestartedByNE(id) { return nil }
        if h.reason == .awaitingNetwork && h.profile != id && pending.count == 1 { return nil }   // review b47da1c L-8b: as `connect`
        return h
    }

    /// A kill-switch session (as started, N6) whose manager has no on-demand rules enabled: NE restarts it itself after
    /// a crash (S2 E1).
    private func mayBeRestartedByNE(_ id: UUID) -> Bool {
        (sessionKillSwitch[id] ?? managerKillSwitch(id)) && managers.managers.first { $0.profileID == id }?.onDemandEnabled != true
    }

    /// Review 5 #1: the user's Disconnect, Cancel or Pause ends a start that hasn't been issued yet and a start that
    /// waits for a stop (its Task's `gone()` checks stop it; whatever it paused comes back at idle). An issued start is
    /// left to its status (`stop` ends that session).
    /// E2E-4 200011: a start waiting for a network is such a start too.
    private func cancelPendingStarts() {
        for (k, e) in pending where e.isUnissuedWait || e.phase == .starting(issued: false) { clearPending(k) }
        switchingTo = nil
    }

    /// Review N7: a removed manager reports no status, so NE's restart of it can't come: its `.awaitingRestart` ends now
    /// (on any status event and on `NEVPNConfigurationChange`), not after the 30 s fallback. Review e321e10 (HIGH): its
    /// last status goes too (a `.disconnecting` whose `.disconnected` NE never delivered kept everything busy until
    /// relaunch), with the session bookkeeping, a start waiting for its stop (starts now) and a `stopAndWait`. True if
    /// anything ended.
    @discardableResult
    private func dropVanished() -> Bool {
        let known = Set(managers.managers.map(\.profileID))
        // Review 385b6ea L-A: a LIVE session (a live status or a watched session) whose manager is missing from the
        // snapshot is not ended here: `SerializedVPNManager` reports `.invalid` for it once two consecutive loads agree
        // (or at once for our own removal), and `handle` ends it then. One partial reload must not end a kill-switch
        // session's bookkeeping and let the restore save inside it.
        func live(_ id: UUID) -> Bool { sawActive.contains(id) || statuses[id]?.isLive == true }
        // Review b061b46-d4feb3a LOW-3: an issued start whose manager is gone (a Delete between `managers.start` and its
        // first status) can never report; its entry ends now, not at `startingTimeout`.
        // E2E-4 200011: NE can't restart a removed configuration after "No network available" either.
        let restarts = pending.filter { [.awaitingRestart, .awaitingNetworkRestart, .starting(issued: true)].contains($0.value.phase)
                                        && !known.contains($0.key) && !live($0.key) }.map(\.key)
        for id in restarts { clearPending(id) }
        let stale = Set(statuses.keys).subtracting(known).filter { !live($0) }
        // Review 385b6ea L-C: one end path.
        for id in stale.union(restarts) { sessionEnded(id) }
        return !restarts.isEmpty || !stale.isEmpty
    }

    private func isKnown(_ id: UUID) -> Bool { managers.managers.contains { $0.profileID == id } }

    /// `NEVPNConfigurationChange` (AppEnvironment): a configuration may have been removed (N7).
    func configurationChanged() {
        noteForeignBusy()
        if dropVanished() { restoreIfIdle() }
        noteStrayDuplicates()                 // also forgets the strays the reload dropped
    }

    /// Ends `id`'s entry; with `token`, only that entry (a newer one stays). A network-restart hold takes its record along.
    private func clearPending(_ id: UUID, token: UInt64? = nil) {
        guard let entry = pending[id], token == nil || entry.token == token else { return }
        entry.timer.cancel()
        pending[id] = nil
        if entry.phase == .awaitingNetworkRestart { forgetNetworkRestartRecord(id) }
        // Review aad7527 #2: a start that waits for a network and found another entry in the way tries again now.
        if !entry.isWaitingForNetwork, pending.values.contains(where: \.isWaitingForNetwork) { applyNetworkToHolds() }
    }

    // MARK: Restore (E2E-3)

    private func addToPauseRecord(_ ids: [UUID]) async {
        // On disk before the pause it describes: a crash still knows (review R11/N4: through the ordered queue).
        await settings.updateDurably { for id in ids where !$0.onDemandPausedByStart.contains(id) { $0.onDemandPausedByStart.append(id) } }
    }

    private func dropFromPauseRecord(_ id: UUID) async {
        guard settings.value.onDemandPausedByStart.contains(id) else { return }
        await settings.updateDurably { $0.onDemandPausedByStart.removeAll { $0 == id } }
    }

    /// The one restore of what a start paused: called from every place a profile's run can end or a start can fail
    /// (an observed disconnect, `fail`, a pending entry's timer, the crash grace), at launch, at the end of a suspension
    /// and on every status event (the retry of a failed restore). Nothing to do: no restore task (`restoring` is
    /// observed, and this runs per status event).
    private func restoreIfIdle() {
        noteForeignBusy()
        healLiveDrift()
        // Round 2 (Fable L2): each time everything has settled (no start, session, hold or NE restart awaited), the
        // unattended records of profiles without a plan go: a user stop, a settled disconnect, a hold that ended.
        let busyNow = isBusy
        if !busyNow, wasBusy { Task { await profiles.revokeUnattended() } }
        wasBusy = busyNow
        // Review N3/N5: only when nothing at all is starting, active, switching or awaiting a restart: a profile that is
        // itself active is never restored (a save inside its own pending start), and while busy nothing flips
        // `restoring`. Review N2: during an extension update every plan is held; `resumeAfterUpdate` hands it back.
        guard !isBusy, !settings.value.extensionHandOver else { return }
        guard restoreTask == nil else { restoreAgain = true; return }
        var ids = restorable()
        guard !ids.isEmpty || profiles.hasDeferredSync else { return }
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.restoreAgain = false
                for id in ids {
                    guard !self.isBusy else { break }           // a start began: the rest stays recorded
                    await self.restore(id, unlessBusy: { [weak self] in self?.isBusy ?? true })
                }
                // Review F5/R3: what `ProfilesStore.load`/`resaveOnDemand` deferred while busy runs now, before
                // `restoreTask` ends, so a start's `pauseOtherOnDemand` waits for it (review R10).
                if self.profiles.hasDeferredSync, !self.isBusy { await self.profiles.runDeferredSync() }
                ids = self.restorable()
            } while self.restoreAgain
            self.restoreTask = nil
        }
    }

    /// E2E-4 (U7): a drift that weakened a connected profile's flags while it was connecting, or while another start
    /// held mutations back, is restored at the next status event or end of an entry (`restoreIfIdle` runs at all of
    /// them). Only with a deferred sync pending (every path that skips a drift sets it); `healProtectiveDrift` decides
    /// when it is allowed.
    private func healLiveDrift() {
        guard profiles.hasDeferredSync else { return }
        for m in managers.managers where m.status == .connected && statuses[m.profileID] == .connected {
            let id = m.profileID
            Task { @MainActor [profiles] in await profiles.healProtectiveDrift(id) }
        }
    }

    /// Review R2: what a start paused (the record) plus every profile whose plan wants on-demand while its manager is
    /// off (Auto-Connect turned on or re-pointed during a session, a failed restore), computed once per pass.
    private func restorable() -> [UUID] {
        var ids = settings.value.onDemandPausedByStart
        for p in profiles.profiles where !ids.contains(p.id) && wantsRestore(p) { ids.append(p.id) }
        return ids
    }

    /// Saves `id` with its on-demand plan. Success (or a plan that no longer wants it: suspended, off, deleted) clears
    /// it from the record; a failure is noted, and retried at the next status event (the record, or `wantsRestore`).
    /// Round 6 (Codex M1): `busy` is the caller's recovery predicate, re-checked inside the serialization.
    private func restore(_ id: UUID, unlessBusy busy: @escaping @MainActor () -> Bool) async {
        guard let p = profiles.profile(id), managers.managers.contains(where: { $0.profileID == id }),
              profiles.onDemandPlan(for: p)?.enabled == true else {
            await dropFromPauseRecord(id)
            return
        }
        do throws(LPError) {
            // Round 6 (Codex M1): "nothing is busy" again inside the serialization (a start elsewhere may begin while
            // this save waits for an earlier mutation). Skipped: the record stays, retried at the next status event.
            let saved = try await profiles.saveOnDemand(p, onlyIf: { !busy() })
            guard saved else {
                log.notice("on-demand restore of \(id.uuidString.prefix(8), privacy: .public) skipped: a start began meanwhile")
                return
            }
            await dropFromPauseRecord(id)
        } catch {
            log.error("couldn't turn on-demand of \(id.uuidString.prefix(8), privacy: .public) back on: \(error.code.rawValue, privacy: .public)")
            profiles.note(String(localized: "Auto-connect of \(p.name) couldn't be turned back on (\(error.code)); LockPlus will try again.", comment: "Problem: restoring a paused auto-connect failed (E2E-3)"))
        }
    }

    /// Round 8 (Fable L2): the app's own `.anotherTunnelActive` (a save skipped inside another configuration's pending
    /// start) names the blocker as the extension's refusal does: no other profile of this user active, so another
    /// user's connection or one LockPlus can't show.
    private func namingTheBlocker(_ e: LPError, _ id: UUID) -> LPError {
        guard e.code == .anotherTunnelActive, !visibleProfileActive(besides: id) else { return e }
        return LPError(.anotherTunnelActive, detail: LPErrorCode.unseenSessionDetail)
    }

    private func fail(_ id: UUID, _ e: LPError) {
        clearPending(id)
        if switchingTo == id { switchingTo = nil }
        startFailure = e
        currentID = id
        observedError = ObservedError(code: e.code, origin: .failedStart)
        errorDetail = e.detail
        errorAt = now()
        userStoppedSinceError = true          // nothing was started, so nothing blocks
        restoreIfIdle()                       // review F2: whatever this start paused comes back
    }

    /// The user's Disconnect (and Cancel, Restore Internet): on-demand off first, or it would restart at once
    /// ("Paused until you join another network", §10.4); then `stopVPNTunnel()`.
    func disconnect() {
        guard let id = currentID else { return }
        restartedAfterCrash = nil
        crashes.forgetCrash(id)
        // Review f0c8c57 #1: another profile's Connect that waited for a network ends with this Cancel too: said.
        let droppedWaits = pending.filter { $0.key != id && $0.value.isWaitingForNetwork }.map(\.key)
        cancelPendingStarts()                 // review 5 #1: a pending start or a switch waiting: off
        for other in droppedWaits {
            let name = profiles.profile(other)?.name ?? ""
            profiles.note(String(localized: "LockPlus stopped waiting for a network to connect \(name). Connect \(name) again if you need it.",
                                 comment: "Problem: the user's Cancel or Disconnect also ended another profile's Connect that waited for a network (review f0c8c57)"))
        }
        if pending[id]?.mayRestart == true { clearPending(id) }    // review e321e10 LOW 1: Cancel ends a hedged wait (`startEndedEarly` implies it)
        if pending[id]?.phase == .awaitingNetworkRestart {
            // E2E-4 200011: Cancel of "X connects when a network is available": the stop is issued (it cancels NE's
            // restart) before the restore below. X's on-demand is off (no rules), so there is nothing to suspend.
            stopNetworkRestart(id)
        } else {
            stop(id)
        }
        restoreIfIdle()
    }

    /// The current network signature (NetworkWatcher), for "suspended until the next network change".
    private(set) var networkSignature: String?

    /// `suspending`: a user's Disconnect keeps on-demand off until the next network change. A stop that is part of a
    /// switch (`beginSwitch`) records nothing: the pause record brings the auto profile back (review F10a).
    private func stop(_ id: UUID, suspending: Bool = true) {
        userStops.insert(id)
        userStopsAt[id] = now()
        userStopSettled.remove(id)
        userStoppedSinceError = true
        Task { @MainActor in
            if suspending, managers.managers.first(where: { $0.profileID == id })?.onDemandEnabled == true {
                // §10.4: off until the next network change (recorded, so a later change or launch restores it).
                settings.update {
                    if !$0.onDemandSuspended.contains(id) { $0.onDemandSuspended.append(id) }
                    $0.onDemandSuspendedNetwork = networkSignature
                }
                do throws(LPError) { try await managers.setOnDemandEnabled(false, for: id) } catch {
                    // Stopping anyway would be undone by on-demand at once: say so instead of failing silently (H2).
                    profiles.note(String(localized: "Auto-connect couldn't be paused (\(error.code)); the tunnel may reconnect by itself.", comment: "Problem"))
                }
            }
            managers.stop(id)
            // A stop of a session that is already down reports nothing: a `stopAndWait` must not wait for it.
            if !managers.status(id).isLive { settleStopOfDownSession(id); resumeEndWaiters(id, ended: true) }
        }
    }

    /// NWPathMonitor (§10.4): a different network ends every "suspended until the next network change". The first
    /// call after launch compares with the network recorded at suspension, which covers a change while we weren't
    /// running.
    func networkChanged(_ signature: String) {
        let previous = networkSignature
        networkSignature = signature
        if let previous, previous != signature {
            // PF 50, E2E-3: push on ARRIVING at a network. A push while there is none (a Wi-Fi switch, a link bounce
            // longer than the settle) retried at once without an interface: WireGuard's new socket went into its own
            // tunnel (source = the tunnel address) and the attempt waited out its 45 s deadline.
            if Self.isArrival(signature) { pushFreshEndpointsIntoHeldStart() } else { endpointPushTask?.cancel() }
        }
        applyNetworkToHolds()                 // E2E-4 200011: every report, the first one after launch included
        let s = settings.value
        guard !s.onDemandSuspended.isEmpty,
              s.onDemandSuspendedNetwork.map(Self.networkIdentity) != Self.networkIdentity(signature) else { return }
        Task { await restoreOnDemand(s.onDemandSuspended) }
    }

    /// The part of a signature that names the network (E2E-3): the physical interfaces, de-duplicated, or "none".
    /// Our own kill-switch start turns the path `unsatisfied` and lists en0 twice; that is not a network change and
    /// must not end a suspension. Leaving a network (a Wi-Fi switch, a link bounce) passes through "none".
    nonisolated static func isArrival(_ signature: String) -> Bool { networkIdentity(signature) != "none" }

    nonisolated static func networkIdentity(_ signature: String) -> String {
        let ifs = signature.split(separator: "|", maxSplits: 1).dropFirst().first.map { Set($0.split(separator: ",").map(String.init)) } ?? []
        return ifs.isEmpty ? "none" : ifs.sorted().joined(separator: ",")
    }

    /// Ends the suspension for `ids`; their on-demand returns through the pause record (`returnOnDemand`).
    func restoreOnDemand(_ ids: [UUID]) async {
        await returnOnDemand(ids, thenConnect: nil) { $0.endOnDemandSuspension(ids) }
    }

    /// "Clear" for an error shown in the hero after the user acted on it.
    func clearError() {
        observedError = nil
        errorDetail = nil
        startFailure = nil
    }

    // MARK: Pause (§10.4)

    var pausedUntil: Date? {
        guard let u = settings.value.autoConnect.pausedUntil, u > now() else { return nil }
        return u
    }

    func pause(minutes: Int) async {
        // Round 5: the launch's spend of an earlier pause's value ends before this pause seals its own (never after it).
        // Round 6 (Codex r6 #3): no owed spend runs while this pause is made (each seal below replaces the value anyway).
        pauseInFlight += 1
        defer { pauseInFlight -= 1 }
        let spend = pauseValueSpend
        pauseValueSpend = nil
        spend?.cancel()
        await spend?.value
        let until = ResumeIntent.wholeSeconds(now().addingTimeInterval(Double(minutes) * 60))
        // E2E-4 200011: a session NE would restart when a network returns counts as the active one: the pause stops it
        // (cancelling that restart) and its end brings it back.
        // Round 3 (Codex r3 #4): a hold re-entered at launch whose record didn't verify (yet) is stopped like any other,
        // but never signed as the pause's target.
        let held = networkRestartHolder
        let active = signableLive ?? signableHold
        // What a start paused (the record) is part of what the pause restores at its end; the record is handed over.
        // Review N9: only this user's configurations (another user's is not ours to turn off, or to restore).
        var onDemand = managers.managers.filter { $0.onDemandEnabled && $0.stored?.ownerUID == profiles.ownerUID }.map(\.profileID)
        for id in settings.value.onDemandPausedByStart where !onDemand.contains(id) { onDemand.append(id) }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        // Pausing again while paused only extends the pause: the first pause's restore list stays (review M7).
        // Round 2 (Fable L5): the earlier record's profile is carried over only if its intent holds for the earlier end;
        // otherwise this pause signs only what it stops itself (a record other code wrote is never laundered).
        // Round 7 (Fable r7 N3): nothing is carried while a value is owed: the record whose value should have gone may
        // be a genuine one written back, and it would verify against the surviving value.
        var carried: UUID?
        if settings.value.pauseValueOwed, settings.value.pausedState?.profileID != nil {
            log.fault("pause extended while an earlier pause's value is owed; the earlier record's profile is not carried")
        } else if let old = settings.value.pausedState, let oldID = old.profileID {
            switch await Self.checkResumeIntent(old, profileID: oldID, until: settings.value.autoConnect.pausedUntil, now: now(),
                                                repository: profiles.repository) {
            case .holds: carried = oldID
            case .unavailable:
                log.error("pause not extended: the earlier pause record couldn't be checked (keychain unavailable)")
                profiles.note(String(localized: "Protection wasn't paused for longer: LockPlus couldn't read its keychain. Try again in a moment.",
                                     comment: "Problems line (2.0.2 round 2): extending a pause failed because the keychain was unavailable"))
                return
            case .changedOutside, .tooOld, .olderRecord:
                log.fault("earlier pause record without a valid intent; its profile is not carried into the extended pause")
            }
        }
        var restore = settings.value.pausedState.map { old in
            PausedState(profileID: carried ?? active, onDemandEnabledIDs: Array(Set(old.onDemandEnabledIDs + onDemand)), agentBuild: build)
        } ?? PausedState(profileID: active, onDemandEnabledIDs: onDemand, agentBuild: build)
        // Round 1 (Codex 3), round 2 (L5): the record's profile is armed and started at the pause's end only with this
        // one-shot intent. A pause that can't make one doesn't happen (and says so): it would end without reconnecting.
        if let id = restore.profileID {
            do throws(LPError) { restore.intent = try await profiles.repository.sealRecord(.pause, ResumeIntent.message(profileID: id, until: until)) } catch {
                log.error("pause refused: no resume intent (\(error.code.rawValue, privacy: .public))")
                profiles.note(String(localized: "Protection wasn't paused: LockPlus couldn't secure the pause in its keychain (\(error.code.rawValue)). Try again in a moment.",
                                     comment: "Problems line (2.0.2 round 2): a pause failed because its resume intent couldn't be written to the keychain"))
                return
            }
        }
        // The agent reads settings.json (RunAtLoad fires at register()): durable first, then register, and only then
        // stop, so a crash at any later point still resumes (N3).
        await settings.updateDurably {
            $0.autoConnect.pausedUntil = until
            $0.pausedState = restore
            if restore.intent != nil { $0.pauseValueOwed = false }     // round 6: the seal replaced the owed value
            $0.onDemandPausedByStart = []
            if held != nil { $0.networkRestartHold = nil; $0.networkRestartHoldTag = nil }     // review b47da1c L-4: the stop below ends it; same write
        }
        // Review 5 #1: a start that hasn't been issued ends here (after the write: its restore then finds every plan
        // paused and only drops records); one issued meanwhile is stopped like a running session.
        cancelPendingStarts()
        // Review aad7527 #8: read again after the write: a hold may have begun or ended (NE's restart landed) meanwhile.
        let heldNow = networkRestartHolder, liveNow = signableLive
        let gapNow = crashGapHolder
        let signable = signableHold
        if held != nil { consumeHoldRecord() }
        if let heldNow { stopNetworkRestart(heldNow) }
        if let gapNow { stopAwaitedRestart(gapNow) }
        // Review f0c8c57 #4: the session the pause stops is the one its end reconnects, also when it began during the
        // write (the value written above was taken when the write began).
        if let begun = liveNow ?? signable, settings.value.pausedState?.profileID == nil {
            do throws(LPError) {
                let intent = try await profiles.repository.sealRecord(.pause, ResumeIntent.message(profileID: begun, until: until))
                await settings.updateDurably {
                    if $0.pausedState?.profileID == nil { $0.pausedState?.profileID = begun; $0.pausedState?.intent = intent }
                    $0.pauseValueOwed = false                                  // round 6: the seal replaced the value
                }
            } catch {
                // Round 2 (L5): the pause holds (the session is stopped below); its end can't reconnect it, and says so now.
                log.error("pause: no resume intent for the session that began meanwhile (\(error.code.rawValue, privacy: .public))")
                profiles.note(String(localized: "\(profiles.profile(begun)?.name ?? "") won't reconnect when the pause ends: LockPlus couldn't secure the pause in its keychain. Connect it yourself then.",
                                     comment: "Problems line (2.0.2 round 2): a session that began during the pause's write can't be resumed because the intent couldn't be written"))
            }
        }
        resumeAgentStatus = resumeAgent.register()
        let owner = profiles.ownerUID
        Task { @MainActor in
            // Also what a cancelled start turned on meanwhile (its own on-demand, `restoreOwnOnDemand`): the plan of every
            // profile is off while paused, and the resume restores by plan (`wantsRestore`).
            let late = managers.managers.filter { $0.onDemandEnabled && $0.stored?.ownerUID == owner && !onDemand.contains($0.profileID) }
            for id in onDemand + late.map(\.profileID) {
                do throws(LPError) { try await managers.setOnDemandEnabled(false, for: id) } catch {
                    profiles.note(String(localized: "Auto-connect couldn't be paused (\(error.code)); the tunnel may reconnect by itself.", comment: "Problem"))
                }
            }
            // Review fd65f25 LOW 1: the target after the last await (a session may have gone live during either write or
            // the on-demand-off loop above).
            let live = self.statuses.first { $0.value.isActive }?.key
            let issued = self.pending.first { $0.value.phase == .starting(issued: true) }?.key
            if let stopping = live ?? issued { stop(stopping) }
        }
        schedulePauseExpiry(until)
    }

    /// Hands paused on-demand back through the pause record (durable first): `target`'s own comes back inside its start
    /// (`restoreOwnOnDemand`), the rest when nothing is active or starting (`restoreIfIdle`, now or at idle). Used by the
    /// end of a user pause, the end of an extension update (`ManagerQuiescer`) and the end of a suspension. Review R5.
    /// `ending` changes the settings in the same durable write as the record (the marker that handed `ids` over is
    /// cleared only together with the record that takes them), so a crash at any point still knows.
    func returnOnDemand(_ ids: [UUID], thenConnect target: UUID?, ending: (inout AppSettings) -> Void = { _ in }) async {
        await settings.updateDurably {
            for id in ids where !$0.onDemandPausedByStart.contains(id) { $0.onDemandPausedByStart.append(id) }
            ending(&$0)
        }
        // A connect that is ignored (review 4 #1: another start is in flight; #5: it runs already) leaves the handed-back
        // ids recorded: they return when that ends (`restoreIfIdle` from its status), never silently off. Review 5 §3:
        // the target itself isn't retried, so Diagnostics says so when another start was the reason.
        if let target, !connect(target) {
            let name = profiles.profile(target)?.name ?? ""
            if let other = pending.keys.first(where: { $0 != target }) {
                let otherName = profiles.profile(other)?.name ?? ""
                log.notice("hand-back connect of \(target.uuidString.prefix(8), privacy: .public) ignored: \(other.uuidString.prefix(8), privacy: .public) is starting")
                profiles.note(String(localized: "\(name) wasn't reconnected: \(otherName) was starting at the time. Connect \(name) again if you need it.",
                                     comment: "Problem: the end of a pause or an update couldn't reconnect a profile because another start was in flight (review 5)"))
            } else if pending[target]?.phase == .awaitingNetworkRestart {
                // Review b47da1c L-4: its own hold ignored the Connect; macOS connects it when a network returns.
                log.notice("hand-back connect of \(target.uuidString.prefix(8), privacy: .public) ignored: NE restarts it when a network returns")
                profiles.note(String(localized: "\(name) wasn't reconnected yet: macOS connects it when a network is available.",
                                     comment: "Problem: the end of a pause or an update didn't reconnect a profile because macOS restarts it once a network returns (review b47da1c L-4)"))
            }
        }
        restoreIfIdle()
    }

    /// Review 4 #2: the one way an extension hand-over marker (`expectedUpdate`, `pendingResume`) is cleared without a
    /// profile to connect: an install that didn't happen, an activation that completed with nothing quiesced. A save in
    /// the hand-over window held a plan off; the restore (now, or at idle) turns it back on, never waiting for a status
    /// event that may not come.
    func endExtensionHandOver(_ ending: (inout AppSettings) -> Void) async {
        await returnOnDemand([], thenConnect: nil, ending: ending)
    }

    /// Ends the pause. `pausedUntil` clears at once (the UI shows "resumed"); `pausedState` is cleared only after
    /// on-demand and the paused profile were restored, so a crash in between still knows what to restore (H4, M7).
    /// The returned task finishes when the restore is done ("Resume Protection and Quit" awaits it).
    @discardableResult
    func resume() -> Task<Void, Never> {
        pauseTask?.cancel()
        pauseTask = nil
        let state = settings.value.pausedState
        let until = settings.value.autoConnect.pausedUntil
        settings.update { $0.autoConnect.pausedUntil = nil }
        let status = resumeAgentStatus
        resumeAgentStatus = nil
        return Task { @MainActor in
            // E2E-3: no OTHER configuration's on-demand while the paused profile starts; those come back through the
            // pause record when it ends. Failures stay recorded and are retried (review F4).
            // Review R5: through the record only, whatever is active or starting now.
            var target = state?.profileID.flatMap { profiles.profile($0) != nil ? $0 : nil }
            // Round 1 (Codex 3): settings.json isn't authenticated; the record's profile is reconnected only with its intent
            // (round 2, L5: one shot, consumed here).
            if let id = target {
                // Round 6 (Codex r6 #3): an owed value (a genuine record hidden while nothing was paused, written back now)
                // goes before anything is checked; if it can't go yet, this end is retried like an unreadable keychain.
                let owedSpent = settings.value.pauseValueOwed ? await spendPauseValue() : true
                let check = owedSpent
                    ? await Self.checkResumeIntent(state, profileID: id, until: until, now: now(), repository: profiles.repository)
                    : .unavailable
                if check == .unavailable, resumeIntentRetries < Self.maxResumeIntentRetries {
                    // Round 2 (L5): retryable, like the headless agent's: the pause record stays as it is and the end runs
                    // again shortly (a quit meanwhile leaves it to the agent, which stays registered).
                    resumeIntentRetries += 1
                    log.error("pause record of \(id.uuidString.prefix(8), privacy: .public) not checked (keychain unavailable); retrying")
                    settings.update { if $0.autoConnect.pausedUntil == nil { $0.autoConnect.pausedUntil = until } }
                    resumeAgentStatus = status
                    let sleep = timerSleep, delay = Self.resumeIntentRetryDelay
                    pauseTask = Task { @MainActor [weak self] in
                        await sleep(delay)
                        guard !Task.isCancelled else { return }
                        self?.resume()
                    }
                    return
                }
                resumeIntentRetries = 0
                // Round 3 (Fable L2): the pause ends here whatever the check says: its one-time value goes in every case
                // (except an unreadable keychain, retried above), so a genuine record that was hidden or altered at this
                // moment can't be written back and verify later. Round 6 (Fable r6 N4b): a delete that fails stays owed.
                if await !spendPauseValue() { runPauseValueSpend(.later) }
                if check != .holds {
                    log.fault("pause record of \(id.uuidString.prefix(8), privacy: .public): \(String(describing: check), privacy: .public); not reconnected")
                    profiles.note(Self.resumeRefusedNote(check, name: profiles.profile(id)?.name ?? ""))
                    target = nil
                }
            }
            if state?.profileID.flatMap({ profiles.profile($0) }) == nil {
                // Round 3 (L2), round 4 (Codex r4 #4): the pause ends here, so its one-time value goes whatever the record
                // says: one naming no known profile, naming none (a removed `profileID`), or no record at all. A genuine
                // record copied earlier and written back later never verifies. Round 6: a failed delete stays owed.
                if await !spendPauseValue() { runPauseValueSpend(.later) }
            }
            await returnOnDemand(state?.onDemandEnabledIDs ?? [], thenConnect: target)
            await restoreTask?.value
            await settings.updateDurably { if $0.autoConnect.pausedUntil == nil { $0.pausedState = nil } }
            // Last: the durable state is already clear (job-not-found = done). Round 6 (Codex r6 #3): kept while the
            // pause's value is owed (the agent's runs keep spending it after a quit).
            if !settings.value.pauseValueOwed { await resumeAgent.unregister() }
        }
    }

    /// Round 1 (Codex 3): the record names `profileID`, carries its intent for the pause's end `until`, and that end is
    /// not older than `ResumeIntent.maxAge`. Round 2 (L5): the intent is one shot (the caller consumes it when it acts),
    /// and a keychain that can't be read is `.unavailable` (retried), never "changed outside". Shared with the headless agent.
    static func checkResumeIntent(_ state: PausedState?, profileID: UUID, until: Date?, now: Date, repository: ProfileRepository) async -> ResumeIntent.Check {
        guard let state, state.profileID == profileID, let until else { return .changedOutside }
        guard ResumeIntent.isFresh(until: until, now: now) else { return .tooOld }
        switch await repository.checkRecord(.pause, tag: state.intent, ResumeIntent.message(profileID: profileID, until: until)) {
        case .valid: return .holds
        case .unavailable: return .unavailable
        case .invalid: return .changedOutside
        case .neverSealed: return state.intent == nil ? .olderRecord : .changedOutside
        }
    }

    /// Round 2 (L5): the GUI's end of a pause retries an unreadable keychain this often, `resumeIntentRetryDelay` apart.
    static let maxResumeIntentRetries = 5
    static let resumeIntentRetryDelay: Duration = .seconds(30)
    @ObservationIgnored private var resumeIntentRetries = 0

    /// Round 2 (L5): the Problems line for a pause end that doesn't reconnect its profile, by reason.
    static func resumeRefusedNote(_ check: ResumeIntent.Check, name: String) -> String {
        switch check {
        case .tooOld:
            String(localized: "\(name) wasn't reconnected: the pause ended more than 7 days ago. Connect it yourself.",
                   comment: "Problems line (2.0.2 round 2): a pause record older than 7 days isn't resumed")
        case .unavailable:
            String(localized: "\(name) wasn't reconnected: LockPlus couldn't read its keychain to check the pause. Connect it yourself.",
                   comment: "Problems line (2.0.2 round 2): the keychain stayed unavailable at the end of a pause")
        case .olderRecord:
            String(localized: "\(name) wasn't reconnected: the pause was started by an earlier version of LockPlus. Connect it yourself.",
                   comment: "Problems line (2.0.2 round 2): a pause record written before 2.0.2 restores on-demand only")
        case .holds, .changedOutside:
            String(localized: "The pause record was changed outside LockPlus, so \(name) wasn't reconnected. Connect it yourself.",
                   comment: "Problems line (2.0.2 round 2): the pause record in settings.json failed its authentication check")
        }
    }

    /// Disconnect and wait for `.disconnected` (≤ `timeout`), for "Disconnect and Quit" (H4).
    func disconnectAndWait(timeout: Duration = .seconds(5)) async {
        guard let id = currentID, statuses[id]?.isActive == true else { return }
        disconnect()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, managers.status(id) != .disconnected, managers.status(id) != .invalid {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func schedulePauseExpiry(_ until: Date) {
        pauseTask?.cancel()
        let delay = max(0, until.timeIntervalSince(now()))
        pauseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.resume()
        }
    }

    private func resumePauseAtLaunch() {
        guard let until = settings.value.autoConnect.pausedUntil else { spendPauseValueWhileUnpaused(); return }
        if until <= now() { resume() } else { schedulePauseExpiry(until) }
    }

    /// Round 5 (Codex r5 #5): nothing is paused at launch, so no pause can end later: its one-time value goes now (a
    /// genuine record whose expiry was removed, written back with it later, never verifies). Round 6 (Codex r6 #3): a
    /// failed delete is owed (`AppSettings.pauseValueOwed`) until one succeeds: retried `maxResumeIntentRetries` times
    /// `resumeIntentRetryDelay` apart, then at each `load()` and wake and at the next launch; spent first at the end of
    /// any pause; the agent isn't unregistered meanwhile. The user's Pause cancels a spend before it seals its own value
    /// (which replaces the owed one).
    @ObservationIgnored private var pauseValueSpend: Task<Void, Never>?
    @ObservationIgnored private var pauseInFlight = 0
    private func spendPauseValueWhileUnpaused() { runPauseValueSpend(.launch) }

    /// Deletes the pause's one-time value. A failure makes (and keeps) it owed, durably; success ends the debt.
    @discardableResult
    private func spendPauseValue() async -> Bool {
        let spent = await profiles.repository.consumeRecord(.pause)
        if settings.value.pauseValueOwed == spent { await settings.updateDurably { $0.pauseValueOwed = !spent } }
        return spent
    }

    /// Round 6 (Codex r6 #3): an owed value may be spent now: no pause is being made, and no pause holds a value of its
    /// own (that pause's end spends it, owed first).
    private var mayRetryOwedSpend: Bool {
        let s = settings.value
        return s.pauseValueOwed && pauseInFlight == 0 && (s.autoConnect.pausedUntil == nil || s.pausedState?.intent == nil)
    }

    enum PauseValueSpendStart { case launch, now, later }
    /// One spend chain at a time: `.launch` spends unconditionally (nothing is paused), `.now` (`load()`, wake) and
    /// `.later` (after a failed spend at a pause's end) only an owed value. Up to `maxResumeIntentRetries` timer retries,
    /// `resumeIntentRetryDelay` apart; then the next `load()`, wake or launch. The chain ends with the agent's reconcile
    /// (round 7): one deferred while it ran, or an agent kept for a debt it cleared, goes when nothing is paused.
    private func runPauseValueSpend(_ start: PauseValueSpendStart) {
        guard pauseValueSpend == nil else { return }
        let sleep = timerSleep
        pauseValueSpend = Task { @MainActor [weak self] in
            var attempt = start == .later ? 1 : 0
            while !Task.isCancelled {
                if attempt > 0 { await sleep(Self.resumeIntentRetryDelay) }
                guard !Task.isCancelled, let me = self, start == .launch && attempt == 0 || me.mayRetryOwedSpend else { break }
                if await me.spendPauseValue() { break }
                if attempt >= Self.maxResumeIntentRetries { break }
                attempt += 1
            }
            guard !Task.isCancelled, let me = self else { return }
            me.pauseValueSpend = nil
            // Round 7 (Codex r7 #3): a reconcile deferred while this spend was pending (the launch's) runs on its result:
            // spent, an agent kept for it goes when nothing is paused; owed, it stays.
            await me.reconcileResumeAgent()
        }
    }

    /// Round 6 (Codex r6 #3): `ProfilesStore.load()` and wake spend an owed pause value.
    func retryOwedPauseValue() {
        if mayRetryOwedSpend { runPauseValueSpend(.now) }
    }

    /// Tests: waits for the spend of the pause value (its retries included).
    func awaitPauseValueSpend() async { await pauseValueSpend?.value }

    /// Launch (§10.4, C12): re-register the agent for a new binary while paused; drop a stale registration otherwise.
    func reconcileResumeAgent(currentBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") async {
        let s = settings.value
        switch ResumeAgentLaunchPolicy.action(pausedUntil: s.autoConnect.pausedUntil, agentBuild: s.pausedState?.agentBuild,
                                              currentBuild: currentBuild, status: resumeAgent.status, now: now()) {
        case .none: break
        case .unregister where s.pauseValueOwed: break           // round 6 (Codex r6 #3): kept for the owed spend
        // Round 7 (Codex r7 #3, Fable r7 N2): the launch's spend may still fail and make the value owed; the chain
        // reconciles again on its result.
        case .unregister where pauseValueSpend != nil: break
        case .unregister: await resumeAgent.unregister()
        case .reregister:
            await resumeAgent.unregister()
            await settings.updateDurably { $0.pausedState?.agentBuild = currentBuild }
            resumeAgentStatus = resumeAgent.register()
        }
    }

    /// Wake: an expired pause resumes at once (the app timer may have slept through it).
    func checkPauseExpiry() {
        if let u = settings.value.autoConnect.pausedUntil, u <= now() { resume() }
    }

    /// `NSWorkspace.didWakeNotification`: the pause check, and a held start gets fresh endpoint IPs (PF 50).
    func didWake() {
        retryOwedPauseValue()                 // round 6 (Codex r6 #3)
        checkPauseExpiry()
        pushFreshEndpointsIntoHeldStart()
    }

    // MARK: Held start, fresh endpoints (PENDING-FOLD 50, §20 risk 25)

    /// On a network change or wake: if our start is held before Connected because its endpoint IPs failed (or there
    /// were none: an on-demand start uses the extension's cache alone), resolve the profile's endpoints again and push
    /// them into the held start, which then retries at once. The extension refuses anything else (`.notHeld`) and
    /// ignores IPs it already tried (`.unchanged`), so this can't loop.
    /// Limit: the hold itself blocks under `includeAllNetworks` (S2 E14a), so the lookup succeeds only where DNS is
    /// exempt or cached: a LAN resolver with "Allow local network" on (S2 E10: 305 ms), or mDNSResponder's cache.
    func pushFreshEndpointsIntoHeldStart() {
        guard let id = currentID, statuses[id] == .connecting, let p = profiles.profile(id) else { return }
        endpointPushTask?.cancel()
        let service = self.service, resolve = resolveEndpoints, settle = endpointPushSettle
        let endpoints = p.summary.resolvableEndpoints
        endpointPushTask = Task { @MainActor [weak self] in
            if settle > .zero { try? await Task.sleep(for: settle) }
            guard !Task.isCancelled,
                  let snap = try? await service.call(.tunnelSnapshot, ProfileRequest(profileID: id), as: TunnelSnapshot.self),
                  PushEndpointsRequest.appliesTo(snap, profileID: id) else { return }
            let map = Self.pushableEndpoints(await resolve(endpoints))
            guard !Task.isCancelled, !map.isEmpty, let self, self.statuses[id] == .connecting else { return }
            do throws(LPError) {
                let r = try await service.call(.pushEndpoints, PushEndpointsRequest(profileID: id, endpoints: map), as: PushEndpointsReply.self)
                self.log.notice("held start: pushed \(map.count, privacy: .public) endpoint host(s): \(r.outcome.rawValue, privacy: .public)")
            } catch {
                self.log.notice("held start: endpoint push failed: \(error.code.rawValue, privacy: .public)")
            }
        }
    }

    /// The resolver's map, shaped to the wire rules (`EndpointMapRules.sanitized`, the extension's own filter).
    static func pushableEndpoints(_ m: [String: [String]]) -> [String: [String]] { EndpointMapRules.sanitized(m) }

    // MARK: Restart after a tunnel-process crash (PENDING-FOLD 52, §20 risk 24)

    /// `NEVPNConnectionErrorDomain` 12: the provider process died (S5, S2 E1).
    static func isPluginFailed(_ e: NSError) -> Bool { e.domain == NEVPNConnectionErrorDomain && e.code == 12 }

    /// A kill-switch profile with on-demand rules gets no restart from NE after a provider crash (S2 E1: any connect
    /// rule disables it; open 4.1–4.5 s on 27, ≥ 30 s on 26, until an on-demand trigger). If we're running, we start
    /// it ourselves, after `crashRestartGrace` and only if it is still `.disconnected`. The start has on-demand
    /// semantics (no `lp.manual`): the extension's start latch still applies, no prompt or prepared answer is taken,
    /// and the endpoint IPs come from its cache, as for the restart NE would have made. Bounded by `CrashRestartPolicy`.
    ///
    /// A kill-switch profile WITHOUT on-demand rules is restarted by NE itself, ≈2.0–2.9 s after `.disconnected`
    /// (LK-02, E2E-1: the restarted session's block lands there). That restart is a pending kill-switch start: nothing
    /// may be saved before it (review R1, 200003). So the disconnect stays `.awaitingRestart` (nothing restored,
    /// `othersBusy`) until the session is back (`handle`), with `systemRestartTimeout` (10 s; E2E-4 U8 measured
    /// `.connecting` ≈1 s after `.disconnected`) as the fallback for a restart that never comes. The 1.5 s grace is only for OUR restart decision, never for NE's. `token`: the
    /// disconnect's entry; once it is gone (the session is back, the user connected) nothing here acts.
    private func restartAfterCrashIfNeeded(_ id: UUID, _ token: UInt64) {
        guard pending[id]?.token == token else { return }
        // Simplification 4: decided twice by design. Now, to tell NE's own restart from ours; after the grace again,
        // with what changed meanwhile (the status, a user stop, a switch, a pause).
        if crashDecision(id) == .expectSystemRestart {
            log.notice("tunnel process crashed; NE restarts it itself: waiting for it")
            arm(id, .awaitingRestart, timeout: systemRestartTimeout, expectsRestart: true)    // the fallback counts from now (U8)
            return
        }
        let ours = arm(id, .awaitingRestart, expectsRestart: true)   // the fetch phase's timer was for the fetch; ours from now
        let grace = crashRestartGrace
        Task { @MainActor [weak self] in
            if grace > .zero { try? await Task.sleep(for: grace) }
            guard let self, self.pending[id]?.token == ours else { return }
            let decision = self.crashDecision(id)
            switch decision {
            case .restart:
                self.crashes.restarted(id, at: self.now())
                self.log.notice("tunnel process crashed; restarting (on-demand semantics)")
                self.arm(id, .starting(issued: true))
                self.newIssuedAttempt(id)
                do throws(LPError) { try self.managers.start(id, options: StartOptionsBuilder.crashRestart) } catch {
                    self.log.error("restart after crash failed: \(error.code.rawValue, privacy: .public)")
                    self.clearPending(id)
                    self.restoreIfIdle()
                }
            case .skip, .expectSystemRestart:
                // Review F1: only now, with the session still down (`.expectSystemRestart` here: the manager changed
                // under us, nobody restarts it now).
                self.log.notice("tunnel process crashed; no app restart: \(String(describing: decision), privacy: .public)")
                self.clearPending(id)
                self.restoreIfIdle()
            }
        }
    }

    private func managerKillSwitch(_ id: UUID) -> Bool {
        managers.managers.first { $0.profileID == id }?.flags?.includeAllNetworks ?? false
    }

    /// Review N6: `includeAllNetworks` as the crashed session was started with (NE restarts it with those options), not
    /// the manager's current flags, which nehelper may have rewritten since.
    private func crashDecision(_ id: UUID) -> CrashRestartPolicy.Decision {
        let m = managers.managers.first { $0.profileID == id }
        return CrashRestartPolicy.decide(
            status: managers.status(id), onDemandEnabled: m?.onDemandEnabled ?? false,
            includeAllNetworks: sessionKillSwitch[id] ?? managerKillSwitch(id), userStopped: userStops.contains(id),
            // Review f0c8c57 #2: any other pending start counts as a switch (it may have begun beside this session's end).
            switching: switchTarget != nil || pending.contains { $0.key != id && $0.value.isStarting }, paused: pausedUntil != nil,
            recentRestarts: crashes.restarts(id), now: now())
    }
}

/// PENDING-FOLD 52 decision (lead, P3): BUILT, bounded. Evaluated against S2 E1: NE restarts a crashed provider by
/// itself only when the manager has no on-demand rule; with one, nothing restarts it until an on-demand trigger. The
/// app restarts only in exactly that gap (kill-switch `includeAllNetworks` + on-demand enabled), never while paused,
/// suspended, switching or after the user's stop, never before the grace (so NE's own restart wins whenever it
/// happens), and at most `maxRestarts` per `window` per profile (a crash loop then waits for the user).
enum CrashRestartPolicy {
    static let grace: Duration = .milliseconds(1500)
    static let maxRestarts = 3
    static let window: TimeInterval = 600
    /// PF 53: a `.connected` this soon after an observed crash is "reconnected after a tunnel process restart".
    static let reconnectWindow: TimeInterval = 120

    /// Review PF-R1: `fetchLastDisconnectError` keeps returning an old `pluginFailed`, so a 12 alone doesn't mean this
    /// disconnect was a crash. A crash kills the extension process, which interrupts our XPC link at once; NE reports
    /// `.disconnected` ~5 s later (S2 E1). The interruption must fall in [`.disconnected` − `crashSignalWindow`,
    /// `.disconnected` + `crashSignalSlack`] and after the session's last `.connected`.
    static let crashSignalWindow: TimeInterval = 10
    static let crashSignalSlack: TimeInterval = 1

    /// `.expectSystemRestart` (review R1): a kill-switch profile without on-demand rules; NE restarts it itself.
    enum Decision: Equatable { case restart, expectSystemRestart, skip(String) }

    /// Whether a `pluginFailed` reported for this disconnect is a fresh tunnel-process crash (PF 52 and PF 53 act only
    /// then): the session reached Connected, and the XPC link was interrupted in the window above.
    static func isFreshCrash(wasConnected: Bool, linkInterruptedAt: Date?, connectedAt: Date?, disconnectedAt: Date) -> Bool {
        guard wasConnected, let t = linkInterruptedAt else { return false }
        let lower = max(disconnectedAt.addingTimeInterval(-crashSignalWindow), connectedAt ?? .distantPast)
        return t >= lower && t <= disconnectedAt.addingTimeInterval(crashSignalSlack)
    }

    /// The per-profile bookkeeping the policy reads: the last `.connected`, a fresh crash (for PF 53's copy, ≤
    /// `reconnectWindow`) and our restarts (≤ `maxRestarts` per `window`).
    struct Book {
        private var connectedAt: [UUID: Date] = [:]
        private var crashedAt: [UUID: Date] = [:]
        private var restartsAt: [UUID: [Date]] = [:]

        mutating func connected(_ id: UUID, at t: Date) { connectedAt[id] = t }
        mutating func crashed(_ id: UUID, at t: Date) { crashedAt[id] = t }
        /// The user acted (Connect, Disconnect): a later `.connected` is not "after a crash".
        mutating func forgetCrash(_ id: UUID) { crashedAt[id] = nil }

        func isFreshCrash(_ id: UUID, wasConnected: Bool, linkInterruptedAt: Date?, disconnectedAt: Date) -> Bool {
            CrashRestartPolicy.isFreshCrash(wasConnected: wasConnected, linkInterruptedAt: linkInterruptedAt,
                                            connectedAt: connectedAt[id], disconnectedAt: disconnectedAt)
        }

        /// A `.connected` (the first of a session): true once if it follows a fresh crash within `reconnectWindow`.
        mutating func reconnected(_ id: UUID, at now: Date) -> Bool {
            guard let c = crashedAt.removeValue(forKey: id) else { return false }
            return now.timeIntervalSince(c) <= reconnectWindow
        }

        func restarts(_ id: UUID) -> [Date] { restartsAt[id] ?? [] }
        mutating func restarted(_ id: UUID, at now: Date) {
            restartsAt[id] = restarts(id).filter { now.timeIntervalSince($0) < window } + [now]
        }
    }

    static func decide(status: TunnelStatus, onDemandEnabled: Bool, includeAllNetworks: Bool, userStopped: Bool,
                       switching: Bool, paused: Bool, recentRestarts: [Date], now: Date) -> Decision {
        guard status == .disconnected else { return .skip("already \(status)") }        // NE or on-demand restarted it
        guard includeAllNetworks else { return .skip("no kill switch") }
        guard onDemandEnabled else { return .expectSystemRestart }                      // NE restarts it itself
        guard !userStopped, !switching, !paused else { return .skip("user action") }
        let recent = recentRestarts.filter { now.timeIntervalSince($0) < window }
        guard recent.count < maxRestarts else { return .skip("restart limit") }
        return .restart
    }
}

extension TunnelStatus {
    var isActive: Bool { self == .connecting || self == .connected || self == .reasserting }
    /// The session has not ended: active, or `.disconnecting` (E2E-4: busy until a handled `.disconnected`).
    var isLive: Bool { self != .disconnected && self != .invalid }
}
