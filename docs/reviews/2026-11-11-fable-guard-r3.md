# Final security review: start guard after 787f15af and b1346c48

Read-only, 2026-11-10, HEAD d7d17cc4. Nothing edited or committed in the repo.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `GT` = `Packages/TunnelEngine/Tests/TunnelEngineTests/ControllerProviderGuardTests.swift`, `HOST` = `Packages/TunnelEngine/Sources/TunnelEngine/Host/`.

## Verdict

No HIGH. The code is correct for the decided policy, and every earlier finding stays fixed. It is not unconditionally release-clean: one MEDIUM is about the b1346c48 trade-off, which DESIGN records as closed when it is open for a kill-switch profile. That needs a decision and a doc correction, not a code fix, before 2.0.1. Two LOWs and four NITs do not block.

What was run:
- `swift test --filter ControllerProviderGuardTests` in TunnelEngine: 44 tests pass (scratch `guard-review/spm3`).
- Nine mutations of the guard and router code in a scratch copy (`guard-review/mut`); results under "Test quality".
- The app suite (`AnotherTunnelActiveTests`) was read, not run. All scenarios below are traced from the code, not reproduced.

## MEDIUM

### M1. The abandoned-instance trade-off is open for a kill-switch profile, and DESIGN says closed
- **Where:** `TC:266-285` (no same-profile exception); `docs/native/DESIGN.md:4325` ("a closed denial of service", "none can turn a closed state open"); `DESIGN.md:2318` ("either way the running session's kill switch keeps the Mac closed").
- **Scenario:** NE drops instance K1 without `stopTunnel` and without freeing it, while the controller still holds K1's session (connected, held or pending). K1's lease stays current. NE's next start of K, on K2, is refused with 222. A failed `includeAllNetworks` start is open (E14c, as `TC:237-238` itself says), and NE no longer enforces K1's session. The Mac is open.
- **How long:** every retry is refused until the extension process exits. No app path ends a connected session the app sees as disconnected (`profileRemoved` and `endWaitingStart` end only a waiting start), so the user has no recovery short of a reboot.
- **Wider than recorded:** the stuck session blocks every profile that doesn't outrank it, not only its own. A stuck kill-switch session refuses all starts; a stuck split session refuses all split starts.
- **Is it reachable from our code:** no. I traced every path where NE ends a session without `stopTunnel` (failed start completion, `cancelTunnelWithError` at `TC:312` and `TC:771`, `endWaitingStart`); each clears `session` first. Preemption, refusal, reuse and late stops cannot produce it either.
- **How likely:** low, and unmeasured. It needs NE to break its stop-or-free contract. The one candidate I can name is an `nesessionmanager` crash or restart with the extension process surviving; I expect the process to die with it, but nobody has measured that.
- **Visibility:** not silent. The app shows row 14 with the "session LockPlus can't see" copy and posts `.killSwitchStartRefused` once per 5 minutes; the extension logs a fault (`TC:277-278`).
- **What changed:** the removed same-key rule was the user's way out of this state (reconnecting the profile replaced the stuck session). Codex 3 is right that `ProfileKey` equality doesn't prove the incumbent is dead.
- **Fix, minimum for 2.0.1:** correct `DESIGN.md:4325` and `:2318`: for an `includeAllNetworks` profile this state is open, it blocks all profiles of equal or lower priority, and recovery needs the process to exit. Record it as an accepted open risk and add the `nesessionmanager`-restart measurement to the VM list.
- **Fix, proper (2.0.2 or 2.1):** identify the NE configuration, not the profile. The app writes a random per-manager ID into `providerConfiguration` at save; a start with the incumbent's own configuration ID proves that session is over (NE never runs one configuration twice) and replaces it. Duplicates have different IDs and stay first-wins, so Codex 3 holds too.
- **Cheaper alternative:** when the incumbent has the same key and both have `includeAllNetworks`, keep the new start pending and re-check instead of failing it. A pending `includeAllNetworks` start is blocked (E14a, one configuration), so both the duplicate and the abandoned case stay closed, and no live lease is displaced.

## LOW

### L1. `endSeenAt` outlives its attempt, so an old 222 can pass the freshness check
- **Where:** `CS:361` (set only at a never-active `.disconnecting`), `CS:759` (cleared only when the configuration vanishes), read at `CS:537`.
- **Scenario:** kill-switch profile K without on-demand is refused once at T0 (`endSeenAt[K] = T0`, snapshot 222 at T0). Later an app-issued start of K ends with `.disconnected` and no `.disconnecting`, with NE's sticky 222 and no newer extension error. `checkNoNetworkRefusal` calls `isFreshRefusal(since: T0)`, which passes however old T0 is.
- **Result:** the "may restart" hold is cleared, `restoreIfIdle` runs inside what may be NE's restart, and row 14 plus the kill-switch notice report a refusal that didn't happen. App bookkeeping only; nothing opens.
- **Fix:** clear `endSeenAt[id]` when `id` reports an active status and when a start is issued, or capture it at the `.disconnected` event, pass it to `readRefusal`/`checkNoNetworkRefusal`, and clear it there. Add a test: old refusal, then an issued start ending in a bare `.disconnected`.

