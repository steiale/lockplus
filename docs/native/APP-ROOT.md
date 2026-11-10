# LockPlus native: app root and preview mode

The decisions below are folded into DESIGN draft 8 (D8-17 to D8-28; §3.4, §4.1–§4.5, §6.7, §6.8, §10.4, §11, §12.1, §14.2); the E2E-1 and PF 50–55 changes into DESIGN draft 10 (D10-1 to D10-8; §3.4, §4.4, §9.3, §10.4, §11.2, §11.7). This file stays the how-to for preview mode and the map of `App/`.

## Launching the "no extension" preview mode

Preview mode runs the real app root (stores, actions, derived state, menu bar, windows) over simulated backends, with
no system extension. (It was the only way to run the app before the product profiles existed; DESIGN draft 10: they
do, and E2E-1 ran notarized product builds on the test VMs.)

```sh
cd native
Tools/dev/preview.sh            # unsigned Debug build into $LP_BUILD_ROOT/preview-dd (default ~/Code/lockplus-build), then launch in preview mode
Tools/dev/preview.sh --no-build # launch the last build
```

Preview mode exists in **Debug builds only** (Fable M1): a Release build ignores `LP_PREVIEW_MODE`/`LPPreviewMode`
and the XCTest environment, and `verify.sh static` fails if preview code is compiled into the Release app.

Manual equivalents: launch the Debug app with the environment variable `LP_PREVIEW_MODE=1`
(`open -n --env LP_PREVIEW_MODE=1 LockPlus.app`), or with the argument `-LPPreviewMode YES`
(Xcode: Scheme › Run › Arguments).

What preview mode does:
- System extension: simulated. "Installing…" for a moment, then ready. Uninstall reports a cancelled administrator
  dialog, so the "component still installed" sheet appears.
- NE managers and XPC: simulated. Connect goes `.connecting` → `.connected` with live rates. "Office" asks for a
  CRV1 code inside its first manual start (draft 9: answered into that start). "Remote Desk" has a static challenge,
  so it prompts before the start. `pushEndpoints` always answers `.notHeld` (preview starts never hold).
- Keychain: in memory. Profile files go to
  `~/Library/Application Support/io.github.steiale.lockplus.mac.preview/`. That directory is reset at every
  preview launch.
- Go migration: an in-memory fixture. The Go app's real data is never read.
- Nothing is installed, activated, saved to NE preferences or written to a host keychain. Login items, the resume
  agent, LAContext, notifications and "move to Trash" are inert.
- Demos: "Update Available…" appears ~3 s after launch (PreviewUpdater, no network); Diagnostics shows a fixture
  resolver (utun4, 10.8.0.1), fixture routes and an installed-but-idle old Go helper; Logs show fixture app and
  tunnel lines; "Add Current Network" adds "Cafe-Guest" after a simulated Location grant.

Under XCTest the host app always uses the preview backends and starts nothing.

