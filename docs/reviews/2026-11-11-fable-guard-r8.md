# Verification round 7: start guard round 6 fixes (dc6ad9df)

Read-only, 2026-11-11, HEAD dc6ad9df. Nothing edited or committed in the repo.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `BE` = `Packages/TunnelEngine/Sources/TunnelEngine/Service/EngineServiceBackend.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `PS` = `App/Stores/ProfilesStore.swift`, `MS` = `App/Stores/ManagerStore.swift`.

## Verdict

Release-clean on HIGH and MEDIUM: none found. Three LOWs and six NITs. Every round 6 finding (mine and Codex's) is fixed.

What was run:
- `swift test` on the whole TunnelEngine package in a scratch copy at HEAD (sources identical to the repo): 347 + 14 tests pass.
- 17 mutations in that copy against the whole suite (`mut-tools/mutate8.py`, `mutate8.out`): 16 caught, 1 survives. Two of the 16 are caught only by a hang (N2).
- 4 probe tests (`mut-tools/R7Probe.swift`, `probe8.out`).
- A release build of TunnelEngine: 0 symbols of `installLatchForTesting`, `trackedInstanceCount` or `cancelRequestCount` in the release objects, 29 in the debug objects.
- The app suite (`Tests/LockPlusTests`) was read, not run. L2, L3, N4 and N5 are traced from the code.
- Nothing ran on NE.

## LOW

### L1. The exempted reservation holder can become a waiter of the old revision, and bind later
- **Where:** `TC:1698-1701` (the holder is left out of the revision invalidation, once), `TC:311-316` (the reservation stays when the preemption is vetoed).
- **Scenario (probe P1, confirmed):** profile A runs split. A duplicate configuration of A with the kill switch (revision 1) preempts it and holds the reservation. During the teardown A is provisioned at revision 2 (the holder is left out) and A's live flag comes back. The incumbent is kept (held, 224). The holder loops, gets `.wait` (same profile, protected incumbent) and now waits like any duplicate, still at revision 1. When the incumbent ends it binds and runs the revision 2 payload under the revision 1 configuration.
- **Control (probe P1b):** a plain waiter in the same end state ends with `.startCancelled`.
- **Why LOW:** this is Codex M2's outcome through a corner that needs a duplicate, a weakened flag, its return during the teardown and a provision in the same window. `runStarting` accepts that direction (`TC:551`).
- **Fix:** remember the exemption on the `GuardedStart` (e.g. `staleRevision = true`), and throw `.startCancelled` ("profile changed") when such a start is about to wait or when `endForReplacement` returns with the session still tracked. Test: P1 as a test, expecting no second bind.

### L2. The user-action saves still check their deferral only outside the serialization
- **Where:** `PS:297-306` (`saveManagerUnlessBlocked`: import, editor save, policy, rename), `PS:645-652` (Delete's `managers.remove`), `PS:479` (the rollback save in `updateMetadata`).
- **Scenario:** the user renames a profile while idle. The save queues behind an earlier mutation (a reload, another save). Before it gets the lock, NE's on-demand or another user's `scutil` starts a kill-switch configuration. The save lands inside that pending start. This is Codex M1 on the paths the commit didn't cover (it says "every idle-path mutation", which is true as written).
- **Why LOW:** needs a start made elsewhere inside the lock wait (an app-issued start waits in `waitUntilSettled` behind the queued mutation).
- **Fix:** `saveManagerUnlessBlocked` calls `managers.save(_, onlyIf:)` with its own predicate and returns false (deferred, `hasDeferredSync = true`) when skipped; Delete uses `remove(id, onlyIf: { !held(id) || stillOnDemand })` and defers to the orphan sweep; the rollback goes through the same conditional save. One test with `startBeginsWhileQueued`.

### L3. A start's own on-demand restore is now skipped beside any other live configuration, untested
- **Where:** `CS:1353-1356` (`restoreOwnOnDemand` passes `othersBusy(except: id)`), `CS:1750-1754`.
- **What changed:** before, this restore was unconditional ("its own on-demand belongs to its own start"). Now it is skipped when another user's session, a stray or another pending entry is live. The start goes on, so the profile runs its whole session with on-demand off, and the record is retried only once everything is idle.
- **Inconsistent with its neighbours:** `prepareForStart`'s `syncManager` and `pauseOtherOnDemand` in the same `runStart` still save unconditionally beside that same foreign session.
- **Test gap:** no test has another configuration live during the own restore. `aConnectOfAnotherProfileInsideAPendingStartIsIgnored` covers only the `except: id` half.
- **Fix:** decide which is meant. If the skip is: say so in DESIGN D10.3-9 and add a test (a foreign stray `.connecting`, connect the recorded auto profile: no save of it, record kept, restored after both end). If not: pass `{ false }` for the own restore.

## NIT

- **N1. A same-revision provision now ends a pending start whose configuration is older than the payload** (probe P2b: held kill-switch start, configuration 1, payload 2; a same-revision provision with credentials ends it, where it used to retry the hold through `credentialsUpdated`). `BE:148-152`, `TC:1697`. Hard to reach (the app re-provisions an equal revision only on a digest mismatch or at `CS:1053`). Say it in D10.3-9 or accept.
- **N2. Two mutations are caught only by a hang.** p7 (`payloadCommitted` doesn't end the pending session) and p10 (`profileProvisioned` doesn't call `payloadCommitted`) ran into the script's 300 s timeout with no failing assertion: some test outside the guard suite waits without a bound for that start to end. I didn't identify it. Give that suite `.timeLimit` like `ControllerProviderGuardTests`, or bound the wait.
- **N3. b5 survives:** `profileRemoved` moved before the payload delete passes every test. A failed payload delete would then end the starts of a profile that still exists. Add to `aPartialRemovalStillEndsTheWaiter` a case with the payload delete failing: the waiter keeps waiting.
- **N4. A stray removal with a key that a reload re-minted reports success.** `PS:165-170`: the predicate reads "not found" as "not live", `NEManagerStore.removeStray` returns for an unknown key, the result is `true` and nothing is deferred. Harmless (the next configuration change runs `load()` again), but `removed` is wrong. Treat a missing key as skipped.
- **N5. `remove(onlyIf:)` and `removeStray(onlyIf:)` repeat the bodies of the unconditional forms** (`MS:535-575`). Let the unconditional ones call the conditional ones with `{ true }`, as one place to change.
- **N6. Not from this commit: `reconcile` never retries a partial provision.** `PS:758-762` compares payload revision and digest only, so after "payload written, credential write failed" the extension keeps the old credentials until the next credential update, and the same-revision retry this commit handles is reached only through `CS:1053`.

## Answers to the questions asked

- **Predicate inside the lock: deadlock?** No. Every predicate is synchronous and reads only main-actor state (`pending`, `statuses`, the manager and stray snapshots, `inner.status`). It never takes the lock. `restoreTask` waits for the lock, and lock holders are NE operations that never wait for `restoreTask`.
- **Starvation of legitimate saves?** None found. Each predicate equals the pre-check its call site already had, so it can only fail where a start began during the wait. The one exception is L3. No spin: `restoreAgain` is set only after `!isBusy`.
- **A lost deferred sync?** No. Every skipped removal, sync and resave sets `hasDeferredSync`; a skipped restore keeps its record; both are picked up by `restoreIfIdle` at the status event that ends the start. `save(onlyIf:)` checks again after a stale-configuration reload (`MS:520-532`).
- **Can `payloadCommitted` end the running incumbent?** No. `endWaitingStart` requires `isWaitingBeforeConnected`; a connected session stays (`aDuplicateWaitingBesideAConnectedSessionEndsAtOnceWhenItsProfileChanges`).
- **The wrong start?** No. Key and strictly higher revision; p4, p5 and p6 are caught.
- **Does a waiting session at the same revision survive?** Yes (probe P2: still held; p6 caught). See N1 for one that is older than the payload.
- **Could a removed profile's start still bind through the holder exemption?** No. Removal and wipe have no exemption (p8, p9 caught) and the loop checks after `endForReplacement` returns, with nothing suspending before admission. The residual is the revision case in L1.
- **DEBUG-only hooks out of Release?** Yes: `#if DEBUG` at `TC:423-428`, `Config/Release.xcconfig:5` sets no conditions, and the release build has none of the symbols. The hook is internal and used only by one test.