### L2. Three behaviours have no test (mutations survive)
- **Packet-flow swap:** removing every `flow.set` from `HOST/ProviderHostRouter.swift:23-36` fails nothing. The "binding and packet flow change under one lock" claim is untested. Production uses `.utunFD`, so only the FaultInjection data plane is exposed. Add a router test: bind A, bind K, read/write reach K's `FakeFlow`; A's late unbind leaves it; K's unbind or release detaches it.
- **Incumbent liveness by lease:** `providers.isCurrent(o)` at `TC:266` can become `isLive(o.token)` with all tests green. Missing case: another instance's start beside a session whose owner instance NE has since reused (must be replaced, not refused).
- **Stop of a stale session:** dropping `providers.isCurrent(o)` from `TC:1054` fails nothing. Missing case: an instance's stop while the session belongs to a different, no-longer-current lease.

## NIT

- **N1.** `GT:598`: the "late cancel reaches nobody" assertion waits a fixed 100 ms. It catches today's regressions (mutations a, b, i fail it) but would pass a cancel that arrives later. Wait on a positive signal, such as the teardown task finishing.
- **N2.** Stale text: `HOST/ProviderInstances.swift:23-24` and `DESIGN.md:2235` still say `RealProviderHost` holds the provider `unowned`; `GT:12-13` still lists "the same profile (review M2)" as an exception.
- **N3.** `CS:913`: exempting 222 from the 1 s M8 filter (Codex 5) widens the window to 10 s for app-issued starts too. A start that fails with no extension error within 10 s of an earlier refusal is labelled as refused. Cosmetic.
- **N4.** `GT:88-98`: unrouted worlds also bind the unused router. Harmless; a `routed` guard would make the intent clear.

## Previous findings

All stay fixed in the current code.

| Source | Status |
|---|---|
| Review H1 (kill-switch priority) | Fixed: `TC:271-275`, `TC:307-313`. |
| Review M1 (cancel to own provider) | Fixed: `TC:766-771`, router dispatch by lease. |
| Review M2 (same-profile restart) | Reverted by decision; see M1 above. |
| Review M3, M4, L1 to L5, N1 to N5 | Fixed. N5's comment is stale (N2 here). |
| Re-check L1 | Superseded by Codex 3: no same-key branch remains. |
| Re-check L2 to L5, N1 to N4 | Fixed: lease-keyed `ProviderBindings`, loop-top lease check `TC:261`, (profile, blockers) throttle, `weak` provider, teardowns stay listed. |
| Codex 1 | Fixed, and verified through the real router (mutations a, b, i fail). |
| Codex 2 | Fixed: `TC:261` and `TC:290` (mutations c, d fail). |
| Codex 3 | Fixed as decided; three duplicate-configuration tests. |
| Codex 4 to 7 | Fixed: `managerKillSwitch` at `CS:627` and `CS:955`; 222 skips the M8 filter; one throttle on both paths, reset only at `.connected` (`CS:299`); latch asserted in the snapshot first. |

## New router and bindings code

Clean.
- **Locking:** one `Mutex` for the bindings; the flow's own lock is taken only inside it (state, then flow), never the reverse. Host calls (`apply`, `cancel`, `setReasserting`) run outside the lock.
- **Lifetime:** a start's entry goes at its own unbind or at `deinit` (`release` removes by object identity whatever the lease). A reuse overwrites the older generation's entry. A cancelled provider's entry stays until NE frees it; nothing depends on it.
- **Weak providers:** `RealProviderHost` and `ProviderRef` both hold the provider weakly; a late cancel, apply or bind on a freed provider is a no-op or a failed start. Nothing in the Tunnel target retains a provider, so `deinit` still marks it stopped.
- **Identity reuse:** `deinit` releases all bindings before the address can be reused, and unbind checks identity and lease.
- **Packet-flow swap:** correct by reading; untested (L2).

## App refusal paths

Clean apart from L1 and N3.
- **Throttle:** recorded once per (profile, set of active profiles), shared by both paths, reset only when the profile reaches `.connected` or its configuration vanishes. A refused start's `.connecting` doesn't reset it.
- **Kill-switch flag:** read from the manager at refusal time on both paths.
- **Freshness:** a 222 after a connected session is never a refusal; a 223 is dated against the disconnect with its own 30 s window.
- **Never silent:** every fresh refusal gives row 14 or a Diagnostics line; a kill-switch profile also gets the notice.

## Test quality

Good overall. Seven of nine mutations are caught, each by a test named for the behaviour:

| Mutation | Result |
|---|---|
| `host(for:)` ignores the lease | caught |
| `unbind` ignores the lease | caught |
| no loop-top own-lease check | caught |
| no post-loop own-lease check | caught |
| router cancel goes to current | caught |
| preempted session's cancel skipped | caught (9 tests) |
| router never touches the packet flow | **survives** (L2) |
| incumbent liveness by token, not lease | **survives** (L2) |
| stop ignores any other owner | **survives** (L2) |

The routed harness mode does exercise the production `ProviderHostRouter` with one `FakeHost` per start, and the routed tests assert on those hosts, not on the unused shared one. The Codex 1 test checks both generation hosts, which is what matters when both wrap the same provider object.

## Scratch left behind

`<build dir>/guard-review/`: `spm3`, `spm-mut` (build products), `mut` (package copy, restored to match the repo), `mut-tools/mutate.py`. All safe to delete.

---

**Fixes.** `32d37bcc` (duplicate kill-switch waits, live protection, reservation, early retire).
