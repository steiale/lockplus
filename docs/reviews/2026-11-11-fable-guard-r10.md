# Verification round 9: start guard round 8 fixes (d46a0cb2)

Read-only, 2026-11-11, HEAD d46a0cb2. Nothing edited or committed in the repo.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `PS` = `App/Stores/ProfilesStore.swift`.

## Verdict

No HIGH, no MEDIUM. The round 8 MEDIUM/HIGH (forged `pendingRollbacks`) is closed. Two LOWs and three NITs remain; none of them lets a kill-switch profile run open or bypasses replay detection.

- L1 is a small regression from this commit (a false "took over" line); the fix is one condition.
- L2 existed in 2.0.0 and is not touched by this commit; it is a design item to accept or track.

I would release with L1 fixed or accepted.

What was run:
- `swift test` on the whole TunnelEngine package in a scratch copy at d46a0cb2: 351 tests pass.
- Three mutants of the `TC:327-332` change against `ControllerProviderGuardTests` (results under "Mutations").
- The app suite (`Tests/LockPlusTests`) was read, not run. Every app-side finding below is traced from the code, not demonstrated.

## Replay detection: can same-user code still bypass it?

No, not through the rollback marker.

- `rollbackPending` (`PS:392-395`) reads three things: the private in-memory dictionary `pendingRollbacks` (`PS:388`), the authenticated metadata (`p.metaRevision`, `p.payloadRevision`), and the NE manager's stored revisions.
- The dictionary is written in one place only (`PS:538`, the skipped rollback) and cleared at `PS:232`, `233`, `495`, `544`, `739`. Nothing seeds it from disk, settings, the environment or a debug hook.
- `AppSettings` no longer has the property, the decoder line or a coding key. A `pendingRollbacks` key in an existing settings.json is ignored and dropped at the next write.
- With a marker for revision N in memory, the exemption applies only to a metadata file at exactly N with the manager at N+1 and the same payload revision. An older authentic file has a different revision and is quarantined. The chain across launches from round 8 is gone, because the marker doesn't survive a launch.
- Same-user code can provoke a marker (make the metadata write fail and start something during the rollback). That gains nothing: the result is the rollback to the metadata the user already had, and the user was shown the failure.
- After a relaunch in that state the profile is quarantined and the manager is left as it is (tested). That is the accepted fail-closed case in D10.3-9.

One related gap in the same control is older than this commit: L2.

## LOW

### L1. A sticky 223 from the previous attempt is shown at an unrelated later end (introduced by 2.0.1, d46a0cb2)
- **Where:** `CS:1022-1023` (223 now skips the generic filter), `CS:1035-1037` (its own check: 30 s before this disconnect).
- **What changed:** before this commit the generic filter dropped any LockPlus error recorded more than 1 s before the attempt started. For 223 the only bound left is "no older than 30 s before this disconnect". The extension keeps `lastErrors` until the profile is removed (`TC:1745`), and `fetchLastDisconnectError` is sticky.
- **Scenario:**
  1. Work's kill-switch start ends Split with 223 at t0.
  2. Work ends. Split is started again and connects at t0+10.
  3. Split is stopped outside the app (System Settings, `scutil --nc stop`, an on-demand disconnect) at t0+25.
  4. The app reads the sticky 223, finds it within 30 s, and shows "Another LockPlus profile with the kill switch took over", the Diagnostics line, the end note and "stopped unexpectedly". Nothing took over.
- **Evidence:** `aStaleSupersededAtALaterStopShowsNoTakeOverLine` passes only because it dates the 223 one hour back. With `-20` it would pass at the parent commit and fail here (traced, not run).
- **Why LOW:** display only, and it needs a second end within 30 s of a real 223.
- **Fix:** Codex L4 is about an attempt that never connected. Keep the generic filter for a session that was connected: add `|| wasConnected` to the 223 exemption (`ns.code != 223 || wasConnected`). Test: the existing stale test with `at: -20`.

### L2. A metadata revision is reused after a failed write, so an authentic same-revision file with other content can exist (pre-existing in 2.0.0)
- **Where:** `PS:516-546` (`updateMetadata` always uses `old.metaRevision + 1`), `App/Stores/AppDataStore.swift:36-57` (`AtomicFile.write`: the MAC'd temp file is in the profiles directory before the rename), `PS:397-406` (an equal revision with other flags is "drift", healed from the metadata).
- **Scenario:**
  1. The kill switch is on, metadata at N. The user turns it off. Same-user code has made the metadata file immutable (`chflags uchg`), so the rename fails. It copies the temp file first: an authentic N+1 file with the kill switch off.
  2. The app rolls the manager back and shows the error. The user leaves the kill switch on.
  3. Later the user renames the profile or edits its notes: a different N+1, kill switch on, on both sides.
  4. The attacker swaps in its N+1 file. Same revision, so not a replay. `load()` sees flags that differ, logs a drift and saves the manager from the metadata: kill switch off, with no Diagnostics note.
- **Why LOW:** the user must have asked for exactly that weakening once and then given it up, and the attacker must win the copy. It is the N6 attacker, though, and the result is a silent downgrade.
- **Confidence:** traced from the code. The rename failing on an immutable target is standard BSD behaviour; I did not run it.
- **Fix:** never reuse a burned revision.
  - Cheap part: keep an in-memory high-water mark per profile and use `max(old.metaRevision, burned) + 1`. That closes it within one run.
  - Across a relaunch it needs a durable mark that same-user code can't write (the NE manager's provider configuration), which is a 2.1 design item.
