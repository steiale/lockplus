# Changelog

All notable changes to LockPlus will be documented in this file. LockPlus 1.x (and WireGuide+ before it) is documented
in its GitHub releases; the entries below 2.0.0 are from the original WireGuide project this app started from.

## [2.0.2] - Unreleased

### Changed
- Starting a profile from System Settings › VPN or with `scutil --nc start` now only works for profiles with Auto-Connect turned on. Any other profile is refused with "Connect it from LockPlus", and Diagnostics notes the attempt. A profile picked for Auto-Connect counts only while Auto-Connect is turned on. Connect those profiles from LockPlus (the main window or the menu bar). This also stops other users on the same Mac from connecting your profiles with your saved credentials.
- Profile checks and zip reading now run in a separate sandboxed helper (LockPlusValidator, inside the app) with no network access and no access to your files. The tunnel component, which runs as root, no longer parses untrusted profiles with the OpenVPN engine. Profiles that were "Not yet verified" are checked again automatically, even before the tunnel component is approved.
- Zip import limits are now 1 MB per profile and 64 MB unpacked (were 10 MB and 100 MB). A file that crashes the checker twice is refused with "LockPlus couldn't check this file safely."; a check that takes too long is retried and, if it still can't finish, the profile is saved as "Not yet verified" and checked again later. Profiles saved by 2.0.1 that the stricter tunnel component would refuse (for example ones with `link-mtu`) are updated and checked once.

### Added
- Open `.ovpn`, `.conf` and `.zip` files from Finder (double-click or Open With) or by dropping them on the Dock icon. LockPlus shows the usual import preview, and nothing is saved until you confirm. LockPlus is offered as the default app for `.ovpn` (another VPN app may already be the default) and under Open With for `.conf` and `.zip`. A file opened this way waits its turn behind an open import sheet, the sheet says where it came from, and Import enables after a moment and has no Return shortcut. You can open up to 20 files at a time.
- Test Connection (Diagnostics, ⌘R Run All, or the link in the protection panel while connected) checks that IPv4, IPv6 and DNS use the tunnel. It contacts only LockPlus's own test page, and only when you start it. A result says "through the tunnel" or "blocked" only when the test proved it; anything else is shown as not verified. Copy Results hashes addresses. It doesn't check the address websites see, because that would need a third-party service. The last result is included in the diagnostics export with addresses hashed.

### Security
- The tunnel component accepts only LockPlus builds at least as new as itself, so older LockPlus copies can no longer talk to it.
- The end of a pause, the end of a tunnel component update and the Auto-Connect setting are acted on only when LockPlus wrote them itself: each is sealed with a key in your keychain and used once. A record changed by another program reconnects nothing, and a changed Auto-Connect setting is turned off and noted in Diagnostics. If LockPlus can't read its keychain at the end of a pause, it tries again instead of giving up; a pause that can't be secured isn't started.
- Turning Auto-Connect off withdraws the profile's permission to be started without LockPlus. A session macOS may still restart by itself (a kill-switch session after a crash or a lost network) keeps that permission until you disconnect it while it runs, delete the profile or restart the Mac. Cancelling it while it is down (for example while it waits for a network) stops macOS's restart but doesn't withdraw the permission.
- The Auto-Connect setting is sealed whether it is on or off, so an older copy of it written back by another program is refused after you turned Auto-Connect off. A recorded "reconnects when a network is available" state is sealed too, and one written by another program is ignored.
- While an older tunnel component is still running during an update, LockPlus doesn't start kill-switch profiles.

### Removed
- The "Import QR Code Image…" menu items and the onboarding QR button. QR import never worked, and dropped images now say "Images aren't supported."