Running the Unit plan: put `-derivedDataPath` on the internal disk (e.g. `$LP_BUILD_ROOT/<name>-dd`; `LP_BUILD_ROOT` defaults to `~/Code/lockplus-build`, see `Tools/lib/paths.sh`). With
derived data on an external volume the ad-hoc test host waits forever on a removable-volume TCC approval ("The test
runner hung before establishing connection"). Two hosted runs of the same bundle ID at once also collide.

## Structure (App/, outside App/UI)

| File | Role |
|---|---|
| `AppEnvironment.swift` | Composition root: backends (live or preview), stores, the one `UIEnvironment` |
| `AppActions.swift` | `LPUIActions` implementation, plus `Uninstaller` (§4.4) |
| `UIBinder.swift` | Store → UI mapping (`UIMapping`, pure) and Observation re-arm; settings two-way |
| `Stores/ProfilesStore.swift`, `ProfileRepository.swift` | §3.3/§3.4 files, HMAC, sealing, replay, provisioning, reconcile |
| `Stores/ManagerStore.swift` | `VPNManaging` + `NEManagerStore` (the only NE owner) |
| `Stores/ConnectionStore.swift` | Status (S5 filter), S12 lastError rule, snapshot, connect/switch/pause |
| `Stores/AuthCoordinator.swift` | §8.4 auth: prompts answered into the pending start (draft 9), `prepareStartAuth` |
| `Stores/ImportCoordinator.swift`, `GoAppMigrator.swift` | §8.1 import, §13 migration |
| `Stores/Keychain.swift` | §6.2 data-protection keychain, plus an in-memory fake |
| `Model/` | `Profile`, `AppSettings`, `ManagerConfiguration` (flags, providerConfiguration, on-demand, start options) |
| `PreviewMode/PreviewBackends.swift` | Simulated backends and fixtures |
| `main.swift`, `Headless/` | Entry: `--resume-protection` runs headless (`HeadlessResume`, GUI `instance.lock`), else the app |
| `Services/UpdateController.swift`, `UpdateCoordinator.swift` | §12 Sparkle 2.10.1 (exact), variant B (`expectedUpdate`), gentle reminders |
| `Services/ResumeAgent.swift` | §10.4 `SMAppService.agent`, launch re-registration rule |
| `Services/Notifier.swift` | §11.7 notification policy and the `UNUserNotificationCenter` bridge |
| `Services/DNSVerifier.swift`, `Stores/DiagnosticsStore.swift` | §10.2 L-DNS-3, Diagnostics rows |
| `Services/Redactor.swift`, `DiagnosticsBundle.swift`, `DiagnosticsExporter.swift`, `LogReaders.swift`, `Stores/LogsStore.swift` | §14.2 bundle and the Logs section |
| `Services/LegacyKeychain.swift` | §6.7 login-keychain reader (opt-in migration of Go passwords) |
| `Services/LegacyAppDetector.swift` | §4.5 Go helper coexistence |
| `Services/WiFiLocator.swift` | "Add Current Network" (CoreWLAN, just-in-time Location) |
| `Services/AppEditorBackend.swift` | §11.4 editor load/save |
| `Services/AppCommands.swift` | "Check for Updates…", Help › "Export Diagnostics…" |
| `../Config/LaunchAgents/` | The resume agent plist (copied to `Contents/Library/LaunchAgents`) |

## Decisions and open items (app root, P4)

- **Sparkle (final, draft 9.1):** `SUFeedURL = https://steiale.github.io/lockplus-updates/appcast.xml` (the public
  repo `steiale/lockplus-updates` on GitHub Pages; archives go to that repo's GitHub Releases) and the real
  `SUPublicEDKey` (generated 2026-10-27 with `generate_keys --account lockplus-native`; the private key is in the owner's
  login keychain plus an offline backup, and agents never read or touch it). The placeholder gate stays:
  `UpdateController` never starts the updater on a placeholder value, and `verify.sh static` refuses one. `SUAllowsAutomaticUpdates
  = NO` (§2.5 default, owner may revisit). Variant B (§12.3). Deviation from DESIGN §2.3: the XPCServices strip is not a Run
  Script phase (it ran before SPM embedding, and its outputPaths collided with the embed step: "Multiple commands
  produce Sparkle.framework"). `Tools/build/build-unsigned.sh` strips `Versions/B/XPCServices` from the archived app
  and fails if it is still there; exercised by an archive on 2026-10-26.
- **Resume agent:** `StartCalendarInterval {}` per DESIGN (TBD-by-S5; fallback `StartInterval 60`).
- **Extension logs (review M1):** no new XPC method and no extension change. `logs-tunnel.txt` and the Logs view read
  the extension's unified-log output with `/usr/bin/log show` as the user (macOS masks `.private` values; non-admin
  accounts get a documented gap). The extension's `LogRing` (OpenVPN event names, debug engine lines) is still not
  delivered anywhere; an owner-tagged ring plus an owner-scoped XPC method stays the §14.1 TODO.
- **Routes:** `netstat -rn` (read-only) instead of `NET_RT_DUMP2` for now.
- **Zip (draft 9.1):** ZIPFoundation 0.9.20 (owner-approved; app target only, exact pin; review
  `reviews/2026-10-27-zipfoundation.md`). `App/Services/ProfileZip.swift` is the only importer: `ZipStructure.validate`
  (our strict structural pass and the §3.5 caps) runs before ZIPFoundation sees any bytes; import reads and inflates in
  memory only; Export All and the diagnostics bundle are built in memory (no `ditto`, no scratch directory) and written
  with `AtomicFile.writeUserFile`.
- **§6.7:** the Swift reader confines the deprecated `SecKeychainCopyDefault`/`SecKeychainOpen` to a deprecated-context
  witness instead of an Objective-C file. Untested against real legacy items (fixtures only, by rule).
- **§4.5:** the read-only `Tunnel.Status` probe is untested against a live Go helper (fixtures only, by rule).

## Review fixes (2026-10-26: Sonnet app-root review, Fable app-side security review)

- **NE managers (AR-H3):** every store talks to `SerializedVPNManager`: one FIFO lock for reload/save/remove/
  on-demand, one retry after `configurationStale`, statuses replayed after each reload, no save before a first
  successful load, observable snapshot. `NEManagerStore.loadAll` removes this user's duplicate and unaddressable
  configurations; `ProfilesStore.load` sweeps managers whose profile is gone.
- **Kill switch (AR-H1):** the manager is saved before the metadata and rolled back if the metadata write fails;
  `syncManager` re-saves a manager that lags its profile at load and before every start.
- **On-demand (AR-H2, §10.4):** a user Disconnect suspends on-demand until the next network change
  (`NetworkWatcher`, NWPathMonitor; recorded in settings.json, so it also ends at the next launch on another
  network); disconnecting a manual profile re-enables the auto profile.
- **Quit (AR-H4):** "Resume Protection and Quit" and "Disconnect and Quit" finish (bounded) before terminating;
  `pausedState` is cleared only after the restore.
- **Uninstall and the master key (AR-H5, FA-H1, §6.8):** nothing local is deleted unless deactivation succeeded;
  the master key and saved passwords go only together with the profiles; residuals are named in a final sheet.
  A missing key with existing profile files is the `.locked` state (`ProfilesStore.locked`, never a new key); a
  wrong-size key is an error, never replaced.
- **Payload files (AR-M4):** `<uuid>.<revision>.sealed`, old revisions pruned after the metadata commit.
- **Credential facts (FA-L3):** `credential-facts.json` (non-secret) feeds the UI; secrets are read only for
  show/change/provision.
- **User files (FA-M2):** exports/logs/diagnostics use `AtomicFile.writeUserFile` (no folder chmod, 0600,
  O_EXCL|O_NOFOLLOW temp) and report failures.
- **Sparkle (FA-M3/M4):** `verify.sh static` refuses the placeholders (kept as a safeguard; CI no longer sets
  `LP_ALLOW_SPARKLE_PLACEHOLDERS`, draft 9.1); the feed comes from Info.plist via the delegate and user-defaults overrides are cleared.
- **Second instance (FA-L5):** quits with "LockPlus is already running".
- Declined nits, with reasons: master key as `kSecClassKey` (no gain without the Secure Enclave, needs a second
  keychain path and a migration); "send Data, not String" to the OpenVPN validator (the
  `OpenVPN3ProfileValidating` protocol in the frozen LPParsing package takes a String); `AES.GCM.open(inPlace:)`
  (the opened Data is zeroed instead).

## E2E-1 and P3 changes (DESIGN draft 10)

- **Drift, not tampering (PF 55, DESIGN §3.4):** `ProfilesStore.isReplay` is a lower revision only; `flagsDrifted`
  (equal revisions, different flags) is healed in `load()` by `syncManager`, once per profile revision per run
  (`healedDrift`), with a `.fault` log and, on a repeat, a problem note. `prepareForStart` (before every start):
  `syncManager`, then for a kill-switch profile settle (`settleAfterSave`, 0.5 s), `loadAll`, one repair, else
  `.killSwitchNotApplied`. `NEManagerStore.save` reads the configuration back and logs "saved protocol flags not kept"
  at `.fault`. `protectionMismatch(id)` feeds `UIMapping` (`killSwitch = false`, `ProfileItem.protectionRepairing`).
- **Held-start push (PF 50, DESIGN §9.3):** `ConnectionStore.pushFreshEndpointsIntoHeldStart` runs on a `NetworkWatcher`
  signature change and in `didWake` (`AppDelegate`'s wake notification), after `endpointPushSettle` (2 s); it asks
  `tunnelSnapshot`, checks `PushEndpointsRequest.appliesTo`, resolves `summary.resolvableEndpoints` and shapes the map
  with `pushableEndpoints` before `pushEndpoints`.
- **Proxy (PF 51):** the start resolves `summary.resolvableEndpoints`; `ImportCoordinator.proxyCheck` adds the
  `.proxyHostUnresolved` warning.
- **Crash restart and copy (PF 52, 53; DESIGN §10.4, §11.2):** `CrashRestartPolicy` (grace 1.5 s, ≤ 3 per 10 min,
  `reconnectWindow` 120 s) in `ConnectionStore`; `restartedAfterCrash` → `ConnectionUIModel.reconnectedAfterRestart`
  (hero strip) and `Notifier`'s `.reconnectedAfterRestart` (not a problem notice).
- **Uninstall (E2E-1 bug 3, DESIGN §4.4):** `LiveSystemHooks.finishUninstall` ends every attached sheet
  (`endAttachedSheets`) before `NSApp.terminate`, and shows `trashFailedMessage` when `NSWorkspace.recycle` fails.

## UI wiring (done)

`UIBinder` fills `ConnectionUIModel.resumeAgentNeedsApproval` (`resumeAgentStatus == .requiresApproval`) and
`ConnectionUIModel.legacyHelper` (`LegacyHelperNotice` from `LegacyHelperStore.finding`); `LogsStore` sets
`LogsUIModel.tunnelLogsGap`. Every UI Connect goes through `UIEnvironment.gatedConnect` (§4.5 refuse/warn);
`AppActions.connect` itself no longer shows an alert. `prepareDiagnosticsPreview()` maps the redacted bundle files.
Inflected counts (`^[…](inflect: true)`) must go through `String(AttributedString(localized:).characters)`;
`String(localized:)` shows the raw markup.

## UI hooks the app root provides (for App/UI)

- `ConnectionStore.resumeAgentStatus == .requiresApproval` → the pause sheet's "protection resumes the next time it
  opens" note.
- `AppActions.importMigration(_:includingSavedPasswords:)` → the onboarding "Import saved OpenVPN passwords" opt-in
  (announce the per-item system prompts first); `MigrationOffer.savedPasswords` is filled.
- `AppEnvironment.prepareDiagnostics()` (redacted files) and `exportDiagnostics()` → Settings › Advanced "Export
  diagnostics…" with the "What's inside" preview; `LogsStore.tunnelGap` → a Logs footer when tunnel logs are
  unavailable.
- `LegacyHelperStore.finding` (`message`, `blocksConnect`, `warnsBeforeConnect`) and
  `AppActions.openOldLockPlus()` → the §4.5 refuse dialog, the persistent banner and the pre-connect warning
  (interim: an alert via `ImportUIModel.errorMessage`).
- `AppActions.requestLocationAccess()` after the Location pre-prompt sheet; `addCurrentNetwork()` otherwise.
- §6.8 locked state: `ProfilesStore.locked` (names from unverified metadata) → "Profiles from another Mac are locked"
  with Re-import / "Remove locked profiles" (`AppActions.removeLockedProfiles()`, after the UI's confirmation).
- `AuthCoordinator.lastError` after a failed answer (the prompt is re-shown via `reshowCount`) → an error line in the
  auth sheet (interim: an alert).
- `ConnectionStore.configurationDenied` is mirrored to `ConnectionUIModel.vpnConfigurationDenied`.
