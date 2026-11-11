# Security re-check: start guard review fold (700cfae2)

Read-only, 2026-11-10. Nothing edited or committed. `swift test --filter ControllerProviderGuardTests` passes (28 tests, scratch `guard-review/spm2`). The app test target (`AnotherTunnelActiveTests`, `OwnerTest1UITests`) was read, not run. Every scenario below is traced from the code, not reproduced.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `EA` = `Tunnel/EngineAssembly.swift`, `PTP` = `Tunnel/PacketTunnelProvider.swift`, `SEAT` = `Packages/TunnelEngine/Sources/TunnelEngine/Host/ProviderSeat.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `GT` = `Packages/TunnelEngine/Tests/TunnelEngineTests/ControllerProviderGuardTests.swift`.

## Verdict

No HIGH, no MEDIUM. H1 is closed under the decided policy: I found no path that leaves an `includeAllNetworks` profile down and open because of another LockPlus session, none where the preemption cancels the wrong provider under NE's normal contract, and none where the kill-switch start runs unbound. M1, M3, M4, L1, L2, L4, L5 are fixed. M2, L3 and N1 are fixed with the reservations below (L1, L2, N1 here). Five LOW findings and four NITs remain; none blocks 2.0.1.

## Original findings

| Finding | Status |
|---|---|
| H1 | Fixed (`TC:262-277`, `TC:294-301`). See trace below and L3 here. |
| M1 | Fixed (`TC:752-757`, `EA:81-84`). Residual: keyed by token, not lease (L2 here). |
| M2 | Fixed (`TC:263-264`). Reservation: L1 here. |
| M3 | Fixed (`TC:280-284`, leases, `bind` returns Bool). Residual: the late stop's `unbind` (L2 here). |
| M4 | Fixed: time limits, bounded awaits, `ProviderSeat` tested. Gaps listed under "Test quality". |
| L1 | Fixed (`CS:587-592`, `CS:903-907`). |
| L2 | Fixed (`refusalDetail`, new copy). |
| L3 | Fixed in the extension (`TC:1171-1181`); the app-side dedupe over-suppresses (L4 here). |
| L4, L5 | Fixed. |
| N1 | Not effective in its own scenario (N1 here). |
| N2 to N5 | Fixed. |

### H1 trace

Paths checked for "kill-switch profile left down and open":
- **K beside a connected, pending, held, sleeping or prompting split session:** preempted. A pending start fails with 223; a started session is torn down and then its own provider cancelled.
- **K latched (on-demand):** the latch is read first, the guard still preempts, then K is held with no I/O (closed).
- **K beside a route-protection session** (`policy.killSwitch` true, `includeAllNetworks` false): preempted. The test is `!s.includeAllNetworks`, which is the right flag.
- **A third start during K's teardown await:** a split start gets the session, K's loop re-checks and preempts it again. A second kill-switch start wins instead and K is refused: closed either way.
- **K refused:** only by another `includeAllNetworks` session (closed), or when `req.configuration` is nil (N3 here; that start fails open without any session too).
- **K ends with `.startCancelled`:** only after NE itself stopped or reused K's instance.

Wrong-provider and unbound paths:
- The cancel uses the owner captured before the teardown and `byToken`, never `current`. Both production `host.cancel` sites pass a non-nil owner.
- If B's own `stopTunnel` or `deinit` runs during the teardown, its `byToken` entry is gone and the cancel is a no-op.
- K binds only after the loop, with no suspension before `beginStart`. B's later `deinit` or stop `unbind` is identity-checked and cannot unbind K.
- `includeAllNetworks` is read from the NE protocol (`StartRequest.swift:88`), not from the app-written dictionary.

## LOW

### L1. The same-profile replacement runs before the policy checks and never cancels the old provider
- **Where:** `TC:263-264`, then `TC:278`.
- **Scenario:** two NE configurations carry one `ProfileKey` (a duplicated manager for one profile after a failed remove or save, one copy with the kill switch and one without). The second start replaces the first session with `stop(.superseded)`. The first provider is never cancelled, so NE keeps it Connected with nothing behind it, which is the shape the guard was written to remove.
- **Policy bypass:** a same-key start without `includeAllNetworks` replaces a kill-switch session, against "a non-kill-switch start beside a kill-switch session stays refused".
- **Open or closed:** closed on both orders. The old NE session keeps `includeAllNetworks` enforced, or the new one has it.
- **Fix:** in the same-key branch, refuse when the session has `includeAllNetworks` and the start hasn't. When the replaced session has no `includeAllNetworks`, cancel its own provider after the teardown, as `endForKillSwitch` does. Add a test for each.

### L2. The per-owner host map is keyed by token, so a late cancel or unbind can hit a reused instance's newer start
- **Where:** `EA:49`, `EA:56`, `EA:62-71`, `EA:82`; `SEAT:47-48`.
- **Scenario 1:** A's session ends (`cancelAfterTeardown` or `endForKillSwitch`), and the teardown runs for up to about 6 s. NE reuses A's instance for a new start that is accepted and bound in that window. The late cancel looks up `byToken[A.token]` and cancels the new start's provider with the old error.
- **Scenario 2:** a reused instance's generation-1 stop Task finishes after generation 2 was bound. `stop(owner:)` is correctly ignored, but `unbind()` on `SEAT:48` still removes generation 2's binding. The session then runs with no provider: `apply` fails with "no provider" (held and retried under the kill switch, failed otherwise).
- **Reachability:** both need NE to deliver a new `startTunnel` on the same instance before the old cancel or stop completed. Not expected from NE, not measured. Closed for a kill-switch session.
- **Fix:** store the lease generation in `Bound`; `bind(_:lease:)`; `cancel` and `unbind` act only when the stored generation matches the caller's lease.

### L3. A kill-switch start that NE already stopped still ends the split session
- **Where:** `TC:257-279` preempts; the starter's own lease is checked only at `TC:280`.
- **Scenario:** K's `stopTunnel` is delivered before K's start Task reaches the actor (start and immediate stop, by the user or by `scutil --nc start K; scutil --nc stop K`). The start preempts B, then finds its own lease stale and ends with `.startCancelled`. B is gone and K never runs. For a route-protection B its protected routes are then open.
- **Weight:** another local user can already end B by starting K (accepted, DESIGN §1.3 A2); this makes it happen for a start that never existed from NE's side.
- **Fix:** check `providers.isCurrent(owner)` at the top of each loop iteration, before preempting or replacing, and keep the check at `TC:280` for the stop that lands during the await. Add a test: K stopped before its start runs leaves B connected.

### L4. The 5-minute dedupe hides a later, different refusal of the same profile
- **Where:** `CS:608-622`. `refusalNotedAt[id]` is never cleared.
- **Scenario:** B is refused beside A, with one Diagnostics line. The user disconnects A, connects C, and starts B from System Settings two minutes later. The hero stays on C, `repeated` is true, so there is no Diagnostics line and, for a kill-switch B, no notification. The refusal is silent, which the store's own contract rules out ("never silent").
- **Fix:** clear `refusalNotedAt[id]` when `id` becomes active and when the set of active profiles changes, or key the dedupe on (profile, blocking profile).

### L5. A late cancel reads an `unowned` provider outside the lock
- **Where:** `ProviderHost.swift:28`, `ProviderHost.swift:48`; `EA:82-83`.
- **Scenario:** M1 and H1 now cancel a provider that is deliberately not the current one, up to about 6 s after its session ended. If NE releases that provider between the map lookup and `cancelTunnelWithError`, or the provider is already in `deinit` waiting for the lock in `unbind`, the `unowned` load traps and the root extension dies with every session in it.
- **Status:** same class as the existing `apply` and `setReasserting` on `current`; the new late cancels widen the window slightly.
- **Fix:** hold the provider `weak` in `RealProviderHost` and no-op when it is nil.

## NIT

- **N1.** `TC:1043` waits on `teardowns`, but `stopSession` empties that dictionary (`TC:1063-1064`) before it awaits. In review N1's own scenario (A's late stop after B replaced A's session) the dictionary is already empty and the ignored stop returns before A's engine has stopped. Fix: drop `teardowns = [:]`; each task removes itself (`TC:1103`). No test covers it.
- **N2.** `EA:82`: `owner.map { … } ?? s.current?.host` depends on which `??` overload the compiler picks. It behaves as documented today (an owner that isn't in the map gives nil, not `current`). Write it as an explicit `if let owner` so the next edit can't change that silently. `ProcessProviderHost` has no test.
- **N3.** `TC:256`: with a `providerConfiguration` that fails to parse, `req.configuration` is nil, so the start has no kill-switch priority and no hold even when the NE protocol has `includeAllNetworks`. Not new. Carrying the protocol flag beside the optional configuration would close it.
- **N4.** A sticky 223 from `fetchLastDisconnectError` can be read at a later clean stop elsewhere of the same profile ("stopped: another profile with the kill switch took over" plus "disconnected unexpectedly"). Same class as L1 of the first review, for any provider-cancel code where `attemptStartedAt` is unset; 223 adds one more code to it. Also `refusalSavedAt` (`TC:208`) grows by one entry per refused `ProfileKey` and is never pruned.

## New code paths

- **ProviderSeat:** clean. The synchronous marks come before the Tasks. If `stopTunnel` interleaves with `startTunnel`, the start ends with `.startCancelled`. An instance that never started stops nothing.
- **ProviderLease and generations:** clean in the controller (`stop`, `sleep`, `wake` and the start loop compare leases or `isCurrent`). The process host still works on tokens (L2 here).
- **Per-owner host map:** no leak. An entry is removed by the stop's `unbind` or by `deinit`, and a failed start's provider is freed and unbound in `deinit`. A cancelled provider's entry and its live mark stay until NE frees it, which nothing depends on. Lifetime hazard: L5 here.
- **Preemption racing a concurrent start:** at most one session and none overwritten (trace above). In theory an on-demand split start that re-enters during every teardown await delays K, but K's start is pending for that time.
- **L1 freshness window:** see open point (c).
- **L3 coalescing:** the extension side hides nothing. The in-memory `lastErrors` time is updated on every refusal, the app reads it over XPC, and any later `save()` writes it. The app-side dedupe does hide a refusal (L4 here).
- **L2 unseen-session detail:** clean. The sentinel is app-local and cannot collide with the extension's constant detail. If the blocking session ends between the refusal and the read, the copy wrongly says "another user's", which is cosmetic.

## Open points

- **(a) Preempting a route-protection split session opens its routes while K is pending: accept.** B stays NE-Connected with no engine during the teardown (its routes are black-holed), and the cancel comes last, so the order is already the safe one. After the cancel, B's destinations are exposed only if NE does not block for a pending `includeAllNetworks` start while a second configuration existed. E14a measured that block for one configuration only. Refusing K instead is the H1 hole, which is worse. Record the two-configuration measurement as open in §20 risk 27. L3 here removes the one case where B is ended with no K start behind it.
- **(b) M2 keyed on the app-asserted `ProfileKey`: accept, with L1 here.** Only the signed app writes `providerConfiguration`, and another user's copy asserts that user's own uid, so another user cannot produce a colliding key. The realistic collision is a duplicated manager, and that case is closed.
- **(c) The 10 s window: accept.** Both sides read the same wall clock, and nothing security-relevant depends on it. Too wide costs a wrong Diagnostics line, and only if a second never-active end happens within 10 s without the extension recording a newer error. Too narrow costs a missed line or notification if the app sees `.disconnecting` more than 10 s late. For app-issued starts the existing M8 check already narrows it to 1 s. No boundary test exists.
- **(d) NE pacing of refused on-demand starts: accept for 2.0.1, measure.** The extension's cost per refusal is one provider instance, one actor hop and one in-memory write. The app's is larger and is not deduped: one `fetchLastDisconnectError` and one `tunnelSnapshot` XPC call per refusal, before the 5-minute check. If the measured cadence is faster than about one per second, hold a repeated non-manual refusal's completion for 1 to 2 s before throwing; NE waits for the start completion, so that paces it without a latch.
- **(e) NE behaviours only faked: none can turn a closed state open, but four need the VM before the 2.1 work builds on them.**
  1. `cancelTunnelWithError` on a provider that is not the latest started one, while another provider's start is pending in the same process: does NE end only B, and leave K's start alone?
  2. Whether NE blocks traffic for K's pending start while B is still connected or being cancelled (point (a)).
  3. Whether NE restarts an on-demand B after the 223 cancel, and at what pace (point (d)).
  4. K's `setTunnelNetworkSettings` before NE has removed B's utun. If both profiles get the same tunnel address, `UtunSelector` reports "ambiguous utun" and K's first attempt fails with `.tunDeviceFailed`. That is retryable, so K is held and retried: closed, but a visible delay.
  Also unmeasured and relied on: no `stopTunnel` after a cancel with two sessions (measured for one, S2 E3), and that NE never reuses an instance before its stop or cancel completed (L2 here).

## Test quality

Good: the M4 fixes are real (a regression now records a named Issue within 5 s), the concurrency tests assert symmetrically, the M1 test checks the cancel's owner, and the seat test fails if either synchronous mark is dropped.

Gaps:
- `GT:45-50` always sets `policy.killSwitch` and `includeAllNetworks` together. No test preempts a route-protection session (`killSwitch` true, `includeAllNetworks` false), which is the case of open point (a), nor a split session in an after-Connected hold.
- No test for preemption with a third start during the teardown await, for K stopped before or during the preemption (L3 here), or for a latched on-demand K preempting a split session (the latched test covers kill switch against kill switch only).
- The M2 test (`GT:313-322`) asserts only the replacement: not the old instance's late stop, not the cancel behaviour, not mixed flags (L1 here).
- No test for a reused instance's late cancel or late unbind (L2 here), and `ProcessProviderHost` itself is untested (N2 here).
- N1 has no test, which is why its fix not working went unnoticed.
- App: no boundary test for the 10 s window, and none for a second refusal after the blocking profile changed (L4 here).

---

**Fixes.** `787f15af` (same-profile rule, lease-keyed bindings, weak host); the Codex findings were folded in `b1346c48` (no same-profile override of a live lease, tested router dispatch).
