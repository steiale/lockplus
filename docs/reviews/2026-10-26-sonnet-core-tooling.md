# Sonnet first-pass review: core, app root, tooling (2026-10-26)

Fix ALL. Overlaps with the Fable review are marked (→ Fable id).

## High
1. **`Tools/release/verify.sh:31-33, 40-41`: the release gates can silently pass.** `! strings … | grep -q X || fail` under pipefail: `grep -q` exits early, the writer gets SIGPIPE (141), and `!` turns that into success. A probe confirmed the bypass. Also, `-showBuildSettings … 2>/dev/null | grep -q` passes when xcodebuild fails. **Fix:** capture the output first (`out=$(strings -a "$m")`; `grep -q X <<<"$out"`), and assert that the build settings are non-empty and contain `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. Audit EVERY script in Tools/ for the same `| grep -q` pattern under pipefail.

## Medium
2. **`Tools/release/macho-hashes.sh:5-7` exits 1 when the last file isn't a Mach-O.** That breaks the CI repro job and release.sh. **Fix:** `if …; then printf; fi`.
3. **The 4102 poisoned state is never cleared.** `resetAfterUserAction()` has no caller (`ExtensionStore.swift:38,45`, `TunnelServiceClient.swift:110`). **Fix:** call it from `retryAfterUserAction()`/`reinstall()` and clear `.failed(.unauthorizedPeer)`.
4. **`SystemExtensionManager`: `.deactivating` is a trap state** (`.ignored` at :162/:179, guidedRemoval timeout :212; `activate()` returns at :103). **Fix:** `defer` restore on every exit; `.ignored` throws or returns a distinct "cancelled" outcome; DebugMenu `try?` must not hide it.
5. **The unclamped `RecentLogsRequest` decode can trap the root extension** (LPWire `RequestReplies.swift:97-102`, `EngineServiceBackend.swift:75`, `Primitives.swift:84-86 LogRing`). → The Fable M1 fix removes recentLogs. Still: validate EVERY request type in `init(from:)` (ranges, counts, sizes), use clamped arithmetic in LogRing if it's kept internally, and add a decode-fuzz test over all request types.
6. **The busy indicator never fires.** `noteSuccess()` is called even on a server `LPError(.timeout)` (`TunnelServiceClient.swift:233-236`), and the client throws `.timeout` where §5.4 says `.extensionBusy`. **Fix:** a server-side timeout counts as a timeout, and client-timer timeouts map to `.extensionBusy`.
7. **CI doesn't run what it claims** (→ Fable L7):
   - the fuzz-smoke and engine-support jobs are missing;
   - Tests/TunnelAdapterTests isn't in the `swift test` loops;
   - LockPlusCore isn't in the TSan loop;
   - `test-without-building` passes with zero tests.

   **Fix:** add the jobs and loops, and use `-resultBundlePath` with a test-count assertion.
8. **`activate()` is reentrant** (`SystemExtensionManager.swift:100-106`): two submissions, then `.ignore` sets `.unknown` while the second is pending. **Fix:** an in-flight flag before the first await; `.ignore` leaves the state as it is.

## Low
9. **Hello gate** (`TunnelServiceClient.swift:231`, 168-176): the post-await recheck `helloTask == nil` misses an in-flight hello. → Fable M3 fixes it with a validated generation (`validatedGeneration == currentGeneration`). Also, a retry loop that sees an interrupt leaves `helloTask` nil and `interruptedSinceHello` true, which flickers `.reconnecting`. Mark the hello validated when the generation is unchanged.
10. **`Tools/build/check-symbols.sh:15` samples ONE WireGuardKitC .o**, which can be the wrong arch. **Fix:** check all objects for the active arch or the merged object; `find | head -1` under pipefail is a SIGPIPE risk.
11. **Scripts:**
    - `Tools/dev/build.sh:13` and `Tools/ui/render-screenshots.sh:7` need `mkdir -p build`. (`render-screenshots` is UI-owned, so just note it.)
    - `openssl.sh:41-43` should assert minos 26.0 and arm64-only.
    - `build-unsigned.sh:11` skips vendor.sh when `.git` dirs exist. **Fix:** run vendor.sh unconditionally so the pins are always checked.
12. **`LPRouteProbe/RouteProbe.swift:22-24,54-60`:** `getaddrinfo` has no timeout and runs serially. **Fix:** a per-endpoint deadline (3 s) and concurrency.
13. **`OVPNNormalizer.swift:179` vs 132-139:** `<connection>` child args skip the control-character check. **Fix:** apply it to children; add a test.
14. **`LPModel/SecretBytes.swift:20-28`: latent double free.** The catch path deallocates, then deinit runs again. **Fix:** remove the manual cleanup.
15. **`LegacyKeychainDecoder.swift:35-37`:** copy-on-write means only a copy is zeroed. **Fix:** zero the originals, or work on a single buffer.
16. **`ListProvisionedReply.maxEntries` 500 vs the 64 KiB reply cap:** too close. **Fix:** derive the cap from the byte limit or use 100; pre-check `requestLimit` before sending.

## Simplifications
- `ExtensionStore` mirrors `TunnelServiceClient.Link/Status`. Expose the client's Status directly.
- `TunnelServiceClient.swift:276-279`: the per-call timer Task is never cancelled. Cancel it on completion.
- `SystemExtensionManager`: merge the three `ObjectIdentifier` dictionaries into one `[ObjectIdentifier: Pending]`.
