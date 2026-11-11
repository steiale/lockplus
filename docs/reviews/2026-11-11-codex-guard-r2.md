# Codex review, round 2: the round 1 fold `700cfae2`

Reviewed: the round 1 fold `700cfae2`. OpenAI Codex (GPT-6-Astra, max reasoning effort), read-only; final message as written. HEAD hashes quoted inside the report are those of a scratch checkout.

1. **HIGH — Host operations discard the lease generation and can cancel a restarted kill-switch session.** [EngineAssembly.swift:81](native/Tunnel/EngineAssembly.swift:81), [ProviderSeat.swift:48](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderSeat.swift:48)

   A cancellation queued for provider P, generation 1, can resume after stop/start has rebound P as generation 2. `byToken[owner.token]` selects generation 2’s host; nothing checks the generation. If generation 2 has `includeAllNetworks`, the old cancellation now ends that protected session and opens the Mac. Likewise, an old stop unconditionally calls `unbind()`, which can remove the newer binding despite the controller correctly ignoring that stop.

   **Fix:** Carry the full lease through bind/unbind/cancel, invalidate older bindings on reuse, and serialize generation validation with the provider operation.

   **Tests:** The fake merely records the supplied owner. Existing tests can pass while the real host cancels the wrong generation. Test actual dispatch and unbinding across reuse.

2. **MEDIUM — A stale start can destroy a newer live session before discovering that it was cancelled.** [TunnelController.swift:262](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:262), [TunnelController.swift:280](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:280)

   Delay generation 1’s start Task; let its stop finish, then connect generation 2 on the reused provider. When generation 1 finally enters `start`, matching tokens bypass the incumbent guard. It tears down generation 2, then checks its own expired lease and throws `.startCancelled`. Actor execution order is [not guaranteed FIFO](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md).

   This recreates the live “Connected” session with no engine behind it—a black hole under the kill switch. A stopped kill-switch request can similarly preempt an unrelated split session before cancelling itself.

   **Fix:** Validate the incoming lease before every destructive loop iteration, including after teardown awaits.

   **Tests:** Add delayed **start** arrival after a newer generation connects; existing coverage tests delayed stops instead.

3. **MEDIUM — Duplicate configurations bypass first-wins through the same-profile exception.** [TunnelController.swift:263](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:263)

   `ProfileKey` identifies a payload namespace, not a unique NE configuration. Duplicate configurations are explicitly supported by [ManagerClassifier](native/App/Stores/ManagerStore.swift:107). With two configurations carrying the same UID/profile UUID, a local user can start the duplicate using `scutil`; this branch tears down the incumbent even when its lease is current and its kill switch is enabled.

   The incumbent’s provider is not cancelled on this path, reproducing the original silent displacement and misleading Connected/Protected state.

   **Fix:** Require evidence that the incumbent NE session ended; payload-key equality must not override a live lease.

   **Tests:** The same-profile replacement test currently endorses this behavior. Add two distinct configurations sharing a profile key.

4. **MEDIUM — A previous session’s cached flag can suppress the kill-switch refusal warning.** [ConnectionStore.swift:622](native/App/Stores/ConnectionStore.swift:622)

   Run B without the kill switch, disconnect it, then enable `includeAllNetworks` and on-demand. Later, B is refused beside another kill-switch session, with `.connecting` omitted. `sessionKillSwitch[B]` still contains `false`; the on-demand case bypasses the teardown path that refreshes it. Consequently, `false ?? managerKillSwitch(B)` suppresses `.killSwitchStartRefused`, despite the current attempt having the flag enabled.

   A background user receives no notification that B’s intended protection failed to start.

   **Fix:** Capture current manager flags for each newly observed refusal, rather than reusing the previous session’s flags.

   **Tests:** Add a flag-change/on-demand case with no `.connecting` event; current tests cover a kill-switch profile without on-demand.

5. **LOW — The earlier one-second filter defeats the new ten-second freshness window.** [ConnectionStore.swift:903](native/App/Stores/ConnectionStore.swift:903)

   If a genuine refusal is recorded two seconds before the app observes `.connecting`, lines 896–899 discard it before `isFreshRefusal` runs. Although it satisfies the new ten-second window, the app shows neither the refusal error nor its kill-switch notification.

   **Fix:** Apply the refusal-specific freshness rule before, or instead of, the generic one-second filter.

   **Tests:** Cover timestamps two seconds before the first observed active status. Current tests use immediate timestamps or an hour-old error.

6. **LOW — Observing `.connecting` bypasses notification throttling.** [ConnectionStore.swift:930](native/App/Stores/ConnectionStore.swift:930)

   Repeated `scutil --nc start` attempts that report `.connecting` enter `observedDisconnect`, which emits `.killSwitchStartRefused` directly. It never consults `refusalNotedAt`, so the promised five-minute suppression applies only when `.connecting` was missed.

   **Fix:** Route both paths through shared notification throttling.

   **Tests:** Repeat kill-switch refusals with `seenConnecting: true`; the existing repetition test always omits that event.

7. **LOW — The latched-start regression test never installs a latch in the controller.** [ControllerProviderGuardTests.swift:186](native/Packages/TunnelEngine/Tests/TunnelEngineTests/ControllerProviderGuardTests.swift:186)

   `World` constructs the controller before this code writes the latch into `w.h.state`. The controller already copied that store into its private `persisted` value and does not reload it. Both parameterized variants therefore exercise an unlatched start, leaving the claimed latch/guard interaction untested.

   **Fix:** Seed persistence before constructing the controller, or establish the latch through controller behavior. Assert that its snapshot contains the latch before attempting the competing start.

Static review of HEAD `7dedf45`; no files modified. Swift tests were inspected, not executed in the read-only sandbox.

---

**Fixes.** `787f15af` (same-profile rule, lease-keyed bindings, weak host); the Codex findings were folded in `b1346c48` (no same-profile override of a live lease, tested router dispatch).
