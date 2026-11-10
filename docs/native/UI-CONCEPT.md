# LockPlus Native: UI concept

Status: draft 8.3, 2026-11-09 (follows DESIGN draft 10.2). The owner decisions of draft 1 (end of document) stand; draft 2 applies the verified reference `reference/swiftui-appkit.md` (its 20 corrections) and the final Fable spec review (F-1 `allowLAN` off, F-4 derived state, F-7–F-9 secret, clipboard and prompt hygiene, F-12 profile switch, F-14 tests, F-15 drift). Companion to `docs/native/DESIGN.md` draft 9 (§11 UI architecture) and `docs/NATIVE-REWRITE.md`. Where this document and DESIGN disagree, DESIGN's revision log decides.

UI review loop: `native/Tools/ui/review/review.sh` renders every screen, builds the review package (screen IDs `S-<section>.<nn>`, contact sheet, comment boxes) and serves it locally; comments are kept in `docs/native/ux-review/` (see `native/Tools/ui/review/README.md`).

Draft 8.3 changes (owner UI review of 2026-11-09, second round; the E2E-5 upgrade fixes, DESIGN draft 10.2), one line each:
- §7.2: **the shipping lock is V2 "Sturdy" with a + in the body** (owner pick p2, S-12.02): heavier strokes, corner radius 17, a short shackle almost as wide as the body, and a larger + (the app is LockPlus) cut into the body. V1, V3, V4 and the other + placements (p1, p3) are retired.
- §6.1, §6.13: **the lock is centred in the status item**: the status canvas is symmetric around the lock body and the badge takes its room on the right inside it. Same in Settings › Menu Bar's preview. The embedded glyphs (hero, menu header, messages) are unchanged.
- §6.2: **the menu header never truncates**: no line limits, it grows to its text; it is 340 pt wide (was 300); rows whose hero title is a long sentence have a short header wording (table in §6.2).
- §2.2a: the **dark selection is a softer, lighter sage** `#4a6e62` (onPastel 5.05:1); light mode unchanged.
- §2.5: in dark mode **grouped rows under a tile sit on navy `lp.panel`** (Activity and Diagnostics tables) instead of the system's grey.
- §2.5: **one text field look** outside system Forms (`lpField()`): a fill close to the window background and a soft border instead of the bezel's grey block.
- §4.5, §6.15: **the old helper's banner offers "Remove Old Helper…"** (DESIGN §13.3a: one administrator password; refused while the old LockPlus protects the Mac) with removing / removed / cancelled / failed states and Try Again (S-9.16 to S-9.20). No "run its uninstaller" (there is none in 1.x). E2E-5 F1.
- §6.15: **the §4.5 refusal and the crashed-helper warning are a strip above the detail, not an alert** (the alert sheet blocked Quit); every Connect re-checks the old helper, and the refusal clears when the old tunnel goes down. "Open the old LockPlus" ends it and appears only while the old app is installed (S-10.06, same ID). E2E-5 F3, F8.
- §6.13, §6.14: **Settings › Advanced › "Import from Old LockPlus…"** opens a sheet any time (S-6.08); onboarding step 4 says the import can happen later. An interrupted migration is offered as **"Finish importing from LockPlus 1.x"** (S-7.18) and, after onboarding, by a banner "Importing from LockPlus 1.x didn't finish." [Finish Import…] (S-9.21). E2E-5 F4.
- §6.14: **the whole migration report** (S-7.15): Needs attention with the reason, "Good to know" (harmless ignored lines such as `nobind`/`verb`, appearance, DNS, the per-network map), an "Open LockPlus at login" checkbox; copy fixed: "LockPlus copies them. The old LockPlus's files stay as they are.", the **login keychain password** prompt, "saved logins", and a last line that depends on the helper. E2E-5 F5–F7.
- §6.15: after 1.0.x's LaunchAgent is removed, a banner offers "Open LockPlus at login instead?" (S-9.22); a second copy started at login quits **silently**. E2E-5 F5.

Draft 8.2 changes (owner UI review of 2026-11-09), one line each:
- §2.4: **SF Mono throughout.** The whole UI (window, sidebar, hero, menu header, settings, onboarding, sheets, editor, status item label, NSMenu standard items) uses the system monospaced design through one definition (`LPTypography`, `lpTypography()` at each root). Weights and sizes keep the system hierarchy. System alerts (NSAlert) and `NSMenuItem.subtitle` stay system type (no API).
- §2.2a: **pastel palette outside the status tiles.** Sidebar selection, badges, banners, chips, chart marks outside the hero, icons and the Connect button use pastel variants of the same hues. Hero, menu header and tray tiles keep their colours.
- §6.3: sidebar rows are one line with middle truncation and the full name as tooltip; the sidebar is 250-340 pt wide (ideal 280) for SF Mono.
- §6.1, §6.13: the **menu bar icon defaults to the colour tile**; Monochrome stays selectable. Existing settings files (schema 1) move to the new default once; a choice made afterwards is kept.
- §6.5 and forms: **one form layout** (`LPFormGrid`): labels left-aligned in one column, all fields on one leading edge (Username, Password, One-time code, Response, Passphrase; also change/reveal password, import, editor Name).
- Review tooling: the screenshot harness compensates for the offscreen vibrancy artefact (UI-M18) in the renderer only; the real app was verified on macOS 27 and is unchanged.

