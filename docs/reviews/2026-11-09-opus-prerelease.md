Nothing is HIGH. There are 7 MEDIUMs and 1 release blocker that is not in a commit yet (the app icon). Read-only throughout: nothing built or run, no files written. Two Sonnet workers reviewed migration/test-infra and the string catalog, and I checked their key findings against the code. All paths are under native.

## BLOCKER (outside the commits)
**B1. The 200013 commit has no app icon, and the DMG volume-icon change is not committed.**
- `Config/App.xcconfig:9` has set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` since the project was created. `App/Assets.xcassets/AppIcon.appiconset/` is untracked.
- So a release built from a fresh clone of HEAD (the toolchain.md flow) ships the generic icon.
- Also not committed: `Tools/release/release.sh` (modified), `Tools/release/make-volume-icon.swift` (new) and `Tools/release/VolumeIcon.icns` (new). The release.sh change would fail at `cp VolumeIcon.icns` if it were committed without the .icns.
- The set itself is fine: the JSON is valid and has all 10 mac slots, and every PNG has the right pixel size. All of them are opaque RGB with no alpha (full-bleed square). That relies on macOS 26 masking it to the squircle, so check it in Finder and the Dock.
- Fix: commit all four together.
  - Make `make-volume-icon.swift` a documented release step, or regenerate the .icns inside release.sh so it can't drift from AppIcon.
  - Replace its `!` force unwraps with errors.

## MEDIUM
**M1. A double Import runs the migration twice and duplicates profiles.**
- Where: `App/UI/Onboarding/MigrationViews.swift:48-52`, `App/AppActions.swift:480-489`, `App/Stores/GoAppMigrator.swift:94`.
- The Import button is only disabled on an empty selection. `GoAppMigrator.run` has no in-flight guard: it copies `plan` with `guard var plan`, and `create` never dedupes.
- Scenario: a run is waiting on keychain prompts and the user clicks Import again. Both runs create "Work" and "Work 2", and they overwrite each other's marker.
- The same race happens from Settings › "Import from Old LockPlus…" during onboarding step 4. `findOldLockPlusData` (`AppActions.swift:496`) only guards `migrationChecking`, and its `detect(force:)` replaces `plan` mid-run.
- Fix:
  - Add a `migrationRunning` flag: disable Import while it is set, and make `findOldLockPlusData` bail out.
  - Add `guard !running` with a `defer` in `run`.

**M2. A run where every create failed still writes `marker.complete = true`.**
- Where: `GoAppMigrator.swift:176-179`.
- Scenario: profiles are locked (§6.8), and the Settings button is not gated on `profiles.locked`. Every create throws, yet settings, Wi-Fi rules and history are applied and the marker is marked complete.
- Any later re-import has `applyGlobal == false`, so auto-connect, trusted networks and history never reach the profiles.
- Fix: gate `findOldLockPlusData` on `profiles.locked == nil`, and leave `complete = false` if any item is "error:…".

**M3. `offerToFinishMigration` runs a full `detect()` on every launch and keeps private keys in memory.**
- Where: `AppEnvironment.swift:555-557`, `GoAppMigrator.swift:62-81`.
- Scenario: onboarding is done, the user skipped the import, and Go data is present.
  - Every launch reads all Go tunnels and runs `keychain.list()`.
  - It then throws the offer away.
  - `migrator.plan` keeps the WG/OVPN private-key payloads for the life of the process.
- The same retention happens after Cancel in the Settings sheet.
- Fix:
  - Load the marker first, and only detect when it is incomplete.
  - Set `plan = nil` in `closeMigration` and on every discarded offer.

**M4. `removeHelper()` can be entered twice.**
- Where: `App/Services/LegacyAppDetector.swift:268-274`.
- The `guard removal != .removing` check runs, but `removal = .removing` is only set after `await refresh()`.
- Scenario: a double-click on "Remove Old Helper…" gives two administrator prompts and two concurrent script runs.
- Fix: set `.removing`, or a separate `inFlight` flag, before the first await, and reset it on the early exits.

**M5. A new string is missing from the catalog, so German users see English.**
- Where: `App/Stores/ConnectionStore.swift:546`, `String(localized: "\(name) couldn't connect: \(…).")`.
- Fix: add the key with DE "%1$@ konnte keine Verbindung herstellen: %2$@."

**M6. Text fields probably get a double focus ring.**
- Where: `App/UI/Design/FormLayout.swift:31-45` (`LPField`).
- `.textFieldStyle(.plain)` on macOS 14+ still draws the system focus ring tight around the text. `LPField` adds its own 2 pt accent ring outside the padding, so you would see two rings: blue inside, accent outside.
- Fields affected: sign-in/auth sheets, password sheet, editor Name, import Name, and the Diagnostics filter.
- Fix: add `.focusEffectDisabled()` after `.textFieldStyle(.plain)`.
- Also check that the caller's `.focused($focus, equals:)` still moves focus programmatically now that a second `.focused($focused)` is stacked on the same field. Programmatic focus could be lost, especially in `responseRow`, where the field is a TextField or a SecureField inside a `Group`.

**M7. The release.sh DMG detach is flaky, and `SetFile` is called without xcrun.**
- Where: `Tools/release/release.sh:98-103`.
- `hdiutil detach "$MNT"` on a freshly written volume often fails with "Resource busy": `-nobrowse` does not stop Spotlight/fseventsd. With `set -e`, that aborts the release after notarization of the app.
- Fix:
  - Retry the detach 3–5 times with `sleep 2`, then fall back to `-force`.
  - Use `xcrun SetFile` so it resolves through the pinned Xcode.
  - Add an `hdiutil attach` check so a missing `.VolumeIcon.icns` fails loudly.

## Test infra / product hook
- **`ImportCoordinator.running`/`idle()` is safe in production.**
  - It is main-actor, creates no continuation, and the Task→self cycle ends when the task finishes.
  - Limits: only `importFiles` and `confirm(batch)` are tracked. A second `importFiles` overwrites `running` without awaiting or cancelling the first.
  - Optional: wrap it in `#if DEBUG`, or document the limits.
