# Codex review, round 10: the round 9 fix `d46a0cb2`

Reviewed: the round 9 fix `d46a0cb2`. OpenAI Codex (GPT-6-Astra, max reasoning effort), read-only; final message as written. HEAD hashes quoted inside the report are those of a scratch checkout.

**HIGH: No new confirmed findings.**

**MEDIUM — Automatic retries can still damage a competing kill-switch start. Pre-existing in 2.0.0; incompletely hardened in 2.0.1.**

[ProfilesStore.swift:603](native/App/Stores/ProfilesStore.swift:603), [ConnectionStore.swift:1422](native/App/Stores/ConnectionStore.swift:1422)

An automatic retry of A needs a manager update—for example, after a rename deferred during error recovery. Its save queues behind another manager operation. Meanwhile, `scutil` starts this user’s kill-switch profile B. The save’s condition excludes **all this user’s managers**, so it permits A’s configuration change during B’s `.connecting`. The automatic-retry busy check runs after preparation. The pause path has the same gap across its awaits.

The repository’s U2/U13 measurements show that such configuration changes can leave B unable to pass traffic until disconnected. This is an availability failure, not a demonstrated leak.

**Fix:** Carry the attempt token and automatic origin into preparation and pause operations. Inside each serialized mutation, reject stale attempts and require `!othersBusy(except: id)` for automatic retries. Add tests that introduce B while these mutations are queued; existing retry tests cover error-read and network waits.

**LOW — A fresh refusal disappears when the refused profile is unprovisioned. Introduced by 2.0.1’s freshness dependency.**

[EngineServiceBackend.swift:82](native/Packages/TunnelEngine/Sources/TunnelEngine/Service/EngineServiceBackend.swift:82), [ConnectionStore.swift:644](native/App/Stores/ConnectionStore.swift:644)

B’s NE configuration exists, but its extension payload is missing after failed provisioning or store recovery. Starting B beside live A records error 222 **before payload lookup**. However, the app’s freshness query requires B to be provisioned. It throws, `isFreshRefusal` returns false, and the genuine refusal is discarded.

The app consequently loses the refusal explanation and kill-switch refusal notification; the never-active path can retain its restart hold until timeout. This does not establish loss of A’s protection.

**Fix:** Allow authenticated, UID-scoped retrieval of the refusal’s timestamp/error independently of payload availability. Test through the real service backend: the app fake returns snapshots without enforcing provisioning, masking this mismatch.

**LOW — The unseen-blocker fix still misidentifies another user’s connection. Introduced in 2.0.1.**

[ConnectionStore.swift:747](native/App/Stores/ConnectionStore.swift:747), [ConnectionStore.swift:1849](native/App/Stores/ConnectionStore.swift:1849)

`statuses` includes other users’ addressable managers, but `anotherProfileActive` checks neither ownership nor visibility. If Bob’s active configuration was loaded at launch or delivered a status event, Alice’s refused start gets the ordinary instruction to disconnect another profile—even though Bob’s profile is absent from Alice’s profile list. Both extension refusals and app-generated 222 errors use this predicate.

**Fix:** Use a separate predicate for a visible, controllable profile when choosing explanatory copy; retain global activity checks for coordination. Test with an actual foreign status present. Existing unseen-blocker tests either omit the blocker or insert a new manager without delivering its status to `ConnectionStore`.

Source inspection confirms the other requested fixes: full-lease routing, loop revalidation, duplicate priority, current-configuration notice flags, shared throttling, 222/223 freshness exemptions, latch seeding, and reservation release. Rollback markers are memory-only and revision-constrained, survive a missing-manager reload, and cannot authorize replay after relaunch; forged settings records are ignored. Automatic origin survives network waits.

Tests were inspected, not executed under the read-only constraint. Their simulated provider lifecycle does not validate the documented macOS abandoned-provider and cancellation assumptions.

---

**Fixes.** `12552857` (display and test fixes before release).
