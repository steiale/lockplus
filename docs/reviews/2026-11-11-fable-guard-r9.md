# Verification round 8: start guard round 7 fixes (f3837f8e, 175a8999)

Read-only, 2026-11-11, HEAD 175a8999. Nothing edited or committed in the repo.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `PS` = `App/Stores/ProfilesStore.swift`, `MS` = `App/Stores/ManagerStore.swift`.

## Verdict

Not release-clean: one MEDIUM, introduced by 175a8999. No HIGH. Three LOWs and four NITs.

The MEDIUM is that `AppSettings.pendingRollbacks` lets same-user code switch off the metadata replay check (DESIGN §3.4 N6). The fix is small.

What was run:
- `swift test` on the whole TunnelEngine package in a scratch copy at HEAD (sources identical to the repo): all 350 tests pass, plus 2 probes.
- 2 probe tests (`mut-tools/R8Probe.swift`, `probe9.out`): P1 confirms L1 below; P2 confirms the Codex M3 fix for a same-profile duplicate.
- The app suite (`Tests/LockPlusTests`) was read, not run. M1, L2, L3 and the NITs are traced from the code.
- No mutation run this round. Nothing ran on NE.

## MEDIUM

### M1. A forged `pendingRollbacks` entry in settings.json suppresses replay detection (introduced by 2.0.1, 175a8999)
- **Where:** `PS:386-389` (`rollbackPending`), `PS:141` (`load()` skips the quarantine), `PS:544` (`managerIsBehind` returns true), `App/Model/AppSettings.swift:139`.
- **Who can write it:** settings.json is plain JSON, 0600, with no MAC (`App/Stores/AppDataStore.swift`, `SettingsFileStore`). Any same-user process can write it. That is the attacker N6 names (DESIGN line 1391): same-user code restoring an older, validly MAC'd metadata file, "e.g. one from before the user turned the kill switch on". The control relies on the reference copy being the NE manager, "which same-user code cannot write". The new exemption is keyed on a file that same-user code can write.
- **Scenario:**
  1. The user turns the kill switch on: metadata and manager go to revision N+1.
  2. While LockPlus is not running, the attacker restores the authentic revision N metadata file and adds `pendingRollbacks: {<profile>: N}` to settings.json.
  3. At launch `load()` sees `isReplay` true but `rollbackPending` true, so there is no quarantine and no "settings were changed outside LockPlus".
  4. `managerIsBehind` is true, so the idle sync (or `prepareForStart`) saves the manager from the old metadata: `includeAllNetworks` off, with no note.
  5. The record is then pruned, leaving no trace.
- **Is "exactly one revision ahead" tight?** Not enough:
  - It is one step per launch, and it chains. After step 4 the manager is at N, so revision N-1 plus a record for N-1 works at the next launch. An attacker who kept each intermediate file can walk back any distance.
  - It ignores the payload half. `rollbackPending` compares only `metaRev`, yet it exempts all of `isReplay`, including `p.payloadRevision < s.revision`. `updateMetadata` never changes the payload revision, so a legitimate record never needs that.
- **A stale legitimate record** is not a problem: it only applies while metadata is at r and the manager at r+1, and `load()` prunes it otherwise.
- **Fix (either):**
  - Smallest: keep the marker in memory only (a dictionary on `ProfilesStore`). After a relaunch in that state the profile is quarantined as it was before round 7. That is fail closed, and needs a failed metadata write, a start during the rollback and a quit before idle.
  - Durable: store the marker in the data-protection keychain through `SecretItemStore`, which same-user code can't write. A MAC'd file is not enough, because a captured marker can be replayed.
  - Either way, also require `s.revision == p.payloadRevision` in `rollbackPending`.
- **Test:** relaunch with an older authentic metadata file and a hand-written record; expect quarantine and an unchanged manager.

## LOW

