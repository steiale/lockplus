# Sonnet first-pass review: tunnel side (2026-10-26)

`TE` = `Packages/TunnelEngine/Sources/TunnelEngine`; `OVPN` = `TE/Adapters/OpenVPN/OpenVPNAdapter.swift`. Fix ALL. Overlaps with other reviews are marked.

## High
1. **`Backoff.next` traps after about 69 attempts** (`TE/Core/Primitives.swift:36`, called from `TunnelController.swift:539`). `Duration * pow(2,68)` overflows `_Int128`, so the extension crashes after about 80 minutes of a kill-switch outage. **Fix:** compute in Double seconds and cap first (exponent ≤ 32). Add a 200-iteration test.

## Medium
2. **A CRV1 answer after Connected loses the cookie and the base password** (`OVPN:444-462` `provideAuth`, `:207-214`, `:269-270`, controller `answerAuth .live`). The server then rejects, which loops into the 3-rejection fatal. **Fix:** carry the challenge cookie and base credentials into `provideAuth`. Add a test for CRV1 after Connected.
3. **AUTH_FAILED after Connected doesn't set `rejectedStoredCredentials`** (`OVPN:271-273`). The stored password isn't cleared and the 60 s guard isn't armed, so the old password is resent (lockout risk). **Fix:** track whether stored credentials were used and set the flag in `terminal()`.
4. **Session summaries get stale or zero rx/tx** (`TunnelController.swift:782-790`, `stop()` ~736-760). **Fix:** take a final `adapter.statistics()` sample (with a short cap) before teardown on every end path. The test must stop without priming the stats.
5. **The W10 `pfTun.Close` may hang `wgTurnOff`** (patch 0003: `unix.Shutdown` doesn't wake a blocked read, per S11). **Fix:** poll with a timeout or a wake pipe, or use `os.NewFile` with a non-blocking fd plus the netpoller. Add a stop-latency test.
6. **A stale `runStarting` catch can fail the next session's start** (`TunnelController.swift:229-230`, `startingFailed:267`). **Fix:** add `guard ep == epoch` in the catch and in `startingFailed`.
7. **Provisioning wedges on an unreadable store item** (ContainerSecretStore `readFile` "format", SystemKeychainSecretStore `read` "item mismatch", against `index()`). **Fix:** `provision` treats an unreadable entry as absent and overwrites it.
8. **Event coalescing can drop `sessionEnded`/`authRequired`** (`TE/XPC/ConnectionRegistry.swift:91`: one `pending` slot for all kinds). **Fix:** coalesce snapshot kinds only and queue the others.
9. **`StartOptions.isManual` ignores the `lp.manual` marker** (`StartRequest.swift:22`). This overlaps a Fable nit. **Fix:** require `lp.manual == 1`.

## Low
10. **Sleep during an after-Connected auth prompt** (`TunnelController.swift:711-735`): the auth deadline is lost, and `wake()` arms the reassert budget while the prompt is still showing. **Fix:** stay in `.awaitingAuth` across sleep, or restore the phase and deadline on wake.
11. **`Attempt.finished()` never resolves if the thread never started** (`OVPN:231-247` vs `404-418`). **Fix:** set `current` after the stopping check, or mark `threadDone` on the bail path.
12. **WG `startWall` is taken after `turnOn`** (`WireGuardAdapter.swift:118` vs `:85`), so an early handshake is missed and connect takes about 5.5 s. **Fix:** capture it before `turnOn`.
13. **WG handle numbers are reused** (patch 0005 `storeHandle` picks the lowest free number). A late call can hit a new device. **Fix:** use a monotonic counter.
14. **The resend guard withholds the whole credential record** (`TunnelController.swift:226`). **Fix:** withhold only the username and password, and keep the key passphrase and proxy credentials.
15. **`promptResolved` is never emitted; `savedUsername` is never filled;** `budgetExpired` creates a stash for on-demand starts. **Fix:** emit `promptResolved` to other instances, prefill the username, and create no stash for on-demand starts (§8.4).
16. **The pump is only ended in `stop()`** (`:253`, `:753`). After a failed start, the next start reuses a pump that is reading the old flow. **Fix:** end and reset the pump on every session end.
17. **Smaller items:**
    - `PacketFlowPump.swift:114` traps on an empty packet (= Fable L3).
    - `UtunSelector` matches IPv4 only. **Fix:** support IPv6-only plans.
    - Fix the wrong "NE's is the lowest number" comment.

## Tests that don't test their claim (fix the tests)
- `ControllerStartTests.secondStartCallCompletesOnce`
- `PrimitivesTests.startOptionsManualMarker`
- `ControllerConnectedTests.sessionSummaryRecorded`
- `staleEpochEventsAndDeadlinesChangeNothing`: uses a real 20 ms sleep. **Fix:** use ManualClock.

## Simplifications / dead code
- **Drop the Swift `WireGuardKit` product** from LockPlusTunnel; only the `WireGuardKitGo` C symbols are used. Remove the patch-0009 and patch-0005 Swift hunks that then have no consumer. Strip the key-bearing `wgGetConfig`/`wgSetConfig` exports (= Fable simplification 3).
- **PacketFlowPump:** replace the reader thread and 200 ms poll with `DispatchSource.makeReadSource` (kqueue). This gives immediate cancel and no thread per attach. Implement it, keep the §7.3 behaviour (one pump per session, closes under the send lock, ≥1 MB buffers), and note the change of the "readers poll" MUST for the design fold-in.
- **Dead code:**
  - `TunnelController.swift:284` redundant condition;
  - `:702` `r == .noNetwork ? .pathChanged : .pathChanged`;
  - `:515-516` double assignment;
  - `stop()` unreachable trailing branch;
  - `:740` `{ _ = live; broker.live = nil }`;
  - `NetworkSettingsBuilder.swift:46` no-op branch;
  - `OVPN:298` `(wasReconnecting || true)`;
  - the four-layer no-op `teardown(disconnect:)` delegate chain;
  - `LPOpenVPN3Core.evaluateProfile` + `lp::probe(profile)` (test-only; also Fable simplification 6);
  - `LPTunnelError.nsError` unused.