Draft 8.1 changes (with DESIGN §10.4, the fifth on-demand pause review, `reviews/2026-10-30-fable-ondemand-pause-5.md` §3), one line each:
- §6.6: new row **12a** for the app's own start work before any `NEVPNStatus` exists: "Preparing to connect Work…" / "Waiting for Home NAS to disconnect…" / "Waiting for Work's tunnel process to restart…", never "Connecting…" (de: "Verbindung mit Work wird vorbereitet…" / "Warte, bis Home NAS getrennt ist…" / "Warte auf den Neustart des Tunnelprozesses von Work…"); Cancel ends a start that hasn't been issued (none while a crash restart is awaited).
- §6.2, §6.3, §6.4, §8.1: while a start, a switch or a crash restart is under way, every Connect (hero, toolbar, sidebar context menu, the menu bar's Connect and profile items, ⌘K) is disabled and its help or tooltip says why ("LockPlus is preparing to connect Work."); the menu header's switch is disabled in row 12a and the menu shows the row's line disabled plus Cancel. The Dock menu (§8.2) isn't built yet; when it is, its Connect follows the same rule.
- §6.11: when the end of a pause or an update can't reconnect its profile because another start is in flight, Diagnostics says so: "Work wasn't reconnected: Home NAS was starting at the time. Connect Work again if you need it."
- §6.14: onboarding step 3 says when a deferred first save happens ("LockPlus adds the VPN configuration for Work when Home NAS disconnects.") instead of claiming it's done.

Draft 8 changes (with DESIGN draft 10: E2E-1 on the notarized 2.0.0 and PENDING-FOLD 50–55), one line each:
- §6.4, §6.15: while macOS has dropped a profile's protection settings and LockPlus restores them (DESIGN §3.4), the profile shows "Restoring this profile's protection settings in macOS. The kill switch isn't active until they're verified, and LockPlus won't connect before that." and nothing claims the kill switch; if they can't be restored, Connect fails with "Couldn't apply the kill switch. LockPlus won't connect unprotected."
- §6.4, §6.15: after the tunnel process crashed and the session came back by itself, the hero shows "Reconnected after a tunnel process restart." and the connect notification reads "Reconnected to <name> after a tunnel process restart." (de: "Nach einem Neustart des Tunnelprozesses wieder verbunden." / "Nach einem Neustart des Tunnelprozesses wieder mit <name> verbunden.").
- §6.4: the kill-switch help adds that LockPlus, while running, restarts an auto-connect profile after such a crash (DESIGN §10.4).
- §6.8: a proxy given by name that can't be looked up at import gets a warning row.
- §6.13, §6.15: Uninstall quits even with the Settings sheet open; when LockPlus can't move itself to the Trash, it says so. The stale "copy fix pending" note is removed (fixed in DESIGN draft 8).
- §6.7: the 15 s re-check after a captive-portal sign-in and "Auto-connect couldn't verify this network" are not built yet (DESIGN §18); protection starts on the next network change.

Draft 7.1 changes (with DESIGN draft 9.1: owner decisions and zip import), one line each:
- §8.3, §11: the German register is **du** (owner, final); the open item is closed.
- §6.15: **zip import is built** (ZIPFoundation approved): a `.zip` opens the batch sheet; archive-level problems (not a zip or damaged, ZIP64, encrypted, an unsupported compression method, more than 500 profiles, more than 100 MB packed or unpacked, a name twice, no .ovpn/.conf inside) are one alert naming the archive; entry-level problems (an unsafe path, a link, not a regular file, over 10 MB, compressed suspiciously well, damaged) are error rows above the list. Folders inside the zip are fine; macOS metadata (`__MACOSX`, `._*`) and other files are ignored. If every profile entry was skipped, the alert lists why.
- §6.15: **Export All** writes one zip ("LockPlus Profiles.zip", save panel), as specified; it no longer writes loose files into a folder. The banner is unchanged.

Draft 7 changes (with DESIGN draft 9: the S2 VM results; macOS has no start time limit, a failed start and a provider cancel are open, a pending start blocks), one line each:
- §6.5: every sign-in the server asks for during a connect (a dynamic challenge, a rejected password, a missing password, a push approval) is answered **into the pending connect**: the sheet's answer connects that same attempt, with no "connect again" step and no second start. The approval wait lasts up to 10 minutes (was 50 s). Known-interactive profiles may still prompt before Connect, while the Mac is online.
- §6.5: Cancel on a sign-in during a connect also disconnects it (with the kill switch the connect would otherwise stay blocked).
- §6.6: row 3 is the sign-in inside the pending connect ("Sign in to connect Work."), and says "No traffic leaves this Mac until you sign in or disconnect" with the kill switch (S2 E14a measured it blocked).
- §6.6: rows 3a/3b are no longer an alternative: a kill-switch connect that fails is **held, blocked** (S2 E14), and row 3a shows real retry text while a retryable failure retries.
- §6.6: rows 13 and 13b are removed, and with them **Restore Internet** and **Cancel and Restore Internet**: macOS never blocks while it reports "disconnected" (S2: a failed start and a provider cancel are open), and LockPlus no longer ends a kill-switch session by itself.
- §6.4: the kill-switch footer says that a crash of LockPlus's tunnel process lets traffic through for under 2 seconds until macOS restarts it (S2 E1 measured 2.45–2.86 s in the spike; E2E-1 on product builds 1.3–1.7 s).

Draft 6 changes (with DESIGN draft 8: the UI as built in P2/P4 and the Sonnet UI review fixes), one line each:
- §8.3, §6.13, §11: v2.0 ships **English and German**; Korean and Japanese are dropped (the language picker offers System, English, Deutsch). The German register (du or Sie) is an open owner question; the catalog uses du today. *(Draft 7.1: du, final.)*
- §2.2, §6.9, §8.2: dark-mode `lp.stroke` is mint **50 %** (45 % failed 3:1 on `lp.card`; High Contrast 65 %); dark editor comments are mint **65 %** (55 % failed on `lp.sunken`; High Contrast 75 %).
- §6.8, §6.15: the "Profiles from another Mac are locked" state as built: **Re-import…** is an explicit "Start over" that moves the locked files aside, and **Remove Locked Profiles…**; zip import waits for an approved zip library (*draft 7.1: built*).
- §6.4: the OpenVPN cipher row shows only when the cipher is known (openvpn3 doesn't report it directly), otherwise it's hidden.
- §6.5: a failed answer re-shows the sheet with an inline error; server text is cleaned (control and bidi characters stripped, newlines collapsed, about 256 characters) before it is shown; the username is prefilled.
- §6.7: "paused until you join another network" survives a relaunch and ends on the next network change.
- §6.9: masking fails closed and also covers VoiceOver, copy, Services, Share, Look Up and Find; Revert asks first; closing or quitting with unsaved edits asks to save.
- §6.12: a footer explains when the tunnel's logs can't be read (non-administrator accounts).
- §6.13: Uninstall's default button is Cancel; "Also delete your profiles and history" decides whether the saved passwords and the key go too; a cancelled administrator dialog keeps everything. "Show in menu bar" off asks first, then really hides the icon. Settings › Advanced has "Export diagnostics…".
- §6.14: the onboarding sheet may grow for German (600–680 pt wide, at least 480 high).
- §6.15: new rows for "already running", locked profiles, zip import and a tunnel component that couldn't be removed.
- §8.1: ⌘⌫ Delete acts only while the sidebar has focus and always asks first; no duplicate shortcuts.

Draft 5.2 changes (with DESIGN draft 7.3, the engine spike results), one line each:
- §6.8, §6.15: a server reachable only through a network other than the Mac's main one (a local VM, Docker, a second port) can't be used by the tunnel (S6). Import shows a warning, and a failed connect names the network.
- §6.13: Uninstall warns up front that macOS asks for an administrator password to remove the tunnel component (S4/S5 on 27).

Draft 5.1 changes (with DESIGN draft 7.1, minimum macOS 26.0), one line each:
- §2.5, §4, §5, §6.1, §6.2, §6.6, §6.8, §6.10, §6.15, §7.1, §7.3, §9, §11, §12: the minimum OS is **macOS 26.0** (was 15.1), and only 26 and 27 are supported and tested. The `.regularMaterial` fallback for floating glass on 15 is gone. The hero always uses Draw Off/On, so the Magic Replace down-up fallback never shows on our symbols. The clipboard privacy checks and Swift Charts plots need no availability notes. Prototypes and the preview matrix run on 26 and 27.

Draft 5 changes (with DESIGN draft 7, the P1 spike results), one line each:
- §6.6: new row 4a "Reconnecting to the tunnel process…" (macOS keeps saying "connected" for ~5 s after the tunnel process crashes; S5); `lastError` is taken from an observed disconnect, never as a stale error at launch (S12).
- §6.14, §6.6 row 1, §6.15: a persistent "Show the Switch Again" action while the extension waits for approval (the first toggle may not stick on 27).
- §6.5: a dynamic-challenge sheet is valid for 5 minutes, and an expired code gets a fresh challenge instead of "wrong password" (S8).
- §6.8, §6.15: profiles with BF-CBC, DES or 3DES are not supported (DESIGN §8.6); new error copy for the tunnel-process crash, a rejected pushed option and a server that needs an outdated cipher.
- §6.2, §8.3, §9: the menu header keeps the default hosting-view sizing and lets the state line wrap to two lines; it updates through Observation alone (S15); Settings opened without a click is brought to the front even when macOS doesn't activate the app.
- §7.1, §7.2, §12: the custom `lockplus.lock` symbols are required, not optional: stock symbols don't morph, don't draw on, and their badges blur at 16 px (S15).

Draft 4 changes (with DESIGN draft 6), one line each:
- §6.6: NE ends a start after ~60 s (DESIGN Conflicts ag), so a failed first connect is the expected before-Connected path: rows 13/13a and the new row 13b ("Sign in to connect", the two-start auth flow) are primary; rows 3a/3b move to a block used only in the withhold alternative (S2 E14b ≥ 15 min); row 3 is the mid-start prompt capped at 50 s; inputs gain `pendingPrompt`.
- §6.5: known-interactive profiles (unsaved password, static challenge, unsaved key passphrase) prompt before Connect; CRV1 and a rejected password prompt after the first start fails, then LockPlus starts again by itself; "Waiting for sign-in approval" is bounded by the start.
- §6.1, §7.2: the "blocked during the first connect" wording follows the failed-start rows.

Draft 3 changes (with DESIGN draft 5), one line each:
- §6.6: rows 3a/3b for holds **before Connected** (status `.connecting` + `holdReason`; never "Connecting…"), row 13 extended to a failed first connect (S2 E14c), row 13a for the start latch; inputs gain `holdBeforeConnected`, `startLatch` and the E14 result; §6.1 and §7.2 wording follows.
- §6.2, §8.2, §9: the header-duplication claim corrected: a standard "Connect/Disconnect <profile>" item and a VoiceOver-only status text item now carry the switch and the facts; the header re-renders through Observation (the `.common` timer is a fallback).
- §6.1: the connecting status item is a 3-frame template sequence (the "Draw On" wording contradicted §6.1/§7.1).

Draft 2 changes, one line each:
- §2.5, §6.2, §6.4, §7.3, §8.2, §9: no `glassEffect` on the hero or the menu header (HIG: no Liquid Glass in the content layer; glass can't sample glass); opaque `lp.card` with a 12 % tint on every OS.
- §4, §7.1, §9: minimum macOS 15.1; Magic Replace (15+) replaces the 3-frame crossfade; the status item uses a 3-frame template sequence (no symbol-effect API on `NSStatusBarButton`).
- §6.1, §6.13: the occlusion check is gone (broken on 27); visibility policy plus a "Show in menu bar" toggle; glyph sized by symbol configuration; fixed label width per locale; one accessibility-label wording.
- §6.2: `preferredImageVisibility = .visible` on profile items (27 hides menu images); the header is not an accessibility element; the Pause rule; the profile-switch copy (F-12); "Update Available…".
- §6.4, §6.8, §6.13: "Allow local network" defaults to **off** (F-1).
- §6.5: auth prompt as a sheet, or a non-activating panel after a user gesture; notification body names the profile only; no text-input notification actions; `localizedReason` without the app name (F-9).
- §6.6: the derived-state table (F-4); "Blocked" after a fatal error shows no retries.
- §6.8: clipboard import respects macOS 15.4+ pasteboard privacy (F-8).
- §6.9: capture hygiene for secret windows and copied secrets; masking decision (F-7).
- §6.10: `AreaPlot`/`LinePlot`, 300 points.
- §6.13: Notifications authorization flow; launch-at-login states; window size.
- §3 principle 2 amended; §8.1 shortcut table is now DESIGN's; §8.2 accessibility wording; §9 "Recommended changes" are applied in DESIGN draft 4; §12 adds tests and prototype gates.

**Recommendation in one paragraph.** Keep the sage, mint and navy palette and the padlock. Rebuild everything else from native parts. The recommended direction is **B, "Native Mac app with a living menu"**: a two-column `NavigationSplitView` main window (profiles in the sidebar, a protection hero and details on the right) and a native `NSMenu` status item with one rich SwiftUI header (state, live rates, a sparkline and an on/off switch). It takes the live menu header from direction A and the single-hero idea from direction C. LockPlus gets its identity from a consistent **glyph language** (shackle open, closing, closed, badged), the "shackle closes" connect moment, and navy brand surfaces. Custom chrome is not where the identity comes from.

---

## 1. Where we start from

### 1.1 Inventory of the Go app (v1.0.68)

| Area | Today (Svelte) | Notes for the rewrite |
|---|---|---|
| Navigation | Icon rail: Tunnels, Tools, Logs, History, Settings (modal) | The rail glyphs are text characters (⊡ ◈ ≡ ⚙), not SF Symbols. Settings is a modal over the app. |
| Tunnels | Expandable cards: a status dot, name, a CONNECTED pill, Disconnect, stat pills (↓ ↑ duration, handshake, latency), speed graph, Address/DNS/Endpoint/Allowed IPs, notes, auto-reconnect toggle, Edit/Export/Delete | Cards exist so that several tunnels can be up at once. That is gone (one active packet tunnel). |
| Editor | CodeMirror modal: name field, Save/Cancel, WG grammar, autocomplete | Light theme GitHub-like, dark theme oneDark (grey `#282c34`, not navy). |
| Stats | Inline speed graph per card (`StatsDashboard`) | rx sage, tx teal |
| History | Grouped by day: name, start time, duration, ↓/↑ pills, end reason | |
| Logs | Level filter, copy, clear, auto-scroll | |
| Tools | DNS leak test, route table, conflict warning modal | Leak test "safe" verdict was once wrong (c9e9ffd) |
| Wi-Fi rules | A tab inside Settings: enable, connect on untrusted, default tunnel, trusted SSIDs, per-SSID map, Location permission states | Per-SSID map is cut in v2.0 (DESIGN §10.4) |
| Settings | General (theme, language, launch at login, export all), Advanced (log level, global kill switch, DNS protection, health check, pin interface), Wi-Fi, About (update, issues, license, Ko-fi) | Most of Advanced becomes per-profile policy or disappears with NE |
| Onboarding | Welcome, scan `/etc/wireguard`, WireGuard App Store tip, import | New steps: system extension and VPN configuration approval, Go migration |
| Menu bar | v1.0.61: padlock on a whole-background color (white idle, green `#34C759` connected, orange `#FF9F0A` warning), rate label, NSMenu with tunnels, Show Window, Quit | |
| Auth | OpenVPN prompt: username, password ("append OTP"), challenge response, save username | |
| Import/export | Drag-drop overlay, file picker, QR image, zip with result list, export, export all | |
| Other | Toasts, update notice, Ko-fi banner, helper-starting banner | Replaced by Sparkle, notifications, inline banners |

### 1.2 Honest audit

What works and should survive:
- The **palette** is distinctive. Navy and mint read as "secure instrument", not as generic SaaS blue.
- The type scale, 8 pt grid, 13 pt body and hairlines already follow the HIG (`frontend/public/style.css` was built from the macos-native-ui token set).
- The rate label with monospaced digits is a real differentiator that Tailscale and the WireGuard app don't have.
- The tray state colors (white, green, orange) are learnable at a glance.

What doesn't, and why a native rewrite is the moment to fix it:
1. **Accent = connected = success.** `--accent`, `--blue` and `--green` are all `#80ae9a`. The Connect button, the selection highlight and the "connected" state share one color, so color alone never tells you the state.
2. **Sage, orange and red have almost the same luminance.** In dark mode sage vs orange is **1.1:1**, sage vs red 1.34:1. In light mode the three sit at relative luminance 0.155–0.167. For deuteranopes and protanopes, "connected", "warning" and "error" are the same color. Shapes are mandatory, not a nice-to-have (see §2.4).
3. **Pill buttons everywhere** (`--radius-btn: 9999px`) and stat pills read as an iOS or web app.
4. **The card list models multi-tunnel concurrency**, which the native app cannot do.
5. **Global policy switches** (kill switch, DNS protection, health check, pin interface) live in Advanced settings, far from the profile they affect. In the NE world they are per-profile or don't exist.
6. **Two visual generations** are in the screenshots (an older system-blue light theme and the navy theme). The native app should have one design.

---

## 2. What to keep: the palette as semantic roles

### 2.1 Source values (from `frontend/public/style.css`)

| Token | Dark | Light |
|---|---|---|
| Canvas (`--bg-primary`) | `#001429` | `#f0f7f5` |
| Grouped (`--bg-secondary`) | `#001d36` | `#e2eeea` |
| Card (`--bg-card`) | `#0d2b47` | `#ffffff` |
| Sunken / input / editor (`--bg-input`) | `#000f20` | `#ffffff` |
| Label (`--text-primary`) | `#b5d1ae` (mint) | `rgba(0,30,40,0.88)` |
| Secondary label | mint 65% | `rgba(0,30,40,0.56)` |
| Muted label | mint 38% | `rgba(0,30,40,0.38)` |
| Accent / sage | `#80ae9a` | `#2d7a68` |
| Yellow | `#e8c547` | `#a07000` |
| Orange | `#e0873a` | `#b85500` |
| Red | `#ef5b5b` (error text `#f08888`) | `#d03025` (error text `#9b1c1c`) |
| Purple | `#a78fd0` | `#6b3fa0` |
| Throughput rx / tx | `#80ae9a` / `#5ab4c9` | `#2d7a68` / `#1a6e8a` |
| Border / strong | mint 18% / 32% | `rgba(0,60,50,0.18)` / `0.32` |
| Tray (v1.0.61) | idle `#FFFFFF`, connected `#34C759`, warning `#FF9F0A` | same |

### 2.2 Semantic mapping for SwiftUI

All of these are Color Set assets in `Assets.xcassets` with Any/Dark appearances **and High Contrast variants**, exposed as `Color.lp.*` / `NSColor.lp.*`. Views never use raw hex.

| Role (asset) | Dark | Light | Used for |
|---|---|---|---|
| `AccentColor` (fill role) | `#2d7a68` | `#2d7a68` | System controls that draw white on accent: `.borderedProminent`, switches, checkboxes, sidebar selection. White on it is 5.13:1 in both modes. |
| `lp.sage` (brand foreground) | `#80ae9a` | `#2d7a68` | Glyphs, chart rx line, tinted text, links, focus accents on brand surfaces |
| `lp.protected` | = `lp.sage` | = `lp.sage` | Connected state, **always with the closed-lock shape** |
| `lp.transition` | `#e8c547` | `#7d5800` (text) / `#a07000` (glyph) | Connecting, reasserting |
| `lp.attention` | `#e0873a` | `#9a4700` (text) / `#b85500` (glyph) | Paused, auth needed, DNS unverified, **Blocked** |
| `lp.critical` | `#f08888` (text) / `#ef5b5b` (glyph, fill) | `#b8291f` (text) / `#d03025` (fill) | Errors, destructive |
| `lp.unprotected` | `secondaryLabelColor` | `secondaryLabelColor` | Disconnected. Deliberately **not red**: off isn't an error, and red-on-idle causes alarm fatigue. |
| `lp.canvas` | `#001429` | `#f0f7f5` | Brand surfaces only (§2.5) |
| `lp.grouped` | `#001d36` | `#e2eeea` | Grouped sections on brand surfaces |
| `lp.card` | `#0d2b47` | `#ffffff` | Hero card, menu header card |
| `lp.sunken` | `#000f20` | `#ffffff` | Editor, logs |
| `lp.label` | `#b5d1ae` | `rgba(0,30,40,0.88)` | Text on brand surfaces |
| `lp.label2` | mint 65% | `rgba(0,30,40,0.62)` (**was 0.56**) | Secondary text on brand surfaces |
| `lp.label3` | mint 55% (**was 38%**) | `rgba(0,30,40,0.40)` | Placeholder, disabled, decoration only |
| `lp.stroke` | mint **50%** (draft 6; draft 2: 45%, was 32%: 45% measured 2.93:1 on `lp.card`) | `rgba(0,60,50,0.55)` (**was 0.32**) | Borders that carry meaning (drop zone, focus-free outlines) |
| `lp.hairline` | mint 18% | `rgba(0,60,50,0.18)` | Decorative separators only |
| `lp.rx` / `lp.tx` | `#80ae9a` / `#5ab4c9` | `#2d7a68` / `#1a6e8a` | Charts, rate glyphs. tx is also **dashed** in charts. |

### 2.2a Pastel palette outside the status tiles (draft 8.2)

Owner decision 2026-11-09: everything except the status tiles (hero card, menu header card, tray colour tiles) uses pastel variants of the same hues. The tiles keep the §2.2 colours. `AccentColor` stays the deep sage: system controls (default buttons, switches) draw white on it, and a pastel accent would fail 4.5:1.

| Role (asset) | Dark | Light | Used for |
|---|---|---|---|
| `lp.pastelSage` / `Amber` / `Rose` / `Teal` / `Yellow` | `#2f5648` / `#5a4128` / `#5c3534` / `#28495a` / `#52471f` | `#d3eae0` / `#fce5c8` / `#f9d5d2` / `#d0e8f0` / `#f8edb8` | Surfaces: info / attention / critical banners (sage, amber, rose), WG (sage) and OVPN (teal) badges. Dark mode uses muted pastel fills so light text keeps contrast. |
| `lp.selection` | `#4a6e62` (draft 8.3; was `#335a4c`) | `#d0e9de` | Sidebar selection (the List's tint). Selected rows switch their text (name and subtitle) to `lp.onPastel` (the system's white fails on a pastel in light mode); on the softer dark tone onPastel is 5.05:1 (High Contrast `#3f6658`, 6.46:1). |
| `lp.onPastel` / `lp.onPastel2` | `#eaf4ee` / 78 % | ink / 74 % | Text on every pastel surface: at least 4.5:1 on all six surfaces in all four appearances (tested). `onPastel2` is never drawn on the selection (3.79:1 there since draft 8.3). |
| `lp.softSage` / `Amber` / `Rose` / `Teal` / `Yellow` | `#a9d8c6` / `#f2b97a` / `#f2a0a0` / `#8fd0e2` / `#f0dc85` | `#3f8e78` / `#b8651a` / `#cc4a4a` / `#2b7a99` / `#9a7a10` | Marks outside the tiles: icons, chart lines and fills in Activity. True pastels in dark mode; **medium tones in light mode**, because a meaningful icon needs 3:1 on the light canvas and a true pastel can't (WCAG 1.4.11). |
| `lp.connectFill` / `lp.connectLabel` | `#9fd0ba` / `#001429` | `#a9d9c6` / `#001e28` | The Connect button: pastel sage with dark ink in both modes. |

Rule: a pastel surface never carries `lp.label2` or the status text colours; its text is `lp.onPastel`. Shape still carries the severity (icon silhouettes), colour is second.

Changes from the Go palette, and why:
- **Split accent into a fill role and a foreground role.** SwiftUI's prominent buttons and macOS selection draw **white** on the accent. White on `#80ae9a` is 2.49:1 and fails. `#2d7a68` passes in both modes. The signature Connect button keeps the Go look in dark mode through a custom `ConnectButtonStyle`: a `#80ae9a` fill with a navy `#001429` label (7.45:1).
- **Darker light-mode text variants for yellow and orange.** `#a07000` (4.02:1 on canvas) and `#b85500` (4.46:1) fail as text. They stay as glyph colors (≥3:1 is enough for meaningful icons) and get text variants `#7d5800` (5.9:1) and `#9a4700` (5.9:1).
- **Light secondary label 56% → 62%.** 56% measures 3.97:1 on canvas and fails; 62% is 4.8:1.
- **Strokes that mean something reach 3:1.** The old 32% borders measured 2.1–2.2:1 (dark) and 1.9:1 (light).
- **The system accent still wins.** If the user picked a non-multicolor accent in System Settings, macOS overrides `AccentColor` for controls. That is correct native behavior. `lp.protected` and the status colors are separate assets and are never overridden.

### 2.3 Contrast checks (WCAG 2.2 AA, computed)

Text needs ≥ 4.5:1 (≥ 3:1 for large text); meaningful UI and icons need ≥ 3:1.

| Foreground on background | Dark | Light | Verdict |
|---|---|---|---|
| Label on canvas | 11.21 | 11.41 | pass |
| Label on card | 8.73 | 12.19 | pass |
| Secondary on canvas (old) | 5.31 (65%) | 3.97 (56%) | dark pass, **light fail → 62% = 4.80** |
| Secondary on card | 4.55 | 4.90 (62%) | pass |
| Muted 38% on canvas | 2.60 | 2.35 | fail → decoration/disabled only; dark label3 at 55% = 4.12 |
| Sage on canvas | 7.45 | 4.72 | pass |
| Sage on grouped | 6.87 | 4.31 | light fails for small text → use `lp.label` for text there, sage for glyphs only |
| Red on card | 4.35 (`#ef5b5b`) | 5.08 | dark fail → error text uses `#f08888` (5.90) |
| Orange on canvas | 6.80 | 4.46 | light fail → `#9a4700` (5.90) |
| Yellow on canvas | 11.05 | 4.02 | light fail → `#7d5800` (5.91) |
| tx teal on canvas | 7.78 | 5.31 | pass |
| White on `AccentColor #2d7a68` | 5.13 | 5.13 | pass |
| White on `#80ae9a` (old dark buttons) | 2.49 | — | **fail** → navy label (7.45) or `#2d7a68` fill |
| White on red `#ef5b5b` (dark destructive) | 3.32 | — | fail → navy label (5.58) or system `.destructive` role |
| Old borders 32% | 2.17 | 1.87 | fail → 45% (3.14) / 55% (3.22) |
| Tray: white glyph on `#34C759` | 2.22 | 2.22 | **fail** → navy glyph (8.36) in the color icon option |
| Tray: white glyph on `#FF9F0A` | 2.06 | 2.06 | **fail** → navy glyph (9.02) |

### 2.4 Status is shape first, color second

Measured: sage, orange and red cannot be told apart by luminance (dark sage/orange 1.1:1). The rule is that **every state has a unique silhouette that works in a monochrome template image at 16 px**. Color only reinforces it. See the glyph table in §7.2.

### 2.5 Where the navy goes

The HIG for Tahoe and 27 says: let the system draw chrome (sidebar, toolbar, menus, sheets) in Liquid Glass, and don't paint opaque skins over it. A navy window background behind a glass sidebar fights the material and kills the scroll-edge effect.

So the palette lives in **brand surfaces**, not in chrome:
- the protection hero card in profile detail;
- the menu header card;
- the editor and the log view (`lp.sunken`);
- charts;
- onboarding illustrations;
- the app icon and the status glyphs.

**Grouped rows under a tile (draft 8.3, review S-8.17).** A blue tile (the hero card, the Diagnostics checks, Activity's live card) over the system's grey table rows looked unbalanced in dark mode. Tables in those panes (Activity sessions, Diagnostics routes) sit on `lp.panel` (`.lpPanel()`): dark `#0b2239`, between the canvas `#001429` and the card `#0d2b47`, the same family as the profile detail's grouped Form rows (translucent over the navy canvas); light mode keeps the system table's white. Comparison: S-8.24.

**Text fields (draft 8.3, review S-4.04).** Fields outside a system `Form` (editor Name, import Name, sign-in and password sheets, Diagnostics' route filter) use `lpField()`: plain field, fill `lp.field` (white 70 % on the light window, white 5 % on the dark one, so the field sits on the window instead of a grey block), 1 pt `lp.fieldBorder` (soft: ink 24 % / mint 28 %), 6 pt corner radius, a 2 pt accent ring while focused, and the ≥ 3:1 `lp.stroke` border under Increase Contrast. Fields in system Forms and toolbars stay system.

In dark mode, the detail column's background is `lp.canvas` navy. The sidebar, toolbar, menus, Settings and alerts stay system. This keeps "it looks like LockPlus" without the app looking like a web view in a frame (owner decision: brand surfaces only). On 26 and 27 the `NavigationSplitView` detail content extends under the floating glass sidebar, so the navy shows through the sidebar glass in dark mode; that is accepted deliberately and screenshot-tested on 26 and 27. No `.background(...)` is ever put on the sidebar `List`.

Typography is **SF Mono everywhere** (owner decision 2026-11-09): the system text styles (`.title`, `.headline`, `.body` = 13 pt, `.caption`) keep their sizes and weights, only the design is monospaced. It is defined once: `LPTypography.design` and the `lpTypography()` modifier at each root (scene content, the menu header host, the sign-in panel, the onboarding callout, the render harness); views never name a design. AppKit-drawn text takes `LPTypography.nsFont` (status item label, editor and gutter, NSMenu items through attributed titles). Not covered: NSAlert text and `NSMenuItem.subtitle` (system type, no API), window titles and toolbar/tab chrome that AppKit draws. Because mono is about 20 % wider and German 30-40 % longer, rows that carry names truncate in the middle with the full text as tooltip, and prose wraps. There are no custom fonts.

---

## 3. Design principles

1. **State before stuff.** The first thing on every surface (menu bar, menu, window) is "am I protected, and through what?" Everything else is below it.
   - ✅ The hero says "Protected · Work · Frankfurt", with throughput under it.
   - ❌ A list of 12 profiles with a small dot next to one of them.
2. **One tunnel, one truth.** The UI shows only what the system and the extension report: `NEVPNStatus`, plus the extension's `TunnelSnapshot` for detail (attempt, next retry, hold reason, last error) and the app's own pause state, combined by **one** derived-state table (§6.6, DESIGN §11.2). There is no optimistic state and no "Connecting…" before the system says `.connecting`.
   - ✅ The button reads "Connecting…" because the status is `.connecting`.
   - ✅ The hero says "Blocked" while `NEVPNStatus` is `.reasserting` and the snapshot holds a fatal error, without inventing retries.
   - ❌ The button flips to "Disconnect" on click and back again on error.
   - ❌ "Reconnecting… attempt 3" for a session the extension is holding without retries.
3. **Shape carries meaning; color confirms it.** Every state is distinguishable in grayscale, in a template image and with Differentiate Without Color.
   - ✅ An open shackle means off; a closed lock means on; a badge means "look at me".
   - ❌ A green dot vs a grey dot.
4. **Native first, brand second.** Use system components and materials. The brand appears in content surfaces, glyphs, motion and words, never in reskinned controls.
   - ✅ `Toggle`, `Form(.grouped)`, `Table`, system sheets, the palette in the hero card.
   - ❌ Pill buttons, custom switches, navy-painted sidebars.
5. **Say what protection actually does.** "Kill switch" only for full tunnels, "Route protection" for split tunnels, "Couldn't verify DNS" instead of a false green.
   - ✅ "Blocked: no traffic leaves this Mac until LockPlus reconnects."
   - ❌ "DNS leak test: safe" when the resolver couldn't be read.
6. **Quiet when healthy, loud only when it matters.** No toasts for routine events and no modal spam. Banners appear for things the user must act on; notifications appear only for unexpected state changes while the window is closed.
7. **Ninety percent from the menu bar, management in the window.** Connect, switch, pause and see the rate without opening a window. Import, edit, diagnose and review in the window.

---

## 4. Platform findings that shape the concept (2025–2026)

- **macOS 26 Tahoe** brought Liquid Glass to the menu bar, toolbars, sidebars and the Dock automatically on recompile. Apple's guidance: use system glass and adaptive materials, add custom `glassEffect` surfaces only for app-specific UI, and remove custom opaque backgrounds that obscure glass.
- **macOS 27** (WWDC26) keeps Liquid Glass but reworks it for readability: more uniform refraction, better contrast, a clear-to-tinted user slider, uniform toolbars, edge-to-edge sidebars, consistent window corners, and **far fewer icons in menus**. For us: no SF Symbol on every `NSMenuItem`, only on items where the symbol carries state (the profiles).
- **Minimum OS is macOS 26.0** (DESIGN §0, O1 revised in draft 7.1; drafts 1–5 targeted 15.1). Only 26 and 27 are supported, so every user gets Liquid Glass and there is no pre-glass look to finish. Content surfaces (the hero, the menu header) still never use Liquid Glass (HIG content layer). The only custom glass is for floating functional controls, with opaque `lp.card` under Reduce Transparency (`.lpSurface`, DESIGN §11.8). The `.regularMaterial` fallback for 15 is gone.
- **SF Symbols 7** (macOS 26, our floor) adds **Draw On/Off** and **Variable Draw**. Magic Replace (`.contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))`) morphs open → closed when both symbols share a layer structure, and on 26 and 27 the same call uses Draw Off/On for draw-annotated layers. No three-frame crossfade is needed in SwiftUI.
- **Menu bar surface choice.** `MenuBarExtra` gives no access to the status item or its window. `NSPopover`/`NSPanel` from a status item need custom dismissal, and a macOS 27 beta report shows views inside status-item buttons losing hover events. The Go app already learned (3f14acd) that event-monitor tricks break on 27. **A native `NSMenu` is the robust choice.** It brings keyboard navigation, VoiceOver and always-fresh content via `menuNeedsUpdate` for free. Rich content goes into **one** `NSMenuItem.view` header. Apple's own Wi-Fi and Bluetooth menus use the same pattern (a toggle in a header plus standard items).
- **macOS 27 specifics (ref/swiftui-appkit §0):** for apps linked on the 27 SDK, **all** menu item images (symbol and non-symbol) are hidden by default, so state glyphs need `preferredImageVisibility = .visible`; `occlusionState` no longer reflects whether a status item is visible (FB23349447), `isVisible` stays true when the item is hidden for lack of space, and there is no API for "Allow in the menu bar"; `NSStatusItem.expandedInterfaceDelegate` exists only for window extras (an `NSMenu` item is "handled automatically"), which confirms the `NSMenu` choice; the menu bar measures 30 pt while `NSStatusBar.thickness` still says 22.
- **Tailscale** shipped a windowed macOS UI (beta September 2025, GA 2026) because menu dropdowns can't show status through shape and color and have no search. They also hit the **notch problem**: status items pushed behind the notch on MacBooks become invisible. Lessons: keep a real window for management, keep the rate label short, and detect an invisible status item.
- **Mullvad**: the blocked state is a first-class state ("error state" = firewall blocking), not an error dialog. Its old menu bar padlock was red/green only, which is the color-only mistake to avoid.
- **The WireGuard macOS app**: a plain list-detail plus `NSMenu`. It's trustworthy but has no live feedback. **iStat Menus** and **Little Snitch**: live numbers in the menu bar with fixed-width digits, and a rich but optional menu header. **Raycast** and **CleanShot**: one strong signature interaction, everything else stays out of the way. **Ice and Bartender** exist because people hide menu items, so our status item must survive being hidden (DESIGN §11.3).

---

## 5. Three concept directions

### A. "Glass Companion" (menu-bar-first)

The status item opens a 340 pt glass panel that handles almost everything: the hero, profile switching, live chart, pause, and recent sessions. The main window is a secondary "Manage profiles" utility.

```
            ⌂ [🔒 ↓1.2M ↑30K]
  ╭───────────────────────────────────────╮
  │  🔒  Protected                 [● On] │
  │      Work · Frankfurt · WireGuard     │
  │  ↓ 1.2 MB/s  ↑ 30 KB/s     02:14:07   │
  │  ▁▂▃▅▇▆▄▃▂▂▃▅▆▇▅▃▂▁▁▂▃▄▅▆▅▄▃▂▁         │
  ├───────────────────────────────────────┤
  │  PROFILES                    🔍       │
  │  🔒 Work                    ✓ active  │
  │  🔓 Home NAS                          │
  │  🔓 Acme        needs code            │
  ├───────────────────────────────────────┤
  │  ⏸ Pause protection   ▸               │
  │  Auto-connect: on untrusted Wi-Fi     │
  ├───────────────────────────────────────┤
  │  Manage…     Diagnostics     ⚙        │
  ╰───────────────────────────────────────╯
```

- **Pros:** fastest path for daily use; looks great on Tahoe; feels like a modern utility (Tailscale, ProtonVPN, CleanShot).
- **Cons:** it needs `NSPanel`/`NSPopover` with custom dismissal, which is the exact area that broke on macOS 27 (3f14acd, plus the hover regression in the forums). VoiceOver and keyboard support must be hand-built. Glass needed a full fallback on 15 (moot since the 26.0 floor, DESIGN draft 7.1). Auth prompts and the editor still need windows, so you build two UIs anyway. Search and long lists in a transient panel are awkward.

### B. "Native Mac app with a living menu" (recommended)

A `NavigationSplitView` window (sidebar of profiles plus sections, detail with a protection hero), a standard `Settings` scene, and a native `NSMenu` status item whose first item is a live SwiftUI header.

```
┌────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   ⟨sidebar⟩                     Work            [+▾] [Connect ⌘K]│
├────────────────────┬───────────────────────────────────────────────────┤
│ 🔍 Search          │  ╭─────────────────────────────────────────────╮  │
│ Profiles           │  │   🔒   Protected                             │  │
│  🔒 Work      WG   │  │        Work · Frankfurt · WireGuard          │  │
│  🔓 Home NAS  WG   │  │                                              │  │
│  🔓 Acme      OVPN │  │   ↓ 1.2 MB/s   ↑ 30 KB/s   02:14:07   12 ms  │  │
│  🔓 Globex    OVPN │  │   ▁▂▃▅▇▆▄▃▂▂▃▅▆▇▅▃▂▁▁▂▃▄▅▆▅▄▃▂▁▁▂▃▅▆▇▅▃▂▁  │  │
│                    │  │                          [   Disconnect   ]  │  │
│ Activity           │  ╰─────────────────────────────────────────────╯  │
│ Auto-Connect       │   Connection   Endpoint, address, DNS, MTU …     │
│ Diagnostics        │   Protection   Kill switch ● on · Allow LAN      │
│ Logs               │   Notes        …                                 │
└────────────────────┴───────────────────────────────────────────────────┘
```

- **Pros:** everything is a stock component (List, Form, Table, Charts, sheets, NSMenu), so VoiceOver, keyboard, Liquid Glass on 26/27 comes for free. It matches DESIGN §11 almost exactly. It is the least-risk path for a single developer, and the menu header still gives the "live" feeling of A.
- **Cons:** it's less novel at first glance; identity has to come from the hero, the glyphs, the motion and the navy surfaces; the header in an `NSMenu` has known limits (no pickers, no keyboard focus), so the standard items below it must cover every action.

### C. "One Lock" (bold)

Drop the "tunnel manager" model entirely. Because only one tunnel can be active, the app is a single **protection instrument**: a compact 420×600 window that is one big hero with a profile switcher (a picker in the title bar, like Music's AirPlay picker). Management (library, editor, diagnostics, logs) lives in secondary windows. A **Control Center control** (WidgetKit `ControlWidgetToggle`, macOS 26+) and a desktop widget become first-class surfaces.

```
┌──────────────────────────────────────┐
│ ● ● ●        [ Work ▾ ]          ⋯   │
│                                      │
│                ╭────╮                │
│                │ 🔒 │                │
│                ╰────╯                │
│             Protected                │
│      Frankfurt · WireGuard · 12 ms   │
│                                      │
│     ↓ 1.2 MB/s          ↑ 30 KB/s    │
│  ▁▂▃▅▇▆▄▃▂▂▃▅▆▇▅▃▂▁▁▂▃▄▅▆▅▄▃▂▁▁▂▃▅   │
│                                      │
│         [     Disconnect     ]       │
│                                      │
│  Kill switch on · Auto-connect on    │
│  ⏸ Pause    ⓘ Diagnostics   📚 Library│
└──────────────────────────────────────┘
```

- **Pros:** the strongest identity; it models the real constraint honestly; a beautiful marketing screenshot; Control Center integration is something few VPN clients do.
- **Cons:** company users with 10–30 profiles need a real library, so the "secondary window" becomes the main app anyway. Diagnostics and logs get buried. Control Center controls (macOS 26, now the floor) need a widget extension and App Intents that start an NE configuration (spike needed). It is the most new UI to design and test.

### Recommendation: B, with one idea each from A and C

Choose **B**. The NE rewrite already carries the project's risk: the system extension, openvpn3, the kill-switch semantics and migration. The UI should be the part that "just works" on 26 and 27, and B is the only direction where nearly every surface is a stock component that Apple keeps working across releases. B gets most of A's daily-use speed through the live `NSMenu` header (which avoids the panel and event-monitor risk) and C's identity through the protection hero and the glyph language. C's Control Center control is a strong **v2.1** add-on once the core ships (Q7).

---

## 6. Screen-by-screen specs (direction B)

Sizes are in points. Window: default 920×620, minimum 900×580 (owner review 2026-11-10). Sidebar: 220–300, default 240.

### 6.1 Menu bar item

The status item is a variable-length `NSStatusItem` with an 18 pt template glyph and an optional rate label.

```
 Disconnected      [🔓]                       open shackle, outline
 Connecting        [🔒…]                      3-frame template sequence (shackle closing); static: closed outline + ellipsis badge
 Connected         [🔒 ↓1.2M ↑30K]            closed, filled body; label in monospaced digits
 Connected, idle   [🔒 ↓  0K ↑  0K]           label width never changes
 Reasserting       [🔒↻]                      closed + circular-arrow badge
 Blocked           [🔒⊘]                      closed filled + no-entry badge   (attention)
 Auth needed       [🔒!]                      closed outline + exclamation badge
 Paused            [🔓⏸]                      open shackle + pause badge       (attention)
 Error (stopped)   [🔓!]                      open shackle + exclamation badge
```

- **Centring (draft 8.3, review S-6.02/S-12.02):** the lock **body** is centred in the status item. `LockGlyphImage.statusTemplate` puts every state on one canvas that is symmetric around the body's centre (measured from the closed lock's ink) and wide enough for the furthest badge on the right; the badge uses that room instead of pushing the lock left. The colour tile wraps the same canvas, so it is centred too; with rates the image slot is the same. About 2 pt wider than before.
- **Glyph size:** a template symbol from the custom family, sized with `NSImage.SymbolConfiguration(pointSize: ~15–16, weight: .medium)` and tuned by eye on 26 and 27 (30 pt measured); never derived from `NSStatusBar.thickness`. While connecting, a 3-frame template sequence on a `.common`-mode timer (~120 ms); static with Reduce Motion.
- **Label formats** (Settings › Menu Bar): Off / Download only `↓1.2M` / Both `↓1.2M ↑30K` (default). The label is shown only while connected and hidden while blocked. A fixed-width formatter keeps 3 significant characters plus a unit (`K`, `M`, `G`), with the locale decimal separator (`1,2M` in German). The font is `monospacedDigitSystemFont(ofSize: 11)`; it fixes digit widths only, so `item.length` is set to the widest possible label for the locale, measured once. The maximum width is about 76 pt, which keeps the item out of the notch zone on 14" MacBooks.
- **Icon style** (Settings › Menu Bar): **Color** (default since draft 8.2, owner decision 2026-11-09: you see the state at a glance; the v1.0.61 look: a whole-background tile, white idle, `#34C759` connected, `#FF9F0A` attention, with a **navy glyph**, because white glyphs fail at 2.2:1) or **Monochrome** (template; follows Liquid Glass tinting and the light/dark menu bar). Both keep the shape language. Migration: settings schema 2; a schema 1 file's stored monochrome (the old default, written into every file) becomes Color once, any choice made from schema 2 on is kept.
- **Accessibility label** (one wording, also DESIGN §11.6): "LockPlus, protected, Work, download 1.2 megabytes per second, upload 30 kilobytes per second." Blocked: "LockPlus, blocked, waiting to reconnect Work." Blocked after a fatal error: "LockPlus, blocked, Work stopped: <short error>." Blocked during a held first connect (§6.6 row 3a): "LockPlus, blocked, Work couldn't connect: <short error>." Sign-in needed (rows 3, 9): "LockPlus, sign-in required, Work." Paused: "LockPlus, paused, 12 minutes left."
- **Visibility (no reliable signal exists on 27):** the main window opens once on first launch and after every update; if the menu wasn't opened in the last 5 launches, the window opens at launch and Settings › Menu Bar shows "The menu bar icon may be hidden" with help; **"Show in menu bar"** in Settings › Menu Bar sets `isVisible = true` (required by `.removalAllowed`: the app must offer a way back); the Dock menu always has "Open LockPlus" (DESIGN §11.3).

### 6.2 The menu

A native `NSMenu`, rebuilt in `menuNeedsUpdate`. Item 0 is a custom view (`NSHostingView` of `MenuHeaderView`, fixed width 340 since draft 8.3, was 300); everything below is a standard item.

```
╭──────────────────────────────────────────╮
│ ╭──────────────────────────────────────╮ │
│ │ 🔒  Protected                 [ ●  ] │ │   ← Toggle: on/off for the current profile
│ │     Work · WireGuard · 02:14:07      │ │
│ │     ↓ 1.2 MB/s   ↑ 30 KB/s           │ │
│ │     ▁▂▃▅▇▆▄▃▂▂▃▅▆▇▅▃▂▁▁▂▃▄▅▆▅▄▃▂▁     │ │   ← 60 s sparkline, rx solid / tx dashed
│ ╰──────────────────────────────────────╯ │
├──────────────────────────────────────────┤
│ Disconnect Work                          │   ← standard item for the header switch (always present)
│ Protected, Work, ↓ 1.2 MB/s ↑ 30 KB/s …  │   ← status text item, only while VoiceOver runs
├──────────────────────────────────────────┤
│ ✓ 🔒 Work                                │   ← active profile: checkmark + state glyph
│   🔓 Home NAS                            │
│   🔓 Acme                                │
│   🔓 Globex                              │
│   More Profiles                        ▸ │   ← after 8 profiles, alphabetically
├──────────────────────────────────────────┤
│ Pause Protection                       ▸ │   ← 5 min / 15 min / 1 hour (only when something is protected)
├──────────────────────────────────────────┤
│ Open LockPlus                            │
│ Settings…                             ⌘, │
│ Quit LockPlus                         ⌘Q │
╰──────────────────────────────────────────╯
```

- The header card is **opaque `lp.card`** with a 12 % state tint (`lp.protected` when connected, attention when blocked), the same on every OS. No `glassEffect`: the menu is already Liquid Glass, and glass can't sample glass. The hero glyph is 28 pt. The `NSHostingView` is created once and reused, with its **default** sizing options (S15: `sizingOptions = []` makes its fitting size zero); it re-renders through Observation while the menu is open (stats poll at 1 Hz while the menu is a consumer). S15 showed on 27 that this alone keeps it live with no layout jump; the 1 Hz `.common`-mode timer stays only as the fallback until the 26 run (draft 6: 15.1 is no longer supported) (DESIGN §11.3, Conflicts aa, ah).
- **The header is not an accessibility element** (`setAccessibilityElement(false)`), and its content is duplicated by standard items (corrected in DESIGN draft 5, Conflicts j: draft 4 claimed this already held, but the switch and the sparkline/rate summary had no equivalent):
  - **"Disconnect Work" / "Connect <last-used profile>"** directly below the header, always present: the switch's action as a standard item, for VoiceOver and Full Keyboard Access;
  - a **status text item** (`NSMenuItem.sectionHeader(title:)`, non-interactive), shown only while VoiceOver runs (`NSWorkspace.shared.isVoiceOverEnabled`, checked in `menuNeedsUpdate`): the header's facts in one sentence, state, profile, rates and the sparkline's last-minute summary ("Protected, Work, download 1.2 megabytes per second, upload 30 kilobytes per second; last minute average 800 kilobytes per second, peak 10 megabytes per second");
  - the status item's own label (§6.1).
- **The header never truncates (draft 8.3, review 2026-11-09).** No line limits: title, message and detail wrap as far as their text needs and the header's height follows (`fittingSize`). 340 pt fits the widest standard items in SF Mono ("Systemeinstellungen öffnen…", "Enter Code for <name>…") and keeps German titles to two lines. Rows whose hero title is a long sentence get a short **header** title; the full sentence stays in the hero and window, or moves to the header's message line:

  | Row | Header title (en / de) | Message line |
  |---|---|---|
  | 1, not allowed / turned off / removed / damaged | Tunnel component not allowed / turned off / removed / damaged · Tunnelkomponente nicht erlaubt / ausgeschaltet / entfernt / beschädigt | as the hero |
  | 1, restart | Restart needed · Neustart nötig | as the hero |
  | 3b, 8, 13a | Auto-connect paused for Work · Automatisches Verbinden für Work pausiert | the error sentence |
  | switch | Switching to Home NAS… · Wechsel zu Home NAS… | Not protected for a moment. · Für einen Moment nicht geschützt. |
  | 4a | Reconnecting… · Neuverbindung… | as the hero |
  | 4a, not responding | Work isn't responding · Work antwortet nicht | The tunnel process doesn't answer. · Der Tunnelprozess reagiert nicht. |
  | 9 | New code needed for Work · Neuer Code für Work nötig | Traffic is blocked meanwhile. |
  | 14 | Stopped, not protected · Gestoppt, nicht geschützt | the error sentence |

  Render fixtures with a 35-character profile name cover every header that names the profile (S-1.67 to S-1.79).
- **States of the header.** Disconnected: "Not protected", the last-used profile, switch off, no sparkline (the space collapses). Connecting: "Connecting to Work…" with an indeterminate shackle animation. Blocked: an orange-tinted card, "Blocked — reconnecting Work", and a second line "No traffic leaves this Mac" (the pause items move up directly under the header). Auth: "Authentication required" plus a standard item below, "Enter Code for Acme…", which is bold and has the key equivalent ↩.
- **Clicking a profile item** connects it, or disconnects it if it is the active one. Clicking a different profile while one is connected switches directly. The disconnect is implicit, because LockPlus runs one tunnel at a time (a design decision: the kill switch routes all traffic through one tunnel). **Switching is an unprotected moment** even between two kill-switch profiles (the first tunnel stops before the second starts; DESIGN §16, LK-17): the hero and header show "Switching to Home NAS — not protected for a moment" until the new status is `.connected`. There is no confirmation, unless the active profile has the kill switch on **and** the target doesn't. Then: "Switch to Home NAS? Home NAS has no kill switch, so traffic outside the tunnel won't be blocked."
- **Pause rule** (one rule, also DESIGN §11.3): "Pause Protection ▸" is shown while a tunnel is connecting, connected, reasserting or held, or any profile has auto-connect/stay-connected on-demand enabled; "Resume Protection Now (12 min left)" replaces it while paused; otherwise it is hidden. (Draft 1's drawing always showed it.)
- **"Update Available…"** appears below the pause items when Sparkle's gentle reminder has an update (the app is an accessory app most of the time, so Sparkle doesn't pop alerts behind other windows).
- **Keyboard:** the header is not focusable, so every action it offers also exists as a standard item. Its toggle is the "Connect/Disconnect <profile>" item (and also matches clicking the active profile's item); if the toggle should dismiss the menu, it calls `menu.cancelTracking()`. The switch's displayed state is bound to the derived state only, never to local `@State`.
- **Following macOS 27:** symbols appear only on profile items (state glyphs), each with `preferredImageVisibility = .visible` (27 hides all menu item images by default for apps on its SDK); utility items stay `.automatic`. Profile subtitles ("Protected · 02:14") use `NSMenuItem.subtitle`; "Profiles" is an `NSMenuItem.sectionHeader`.
- **Settings…** from the menu reaches the SwiftUI Settings scene through a hidden bridge window (DESIGN §11.1); `showSettingsWindow:` is dead since macOS 14. S15 (27): it opens with or without a main window. When macOS refuses to activate LockPlus (no user click behind the request), the Settings window would open **behind** the frontmost app; LockPlus then brings the window to the front without activating it, so it is at least visible.

### 6.3 Main window

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  ▤                     Work                    [+ ▾]  [ Connect ] │  ← unified toolbar
├────────────────────┬─────────────────────────────────────────────────────┤
│ 🔍 Search  ⌘F      │                                                     │
│                    │           (profile detail, §6.4)                    │
│ Profiles           │                                                     │
│  🔒 Work           │                                                     │
│     Protected      │                                                     │
│  🔓 Home NAS       │                                                     │
│     Auto-connect   │                                                     │
│  🔓 Acme           │                                                     │
│     OpenVPN · OTP  │                                                     │
│                    │                                                     │
│ ─────────────────  │                                                     │
│ ◷ Activity     ⌘2  │                                                     │
│ ⌁ Auto-Connect ⌘3  │                                                     │
│ ✚ Diagnostics  ⌘4  │                                                     │
│ ≡ Logs         ⌘5  │                                                     │
│                    │                                                     │
│ [+]  [−]       ⋯   │  ← sidebar footer: Import, Delete, More             │
└────────────────────┴─────────────────────────────────────────────────────┘
```

- **Sidebar:** a `List(selection:)` with a `.sidebar` style. Profile rows: a state glyph (16 pt) and the name (`.headline`), with a subtitle (`.subheadline`, secondary) giving the most useful fact: "Protected · 02:14", "Auto-connect", "OpenVPN · OTP", "Needs attention". The protocol appears as a tag (WG/OVPN) only when the window is wide (≥ 280 pt sidebar) or as a VoiceOver hint.
- **Sidebar row rule (draft 8.2):** the name is **one line, middle truncation** ("ovpn-auth-…-crv1"), the full name in the tooltip; the subtitle may take two lines (German). The sidebar is 250-340 pt wide (ideal 280): SF Mono is wider, and a name must not wrap mid-word at a hyphen. The protocol badge is a pastel chip (WG sage, OVPN teal) with `lp.onPastel` text; the selection is `lp.selection` with `lp.onPastel` text; section icons are `lp.softSage`.
- **Order:** the active profile pins to the top; the rest follow a user-defined drag order (default alphabetical).
- **Sections** below the profiles use SF Symbols `clock.arrow.circlepath`, `wifi.circle`, `stethoscope` and `list.bullet.rectangle`. There is no "Statistics" section; it merges into Activity (§6.10).
- **Toolbar:** the `+` menu (New WireGuard Profile, New OpenVPN Profile, Import File…, Import QR Code Image…, Import from Clipboard), plus the primary Connect/Disconnect for the selected profile, mirrored in the hero.
- **Drop target:** the entire window. On drag-over, a full-window overlay appears with `lp.stroke` dashed 2 pt around the detail area and the text "Drop .conf, .ovpn, .zip or a QR code image".
- **Selection:** at launch (and whenever the selected profile is deleted) the window selects the active profile, else the last used one, else the first listed; the detail never stays empty while profiles exist. One source of truth: `ProfilesUIModel.selection` (set by the binder, the editor and Duplicate) and the window's selection follow each other. With profiles but no selection the detail shows "Select a profile" (§6.15).
- **Empty library:** the detail shows `ContentUnavailableView` (§6.14), and the sidebar shows a single "Import Profile…" row.

### 6.4 Profile detail

```
╭───────────────────────────────────────────────────────────────╮
│  🔒   Protected                                               │  lp.card (opaque), sage tint 12 %
│       Work · Frankfurt (vpn.example.de) · WireGuard           │
│                                                               │
│   ↓ 1.2 MB/s       ↑ 30 KB/s       02:14:07      Handshake 21 s│  monospaced digits
│   ▁▂▃▅▇▆▄▃▂▂▃▅▆▇▅▃▂▁▁▂▃▄▅▆▅▄▃▂▁▁▂▃▅▆▇▅▃▂▁▁▂▃▄▅▆▅▄▃▂▁▁▂▃▅      │  5 min, Swift Charts
│                                                               │
│   ✓ DNS through tunnel (verified)                [Disconnect] │
╰───────────────────────────────────────────────────────────────╯

 Connection                                              Form(.grouped)
   Endpoint          vpn.example.de:51820  (198.51.100.7)
   Address           10.8.0.2/32, fd00::2/128
   DNS               10.8.0.1
   Routes            All traffic (0.0.0.0/0, ::/0)
   MTU               1420
   Received / Sent   1.4 GB / 92 MB this session
   Cipher            AES-256-GCM            (OpenVPN only, and only when known; draft 6)

 Protection                       (disabled while connected: "Disconnect to change")
   Kill switch                                   [●  ]
     Blocks all traffic outside the tunnel, including if it drops.
   Allow local network (printers, NAS)           [  ○]      (off by default)
   Block IPv6 without kill switch                [  ○]      (v4-only full tunnel only)

 Auto-Connect
   This is the auto-connect profile.  Edit rules…

 Credentials                                       (OpenVPN only)
   Username          j.appleseed
   Password          Saved in Keychain     [Change…] [Forget]
   One-time code     Asked on every connect

 Notes
   ┌───────────────────────────────────────────────┐
   │ Office VPN, ask IT for new keys in March      │
   └───────────────────────────────────────────────┘

 Import report        2 directives ignored ▸
                                                       [Edit Config… ⌘E]  [Export… ⇧⌘E]
```

- **Hero states:**
  - Disconnected: an open shackle, "Not protected", the button "Connect" (`ConnectButtonStyle`, large), and the last session summary ("Last connected yesterday, 1 h 29 m").
  - Connecting: the shackle animates; "Connecting…" and a phase line from status ("Waiting for handshake").
  - Connected: as drawn.
  - Reasserting (kill switch off): a ↻ badge and "Reconnecting… (attempt 2)" from the snapshot's `attempt`.
  - Blocked (kill switch on: reconnecting, or held after a fatal error): §6.6.
  - Switching: "Switching to Home NAS — not protected for a moment" (§6.2).
  - Error: a red critical banner **inside** the hero with the localized message and "Details…" (DESIGN §11.7).
- **The kill switch is called "Route protection"** with the text "Keeps the tunnel's routes in place. Traffic to other destinations is **not** blocked." for split-tunnel profiles (DESIGN §10.1).
- **"Allow local network" is off by default** for every profile (TunnelCrack LocalNet; DESIGN §3.1, F-1). Turning it on shows: "Devices on this network (printers, NAS, AirPlay) can be reached outside the VPN. A hostile Wi-Fi network can abuse this." It applies to full tunnels with the kill switch and to route-protected split tunnels.
- **Kill switch off, explained:** the toggle's footer says "Without the kill switch, a malicious Wi-Fi network can route some traffic around the VPN (TunnelVision)." (DESIGN §10.1.2).
- **Kill switch on, explained honestly (draft 7, DESIGN §20 risk 24):** the footer says "Blocks all traffic outside the tunnel, including if it drops. If LockPlus's tunnel process crashes, macOS lets traffic through for under 2 seconds until it restarts it." (E2E measured 1.3–1.7 s on product builds; the S2 E1 spike measured 2.45–2.86 s). The help page adds that an auto-connect profile isn't restarted by macOS after such a crash; *draft 8 (DESIGN §10.4):* while LockPlus is running it restarts that profile itself about 1.5 seconds after macOS reports the disconnect.
- **Protection settings being restored (draft 8, DESIGN §3.4, E2E-1).** macOS can rewrite a just-saved VPN configuration and drop the kill switch. While the configuration's flags differ from the profile, the hero of a kill-switch profile shows an attention strip, "Restoring this profile's protection settings in macOS. The kill switch isn't active until they're verified, and LockPlus won't connect before that." (de: "Die Schutzeinstellungen dieses Profils werden in macOS wiederhergestellt. Der Kill Switch ist erst aktiv, wenn sie bestätigt sind, und LockPlus verbindet sich vorher nicht."), and the derived state treats the profile as having no kill switch, so no row claims protection it doesn't have.
- **Reconnected after a crash (draft 8, DESIGN §11.2, PF 53).** When the session comes back by itself within 2 minutes of a tunnel-process crash (macOS's restart or LockPlus's), the hero shows an info strip, "Reconnected after a tunnel process restart." (de: "Nach einem Neustart des Tunnelprozesses wieder verbunden."), until the user connects or disconnects or the session ends.
- **The DNS line** comes from `DNSVerifier`: "✓ DNS through tunnel (verified)" / "⚠ DNS overridden by another profile" / "? Couldn't verify DNS". `.unknown` never uses the check glyph.
- **Cipher row (draft 6, DESIGN §7.7):** openvpn3's connection info has no cipher field, so the row comes from the negotiated-cipher log line. When that isn't available the row is **hidden**, never shown as "Unknown" or "—".
- Rows are selectable text (copyable). The private key is never shown in detail; it appears only in the editor behind Touch ID. Section titles (Connection, Protection, Auto-Connect, Credentials, Notes) carry the header trait for VoiceOver's Headings rotor.
- "Password: Saved in Keychain [Change…] [Forget]" has a "Show" action behind Touch ID (`RevealGate`, F-10); the revealed password sheet sets `sharingType = .none` and closes after 60 s.

### 6.5 Connect and auth flows

Auth prompts appear as a **sheet** on the main window when it is visible. Otherwise LockPlus posts a notification ("Acme needs sign-in", the profile name only) and shows the menu item "Enter Code for Acme…"; the prompt opens only after the user's **gesture** (clicking the notification, the menu item or the Dock icon), as the main window with the sheet or a small **non-activating** `NSPanel` anchored to that gesture. LockPlus never pops an activating credential window by itself: that is spoofable, trains users to type secrets into whatever appears, and macOS doesn't guarantee background activation anyway. One prompt at a time, keyed by `promptID` (DESIGN §8.4, F-9).

```
 Password (not saved)                     Static challenge (SC)
╭──────────────────────────────────╮     ╭──────────────────────────────────╮
│ 🔑  Sign in to Acme              │     │ 🔑  Sign in to Acme              │
│                                  │     │                                  │
│ Username       [j.appleseed  ]   │     │ Username  [j.appleseed       ]   │
│ Password       [••••••••      ]  │     │ Password  [••••••••           ]  │
│ One-time code  [              ]  │     │ "Enter your Authenticator code"  │  ← server text, verbatim
│                                  │     │ Response  [123456             ]  │  echo per flag
│ ☐ Save password in Keychain      │     │ ☐ Save password in Keychain      │
│   (the code is never saved)      │     │                                  │
│            [Cancel]  [Connect ↩] │     │            [Cancel]  [Connect ↩] │
╰──────────────────────────────────╯     ╰──────────────────────────────────╯

 Dynamic challenge (CRV1)                 Rejected
╭──────────────────────────────────╮     ╭──────────────────────────────────╮
│ 🔑  Verification required        │     │ ⚠  The server rejected the       │
│                                  │     │    sign-in for Acme.             │
│ Signed in as j.appleseed         │  ←  │    "Invalid OTP" (server)        │
│ "Enter the code sent to ••42"    │ read │ Username       [j.appleseed  ]   │
│ Response  [                   ]  │ only │ Password       [              ]  │
│                                  │     │ One-time code  [              ]  │
│            [Cancel]  [Verify ↩]  │     │            [Cancel]  [Try Again] │
╰──────────────────────────────────╯     ╰──────────────────────────────────╯
```

- **When the prompt appears (DESIGN §8.4, draft 9).** macOS doesn't limit how long a VPN may take to connect (S2), so a sign-in happens **inside** the connect:
  - **Known before connecting** (password not saved, static challenge, key passphrase not saved): clicking Connect opens the sheet first, while the Mac is still online; "Connect ↩" submits and starts the tunnel, which uses the answer. The hero says "Connecting to Work…" only after the sheet is submitted.
  - **Asked by the server during the connect** (dynamic challenge, a rejected password, a password the app didn't expect): the connect keeps waiting, the hero shows "Sign in to connect Work" (row 3, not an error), the sheet opens (or the notification, per the gesture rule above), and "Verify ↩"/"Try Again" **answers into that same connect**: it goes on and connects, with no second click on Connect and no "connect again" step. With the kill switch on, the Mac stays blocked while the sheet is open ("No traffic leaves this Mac until you sign in or disconnect"). The sheet stays valid for 10 minutes (a dynamic challenge: 5 minutes, because servers forget the challenge; the test server after 300 s); after that it closes with "The sign-in request expired. Connect again."; with the kill switch the connect is then held, blocked, until Disconnect (row 3a).
  - **An expired or already-used code** comes back from the server as a plain rejection. For a dynamic challenge LockPlus then fetches a new challenge by itself and shows the CRV1 sheet again with "The code was not accepted or has expired. Enter the new code." (never "wrong password"; DESIGN §8.4).
  - Cancel on either sheet leaves the profile disconnected with no error. Cancel on a sheet that came during a connect also stops that connect (a Disconnect), so a kill-switch connect never stays blocked behind a cancelled sheet.
- **Form rule (draft 8.2):** every label-plus-field group (these sheets, change/reveal password, import, the editor's Name row) is one `LPFormGrid`: labels left-aligned in one column, all fields on the same leading edge and filling the rest of the width, so "One-time code" never starts left of "Username". System `Form` panes (Settings) already align this way.
- The "One-time code" field appears only for `appendOTP` profiles; the app concatenates (DESIGN §8.4). After 3 rejections in 10 minutes, the sheet closes and the hero shows the `.authFailed` error.
- **Reconnect needing a code** (no auth-token, OTP profile): the menu bar shows the `!` badge, the header says "Enter a new code to stay connected", and the hero shows the reason "Your server asks for a new code on reconnect". A user notification appears only if no window is key: "Acme needs a new one-time code".
- **Notifications never carry the challenge**, the server's text or a username, and offer **no text-input action** (`UNTextInputNotificationAction`): a code typed into a notification bypasses the secure field and lingers in Notification Center.
- **Waiting for approval** (`AUTH_PENDING`, e.g. a push prompt on the user's phone): the sheet shows "Waiting for sign-in approval…" with a progress indicator and Cancel. It waits up to the server's timeout, at most 10 minutes, during a first connect too (draft 7: the 50 s limit is gone); if the approval never comes, the sheet says "Approval took too long. Try again to get a new request." with **Try Again** (a new connect, a new push).
- **Web/SSO profiles:** no prompt; an error banner, "This server uses web sign-in, which LockPlus doesn't support yet."
- **Touch ID** (`LAContext` `.deviceOwnerAuthentication`: Touch ID, a paired Apple Watch, or the login password) gates **revealing secrets**: opening the editor of an existing profile, exporting a profile with keys, "Show password", Duplicate, and export all. It never gates connecting with saved credentials (that would break on-demand). One successful check covers 60 s (LockPlus's own timer; cleared on lock, sleep and when the app loses focus). The button labels say why: "Edit Config…" shows the 􀟒 touchid symbol. The `localizedReason` is "show the keys for “Work”" **without** the app name, which macOS already puts in the dialog title (ref/security C11).
- Secure fields are cleared on submit and on dismiss; prompt windows set `sharingType = .none`.
- **A failed answer (draft 6):** if sending the answer fails (the tunnel process is busy or the prompt expired), the same sheet comes back with an error line under the fields saying why; it never just disappears. The username field is prefilled from the saved username.
- **Server text (draft 6, DESIGN §8.4):** the challenge text and the server's rejection reason are shown in quotes and marked as coming from the server, after control and bidirectional-override characters are removed, newlines are collapsed to spaces and the text is cut at about 256 characters.

### 6.6 Kill switch, "Blocked", and the derived-state table

Blocked is a state, not an error dialog. There are two kinds, and the UI must not confuse them (F-4):
- **Blocked, reconnecting:** a kill-switch profile is reasserting and the extension keeps retrying. Retry text is real.
- **Blocked after a failure:** the extension hit a fatal error and **holds** the session without retries (DESIGN §7.2 `held`, the Go app's `fwBlocked`). There is no retry text; the only way out is Disconnect.

```
 Blocked, reconnecting (table row 10)
╭───────────────────────────────────────────────────────────────╮
│  🔒⊘  Blocked                                                 │  attention tint (orange 12 %)
│       Work lost its connection. No traffic leaves this Mac    │
│       until LockPlus reconnects.                              │
│                                                               │
│   Reconnecting… attempt 3 · next try in 20 s                  │
│                                                               │
│   [ Disconnect and Restore Internet ]   [Pause ▾]  [Details…] │
│   On a hotel or café network? Pause protection to sign in.    │
╰───────────────────────────────────────────────────────────────╯

 Blocked after a failure (table row 7): no retries, no Pause
╭───────────────────────────────────────────────────────────────╮
│  🔒⊘  Blocked                                                 │  attention tint (orange 12 %)
│       Work stopped: the server's certificate is not trusted.  │
│       No traffic leaves this Mac.                             │
│                                                               │
│   [ Disconnect and Restore Internet ]              [Details…] │
╰───────────────────────────────────────────────────────────────╯
```

**Derived-state table** (the only mapping from engine state to UI; DESIGN §11.2; unit-tested row by row). Inputs: `NEVPNStatus`; the profile's kill switch; `lastError` (`fetchLastDisconnectError` only after a disconnect the app observed; at launch the snapshot's `lastError` with its time, shown only with a start latch or when newer than the app's last quit, because macOS keeps returning an old error; DESIGN §5.5); the snapshot's `phase`, `attempt`, `nextRetryAt`, `holdReason`, `holdBeforeConnected`, `startLatch`; `awaitingApproval`; `pausedUntil`; the extension state and the XPC link state (`validated`/`reconnecting`/`unavailable`, DESIGN §5.4). Rows are evaluated **in the listed order**; first matching row wins. **Draft 7 (DESIGN draft 9, S2):** a hold exists **after** Connected (status `.reasserting`, rows 7–9) and, with the kill switch, **before** Connected (status `.connecting`, rows 3a/3b): a kill-switch connect that fails is held, blocked, because macOS lets a failed connect through (S2 E14c) and doesn't limit how long a connect may take (E14b). macOS never blocks while it says "disconnected" (a failed start and a provider cancel are open, E3/E14c), so `.disconnected` rows are never "Blocked".

| # | Condition | Glyph (§7.2) | Hero / header copy | Actions |
|---|---|---|---|---|
| 1 | Extension not ready (`needsUserApproval`, `disabledByUser`, `removedDuringUpdate`, `failed`) | needs attention `!` | "The tunnel component isn't allowed yet" / "…is turned off in System Settings" / "…was removed during the update" / "…is damaged" | Open System Settings, plus **Show the Switch Again** while waiting for approval (§6.14) / Approve / Reinstall |
| 2 | `pausedUntil` in the future | paused `⏸` | "Paused — 12 min left. Your Mac is not protected." | Resume Now |
| 3 | `.connecting` and `phase == .awaitingAuth` (a sign-in inside the pending connect: the server asked for a code, rejected the password, or waits for an approval; draft 7: the answer connects this same attempt) | needs attention `!` | "Sign in to connect Work." (or "Waiting for sign-in approval…"); with the kill switch: "No traffic leaves this Mac until you sign in or disconnect." (S2 E14a: blocked), otherwise "Work is waiting for you to sign in." **Not an error.** | Enter Code… / Cancel (Cancel also disconnects) |
| 3a | `.connecting`, kill switch on, `holdReason == .blockedAfterFailure(e)` (a held connect: the extension withholds the start completion after a failure; DESIGN §7.2, S2 E14) | blocked `⊘` | "Blocked — Work couldn't connect: <e>. No traffic leaves this Mac." Retry text **only** while a retryable failure retries inside the hold ("Retrying… attempt 2 · next try in 4 s", from `attempt`/`nextRetryAt`); none for a failure that waits for the user. **Never "Connecting…".** | Disconnect and Restore Internet, Details |
| 3b | `.connecting`, `holdReason == .nonRetryable(e)` (an auto-connect start held before Connected) | error `!` (blocked `⊘` if kill switch on) | "<e>. Auto-connect is paused for Work." | Sign In… / Disconnect |
| 4 | `.connecting` | connecting `…` | "Connecting to Work…" + phase line | Cancel |
| 4a | `.connected` and the XPC link is `reconnecting` (the tunnel process was interrupted, usually a crash; macOS reports the disconnect only ~5 s later, and launchd may need up to ~11 s to restart the process; DESIGN §5.4) | reasserting `↻` | "Reconnecting to the tunnel process…" (never "Protected"). If the link becomes `unavailable` while macOS still says connected: "Work's tunnel process isn't responding." | Disconnect, Details |
| 5 | `.connected` and DNS `.unknown`/`.mismatch` | needs attention `!` (closed lock) | "Protected · Work" + "Couldn't verify DNS" | Run Diagnostics |
| 6 | `.connected` | protected | "Protected · Work · Frankfurt · WireGuard" | Disconnect |
| 7 | `.reasserting`, kill switch on, `holdReason == .blockedAfterFailure(e)` | blocked `⊘` | "Blocked — Work stopped: <e>. No traffic leaves this Mac." **No retry text.** | Disconnect and Restore Internet, Details |
| 8 | `.reasserting`, `holdReason == .nonRetryable(e)` (on-demand) | error `!` (blocked `⊘` if kill switch on) | "<e>. Auto-connect is paused for Work." | Sign In… / Disconnect |
| 9 | `.reasserting`, kill switch on, `phase == .awaitingAuth` | needs attention `!` | "Enter a new code to reconnect Work. Traffic is blocked meanwhile." | Enter Code…, Disconnect |
| 10 | `.reasserting`, kill switch on | blocked `⊘` | "Blocked — reconnecting Work. No traffic leaves this Mac." + "attempt 3 · next try in 20 s" (from `attempt`/`nextRetryAt`) | Disconnect and Restore Internet, Pause ▸, Details |
| 11 | `.reasserting`, kill switch off | reasserting `↻` | "Reconnecting Work… attempt 3" | Disconnect |
| 12 | `.disconnecting` | connecting `…` (shackle lifting) | "Disconnecting…" | — |
| 12a | `.disconnected`/`.invalid` while the app's own start work holds a Connect back (`ConnectionStore.startHold`, draft 8.1): a start being prepared (flags verified, other auto-connect paused, the configuration settling) or issued without a status yet; a start waiting for a session to stop (NE drops a start issued while it stops, S2); NE's (or LockPlus's) restart after a tunnel-process crash. Before 13a/14/15, so a Connect that would be ignored is never offered. | connecting `…` (short word "Preparing…" / "Waiting…", never "Connecting…") | "Preparing to connect Work… Not protected yet." / "Waiting for Home NAS to disconnect… Then LockPlus connects Work. Not protected meanwhile." / "Waiting for Work's tunnel process to restart… Not protected until Work is back." (≤ 30 s; the menu header uses "Preparing Work…" / "Waiting for Home NAS to disconnect…" / "Waiting for Work to restart…"). *Review e321e10:* when a restart is only possible (an unexpected stop without a seen crash): "Checking whether Work restarts…" / "Work stopped unexpectedly. Not protected meanwhile." (≤ 10 s; header "Checking Work…"), with Cancel. *Review 5c3a899/f18c0d6 L-3:* when it is LockPlus's own start that ended before any status was read (not a stop of a running session): "Checking whether Work starts…" / "The start ended early. Not protected meanwhile." (de: "LockPlus prüft, ob Work startet…" / "Der Start wurde vorzeitig beendet. Währenddessen nicht geschützt."; same header and Cancel; never "stopped unexpectedly"). *E2E-4 200011:* a Connect while the Mac has no network starts nothing until one is available: "Waiting for a network to connect Work…" / "Not protected until a network is available." (de: "Warte auf ein Netzwerk, um Work zu verbinden…" / "Nicht geschützt, bis ein Netzwerk verfügbar ist."; header "Waiting for a network…" / "Warte auf ein Netzwerk…"; no time limit; other Connects held), with Cancel. When macOS refused a kill-switch start for want of a network and connects it by itself once one returns: "Work connects when a network is available." / "Not protected until a network is available." (de: "Work verbindet sich, sobald ein Netzwerk verfügbar ist." / same second line; same header), with Cancel (stops Work, so macOS doesn't connect it later); a Connect of another profile stays available and stops Work first; no "stopped unexpectedly" notification | Cancel (none while a seen crash's restart is awaited). *E2E-4 200012:* this row also wins over row "Switching…" while the target has no status yet (a switch: "Waiting for Home NAS to disconnect…", short word "Waiting…"); the switching row appears only once NE reports `.connecting` (or when no hold shows) |
| 13a | `.disconnected`, a `.hard` `snapshot.startLatch` (on-demand starts of Work fail fast until the user acts; with the kill switch they are held instead, row 3b) | error-stopped `!` (open shackle) | "<e>. Auto-connect is paused for Work." | Sign In… / Connect, Details |
| 14 | `.disconnected` with `lastError` (*E2E-4 200012:* for a start made elsewhere (System Settings) that macOS refused for a profile without the kill switch, the hero follows that profile when nothing else is active or starting, so this row shows for it; beside another session Diagnostics lists "Work couldn't connect: …" instead and the hero stays) (per the input rule above; `pluginFailed` reads "LockPlus's tunnel process stopped unexpectedly"; *review b47da1c:* "No network available" (code 2) reads "Your Mac isn't connected to a network." / "Dein Mac ist mit keinem Netzwerk verbunden.") | error-stopped `!` (open shackle) | "<localized error>. Not protected." | Connect, Details |
| 15 | `.disconnected`/`.invalid` | unprotected | "Not protected" + last session summary | Connect |

- "Disconnect and Restore Internet" is the honest name for the action: a user stop is Apple's documented way out of the blocked state (DESIGN §10.1.1).
- Row 12a (draft 8.1) is the app's own work, not a tunnel status, so it never reads "Connecting…". While it lasts, and while the cause of an unexpected disconnect is still being read (a few seconds, no row), every Connect the store would ignore is disabled with the reason as its help text or tooltip: "LockPlus is preparing to connect Work.", "LockPlus is waiting for Home NAS to disconnect, then connects Work.", "LockPlus is waiting for Work's tunnel process to restart.", "LockPlus is checking why Work stopped.", *E2E-4 200011:* "LockPlus connects Work when a network is available." (de: "LockPlus verbindet Work, sobald ein Netzwerk verfügbar ist.") while a start waits for a network, and on Work's own Connect "Work connects when a network is available." while macOS's restart is awaited. Cancel (also Disconnect and Pause) ends a start that hasn't been issued yet, and stops a session macOS would connect when a network returns.
- Row 3 with the kill switch on: the connect is still pending, which S2 E14a measured as blocked, so the copy says so. The sheet stays answerable for up to 10 minutes (CRV1: 5); there is no 50 s limit any more.
- Rows 13 ("Blocked" while disconnected, **Restore Internet**) and 13b ("Sign in to connect" after a failed first connect) are **removed** (draft 7): S2 measured a failed start and a provider cancel as open on macOS, and LockPlus now holds a failing kill-switch connect (row 3a) and asks for sign-in inside the connect (row 3) instead.
- Pause offers 5 min / 15 min / 1 hour, then a confirmation sheet: "LockPlus will disconnect and allow unprotected internet for 15 minutes." While paused: an open shackle with a pause badge, "Paused — 12 min left", and "Resume Now" in the hero, the menu and the Dock menu. Pause is not offered in rows 7 and 3a: there is no network problem to sign in to.
- The menu bar label hides while blocked (rates would be 0 and misleading); the glyph carries the state.
- VoiceOver announces once, when the state is entered, with high priority: row 10 "Blocked. Traffic is held until Work reconnects."; row 7 "Blocked. Work stopped because <short error>. Disconnect to restore internet."; row 3 "Sign-in required to connect Work."; row 3a "Blocked. Work couldn't connect because <short error>. Disconnect to restore internet."

### 6.7 Auto-Connect (on-demand Wi-Fi rules)

This is a main-window section, not a settings tab: it is a protection feature, and it needs room.

```
 Auto-Connect                                                    [●  ] On
 ─────────────────────────────────────────────────────────────────────────
 Profile             [ Work                       ▾ ]
                     Profiles that need a one-time code can't auto-connect.

 Connect on          ☑ Wi-Fi networks you don't trust
                     ☐ Ethernet

 Trusted networks    ┌───────────────────────────────────────────┐
 (never connect)     │  Home-5G                                  │
                     │  Office-Guest                             │
                     └───────────────────────────────────────────┘
                     [+] [−]   [Add Current Network]

 ⓘ On networks with a sign-in page, LockPlus waits until you have signed in.
   If LockPlus isn't running, protection starts on the next network change.
```

- **The Location permission flow is just-in-time.** Location is requested **only** when the user clicks "Add Current Network" (A-OD-1: `ssidMatch` should work without it). The states:

  | Location state | UI |
  |---|---|
  | not determined | The button reads "Add Current Network…"; clicking shows a pre-prompt sheet: "macOS only reveals the Wi-Fi name to apps with Location access. LockPlus uses it once to fill in the name and never stores your location." [Not Now] [Continue], then the system prompt |
  | authorized | The button adds the SSID directly; a caption shows "Currently on: Home-5G" |
  | denied | The button is replaced by the caption "Type the network name, or allow Location in System Settings" [Open Privacy Settings] |
  | restricted (MDM) | Caption: "Location is managed by your organization. Type network names manually." |

- **If spike S1 fails** (the fallback: the app-assisted mode needs Location and a running app), the toggle row gets a subtitle, "Requires LockPlus to be running", and Location becomes mandatory, with the same pre-prompt.
- *Draft 8:* the 15 s re-check after a portal sign-in and the "Auto-connect couldn't verify this network" state with "Connect now" (DESIGN §10.4) are **not built yet** (DESIGN §18); the ⓘ line's "protection starts on the next network change" is what happens today, LockPlus running or not.
- **Status line** at the top when relevant: "Auto-connect is paused until you join another network" (after a manual disconnect), or "Auto-connect resumes when you disconnect Home NAS" (another profile started and its start paused auto-connect; not shown for a session started in System Settings), or "Auto-connect is off; LockPlus couldn't turn it back on." (a restore failed and is retried). *Draft 6 (DESIGN §10.4):* the pause is remembered across a relaunch and ends on the next network change (another Wi-Fi network, or Ethernet plugged in or out).
- **Per-SSID → profile mapping** is cut (DESIGN §10.4). Migration reports it under "Not migrated".

### 6.8 Import and export

**Import sources:** drop anywhere on the window or onto the Dock icon, `+` menu, File menu, `⌘O`, clipboard (`⇧⌘V`, for config text or a QR image), and a QR image file. Camera import is not planned (Q6).

**Clipboard privacy (F-8; the 15.4 APIs are baseline on 26):** "Import from Clipboard" is enabled only when `NSPasteboard.detectPatterns`/`detectMetadata` (which show no alert) say the clipboard may hold text or an image; LockPlus reads the clipboard only on ⇧⌘V or the menu command, which may show macOS's paste-permission alert, never in the background. If the user set LockPlus to "Deny" (`accessBehavior == .alwaysDeny`), the item reads "Clipboard access is off for LockPlus" and opens System Settings. (Draft 6: the 15.1–15.3 note is gone with the 26.0 floor.)

**Import preview sheet** (single file):

```
╭──────────────────────────────────────────────────────────╮
│  Import "office.ovpn"                                    │
│                                                          │
│  Name      [ Office                       ]              │
│  Type      OpenVPN · UDP · vpn.example.com:1194          │
│                                                          │
│  ✓ 41 directives supported                               │
│  ⚠ 2 ignored    (show)   script-security, up             │
│  ✕ 0 unsupported                                         │
│                                                          │
│  Protection   ☑ Kill switch   ☐ Allow local network      │
│                                                          │
│                              [Cancel]  [Import ↩]        │
╰──────────────────────────────────────────────────────────╯
```

- If anything is **unsupported** (TAP, plugins, web auth, and since DESIGN draft 7 an outdated 64-bit cipher such as BF-CBC, DES or 3DES), Import is disabled and the row explains why in plain language. "Show" expands a list with line numbers. AES-CBC profiles import normally with a "Legacy encryption" warning.
- **Server on another network (DESIGN draft 7.3, §9.3):** if the server's address is reached through an interface other than the Mac's main one (a local VM, Docker, a second network port), the sheet shows a ⚠ row, "This server is reached through bridge100. LockPlus's tunnel can only use your main network (Wi-Fi or Ethernet), so it may not connect." This is a warning, and Import stays enabled. The Go-app migration report carries the same line (DESIGN §13.1).
- **Proxy by name (draft 8, DESIGN §9.3):** if the profile's `http-proxy` is a name that can't be looked up at import, the sheet shows a ⚠ security row: "The proxy is given by name, and that name couldn't be looked up. LockPlus looks it up before each connect; with the kill switch on, it can't connect while the lookup fails. Use the proxy's IP address to avoid this." Import stays enabled.
- The Protection defaults come from Settings › Profiles: kill switch on for full tunnels, **Allow local network off** (F-1).
- ~~**Zip import waits (draft 6)**~~ *Draft 7.1: zip import is built (DESIGN D91-2).* A `.zip` is read in memory and opens the batch sheet below; an archive-level problem is one alert naming the archive (for example "Work.zip uses the ZIP64 format, which isn't supported. Unpack it and import the files.").
- **Zip or multiple files:** a list with checkboxes, a per-item result glyph (✓/⚠/✕) and a summary "6 imported, 1 skipped". Caps (500 entries, 10 MB per entry) appear as errors, not as silent truncation. *Draft 7.1:* entry-level errors are critical strips above the list ("“x.ovpn” is a link, not a file, and was skipped."); more than 500 profiles or 100 MB refuses the whole archive with an alert.
- **Export** (`⇧⌘E`): Touch ID, then `NSSavePanel` with the suggested name `Work.conf`. Export All (Settings › General and File menu): Touch ID, then a zip (*draft 7.1: built; save panel suggests "LockPlus Profiles.zip", entries 0600, names made unique as "Work 2.conf"*). The result is a non-modal banner, "Exported 6 profiles to Downloads" [Show in Finder]. *Draft 6:* a failed write is reported as a failure (never "Exported"), an existing file is never silently overwritten, and a name starting with "." is sanitized so it can't become a hidden file.

**Locked profiles (draft 6, DESIGN §6.8).** When the profile files exist but the key that opens them doesn't (a restore or migration to another Mac), the library shows, in place of the list:

```
 ╭──────────────────────────────────────────────────────────╮
 │  🔒  Profiles from another Mac are locked                 │
 │  These profiles were sealed on another Mac and can't be   │
 │  opened here. Import the original profile files again,    │
 │  or remove the locked profiles.                           │
 │  Locked profiles: Work, Home NAS and Acme                 │
 │                [Remove Locked Profiles…]  [Re-import…]    │
 ╰──────────────────────────────────────────────────────────╯
```

- The names come from unverified metadata and are only displayed.
- **Re-import…** asks "Start over?" ("The locked profiles are moved to a folder next to your profiles, and LockPlus creates a new key. Then choose the original profile files to import.") and then opens the file picker. Nothing is deleted: the locked files are moved aside.
- **Remove Locked Profiles…** asks "Remove 3 locked profiles?" first.
- **Import from Old LockPlus…** appears only when the old (Go) LockPlus left data to migrate. It asks the same "Start over?" (message: "…Then choose the profiles to import from the old LockPlus.") and then opens onboarding's "Bring your profiles" step with the migration list (DESIGN §6.8).

### 6.9 Editor

An editor window (`WindowGroup("Edit Profile", for: Profile.ID.self)`), so it can sit next to the detail or documentation. New profiles use the same view.

```
┌────────────────────────────────────────────────────────────────────────┐
│ ● ● ●     Work — WireGuard                         [Revert] [Save ⌘S] │
├──────────────────────────────────────────────────┬─────────────────────┤
│  1 │ [Interface]                                 │ Issues (1)          │
│  2 │ PrivateKey = ••••••••••••••••••• [Show]     │ ✕ Line 9: Endpoint  │
│  3 │ Address = 10.8.0.2/32                       │   needs host:port   │
│  4 │ DNS = 10.8.0.1                              │                     │
│  5 │ PostUp = iptables …        ← dimmed, ignored│ Reference           │
│  6 │                                             │ AllowedIPs          │
│  7 │ [Peer]                                      │   Routes sent into  │
│  8 │ PublicKey = mJ3…=                           │   the tunnel. Use   │
│  9 │ Endpoint = vpn.example.de  ~~~~~~           │   0.0.0.0/0 for …   │
│ 10 │ AllowedIPs = 0.0.0.0/0, ::/0                │                     │
│ ✕  │                                             │                     │
└──────────────────────────────────────────────────┴─────────────────────┘
```

- An `NSTextView` (TextKit 2) in `NSViewRepresentable` (DESIGN §11.4), SF Mono 12 pt, line numbers in a gutter drawn from the TextKit 2 layout fragments (not an `NSRulerView`/`NSLayoutManager` sample, which would silently switch the view to TextKit 1), issue markers (✕/⚠) in the gutter. Highlighting uses rendering attributes, so it never touches the undo stack.
- **The inspector** (`.inspector` with `InspectorCommands`; the shortcut is the system default, checked in prototype 7 rather than forcing ⌥⌘I) shows the issue list (click to jump) and **Reference**: the documentation for the key under the caret. This replaces CodeMirror autocomplete with something more useful. Completion of key names stays as `NSTextView` completion (`⌥⎋`); automatic text completion is off.
- **The private key is masked** with a "Show" button until revealed. The editor is already behind Touch ID; masking is protection against shoulder surfing. The bullets are drawn by a custom text layout fragment while the real key stays in the buffer for the parser (decided in prototype 7; fallback: a placeholder line that Save re-inserts). **As built (draft 6, DESIGN §11.4):** masking fails closed (a key line typed or pasted above stays masked while the analysis catches up); while masked, VoiceOver reads bullets, copy and ⌘A ⌘C over a key are refused with an explanation instead of a beep, and Services, Share, Look Up and the find bar can't reach the key text.
- **Capture and clipboard hygiene (F-7):** the editor window sets `sharingType = .none` (window-server capture such as screenshots and most screen recording skips it; mirroring, cameras and an admin are out of scope, and the help says so). Copying a key or password marks the clipboard item concealed and transient (clipboard managers skip it) and clears it after 60 s. The window is **not restored** after relaunch, has **no autosave**, and its undo history is cleared on close and after Save. Writing Tools, inline prediction, spell checking and all substitutions are off in the buffer.
- **Syntax colors.** Dark ("Navy" theme on `lp.sunken`): section headers `lp.sage` bold, keys `lp.label`, values `#5ab4c9`, numbers `#e8c547`, comments mint **65%** italic (`lp.syntaxComment`; draft 6: 55% was 4.16:1 on `lp.sunken`), ignored keys mint 55% with a tooltip, forbidden keys with a red wavy underline. Light: headers `#2d7a68` bold (not red; red means error), keys `#953800`, values `#0a3069`, numbers `#0550ae`, comments `#6e7781`.
- **Save** is disabled while errors exist; the tooltip says why. Closing with unsaved edits uses the standard document-style alert; its Save closes the window, and quitting with unsaved editors asks first (draft 6). **Revert** asks "Revert to the saved version?" first (draft 6). Saving a connected profile: "Work is connected. Save and reconnect?" [Cancel] [Save Only] [Save and Reconnect].

### 6.10 Activity (statistics and history merged)

```
 Activity                                     [All profiles ▾] [Last 7 days ▾] [Clear…]
 ───────────────────────────────────────────────────────────────────────────────────
 ╭ Now: Work ────────────────────────────────────────────────────────────────────╮
 │  ↓ 1.2 MB/s  ↑ 30 KB/s     5 min                                             │
 │  ▁▂▃▅▇▆▄▃▂▂▃▅▆▇▅▃▂▁▁▂▃▄▅▆▅▄▃▂▁▁▂▃▅▆▇▅▃▂▁▁▂▃▄▅▆▅▄▃▂▁   ── rx   - - tx         │
 ╰──────────────────────────────────────────────────────────────────────────────╯
  This week: 14 sessions · 21 h 40 m · ↓ 18.2 GB ↑ 1.1 GB

  Profile        Started             Duration    ↓ Received   ↑ Sent    Ended
  Work           Today 08:31         active      1.4 GB       92 MB     —
  Work           Yesterday 21:22     1 h 29 m    31.8 MB      1.2 MB    You
  Acme   Yesterday 14:02     57 m        1.3 MB       2.2 MB    ⚠ Network
```

- The live chart is Swift Charts `AreaPlot` (rx) and `LinePlot` with a dash (tx), the vectorized plots: 5 minutes at 1 Hz = 300 points, **no downsampling**, fixed `chartXScale`/`chartYScale` domains (the Y ceiling changes only when the peak moves by > 25 %), animations off. The y axis uses a byte-rate format. The chart view reads only its samples, so rate ticks don't re-render the table.
- The table is a SwiftUI `Table` with sortable columns, a context menu (Copy Row, Show Logs Around This Time), and the end reason as glyph plus word.
- The old card pills are cut. Totals are one sentence.

### 6.11 Diagnostics

A health report: every check is a row with a shape-coded result, so a non-expert can read it and an expert can expand it.

```
 Diagnostics                                                       [Run All ⌘R]
 ─────────────────────────────────────────────────────────────────────────────
  ✓  Tunnel                 Handshake 21 s ago · latency 12 ms         [▸]
  ✓  DNS                    Tunnel resolver 10.8.0.1 owns all domains  [▸]
  ?  IPv6                   Not tested while disconnected              [▸]
  ⚠  Other VPNs             utun7 (another app) has a default route    [▸]
  ✓  Old LockPlus helper    Removed                                    [▸]
 ─────────────────────────────────────────────────────────────────────────────
  Routes                                               [Reload]  🔍 filter
  Destination        Gateway        Interface     Via
  0.0.0.0/0          10.8.0.1       utun4         🔒 Tunnel
  192.168.1.0/24     link#6         en0           Local
  ─────────────────────────────────────────────────────────────────────────────
  Problems (0)       Background failures appear here instead of alerts.
```

- Glyphs: ✓ `checkmark.circle.fill` (sage), ⚠ `exclamationmark.triangle.fill` (attention), ✕ `xmark.octagon.fill` (critical), ? `questionmark.circle` (secondary). `?` is **never** rendered green.
- Expanding a row (`DisclosureGroup`) shows raw detail (the `scutil --dns` excerpt, resolver list tagged tunnel/non-tunnel) with Copy.
- Latency runs only against the profile's own endpoint (DESIGN §11.5).

### 6.12 Logs

- Toolbar: level segmented control (All / Info / Warnings / Errors), source picker (App / Tunnel / Both), search field, Copy, Save…, Clear.
- The list is a lazy `List` of monospaced rows: time, level glyph (shape plus color), message. "Follow" (auto-scroll) is a toolbar toggle; it switches off when the user scrolls up, with a "Jump to Latest" button.
- Secrets are already redacted at the source; the UI adds a footer, "Logs never contain keys or passwords", which tells users it is safe to share them.
- **Tunnel logs (draft 6, DESIGN §14.2):** the tunnel's lines come from the system log, read as the logged-in user. When the account can't read it (non-administrator accounts), a footer says so and that an administrator's diagnostics export includes them; the app's own lines are always there.

### 6.13 Settings

A `Settings` scene with a `TabView`, `Form(.grouped)`, about 520 pt wide.

| Tab | Contents |
|---|---|
| General | Launch at login (`SMAppService.mainApp`: on / off, or "Allowed in System Settings › Login Items" with a button when approval is pending; re-read every time the pane appears); Open window at login; Language (System / English / Deutsch, applies after relaunch; draft 6: ko/ja dropped); Appearance (System (default) / Light / Dark, applies at once; owner request 2026-11-10); Notifications (Only problems (default) / Connect and disconnect / Off), with "Notifications are off for LockPlus in System Settings" and a button when macOS authorization was denied |
| Menu Bar | Show in menu bar (toggle; the way back after a Cmd-drag removal; draft 6: turning it **off** asks "Hide the menu bar icon?" first, because the icon may be the only way back, then really hides it); Show rates (Off / Download / Both); Icon style (Monochrome / Color); preview of both states, drawn with the status item's own images (so the lock is centred as in the menu bar, draft 8.3); "The menu bar icon may be hidden" helper (§6.1) |
| Profiles | Defaults for new profiles: kill switch for full tunnels (on), allow local network (**off**); Export All… |
| Advanced | Log level (the app's); Receive release candidates; Export diagnostics… (with the "What's inside" preview); **Import from Old LockPlus…** (draft 8.3, E2E-5 F4: a sheet that looks for LockPlus 1.x's data every time and shows the migration offer, "Finish importing…" for an interrupted one, or "There's nothing to import"; footer "Copies profiles, settings and history from LockPlus 1.x. Profiles already imported are skipped."); Reinstall Tunnel Component…; Uninstall LockPlus… (DESIGN §4.4; the confirmation says up front that "macOS will ask for an administrator password to remove the tunnel component", because on 27 removing it raises a system password dialog). **Draft 6, as built:** the confirmation's default button is **Cancel**, not the destructive one; the checkbox "Also delete your profiles and history" (off by default) also decides whether the saved passwords and the key that opens the profiles are deleted (without it they stay, so a reinstall finds the profiles). If the administrator dialog is cancelled, nothing local is deleted and LockPlus stays: "The tunnel component couldn't be removed… Your profiles and LockPlus itself were kept. Try again to finish uninstalling." Anything left behind is named in a final sheet. ~~*Copy fix pending:* the confirmation text still says the saved passwords are always removed (DESIGN §17.1).~~ *(Fixed in DESIGN draft 8.)* **Draft 8 (E2E-1):** after a successful uninstall LockPlus closes the open Settings sheet and quits (it used to stay running); if it can't move itself to the Trash (for example another administrator installed it), it says "The tunnel component was removed, but LockPlus couldn't move itself to the Trash. Drag LockPlus from Applications to the Trash to finish." and then quits. Debug submenu only in dev builds |
| About | Icon, version, "Check for Updates…" (Sparkle), Release Notes, Report an Issue, License, Support LockPlus (Ko-fi link; no banner nagging elsewhere) |

The Go app's Theme picker became Settings › General › Appearance (System / Light / Dark; default System, owner request 2026-11-10), and a Go `theme` carries over to it (DESIGN §13.1 step 6).

**Notification permission:** requested once, at the end of onboarding, after one sentence ("LockPlus tells you when protection stops unexpectedly"). LockPlus never asks again on its own; choosing a setting other than Off while permission is undecided asks then. Notifications appear only while no LockPlus window is key and name the profile only.

### 6.14 Onboarding

A sheet over the main window, 600×480 by default and allowed to grow to 680 pt wide for German (draft 6), five steps with a page indicator. Each step has one primary button, and the steps are skipped automatically when already satisfied (L-EXT-2: activation on every launch is silent if already approved).

```
 1 Welcome                       2 Install tunnel component
╭─────────────────────────────╮ ╭─────────────────────────────────────╮
│          ╭────╮             │ │  🧩  Install the tunnel component   │
│          │ 🔓 │  → 🔒       │ │                                     │
│          ╰────╯             │ │  LockPlus runs its VPN engine as a  │
│   Welcome to LockPlus       │ │  macOS system extension. macOS will │
│  WireGuard and OpenVPN,     │ │  ask you to allow it once.          │
│  native on your Mac.        │ │                                     │
│                             │ │  ⏳ Waiting for approval…            │
│                             │ │  System Settings › General ›        │
│                             │ │  Login Items & Extensions           │
│            [Get Started]    │ │  [Open System Settings]  [Install]  │
╰─────────────────────────────╯ ╰─────────────────────────────────────╯

 3 Allow VPN configuration        4 Bring your profiles
╭─────────────────────────────╮ ╭─────────────────────────────────────╮
│  🔐  Allow VPN configuration │ │  Found LockPlus 1.x                 │
│                             │ │  6 profiles · 2 saved logins         │
│  Next, macOS asks whether   │ │  ☑ Work  ☑ Home NAS  ☑ Acme  …       │
│  LockPlus may add VPN       │ │  LockPlus copies them. The old       │
│  configurations. Choose     │ │  LockPlus's files stay as they are.  │
│  "Allow".                   │ │  [Import 6 Profiles]                 │
│  (illustration of the       │ │  ─────────── or ───────────          │
│   system alert)             │ │  [Choose Files…] [QR Image…]         │
│              [Continue]     │ │  Found 2 in /etc/wireguard [Add]     │
╰─────────────────────────────╯ ╰─────────────────────────────────────╯

 5 Done: "LockPlus lives in your menu bar" with a callout arrow at the status item's real position, then the one-time
   notification permission request (§6.13).
```

- **Step 2 states:** idle, then requesting, then needs approval (deep link, polling `ExtensionStore`; on macOS 27 the switch may not stay on the first time, so this state keeps a secondary **"Show the Switch Again"** button that reopens Login Items & Extensions, with the line "If the switch turned itself off, turn it on again"; P1 skeleton, DESIGN §4.2), reboot required (".willCompleteAfterReboot": "Restart your Mac to finish", [Restart Later]), or failed (localized error, "Try Again", "Get Help"). There is only one dialog and no retry loops (L-EXT-1).
- **Step 3** explains the system alert **before** it can appear, so the user isn't surprised by a password-like system prompt. With no profile yet, step 3 saves nothing (there is no configuration to save): it says macOS asks at the first import in step 4, and the step-4 import buttons carry the same hint. Once a LockPlus VPN configuration exists in the system (even with every profile deleted) macOS has asked already: no hint, and step 3 says so. With profiles (re-onboarding) step 3 triggers `saveToPreferences` for the first one. If the user denies it: "LockPlus can't connect without this. [Try Again]" (the next attempt shows the system prompt again).
- **Step 4, migration (DESIGN §13):** the migration report afterwards lists Imported / Needs attention (for example "OVPN profile uses `up` script: ignored") / Not migrated (the per-SSID map, global DNS protection). A final note: "When you're happy, remove the old app. LockPlus 1.x's last update cleans up its helper."
  - *Draft 8.3 (E2E-5 F4–F7), as built:* the offer counts "N profiles · N saved logins" (a 1.x item may hold only a username) and its opt-in reads "Import saved OpenVPN logins" / "macOS asks for your login keychain password, usually your Mac login password, once for each: N prompts. You can also skip this and enter them on first connect." Under the offer: "You can also import from the old LockPlus later, in Settings › Advanced." An interrupted earlier import shows "Finish importing from LockPlus 1.x" ("An earlier import didn't finish. LockPlus adds what's missing: the remaining profiles, settings, Wi-Fi rules, history and saved logins.") with [Finish Import] when no profile is left to copy (S-7.18).
  - The report: **Imported**; **Needs attention** "<profile>: <line, directive: reason>" (and "and N more in the profile's import report"); **Not migrated**; **Good to know** (ⓘ): "<profile>: nobind, verb ignored; LockPlus doesn't need these lines.", "<profile>: the saved username was imported; the old LockPlus kept no password, so LockPlus asks for it on connect.", "DNS now always goes through the tunnel; the old app's DNS protection setting isn't needed.", "Per-network profile choices aren't supported yet. The old LockPlus used: CafeNet → ovpn-tcp. Auto-Connect uses one profile for every untrusted network.", Go 1.1's login item ("System Settings › General › Login Items may still list the old LockPlus. Turn it off there; LockPlus has its own setting."); then ☐ "Open LockPlus at login" ("The old LockPlus opened at login.") when 1.x opened at login. The final note replaces the one above: with the old helper installed "The old LockPlus's helper is still installed. If the old LockPlus offers its update to 1.2, that update removes the helper; otherwise choose “Remove Old Helper…” in the LockPlus window.", without it "When you're happy, you can delete the old LockPlus if it's still in Applications." (S-7.15)
- **Step 4, the WireGuard App Store tip** (export a zip first) stays as a disclosure.

### 6.15 Errors and empty states

| Situation | Surface | Copy (en) |
|---|---|---|
| No profiles | `ContentUnavailableView`, padlock 64 pt | "No Profiles" / "Drop a .conf, .ovpn or .zip file here, or import one." [Import Profile…] [New WireGuard Profile] |
| Profiles exist, none selected | `ContentUnavailableView`, padlock 64 pt, never the empty-library copy | "Select a profile" / "Choose a profile in the sidebar to see its details." |
| Search finds nothing | `ContentUnavailableView.search` | system default |
| No history | Activity empty | "No Sessions Yet" / "Connections appear here after you disconnect." |
| Extension not approved | persistent banner above detail | "The tunnel component isn't allowed yet." [Open System Settings] [Show the Switch Again] |
| Tunnel process crashed while connected | hero row 4a, then row 14 | "Reconnecting to the tunnel process…", then "LockPlus's tunnel process stopped unexpectedly. Not protected." [Connect] [Details…] |
| Profile uses a 64-bit cipher | import sheet, Not supported | "office.ovpn uses BF-CBC, an outdated cipher LockPlus doesn't support. Ask the server's operator to enable AES-GCM." |
| Server needs an outdated cipher (no `cipher` in the profile, old server) | critical strip in hero | "This server needs an outdated cipher LockPlus doesn't support." [Details…] |
| A pushed option was rejected by the profile's `pull-filter` | critical strip in hero | "The server sent a setting this profile refuses (redirect-gateway). Edit the profile or ask the server's operator." [Details…] |
| Server only reachable via a non-primary network (`.endpointInterfaceUnusable`, DESIGN §9.3) | critical strip in hero + menu header line | "This server is only reachable via bridge100, a network LockPlus's tunnel can't use. Connect the server to your main network (Wi-Fi or Ethernet)." [Details…] |
| VPN configuration denied | banner | "macOS hasn't allowed LockPlus to add VPN configurations." [Allow…] |
| Connect failed | critical strip in hero + menu header line | localized `LPErrorCode` message, [Details…] with code, time, extension detail |
| Another VPN app active | attention strip | "Another VPN (Tailscale) is active. Connecting Work will disconnect it." |
| DNS unverified after connect | attention line in hero | "Couldn't verify DNS. [Run Diagnostics]" |
| Import error | sheet alert | "office.ovpn can't be imported: it needs a TAP adapter, which macOS doesn't support." |
| Background failure | Diagnostics › Problems + sidebar badge on Diagnostics | never a modal |
| Menu bar icon may be hidden | Settings › Menu Bar + window opens at launch (§6.1 policy) | "The menu bar icon may be hidden. Turn on LockPlus in System Settings › Menu Bar, or use Show in Menu Bar." |
| Tunnel component turned off by the user | persistent banner | "LockPlus's network extension is turned off in System Settings." [Open System Settings] |
| Tunnel component removed during an update (Finder replace) | banner + onboarding step 2 | "The tunnel component was removed during the update. Approve it again to reconnect." |
| Clipboard access denied | disabled menu item | "Clipboard access is off for LockPlus." [Open System Settings] |
| Switching profiles | hero + header line | "Switching to Home NAS — not protected for a moment." |
| A second copy is launched (draft 6) | alert, then the second copy quits | "LockPlus is already running" (draft 8.3: a copy started at login, by 1.0.x's LaunchAgent or as a login item, quits silently) |
| Old (Go) helper installed and idle (draft 8.3, E2E-5 F1; DESIGN §4.5, §13.3a) | persistent banner (S-9.16) | "The old LockPlus helper is still installed. LockPlus can remove it; macOS asks for an administrator password." [Remove Old Helper…] → "Removing the old LockPlus helper…" (S-9.17) → "The old LockPlus helper was removed." [OK] (S-9.18; with state left: "The old LockPlus helper was removed, but it left network settings behind. If websites don't load, set DNS back to Automatic in System Settings › Network, then restart your Mac."); cancelled: "The old helper wasn't removed because the administrator password was cancelled. It is still installed." [OK] [Try Again] (S-9.20); refused: "The old LockPlus is still connected or its kill switch is on, so its helper wasn't removed. Disconnect in the old LockPlus first, or restart your Mac, then try again." (S-9.19); other files: "The installed helper doesn't match the old LockPlus helper, so LockPlus didn't change anything." Review (2026-11-09): while the old app runs the button is hidden and the banner reads "The old LockPlus helper is still installed. Quit the old LockPlus first; then LockPlus can remove its helper." (it would reinstall the helper); an unreachable helper with an un-replayed DNS journal: "The old LockPlus helper isn't running, and its DNS settings are still active. Open the old LockPlus once so its helper restores DNS, or set DNS back to Automatic in System Settings › Network. Then remove the helper." |
| Connect while the old helper protects the Mac (draft 8.3, E2E-5 F8) | critical strip above the detail, never an alert sheet (S-10.06) | "The old LockPlus is still protecting this Mac. Disconnect in the old LockPlus and turn off its kill switch first." [Open the old LockPlus] (only while it is installed; ends the strip) [OK]. Crashed helper (attention): "The old LockPlus may have left its firewall on. If connecting fails, restart your Mac." [Cancel] [Connect Anyway] |
| An import from LockPlus 1.x didn't finish (draft 8.3, E2E-5 F4) | info banner after onboarding (S-9.21) | "Importing from LockPlus 1.x didn't finish." [Not Now] [Finish Import…] (only after a migration that really was interrupted; finishing overwrites no setting) |
| 1.0.x's LaunchAgent was removed (draft 8.3, E2E-5 F5) | info banner (S-9.22) | "The old LockPlus opened at login. Open LockPlus at login instead?" [Not Now] [Open at Login] |
| Profiles from another Mac (draft 6) | library placeholder (§6.8) | "Profiles from another Mac are locked" [Remove Locked Profiles…] [Re-import…] |
| A `.zip` can't be imported (draft 7.1) | import alert | "<archive> isn't a valid zip archive or is damaged." / "… uses the ZIP64 format …" / "… is encrypted …" / "… has more than 500 profiles …" / "… contains no .ovpn or .conf files." (draft 6's "can't be imported yet" is gone) |
| Tunnel component couldn't be removed during Uninstall (draft 6) | Settings › Advanced | "The tunnel component couldn't be removed, for example because the administrator password dialog was cancelled. Your profiles and LockPlus itself were kept. Try again to finish uninstalling." |
| Protection settings being restored (draft 8, DESIGN §3.4) | attention strip in hero | "Restoring this profile's protection settings in macOS. The kill switch isn't active until they're verified, and LockPlus won't connect before that." |
| Kill switch couldn't be applied (draft 8, `.killSwitchNotApplied`) | critical strip in hero + menu header line | "Couldn't apply the kill switch. LockPlus won't connect unprotected." (de: "Der Kill Switch konnte nicht angewendet werden. LockPlus verbindet sich nicht ungeschützt.") [Details…] |
| Session came back after a tunnel-process crash (draft 8, PF 53) | info strip in hero; notification ("Connect and disconnect" setting only) | "Reconnected after a tunnel process restart." / notification "Reconnected to Work after a tunnel process restart." |
| LockPlus couldn't move itself to the Trash after Uninstall (draft 8) | alert, then LockPlus quits | "The tunnel component was removed, but LockPlus couldn't move itself to the Trash. Drag LockPlus from Applications to the Trash to finish." |
| Pause with the background item not allowed (draft 6) | pause sheet note | "LockPlus's background item isn't allowed yet, so if you quit LockPlus, protection resumes the next time it opens instead of on time. Allow LockPlus in System Settings › General › Login Items." |

---

## 7. Signature moments

### 7.1 "The shackle closes"

On connect, the hero padlock's shackle closes: `.contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))` between `lockplus.lock.open` and `lockplus.lock.closed` (Magic Replace; the two symbols share one layer structure with the shackle as its own layer). On 26 and 27, the same call uses Draw Off/On for the layers annotated for Draw in the SF Symbols 7 app (Regular, Ultralight and Black, at least two guide points per path). `.symbolEffect(.breathe)` runs while connecting. Draw On (`.transition(.symbolEffect(.drawOn))`) is used only where the glyph is *inserted* (the onboarding hero), because Draw On animates appearance, not the open → closed change. On `.connected`, a single soft sage ring expands once from the glyph (about 450 ms, `ease-out`). On disconnect, the shackle lifts, with no ring. With Reduce Motion (read explicitly from `accessibilityReduceMotion`): `.contentTransition(.opacity)` for 150 ms, and no ring or breathe. The menu bar item can't run symbol effects (`NSStatusBarButton` has none): it shows a 3-frame template sequence while connecting, static with Reduce Motion (S15: works). **The custom symbols are required for all of this (S15, 27):** between stock `lock.open` and `lock.fill` (or `lock`) Magic Replace falls back to the down-up bounce, with no shackle movement, and Draw On on stock `lock.fill` is only a fade. The shackle morph needs our two symbols with the shared layer structure, and Draw needs our annotations.

### 7.2 The glyph language

One custom symbol family, `lockplus.lock`, with variants. It is used identically in the menu bar, sidebar, hero, menu items, notifications and the future Control Center control.

| State | Silhouette | Badge | Color (when color is allowed) |
|---|---|---|---|
| Unprotected | open shackle, outline | — | secondary label |
| Connecting / reasserting | shackle closing / closed outline | `…` / `↻` | transition yellow |
| Protected | closed shackle, filled body | — | sage |
| Blocked | closed, filled | `⊘` | attention orange |
| Needs attention (auth, DNS unverified) | closed outline | `!` | attention orange |
| Paused | open shackle | `⏸` | attention orange |
| Error, stopped | open shackle | `!` | critical red |

**Blocked** covers every blocked row of §6.6: reconnecting (row 10), held after Connected (row 7) and held before Connected (row 3a, status `.connecting`: never the connecting glyph; draft 7: row 13, the OS-blocked `.disconnected` case, is gone because S2 measured it open). The test is that all seven are distinguishable as 16 px black-on-white template images; a snapshot unit test enforces it (DESIGN §15.1). S15's stand-ins (stock SF Symbols) failed it partly: the silhouettes separate well, but the clock and xmark badges blur into similar dots at 16 px, so the custom badges must be bolder and differ in outline, not just in interior detail (stock symbols also have no lock + pause or lock + ellipsis). The badge is always in the bottom-right quadrant, so the eye learns one place to look. The glyph view itself is `accessibilityHidden`: the state **word** next to it carries the meaning for VoiceOver.

**Shipping lock: V2 "Sturdy" with a + in the body (draft 8.3, owner picks in review S-12.02).** The owner kept the family and the badges but found the first lock too tall, too narrow and too thin; of four candidates (V1 Compact, V2 Sturdy, V3 Soft, V4 Shield) he picked V2: body 68 × 52 units with corner radius 17, heavy strokes (Regular: shackle 12, body 10), a short shackle almost as wide as the body, badges of radius 21. He then asked for a + ("the app is called LockPlus") and chose **p2** of three placements: a larger + in the body, where a keyhole would be. `gen_lock_symbols.py` writes it to the app's catalog (every state, Ultralight, Regular and Black); V1, V3, V4, p1 (smaller +) and p3 (+ in the shackle's loop) are retired and so are their test-bundle catalog and the `GlyphSymbolSource` hook.

Why the + is in the body and large: it is a mark of the product name, so it has to read in the states people see most (Protected and Blocked, the filled bodies, and the 40-44 pt hero and header). In a filled body it is a cut-out; in an outline body it is a small filled + in the window. It never touches the badge notch (the generator checks the clearance per weight); in badged outline states it moves up and left, or shrinks, to clear the notch. The + is part of the body layer, so Magic Replace still morphs only the shackle. The 15 pt menu bar centring (§6.1) is measured on the closed lock's body, which the + does not change.

Legibility at 15/13 pt @1x (checked on every state, mono and colour tile, with and without rates, on S-12.02): the + in the filled bodies holds (Protected, Blocked); in the badged outline bodies (Connecting, Reasserting, Needs attention) the window is small and the shifted + is a few pixels of mush at @1x (crisp at @2x), so the badge carries those states; the ellipsis dots still fuse into a bar at @1x. Neither changes a silhouette: the §2.4 grayscale test still passes.

### 7.3 The protected-state hero

A large **opaque** `lp.card` with a subtle tint matching the state (sage 12 % protected, orange 12 % blocked, none when off), the same on every OS; it is content, so it never uses Liquid Glass (HIG). Under Increase Contrast it gets a 1 pt `lp.stroke` border. It shows the glyph at 44 pt, the state word in `.title`, and one line of "through what". Everything else in the window is quieter, so the hero is unmistakably the answer to "am I safe?"

### 7.4 The live throughput sparkline

There are 60 samples (1 Hz) in the menu header and 300 in the hero. rx is a sage area, tx a teal dashed line. The baseline is fixed at 0 so idle looks idle. Drawing uses `Canvas` for the menu (cheap, no Charts layout pass inside an `NSMenu`; the canvas has its own accessibility label and value) and Swift Charts `AreaPlot`/`LinePlot` in the window. It updates only while visible (`menuWillOpen`/`menuDidClose`, `scenePhase`, `onAppear`/`onDisappear`) to save energy; with no visible consumer, stats polling stops.

### 7.5 Navy night

In dark mode the detail canvas, editor and logs sit on LockPlus navy with mint labels, while the system chrome is neutral glass. That one surface choice makes a screenshot recognizable as LockPlus without fighting the OS.

---

## 8. Interaction details

### 8.1 Keyboard shortcuts and menu commands

This table is now DESIGN §11.6's (draft 4): ⌘N is "New WireGuard Profile" (the Mac convention); import is ⌘O.

| Menu | Command | Shortcut |
|---|---|---|
| File | New WireGuard Profile | ⌘N |
| File | New OpenVPN Profile | ⌥⌘N |
| File | Import… | ⌘O |
| File | Import from Clipboard | ⇧⌘V |
| File | Import QR Code Image… | — |
| File | Export… / Export All… | ⇧⌘E / — |
| Edit | standard, plus Rename (↩ on a selected sidebar row) | |
| Profile | Connect / Disconnect | ⌘K |
| Profile | Pause Protection ▸ / Resume Protection | — / ⇧⌘K |
| Profile | Edit Config… | ⌘E |
| Profile | Duplicate | ⌘D |
| Profile | Delete… (always asks first; ⌘⌫ acts only while the sidebar has focus, so it never deletes a profile while editing text; draft 6) | ⌘⌫ |
| View | Profiles, Activity, Auto-Connect, Diagnostics, Logs | ⌘1 … ⌘5 |
| View | Show/Hide Sidebar · Show Inspector (editor) | ⌃⌘S · system default from `InspectorCommands` (verified in prototype 7) |
| View | Find | ⌘F |
| Diagnostics | Run All | ⌘R |
| Window | standard | |
| Help | LockPlus Help · Report an Issue · Show Logs | |

The Dock menu repeats: Connect/Disconnect <profile>, Pause/Resume, "Open LockPlus", plus the profile list, as standard items only (menu item views are not supported in the Dock menu). Global hotkeys are not part of v2.0 (Q5).

### 8.2 Accessibility

- **VoiceOver:**
  - status item label as in §6.1; the menu header is **not** an accessibility element; its switch is the standard "Connect/Disconnect <profile>" item and its facts are in the VoiceOver-only status text item (§6.2);
  - sidebar rows read "Work, protected, WireGuard";
  - hero rates are one combined element ("download 1.2 megabytes per second, upload 30 kilobytes per second") so they don't chatter;
  - charts provide an `AXChartDescriptor` (summary: "Download averaged 800 KB/s over 5 minutes, peak 10 MB/s");
  - state changes post `AccessibilityNotification.Announcement`, with `accessibilitySpeechAnnouncementPriority = .high` for Blocked and auth (wording in §6.6; UI tests assert them);
  - section titles (Connection, Protection, Credentials, Notes) carry `.accessibilityAddTraits(.isHeader)`, so VoiceOver's built-in Headings rotor works; a custom rotor exists only for the editor's Issues list (DESIGN §11.6).
- **Reduce Motion:** no shackle draw, ring or pulse; charts update without animated transitions.
- **Reduce Transparency:** system glass adapts by itself. Content surfaces are already opaque (`lp.card`); the only custom glass (`.lpSurface(.floatingControl)`) falls back to `lp.card` when `accessibilityReduceTransparency` is on.
- **Increase Contrast:** high-contrast asset variants (strokes to mint 65% / `rgba(0,60,50,0.7)` (draft 6; was 60%), label2 to 80%), and a 1 pt `lp.stroke` border around the hero and the menu header card. A unit test checks every §2.3 pair in light, dark and High Contrast (DESIGN §15.1).
- **Differentiate Without Color:** the glyph shapes already cover it. Additionally, sidebar subtitles always contain the state word, and chart tx is dashed.
- **Full Keyboard Access:** every control is reachable; the header-only toggle has a standard item equivalent.
- **Targets:** at least 24×24 pt; macOS regular control size is the default.

### 8.3 Localization (en, de)

- German runs 30–40% longer ("Verbindung wird hergestellt…", "Netzwerkverkehr blockiert"). No fixed widths on buttons; `Form` handles label columns. The menu header is 300 pt wide, with a state line that may wrap to two lines (`lineLimit(2)`; S15 showed even English truncating on one line next to the switch).
- **Draft 6 (DESIGN Conflicts bc):** v2.0 ships **English and German** only; Korean and Japanese are dropped and can return later with a full translation and a CJK layout pass. Every key has a German translation; screenshots are rendered in both (`-de` variants), which doubles as the German-length smoke test.
- **German register: du (owner, final; draft 7.1).** The whole catalog addresses the user with du.
- German-length rules from the UI review: no fixed 300 pt header or 150 pt column that clips German, no `lineLimit(1)` on rows that carry sentences, units through `Measurement`/`Duration` formatters (no hard-coded "s" or "KB/s"), and no sentence fragment reused after both ":" and "because".
- Don't use `.textCase(.uppercase)` captions (not the Tahoe style). Use sentence-case section headers.
- The menu bar label contains **numbers and unit letters only**, never words, so it has the same width in both languages. It uses a locale decimal separator; units stay K/M/G (universally read, and keeps the label fixed width).
- The hero line is "<state word>" plus "<profile> · <place> · <protocol>". Each piece is a separate string; no sentence assembly by concatenation.
- Pseudo-localization (`-NSDoubleLocalizedStrings YES`, plus `-AppleTextDirection YES` as a layout smoke test) runs in the preview catalog for every screen (§12).
- No `Text` + `Text` concatenation (deprecated in the macOS 26 SDK) and no non-localized interpolation into `LocalizedStringResource`; counts use the String Catalog's "Vary by Plural" (en/de: one/other) through inflected strings, which go through `String(AttributedString(localized:).characters)` (`String(localized:)` shows the raw markup).
- Error copy lives in `LocalizedStringResource` per `LPErrorCode` (DESIGN §11.6). The server's own text (challenge, AUTH_FAILED reason) is displayed in quotes and marked as coming from the server, cleaned as in §6.5 (draft 6: no longer verbatim).

---

## 9. SwiftUI building blocks per screen

| Screen | Views | Native components | AppKit needed |
|---|---|---|---|
| Status item | `MenuBarController` (DESIGN §11.3) | — | `NSStatusItem` (stock button, `.removalAllowed`, stable `autosaveName`), `NSMenu`, `NSMenuItem` (`subtitle`, `sectionHeader`, `preferredImageVisibility` on 27), template `NSImage` from the custom symbol sized by `SymbolConfiguration`, `attributedTitle` with `monospacedDigitSystemFont` and a fixed `length` |
| Menu header | `MenuHeaderView`, `SparklineCanvas`, `LockGlyph` | `Toggle(.switch)`, `Canvas`, opaque `lp.card` via `.lpSurface(.menuHeader)` (no `glassEffect`) | `NSHostingView` inside `NSMenuItem.view`, created once; **default** `sizingOptions` (`[]` zeroes `fittingSize`, S15); width fixed at 300, height = `fittingSize.height` re-applied after each update; re-rendered by `withObservationTracking` (confirmed on 27; a 1 Hz `.common`-mode `Timer` only as the fallback until S15 runs on 26); not an accessibility element, with the switch and facts duplicated as standard items (§6.2). `NSHostingMenu` is **not** used for the header (its items derive from `Button`s and can't host a live view) |
| Main window | `MainView` → `NavigationSplitView` | `List(.sidebar)` (no background modifier), `.navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)`, `.searchable(placement: .sidebar)`, `.toolbar`, `ContentUnavailableView`, `.dropDestination` (or `onDrop` for multiple types) | the hidden bridge `Window` for `openSettings`/`openWindow` from AppKit (DESIGN §11.1); `applicationShouldTerminateAfterLastWindowClosed → false` |
| Profile detail | `ProfileDetailView`, `ProtectionHero`, `PolicySection`, `CredentialsSection`, `ImportReportSection` | `Form(.grouped)`, `LabeledContent`, `Toggle`, `TextEditor` (notes), Swift Charts | — |
| Connect button | `ConnectButtonStyle` | custom `ButtonStyle` (sage fill + navy label in dark) | — |
| Auth | `AuthPromptView` | `SecureField`, `TextField`, `.sheet` | non-activating `NSPanel` host (`AuthPanelController`), opened only from a user gesture; `sharingType = .none` |
| Touch ID | `RevealGate` (DESIGN §1.3 A6) | — | `LAContext` (`.deviceOwnerAuthentication`), one evaluated context with a 60 s app-side expiry |
| Blocked / pause | part of `ProtectionHero`; `PauseConfirmSheet` | `Menu`, `.confirmationDialog` | — |
| Auto-Connect | `AutoConnectView`, `LocationPrePromptSheet` | `Form`, `Picker`, `List` with `onDelete`, `.sheet` | `CLLocationManager`, CoreWLAN (only for "Add Current Network") |
| Import | `ImportPreviewSheet`, `ZipImportSheet` | `.fileImporter`, `.sheet`, `List` with `Toggle` rows | `NSPasteboard` (`detectPatterns`/`accessBehavior`), Vision `VNDetectBarcodesRequest` for QR; parsing via `@concurrent` helpers |
| Export | — | `.fileExporter` | `NSSavePanel` if `O_NOFOLLOW`/0600 can't be honored through `.fileExporter` (DESIGN NR §3) |
| Editor | `EditorWindow`, `ConfigTextView`, `IssuesInspector` | `WindowGroup(for:)` with restoration disabled, `.inspector` + `InspectorCommands`, `.toolbar` | `NSTextView(usingTextLayoutManager: true)` in `NSViewRepresentable`; a gutter view over `textLayoutManager` fragments (never `NSRulerView` + `layoutManager`); rendering-attribute highlighting; `sharingType = .none` |
| Activity | `ActivityView`, `LiveChart`, `SessionsTable` | Swift Charts `AreaPlot`/`LinePlot`, `Table`, `Picker`, `accessibilityChartDescriptor` | — |
| Diagnostics | `DiagnosticsView`, `CheckRow`, `RoutesTable`, `ProblemsList` | `DisclosureGroup`, `Table`, `ProgressView` | — |
| Logs | `LogsView` | `List`, `Picker(.segmented)` (a value filter, so not `.tabs`), `.searchable` | `OSLogStore` |
| Settings | `SettingsView` + tab views | `Settings` scene (declared after the bridge window), `TabView`, `Form(.grouped)` | `SMAppService` (`LoginItemController`), `UNUserNotificationCenter` |
| Onboarding | `OnboardingSheet`, step views | `.sheet`, `TabView`-free custom pager, `ProgressView` | `OSSystemExtensionRequest` via `ExtensionStore`; status-item frame for the callout |
| Shared | `LockGlyph(state:size:)`, `StateWord`, `RateText`, `ByteRateFormatter` | SF Symbols custom symbol; `.contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))`; `.symbolEffect(.breathe)` while connecting; Draw annotations (Regular, Ultralight, Black) used automatically | — |

### Recommended changes to DESIGN §11 (all applied in DESIGN draft 4)

1. **§11.1 navigation:** merge **Statistics into Activity** (history plus live chart), so the sections are Profiles, Activity, Auto-Connect, Diagnostics, Logs (⌘1–⌘5). Profiles are listed **in the sidebar**, a two-column split, not a three-column list-detail.
2. **§11.1 Settings tabs:** General, **Menu Bar**, **Profiles** (new-profile defaults, export all), Advanced, About. Drop the appearance override.
3. **§11.1 scenes:** add `WindowGroup("Edit Profile", for: Profile.ID.self)` for the editor, instead of editing inside the main window.
4. **§11.3 menu contents:** add the **custom header item** (`NSHostingView` in item 0) with a fixed width of 300 pt and its own visibility-driven 1 Hz updates; profile overflow into "More Profiles ▸" after 8; per macOS 27, symbols only on profile items, with `preferredImageVisibility = .visible`. Add the **icon style** setting (Monochrome default / Color, with a navy glyph on color tiles) and the visibility policy with "Show in menu bar" (draft 1's occlusion check doesn't work on 27).
5. **§11.3 icon states:** extend from three to seven states (§7.2), including Paused and Error-stopped, each with a distinct badge.
6. **§11.6 shortcuts:** ⌘N = New WireGuard Profile, ⌥⌘N = New OpenVPN Profile, ⌘O = Import, ⇧⌘K = Resume, ⌘R = Run diagnostics.
7. **§11.2:** add `PauseStore` (or fold `pausedUntil` into `ConnectionStore`), so hero, menu and Dock read one source.
8. **New §11.8 "Design tokens":** the asset catalog roles from §2.2, `ConnectButtonStyle`, the `LockGlyph` symbol family, and the surface helper `.lpSurface(_:)` (opaque for hero and header; glass only for floating controls), plus the Icon Composer app icon.
9. **(Draft 2)** §11.2 derived-state table (§6.6); §11.4 capture hygiene (§6.9); §11.5 clipboard privacy (§6.8); §8.4 prompt placement (§6.5).

---

## 10. What to cut or simplify

| Cut / simplify | Why |
|---|---|
| Multi-tunnel cards, expand/collapse | Only one active tunnel on macOS. A list plus one detail is clearer. |
| Stat pills row (↓ ↑ ⏱ ⇄ ~) | They duplicate the hero; one line of monospaced numbers is enough. |
| Separate Statistics page | Merged into Activity; the live chart also lives in the hero. |
| "Tools" bucket | Becomes Diagnostics as a health report; routes and the DNS check are rows in it. |
| Global kill switch, DNS protection, health check, pin interface | Kill switch is per profile (DESIGN §10.1); DNS follows it; the watchdog is always on (§7.5); pinning is meaningless with NE. |
| Conflict warning modal | Becomes an inline attention strip and a Diagnostics row. |
| Per-SSID tunnel map | Cut from v2.0 (DESIGN §10.4). |
| Theme picker | Settings › General › Appearance (System / Light / Dark). |
| Toasts | Replaced by inline banners (window), user notifications (window closed), or nothing (routine events). |
| Custom update notice | Sparkle standard UI. |
| Ko-fi banner in the main view | Moves to About and to a one-time note after the 10th successful session, dismissible forever. |
| Auto-reconnect toggle per tunnel | Reconnect is the engine's job (DESIGN §7); the only user-facing policy is the kill switch and auto-connect. |
| Double-click to rename in the detail title | Native rename in the sidebar (↩ or context menu). |
| CodeMirror and web views | Native `NSTextView` with our own parser driving highlighting (DESIGN §11.4). |
| Pill-shaped buttons and the accent gradient | Native bezels; the gradient goes. |

---

## Decisions (owner, 2026-10-26)

- **Direction B, "Native Mac app with a living menu"**: approved.
- **Navy reach:** brand surfaces only (hero, detail canvas, editor, logs, charts). Sidebar, toolbar and menus stay system glass.
- **Menu bar default:** ~~monochrome template icon~~ superseded 2026-11-09: the **color tile** is the default, monochrome stays an option.
- **App icon:** refresh for Tahoe (layered Icon Composer style), keeping the same padlock and colors.
- **Open questions 3–9** take the recommended option in §11 unless the owner revisits them:
  - rate label: both directions;
  - switching profiles from the menu: immediate;
  - no global hotkey in v2.0;
  - QR from an image file or the clipboard (no Continuity Camera in v2.0);
  - Control Center control in v2.1;
  - Touch ID only for revealing and exporting secrets;
  - Ko-fi note shown once.
- **Draft 2 note:** these decisions stand. The verified references only changed *how* they are built (no glass on the hero or menu header, Magic Replace instead of a crossfade, the 27 menu-image and visibility rules), and the Fable review fixed the `allowLAN` default (off).

## 11. Open questions for the owner

All ten were answered by the owner decisions above (1, 2 and 10 explicitly; 3–9 by the recommended option). They are kept for the record; none is open in draft 2. New owner items raised by DESIGN draft 4 are not UI questions (feed host, G2 certificate, CRA position; DESIGN §18, §22).

**Open in draft 6:**

11. ~~**German register.** Should the German UI address the user with **du** or **Sie**?~~ **Decided (owner, draft 7.1): du.**

1. **Navy reach.** In dark mode, should navy cover only the brand surfaces and the detail canvas (recommended), or the whole window including the sidebar (more Go-like, but fights Liquid Glass)?
2. **Menu bar default.** Monochrome template (recommended, native and Liquid Glass-friendly) or the v1.0.61 color tile as the default?
3. **Rate label default.** Both directions, download only, or off? (Both is the current behavior; download only halves the width for notch-crowded menu bars.)
4. **Switching profiles from the menu.** Switch immediately (recommended), or always confirm when a connection is active?
5. **Global hotkey** for connect/disconnect: wanted in v2.0? (It needs an extra dependency or a Carbon `RegisterEventHotKey` wrapper.)
6. **QR import from Continuity Camera:** worth it, or are image file and clipboard enough?
7. **Control Center control and widget** (direction C idea, macOS 26, the floor since DESIGN draft 7.1): plan for v2.1?
8. **Touch ID scope:** is gating only secret reveal and export right, or should "Require Touch ID to connect" exist as a per-profile option for shared Macs?
9. **Ko-fi:** is the one-time note after the 10th session acceptable, or About only?
10. **App icon:** keep the current icon exactly, or refresh it for Tahoe's icon style (layered, Icon Composer) with the same padlock and colors?

**Follow-ups (draft 8.3):**

12. **App icon and the + mark.** The status glyph now carries a + in the lock body. Should the app icon (Dock, Finder, Sparkle) carry the same + mark so the two match, or keep the plain padlock? The icon is unchanged for now; open for the owner (it belongs with question 10, the Tahoe refresh).

## 12. Prototype plan (SwiftUI previews first)

There's no engine needed: a `PreviewConnectionStore` drives every `NEVPNStatus` plus our extra states (blocked, paused, auth) from a debug picker.

| Order | Prototype | Why first | Done when |
|---|---|---|---|
| 1 | `LockGlyph` symbol family plus the menu bar item (both icon styles, rate label) | The identity and the most-seen pixels; validates the 16 px shape test | All 7 states are distinguishable in grayscale at 16 px (the snapshot test exists); label width stable across rates and locales; the 3-frame connecting sequence runs and stops with Reduce Motion. S15 ran the sequence and Reduce Motion with stock stand-ins on 27; the custom family itself is still to be drawn (§7.2) |
| 2 | `MenuHeaderView` inside a real `NSMenu` (DESIGN spike S15) | The riskiest AppKit/SwiftUI seam (sizing, live updates, toggle inside a menu item) | Runs on macOS 26 and 27; toggle works; no layout jump while open; updates at 1 Hz while the menu tracks through Observation alone (XPC-driven main-actor updates checked; the `.common` timer is the fallback); profile glyphs visible on 27. **S15: done on 27** (all criteria met; toggle and `SettingsLink` clicked synthetically only); 15.1, 26 and a real-mouse check pending |
| 3 | `ProtectionHero` with all derived states (§6.6 table) plus the shackle animation | The signature moment | Draw Off/On on 26 and 27; Reduce Motion and Increase Contrast variants; VoiceOver reads one sentence; every §6.6 row renders |
| 4 | `MainView` split with sidebar plus `ProfileDetailView`; the bridge window (S15) | The daily window; Settings from the menu | Pseudo-localized de-length strings don't truncate at 720 pt; closing the main window doesn't quit; Settings opens from the status menu with no window open. **S15: the bridge, quit and Settings parts done on 27**; 26 and activation from a real click pending |
| 5 | `AuthPromptView` (four variants plus "waiting for approval") as a sheet and as a non-activating panel | The OVPN spike gate depends on it (Acme, Globex) | Focus lands in the right field after the user's gesture; stale `promptID` handling mocked; no activating window without a gesture |
| 6 | Onboarding steps 2–5 | Extension and configuration approvals are the first-run risk | Each extension result has a screen; migration report renders; the notification request comes last |
| 7 | Editor window with inspector | Largest custom AppKit piece | Highlighting from the real `LockPlusCore` parser via rendering attributes; masking decided; no TextKit 1 fallback (debug assertion silent); not restored after relaunch; excluded from window capture |
| 8 | Activity, Diagnostics, Auto-Connect, Settings | Mostly stock components | `AreaPlot`/`LinePlot` with 300 points stay smooth; the diagnostics "What's inside" preview renders |

Preview matrix for every screen: light/dark × Increase Contrast × en/de/ja × macOS 26/27 (Xcode preview variants plus snapshot tests in CI). On 26 and 27, also screenshot the navy detail under the floating sidebar glass.

---

## Sources

- Apple, SF Symbols 7 (Draw, Variable Draw): https://developer.apple.com/sf-symbols , WWDC25 session 337 https://developer.apple.com/videos/play/wwdc2025/337/ , `drawOn` https://developer.apple.com/documentation/symbols/symboleffect/drawon
- Liquid Glass best practices for macOS Tahoe: https://dev.to/diskcleankit/liquid-glass-in-swift-official-best-practices-for-ios-26-macos-tahoe-1coo ; macOS Liquid Glass skill notes: https://tessl.io/registry/skills/github/robinebers/openusage/macos-liquid-glass
- macOS 27 design refinements: https://9to5mac.com/2026/06/09/macos-27-golden-gate-includes-these-changes-that-tahoe-critics-will-appreciate/ , https://www.igeeksblog.com/macos-27-liquid-glass-redesign/ , https://www.macworld.com/article/3135972/sorry-haters-liquid-glass-on-the-mac-isnt-going-anywhere.html
- NSStatusItem issues on macOS 27 (developer forums): https://origin-devforums.apple.com/forums/thread/836113 ; MenuBarExtra limits: https://swiftpackageregistry.com/orchetect/MenuBarExtraAccess ; NSStatusItem patterns: https://multi.app/blog/pushing-the-limits-nsstatusitem , https://developer.apple.com/forums/thread/710832
- Tailscale windowed macOS UI and the notch: https://tailscale.com/blog/windowed-macos-ui-beta , https://tailscale.com/blog/macos-notch-escape
- Mullvad states and kill switch: https://github.com/mullvad/mullvadvpn-app/blob/master/docs/security.md , https://mullvad.net/en/blog/get-it-now-official-release-mullvad-vpn-app-macos
- WCAG 2.2: https://www.w3.org/TR/WCAG22/ (contrast values in §2.3 computed with the WCAG relative-luminance formula)
- Verified reference for the AppKit/SwiftUI facts in draft 2: `docs/native/reference/swiftui-appkit.md` (macOS 27 release notes, HIG Materials and Menu bar, WWDC25-310, `NSStatusItem.h`/`NSMenuItem.h` in the 27.0 SDK)
