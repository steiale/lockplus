# Codex review, round 8: the round 7 fixes `dc6ad9df`

Reviewed: the round 7 fixes `dc6ad9df`. OpenAI Codex (GPT-6-Astra, max reasoning effort), read-only; final message as written. HEAD hashes quoted inside the report are those of a scratch checkout.

**HIGH: None established.**

- **MEDIUM — Automatic repair can stop a newer kill-switch session.** [ConnectionStore.swift:1048](native/App/Stores/ConnectionStore.swift:1048)  
  Split profile A fails with `profileNotProvisioned` or `profileRevisionStale`. While its error read or provisioning awaits, kill-switch profile B connects through System Settings or `scutil`. A’s recovery still calls `startNow(A)`; `runStart` subsequently switches away from B. This bypasses the extension’s first-wins guard through an app-issued stop. B’s stop is classified as user-initiated, suppressing its protection-loss notification under the default problems-only setting.  
  **Fix:** Bind automatic recovery to the original attempt and pending token; recheck after provisioning, and never let background recovery switch away from another live session. **Tests:** The slow-refusal test covers 222, not this provisioning branch. Add the delayed-A-recovery/B-connected sequence.

- **MEDIUM — The conditional on-demand save still uses stale protection eligibility.** [ProfilesStore.swift:604](native/App/Stores/ProfilesStore.swift:604)  
  `behind` is calculated before acquiring serialization and captured as a Boolean. While the save waits—or during a stale-configuration reload—the manager can acquire newer flags and become connected. `mutationBlocked(id)` permits the connected profile’s own saves, and the cached `behind == false` admits the old configuration. For example, a resave captured before a kill-switch enable can overwrite the newly connected configuration with `includeAllNetworks == false`.  
  **Fix:** Recompute the flag/revision comparison inside the predicate on every invocation, including retries. **Tests:** Add an own-profile transition to Connected with changed flags while queued; existing tests introduce another pending configuration instead.

- **MEDIUM — Pending-start preemption lacks the final protection recheck.** [TunnelController.swift:445](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:445)  
  For an incumbent whose start completion remains pending, preemption calls `recordLastError`, which performs synchronous disk I/O, then unconditionally fails that start. If its live `includeAllNetworks` becomes true during the write, it is nevertheless ended with 223. This displaces a now-protected incumbent and completes its start with the fail-open outcome. The connected-session branch already rechecks after its disk write.  
  **Fix:** Re-read protection immediately before failing the pending start; preserve it and withdraw the 223 record if it became protected. **Tests:** Extend the save-time flag-promotion test to an incumbent with a non-nil `startGate`.

- **MEDIUM — Foreground configuration work can still cross the activity guard.** [ProfilesStore.swift:297](native/App/Stores/ProfilesStore.swift:297), [ConnectionStore.swift:1355](native/App/Stores/ConnectionStore.swift:1355)  
  `saveManagerUnlessBlocked` checks activity before queuing an unconditional save. An external kill-switch start arriving while that save waits therefore does not prevent the mutation. Separately, `restoreOwnOnDemand` excludes its own profile from its predicate: an external start of that same profile can clear the app’s pending attempt while its queued restore still saves inside `.connecting`. These paths retain the measured configuration-change denial of service during pending starts.  
  **Fix:** Use conditional serialization for the foreground helper; make the own-profile restore also validate the original attempt and actual session status. **Tests:** Exercise both callers with the existing queued-mutation barrier.

- **LOW — A skipped drift repair consumes the repair allowance.** [ProfilesStore.swift:209](native/App/Stores/ProfilesStore.swift:209)  
  `healedDrift` is marked before the conditional save. If activity makes that save return `false`, the next load treats the never-attempted repair as already exhausted. A manual-only profile is also skipped by `resaveOnDemand`, leaving its weakened flags unrepaired and reporting that restoration failed.  
  **Fix:** Clear the marker when the save is skipped, as the live-heal path already does. **Tests:** Extend the queued-sync test through recovery after the blocker ends, using a profile without on-demand rules.

- **LOW — A refused split duplicate is described as waiting.** [ConnectionStore.swift:728](native/App/Stores/ConnectionStore.swift:728)  
  The note checks the incumbent’s kill-switch flag but cannot check the stray’s: `StraySnapshot` carries no protection flags. An older non-kill-switch duplicate briefly observed as `.connecting` beside its protected incumbent is therefore labeled “waiting,” although the extension refuses it with 222. Repeated starts can produce a fresh misleading problem line each attempt, bypassing the refusal throttle.  
  **Fix:** Include the stray’s current flags in the snapshot and require its `includeAllNetworks`, or use neutral pending-configuration wording. **Tests:** Add a non-kill-switch stray beside a connected kill-switch incumbent.

Verified in source: full-lease cancellation/unbinding, loop-entry lease validation, duplicate-key priority, current-flag refusal notices, the independent freshness window, shared refusal throttle, and preconstruction latch seeding remain intact. Round-6 payload invalidation precedes credential I/O; same-revision retries invalidate older waiters; reservation holders remain exempt from revision invalidation but not removal/wipe. Stray identity survives reloads and the incumbent checks are present.

Reviewed HEAD `8b8a85f`. No files changed. Tests inspected, not executed in the read-only sandbox.

---

**Fixes.** `f3837f8e` (pending-incumbent re-read, stale holder ends, bound recovery, one pending-start predicate) and `175a8999` (a skipped manager rollback is recorded and retried, never read as a replay; the durable record in this commit was a mistake, see the overview).
