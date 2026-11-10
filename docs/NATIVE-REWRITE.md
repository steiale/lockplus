# LockPlus Native: decision, requirements, lessons

This document defines the native Swift rewrite of LockPlus. It records the architecture decision, the requirements, and every lesson the Go/Wails app had to learn, so the native app starts out knowing them.

Sources:
- 276 commits of history and the project memory notes;
- the Fable security review and the Opus code reviews of October 2026;
- research into Apple guidance and open-source apps that ship this stack (sources in the last section).

Status: decided 2026-10-25; updated 2026-10-26 for DESIGN draft 7.1 (draft 7.1: the minimum OS rises from macOS 15.1 to **26.0**, and only 26 and 27 are supported and tested; draft 6: the 60 s NE start limit, so a failed start + start latch is the expected before-Connected path and first-connect interactive auth takes two starts; draft 5: holds before Connected and spike row E14, the P1 prerequisites, the `LP_DEV_SIGNING` dev clause; draft 4: the verified component references in `docs/native/reference/`, the final Fable spec review, and the owner decisions: macOS 15.1 minimum (raised to 26.0 by draft 7.1), openvpn3 `release/3.11.8` + OpenSSL 3.5 LTS, wireguard-go master, Swift 6 with explicit concurrency settings, Apple Development dev builds, cask cleanup under `zap`). Nothing is built yet. Where this document and `docs/native/DESIGN.md` disagree, DESIGN wins.

## 1. Decision

LockPlus will only ever target macOS. The rewrite is native Swift:

| Concern | Native design | Replaces (Go app) |
|---|---|---|
| UI | SwiftUI windows + AppKit `NSStatusItem`/`NSMenu` for the menu bar | Wails v3 beta + Svelte + a tray patch + `private_mac_apis` |
| Tunnel host | `NEPacketTunnelProvider` **system extension** (Developer ID in releases; Apple Development for dev builds) | root LaunchDaemon helper, osascript installer, unix-socket JSON-RPC |
| WireGuard | WireGuardKit, from a fork we maintain (patch series W0–W9), built on wireguard-go **master** (pinned by pseudo-version for the 2026-10 security fixes) | wireguard-go in the root helper + utun |
| OpenVPN | openvpn3 core **`release/3.11.8`** (never master; MPL-2.0 option) + OpenSSL **3.5 LTS** + our own ObjC++ shim | bundled openvpn 2.7 subprocess + management interface |
| Kill switch | `includeAllNetworks` (full tunnel) / `enforceRoutes` (split) | pf anchors |
| DNS | `NEDNSSettings` (`matchDomains: [""]` for full, explicit domains for split) | networksetup/scutil + DNS journal |
| Wi-Fi auto-connect | `NEOnDemandRule` with `ssidMatch` | CoreWLAN polling + Location |
| Secrets | app: data-protection keychain; extension: the **System keychain** (primary; the 2021 sandbox bug was fixed for NE system extensions in macOS 14), with sealed root-owned 0600 files in its sandbox container as the tested fallback; spike S4 picks one; handed over via XPC (DESIGN §6.3) | legacy file keychain |
| Updates | Sparkle 2.10.1, pinned exactly (EdDSA, signed feed, deltas) | custom GitHub + Ed25519 updater that only revealed the zip |
| Login item | `SMAppService.mainApp` | LaunchAgent plist, later the Wails AutostartManager |
| Build | Xcode 27.1 (pinned in `toolchain.lock`); release = unsigned `xcodebuild archive` + inside-out Developer ID signing + `notarytool` + DMG, on the dev Mac only | go-task Taskfiles + wails3 CLI |

Why:
- Apple tells VPN apps to migrate to Network Extension and to avoid pf and route-table edits (WWDC25 session 234; TN3165 "pf is not API").
- About 9–10k lines of Go exist only because we run as root: helper, ipc, elevate, firewall, network, most of tunnel, reconnect and ovpn. That is where our recurring bugs and the whole root attack surface lived.
- Wails v3 is a nightly pre-1.0 with a bus factor of about 1, and macOS 27 tray bugs are still open upstream.

