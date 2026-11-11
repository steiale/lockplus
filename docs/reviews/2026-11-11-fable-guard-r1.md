# Security review: start guard (91a0c318) and onboarding step 3 (c2db6532)

Read-only review, 2026-11-10. Nothing edited or committed. `swift test --filter ControllerProviderGuardTests` passes (13 tests). Nothing was mutated to reproduce a finding: every scenario below is traced from the code, not run.

Paths are relative to `native/`. `TC` = `Packages/TunnelEngine/Sources/TunnelEngine/Controller/TunnelController.swift`, `CS` = `App/Stores/ConnectionStore.swift`, `PTP` = `Tunnel/PacketTunnelProvider.swift`.

## Verdict

The guard does what it claims for the measured bug: a start beside another live instance's session is refused, never bound, and the running session, its host binding and its packet flow are untouched. The check-then-create is atomic on the actor, and I found no way to displace a live session through start, stop or XPC.

It is not ready to ship as the last word on the kill switch. "First wins, no priority" turns the old fail-closed displacement into a fail-open refusal for a kill-switch profile (H1). Three smaller holes sit in the same area (M1 to M3).

## HIGH

### H1. A session that gets in first keeps a kill-switch profile down, and that failure is open
- **Where:** `TC:250-256` (refusal has no regard for `includeAllNetworks`); `CS:877` (no notification for 222); DESIGN §7.2 row ("this failed start is open (E14c) for the refused profile only: the running session keeps its own protection").
- **Scenario:** Kill-switch profile K is down but due back: NE's restart after a tunnel crash, the "No network available" restart, an on-demand start, wake. In that window split profile B (no kill switch) is started with `scutil --nc start` or System Settings. B gets the session. K's start is refused with 222, and a failed `includeAllNetworks` start is open, so the Mac runs on B's split routes with everything else in the clear, indefinitely.
- **Who can do it:** `TC:308-309` records that another local user can start our configuration (S2 E13, accepted for 2.0). So a local non-admin user can loop `scutil --nc start B` and win the race. A single user with on-demand on two profiles can hit it by accident.
- **Old behaviour:** last wins. K's restart displaced B. A hostile start of B over a running K black-holed K but NE kept `includeAllNetworks` enforced: denial of service, but closed. The new behaviour removes that DoS and adds a way to hold a kill-switch tunnel open.
- **Why the DESIGN sentence doesn't cover it:** "the running session keeps its own protection" is only true when the running session has the kill switch.
- **Visibility:** K's refusal sends no notification (`CS:877` suppresses `stoppedUnexpectedly` for 222 unconditionally). The user gets one Diagnostics line while the hero shows B connected.
- **Fix:**
  1. Priority rule: a start whose configuration has `includeAllNetworks` is not refused by a live session without it. End that session visibly instead: teardown, then `cancelTunnelWithError` on its own provider (needs the per-owner host handle from M1), then accept the kill-switch start. NE shows B disconnected, so there is no black hole.
  2. Kill switch against kill switch stays first-wins (closed either way).
  3. App: when the refused profile has the kill switch, keep a notification ("K couldn't start: B is connected. K's kill switch is not protecting this Mac").
  4. If the policy stays as is, record it as an accepted risk in DESIGN §1.3/§20 and correct the §7.2 sentence.
- **Not measured:** what NE does with traffic while an on-demand `includeAllNetworks` configuration keeps failing its start, and cross-user starts with two sessions (phase 0 lists both as open).

## MEDIUM

