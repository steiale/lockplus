# Final security spot check: 12552857 (last commit before 2.0.1)

Read-only, 2026-11-11, HEAD 12552857. Nothing edited or committed in the repo.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `ESB` = `Packages/TunnelEngine/Sources/TunnelEngine/Service/EngineServiceBackend.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `PS` = `App/Stores/ProfilesStore.swift`.

## Verdict

Release-clean for security: no HIGH, no MEDIUM. One LOW (fails closed, a double-failure corner introduced by this commit) and two NITs. Nothing in the diff lets a caller read another user's data, lets a kill-switch profile run open, or bypasses replay detection.

What was run:
- `swift test` on the TunnelEngine package at 12552857: 353 tests pass, including the two new ones. The scratch build (`spm11`) is deleted.
- The app suite (`Tests/LockPlusTests`) needs xcodebuild and was read, not run. The LOW below is traced from the code, not demonstrated.

## 1. `tunnelSnapshot` fallback for an unprovisioned profile (`ESB:82-88`, `TC:1480-1484`)

Clean.

- **Caller identity:** `ownerUID` is `peer.uid`, which is `c.effectiveUserIdentifier` of the XPC connection (`XPC/TunnelServiceListener.swift:70`). The request carries only the profile ID.
- **What is returned:** `lastError` and `lastErrorAt` of exactly `(peer.uid, profileID)`, phase `.idle`, epoch 0. No latch, no session data, even when that same profile is the running session of another uid.
- **Other users' data:** not reachable. The lookup key always contains the caller's uid.
- **Oracle:** none on other users' profiles. Both the provisioned check (`ESB:170-175`) and the fallback look only at the caller's own namespace, so the answer and its timing depend only on the caller's own state. The new test asserts that another uid asking for the same ID still gets `profileNotProvisioned`.
- **Timing:** the fallback adds one actor hop, taken only when the caller's own payload is missing.
- **Cleanup:** `profileRemoved` and `secretsWiped` clear the entries (`TC:1753`, `TC:1762`), so a removed profile's error doesn't linger.

See NIT 2 for the one pre-existing property this makes slightly more visible.

## 2. `visibleProfileActive` vs `anotherProfileActive`

Copy only, coordination unchanged.

- The three changed call sites (`CS:654`, `CS:1041`, `CS:1856`) only choose the error detail.
- That detail (`unseenSessionDetail`) is read in `App/UI/State/ErrorCopy.swift:58`, `120`, `183` and nowhere in control flow.
- The two coordination uses keep the global predicate (`CS:340`, `CS:668`).
- The `|| wasConnected` change at `CS:1030` is a display filter only (my r9 L1, fixed as proposed).

## 3. Revision bump by two while a rollback marker exists (`PS:522`)

It can't make a replay pass. In one corner it makes a legitimate state read as a replay: the LOW below.

- **Normal paths are right.** With the metadata at N, the manager at N+1 and the marker at N, an edit commits N+2. If the manager save lands, both are at N+2. If it is deferred, the manager is plainly behind and is re-saved. The new test covers the deferred case.
- **No new replay acceptance.** An older authentic file is still below the manager or the committed metadata. The same-revision temp file case (my r9 L2, accepted in DESIGN) is not widened.

### LOW: a second failed edit with a second skipped rollback quarantines the profile (introduced by 12552857)

- **Where:** `PS:522` (bump by two), `PS:541` (marker set to `old.metaRevision`), `PS:392-395` (`rollbackPending` accepts only the manager at marker + 1), `PS:141` (quarantine).
- **Scenario:**
  1. A rollback is pending: metadata N, manager N+1, marker N.
  2. The user edits again while idle. The manager is saved at N+2.
  3. The metadata write fails again (the cause of the first failure often persists).
  4. A start begins during that write, so the rollback is skipped again. The marker stays N, the manager stays at N+2.
  5. At the next `load()` the manager is two ahead, `rollbackPending` is false, `isReplay` is true, and the profile is quarantined with "settings were changed outside LockPlus".
- **Before this commit:** the second edit used N+1 again, the marker matched and the manager was healed.
- **Why LOW:** it fails closed, and it needs two metadata write failures plus two starts racing the rollback. It is the same end state DESIGN D10.3-9 already accepts for a relaunch, but here without one.
- **Fix:** keep the manager's revision in the marker (set it to `p.metaRevision` next to `old.metaRevision` at `PS:541`) and compare `s.metaRev` against that at `PS:394`. Test: the new `anEditWhileARollbackIsPendingSkipsTheBurnedRevision` with the second edit made idle, its metadata write failing and a start beginning in `onSave`.
- **Release:** I would ship and put it in PLAN-2.0.2.

## 4. Removal of the stale-holder check after a veto (`TC:328`)

Security-equivalent, not literally equivalent (NIT 1). A vetoed stale holder still never waits and never binds beside a live session.

- No suspension lies between the veto and the next loop iteration, so the actor's own state is unchanged.
- Same profile as the kept session: `.wait`, where `staleHolder()` throws `startCancelled` as before (`TC:335`). `anExemptedHolderWhosePreemptionIsVetoedEnds` still passes.
- Another profile: `.refuse`, see NIT 1.

## 5. Anything else

Nothing else changes security behaviour. The remaining diff is tests and DESIGN text.

## NIT

- **NIT 1. A vetoed stale holder of a different profile now ends with 222, not `startCancelled`** (`TC:328`, `TC:346`, `TC:399`). The refusal is also recorded under its key, so the app shows "another tunnel active" instead of a silent cancel. Both are true and neither binds. Two further differences exist only if the kept session's live flag or lease changes on another thread within that same synchronous stretch: the holder then preempts again or replaces a stale session and starts on the newest payload, which is what round 6 L3 already allows a holder. No action needed.
- **NIT 2. The refusal entry is written under the app-asserted key before any payload lookup** (`TC:399-403`, pre-existing, review N3). With the fallback, such an entry is now readable by the asserted uid without a payload. The content is a constant 222 and a time, and writing it needs a LockPlus configuration that asserts another uid, so there is nothing to gain. Noted for completeness.

## Scratch left behind

None from this pass (`spm11` deleted).

---

**Fixes.** None; this was the last check before release (`12552857`). The one LOW (fails closed, a double-failure corner) is carried to 2.0.2.