### Fixed
- An automatic retry never changes a profile's VPN configuration while another profile is starting.
- A second failed profile edit no longer marks the profile as tampered: the pending rollback is now tied to the VPN configuration's revision.
- After "Save Only" on a connected kill-switch profile, a restart of the session by macOS is no longer refused.
- A duplicate VPN configuration started outside LockPlus is noted in Diagnostics when it starts, and at launch the profile's row follows the configuration that is actually connected.
- A start from System Settings refused shortly after LockPlus launched now says why.
- "Save Only" of a connected profile whose new version isn't verified yet keeps the installed version, so macOS can still restart the session.
- A file opened from Finder never replaces an import you started yourself; at most 5 opened files wait, and a file that can't be read within 10 seconds is refused.
- A profile whose file check keeps timing out no longer slows down every launch: after three launches it waits for "Check Again" on the profile.
- Test Connection: a connection that reached the network outside the tunnel and then stalled is no longer shown as "blocked"; IPv6 "blocked" is checked against the address actually tried; split DNS says that only the profile's DNS servers were checked. A connection attempt that started and then timed out is shown as not verified, never as "blocked" or "no IPv6", and "no IPv6" needs the routes to prove it.
- A profile edit verified and installed in the background no longer interrupts a kill-switch connection macOS is restarting at that moment.
- A profile whose settings file was found changed outside LockPlus keeps its installed copy (and a running session keeps working) until you delete it, and LockPlus never removes the installed copy of a profile while it is connected or connecting.
- Files on a stalled network volume no longer slow LockPlus down: an unreadable file stops its import, and a burst of opened files can't start more than one import at a time.
- With more than 500 profiles, LockPlus still withdraws the permissions of profiles that no longer have Auto-Connect.
- A profile edit installed in the background no longer stops a kill-switch connection that macOS is restarting while the previous session is still shutting down.
- The end of a pause is used once even when the pause record was changed to name no profile, so an older copy written back reconnects nothing.
- Pausing while macOS is about to restart a kill-switch session after a crash or a lost network, or while that restart is still connecting, now stops it and reconnects the profile when the pause ends, if LockPlus started that session or saw it connected. A start from elsewhere that was refused, also one still connecting when you paused, is stopped by the pause and not reconnected.
- A pause record that another program changed to show nothing paused is used up, so writing the original back later reconnects nothing.
- An answer to a server prompt is never sent to the server of a newer version of the profile installed meanwhile, and saving it never overwrites the newer version's saved credentials.
- If LockPlus can't use up a pause's one-time value because the keychain is unavailable, it keeps trying (also after a quit, and the resume helper stays registered for it) and uses it up before it acts on a pause record again. This record of the debt is kept in the settings file, so a program that writes back a whole earlier copy of that file can undo it (a known limit, see DESIGN §20 risk 31).
- Turning Auto-Connect off while the keychain is unavailable is secured once it is available again, also after LockPlus was quit in between.
- Start permissions of kill-switch sessions survive a tunnel component state file of another version, and are the last to go when the permission table is full.
- The end of a pause reconnects the profile also while LockPlus isn't open. The helper that does it could hang on the first VPN status change it saw, so the profile stayed disconnected until LockPlus was opened. It now ends within 5 seconds. A run that runs out of time (for example right after the Mac wakes) leaves the pause in place, and the next minute's run tries again; a run cut off at any point is completed by the next one without starting the profile twice. Only a profile that can't be read, or whose kill switch can't be applied, ends the pause without reconnecting.
- The profile checker (LockPlusValidator) no longer crashes every time it starts (release candidate 200026), which left new OpenVPN profiles "Not yet verified" and refused every zip import. It still accepts requests only from this LockPlus build.

## [2.0.1] - 2026-11-11

