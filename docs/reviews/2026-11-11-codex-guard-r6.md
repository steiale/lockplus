# Codex review, round 6: the round 5 fixes `1814d25a`

Reviewed: the round 5 fixes `1814d25a`. OpenAI Codex (GPT-6-Astra, max reasoning effort), read-only; final message as written. HEAD hashes quoted inside the report are those of a scratch checkout.

1. **HIGH — Stray cleanup can stop the kill-switch replacement, leaving both configurations down.** [ConnectionStore.swift:720](native/App/Stores/ConnectionStore.swift:720), [TunnelController.swift:407](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:407).

   Addressable A is Connected but its live `includeAllNetworks` is false—possibly after protection drift. Someone starts same-key stray B with the flag enabled. The controller begins preempting A and awaits teardown. Meanwhile, cleanup sees A Connected and B Connecting and stops B: it never checks whether B is a waiter or the protective replacement. Teardown still cancels A; only afterward does the start loop detect B’s stopped lease. Both end, leaving traffic open. This requires no flag change during the accepted final-read/cancel window.

   **Fix:** Restrict cleanup to a confirmed guard waiter behind an incumbent currently enforcing full protection, with lease validation in the controller. A Connected status alone is insufficient. **Tests:** Combine the existing same-profile priority and stopped-preemptor tests with the app’s stray callback during suspended teardown; current tests exercise these separately.

2. **MEDIUM — Profile invalidation misses starts waiting inside the guard.** [TunnelController.swift:313](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:313), [TunnelController.swift:1623](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:1623).

   A pending protected session has a same-profile duplicate waiting behind it. `removeProfile` deletes the payload and ends A, waking the duplicate. The duplicate has no `Session` yet, so `endWaitingStart` never invalidated it. It subsequently binds, discovers the missing payload, and enters a protected hold. That can leave an unaddressable configuration blocking the Mac after its profile was deleted. Higher-revision provisioning similarly lets a queued request survive the invalidation of its old configuration.

   **Fix:** Track waiting requests by lease and `ProfileKey`; invalidate them on removal, wipe, and relevant revision changes before admitting them. **Tests:** `aWaitingDuplicateProceedsWhenTheIncumbentEndsByItself` actually expects admission after `profileRemoved`; it leaves the fake payload present. Add coverage through the real removal backend.

3. **MEDIUM — A stray’s end does not resume deferred protection repair.** [ConnectionStore.swift:261](native/App/Stores/ConnectionStore.swift:261).

   A connected profile needs protective flag repair, but a live stray makes `mutationBlocked` true. Once the stray ends, its callback only runs `stopStrayDuplicates()`. It never calls `restoreIfIdle()`, which also drives `healLiveDrift()`. With the incumbent remaining Connected and no further configuration/status event, the weakened protection remains unrepaired indefinitely. Deferred on-demand restoration has the same missing trigger.

   **Fix:** Run the shared recovery logic after stray status changes, retaining the serialized conditional-save checks. **Tests:** Existing stray tests verify that `mutationBlocked` becomes false, not that deferred repair or restoration actually executes.

4. **MEDIUM — The ten-second stray-stop expiry does not schedule a retry.** [ConnectionStore.swift:719](native/App/Stores/ConnectionStore.swift:719).

   Cleanup stops a duplicate. A local `scutil` loop restarts it within ten seconds, and the intervening Disconnected state is missed. Its Connecting callback is suppressed by the outstanding stop entry. If both statuses then remain stable, nothing invokes cleanup at expiry: the duplicate stays pending indefinitely and continues blocking configuration changes and protection repair.

   **Fix:** Schedule a bounded retry when an outstanding stop expires, revalidating ownership, current statuses, and waiter eligibility before acting. **Tests:** [AnotherTunnelActiveTests.swift:527](native/Tests/LockPlusTests/AnotherTunnelActiveTests.swift:527) advances time **and manually supplies another callback**, concealing the missing timer. Test expiry without another event.

5. **MEDIUM — A queued start uses a stale latch decision after awaiting teardown.** [TunnelController.swift:256](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:256), [TunnelController.swift:325](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:325).

   An on-demand protected start captures a hard authentication latch, then awaits the incumbent’s teardown. The user updates its credentials during that await; `credentialsUpdated` clears the persisted latch, but the replacement is not yet `session`, so nothing updates its captured `latched` value. Admission subsequently installs a permanent hard hold despite the corrected credentials. Conversely, a latch installed while a duplicate waits is ignored when its captured value was nil.

   **Fix:** Recompute the latch from current persisted state immediately before admission. **Tests:** Keep the corrected constructor-time seeding test, and add credential/latch changes while teardown or guard waiting is suspended.

6. **LOW — A vetoed preemption still reports that another kill-switch profile took over.** [TunnelController.swift:456](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:456).

   If A gains protection during preemption, cancellation is correctly vetoed and B is refused. However, `holdEnding` publishes `.blockedAfterFailure(.supersededByKillSwitch)`. The UI renders that reason as another kill-switch profile having taken over, although none did. Removing 223 from persisted `lastErrors` does not remove this separate reporting path.

   **Fix:** Use an accurate hold reason for an interrupted, vetoed replacement. **Tests:** Assert the snapshot’s hold reason and rendered copy; the current “carries no 223” test checks persisted errors and summaries only.

The earlier lease/generation, duplicate-priority, current-flag notice, freshness, shared-throttle, and latch-seeding fixes are present. The lifecycle lock, watermark removal, serialized save condition, summary-I/O protection reread, and protection-helper split also match the described changes. The stray-cleanup restrictions are present but have the interactions above.

Static review of `2c4aaf8`; tests inspected, not executed. No files modified.

---

**Fixes.** `4a3bcd7a` (the automatic stray stop removed, guarded starts invalidated, latch at admission, interrupted hold).
