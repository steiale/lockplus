# Codex review, round 3: `787f15af` and `b1346c48`

Reviewed: `787f15af` and `b1346c48`. OpenAI Codex (GPT-6-Astra, max reasoning effort), read-only; final message as written. HEAD hashes quoted inside the report are those of a scratch checkout.

1. **HIGH — Live protection changes can bypass kill-switch first-wins.** [TunnelController.swift:271](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:271), [ProfilesStore.swift:253](native/App/Stores/ProfilesStore.swift:253)

   A starts while its configuration’s `includeAllNetworks` is weakened to false. The app subsequently repairs it on the connected session, but the controller permanently retains the original false value. A competing kill-switch start therefore tears A down and cancels its now-protected provider. If the competing start is stopped during teardown, it subsequently fails its lease check: **both profiles end down and open, although A’s user never disconnected it**.

   Conversely, true→false drift leaves an unprotected incumbent eligible to refuse a genuine kill-switch start.

   **Fix:** Observe effective protocol changes per lease and coordinate protection changes with preemption. Revalidate protection before cancellation; the Boolean captured before the teardown await is insufficient. **Tests:** Existing app repair tests and engine guard tests are separate; neither tests a live flag change followed by preemption.

2. **MEDIUM — Generation retirement leaves a cancellation window before the new binding.** [ProviderSeat.swift:29](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderSeat.swift:29), [ProviderBindings.swift:44](native/Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderBindings.swift:44)

   Under the reused-provider interleaving this patch supports, generation 1 has a cancellation waiting on teardown. Generation 2 enters `startTunnel`, updating `ProviderInstances`, but its controller task has not bound yet—or is awaiting another teardown. The router still contains generation 1’s binding, so its delayed cancellation passes the full-lease comparison and calls the **same native provider object now handling generation 2**.

   **Fix:** Retire the old dispatch generation synchronously when a new lease starts, independently of acceptance/binding. Serialize cancellation validation and dispatch with that retirement. **Tests:** The current reuse test binds and connects generation 2 before releasing generation 1’s teardown, skipping this window. Actual NE delivery of the earlier reuse ordering remains unverified here.

3. **MEDIUM — Split-start loops can starve a kill-switch preemption.** [TunnelController.swift:1074](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:1074)

   Preemption clears `session` before awaiting teardown, without reserving the slot for the kill-switch requester. Another split start can occupy that slot. When the requester resumes, it preempts that session and opens another admission window. A local user repeatedly issuing `scutil --nc start` can sustain this cycle, preventing the kill-switch requester from reaching its own engine. Teardown caps bound individual waits, not total progress.

   **Fix:** Reserve ownership for the accepted replacement across teardown; competing starts must encounter that reservation. **Tests:** [ControllerProviderGuardTests.swift:361](native/Packages/TunnelEngine/Tests/TunnelEngineTests/ControllerProviderGuardTests.swift:361) explicitly exercises one interloper, but does not test sustained arrivals or bounded progress.

4. **MEDIUM — A delayed refusal read can clear a newer session’s authentication prompt.** [ConnectionStore.swift:922](native/App/Stores/ConnectionStore.swift:922), [AuthCoordinator.swift:39](native/App/Stores/AuthCoordinator.swift:39)

   Attempt B1 ends with 222 and its error task awaits the freshness snapshot. B2 then starts and presents an authentication prompt. When B1’s task resumes, it never rechecks attempt identity or current status: it updates error state, potentially posts a refusal notice, and unconditionally calls `onObservedDisconnect`. That callback clears B2’s prompt because it checks only the profile ID. B2 can remain blocked awaiting credentials whose prompt disappeared.

   **Fix:** Capture an attempt/end generation and revalidate it after every await, before updating UI state or delivering disconnect callbacks. **Tests:** Add a gated snapshot response, start B2 and deliver its prompt while B1 waits, then release B1. The current fake snapshot call does not exercise that suspension.

5. **LOW — Preemption error 223 disappears when `.connecting` was missed.** [ConnectionStore.swift:575](native/App/Stores/ConnectionStore.swift:575)

   A pending split start is preempted before the app observes it active. NE reports only `.disconnecting` → `.disconnected`. This reaches `readRefusal`, which handles code 2 and 222, but ignores 223. The failed attempt receives no corresponding error or Diagnostics problem.

   **Fix:** Handle fresh 223 on this path, including its appropriate freshness window and attribution. **Tests:** The app’s supersession test starts with an already-connected incumbent; add the never-observed-active case.

6. **LOW — Duplicate configurations bypass refusal log throttling.** [TunnelController.swift:278](native/Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift:278)

   Repeatedly starting a duplicate configuration emits `engineLog.fault` on every refusal, before `recordRefusal` applies its throttle. An unprivileged start loop therefore still floods fault diagnostics despite coalesced state-file writes.

   **Fix:** Apply the refusal throttle to this diagnostic too. **Tests:** The coalescing test checks persisted timestamps, not log emissions.

7. **LOW — The connection test helper races its own adapter index.** [ControllerProviderGuardTests.swift:124](native/Packages/TunnelEngine/Tests/TunnelEngineTests/ControllerProviderGuardTests.swift:124)

   `connect` launches the start task before reading `factory.adapters.count`. If that task creates its adapter first, the helper waits for the following, nonexistent adapter and reports timeouts. This makes security regression tests intermittently fail for unrelated scheduling reasons.

   **Fix:** Capture the expected index before launching the task, or identify adapters by their owning start.

The seven requested fixes are present: full-lease cancel/unbind matching, lease validation on every loop iteration, duplicate first-wins/priority, current configuration flags for refusal notices, exemption from the generic freshness filter, shared notice throttling, and latch seeding before controller construction. Finding 2 concerns an additional window before rebinding.

Reviewed HEAD `58d4758a`; no files changed or tests run. Providers that NE neither stops nor releases remain an indefinite blocker by design; manually invalidating tokens in unit tests does not validate that native lifecycle assumption.

---

**Fixes.** `32d37bcc` (duplicate kill-switch waits, live protection, reservation, early retire).