### Fixed
- A second LockPlus VPN configuration started while one is connected (a duplicate, a start from System Settings or `scutil`, or another user's) is refused instead of taking over the running tunnel, which could leave the Mac without a working connection while it still showed Connected. A kill-switch profile still takes over from a profile without a kill switch, and a duplicate of the running kill-switch profile waits for it to end.
- A refused start no longer takes over the main window's status; Diagnostics says why it was refused.
- Onboarding step 3 moves on with one click when there is nothing to allow yet.

### Added
- SECURITY.md: how to report a vulnerability privately, response times and supported versions.

## [2.0.0] - 2026-11-10

LockPlus rebuilt as a native macOS app (macOS 26, Apple silicon). See `docs/release/RELEASE-NOTES-2.0.md`.

### Added
- Native SwiftUI/AppKit app with a menu bar; the tunnel runs in a Network Extension system extension (no root helper, no firewall rules).
- Kill switch enforced by macOS (`includeAllNetworks`), route protection for split tunnels, "Disconnect and Restore Internet".
- WireGuard and OpenVPN (OpenVPN 3) in one app, with password, static and dynamic challenge sign-in.
- Auto-Connect on untrusted Wi-Fi and/or Ethernet with trusted networks, through macOS on-demand rules.
- Pause Protection, DNS verification, live rates in the menu bar, one-click switching.
- Import with a report (`.conf`, `.ovpn`, zip, the WireGuard app's export) and a built-in editor with checks.
- Diagnostics with an export that removes secrets; English and German; a new adaptive app icon.
- Import of LockPlus 1.x profiles, settings, history and (with your permission) saved passwords.

### Changed
- One tunnel at a time (LockPlus 1 could run several WireGuard tunnels).

### Removed
- The LockPlus 1.x background helper and its firewall rules.

## [0.1.8] - 2026-04-13

### Changed
- Sidebar navigation: removed Tools tab bar, DNS Leak Test and Route Table are now direct sidebar sub-items
- Settings modal: fixed size regardless of active tab (no more resize when switching to Advanced)
- Settings sidebar active state: tint highlight instead of solid blue (macOS HIG)
- Dropdown controls: custom styled per macOS HIG (28px height, 6px radius, theme-aware chevron)

### Improved
- Route table: sticky column header, legend pinned to bottom, table fills remaining space with scroll
- DNS Leak Test and Route Table now call real backend (previously stub implementations)
- macOS HIG design tokens: added `--border-strong` for input control borders

### Removed
- Network Diagnostics (Ping) tool — not meaningfully useful as a standalone feature
- Unused i18n keys for removed Diagnostics feature

## [0.1.7] - 2026-04-09

### Added
- Multiple simultaneous tunnel support
- Per-tunnel NetworkManager (independent routes, DNS, route monitor per tunnel)
- Per-tunnel health check and reconnection
- Full-tunnel conflict detection (reject two 0.0.0.0/0 configs)
- DNS union across all active tunnels
- No-handshake warning: orange dot in tunnel list, ◐ in tray menu
- Tray menu shows per-tunnel connection + handshake status
- Architecture & design documentation (docs/DESIGN.md)

### Fixed
- Disconnect one tunnel no longer breaks other active tunnels
- Conflict detection: macOS netstat abbreviated CIDRs now parsed correctly
- GUI not reflecting connection state when tunnel connected via system tray
- Bypass route race conditions (lock safety, error propagation)
- Tray icon padding: trimmed transparent pixels for tighter menu bar fit
- Tunnel list unnecessary re-renders on every status tick
- README streamlined: removed defensive tone, screenshots moved to top

### Changed
- Pin Interface toggle added (Settings > Advanced) for dual-network stability
- Bypass routes pinned to upstream interface with -ifscope when enabled

## [0.1.6] - 2026-04-08

### Added
- Settings redesign: split layout with sidebar (General / Advanced / About)
- About tab: app icon, version, GitHub/Issues/License links, update status
- Update popup: modal with release notes ("What's New") and "Skip This Version"
- Helper auto-upgrade: detects version mismatch and reinstalls on app update
- Helper install retry dialog with Quit/Retry options on cancel
- OpenURL Wails binding (restricted to github.com)
- Tests for IsBrewInstall and OpenURL validation (7 new tests)

### Fixed
- Brew install detection: check Caskroom receipt instead of binary path
- Non-brew update: opens GitHub Releases page instead of broken auto-download
- Brew update: runs `brew update` before `brew upgrade` for third-party taps
- Helper Ping response: separate AppVersion field (fixes IPC protocol validation)
- Update popup double-click guard
- localStorage exception handling for skip version
- Detailed admin prompt explaining why password is needed

### Changed
- README/About description: "native macOS" → "cross-platform"

## [0.1.5] - 2026-04-07

### Added
- Health Check toggle in Settings (default: off, recommended with PersistentKeepalive)

### Changed
- Health Check default changed from on to off (consistent with other WG clients)
- README rewritten: removed aggressive tone, verified claims, acknowledged official app works for many users

## [0.1.4] - 2026-04-07

### Security
- Remove script execution (PreUp/PostUp/PreDown/PostDown) — eliminates local privilege escalation via ApproveScripts RPC
- Fix Windows IPC ACL: allow non-admin GUI to connect to helper pipe
- Harden update integrity: asset size validation + Content-Length check

### Fixed
- Kill switch pf rules: use anchor-only approach instead of modifying main ruleset (fixes Tahoe compatibility)
- Kill switch + DNS protection now toggleable while VPN is connected
- Kill switch reconnect deadlock: suspend/resume firewall rules during reconnect
- Log viewer scroll not working
- Tunnel list scroll overflow

### Added
- Handshake-based health check: detects dead tunnels and triggers reconnect after 180s
- Instant sleep/wake detection via NSWorkspace notification (polling fallback kept)
- Typed tunnel error enums (ErrAlreadyConnected, ErrNetwork, etc.)
- DNS post-write verification
- Crash recovery journal with pre-modification DNS snapshot
- Comprehensive unit tests (102 tests, race-clean)
- CHANGELOG.md
- Info-level logs for kill switch and DNS protection events

## [0.1.3] - 2026-04-07

### Fixed
- "Show Window" not working after closing the window (RegisterHook instead of OnWindowEvent)
- Dock icon hide/show when window is closed/reopened
- App icon showing Wails default (white W) instead of WireGuide red icon
- About/Settings dialog showing wrong version — now fetched dynamically from Go

### Added
- GitHub issue templates (bug report, feature request)
- CONTRIBUTING.md and PR template

## [0.1.2] - 2026-04-07

### Fixed
- Dock icon not hiding when window is closed
- Tunnel list not updating after rename

## [0.1.1] - 2026-04-06

### Fixed
- Daemon socket directory permissions (0700 → 0755)
- LaunchDaemon install flow rewrite (app first-launch, not cask postflight)

### Added
- Version display in Settings

## [0.1.0] - 2026-04-05

### Added
- Initial release
- WireGuard tunnel management (import, create, edit, export .conf files)
- Config editor with CodeMirror 6 syntax highlighting and autocompletion
- System tray with connection status badge
- Kill switch via macOS pf
- DNS protection (force DNS through VPN tunnel only)
- Auto-reconnect with exponential backoff
- Sleep/wake recovery
- Route monitor for gateway changes
- Conflict detection (Tailscale, other WG interfaces)
- Network diagnostics (ping, DNS leak test, route table)
- Auto-update (GitHub Releases + Homebrew)
- Real-time RX/TX speed graph
- i18n (English, Korean, Japanese)
- Dark / Light / System theme
