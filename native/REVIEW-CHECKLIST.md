# LockPlus native: review checklist (P2a)

Every PR touching `native/` goes through this list (DESIGN §12.4, §18 "Definition of Done"). `Tools/build/lint.sh`
and `.swiftlint.yml` catch what a regex can catch; the reviewer checks the rest. Fable reviews every item marked 🔒
(extension, keychain, parser and XPC code, and every SAFETY-marked escape).

## Concurrency (§0 MUST, ref/swift-concurrency §0)

1. **Framework closures are `@Sendable`.** Every closure handed to an XPC, NetworkExtension or Dispatch API (proxy error
   handlers, reply blocks, `interruptionHandler`/`invalidationHandler`, `sendProviderMessage` replies, the
   `fetchLastDisconnectError` completion, NE `saveToPreferences`/`loadAllFromPreferences` completions,
   `DispatchSource` handlers, `DispatchQueue.async`) is spelled `@Sendable` or built in a `nonisolated` function.
   Inside a `@MainActor` type an unannotated closure inherits main-actor isolation and traps on the framework's queue
   (S5.2, S15 crashes).
   - ✅ `c.invalidationHandler = { @Sendable [weak self] in Task { await self?.didInvalidate(gen) } }`
   - ❌ `c.invalidationHandler = { [weak self] in self?.didInvalidate(gen) }` inside a `@MainActor` class
2. **`main.swift` has no closure literals** (D73-11). Top-level code is main-actor isolated in Swift 6; an ASan hook, a
   C library's log/signal callback or anything registered at process start traps when called on another thread.
   `main.swift` only calls functions; hooks live in `nonisolated` functions or C files elsewhere.
   - ✅ `TunnelProcess.startSystemExtensionMode()` (the `autoreleasepool { … }` lives in TunnelProcess.swift)
   - ❌ `__asan_set_error_report_callback { report in … }` at the top of `main.swift`
3. **C-callback trampolines** (`@convention(c)`, OpenVPN3Shim callbacks, the Go log callback, sanitizer hooks) are
   defined in a `nonisolated` context, capture nothing, touch only `Sendable` state (`Mutex`, `Logger`, `LogRing`) and
   never assume the main actor or call back into Go.
4. **Exported XPC objects and NE/SystemExtensions delegates are nonisolated.** Delegate witnesses on a `@MainActor`
   type are `nonisolated` and hop with `MainActor.assumeIsolated` only when the request was created with
   `queue: .main` (SAFETY comment citing the header line).
5. **Every unsafe escape has a `// SAFETY:` comment** citing its contract: `@unchecked Sendable`,
   `nonisolated(unsafe)`, `MainActor.assumeIsolated`, `@preconcurrency`, `DispatchSemaphore`. 🔒
6. **Continuations resume exactly once** through `OneShot`; timeouts are timers on that gate, never a `TaskGroup`
   race around non-cancellable work. Catch sites use `do throws(LPError)`.
7. **State is re-checked after every `await`** inside actors (reentrancy); stale callbacks are dropped by generation.
8. Retry loops use the design's backoff (TunnelEngine `Backoff`, the §5.4 hello retry policy); no ad-hoc sleeps.

## XPC (§5) 🔒

9. Nothing secret is sent before `hello`'s reply arrived on the same connection object, and again after every
   interruption (`provisionProfile`, `updateCredentials`, `answerAuth`).
10. Requirements: `APP_REQ`/`EXT_REQ` come only from `Shared/ActiveRequirements.swift` and reach package code as init
    parameters; no package code calls `setCodeSigningRequirement` with `SigningRequirements.releaseSigner` directly.
    The listener sets the requirement once (no second call in `shouldAcceptNewConnection`).
11. Every handler replies exactly once on every path within `LPMethod.serverDeadline`; decode with the method's cap
    before anything else; profile-scoped calls check `ownerUID` against `peer.uid`.
12. Profile-scoped events go only to the owner's uid; others get `.anyTunnelStateChanged`.
13. 4102 is never retried and never triggers a reinstall; a timeout never invalidates the connection.

## Security invariants (§1.4)

14. No secret in logs, `NSError.userInfo`, XPC error strings, `providerConfiguration`, `UserDefaults` or plaintext files.
    `LPError.detail` never carries secrets or server-controlled text.
15. The extension links no AppKit/SwiftUI/Sparkle/ZIPFoundation; no `exit(` in the extension; no `com.apple.security.cs.*` or
    `get-task-allow` on the extension (`verify.sh static`, `check-entitlement-sources.sh`).
16. No `#filePath` in shipped code; no settings-level `includeAllNetworks`/`excludeLocalNetworks`/`enforceRoutes`.
16a. **S2 rules (DESIGN draft 9, lint enforces the first three):** extension deadlines use the injected clock
    (`StrictSuspendingClock` in production), never `asyncAfter`/`Task.sleep`; `cancelTunnelWithError` only in
    `RealProviderHost`, called only with the kill switch off and only after the teardown; no name resolution in the
    extension except `GetAddrInfoResolver` (kill switch off, 2 s); no provider-originated connection besides the engines'
    transport (S2 E5: it bypasses the tunnel); start options carry nothing one-shot (NE replays them, S2 E1).
17. `LP_DEV_SIGNING` appears only in `Debug.xcconfig` (and via it `FaultInjection.xcconfig`), never as a target-level
    override in `project.pbxproj` (`verify.sh static` checks `-showBuildSettings -configuration Release`).

## Build and project

18. New sources go into the synchronized folders (`App/`, `Tunnel/`, `Shared/`, `Tests/…`); non-code files that must not
    ship (scripts, notes) stay outside `App/`. Build settings change only in `Config/*.xcconfig`, never in the project.
19. New third-party dependencies need the owner's approval (CLAUDE.md "ask first"). ZIPFoundation is approved (draft 9.1,
    pinned 0.9.20, app target only): only `App/Services/ProfileZip.swift` imports it, every read passes
    `ZipStructure.validate` first, nothing is extracted to disk (lint), and the extension never links it (`verify.sh`,
    `check-symbols.sh`). An upgrade re-runs `docs/native/reviews/2026-10-27-zipfoundation.md` on the diff.
20. Nothing writes to `/tmp`; build output goes under git-ignored `native/build/`.