### M1. `cancelAfterTeardown` cancels whichever provider is bound when the teardown finishes
- **Where:** `TC:706-721`; `Tunnel/EngineAssembly.swift:75` (`ProcessProviderHost.cancel` goes to `current`).
- **Scenario:** A (no kill switch) hits an after-Connected fatal. `endSession` sets `session = nil` at once; `host.cancel(with:)` runs later in a detached Task after the adapter teardown (up to about 6 s: 1 s stats plus the 5 s stop cap). In that window B is started outside the app. The session is nil, so the guard has nothing to refuse; B is accepted and bound. The late cancel then calls `cancelTunnelWithError` on B's provider.
- **Result:** A stays Connected in NE with no engine (the measured bug's shape), and B is cancelled while the controller still runs B's session.
- **Status:** pre-existing, but it is the remaining path to "Connected with nothing behind it" and the guard does not close it.
- **Fix:** capture the owner's own host before `endSession` (a token to provider-host map in `ProcessProviderHost`, or `host.handle()` returning the bound `RealProviderHost`) and cancel that. Alternatively keep the session in `.stopping` with its owner until the cancel is issued. Add a test: fatal, then another instance's start during a slow `FakeAdapter.stop`; the cancel must go to A.

### M2. A restart of the same profile from a new instance is refused if the old instance is still marked live
- **Where:** `TC:250` compares tokens only, never `ProfileKey`.
- **Answer to "open or closed":** closed on every path I traced, but only because NE keeps its contract. There is no fallback if it doesn't.
  - `stopTunnel` marks the token stopped synchronously (`PTP:50`).
  - Failed starts and `cancelTunnelWithError` end the session before NE can start again (`TC:650-651`, `TC:715`).
  - A freed instance is marked in `deinit` (`PTP:83`); `RealProviderHost` holds the provider `unowned`, so the host binding does not keep it alive.
  - A reused instance matches `o == owner`.
- **Scenario if the contract breaks:** NE abandons A1 without `stopTunnel` and without freeing it while the controller still holds A1's session (held, reasserting, an nesessionmanager hiccup, behaviour on sleep/wake or user switch: none measured). Every later start is refused until the extension process dies, including A's own on-demand restart on a new instance A2. For a kill-switch A that is a tunnel left down and open.
- **App side in that state:** silent. `anotherProfileActive` is false, so `readRefusal` shows nothing (`CS:557`), and the notification is suppressed (`CS:877`).
- **Fix:** treat a session with the same `ProfileKey` as the request as stale and replace it (NE never runs two sessions of one configuration, so A2's start proves A1's session is over). Log a fault when a refusal hits an owner whose session NE has not touched for a long time. Add a test "same profile, new instance, old instance never stopped → replaced".

### M3. A start can begin after its own provider was stopped or freed
- **Where:** `TC:244-262` (no liveness check on `owner` before `bind()`); `PTP:92-96` (`ProviderRef.bind` is a silent no-op for a freed provider).
- **Scenario:** A2's start is suspended in `await stop(reason: .other(-1))` replacing a stale session (up to about 6 s). NE delivers A2's `stopTunnel`. The stop finds no session, unbinds and completes. The start resumes, sees `session == nil`, binds the stopped provider and begins a session NE believes is over.
- **Result:** a zombie engine and a stale host binding until the next start replaces it. If the provider was freed, `bind` does nothing and the session runs against whatever is still bound, or nothing.
- **Same family:** a reused instance whose `stopTunnel` and next `startTunnel` Tasks reach the actor in reverse order; the late stop matches `o == owner` and ends the new session.
- **Status:** pre-existing shape, now cheap to close.
- **Fix:** after the loop and before `bind()`, `if let owner, !providers.isLive(owner) { throw .of(.startCancelled) }`. Make `bind` return Bool and fail the start on false. Give `started()` a generation that `stop(owner:)` carries, for the reuse case.

### M4. The guard tests hang on regression instead of failing
- **Where:** `Packages/TunnelEngine/Tests/TunnelEngineTests/ControllerProviderGuardTests.swift:87, 110, 127, 139, 204` (`await w.start(b, …).value` with no bound).
- **Is the hang acceptable:** no. With the guard off, B displaces A and waits for an adapter nobody drives, so the suite blocks until the CI job is killed, with no named failing test.
- **Fix:** add `.timeLimit(.minutes(1))` to the suite; the app suites already use it (`Tests/LockPlusTests/E2E6FixTests.swift:17`). `AnotherTunnelActiveTests` lacks it too. Better still, a `value(within:)` helper that records an Issue naming the start that never completed.
- **Coverage gaps:**
  - Nothing covers the Tunnel target wiring. Moving `bind` back into `startTunnel`, or dropping `providers.stopped` from `stopTunnel` or `deinit`, fails no test. Extract a small testable shim or add a provider-level test.
  - No test for a refused on-demand `includeAllNetworks` start (latched and unlatched).
  - No test for a stop of the owner during another start's replace-await (M3), the misdirected cancel (M1), the same-profile restart (M2), or a refused instance's later accepted start on the same token.
- **What is good:** the two concurrency tests assert symmetrically (exactly one success, one 222), so they do not depend on Task order.

## LOW

### L1. A sticky 222 is trusted wherever another profile happens to be active
- **Where:** `CS:369-373`, `CS:519`, `CS:557`, `CS:877`.
- **Background:** `fetchLastDisconnectError` is sticky. M8's timestamp check (`CS:850`) only works when `attemptStartedAt` is set, which is app-issued starts only.
- **Scenarios:**
  - B was refused once. Later, started from System Settings, it connects and is ended cleanly elsewhere (`scutil --nc stop`, an on-demand disconnect). `observedDisconnect` maps the stale 222: the hero says "Another LockPlus profile is connected. Disconnect it first." and the "disconnected unexpectedly" notice is suppressed for a session that was connected.
  - With A active, any never-active `.disconnecting → .disconnected` of B posts a false "B couldn't connect: another LockPlus profile is connected".
  - `checkNoNetworkRefusal` ends a kill-switch hold as "NE won't restart it" on a stale 222 and runs `restoreIfIdle` inside what may be NE's restart.
- **Fix:** one helper for all three sites: accept 222 only when `tunnelSnapshot.lastErrorAt` is newer than this attempt's first status event, and never when `wasConnected`. At `CS:877` suppress the notice only for `!wasConnected`.

### L2. The refusal is silent when the app can't see the session that caused it
- **Where:** `CS:580-582` (`anotherProfileActive` reads `statuses` only).
- **Scenario:** the running session is another user's, or the stuck owner of M2. `readRefusal` and `checkNoNetworkRefusal` then show nothing. Through `observedDisconnect` the copy says "Disconnect it first", which this user cannot do.
- **Fix:** gate on freshness (L1), not on a visible active profile. Add a variant of the copy for "a VPN connection of another user or one LockPlus can't address" (`BusyReason.anotherUser` already exists).

### L3. Refusals have no backoff
- **Where:** `TC:252-255`.
- **Scenario:** an on-demand B beside a live A is retried by NE at its own cadence. Each try makes a provider, a plist write (`recordLastError` then `save`), a notice log and, app-side, a fetch plus a Diagnostics line (`ProfilesStore.note` does not dedupe, cap 50, so real problems get pushed out).
- **Fix:** skip the write when the stored error is already 222 and under N seconds old, or update `at` in memory and coalesce the save. Dedupe the Diagnostics line per profile. Not measured: whether NE honours on-demand on a second configuration at all.

### L4. `sleep()` and `wake()` are not owner-aware
- **Where:** `PTP:59-70`, `TC:955-990`.
- **Scenario:** any provider instance's sleep or wake drives the one session. Benign today (a refused instance has no NE session), but it is the same assumption the guard just removed for start and stop.
- **Fix:** pass the token and ignore calls from a non-owner.

### L5. Onboarding writes `step = .profiles` unconditionally after an await
- **Where:** `App/AppActions.swift:437, 445`.
- **Scenario:** `allowVPNConfiguration()` is also the main window banner's "Allow…" action (`App/UI/Main/MainView.swift:237`), so the step is written with onboarding not presented. It also runs after the system alert, however long that stays up.
- **Impact today:** none. Both presentation sites set the step themselves (`AppEnvironment.swift:543`, `AppActions.swift:72`), and Continue is disabled while `.requesting`.
- **Fix:** `if env.ui.onboarding.isPresented, env.ui.onboarding.step == .allowConfiguration { … }`.
- **Rest of the state machine:** clean. `.denied` and `.deferred` do not auto-advance, so the deferred message is still read. Re-entry with `.done` shows a plain Continue. The migration flow enters at `.profiles`.
- **Test gap:** the test covers only the no-profile branch. Add the allowed-with-profile and deferred branches (step stays).

## NIT

- **N1.** `PTP:53-55` with `TC:999-1002`: an ignored stop returns before the instance's own adapter teardown has finished, so NE's stop completion can precede it. A replaced session's summary also says `other(-1)` instead of the real stop reason.
- **N2.** `vpnConfigurationDenied` is only ever set to true (`AppActions.swift:451`, `UIBinder.swift:280`). The banner stays after a successful "Allow…". Pre-existing, next to the changed code.
- **N3.** `TC:254`: `lastErrors` is written under the app-asserted key before any payload ownership check. Same class as the other pre-validation failures (`TC:312`). Constant detail string, no secret, root-owned plist.
- **N4.** DESIGN §7.2 "of two racing starts exactly one runs": with a third start during the teardown await, the refused one is refused by the third's session. True, but word it as "at most one session, never overwritten".
- **N5.** `Host/ProviderInstances.swift`: `live` only shrinks through `stopped` or `deinit`. Fine with the `unowned` host. Add a comment that anything retaining a provider breaks the "freed" rule.

## Checked and found clean

- **Atomicity:** `TC:244-262`. `stop()` runs synchronously up to its first real suspension, so check and teardown are one step. After each await the loop re-checks. `withCheckedContinuation` inherits the actor's isolation (tools 6.2), so there is no hop between the last check and `beginStart`. A second start cannot overwrite a session or leak its continuation.
- **Refused start touches nothing of A:** no bind, no `apply`, no cancel, no sink event, no latch, no `clearLatch`, no prepared-answer take. A's `lastError` is untouched.
- **Refusing B never unbinds A:** `ProcessProviderHost.unbind` is identity-checked, so the refused instance's `stopTunnel`, `deinit` and `ref.unbind()` are no-ops for A. `stop(owner:)` ignores a non-owner. A held kill-switch session (before or after Connected) is not displaced.
- **Late stop:** A's stop arriving after B replaced A's stale session is ignored.
- **Token reuse:** a UInt64 counter under a Mutex, never an address; no reuse.
- **NE or extension restart, update quiesce:** ownership is in memory only. A new process starts clean, and nothing persisted can refuse a start.
- **Other callers:** no production caller of `start` or `stop` without an owner except the internal replace. The XPC paths that end sessions (`endWaitingStart`, `profileRemoved`, `secretsWiped`) are keyed by the caller's uid and the session key, so another user cannot use them to end or hold a session.
- **Late bind into a freed provider:** cannot crash. `ProviderRef` is weak, and `deinit` unbinds before the `unowned` reference could dangle. It can only no-op (M3).
- **Sleep:** `disconnectOnSleep = false` (`ManagerStore.swift:231`), so sleep adds no stop/start cycle of its own.
- **App:** the refusal never touches the running session's hero or status and issues no stops. A kill-switch profile's 222 does not enter the "may restart" hold through `observedDisconnect` (`CS:845`). `surfaceRefusal` reuses the existing rule.
- **Error code and copy:** `LPErrorCode` 222 bridges with domain and detail; EN/DE copy present.

---

**Fixes.** `700cfae2` (kill-switch priority, cancel goes to the ended session's own provider, leases, freshness).
