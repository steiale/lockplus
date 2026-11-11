# Verification: start guard after 32d37bcc and 7b24776a

Read-only, 2026-11-10, HEAD c40264a5. Nothing edited or committed in the repo.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `HOST` = `Packages/TunnelEngine/Sources/TunnelEngine/Host/`, `GT` = `Packages/TunnelEngine/Tests/TunnelEngineTests/ControllerProviderGuardTests.swift`.

## Verdict

No HIGH, no MEDIUM. Release-clean for 2.0.1 on the security side: every earlier finding stays fixed, and the new wait, reservation, live-flag read and retire code hold up under tracing. Five LOWs and four NITs, none of which can open the Mac. L1 and L2 are the two I would fix before shipping (both are one-line changes); L3 needs one VM measurement.

What was run:
- `swift test` on the guard suite (scratch `guard-review/spm4`): 55 tests pass.
- 14 mutations of the new code in a scratch copy (`guard-review/mut`, `mut-tools/mutate2.py`): 7 caught, 7 survive (L5).
- The app suite was read, not run. All scenarios below are traced from the code, not reproduced.

## Answers to the questions asked

- **Can the wait hang forever?** Only when it should: beside an incumbent NE neither stops nor frees (the accepted risk). Every lease change is followed by a wake on the actor (`stop`, `endSession`, `providerReleased`, a reuse's `stop(.superseded)`, the end of a reservation). The check and the `waiters.append` run with no suspension between them, so no wake is lost. One gap: a live flag change wakes nobody (N1).
- **Deadlock or leak?** No. The wait is a continuation, not a blocked actor. One continuation per waiting start, each resumed exactly once (`wakeWaiters` swaps the array out first).
- **Does its own stop always end it?** Yes. `ProviderSeat.stopTunnel` marks the lease stopped synchronously, `stop()` wakes first (`TC:1120`), and the woken start throws `.startCancelled` at the loop top. Also true when the stop lands before the start reaches the actor, and when NE reuses the instance.
- **Is the Mac closed throughout?** By the measured rule (E14a: a pending `includeAllNetworks` start is blocked), yes. What an indefinitely pending second kill-switch configuration does to the running one's traffic is unmeasured (L3).
- **Reservation leaks?** None. It is cleared in the start's continuation body and by the `defer`, and a reservation whose lease is no longer current is ignored. A stop of the reserving start during the teardown makes it non-current at once; the start then throws and clears it. The preempted session's provider is still cancelled, which is right (it was already torn down).
- **Lock ordering?** Consistent: actor, then router lock, then the flow's lock; nothing calls back into the actor. But `cancel` is now a host call under the router lock (L2).

## LOW

### L1. `startIssuedAt` is never cleared, so an old 222 passes the freshness check again
- **Where:** `CS:217`, set at `CS:678`, read at `CS:622-626`; no other write.
- **Scenario:** 09:00 the user connects X in the app and later disconnects. 10:00 a start of X made elsewhere is refused (222 recorded at 10:00). 15:00 another outside start or stop of X ends as `.disconnecting` then `.disconnected` with no new extension error. `isFreshRefusal` takes the 09:00 issue time, ignores `since`, and accepts the 10:00 error.
- **Result:** a refusal that didn't happen gets row 14 or a Diagnostics line, plus the kill-switch notice. Same class as the previous L1, reopened by the N3 fix. App bookkeeping only; nothing opens.
- **Paths affected:** `readRefusal` (`CS:601`) and `observedDisconnect` (`CS:965`). `checkNoNetworkRefusal` is fine (always an issued start).
- **Fix:** keep both bounds: `return at >= max(issued - 1, (since ?? now()) - window)`. Or store the attempt generation with the issue time and use it only for that generation.

### L2. `cancel` calls the host under the router lock; a provider freed inside the call traps the extension
- **Where:** `HOST/ProviderHostRouter.swift:55-56`; `HOST/ProviderHost.swift:57`; `Tunnel/PacketTunnelProvider.swift:59-62`.
- **Scenario:** `provider?.cancelTunnelWithError` holds a temporary strong reference. If NE drops its last reference during the call, `deinit` runs on this thread, still inside `state.withLock`, and calls `ProcessProviderHost.shared.release`, which takes the same lock. `Mutex` is not recursive: the root extension traps, taking any running session with it.
- **How likely:** very low. For a stopped provider the order unbind, then completion, closes it. It needs NE to free a connected provider without a stop at that moment.
- **What the lock buys:** little. `retire` runs inside generation 2's `startTunnel`, which NE has already delivered. A generation-1 cancel that wins the lock still reaches the native object after NE began generation 2. The window between NE's delivery and `retire` can't be closed from our side.
- **Fix:** dispatch outside the lock again (`state.withLock { $0.host(for: owner) }?.cancel(...)`), as `includeAllNetworks` does at `:61`, and record the residual window under risk 27. If the lock stays, keep the provider alive past the unlock so `deinit` can't run inside it.

### L3. A waiting duplicate is pending without limit: unmeasured on NE, and the app stays busy
- **Where:** `TC:298-304`; `CS:1303-1311` (`othersBusy` counts live strays); `CS:1375-1377` (`mutationBlocked`).
- **Network side:** t7 measured two kill-switch profiles with the second pending for 1.2 s (the first kept 149/152 pings). A same-profile duplicate now pends indefinitely. Whether the running session keeps passing traffic for that long is not measured. If not, anyone who can start the duplicate (`scutil --nc start`) black-holes the profile until the duplicate is stopped. Closed either way.
- **App side:** the duplicate is a stray (`ManagerClassifier`). While it reports `.connecting` the app is busy with reason "a VPN configuration LockPlus can't address": no configuration changes, no auto-connect, no orphan sweep (idle only), and the connected profile's own protective flag heal is deferred. Before, the refusal ended this in about a second.
- **After a Disconnect:** the waiting duplicate proceeds and connects the profile again. That follows DESIGN, but the user sees a reconnect they didn't ask for and can't stop from the app.
- **Fix:** add a VM scenario t8 (K connected, then a duplicate of K started with `scutil`, held 5 minutes: pings, plaintext, app state). In the app, treat this user's stray duplicate of a connected profile as stoppable (stop it, then sweep). Either before release, or record both under risk 27.

### L4. DESIGN §7.2 contradicts §20 risk 27 on the stuck kill-switch session
- **Where:** `docs/native/DESIGN.md:2320` says a kill-switch start of another profile beside a stuck kill-switch session is refused "closed"; `:4327` says "open".
- **Which is right:** `:4327`. A refused `includeAllNetworks` start is open (E14c) and NE no longer enforces the stuck session.
- **Fix:** correct the parenthesis at `:2320`.

### L5. Three new behaviours have no test (mutations survive)
- **`endSession` wake (`TC:1216`):** removable with all tests green; every test ends the incumbent through `stop()`. Missing case: the incumbent ends by itself while a duplicate waits.
- **Wake after `beginStart` (`TC:316`):** removable. Missing case: a same-profile duplicate waiting behind a reservation whose kill-switch start then stays held; without this wake it waits on nothing.
- **Wait behind a reservation (`TC:279`):** turning it into a refusal fails nothing.
- **Redundant pairs, not gaps:** the `isCurrent` check on the reservation and the `defer` cover each other, so each survives alone. The same goes for the clear in the continuation body and the wake in the `defer`.

## NIT

- **N1.** No wake when the incumbent's live flag changes. A duplicate waiting beside a session that loses `includeAllNetworks` should preempt it, but stays waiting until the next stop or release. Closed. A coarse periodic re-check would cover this and any future missed wake.
- **N2.** `CS:320-331`: the hero stays on the ended profile. A is current, a kill-switch start made elsewhere preempts it and is then held. A shows row 14 with Connect; the blocking profile never becomes current, because nothing moves `currentID` at A's `.disconnected`. Move it to an active profile there; A's 223 stays in `endNotes`.
- **N3.** `HOST/ProviderHostRouter.swift:18-20, 56`: the `cancelRequests` counter is a test seam compiled into the release extension. Harmless.
- **N4.** `TC:302`: the "waits for that session to end" notice is logged on every wake, unthrottled. Bounded by stop and release events.

Also unmeasured, with a safe fallback: that the provider's `protocolConfiguration.includeAllNetworks` follows a flag save on a connected session (header text only). If it doesn't, the guard decides on the start-time flag as before.

## Previous findings

All stay fixed.

| Source | Status |
|---|---|
| Fable M1 | Fixed: the duplicate waits (`TC:298`), three tests; DESIGN risk 27 corrected (but see L4). |
| Fable L1 | Fixed as reported: `endSeenAt` cleared at `CS:303` and `CS:677`. The N3 fix reopens the class by another route (L1 above). |
| Fable L2 | Fixed: three tests added; the three old surviving mutations now fail. |
| Fable N1 to N4 | Fixed. |
| Codex 1 | Fixed: live flag at the verdict and again before the cancel (`TC:377`); both mutations caught. |
| Codex 2 | Fixed within what our side can do: `retire` on the provider queue; mutation caught. See L2 for the lock. |
| Codex 3 | Fixed: reservation; mutation caught. |
| Codex 4 | Fixed: generation checked after every await; `onObservedDisconnect` has one consumer (`AuthCoordinator`), so dropping it is safe. |
| Codex 5 to 7 | Fixed. |
| E2E F1 | Fixed for the measured scenarios; N2 is the remaining display case. |
| E2E F2 to F5 | Fixed by reading. `MainSheet.nested` returns nil under an auth prompt and when onboarding closes, so nothing is cleared by mistake. |
| Earlier reviews (H1, M1 to M4, re-check L1 to L5) | Unchanged and still fixed. |

## Mutations

| Mutation | Result |
|---|---|
| `stop()` doesn't wake | caught |
| `endSession` doesn't wake | **survives** (L5) |
| release doesn't wake | caught |
| no reservation | caught |
| reservation ignores lease currency | survives (redundant with the `defer`) |
| no `defer` release | survives (redundant with the currency check) |
| reservation kept after `beginStart` | survives (equivalent) |
| `retire` is a no-op | caught |
| no re-read before the cancel | caught |
| verdict uses the start-time flag | caught |
| no wake after `beginStart` | **survives** (L5) |
| wait becomes refuse | caught |
| duplicate behind a reservation refused | **survives** (L5) |
| `defer` release doesn't wake | survives (redundant) |

## Scratch left behind

`<build dir>/guard-review/`: `spm4`, `spm-mut` (build products), `mut` (package copy, restored to match the repo), `mut-tools/mutate2.py` and `mutate2.out`. All safe to delete.

---

**Fixes.** `f09d1d04` (one effective-protection source, one lifecycle gate per provider).