What is deliberately NOT carried over:
- Multi-tunnel concurrency. macOS runs only one active packet-tunnel configuration at a time. Decide this before writing any UI.
- openvpn 2.x features that need scripts, plugins or TAP. Profiles that rely on them get a clear "unsupported" message at import.

## 2. Target skeleton

- **Minimum macOS 26.0** (supported and tested: 26 and 27; owner decision 2026-10-26, DESIGN draft 7.1, replacing 15.1: every Apple Silicon Mac that runs 15 also runs 26, and two OS versions match the two VMs macOS runs at once), arm64 only, Swift 6 language mode with explicit concurrency settings (`nonisolated` default isolation, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, plus `MemberImportVisibility`).
- **`LockPlus.app`**: SwiftUI + AppKit, Sparkle, hardened runtime, not sandboxed.
  - Entitlements: `com.apple.developer.system-extension.install`, NE `packet-tunnel-provider` (dev) / `packet-tunnel-provider-systemextension` (release), `application-groups` `M53GHX9FAY.<bundle-id>`, `keychain-access-groups`, `personal-information.location`.
- **`LockPlusTunnel.systemextension`** in `Contents/Library/SystemExtensions/`: sandboxed, with `network.client`, `network.server`, the NE entitlement and the same group, and no Hardened Runtime exception entitlements.
  - `Info.plist`: `NEProviderClasses` → `com.apple.networkextension.packet-tunnel`, `NSSystemExtensionUsageDescription` (required, or activation fails), plus `NEMachServiceName = $(LP_APP_GROUP).tunnel.v$(CURRENT_PROJECT_VERSION)`. The name changes with every version (see L-EXT-3).
  - WireGuardKit's Go bridge (`libwg-go.a`) and openvpn3 are linked statically **into** the extension; if anything must be dynamic, it goes in the extension's own `Contents/Frameworks` with rpath `@executable_path/../Frameworks` (never the template's inherited `../../../../Frameworks`).
- **Packages:**
  - `LockPlusCore`: models, the `.conf`/`.ovpn` parsers and allowlist, the XPC protocol and the signing requirements.
  - `TunnelEngine`: provider logic behind protocols, unit-testable outside the NE.
  - `Vendor/wireguard-apple`: the forked WireGuardKit **is** the local package (Swift 5 mode until its annotation patch lands); its Go bridge is built by an External Build System target.
  - `OpenVPN3Shim`: ObjC++, with OpenSSL consumed as a prebuilt XCFramework.
- **Bundle IDs:** new ones, so the native app can be installed next to the Go app (`io.github.steiale.lockplus.mac` and `.mac.tunnel`), plus a separate Homebrew cask.
- **Profiles:** four provisioning profiles, a development and a Developer ID one for each bundle ID. Development (Xcode automatic signing, Apple Development) uses the unsuffixed NE value; Developer ID needs `-systemextension` on **both** the app and the extension. P1 uses the team's existing Developer ID certificate; the **G2** certificate (the old Developer ID CA expires 2027-02-01) is requested on P1 day 1 and is in use by P2a at the latest (DESIGN §2.7, S9/S9b).
- **Version:** one `xcconfig` value drives `CFBundleShortVersionString` **and** `CFBundleVersion` for the app, the extension and the appcast. CI fails if they disagree; a release's `CFBundleVersion` must be strictly greater than the previous one. Dev builds add a stamp to `CFBundleVersion` only.

## 3. Requirements from our own history

Each item: what happened (evidence) → the requirement in the native app → the test that proves it.

### Tunnel lifecycle
- **L-LC-1: no zombie tunnels.** wireguard-go closed its own device after a fatal TUN read error and the UI kept showing "Connected" (e7bbed1). A `select` on two ready channels skipped death handling half the time.
  - Requirement: any engine or openvpn3 fatal error calls `cancelTunnelWithError` (or fails the pending start), or is held with the kill switch (DESIGN §7.2). The app's only state source is `NEVPNStatus` plus `fetchLastDisconnectError`.
  - Test: kill the WG backend inside the extension; status must leave `.connected` within 5 s.
- **L-LC-2: "connected" means the data plane is up.** The OpenVPN reconnect returned when the process started, so the kill-switch resume found no interface and stayed off (e7bbed1).
  - Requirement: call the `startTunnel` completion only after openvpn3 reports CONNECTED **and** `setTunnelNetworkSettings` has completed.
- **L-LC-3: every cross-process call has a timeout.** A wedged management socket blocked forever. An RPC timeout shorter than the connect killed the helper. Health pings queued behind Connect caused false "dead helper" verdicts (7a55ba6, aa46660, e7bbed1).
  - Requirement: every XPC call has a timeout, and a slow connect is never mistaken for a dead extension.
- **L-LC-4: one source of truth.** The GUI drifted from reality on tray and Wi-Fi-rule connects (7a6e365, cfc7fe9). Policy such as the kill switch was applied only for connects from one UI path (Opus review H3).
  - Requirement: the policy lives in the configuration (`includeAllNetworks` etc.), never in a UI code path.

### Reconnect, sleep, network change
- **L-RC-1: path changes.** Wi-Fi to Ethernet left the tunnel zombied, because wake was the only trigger (33e2ef6).
  - Requirement: the extension watches `NWPathMonitor` (`NEProvider.defaultPath` is deprecated in macOS 15 and hidden in Swift 6), sets `reasserting`, and rebinds.
- **L-RC-2: dead peer.** There was no handshake for 180 s and nothing noticed (de542d0).
  - Requirement: a handshake-age watchdog in the extension (WG) and openvpn3 keepalives.
- **L-RC-3: respect backoff.** Releasing openvpn's hold at once skipped its restart pause and could lock accounts (c15d1ba).
  - Requirement: every retry loop has exponential backoff with a cap.
- **L-RC-4: auth during reconnect.** A 2FA prompt was torn down by the reconnect timeout, and a stale TOTP reply got reused.
  - Requirement: a pending auth prompt pauses the timeout, and stale replies are drained. (Before Connected nothing may pause: NE ends a start after 60 s, so a first-connect prompt takes two starts, DESIGN §7.2/§8.4.)
- **L-RC-5: sleep/wake.**
  - Requirement: with `disconnectOnSleep=false`, `sleep()` quiesces and `wake()` reconnects with `reasserting=true`; on failure call `cancelTunnelWithError`, or hold with the kill switch (DESIGN §7.2). Recreate UDP sessions after wake.

### Kill switch
- **L-KS-1: verify behavior, not configuration.** The pf kill switch was a no-op for months because the anchor name was wrong (c9e9ffd). It was also disabled during every reconnect (Opus review, root H1) and failed open when `pfctl -e` failed (b120e52).
  - Requirement: an automated **leak harness** before every release, checking:
    - the extension is killed;
    - reconnect keeps blocking;
    - sleep/wake;
    - a Wi-Fi to Ethernet switch;
    - fragmented and large packets (RDP/SMB);
    - OpenVPN over TCP;
    - DNS (`scutil --dns`, plus querying an external resolver directly).
- **L-KS-2: never toggle `includeAllNetworks` while connected.** Save it only while disconnected.
- **L-KS-3: updates while blocked.** With the kill switch on, an update can leave the Mac offline (Mullvad's experience).
  - Requirement: stop the tunnel before replacing the extension, then reconnect.
  - Test: run a Sparkle update with the kill switch on.
- **L-KS-4: fragments and TCP.** IP fragments and SYN-only TCP state broke RDP and OpenVPN-over-TCP under pf (e7bbed1, c9e9ffd).
  - Requirement: keep these cases in the leak and throughput harness even though pf is gone.

### DNS
- **L-DNS-1: crash leaves no state.** Hijacked DNS survived crashes, which needed a journal (5e5b72b, b120e52). The NE removes the problem.
  - Test: `kill -9` the extension, then check `scutil --dns`.
- **L-DNS-2: every pushed form.** `dhcp-option DNS`/`DNS6`/`DOMAIN-SEARCH`, 2.7 `dns server N`/`search-domains`, PUSH_UPDATE, and DNS defined in the profile itself all appeared (04048ab, c15d1ba). `pull-filter` must be honoured.
  - Requirement: map all of them into `NEDNSSettings`, using `matchDomains` and `matchDomainsNoSearch`.
- **L-DNS-3: diagnostics fail closed.** The leak test reported "safe" when it couldn't read the resolver (c9e9ffd). MDM profiles silently ignored DNS writes.
  - Requirement: after connect, verify the effective resolver.

### MTU and endpoints
- **L-MTU-1.** MTU parsing always fell back to 1420 (c7e3a74), and imported profiles without `mssfix`/keepalive stalled RDP (e7bbed1).
  - Requirement: set `NEPacketTunnelNetworkSettings.mtu` explicitly, try every resolved endpoint IP, and keep MSS/keepalive floors.

### OpenVPN
- **L-OVPN-1: profile validation is an allowlist with a parser identical to the engine's.** A blocklist let profiles make root write and read files, and our tokenizer disagreed with openvpn's on quotes, backslashes and inline close tags (c59eb25).
  - Requirement: port the allowlist and the differential tests (`internal/ovpn/allowlist.go`, `parse.go`, `validate_test.go`). Add a differential test against **openvpn3's** parser.
- **L-OVPN-2: 2.7 compatibility traps.**
  - `cipher X` is no longer a data-cipher fallback; we added a shim for CBC-only servers (04048ab).
  - `verb` must be ≥3 to see PUSH DNS but ≤4 to avoid logging keys (c15d1ba).
  - OpenSSL 3.x/4 needs `providers legacy default` for BF-CBC.
  - Requirement: confirm the openvpn3 equivalents in the spike. The native engine pins openvpn3 `release/3.11.8` (never master) against OpenSSL **3.5 LTS**. 64-bit block ciphers (BF-CBC/DES/3DES) and sub-160-bit digests are **unsupported** in v2.0 and `enableLegacyAlgorithms` is never set (DESIGN §8.1, §8.3).
- **L-OVPN-3: auth flows.**
  - Combined password+OTP strings, static challenge (SC), dynamic challenge (CRV1, which carries the username in the challenge), and auth-failed re-prompts all occur.
  - Web/SSO auth (`WEB_AUTH`/`OPEN_URL`/`CR_TEXT`) and encrypted keys must not hang; show a clear error or support them.
  - Never advertise `IV_SSO` features we don't implement.
  - A first-connect prompt never waits inside a pending start (NE times a start out after 60 s): prompt before the start, or fail it and start again with the answer (DESIGN §8.4 two-start flow, draft 6).
- **L-OVPN-4: errors reach the user.** FATAL, auth failure and missing passwords were silent until a 150 s deadline (c15d1ba).
  - Requirement: every terminal error produces a visible message via `fetchLastDisconnectError`.
- **Spike gate (before any OVPN UI work):** the real **Acme** and **Globex** profiles connect, CRV1 and SC work, a CBC-only server works, and tls-crypt-v2 works.

### Credentials
- **L-CRED-1: keychain location matters.** Writing as root landed items in the System keychain and caused an admin prompt on every connect. `SecItemUpdate` never moved them (e7bbed1, cbd05ce). Secrets were passed in `security` CLI argv. Text encodings mangled bytes. Synchronous keychain shell-outs froze the GUI.
  - Requirement:
    - store raw `Data` through the native API only, never on the main thread;
    - key items by a stable profile UUID, not the display name (a rename orphaned credentials, tunnel_ops.go);
    - the app owns the data-protection copy;
    - the extension owns its own copy, imported over XPC; the app never reads it. Draft 4 (DESIGN §6.3, Conflicts a): the **System keychain** is the primary store, because the 2021 sandbox violations (forum 672456) were fixed for NE system extensions in macOS 14 (FB11916222) and TN3137 names it the daemon keychain; sealed root-owned 0600 files in the extension's sandbox container stay as the tested fallback. Spike S4 runs both and picks one. Either way root ownership is the real boundary, admin users are out of scope, and our old admin-prompt bug came from the GUI process writing there as root, which the extension-only design avoids;
    - `passwordReference` written by the app is **not** readable from the extension (-25308).

### Menu bar
- **L-MB-1.**
  - Rate calculation: byte and time baselines must update together (0K/0K bug).
  - Use monospaced digits so the label width doesn't jitter (2d08dc8).
  - Rebuild the menu in `menuNeedsUpdate`, so states like ◐ don't go stale (f83384f).
  - Assign `statusItem.menu` natively, with no synthetic clicks; macOS 27 broke the event-monitor path (3f14acd).
  - The tray icon must disappear on quit (92a45b5).
  - Respect `isRemovalAllowed`/"Allow in the menu bar" (macOS 26).
  - The menu bar is 30 pt on Tahoe.

### Install, upgrade, extension lifecycle
- **L-EXT-1: one clear dialog, no retry loops.** Retries caused endless admin prompts (c9e9ffd, 8341d47).
  - Requirement: handle every `OSSystemExtensionRequest` result (needs approval, `.willCompleteAfterReboot`, failure) with one dialog that deep-links to System Settings › Login Items & Extensions.
- **L-EXT-2: activate on every launch.** The request is idempotent. `actionForReplacingExtension` returns `.replace`. Every release bumps **both** version keys, because a version check alone missed a stale binary (805a5fc). Every dev build changes `CFBundleVersion` (a build stamp); `CFBundleShortVersionString` stays the release value, which is enough because the replacement callback fires when **either** key differs (DESIGN §2.6).
- **L-EXT-3: replacement while connected** breaks XPC (FB17032197). Use a per-version `NEMachServiceName`, and stop the tunnel before replacing.
- **L-EXT-4: uninstall.** Trash doesn't remove system extensions.
  - Requirement: an in-app "Uninstall" removes the configurations, calls `deactivationRequest`, and deletes our keychain items.
- **L-EXT-5:** the extension has **no** AppKit dependency. The root helper crash-looped when it linked GUI frameworks (6330e74).
- **L-EXT-6: dev builds are Apple Development signed** (owner decision, draft 4). An ad-hoc NE won't load, as with the helper (8341d47). Developer ID dev builds would need notarization on every build, so dev uses Xcode automatic signing with the two development profiles (unsuffixed NE value) and SIP stays on. The XPC peer requirement in Debug (and FaultInjection) builds adds an Apple Development clause, compiled only under the target-level condition `LP_DEV_SIGNING`, never in Release, and needs Fable sign-off (DESIGN §5.3, Conflicts b). The debug loop:
  - log "first light" in `main.swift`;
  - Activate/Deactivate buttons in a debug menu;
  - after rebuilds, deactivate and reactivate.

### Updates, signing, distribution
- **L-UPD-1.** The custom updater silently failed its hash check for every non-brew user (installer.go). Asset matching missed "universal" (89747c0). Signatures weren't bound to the version, which allowed a downgrade (dd3b465). Redirect hosts weren't restricted (8f578a8). The release could ship unsigned ("grace mode").
  - Requirement: Sparkle 2 with EdDSA; refuse downgrades; re-activate the extension on the first launch after an update (the system keeps its own copy).
  - Test: an N-1 → N update end to end on every release.
- **L-DIST-1.**
  - The cask zip must contain the exact `.app` name.
  - Destructive cleanup (extension deactivation, keychain items) goes under `zap`, not `uninstall`; a plain `brew uninstall` only removes the app (DESIGN §12.2).
  - The old cask's `zap` deleted the new app's data (bb50f10). Audit **every** other cask's zap/uninstall when renaming.
  - Brew detection needs absolute paths, because Finder launches have no PATH (15b0d2a).
  - Set the cask to `auto_updates true`.
- **L-DIST-2.**
  - Check notarization credentials with `notarytool history`, not `security find-generic-password`.
  - Releases fail hard without the signing key.
  - Release signing is **inside-out** from an unsigned archive (`sign-inside-out.sh`), the primary path. Xcode ≤26 doesn't apply the `-systemextension` values when exporting (r. 108838909); an Xcode 27 fix is only forum-reported, so `xcodebuild -exportArchive` is at most a cross-check (DESIGN §12.4).

### Data migration
- **L-MIG-1.** Tunnels were lost on the wireguide-plus → lockplus rename (6a1c68c); the fix was copy-only migration plus a marker.
  - Requirement: the native app imports the Go app's tunnels (`~/Library/Application Support/lockplus/tunnels`) and keychain items by **copying**, never deleting. The Go app's final release uninstalls its helper, flushes its pf anchors and restores DNS.

### Security posture to keep
- Import caps: 500 zip entries, 10 MB per entry; no zip-slip (we never unpack to disk).
- Names validated before they touch any path.
- Exports opened `O_NOFOLLOW` at 0600.
- XPC listeners validate the peer's code signature, because the Mach service is global.
- A CSP-equivalent mindset: no web views unless needed. If CodeMirror is kept in a `WKWebView`, give it a strict CSP and no bridge to secrets.
- A mandatory Fable security review for extension, keychain, parser and XPC code; Opus for architecture; fix **every** finding.

## 4. Best-practices checklist (research, Oct 2026)

Pitfalls to avoid:
1. Relying on Xcode export for Developer ID NE apps: Xcode ≤ 26 doesn't apply the `-systemextension` values when exporting (r. 108838909, forum 737894). Sign inside-out.
2. A missing `-systemextension` suffix or profile on app **or** extension in a Developer ID build (development builds use the unsuffixed value).
3. Frameworks or rpaths only in the app bundle.
4. Expecting the data-protection keychain or `passwordReference` to work in the extension (the extension uses the System keychain or its sealed-file fallback).
5. A static `NEMachServiceName` combined with replacement while connected.
6. Not bumping both version keys.
7. Relying on Trash to uninstall.
8. Toggling `includeAllNetworks` while connected.
9. An update with the kill switch on leaves the Mac offline.
10. Calling `exit()` or `stopTunnel` from the provider; use `cancelTunnelWithError`.
11. No `reasserting` on wake or path change.
12. Split DNS without a `""` catch-all leaks.
13. Assuming SSID access without Location.
14. Re-registering the login item on every launch (undoes the user's choice).
15. Building on unmaintained wireguard-apple without a pinned fork.

Practices:
- Cache `NETunnelProviderManager`s; repeated `loadAllFromPreferences` leaves stale managers firing notifications.
- Use one manager per profile.
- Keep `providerConfiguration` small and free of secrets.
- Use XPC via `NEMachServiceName` (`NSXPCConnection(machServiceName:options:.privileged)`) for app ↔ extension; `sendProviderMessage` only for trivial calls. A nil reply means delivery failed.
- Set `excludeLocalNetworks`, `excludeAPNs`, `excludeCellularServices` and `excludeDeviceCommunication` explicitly.
- Use TN3165's compatibility list as a test matrix: AirDrop, Continuity, Internet Sharing, Xcode device debugging.
- Local Network privacy applies to the app if it probes LAN hosts, not to the root extension (TN3179).
- On-demand rules are evaluated by the system: prototype them with a configuration profile first.

## 5. Phased plan (about 92–122 developer-days after draft 4; draft 3 was 77–106, the original 65–95)

Owner prerequisites before P1 (DESIGN §18): the existing Developer ID Application certificate (backed up as `.p12`) and the G2 certificate requested on day 1; both App IDs with the NE and System Extension capabilities and the app group; both Developer ID provisioning profiles (the development ones come from Xcode); the `notarytool` keychain profile; macOS 26/27 VMs, which run notarized Developer ID builds only (no VM UDID registration). S1 probes Apple's page and a temporary host on the test VPS.

Owner prerequisites before P2a: the G2 certificate and the Developer ID profiles regenerated to list it (if S9 didn't use it, S9b runs on P2a day 1); the GitHub Pages feed host; ZIPFoundation approval. Before P2a ends: Fable sign-off of the dev requirement clause.

0. **Done in Go (v1.1.0):** dependency upgrades, security hardening, review fixes. The Go app stays the release line until parity.
1. **Spike (18–24 d, DESIGN §18 P1, including test-server infrastructure):** an openvpn3 `release/3.11.8` shim with OpenSSL 3.5 connecting Acme and Globex with CRV1/SC, plus WireGuardKit (forked, wireguard-go master) in one system extension; spikes S1, S2 (E1–E14), S4–S15, including the new S14 (build system) and S15 (AppKit/SwiftUI seams). Answer the open questions below. **Go/no-go for OpenVPN-in-NE.**
2. **WireGuard beta (30 d = DESIGN §18 P2a 8 + P2b 10 + P2c 12):**
   - Xcode project, four profiles, inside-out signing with the G2 certificate, extension activation, WG tunnel with the W0–W9 fork patches;
   - `includeAllNetworks`, `NEDNSSettings`, the app keychain and the S4-selected extension store;
   - importer from the Go app, notarization, DMG, a separate cask;
   - Sparkle 2.10.1 and the update-with-extension-replacement flow (moved here from phase 4, because the beta's N-1 → N update test needs it).
   - Coexistence: refuse to connect while the Go helper's pf anchor is loaded.
3. **OpenVPN (22–32 d, DESIGN §18 P3):** shim hardening, the auth UI (password, SC, CRV1; prompts before the start or the two-start flow, because NE ends a start after 60 s), the profile allowlist port, a corpus test of the real profiles, an "unsupported directive" report at import.
4. **UI parity (16–25 d, DESIGN §18 P4; Sparkle moved to phase 2):**
   - menu bar states and rates, tunnel list and detail with the derived-state table, editor with capture hygiene;
   - stats (Swift Charts), history, logs (`OSLog`), export/export-all;
   - on-demand Wi-Fi rules, settings, notifications, pasteboard privacy, onboarding;
   - String Catalogs (en/de/ko/ja);
   - `SMAppService.mainApp`, in-app Uninstall.
5. **Cutover (6–11 d, DESIGN §18 P5):** the Go app's final release runs its uninstaller (helper, pf, DNS). The native app becomes the `lockplus` cask; the old cask is retired. Operations and legal artifacts are published (DESIGN §22: `SECURITY.md`, `security.txt`, private vulnerability reporting, privacy notice, support period, export-control and CRA statements).

## 6. Open questions for the spike

1. Does `ssidMatch` work without Location on macOS 26/27?
2. How do `includeAllNetworks` and the exclude flags behave on macOS 26/27: for AirDrop, Xcode device debugging and Sparkle while blocked, and does traffic stay blocked after provider `kill -9`, `stopVPNTunnel` and `cancelTunnelWithError`? Does it break the provider's own TCP connects, such as OpenVPN over TCP (DESIGN §10.1.1)? Draft 4 adds E10 (provider DNS for hostname endpoints under the flag), E11 (settings-level flags: `API_UNAVAILABLE(macos)` in SDK 27.0, so never set), E12 (`NWPathMonitor` inside the provider) and E13 (cross-user manager visibility). Draft 5 adds E14: traffic while `.connecting`, how long NE lets a start stay pending, and what a failed first connect does with the kill switch and on-demand on. Draft 6: the start limit is expected to be ~60 s, then 20 s in Stopping (forum 731820, iOS 16.5+); E14b measures it on macOS (50 s / 70 s / 5 min), so the design fails the start with a start latch and never waits for the user inside a start.
3. ~~Does `NEDNSOverHTTPSSettings` inside tunnel network settings work on macOS?~~ Deferred: DoH/DoT is cut from v2.0 (DESIGN §21).
4. Extension secret storage: does the System keychain work from the sandboxed extension across replacement without prompts (primary), and do root-owned container files with a CryptoKit Secure Enclave wrap of their file key work as the fallback (forum 804612)? S4 tests both and picks one.
5. Is `sendProviderMessage` enough, or is XPC required? Does the per-version Mach name have side effects?
6. Does the extension's root context get the TN3179 exemption?
7. Can WireGuardKit (Go runtime) and openvpn3 (asio + OpenSSL) coexist in one extension process?
8. Do openvpn3 CRV1 and static-challenge flows work through our shim, including CRV1 answered in a second `startTunnel` with a new client (DESIGN draft 6, §8.4)?
9. Do inside-out-signed Developer ID builds (the existing certificate in P1; G2 in S9 or S9b) pass `codesign -R`, notarization and activation on 26 and 27? (Inside-out signing is primary; whether an Xcode 27 export also works is a cross-check only.)
10. Does a Sparkle update correctly replace the extension while connected and while the kill switch is on?

## 7. Process rules carried over

- One version source, enforced in CI. A drift between `fallbackVersion` and Info.plist caused an infinite reinstall loop.
- Every security toggle gets a **behavioral** test. Three features shipped as silent no-ops: the pf anchor, OVPN auto-reconnect, and the updater hash gate.
- Review by lens:
  - Sonnet first pass;
  - Opus architecture and full review;
  - Fable mandatory security pass on extension, keychain, parsers and XPC.
  - Fix all findings.
- Never hand-run code generators with guessed flags, and never keep build patches in `/tmp`; vendor them in the repo.
- Release:
  - confirm scope on a bare "deploy";
  - confirm every push separately;
  - run an N-1 → N upgrade test with real data;
  - check notarization with `notarytool history`;
  - build, sign, notarize and EdDSA-sign releases only on the dev Mac from a fresh clone of the signed tag; CI only builds and tests and holds no signing material (DESIGN §12.4).
- Debugging: a silent gap in the extension log during a reported freeze points at the app process. Cross-check rates against `netstat -ibn`.

## Sources

Apple:
- WWDC25 session 234: https://developer.apple.com/videos/play/wwdc2025/234/
- TN3165, pf is not API: https://developer.apple.com/documentation/technotes/tn3165-packet-filter-is-not-api
- TN3134, NE provider deployment: https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment
- TN3179, Local Network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy

Apple Developer Forums:
- Developer ID NE export / `-systemextension` suffix: https://developer.apple.com/forums/thread/737894
- Packaging, XPC, app groups: https://developer.apple.com/forums/thread/800887
- XPC breaks after replacement while connected (FB17032197): https://developer.apple.com/forums/thread/779395
- System keychain hand-off pattern: https://developer.apple.com/forums/thread/680013
- Sysex keychain limits (2021 sandbox violations on the System keychain, fixed for NE sysex in macOS 14, FB11916222): https://developer.apple.com/forums/thread/672456, https://developer.apple.com/forums/thread/824202
- Component references with verified corrections (networkextension, wireguard, openvpn3, security, xpc, sparkle, swiftui-appkit, toolchain, swift-concurrency): `docs/native/reference/`
- No supported partition-list API: https://developer.apple.com/forums/thread/98182
- Secure Enclave keys from daemons via CryptoKit: https://developer.apple.com/forums/thread/804612
- XPC code-signing requirement enforced on the first message: https://developer.apple.com/forums/thread/760287
- `passwordReference` not readable in the extension: https://developer.apple.com/forums/thread/672748
- Stopping vs. cancelling the tunnel: https://developer.apple.com/forums/thread/772393
- Sleep/wake: https://developer.apple.com/forums/thread/95988
- Toggling `includeAllNetworks`: https://developer.apple.com/forums/thread/731793
- On-demand rules and SSID: https://developer.apple.com/forums/thread/813746
- Menu bar visibility (macOS 26): https://developer.apple.com/forums/thread/788101
- Extension debugging: https://developer.apple.com/forums/thread/725805
- Extension after a Sparkle update: https://developer.apple.com/forums/thread/732624

Other:
- System extension deletion: https://obdev.at/blog/deletion-impossible-2
- Tailscale macOS variants: https://tailscale.com/kb/1065/macos-variants
- OpenVPN Connect and NE: https://openvpn.net/connect-docs/macos-network-extension.html
- openvpn3 licence: https://raw.githubusercontent.com/OpenVPN/openvpn3/master/LICENSE.md
- wireguard-apple history: https://git.zx2c4.com/wireguard-apple/log/
- Partout (GPL, architecture reference only): https://github.com/partout-io/partout
- Mullvad on `includeAllNetworks`: https://cyberinsider.com/mullvad-vpn-explains-why-it-holds-back-key-ios-privacy-feature/
- Privacy Guides, macOS VPN expectations: https://discuss.privacyguides.net/t/what-should-we-require-of-vpn-providers-on-macos/36175