- **`FakeVPNManager.start()` and `emit()` never call `onChange`** (`Tests/LockPlusTests/AppRootFakes.swift:122`).
  - The `until(h.managers) { starts.count == 1 }` wait in `OnDemandPauseReviewTests.swift:106` passes only by scheduling order and can hang.
  - Fix: add `defer { onChange?() }` to both.
- **No suite that uses `until` has a `.timeLimit`**, so one hang stalls the whole run. Add `.timeLimit(.minutes(1))`.
- **`FakeTimers.fire`** (`AppRootFakes.swift:290`) drops the result of its 3 s wall-clock `eventually`. Wrap it in `#expect`.
- **`until` has a single `onChange` slot**, so a second concurrent `until` would overwrite the first. Also `loadGate` is one-shot. Both are fine today.
- **`E2E5FixTests.swift:127`** uses a 100 ms sleep as a negative check, which is a small flake risk.

## LOW
- **Migration resume:**
  - `fillOnly` drops language, log level and icon style after a kill during the profile loop (`GoAppMigrator.swift:155,347-361`).
  - Already-imported profiles are deduped by digest only, so an edited profile is duplicated on re-run (`:111-123`).
  - History is appended before the marker is saved, with fresh UUIDs, so a kill duplicates history on resume (`:160`).
  - On resume the credentials step is skipped for newly selected profiles (`:146`).
  - Errored tunnels get a second marker item on resume (`:126,142`).
- **Gate and legacy-helper UI:**
  - A `.warn` gate is never auto-cleared (`UIBinder.swift:271` only clears `.refused`). After the profile is deleted, Connect Anyway passes a dead id.
  - `ConnectGateStrip` announces only `onAppear`, so `.refused(A)` replaced by `.refused(B)` is not re-announced.
  - The `.cancelAction` shortcut on the strip takes Escape for the whole main window.
  - `removeHelper` with no helper present shows "was removed" (`LegacyAppDetector.swift:271`).
  - `log.notice` fires on every 5 s poll while refusing (`:307`).
- **Launch at login:** the Go LaunchAgent is deleted at launch, but `launchAtLoginOffer` lives only in memory. Quit before answering, and both the old autostart and the offer are gone (`AppEnvironment.swift:362-366`).
- **Settings migration sheet:** "Import from Old LockPlus…" clears `onboarding.migration` and `migrationReport`. It can wipe an open onboarding offer, and the two sheets share one model (`SettingsView.swift:207`).
- **Sidebar selection colour:**
  - It relies on `.tint(Color.lp.selection)` plus `SidebarInk` (onPastel text whenever `backgroundProminence == .increased`).
  - It was checked only on macOS 27 with default settings. With a non-Multicolor system accent, the selection may come out in the user's accent, and dark onPastel text on it would fail contrast. Verify on real hardware.
  - The renderer fakes the selection (`RenderFixups.swift`), so screenshots can't catch it.
