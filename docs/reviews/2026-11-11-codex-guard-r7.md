# Codex review, round 7: the round 6 fixes `4a3bcd7a`

Reviewed: the round 6 fixes `4a3bcd7a`. OpenAI Codex (GPT-6-Astra, max reasoning effort), read-only; final message as written. HEAD hashes quoted inside the report are those of a scratch checkout.

**HIGH: No new findings.** The documented abandoned-provider fail-open risk remains.

1. **MEDIUM — Deferred recovery can save inside a newly pending kill-switch start.**  
   [ConnectionStore.swift:1699](native/App/Stores/ConnectionStore.swift:1699), [ProfilesStore.swift:559](native/App/Stores/ProfilesStore.swift:559), [ManagerStore.swift:494](native/App/Stores/ManagerStore.swift:494).

   A stray ends, recovery passes `!isBusy`, and an on-demand restore queues behind an existing manager operation. Before it acquires the serialization lock, another user starts a kill-switch configuration with `scutil`. The queued save still executes: only the protective **heal** uses `save(onlyIf:)`; `saveOnDemand` uses the unconditional overload. This reintroduces the documented configuration-mutation failure during a pending kill-switch start, despite the app now knowing it is busy.

   **Fix:** Revalidate the recovery predicate inside serialization, including stale-configuration retries. Preserve the pause record when a restore is skipped. **Tests:** Existing conditional-save tests cover healing; add a queued on-demand restore interrupted by an external `.connecting` transition.

2. **MEDIUM — Partial provisioning bypasses the new waiter invalidation, even after a successful retry.**  
   [EngineServiceBackend.swift:141](native/Packages/TunnelEngine/Sources/TunnelEngine/Service/EngineServiceBackend.swift:141), [TunnelController.swift:551](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:551).

   A revision-1 duplicate waits behind its incumbent. Provisioning revision 2 writes the payload successfully, but the credential write throws before `profileProvisioned` executes. Retrying revision 2 now computes `higher = false`, so even a successful retry never invalidates that revision-1 waiter. When the incumbent ends, the waiter can bind and load revision-2 payload under revision-1 configuration; the start-time revision check explicitly permits that direction.

   **Fix:** Make invalidation part of committing the payload revision, before subsequent credential I/O, and ensure partial failures and same-revision retries cannot skip it. Coordinate admission with an in-progress mutation. **Tests:** Inject failure after the payload write, retry the same revision, then release the incumbent; assert `.startCancelled` and no waiter binding. The new successful-provision tests miss this path.

3. **LOW — “Once per attempt” duplicate diagnostics reset on every configuration reload.**  
   [ManagerStore.swift:200](native/App/Stores/ManagerStore.swift:200), [ConnectionStore.swift:720](native/App/Stores/ConnectionStore.swift:720).

   `loadAll` assigns every stray a new random key. `strayNoted` uses those keys, so the next configuration-change callback forgets the previous notice and reports the same continuously pending duplicate again. Repeated reloads can fill the 50-entry Problems list and evict real failures.

   **Fix:** Deduplicate using identity that survives reloads, or conservatively group notices by owner/profile while matching duplicates remain live. **Tests:** The current test retains one key throughout; add reloads that remint keys without ending the attempt.

Verified by inspection: full-lease cancellation/unbinding and generation gating; loop-top stale-lease checks; duplicate first-wins/kill-switch priority; current-flag refusal notices; the independent 222 freshness window; shared refusal throttling; and latch seeding before controller construction.

All five round-5 changes are present. Automatic stray stopping is removed, admission recomputes `activeLatch`, and vetoed preemption uses 224. The recovery, invalidation, and notice gaps are described above.

Tests were inspected, not executed, to preserve the read-only constraint.

---

**Fixes.** `dc6ad9df` (conditional idle-path mutations, invalidation committed with the payload, precise stray note).
