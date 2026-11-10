# LockPlus native: UI review overview

Input for the owner's design decisions, not a recommendation. Source: `docs/native/UI-CONCEPT.md` draft 8.2 and the rendered app. Every screen has an ID (`S-<section>.<nn>`); comment by ID in `index.html` (autosaved) or in this file's terms ("S-2.07: ..."). Light/dark and EN/DE variants share one ID. Region markers are `S-x.yy-a`, `-b`, ...

## 1. Information architecture

- **Menu bar item** (always there; the app is mostly an accessory): glyph (8 states) plus an optional rate label. Click opens the **menu**: header card (state, profile, switch, rates, sparkline), a Connect/Disconnect line, the profile list (checkmark on the active one, up to 8, then "More Profiles"), Pause Protection submenu (5 min / 15 min / 1 hour), Open LockPlus, Settings..., Quit. Conditional lines: Cancel (starting), Enter Code for ... (sign-in waiting), Update Available..., Tunnel Component Not Updated. (S-1)
- **Main window** (920x620, min 720x480): sidebar (Search, Profiles, then Activity, Auto-Connect, Diagnostics, Logs, footer + / - / more) and a detail pane. A profile's detail is the **protection hero** (state glyph, state word, numbers, chart, actions) followed by Connection, Protection (kill switch, local network), Auto-Connect, Credentials, Notes, Import report, Edit Config / Export. Banners sit above the detail for system-level problems. The whole window is a drop target for .conf/.ovpn/.zip/QR images. (S-2, S-3, S-8, S-9)
- **Editor window** (one per profile, behind Touch ID): text editor with line numbers, masked private key, issues and reference inspector. (S-4)
- **Sheets/panels**: import preview and batch import, sign-in prompts (sheet on the window, or a small non-activating panel opened from a menu/notification click), password change/reveal, pause confirmation, error details, diagnostics export, uninstall, onboarding. (S-4, S-5, S-7, S-10)
- **Settings window** (5 tabs): General (login, language, notifications), Menu Bar (visibility, rates, icon style), Profiles (defaults, Export All), Advanced (log level, release candidates, diagnostics, reinstall, uninstall), About. Auto-Connect is a main-window section, not a Settings tab. (S-6)
- **System UI not drawn by the app**: Sparkle's update dialogs, the macOS approval prompts, Notification Center, the Location prompt. (see artefacts)

## 2. Main flows

1. **First launch / onboarding** (S-7): Welcome -> Install the tunnel component (macOS asks once; waiting-for-approval state with "Show the Switch Again"; restart needed; failed) -> Allow VPN configuration (explained before the system alert) -> Bring your profiles (migration from LockPlus 1.x with optional saved passwords, choose files, QR) -> Done (menu bar callout, then the notification permission). Steps already satisfied are skipped.
2. **Import** (S-4): drop, + menu, File > Open, clipboard, QR image. One file -> preview (name, type, supported/ignored/unsupported, kill switch and local-network defaults); zip or several -> batch list. Unsupported content disables Import and says why; warnings (legacy cipher, server on another network) keep it enabled.
3. **Connect / disconnect** (S-1, S-2): Connect in the hero, toolbar, menu or sidebar context menu. States run Not protected -> (Preparing) -> Connecting -> Protected. Switching to another profile is "not protected for a moment". Disconnect is one click. Every Connect is disabled with an explanation while another start, switch or restart is under way.
4. **Kill switch blocked** (S-2 rows 3a, 7, 10): the profile's kill switch keeps traffic blocked while the connection is lost. The hero is orange, says "No traffic leaves this Mac", shows retry countdown (row 10), offers "Disconnect and Restore Internet" and Pause (hotel Wi-Fi hint). After a fatal failure (row 7) there are no retries.
5. **Sign-in** (S-5): known before connecting (password/key passphrase not saved, static challenge) -> sheet first. Asked by the server during the connect (dynamic challenge, rejection, push approval) -> the hero says "Sign in to connect", the answer goes into the same connect. Cancel also disconnects. Expiry and failure variants are rendered.
6. **Auto-Connect** (S-8): one profile, "Wi-Fi networks you don't trust" and/or Ethernet, a trusted-networks list, Location only when "Add Current Network" is used. Status lines: paused after a manual Disconnect (until another network), resumes when another profile disconnects, held during a tunnel-component update, could not be turned back on, blocked by another user's VPN. "Paused" and "restored" are those lines plus the menu's Pause Protection (a timed pause, row 2, resumes automatically).
7. **Errors** (S-2 rows 14, 3b, 8, 13a, S-9): error-stopped hero with "Not protected" (e.g. no network, kill switch not applied, server unreachable); background failures go to Diagnostics > Problems, never a modal; system-level problems are banners.
8. **Update and tunnel component** (S-9, S-1): Sparkle drives the update (menu gets "Update Available..."); the extension can be not allowed, turned off, removed by an update, damaged, waiting for restart, or "update failed" (old one still connects; details unavailable). Each has a banner, a menu line or a hero row.

## 3. State model in plain words

