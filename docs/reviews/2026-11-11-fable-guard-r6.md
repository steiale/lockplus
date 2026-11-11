# Verification round 5: start guard round 4 fixes (1814d25a)

Read-only, 2026-11-11, HEAD 1814d25a. Nothing edited or committed in the repo.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `HOST` = `Packages/TunnelEngine/Sources/TunnelEngine/Host/`.

## Verdict

Release-clean on HIGH and MEDIUM: none found. One LOW in the stray stop (L1), one LOW test gap (L2) and five NITs.

Every finding of round 4 is fixed (my M1, L1–L3, N1–N5; Codex 1–5), with two partial residues listed as L1 and N1. I found no spin, no deadlock, no lost heal and no wrong rollback.

What was run:
- `swift test` on the guard, connected and start suites, in a scratch copy of the package at HEAD (sources identical to the repo): 147 tests pass.
- 46 mutations in that copy (`mut-tools/mutate6.py`, results in `mutate6.out`): 30 caught, 16 survive (table below).
- 3 probe tests (`mut-tools/R5Probe.swift`, output in `probe6.out`).
- The app suite (`Tests/LockPlusTests`) was read, not run. L1 and the app-side answers are traced from the code.
- Nothing ran on NE; no build contains this commit.

## LOW

### L1. The stray stop also stops a stray that is preempting, not waiting
- **Where:** `CS:720-721`. The stop needs only "stray `.connecting`" and "addressable configuration `.connected`".
- **Why it matters:** the extension keeps a stray waiting only when the addressable session has live `includeAllNetworks`. If it hasn't, a kill-switch stray preempts it (`TC:298`, live read), and a stray without the kill switch is refused by itself (222).
- **Scenario:** the addressable configuration of a kill-switch profile is connected with its live flags weakened (drift not healed: a heal that failed, a repeated drift, or the heal still blocked). Its stray duplicate with intact flags is started (`scutil --nc start`, System Settings, its own on-demand rule).
  - The extension preempts the addressable session; the app sees "stray connecting, addressable connected" and stops the stray.
  - Unless the stop lands before the stray's start reaches the controller, the addressable session is cancelled (223) and the stray is stopped or abandoned: both down, the Mac open.
  - Without the app's stop, the stray would have taken over with the kill switch.
- **Same shape, availability only:** the profile no longer has the kill switch and an older-revision stray still has it.
- **Preconditions:** a duplicate configuration of the profile, a flag difference between the two, and a start of the stray from outside the app. That is why it is LOW.
- **Fix:** stop a pending stray only when the addressable manager's own flags say `includeAllNetworks` (`managers.managers.first { $0.profileID == pid }?.flags?.includeAllNetworks == true`, as `managerKillSwitch` reads it). That is exactly the case in which the extension keeps the stray waiting.
- **Test:** a pending stray beside a connected addressable configuration without the flag is not stopped.

### L2. The 223 rollback in `finishEnding` has no test
- **Where:** `TC:444` (`persisted.lastErrors[key] = previousError`). Mutation f3 removes it with all tests green.
- **Detail:** the summary-save test covers the fatal path, which records no error; `aKeptPreemptedSessionCarriesNo223` enables the flag before the first read. The combination (a preemption whose incumbent gets the flag during the summary save) is untested.
- **The code is right:** probe 3 shows the session held, no cancel, no summary, `lastError` nil.
- **Fix:** add that probe as a test (the `setOnSave` barrier with a kill-switch start as the trigger).

## NIT

- **N1. A kept preempted session is held under code 223** (`TC:456`). The last error is no longer recorded (old N4), but the hold reason is `.blockedAfterFailure(.supersededByKillSwitch)` (probe 3). The app would say another kill-switch profile took over, although that start was refused. Use a neutral hold code for the preemption's keep.
- **N2. The summary rollback doesn't restore a trimmed entry** (`TC:443`, `TC:1292`). With 100 summaries stored, `appendSummary` drops the oldest before the rollback removes the new one, so one old summary is lost. Only in the flag-during-save race.
- **N3. The stray check prefers the cached status** (`CS:721`, `statuses[pid] ?? managers.status(pid)`). If the stray's `.connecting` is delivered before the addressable session's `.disconnecting`, a stray that is about to take over is stopped. Require the live `managers.status(pid) == .connected` as well.
- **N4. The 10 s retry has no timer** (`CS:719`). A repeat stop happens only at the next status event, launch or reload. A stray restarted inside the 10 s whose `.disconnected` was never delivered waits until then (the old L2 state: closed, app busy).
- **N5. Two guard halves and two equivalent mutations survive.** `session === s` and `phase == .stopping` (`TC:434`) each survive alone; removing both is caught. The identity half is the one that matters; the phase half is redundant with it today. f6 (no save of a 223 without a summary) and e1 (forget after the cancel) are equivalent as far as I can tell.

## Answers to the questions asked

- **holdProtection vs effectiveProtection, any spin?** No.
  - The verdict (`TC:298`) and the preemption's `keepIf` (`TC:411`) use the same live read, so a kept session is never preempted again in the same loop.
  - Mutations h3 and c13, which make the two reads differ, spin and time out, so the suite guards this.
- **Does the guard preempt something the hold logic would keep?** Yes, in one case, and it is safe.
  - A session with the start-time flag on and the live flag off, held after a fatal or withheld before Connected, is preempted by a kill-switch start of another profile (probes 1 and 2: 223, the kill-switch start connects).
  - NE isn't enforcing that session's flag, and a kill-switch session takes its place.
  - The reverse can't happen: the hold read is a superset of the live read, so nothing the guard keeps is cancelled by the hold logic.