- **Contrast tests:**
  - `DesignTokenTests` does not cover `lp.panel`, which Activity and Diagnostics now sit on.
    - Text pairs to add: label and label2.
    - Mark pairs to add: softSage, softAmber and softRose.
  - Also missing: the selected badge (onPastel on canvas at 55 % over the selection) and `lp.fieldBorder`. The field border is probably under 3:1, so the WCAG 1.4.11 field boundary is met only under Increase Contrast.
- **Activity table:**
  - Toggling `compactTable` rebuilds the columns and loses any user resize.
  - In compact mode, You and macOS end reasons aren't shown (intended).
  - There is no layout loop: the full layout's column minimums sum to 620 pt, under the 700 threshold.
- **Strips and ActionRow:**
  - `InlineStrip`/`ActionRow` rebuild their buttons when ViewThatFits switches branch on resize, so keyboard focus on a strip button is lost.
  - A conditional `actions {}` that ends up empty still renders an empty ActionRow (8 pt gap), because the `Actions.self != EmptyView.self` check doesn't catch `Optional`.
- **Menus:**
  - `setMonospaced` finds the bold item by title (`MenuBarController.swift:402-404`). Match by identity or tag instead.
  - Section headers and subtitles stay in the system font (documented).
  - Key equivalents and accessibility titles are unaffected.
- **Menu bar icon revert (90e5953):**
  - It is clean. LockGlyph.swift is byte-identical to before 15c49ba, and no `statusScale`, `tileHeight`, `statusTemplateWithLabel` or `inkBounds` remain.
  - The 4.5 pt gap applies only to the colour tile. The Settings preview (`SettingsView.swift:141`) uses `HStack(spacing: 4)` rather than the real gap.
  - `fixedLength` always measures the monochrome glyph width.
- **Sidebar name:** the full-name tooltip shows even when the name isn't truncated. The subtitle comment "never truncates" is wrong with `.lineLimit(2)`.
- **Glyphs:** no leftover glyph variants or p2 references.
- **Typography:** fully centralised; no stray `.monospaced` or system fonts.
- **Launch selection resolver:** only fixture renames, no logic change.
- **Dependencies:**
  - The pins are consistent: pins.sh, vendor.sh, the OpenVPN3Shim Package.swift comment, DESIGN §1009/§2812, patch 0012 (go 1.26.0 ≤ the 1.27.3 toolchain) and the gomodcache flow.
  - `docs/native/DEPENDENCY-AUDIT-2026-11.md` is partly stale. The §4 heading still says "lz4 1.10.0". §5 says "+ 11 patches" (now 12). "Suggested order" item 2 still lists the lz4 and x/* bumps as to-do.
  - `native/spike/s14-build/pins.sh` still says 1.10.0 (it's a spike).
- **Localization:**
  - 11 DE strings put a space before the ellipsis while 59 don't, e.g. "Aus altem LockPlus importieren …" and "Altes Hilfsprogramm entfernen …" (the quoted copy doesn't match the menu item). Remove the space.
  - "in ^[%lld Profil](inflect)" gives the wrong case ("in 2 Profile").
  - "Warte…" and "Prüfe %@…" read as commands; use "Warten…" and "%@ wird geprüft…".
  - "bewegt" should be "verschoben".
  - "Behalte sie bei: Sie…" has an unclear "sie".
  - `SaveError(message: "LockPlus is quitting.")` in `Services/AppEditorBackend.swift:22,41` is not localized.
  - 82 EN entries are still in state "new".
  - Otherwise clean:
    - Every key has a translated DE value.
    - EN and DE format specifiers match.
    - The catalog has no unused keys.
    - The du-form is consistent, with no Sie/Ihr/Ihnen left.
    - DE quotes are „…“ throughout.
- **General:**
  - Unused `Logger`s in `GoAppMigrator.swift:38` and `ImportCoordinator.swift:83`.
  - No new force unwraps in App code, no TODOs, and no non-private logging of profile names or keys in scope. The security reviewer covers the `.public` logging of LegacyHelper state.