# Fable review: 4b5ec88..994f83e (on-demand pause/restore, E2E-3 fixes), 2026-10-30. Fix ALL.

Read-only review of 4b5ec88..994f83e (917369b, 0f33d3c, ca0df9e, 8d7d7f5 + docs/build commits). Files: native/App/Stores/ConnectionStore.swift (CS), native/App/Stores/ProfilesStore.swift (PS), native/App/Headless/HeadlessResume.swift (HR), native/App/Stores/ManagerStore.swift (MS), native/App/UIBinder.swift (UB), native/App/AppEnvironment.swift (AE), tests. I did not run the Unit plan.

Short answer to the durability question first: the pause is NOT recorded anywhere. Restore is derived at runtime from settings.autoConnect + the manager's isOnDemandEnabled (CS:114-121 autoProfileToRestore, CS:462-470 reenableAutoProfile). That derivation is sufficient for THIS user's auto profile and nothing else (see F7, F8).

FINDINGS (most severe first)

F1 HIGH — a tunnel-process crash of the manual profile re-enables the auto profile, then NE restarts the crashed session with it on: the bug is recreated.
CS:182-211. observedDisconnect(X) calls reenableAutoProfile(after: X) at line 188 unconditionally, BEFORE the pluginFailed check (200-211). For a kill-switch profile WITHOUT on-demand rules (any manual X) NE restarts the provider itself ~1 s after .disconnected (DESIGN §10.4 D9-8/S2 E1, quoted at CS:617-622). Scenario: A auto, X connected (A paused). X's provider crashes → .disconnected → A saved with on-demand ON (a config change landing exactly at NE's own restart of X, the 200003 failure mode) → X comes back .connecting; handle() sets holdsBackOnDemand(A)=true but nothing turns A off again (pauseOtherOnDemand runs only inside startNow, CS:344; restartAfterCrashIfNeeded CS:640 also skips it) → the restarted X session runs beside A's enabled on-demand → next en0 change: X blocked until the user disconnects (fail-closed, not unprotected, but exactly the PF 50 state the fix targets).
Fix: in observedDisconnect, run reenableAutoProfile only after fetchLastDisconnectError and only when no NE restart is expected (not pluginFailed, or after crashRestartGrace with status still .disconnected); additionally, in handle(.connecting) for a session this instance did not start, re-run pauseOtherOnDemand (also narrows the System Settings residual — but see U2 before relying on a post-start pause).