### L1. Fable r7 L1 is closed in one order only (introduced by 2.0.1)
- **Where:** `TC:1719-1724` (the holder is flagged `staleRevision`, not invalidated, and nobody is woken), `TC:279-281` and `TC:302/327/330` (`staleHolder()` is read only on the way into a wait).
- **Scenario (probe P1, confirmed):** the same set-up as r7 L1, but the veto comes first. The kill-switch duplicate K (revision 1) preempts A, A regains the flag during the teardown, A is kept (224) and K waits while still holding the reservation. Then A is provisioned at revision 2. K is still "the holder", so it is exempted and flagged, but it is already waiting. When A ends, K leaves the loop through `session == nil`, binds, and runs the revision 2 payload under the revision 1 configuration. Probe output: `after A stopped: binds: 2 K bound: true`.
- **The shipped test** (`anExemptedHolderWhosePreemptionIsVetoedEnds`) covers only provision-then-veto.
- **Why LOW:** as in r7. It needs a duplicate, a weakened flag, its return and a provision.
- **Fix:** give the reservation back when the preemption is vetoed (after `endForReplacement`, if `session != nil` and the reservation is ours: `reservation = nil; wakeWaiters()`). K is then a plain waiter and any later revision invalidates it. Keep the existing `staleHolder()` checks for the other order. Alternatively check `staleHolder()` at the loop top once the start has waited, and wake waiters when a holder is flagged. Test: P1 as a test, expecting `.startCancelled` and no second bind.

### L2. The app's own `.anotherTunnelActive` names the wrong blocker (introduced by 2.0.1, f3837f8e)
- **Where:** `PS:595`, `PS:605` (`prepareForStart`), `CS:1365` (cross-pause), shown through `CS:1819` (`fail`) and `App/UI/State/ErrorCopy.swift:57-62`.
- **Is failing the start correct?** Yes. The save would land inside another configuration's pending start (E2E-3), and failing is fail closed.
- **Is it truthful?** Not in the usual case. `otherStartPending` is true mostly for another user's configuration or a stray in `.connecting`. `fail()` passes the detail "another configuration is starting", which is not `unseenSessionDetail`, so the user reads "Another LockPlus profile is connected. Disconnect it first." They have nothing to disconnect, and nothing is connected. The extension-refusal path already maps this case (`CS:1032`).
- **Fix:** in `runStart`'s catch and in `failPause`, when the code is `.anotherTunnelActive` and `!anotherProfileActive(besides: id)`, set the detail to `LPErrorCode.unseenSessionDetail`. Test: `prepareForStartDoesNotSaveInsideAnotherUsersPendingStart` also asserts `errorDetail`.

### L3. The automatic retry loses its "automatic" mark when it has to wait for a network (behaviour from 2.0.0; residual of the round 7 fix for Codex M1)
- **Where:** `CS:1257-1260` (`startNow(_:automatic:)` returns into `waitForNetwork` before the token is marked), `CS:1322-1325` (the same inside `runStart`; the `defer` drops the mark), `CS:803-810` (the waiting entry resumes through `beginStart`, which switches).
- **Scenario:** A fails with `profileNotProvisioned`, and the network drops during the re-provision. The retry becomes an ordinary `.waitingForNetwork` entry. The network returns and NE's on-demand starts kill-switch profile B with it. A's entry resumes, sees B active and calls `beginSwitch`, which stops B with an app-issued stop. That is the bypass Codex M1 described.
- **Why LOW:** needs a network loss inside the recovery window and an on-demand start at its return.
- **Fix:** a background retry doesn't wait for a network: with `automatic` and `networkAvailable == false`, skip with the same note. Or carry `automatic` on the `Pending` entry and honour it in `beginStart`.

## NIT

- **N1. `prepareForStart`'s predicate doesn't exclude this user's own profiles; the cross-pause does** (`PS:593` against `CS:1360-1363`). NE's on-demand start of another own profile that is `.connecting` during the prepare fails a behind profile's start, where a profile that is not behind switches it out (`CS:1310`). The comment "it would be refused beside it anyway" is wrong for own profiles: the app switches. Narrow, because `connect()` allows one start at a time. Pass the same `besides: ours`. Introduced by 2.0.1.
- **N2. A skipped automatic retry uses up `retriedAfterProvision`** (`CS:1052`, cleared only at `CS:384`). The provision itself was done, so nothing is lost; a later failure of the same kind gets no second repair. Remove the ID on the skip. Introduced by 2.0.1.
- **N3. The automatic start pauses the others' on-demand before it finds another session active** (`CS:1290` before `CS:1310`). The other session's on-demand then stays off until it ends. Check `othersBusy(except: id)` for an automatic token before `pauseOtherOnDemand`. Introduced by 2.0.1.
- **N4. A metadata change that doesn't touch the manager, made while a rollback is pending, leaves both sides at the same revision with different content** (`PS:513-516`: a notes edit, or a deferred save). A policy difference is then healed as "drift" with the wrong log line; a name difference stays until the next save. Force `managerRelevant` while `rollbackPending`. This goes away with M1's in-memory fix only if the same guard is kept. Introduced by 2.0.1.