## Mutations

| Mutation | Result |
|---|---|
| p1 `payloadCommitted` invalidates no guarded start | caught |
| p2 the holder is not left out | caught |
| p3 every start with a lease is left out | caught |
| p4 guarded starts: equal revision counts | caught |
| p5 guarded starts: key ignored | caught |
| p6 pending session: equal revision counts | caught |
| p7 pending session not ended by `payloadCommitted` | caught by a hang only (N2) |
| p8 removal leaves the holder out | caught |
| p9 wipe leaves the holder out | caught |
| p10 `profileProvisioned` doesn't call `payloadCommitted` | caught by a hang only (N2) |
| l2 a latched start without the flag isn't thrown at admission | caught (was a survivor) |
| l3 entry latch check removed | caught (was a survivor) |
| b1 a same-revision provision doesn't commit | caught |
| b2 provision: invalidation after the credential write | caught |
| b3 removal: invalidation after the credential delete | caught |
| b4 a higher revision only commits the payload | caught |
| b5 removal: invalidation before the payload delete | **survives** (N3) |

## Previous findings

| Source | Status |
|---|---|
| Codex M1, queued recovery saves inside a new start | Fixed for the restore, `load()`'s removals and syncs, `resaveOnDemand`; tests for each. Residual on user-action saves: L2. Side effect: L3. |
| Codex M2, partial provision skips invalidation | Fixed: committed with the payload, same-revision retry covered (b1, b2 caught). Corner: L1. |
| Codex L3 = Fable L1, note repeats per reload | Fixed: keyed by owner and profile; test re-mints keys three times. |
| Fable L2, note where nothing waits | Fixed: only beside `.connected` with `includeAllNetworks`; test for both other cases. |
| Fable L3, invalidated preemptor takes the incumbent down | Fixed for a revision change (holder left out, p2 caught); removal and wipe assert B's 223. Corner: L1. |
| Fable L4, two latch lines untested | Fixed: l2 and l3 are caught. |
| Fable N1, `GuardedStart.lease` unread | Fixed: used for the exemption. |
| Fable N2, equivalent survivors | Unchanged, not re-run. |
| Fable N3, partial removal skips invalidation | Fixed (b3 caught). |
| Fable N4, DESIGN D10.3-7/8 | Fixed: both marked. |

## Scratch left behind

`<build dir>/guard-review/`: `mut` (package copy, identical to the repo, no probe file in it), `mut-tools/mutate8.py`, `mut-tools/R7Probe.swift`, `mutate8.out`, `probe8.out`. The build output (`spm8`) is deleted. All safe to delete.

---

**Fixes.** `f3837f8e` (pending-incumbent re-read, stale holder ends, bound recovery, one pending-start predicate) and `175a8999` (a skipped manager rollback is recorded and retried, never read as a replay; the durable record in this commit was a mistake, see the overview).