F2 HIGH — a failed prepareForStart after a switch leaves the auto profile silently off until relaunch.
CS:336-340: `fail(id, error); return` — no reenableAutoProfile (only the managers.start throw path at 348-351 has it). Scenario: X running (A paused by X's start). User clicks Connect on Y → connect() switches (CS:310-323): stop(X) → X .disconnected → reenableAutoProfile(after: X) returns because currentID == Y (guard CS:467) → startNow(Y) → prepareForStart(Y) throws (.killSwitchNotApplied, a configuration-denied save, extensionUnavailable) → fail(Y). Now nothing runs, A's manager has isOnDemandEnabled=false, settings say auto-connect on. Nothing restores it until the next app launch (CS:102); the Auto-Connect pane shows the toggle ON (UB:216-220 mirrors settings) and no status line (UB:244 needs an active current). The user walks onto untrusted Wi-Fi unprotected believing auto-connect is on.
Fix: call reenableAutoProfile(after: id) from fail() (or from the prepareForStart catch), and make the guard "nothing else active or starting" rather than currentID-based.

F3 MEDIUM — a failed pause still starts the kill-switch session beside an enabled on-demand configuration.
CS:365-367 logs and continues; `paused` stays false so there is no settle either. Scenario: setOnDemandEnabled(false, A) fails (stale retried once in MS:343-351; permission/NEVPNErrorDomain otherwise) → start(X) proceeds with A's on-demand ON → PF 50 blocked session after the next network change. The root cause doc says this is deterministic on 26 with a kill-switch profile.
Fix: treat a failed pause as a start failure (fail(id, error) with a note "Auto-connect of <A> couldn't be paused; not connecting"), or at least note() it so Diagnostics shows why the tunnel later hangs.

F4 MEDIUM — every restore is `try?` with no note; a failed save = permanent silent loss, and the UI cannot show it.
CS:110 (launch), CS:456 (suspension end), CS:469 (profile end): `try? await profiles.saveOnDemand(p)`. Compare stop() CS:415-418 which notes a failed disable. Nothing retries; the next chance is the next launch, which is `try?` again. The UI never renders a profile's actual on-demand state: UB:184-190 computes ProfileItem.onDemandEnabled but no view reads it (grep App/UI: only UIModels.swift and PreviewFixtures.swift); the Auto-Connect toggle mirrors settings, not the manager. So "A's on-demand is off although auto-connect is on" is invisible in every F1/F2/F4 case.
Fix: note() on a failed restore and schedule a retry on the next status event/launch; derive the Auto-Connect pane's state (or a status line "Auto-connect is off; LockPlus couldn't re-enable it") from `managers.managers[auto].onDemandEnabled != plan.enabled`.

F5 MEDIUM — saves made by other paths land inside the start window without the settle.
CS:371 settles only when pauseOtherOnDemand itself saved. Any other manager save between pause and start bypasses it: (a) our own pause save fires NEVPNConfigurationChange → AE:247-250 → PS.load() → PS:127-137 syncManager re-saves any manager that is behind/drifted, possibly inside the 1 s window or right at start(X); (b) restoreOnDemand on a network change (CS:439, held back → saves A with enabled=false anyway); (c) resaveOnDemand from a UI click (UB:298); (d) launch ordering CS:101-102: resumePauseAtLaunch → resume() Task (enables pausedState IDs, connect(X)) and restoreAutoProfileAtLaunch run back-to-back; if pausedState lists A (X started via System Settings or pre-fix build), A is turned on, then off by pauseOther, then X starts — if the off-save from the launch Task completes before pauseOther runs, `paused` is false → no settle → the "16 ms before the start" case of 200003.
Fix: settle relative to the last manager mutation (timestamp in SerializedVPNManager; wait until ≥ 1 s has passed since any save/setOnDemandEnabled before start()), and defer load()-driven re-saves while `starting` is non-empty.

F6 MEDIUM — NE's own on-demand start of A can race the manual start of X.
CS:301-344: connect() checks for an active profile synchronously (310), then startNow does prepareForStart (≤ 0.5–1 s) + resolveEndpoints (≤ 3 s) before pausing A. If on-demand fires A in that window (user opened an app on untrusted Wi-Fi), handle(A, .connecting) makes A current, then pauseOther turns A off while connecting and start(X) is issued on top of an active A — two sessions / an NE error, and A was stopped without a suspension record, so its end does nothing.
Fix: after pauseOtherOnDemand + settle, re-check `statuses` for another active profile and route through the switch path (pendingSwitch = id; stop(active); return) instead of starting.

F7 MEDIUM — the pause touches other users' configurations, the restore does not.
MS:90-122 loadAll keeps every configuration of our bundle id regardless of ownerUID (the codebase assumes other users' managers are present: PS:121 restricts the orphan sweep to `m.stored?.ownerUID == ownerUID`). CS:363 pauses every manager with onDemandEnabled; CS:462-470 and CS:114-121 restore only this user's settings.autoConnect profile. Scenario (shared Mac, fast user switching): user 1 connects X → user 2's auto profile turned off → restored only when user 2's own app next launches with nothing active, meanwhile user 2's auto-connect is silently off.
Fix: either filter pauseOther to `m.stored?.ownerUID == ownerUID` (accept and document that another user's on-demand config still triggers the NE bug), or record the paused IDs durably (settings.onDemandPausedByStart) and restore exactly those — which also answers the durability question and fixes F8.

F8 LOW (latent) — stayConnected profiles are paused and never restored.
OnDemandPlan.stayConnected (ManagerConfiguration.swift:73-75, 84) gives non-auto profiles on-demand; pauseOther pauses them, but reenableAutoProfile/autoProfileToRestore/HR:66 only ever restore the auto profile; HR:74 restores `all` only when the restart fails. Latent today: NetworkPolicy.stayConnected is never set true in production (GoAppMigration.swift:316 sets false; no UI), but the model and plan exist and tests exercise them.
Fix: same as F7 (restore exactly what was paused), or remove stayConnected.

F9 LOW — `starting` can hold the auto profile back with nothing running.
CS:330 inserts, CS:136/380 remove on the first status or a throw. If NE silently drops the start (S2: a start issued while still Stopping; CS:171 comment) and never reports a status, X stays in `starting`, holdsBackOnDemand(A) stays true, and any save keeps A off until some status for X arrives. The pendingSwitch design mostly avoids this; the 22 s fallback (CS:318-322) calls startNow again (a second pause, no settle since A is already off).
Fix: clear `starting` on a timeout (e.g. 30 s without a status) and restore.

F10 LOW — UI truth gaps.
(a) UB:241: switching away from the auto profile goes through stop(A) (CS:314 → CS:409-414) which records a Disconnect suspension; the pane then says "because you disconnected it" and A does NOT resume when X ends (reenableAutoProfile guard CS:464) — DESIGN:3013-3015 promises it does. Fix: in the switch path stop without recording a suspension; X's pause/restore then handles A. (b) UB:244-246 "resumes when you disconnect X" is also shown when X was started from System Settings, where A's on-demand is still on. (c) During startNow's window (resolve + 1 s settle, before .connecting) A is already off and nothing is shown. (d) connect() has no in-flight guard; the added settle widens the double-click window (two pauses, two starts).

F11 LOW — the headless resume starts without prepareForStart (HR:71): no kill-switch flag verification for the restarted profile (pre-existing, unchanged by this range, but the new HR code path is the one being relied on now).

saveToPreferences VOLUME / PF 55
Per manual connect of X with an auto profile: 1 pause save (A, isOnDemandEnabled only, MS:207-211, no loadFromPreferences), 0–1 prepareForStart save (X), start; per end: 1 full ManagerConfiguration save of A (saveOnDemand, MS:144-182 incl. loadFromPreferences). Every save fires NEVPNConfigurationChange → SerializedVPNManager.loadAll + PS.load() (repository.list + HMAC + drift check). None of these touch the live tunnel's manager except prepareForStart. Extra: while X runs and A is suspended, every pass through "none" (CS:437-439) re-saves A with enabled=false — a no-op save on a non-live manager during a network change (see U2). Drift healing: each A save is another chance for nehelper's rewrite; PS:129-131 heals once per revision per run, the second drift is only noted and A stays drifted until prepareForStart(A) — fail-closed for app starts, but an NE on-demand start of A uses the drifted config (pre-existing exposure, now with 2 more A saves per connect cycle).

HEADLESS AGENT (HR:62-77): correct for the auto profile: target X → only X's own on-demand (none) enabled; failed start → `all` restored. pausedState recorded while X ran post-fix has onDemandEnabledIDs=[] (A already paused), so A's return relies entirely on the GUI's launch restore (CS:108) — fine, but it fails for F7/F8 and is `try?`.

SYSTEM SETTINGS GAP: documented residual; the app could pause on an observed .connecting of a session it did not start (handle(), CS:134), which would also fix F1 — only if U2 is measured safe.

TESTS
- aStartThatFailsAtOnceRestoresTheAutoProfile (OnDemandRestoreTests:380-391) does not prove a pause happened: start throws before onDemandAtStart is recorded, and `onDemand == true` also holds if pauseOther were a no-op. Fix: record setOnDemandEnabled calls in FakeVPNManager (AppRootFakes:81-86 has no log) and assert [false, true].
- pushOnlyOnArrivingAtANetwork (HeldStartRecoveryTests:83-98): `pushes.count == 1` also holds for the old code (the second change cancelled and rescheduled the first push); only the two static isArrival asserts distinguish. Fix: after "unsatisfied|" wait > settle and assert 0 pushes, then arrive and assert 1.
- startingAnotherProfilePausesTheAutoProfileUntilItEnds, nothingReEnablesTheAutoProfileWhileAnotherRuns, aPausedAutoProfileReturnsAtLaunch…, anExpiredPauseRestartsAManualProfile…: prove what they claim (onDemandAtStart is a real ordering assertion). settleAfterSave = 0 in the harness, so the 1 s settle is untested.
- No test for F1 (crash + NE restart), F2 (prepareForStart failure after a switch), F3 (failed pause), F4 (failed restore), F6 (on-demand fires mid-start).

SIMPLIFICATIONS
1. One restore function (restoreAutoProfileIfIdle) called from observedDisconnect, fail(), start() and the prepareForStart catch, with one guard set; today autoProfileToRestore (CS:114-121) and reenableAutoProfile (CS:462-470) use different predicates (manager flag vs currentID).
2. pauseOtherOnDemand returns the paused IDs; persist them (settings.onDemandPausedByStart) and restore exactly those: durable, fixes F7/F8, and drops the derived guessing.
3. Skip no-op saves: saveOnDemand/restoreOnDemand when the manager already has the planned enabled state and the rules can't have changed (MS:208 already does this for setOnDemandEnabled; save() does not) — cuts churn and the in-window risk of F5.
4. holdsBackOnDemand (CS:375-377) and the reenableAutoProfile guard (CS:467) duplicate the "another profile active" predicate; share it.

COULD NOT VERIFY
U1 The Unit plan (303/303 claim) — not run.
U2 Whether a save on another manager AFTER the started session reports .connecting/.connected (not during the pending start) causes the en0 loss; this decides whether a post-start pause (F1 fix b, System Settings gap) and the held-back no-op saves during a network change are safe. E2E-3 measured only the pending-start case and E9 only the connected manager itself.
U3 That loadAllFromPreferences returns other users' configurations on 26/27 (the code assumes it; F7 depends on it).
U4 The timing of the load()-driven re-save after our own pause save relative to the 1 s settle (F5a).
U5 Whether an isOnDemandEnabled-only save triggers nehelper's flag rewrite (PF 55 interaction).
U6 That NWPathMonitor reports an empty-interface path on an SSID switch ("passes through none", CS:444) — if it does not, a same-interface SSID change no longer ends a suspension (previously the status flip did).