The hero, menu header, menu bar glyph and sidebar subtitle all come from one table of 15 rows (plus variants), first match wins. In order: (1) the tunnel component is not usable; (2) paused; (3) a sign-in is needed during a connect; (3a/3b) a connect failed (blocked / auto-connect paused); (4) connecting; (4a) the tunnel process is being restarted; (5) protected but DNS not confirmed; (6) protected; (7-10) the connection dropped: blocked after a failure, auto-connect paused, new code needed, blocked and retrying; (11) reconnecting without a kill switch; (12) disconnecting; (12a) LockPlus's own start work before the system reports anything (preparing, waiting for a stop, waiting for a restart, may restart, start ended early, waiting for a network, connects when a network is available); (13a) auto-connect paused after a failed start; (14) stopped with an error (including "no network"); (15) not protected. Shape comes first, colour second: each state has its own glyph (open/closed lock with a badge: ..., !, blocked, pause, error). "Blocked" is a state, not an alert. The words "Connecting..." and "Protected" are only used when the system really says so.

## 4. Decisions to confirm or change

1. **Menu-bar-first vs window-first.** Today the app lives in the menu bar; the window opens on demand (and at login if set). A Dock icon exists while the window is open. Alternative: window-first with the menu as a shortcut.
2. **Hero wording.** "Protected" / "Not protected" / "Blocked"; "Not protected" is also shown in plain grey-white, not alarming. Confirm tone: the unprotected state carries no warning colour; error-stopped and attention states do.
3. **Number of status rows.** 15 rows plus about 25 variants (S-2.xx, S-1.xx headers). Possible to merge e.g. all row 12a variants into one "Preparing..." copy, or to fold 3a/7/10 into one "Blocked".
4. **"Not protected" emphasis.** Should a disconnected profile look calmer (today) or louder (e.g. orange when auto-connect is on and the Mac is unprotected)?
5. **Menu content.** Profiles inside the menu (switch from the menu) vs only the header and window; the 8-profile limit; whether Pause belongs in the menu or only in the hero; whether the header switch should exist next to the Connect line.
6. **Menu bar label.** Rates shown by default ("Both"), hidden while blocked. Icon style default is the colour tile (draft 8.2); monochrome is optional. Glyph set (8) and their badges.
7. **German register: du-form** (decided by the owner; shown throughout S-x EN/DE pairs for a last read-through).
8. **Colours.** Green-sage protected, orange attention/blocked, red critical, navy dark surfaces; contrast checked, but taste is open.
9. **Kill switch naming.** "Kill switch" for full tunnels, "Route protection" for split tunnels; footer text mentions the 3-second crash window.
10. **Auto-Connect as a main-window section** (not in Settings), and the length of its status lines.
11. **Sign-in as a sheet** vs a non-activating panel; Touch ID gates (Edit Config, Export, Show password).
12. **Settings tabs** (5) and the amount of explanation text in each.
13. **Onboarding length** (5 steps, partly skipped automatically) and the migration step's density.
14. **Destructive actions**: Uninstall's default button is Cancel; Delete asks first; "Disconnect and Restore Internet" wording.

## 5. Known render artefacts (not design)

- **UI-M18, sidebar and inspector vibrancy (fixed in the renderer, draft 8.2)**: offscreen capture can't composite vibrant material, so default-styled text in the sidebar and the editor inspector rendered near-black and the selected row as a black bar. The real app was checked on macOS 27 (2026-11-09) and was always readable; `ScreenshotTests.render` now sets an explicit `labelColor` foreground and replaces the selection view (`RenderFixups`), so the PNGs show the real look. Remaining difference: the sidebar's translucent glass is a flat grey/white fill here.
- **Toolbar and title bar are missing** from all window images (borderless offscreen window): the toolbar's + menu and the Connect button are not visible here.
- **Inactive-window controls**: the test host is never key, so switches show a grey track and tabs/selection their inactive style; the Settings tab bar shows a blank highlight on the selected tab.
- **Menu bar menus are stand-ins**: an NSMenu can't be captured offscreen (it is system Liquid Glass). The items, order, enablement, subtitles, checkmarks, glyphs and shortcuts come from the real MenuBarController; the header is the real view; the panel styling is approximate.
- **Alerts, confirmations and notifications are stand-ins** drawn from the app's strings (native NSAlert/Notification Center can't be captured). The status item icons are drawn from the same images the controller assigns; real menu bar background differs.
- **Not rendered**: Sparkle's update window, macOS approval/Location/Touch ID prompts, the Dock menu (not built), the drag-over drop overlay, VoiceOver-only menu line, context menus, popovers of the editor's text completion. Sign-in panel (non-activating NSPanel variant) is shown as the sheet.
- Numbers and times are fixtures (e.g. 02:14:07, "Handshake 111 sec" grows with run time); German pluralisation or locale separators ("1,2 MB/s") follow the system locale.
- Editor images show the text area and inspector only (no title bar with Revert/Save).

## 6. Contents (screen IDs)

<!-- TOC -->
