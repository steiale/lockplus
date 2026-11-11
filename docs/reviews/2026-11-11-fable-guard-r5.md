# Verification round 4: start-guard structural rework (f09d1d04)

Read-only, 2026-11-10, HEAD f09d1d04. Nothing edited or committed in the repo.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `HOST` = `Packages/TunnelEngine/Sources/TunnelEngine/Host/`, `GT` = `Packages/TunnelEngine/Tests/TunnelEngineTests/ControllerProviderGuardTests.swift`.

## Verdict

Not release-clean: one MEDIUM (M1), introduced by this commit. No HIGH. Three LOWs and five NITs.

Every earlier finding (my L1–L5, N1–N4; Codex round 3, 1–6) is fixed. The lifecycle gate, the tracked `.stopping` session and the wake paths hold up under tracing: I found no deadlock, no lock-order inversion, no start that never wakes and no held session that can't be released.

M1 is the other side of the Codex HIGH fix. `effectiveProtection` now trusts the live flags in both directions, so a kill-switch session whose flags the system weakened is cancelled, or its start failed, where 7b24776a held it. The fix is small and passes the existing suite.

What was run:
- `swift test` on the guard and connected suites (scratch `guard-review/spm5`): 90 tests pass.
- 32 mutations in a scratch copy (`guard-review/mut`, `mut-tools/mutate5.py`): 19 caught, 13 survive (table below).
- 4 probe tests in the scratch copy (`R4Probe.swift`): two reproduce M1, two confirm paths that have no test.
- The app suite was read, not run. The app-side scenarios (L1, L2) are traced from the code.
- No build contains this commit (200025 is c40264a5, its parent), so none of it has run on NE.

## MEDIUM

### M1. A weakened live flag turns hold into cancel, and withhold into a failed start
- **Where:** `TC:356-359` (`effectiveProtection`: live flags win whenever the provider answers), used at `TC:795`, `TC:799` (before Connected), `TC:854`, `TC:872`, `TC:879` (fatal), `TC:893`, `TC:950`, `TC:957` (reconnect budget).
- **Precondition:** the profile's configuration has the kill switch, but the provider's live `protocolConfiguration` has neither `includeAllNetworks` nor `enforceRoutes`. This is the weakening drift the app already handles (`ProfilesStore.healProtectiveDrift`, DESIGN U7). It is healed only at `.connected`, with the app running and nothing else busy.
- **Scenario A (reconnect budget):** the kill-switch session is in that state (app closed, or another start under way). The network is gone for more than 300 s. `enterReasserting` arms the budget because the live flag is off; its expiry cancels the session. Before this commit a kill-switch session had no budget and reconnected when the network returned.
- **Scenario B (fatal):** same state, engine fatal. The session is cancelled instead of held. Reproduced: `PROBE1 cancelled: [engineFatal] phase: idle`.
- **Scenario C (before Connected):** the drift is seen while `.connecting`, which the app answers with "LockPlus restores them as soon as it is connected". A connect timeout now fails the start instead of withholding and retrying, so it never reaches `.connected` and the heal never runs. Reproduced: `PROBE2 result: failure(connectTimeout)`, phase idle.
- **Result:** a kill-switch profile ends disconnected and open, with nothing restoring it. Under 7b24776a it stayed held or kept retrying.
- **Why only this direction:** the app never weakens a live session's flags itself (L-KS-2), so start-time on plus live off is always a system change, never the user's choice.
- **Fix:** for every hold-vs-cancel, withhold and budget decision, treat the session as protected when the live flags **or** the start-time flags say so. Keep the live-only read for the guard's verdict (`TC:298`) and the preemption's `keepIf` (`TC:396`).
  - Those two must use the same read. If the verdict is live-only and the preemption's keep is the union, the start loop preempts, holds and preempts again without suspending. Mutation c13 shows this spin.
  - I ran this fix as mutation u1: all 90 tests pass.
  - Add three tests: start-time on with live off for a fatal, for the budget, and for a before-Connected failure.

## LOW

### L1. The stray stop also stops a connected stray when the addressable configuration is only connecting
- **Where:** `CS:704-711`. Both sides are tested with `isActive`.
- **Scenario:** two configurations of one profile, both this user's. The stray (older revision) is connected, started from System Settings or by its own on-demand rule. The addressable one starts. At its `.connecting` the app stops the connected stray.
  - Full-tunnel kill switch: the addressable start was waiting and takes over. Closed, and a fine outcome.
  - Split with route protection, or no kill switch: the extension refuses the addressable start (222). The stray is stopped anyway, so nothing is connected and a route-protection profile is open.
- **Not affected:** another user's session. Only strays whose `ownerUID` is this user's are stopped; an unreadable owner or profile ID is skipped.
- **Fix:** stop a stray only when it is not `.connected`/`.reasserting`, or only when the addressable profile reached `.connected`. That is the case L3 asked for. The one test covers only that case (`aStrayDuplicateOfTheConnectedProfileIsStopped`).

