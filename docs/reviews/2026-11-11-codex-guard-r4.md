# Codex review, round 4: `32d37bcc` and the VM display fixes `7b24776a`

Reviewed: `32d37bcc` and the VM display fixes `7b24776a`. OpenAI Codex (GPT-6-Astra, max reasoning effort), read-only; final message as written. HEAD hashes quoted inside the report are those of a scratch checkout.

1. **HIGH — Ordinary failure paths still cancel a live-enabled kill switch.** [TunnelController.swift:825](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:825)

   Start A with `includeAllNetworks=false`, then enable it while connected—for example through protective drift repair. The guard correctly treats A as protected and refuses another kill-switch start. However, fatal-error handling and the reconnect budget still use A’s immutable `s.killSwitch`. An engine failure or budget expiry reaches `cancelAfterTeardown`, which cancels A without reading its live flag, leaving the Mac **down and open**.

   **Fix:** Use effective protection throughout failure handling, including immediately before deferred cancellation; preserve a protected session as held. Existing live-flag tests exercise preemption only. Add flag-enable → fatal, reconnect-budget expiry, and flag-enable during teardown cases.

2. **MEDIUM — Generation retirement still has cancellation and binding races.** [ProviderSeat.swift:32](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderSeat.swift:32), [ProviderHostRouter.swift:55](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderHostRouter.swift:55)

   If NE delivers generation 2 while generation 1’s cancellation remains outstanding, `started(token)` publishes generation 2 **before** `retire` acquires the router lock. A generation-1 cancellation in that interval still finds its binding and cancels the reused native provider. Locking validation and dispatch together does not close this interval.

   Additionally, [ProviderBindings.swift:37](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderBindings.swift:37) only deletes an entry: an older bind that already passed the controller’s liveness check can reinstall it after retirement.

   **Fix:** Serialize generation publication, retirement, binding acceptance and cancellation through one lifecycle gate; retain a generation watermark. Current tests finish retirement before releasing cancellation. Add barriers inside these intervals and a fake that models both generations sharing one native provider.

3. **MEDIUM — Cancellation under the router mutex can deadlock during provider destruction.** [ProviderHostRouter.swift:56](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderHostRouter.swift:56), [PacketTunnelProvider.swift:59](native/Tunnel/PacketTunnelProvider.swift:59)

   `RealProviderHost.cancel` temporarily retains its weak provider while the router lock is held. If NE releases its last other reference during that call, releasing the temporary can run the provider’s `deinit`. That synchronously calls the same router’s `release`, recursively acquiring its nonrecursive mutex. This can hang or trap the shared extension during concurrent cancellation and release.

   **Fix:** Keep the native provider strongly retained until after unlocking, while preserving atomic generation validation. Add a lifetime-sensitive fake whose final release invokes router cleanup; the recording-only `FakeHost.cancel` cannot expose this.

4. **MEDIUM — Vetoing cancellation leaves an untracked, engine-less “Connected” provider.** [TunnelController.swift:376](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:376)

   A is unprotected when K preempts it, but gains `includeAllNetworks` during teardown. `stopSession` has already removed A’s controller session and stopped its engine. The re-read then suppresses cancellation, and K proceeds. A remains Connected in NE without an engine, held state or controller ownership.

   If K remains pending, the app can continue showing A as Protected. For duplicate configurations with equal addresses, A’s retained utun can also keep K failing with ambiguous-utun errors.

   **Fix:** Preserve A as a tracked held/reasserting session when cancellation is vetoed, then reconsider K against that protected owner. The test at [ControllerProviderGuardTests.swift:677](native/Packages/TunnelEngine/Tests/TunnelEngineTests/ControllerProviderGuardTests.swift:677) currently accepts this outcome; it needs assertions about A’s lifecycle, displayed state and subsequent starts.

5. **MEDIUM — An accepted preemptor that stays pending never takes over the app’s current profile.** [ConnectionStore.swift:326](native/App/Stores/ConnectionStore.swift:326)

   Sequence: A is Connected; K reports Connecting; A is preempted and becomes Disconnected; K enters a before-connected hold. The new rule keeps A current when K first reports Connecting. A’s subsequent disconnect does not select K, and K’s hold produces no new NE status transition.

   Snapshot refreshes therefore keep querying A. K’s failure and recovery controls remain hidden; selecting K renders the non-current “Unprotected” hero, while Disconnect targets A.

   **Fix:** Reconsider `currentID` when the current profile becomes inactive, selecting an already-active successor. Extend the preemption UI test to leave K held instead of emitting `.connected`, and verify both its error and Cancel target.

6. **LOW — An old app-issued timestamp disables freshness checks for later external attempts.** [ConnectionStore.swift:622](native/App/Stores/ConnectionStore.swift:622)

   `startIssuedAt[id]` is assigned but never cleared. Once an app-issued attempt records 222, a later external stop/start can read that sticky error hours afterward. The `issued` branch accepts it because it postdates the historical issue time, bypassing the ten-second window entirely. This produces false refusal notes and kill-switch warnings, and can incorrectly end a restart hold.

   **Fix:** Scope the issue timestamp to its actual attempt and retain the appropriate freshness bound for subsequent external attempts. Existing stale-error tests lack a preceding app-issued attempt; add that history and advance the clock.

Verified by inspection: full-lease lookup/unbind, per-loop stale checks, profile-key priority, current-flag refusal notices, the 222 exemption from the generic one-second filter, shared throttling and pre-construction latch seeding remain present. Duplicate waits wake on stop/end/release; attempt-generation checks, never-active 223 handling, per-profile notes and nested onboarding presentation are wired in. I found no independent reservation-cleanup leak.

Static review of HEAD `46f24d1`. Files unchanged; tests were not executed under the read-only constraints.

---

**Fixes.** `f09d1d04` (one effective-protection source, one lifecycle gate per provider).