- **Can the 10 s expiry stop something it shouldn't?** No. The expiry only allows a repeat; both conditions are evaluated again each time, and keys are fresh per load and pruned. The wrong stop that exists is L1, and it doesn't depend on the expiry.
- **Conditional save: deadlock or lost heal?** Neither.
  - The condition is synchronous and reads only `inner.status` and `mutationBlocked`; it never re-enters the serial lock.
  - A skipped save clears `healedLiveDrift` and sets `hasDeferredSync`, so `healLiveDrift` tries again at the next status event.
  - The condition is checked when the save is issued, not when NE applies it; that window is the residual DESIGN §20 risk 27 records.
- **Summary rollback?** Correct: summary and 223 are withdrawn and saved before the hold, all synchronous on the actor, so no XPC read can see the intermediate state. Residues: L2, N1, N2.
- **Bind under the lifecycle lock?** No deadlock found. Bind and cancel both run on the actor; publish holds the gate only for `providers.started`; `release` still takes only `state`.
- **Watermark removal on release?** Safe. `deinit` marks the instance stopped before the release, and `ProviderRef.bind` returns false once the provider is gone.

## Mutation survivors

The implementer's claim (only layered reads survive singly) holds for 11 of the 16 survivors. The other five are f3 (L2), the two guard halves and the two equivalent ones (N5).

| Mutation | Result |
|---|---|
| h1 `holdProtection` live-only (M1 reverted) | caught |
| h2, h2a–h2d `holdProtection` start-only, or one term dropped | caught (all five) |
| h3 preemption `keepIf` uses the hold read | caught (spin; timeout) |
| h4 verdict uses the hold read | caught |
| h5 verdict and `keepIf` both use the hold read | caught |
| f1 no re-read after the summary I/O | caught |
| f2 rollback keeps the summary | caught |
| f3 rollback keeps the 223 | **survives** (L2) |
| f4 rollback not saved | caught |
| f5 223 recorded although kept | caught |
| f6 no save of the 223 without a summary | survives (equivalent) |
| f7 223 never recorded for an ended preempted session | caught |
| f8 first `keepIf` removed | survives (layer: the read after the I/O) |
| c2 `holdEnding` doesn't wake | caught (was L3) |
| c3 `finishEnding` without its guard | caught (was L3) |
| c3a, c3b one half of that guard | survive (N5) |
| c14 `holdEnding` without `setReasserting` | caught |
| b1 `beginEnding` drops the prompt silently | caught |
| c5 fatal teardown never holds | caught |
| c5a fatal teardown `keepIf` live-only | survives (layer: entry guards) |
| c6, c6a `cancelAfterTeardown` entry start-only / live-only | survive (layer) |
| c7, c7a `afterConnectedFatal` start-only / live-only | survive (layer) |
| c8 budget expiry start-only | caught |
| c8a budget expiry live-only | survives (layer: arming) |
| c9, c9a `enterReasserting` start-only / live-only | survive (layer: expiry) |
| c10, c10a `resumeReassertBudget` start-only / live-only | survive (layer: expiry) |
| c11, c11a withhold start-only / live-only | caught (was L3) |
| c12, c12a latch start-only / live-only | caught (was L3) |
| c13 verdict start-only | caught (spin; timeout) |
| r1 bind ignores the watermark | caught |
| r9 bind outside the lifecycle gate | caught |
| r10 release keeps the watermark | caught |
| s1 `protectionChanged` is a no-op | caught (was L3) |
| m2 `forgetSession` doesn't wake | caught |
| e1 forget after the cancel | survives (equivalent) |

The layered groups are covered jointly: h1 flips every hold read to live-only at once and four tests fail.

## Previous findings

| Source | Status |
|---|---|
| Fable M1 | Fixed: `holdProtection` (`TC:363`) at every hold, withhold, latch and budget decision; five tests, both directions. |
| Fable L1 = Codex 1 (HIGH) | Fixed for the reported case: a connected or reasserting stray is never stopped; reverse-order test with 222. Residue: L1 above. |
| Fable L2 = Codex 4 | Fixed: per-attempt record, pruned, 10 s expiry, launch and reload passes; tests. See N4. |
| Fable L3 | Fixed: c2, c3, c11, c12 and s1 are caught now. |
| Fable N1 | Open by nature: KVO on NE is unmeasured (t9); the seat now logs it. |
| Fable N2 = Codex 5 | Fixed: `release` drops the watermark; churn test. |
| Fable N3 | Fixed: `resolveLivePrompt` in `beginEnding`; test. |
| Fable N4 | Fixed for the last error; the hold code still says 223 (N1 above). |
| Fable N5 | Fixed: the issue time is only a floor (`max` with the window), so a stale one never widens it. |
| Codex 2 (HIGH) | Fixed as far as our side can: tracked through the summary I/O, re-read right before the cancel, rollback; barrier test. Heal save conditional (2a). The remaining window is recorded in DESIGN §20 risk 27. |
| Codex 3 | Fixed: bind takes `lifecycle`; bind-during-publication test; the harness publishes through the router and propagates bind's result. |

## Scratch left behind

`<build dir>/guard-review/`: `mut` (package copy, 1.5 MB, sources match the repo, plus `Tests/TunnelEngineTests/R5Probe.swift`), `mut-tools/mutate6.py`, `mut-tools/R5Probe.swift`, `mutate6.out`, `probe6.out`, `r5-baseline.out`. The build output (`spm6`) is deleted. All safe to delete.

---

**Fixes.** `4a3bcd7a` (the automatic stray stop removed, guarded starts invalidated, latch at admission, interrupted hold).