### L2. A stray is stopped once per load, and not at launch
- **Where:** `CS:223`, `CS:707` (`strayStopsIssued` is never pruned); `CS:260-277` (`start()` doesn't call `stopStrayDuplicates`).
- **Scenario:** the stopped duplicate is started again (`scutil` again, or its own on-demand rule restarts it after the stop). Its key is already in the set, so it is not stopped again until the next `loadAll` gives it a new key. Until then the old L3 state returns: the duplicate waits without limit and the app is busy. A duplicate already waiting when the app launches is stopped only at the next status event.
- **Fix:** remove a key when its stray is no longer active, and call `stopStrayDuplicates()` at the end of `start()`.

### L3. Four behaviours of the rework have no test (the mutations survive, and they are not redundant layers)
- **c3, the `session === s, phase == .stopping` guard in `finishEnding` (`TC:413`):** removable with all tests green. It is the only thing that keeps a late `finishEnding` from ending a successor session. The code is right (`PROBE4`: the new session stays connected, no cancel). Missing test: the session's own stop and a new start during a fatal's teardown.
- **c2, the wake when `finishEnding` holds (`TC:418`):** removable. Without it a start waiting beside a fatal's teardown that ends held waits forever instead of being refused. The code is right (`PROBE3`: refused with 222). Missing test: exactly that case.
- **c11 and c12, the live read before Connected (`TC:795`, `TC:799`):** no test in either direction. The M1 tests cover this.
- **s1, `ProviderSeat.protectionChanged` (`HOST/ProviderSeat.swift:89`):** a no-op passes. The test calls `recheckWaitingStarts` on the controller directly, so the seat's wiring is untested. One seat-level test closes it.

## NIT

- **N1.** The KVO path is unmeasured. Whether NE fires KVO for `protocolConfiguration`, and that a provider observing itself (`Tunnel/PacketTunnelProvider.swift:37`) deallocates cleanly, need one VM pass with a few start/stop cycles and a flag save on a connected session. If KVO never fires, the wait falls back to the stop and release wakes, as before.
- **N2.** `HOST/ProviderHostRouter.swift:31`: `watermark` is never pruned; one entry per provider instance for the life of the process. Remove it in `release`.
- **N3.** `TC:403`: `beginEnding` clears `broker.live` without `promptResolved`. A preempted session with an after-Connected prompt showing used to resolve it through `endSession`; now the app is not told. Call `resolveLivePrompt()` there.
- **N4.** `TC:388`: `endForReplacement` records 223 before it knows the outcome. A session that ends up held carries "superseded" as its last error and hold code although it was kept.
- **N5.** `CS:426`: the previous session's late `.disconnected` (it can land after `managers.start`) clears the new attempt's issue time. That attempt's refusal then falls back to the 10 s window alone. No false positive found.

## Answers to the questions asked

- **Deadlocks or lock-order inversions?** None found.
  - Order: controller actor, then `lifecycle`, then `state`; `ProviderInstances`' lock is taken inside `lifecycle` during `publish`. Nothing takes them in reverse, and nothing under a lock calls back into the actor.
  - `deinit` takes only `state` and the instances lock, never `lifecycle`, and the pin keeps it out of the dispatch.
  - `cancelTunnelWithError` still runs under `lifecycle`, so a `startTunnel` on NE's queue waits for it. That is the same exposure as the single lock before.
- **Which thread does NE deliver KVO on?** KVO is synchronous on whichever thread sets the property, so an NE-internal queue. The callback only starts a Task (`seat.protectionChanged()`), takes no lock and touches no provider state, so any thread is safe.
- **A held session that can't be released, or blocks everything?** No. A session held by `finishEnding` ends on its own `stopTunnel` like any after-Connected hold. It refuses other starts by first-wins, which is the design for a protected session. It doesn't retry by itself; neither does the ordinary after-Connected hold.
- **Waiting starts that never wake?** No. The three waits (reservation, `.stopping`, same-profile duplicate) are followed by a wake on every exit: `endSession`, the hold in `finishEnding`, `stop`, release, KVO, and the reservation's `defer`. The teardown the `.stopping` wait depends on is capped (1 s + 5 s).
- **Races in the protection reads?** The read and the action are synchronous on the actor. The only window is NE flipping the flag between the read and `cancelTunnelWithError`, which can't be closed from our side.
- **Stray stop hitting the wrong thing?** Never another user's session. It can stop this user's connected stray (L1).
- **Open paths, or protection claimed but absent?** M1, plus the route-protection case of L1.

## Mutation survivors: are the redundant layers acceptable?

I found no table for the implementer's labels (G1, E2, E6, A2), so I can't map them one to one. By my own run:

- **Acceptable (redundant or equivalent), 8 of 13:**
  - c6 and c7: the entry checks in `afterConnectedFatal` and `cancelAfterTeardown` are backed by the re-read in `finishEnding` (c5, caught).
  - c9 and c10: arming the budget is backed by the check at its expiry (c8, caught).
  - r2 and r7: the watermark check in `cancel` and `liveProtection` is backed by the retirement and the refused bind (r1 and r4, caught).
  - r3: the retirement in `publish` is backed by the watermark.
  - r8: dispatch outside `state` is backed by the pin (r5, caught).
- **Equivalent:** m11, the wake after `beginStart`. A start waiting behind a reservation is a same-profile kill-switch duplicate and waits again beside the new session either way. I listed this as a gap in the last round; that was wrong.
- **Not acceptable as "redundant":** c2, c3, c11, c12 and s1. These are single layers with no test (L3).

| Mutation | Result |
|---|---|
| c1 no wait beside a `.stopping` session | caught |
| c2 `finishEnding` hold doesn't wake | **survives** (L3) |
| c3 `finishEnding` without its identity/phase guard | **survives** (L3) |
| c4 preemption never holds | caught |
| c5 fatal teardown never holds | caught |
| c6 `cancelAfterTeardown` entry uses the start flag | survives (redundant) |
| c7 `afterConnectedFatal` uses the start flag | survives (redundant) |
| c8 budget expiry uses the start flag | caught |
| c9 `enterReasserting` uses the start flag | survives (redundant) |
| c10 `resumeReassertBudget` uses the start flag | survives (redundant) |
| c11 withhold uses the start flag | **survives** (L3) |
| c12 before-Connected latch uses the start flag | **survives** (L3) |
| c13 verdict uses the start flag | caught (the start loop spins; timeout) |
| c14 `finishEnding` hold without `setReasserting` | caught |
| c15 `beginEnding` leaves the phase | caught (spin; timeout) |
| c16 fallback drops `enforceRoutes` | caught |
| r1 bind ignores the watermark | caught |
| r2 cancel ignores the watermark | survives (redundant) |
| r3 publish doesn't retire | survives (redundant) |
| r4 publish doesn't raise the watermark | caught |
| r5 no pin | caught |
| r6 publish outside the lifecycle lock | caught |
| r7 `liveProtection` ignores the watermark | survives (redundant) |
| r8 cancel dispatched under the bindings lock | survives (redundant with the pin) |
| s1 `protectionChanged` is a no-op | **survives** (L3) |
| s2 seat bypasses the gate | caught |
| s3 release doesn't wake | caught |
| m2 `endSession` doesn't wake (old L5) | caught now |
| m11 no wake after `beginStart` (old L5) | survives (equivalent) |
| m13 duplicate behind a reservation refused (old L5) | caught now |
| u1 the M1 fix (union for hold-vs-cancel) | all tests pass |

## Previous findings

| Source | Status |
|---|---|
| Fable L1 = Codex 6 | Fixed: issue time captured per attempt, both bounds applied, cleared at `.disconnected` (`CS:426`, `CS:635-642`); test added. See N5. |
| Fable L2 = Codex 3 | Fixed: host call outside `state`, provider pinned past both unlocks; lifetime-sensitive test added (r5 caught). |
| Fable L3 | Fixed for the measured case; t8 recorded as unmeasured in DESIGN risk 27 and `e2e/RESULTS-2.0.1.md`. See L1 and L2. |
| Fable L4 | Fixed: DESIGN §7.2 and risk 27 agree (a refused start beside a stuck session is open). |
| Fable L5 | Fixed: two of the three mutations are caught now; the third is equivalent (m11). |
| Fable N1 | Fixed in code (KVO); unmeasured on NE (N1 above). |
| Fable N2 = Codex 5 | Fixed: `selectActiveSuccessor` (`CS:692`); test with a held preemptor and its Cancel target. |
| Fable N3, N4 | Fixed. |
| Codex 1 (HIGH) | Fixed: fatal, budget and both ends of `cancelAfterTeardown` read the live protection; four tests. The fix opened M1. |
| Codex 2 | Fixed within what our side can do: publish, retire and watermark in one step under `lifecycle`; bind refused below the watermark; barrier test. |
| Codex 4 | Fixed: the session stays tracked as `.stopping`, then held or ended; the test asserts phase, snapshot, no cancel and a later start. |

## Scratch left behind

`<build dir>/guard-review/`: `spm5`, `spm-mut` (build products), `mut` (package copy; sources match the repo, plus `Tests/TunnelEngineTests/R4Probe.swift`), `mut-tools/mutate5.py`, `mutate5.out`, `mutate5b.out`, `probe.out`. All safe to delete.

---

**Fixes.** `1814d25a` (live-or-start-time protection for holds, bind in the lifecycle gate, safe stray stop).