- **Recommendation:** accept for 2.0.1, record it in D10.3-9, track for 2.1.

## NIT

- **N1. Fable r8 N4 is only partly fixed** (`PS:526-528`, `PS:544`). The manager save is now forced while a rollback is pending, but `saveManagerUnlessBlocked` returns false when something is busy, which is the very condition that made the rollback skip. The metadata then commits at N+1, the marker is cleared, and the manager still holds the failed change at N+1: same revision, other content. A flag difference is healed as "drift" with the wrong log line; a name difference stays. Fix: while a marker exists, bump the revision by two (`if pendingRollbacks[id] != nil { p.metaRevision += 1 }` before the existing increment), so the manager is plainly behind. This is also the in-memory half of L2's fix. Introduced by 2.0.1.
- **N2. No test has a third start waiting on a vetoed preemptor's reservation** (`TC:331`). Mutant m3 (release without `wakeWaiters()`) survives. In the pending-incumbent veto path (`TC:468-471`) that wake is the only one. Introduced by 2.0.1.
- **N3. `TC:328` is redundant.** Mutant m2 (line removed) survives because the next iteration's `.wait` branch throws the same error (`TC:335`), or the start is refused. Harmless; remove it or leave it.

Not counted: `namingTheBlocker` (`CS:1848-1851`) keeps "Another LockPlus profile is connected. Disconnect it first." when one of the user's own profiles is active while another user's start is the real blocker. That only happens during a switch, which disconnects it anyway.

## Previous findings

| Source | Status |
|---|---|
| Fable M1 / Codex H1, forged `pendingRollbacks` | Fixed: in memory only, payload revision and one-ahead conditions, test with a forged settings key (quarantine, manager unchanged). |
| Codex M3, one incomplete reload drops the record | Fixed (`PS:231-234`): cleared only when the manager is seen at the metadata revision, the metadata moved on, or on Delete. Tested with a missing manager. |
| Relaunch with a rollback pending | Accepted, in D10.3-9: quarantined, fail closed. Tested. |
| Fable L1, veto-then-provision binds | Fixed (`TC:327-332`). My probe P1 is now a test; mutant m1 is killed by it. |
| Fable L2, wrong blocker copy | Fixed (`CS:1302`, `CS:1399`, `CS:1848`); asserted in two tests. |
| Fable L3 / Codex M2, automatic mark lost in a network wait | Fixed: `Pending.automatic` is carried by `arm` (`CS:1606`), set in both branches of `startNow` (`CS:1267`, `1271`), checked at `CS:1209`, `1311`, `1334`. Test: Work is never stopped. |
| Codex L4, generic filter hides a 223 | Fixed for the reported case; over-corrected for a connected session (L1 above). |
| Fable N1, wider predicate in `prepareForStart` | Fixed (`AppEnvironment.swift:191`, `CS:1422`). No test (see Mutations). |
| Fable N2, skipped retry uses up the repair | Fixed (`CS:1064`, `CS:1284`). |
| Fable N3, pause before the busy check | Fixed (`CS:1311`). |
| Fable N4, same revision with other content | Partly fixed (N1 above). |

`Pending.automatic` was also checked for sticking to a later attempt. The user's Connect clears it (`CS:1200`). An entry it survives on is the same attempt's teardown or restart hold, where staying conservative is right.

## Mutations

Run by me (TunnelEngine, scratch copy):

| Mutant | Result |
|---|---|
| m1: no reservation release after a veto (`TC:331`) | Killed by `aVetoedPreemptorIsInvalidatedByALaterRevision`. |
| m2: no `staleHolder()` throw in the veto block (`TC:328`) | Survives. Equivalent (N3). |
| m3: release without `wakeWaiters()` (`TC:331`) | Survives. Test gap (N2). |

The implementer's K1, K5, N1 and N4: their definitions and reasons were not in my brief and I found no round 9 mutation file, so I can't judge K1 and K5 as written. What I can say from the code:

- **N1** (taken as: `prepareForStart` back to the unfiltered predicate). Survival is expected: no test has an own profile `.connecting` during another's prepare. It is testable (a profile behind its manager, another own profile emitted `.connecting`, expect a switch and not a failure). A NIT-level behaviour, so acceptable for release.
- **N4** (taken as: `|| pendingRollbacks[id] != nil` removed). Survival is expected: no test edits a profile while a rollback is pending. The fix itself is incomplete (N1 above), so a test should come with the revision bump.
- App-side mutants of this commit that I judge equivalent or harmless, in case K1 and K5 are among them:
  - dropping `&& s.revision == p.payloadRevision` (`PS:394`): unreachable with an in-memory marker, since `replacePayload` clears it on commit and nothing else moves the payload revision. Defence in depth.
  - dropping the clears at `PS:495`, `PS:544` or `PS:739`: `load()` clears on a moved revision anyway, and a deleted profile's ID is never reused.
  - dropping `PS:233`: the marker lingers but can't apply once the manager is at the metadata revision.
  - dropping `CS:1311`: caught later at `CS:1334`; only the pause's side effect differs.
- One I would not call equivalent: dropping `CS:1200` (the user's Connect clears `automatic`). It is reachable over the profile's own `.awaitingRestart` entry and would make a user's Connect give up instead of switching. If that is K1 or K5, it deserves a test.

## Scratch left behind

`<build dir>/guard-review/`: `mut` (package sources at d46a0cb2, unmodified), `r9-baseline.out`, `r9-m1.out`, `r9-m2.out`, `r9-m3.out`. The build output (`spm10`) is deleted. All safe to delete.

---

**Fixes.** `12552857` (display and test fixes before release).