## Answers to the questions asked

- **`pendingRollbacks`: can a forged or stale record suppress replay detection?** Forged: yes (M1). Stale: no.
- **Who can write AppSettings?** Any process of the same user; the file has no integrity protection.
- **Is "exactly one revision ahead" tight?** No: it chains across launches and it ignores the payload revision (M1).
- **`prepareForStart` failing with `.anotherTunnelActive`:** correct and fail closed; the copy is wrong for another user's or a stray's start (L2), and the predicate is wider than the pause's (N1).
- **Conditional cross-pause: can a skipped pause leave two on-demand configurations active?** No. A skipped pause throws `PauseFailure`, the start fails and `startVPNTunnel` is never issued, so no start of ours runs beside an enabled on-demand configuration. Managers paused earlier in the loop stay recorded and come back at idle. `failPause` drops the record of the one that stayed on. In `beginSwitch` the active session is not stopped.
- **Recovery skip: lost recoveries?** No. The provision has completed before the skip, Diagnostics says so, and the entry is cleared with `restoreIfIdle`. Only the once-per-profile budget is spent (N2). The residual is L3.

## Previous findings

| Source | Status |
|---|---|
| Fable L1, exempted holder becomes a waiter | Partly fixed: provision-then-veto ends `.startCancelled` (test). Veto-then-provision still binds (L1, probe P1). |
| Fable L2, user-action saves checked only outside the serialization | Fixed: `saveManagerUnlessBlocked`, Delete's removal and the rollback are conditional; tests for policy save and Delete. The skipped rollback's record is M1. |
| Fable L3, own restore skipped beside any live configuration | Fixed: decided (`otherStartPending`, a connected one doesn't block), in D10.3-9, bound to token and own status. |
| Fable N1, same-revision provision ends an older pending start | Accepted, in D10.3-9. |
| Fable N2, mutations caught only by a hang | Fixed: `.timeLimit(.minutes(1))` on both suites. |
| Fable N3, b5 survives | Fixed: `aFailedPayloadDeleteLeavesTheWaiterWaiting`. |
| Fable N4, re-minted stray key reported as removed | Fixed (`PS:172-174`). |
| Fable N5, duplicated bodies | Fixed (`MS:546-548`, `MS:573-575`); bodies unchanged. |
| Fable N6, partial provision never retried | Fixed in memory (`provisionIncomplete`); limits in D10.3-9. |
| Codex M1, recovery stops a newer session | Fixed (attempt, entry, `othersBusy`, automatic token; test). Residual: L3. |
| Codex M2, stale "behind" | Fixed: `liveSafe`/`behindSafe` recomputed inside, plus the metadata revision check. |
| Codex M3, pending incumbent not re-read | Fixed (`TC:459-467`): same read as the verdict, no suspension, 223 withdrawn; test and probe P2. |
| Codex M4, foreground saves and own restore | Fixed (see Fable L2, L3). |
| Codex L5, skipped drift repair used up | Fixed (`PS:228`). |
| Codex L6, refused split duplicate noted as waiting | Fixed (`CS:729`, `StraySnapshot.includeAllNetworks`; test). |

## Scratch left behind

`<build dir>/guard-review/`: `mut` (package copy at HEAD, identical to the repo, no probe file in it), `mut-tools/R8Probe.swift`, `probe9.out`. The build output (`spm9`) is deleted. All safe to delete.

---

**Fixes.** `d46a0cb2` (the rollback marker is in memory only, automatic retry carried through network waits, a vetoed preemptor releases its reservation).
