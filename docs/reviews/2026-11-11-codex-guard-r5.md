# Codex review, round 5: the structural rework `f09d1d04`

Reviewed: the structural rework `f09d1d04`. OpenAI Codex (GPT-6-Astra, max reasoning effort), read-only; final message as written. HEAD hashes quoted inside the report are those of a scratch checkout.

1. **HIGH — Duplicate cleanup can stop the protected incumbent.** [ConnectionStore.swift:705](native/App/Stores/ConnectionStore.swift:705), [ManagerStore.swift:124](native/App/Stores/ManagerStore.swift:124).

   “Stray” means older metadata, not a rejected session. Let older configuration A be connected with `includeAllNetworks`, while its addressable duplicate B lacks that flag. A local user starts B. If B’s `.connecting` notification arrives before its 222 completion, cleanup stops A because **both configurations merely need to be active**. B can then finish its already-decided refusal, leaving both down and the Mac open. A’s protection is stopped without a user disconnect, bypassing the extension’s first-wins guard.

   **Fix:** Identify the actual incumbent before automatic cleanup. At minimum, never automatically stop a connected/reasserting stray, or choose between two connecting configurations by metadata revision.

   **Tests:** The stray test covers only canonical-connected/stray-connecting. Add the reverse ordering, including a non-kill-switch duplicate refused with 222.

2. **HIGH — The final protection check still races a live flag save.** [TunnelController.swift:414](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:414), [ProviderHostRouter.swift:104](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderHostRouter.swift:104).

   After a fatal teardown, `finishEnding` reads protection as false, calls `endSession`, then cancels unconditionally. `endSession` performs synchronous plist I/O before cancellation. NE can enable `includeAllNetworks` during that interval; configuration updates are independent of the controller actor. The lifecycle mutex protects generation publication, not those updates. The subsequently cancelled session is now protected, producing the measured fail-open behavior. Its tracking has already been removed, so the queued KVO callback cannot recover it. Apple documents that the [provider configuration changes during a tunnel’s lifetime](https://developer.apple.com/documentation/networkextension/netunnelprovider/protocolconfiguration).

   **Fix:** Keep the session tracked until a conditional native cancellation succeeds. Protection updates and cancellation need a genuine serialization boundary; another unsynchronized read only narrows the race. If NE updates cannot be serialized, conservatively hold failure paths.

   **Tests:** Existing tests enable protection before teardown finishes. Add a barrier during the final summary save, enable protection there, and assert no cancellation and a tracked hold.

3. **MEDIUM — Generation publication is not atomic against binding.** [ProviderHostRouter.swift:46](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderHostRouter.swift:46), [ProviderHostRouter.swift:59](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderHostRouter.swift:59).

   G1 can pass the controller’s final lease check, then G2’s publication calls `providers.started`, making G2 current. Before publication acquires `state` and raises the watermark, G1 can acquire `state` through `bind`, which does **not** acquire `lifecycle`. G1 therefore binds successfully under an obsolete watermark. Retirement subsequently removes its dispatch entry but deliberately leaves `current` intact. The stale attempt can bind the reused provider’s packet flow and issue settings before G2 reaches the actor.

   **Fix:** Make binding participate in the lifecycle gate, or hold `state` across generation publication and watermark/retirement updates.

   **Tests:** The publication test races cancellation, but tests binding only after publication finishes. Add a bind during publication, after `providers.started`. The controller harness also bypasses publication and discards `router.bind`’s Boolean result; propagate it.

4. **MEDIUM — Restarting a stray bypasses cleanup permanently until reload.** [ConnectionStore.swift:705](native/App/Stores/ConnectionStore.swift:705).

   `strayStopsIssued` is never cleared. With canonical A connected, start its kill-switch duplicate D: cleanup stops D and records its key. Start D again without a configuration reload: the same key suppresses every further stop. D waits indefinitely beside A, and its live status blocks configuration changes and protective flag repairs through `othersBusy`. Two `scutil --nc start` attempts suffice; sustained flooding is unnecessary.

   **Fix:** Track an outstanding stop per attempt. Clear it when that session ends and prune obsolete keys on reload.

   **Tests:** Extend the existing stray test with disconnected → connecting on the same key, without reloading, and require a second stop.

5. **LOW — Provider watermarks accumulate for the process lifetime.** [ProviderHostRouter.swift:50](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderHostRouter.swift:50), [ProviderHostRouter.swift:80](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderHostRouter.swift:80).

   Every fresh provider start adds a watermark, including refused starts. `release` removes bindings but never that watermark. Keeping one tunnel running while repeatedly starting another accumulates entries whenever NE creates fresh provider instances, even after those instances are freed. The refusal throttle does not bound this memory growth.

   **Fix:** Tie generation state to provider/lease lifetime, or reclaim retired entries once outstanding work cannot bind them.

   **Tests:** No churn test checks bounded bookkeeping after repeated publish/release cycles.

Verified in source: full-lease cancel/unbind routing; lease validation at every start-loop iteration; the extension’s duplicate first-wins policy; current configuration flags for refusal notices; exemption from the generic 1-second filter; shared refusal throttling; and latch seeding before controller construction. Tracked teardown holds, owner-scoped stop/sleep/wake, waiter wakeups, active-successor selection, and per-attempt issue timestamps are present. Findings 2 and 3 leave the corresponding structural fixes incomplete.

No concrete lifecycle/KVO deadlock found. The documented abandoned-provider case still depends on unmeasured NE enforcement behavior; the unit tests cannot establish that it remains closed.

Reviewed HEAD `2c6c818` read-only. Tests inspected, not executed.

---

**Fixes.** `1814d25a` (live-or-start-time protection for holds, bind in the lifecycle gate, safe stray stop).
