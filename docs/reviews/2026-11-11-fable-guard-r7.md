# Verification round 6: start guard round 5 fixes (4a3bcd7a)

Read-only, 2026-11-11, HEAD 4a3bcd7a. Nothing edited or committed in the repo.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `MS` = `App/Stores/ManagerStore.swift`.

## Verdict

Release-clean on HIGH and MEDIUM: none found. Four LOWs (two in the new Diagnostics note, one in the invalidation of a preempting start, one test gap) and four NITs.

Every finding of round 5 (mine and Codex's) is fixed or removed with the stray stop. Nothing is left of the stray stop in code, fakes or tests.

What was run:
- `swift test` on the guard, connected and start suites in a scratch copy of the package at HEAD (sources identical to the repo): 154 tests pass.
- 25 mutations in that copy (`mut-tools/mutate7.py`, results in `mutate7.out`): 20 caught, 5 survive (table below).
- 2 probe tests (`mut-tools/R6Probe.swift`, output in `probe7.out`).
- The app suite (`Tests/LockPlusTests`) was read, not run. L1, L2 and the copy answers are traced from the code.
- Nothing ran on NE.

## LOW

### L1. The stray note repeats at every configuration reload
- **Where:** `CS:720` prunes `strayNoted` to the keys of the strays now loaded; `MS:200` gives every stray a fresh `UUID()` key at each `loadAllFromPreferences`.
- **Scenario:** a duplicate waits. Any NE configuration change (another user's LockPlus, nehelper's rewrite, System Settings) reloads; the same waiting stray comes back under a new key, `configurationChanged` runs `noteStrayDuplicates`, and the line is posted again. That is once per reload, not once per attempt.
- **Effect:** repeated Diagnostics lines; `ProfilesStore.note` keeps 50, so repeats push real problems out.
- **Why the tests miss it:** the fake keeps a stray's key across `loadAll` (`AppRootFakes.swift:101`).
- **Fix:** key `strayNoted` by something stable across loads (the stray's `profileID` plus owner, cleared when no stray of that profile is live), or keep keys stable in `MS` by matching the configuration's identifier. Test: a reload with re-keyed strays posts nothing new.

### L2. The note says "is waiting, stop it" about strays that are not waiting
- **Where:** `CS:721-722`. The condition is "stray `.connecting`" and "addressable profile active".
- **Why it matters:** the extension keeps a stray waiting only beside a session with live `includeAllNetworks`. In the other cases the same statuses mean something else:
  - the addressable session's live flag is weakened and the stray has the kill switch: the stray is the protective replacement (the case the stop was removed for). The note tells the user to stop it;
  - the profile has no kill switch: the stray is refused (222) within moments, and the note stays behind about something that is gone.
- **Effect:** wrong advice in Diagnostics only; the app does nothing itself. Hence LOW.
- **Fix:** post only when the addressable manager's flags say `includeAllNetworks` and its status is `.connected` (the `managerKillSwitch` read), or soften the copy ("may be waiting").

### L3. An invalidated preempting start still takes the incumbent down
- **Where:** `TC:281` (the check runs only after `endForReplacement` returns), `TC:1680` (revision match).
- **Scenario (probe 2):** split B is connected. Kill-switch profile A's start (configuration revision 1) preempts it and holds the reservation during B's teardown. A is provisioned at revision 2 in that window (an edit saved in the app while NE's on-demand start of A is in flight).
  - B is cancelled with 223 ("another profile with the kill switch took over"); A's start ends `.startCancelled`: both down.
  - Before this commit A would have started on the new payload (`runStarting` accepts an older configuration revision, `TC:551`) and connected with the kill switch.
- **Same for removal and wipe (probe 1),** where A must not start anyway and B's teardown can't be undone.
- **Why LOW:** a window of the teardown's length (up to about 6 s), a failed kill-switch start is what `endWaitingStart` already produces for a pending session, and on-demand starts A again.
- **Fix:** either leave the reservation holder out of the revision invalidation (`reservation?.lease == g.lease`; this would also give `GuardedStart.lease` a use), or accept it and say so in DESIGN D10.3-9. Either way assert B's outcome in `aPreemptingStartEndsWhenItsProfileIsRemovedDuringTheTeardown` (it checks only A).

### L4. Two latch lines have no test
- **`TC:337`** (a start without the flag that is latched at admission throws): mutation l2 removes it with all tests green. Without it such a start enters a hold and never completes. Reachable when an on-demand start without the flag waits on a `.stopping` session (`TC:302`) while a latch of its profile is installed.
- **`TC:262-265`** (the entry check): mutation l3 removes it with all tests green (probably the implementer's "L3"). It is not purely redundant with the admission read: without it a latched start without the flag goes through the guard first (a 222 and a recorded refusal beside a running session, or a stale session's teardown) before it fails.
- **Fix:** one test per line: a latched on-demand start without the flag beside a running session fails with the latch's code and records no refusal; a latch installed while such a start waits on a `.stopping` session makes it throw.

## NIT

- **N1. `GuardedStart.lease` is never read** (`TC:220`). The matches use key, owner uid and revision only. Drop it or use it (L3).
- **N2. Three survivors are equivalent or layered.** g9 (the entry is never removed: a leak and spurious wakes only), g10 (an invalidated start marked again: only the detail text changes), k5 (the first `keepIf`: covered by the read after the I/O, as in round 5).
- **N3. A partial removal skips the invalidation** (`EngineServiceBackend.swift:31-33`, not new). If the credential delete throws after the payload delete, `profileRemoved` isn't called, so neither the pending session nor the waiters end. Call it before rethrowing.
- **N4. DESIGN D10.3-7 and D10.3-8 still say the stray is stopped.** They are history and D10.3-9 supersedes them; a "(removed in round 5)" would save a reader the search.

## Answers to the questions asked

- **Anything left of the stray stop?** No. `stopStrayDuplicates`, `stopStray` (protocol, default, NE store, observable store), `strayStopsIssued`, `strayStopRetry` and the fake's recorder are gone; no caller, test or doc line outside the history entries (N4) refers to them. The app has no code path that stops a stray.
- **Can invalidation end the wrong start?** No. Matches are exact (`ProfileKey` for removal, key and strictly higher revision for a provision, owner uid for a wipe); mutations g2a, g2b, g3, g3a, g4 and g6 are all caught. An admitted start keeps its entry until `start` returns, and marking it has no effect (the session path, `endWaitingStart`, handles it).
- **Can it miss one?** No. Every start registers synchronously before its first suspension, and the check at the loop's top runs after each of the three suspensions (wait, preemption, stale teardown).
- **Can it race admission?** No. Between the loop's last check and `beginStart` nothing suspends, and invalidation and the wake run in one actor turn. In the backend's window between the payload delete and `profileRemoved`, an admitted waiter is a pending session and `endWaitingStart` ends it.
- **Latch at admission vs hold semantics?** Consistent. With the flag a latched on-demand start is admitted and held (closed), never failed; without it, it fails. A hard latch cleared, a backoff latch expired or a latch installed during the wait is read as it is at admission (l1 caught by five tests). A latched kill-switch on-demand start still preempts a split session and then sits in its hold: closed, and unchanged from before.
- **Code 224, copy and accessibility?** Complete: message, reason fragment and the VoiceOver "because" fragment, EN and DE, in all three `ErrorCopy` switches (`ErrorCopy.swift:64, 126, 189`); the German subordinate clause is verb-final as "weil …" needs. Row 7 reads "Work stopped: another LockPlus start interrupted its connection. No traffic leaves this Mac." and the announcement ends "Disconnect to restore internet.", both true for the held session. 224 is only ever a hold reason, never a recorded last error, so no freshness logic in the app needs it.
- **Stray status change runs `restoreIfIdle`?** Safe. The heal's save is still conditional on `.connected` and `!mutationBlocked` when issued, and the restore is guarded by `isBusy`, so a stray that begins (rather than ends) triggers nothing.

## Mutations

| Mutation | Result |
|---|---|
| g1 loop never checks the invalidation | caught |
| g2 `profileRemoved` doesn't invalidate | caught |
| g2a removal matches the profile ID only (another user's namesake) | caught |
| g2b removal invalidates every start | caught |
| g3 provision invalidates regardless of revision | caught |
| g3a provision invalidates at an equal revision | caught |
| g4 provision invalidates regardless of key | caught |
| g4a provision doesn't invalidate | caught |
| g5 wipe doesn't invalidate | caught |
| g6 wipe invalidates every uid | caught |
| g8 invalidation doesn't wake | caught |
| g9 the entry is never removed | survives (equivalent: leak) |
| g10 an invalidated start is marked again | survives (equivalent) |
| l1 no latch read at admission | caught |
| l2 a latched start without the flag isn't thrown at admission | **survives** (L4) |
| l3 entry latch check removed | **survives** (L4) |
| l4 the latch applies to manual starts | caught (run exits 1; failing test not identified from the output) |
| l5 entry: a latched kill-switch start is thrown too | caught |
| k1 kept preemption held as 223 | caught |
| k2 rollback removes by id only (trimmed entry lost) | caught |
| k3 rollback keeps the 223 (round 5's f3) | caught |
| k4 rollback not saved | caught |
| k5 first `keepIf` removed | survives (layer) |
| k6, k7 either hold uses the error's code | caught (both) |

## Previous findings

| Source | Status |
|---|---|
| Codex 1 (HIGH) = Fable L1, stray stop hits the replacement | Fixed by removal. Residual (a pending duplicate keeps the app busy) accepted in DESIGN §20 risk 27. See L2 for the note's wording in that same case. |
| Codex 2, waiters survive invalidation | Fixed: `guardedStarts`, tests through the real backend (remove, higher revision, wipe). See L3. |
| Codex 3, a stray's end doesn't resume the heal | Fixed: `strayStatusChanged` runs `restoreIfIdle`; test with no other event. |
| Codex 4 = Fable N4, no timer for the 10 s retry | Gone with the stop. |
| Codex 5, stale latch after the wait | Fixed: `activeLatch` at admission; both directions tested. See L4. |
| Codex 6 = Fable N1, kept preemption says 223 | Fixed: 224 in the phase, the snapshot and the copy. |
| Fable L2, 223 rollback untested | Fixed: probe 3 is a test; k3 is caught. |
| Fable N2, trimmed summary lost in the rollback | Fixed: the ring is restored whole; k2 is caught with a full ring. |
| Fable N3, cached status in the stray check | Gone with the stop (the note still prefers the cached status, harmless there). |
| Fable N5, guard halves and equivalent mutations | Unchanged, not re-run. |

## Scratch left behind

`<build dir>/guard-review/`: `mut` (package copy, sources match the repo, no probe file left in it), `mut-tools/mutate7.py`, `mut-tools/R6Probe.swift`, `mutate7.out`, `probe7.out`. The build output (`spm7`) is deleted. All safe to delete.

---

**Fixes.** `dc6ad9df` (conditional idle-path mutations, invalidation committed with the payload, precise stray note).
