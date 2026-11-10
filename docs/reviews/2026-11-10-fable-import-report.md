# Fable security review: import report classification (`f2e0e35c`)

Security review of f2e0e35c (import report: harmless vs not-applied). Read-only; nothing edited, nothing run.

## Findings

### MEDIUM — the normalizer's fallback reason `.engineIgnores` is classified harmless, so the pipeline defaults to "not needed" for any ignored directive without an explicit reason
- `native/Packages/LockPlusCore/Sources/LPModel/ImportReport.swift:200-204` lists `.engineIgnores` among `isHarmlessWhenIgnored == true`.
- `native/Packages/LockPlusCore/Sources/LPParsing/OpenVPN/OVPNNormalizer.swift:70` — `ignoredReason(_:)` has `default: .engineIgnores`. Every `.ignoredWarn/.ignoredSilent/.dropped` directive in the GENERATED table (`OVPNEngineSupport.generated.swift`) that is not named in lines 54-69 lands here.
- Today that is 13 directives: allow-pull-fqdn, allow-recursive-routing, disable-dco, disable-occ, link-mtu, mtu-disc, **reneg-bytes** (:100), **reneg-pkts** (:101), **replay-window** (:103), route-delay, tls-version-max, tun-ipv6, tun-mtu-extra.
- Scenario: a hardened profile with `reneg-bytes 100000000` / `reneg-pkts 100000` / `replay-window 32 5` imports with verdict `.imported` (green), and the sheet/detail says "N directives not needed — Nothing to do: the profile works as it is." The user's data-channel rekey thresholds and replay window are not applied (openvpn3 only honours `reneg-sec` and its own fixed replay window). Degraded, not absent, hence MEDIUM not HIGH — but the structural problem is that the table is regenerated per openvpn3 release, and any directive that moves to "ignored with warning" in a future table (e.g. a TLS verification option) would silently become "not needed". This is exactly the Q3 property the commit gets right in `isHarmlessWhenIgnored` (`default: false`) but loses one layer up.
- Fix (either): (a) remove `.engineIgnores` from the harmless set — the 13 then show amber "not applied: not used by LockPlus's OpenVPN engine", which is honest; or (b) keep it harmless but make `ignoredReason` exhaustive: add a test in `EngineSupportTests` asserting every `.ignoredWarn/.ignoredSilent/.dropped` key in `OVPNEngineSupport.table` maps to a non-`.engineIgnores` reason, and give reneg-bytes/reneg-pkts/replay-window a not-applied reason (e.g. `.cryptoTuningNotApplied`, text "rekey/replay tuning isn't applied; LockPlus uses the engine's defaults"). (b) is the smaller UX change; (a) is the safer default.

### LOW — `allow-compression` is harmless, but LockPlus relaxes an explicit `allow-compression no`
- `OVPNNormalizer.swift:67` → `.compressionPolicyManaged` (harmless); `native/Packages/TunnelEngine/Sources/TunnelEngine/Adapters/OpenVPN/OpenVPNClientShim.swift:74` fixes `compressionMode = "asym"`.
- Scenario: profile has `allow-compression no` (OpenVPN 2.5+ hardening: refuse even server-pushed compression) and no comp directive, so no `.compressionEnabled` warning fires. LockPlus runs asym: a server push of `compress lz4` is accepted for the downlink. Report says "LockPlus decides compression itself — nothing to do". VORACLE needs client-side compression so the practical risk is small, but the user asked for stricter and got looser without a warning.
- Fix: `ignoredReason` currently gets only the name; pass `c.args` and classify `allow-compression no` (and `allow-compression` with no arg, which also means no in 2.x) as not-applied with text "LockPlus decompresses server data (asym); `no` isn't enforced". `allow-compression asym` stays harmless.

### LOW — `data-ciphers` / `ncp-ciphers` / `data-ciphers-fallback` as "ciphers are negotiated automatically"
- `OVPNNormalizer.swift:58`. The user's cipher allowlist is not enforced; openvpn3 negotiates from its own list. Outcome is still AEAD (CBC only if `cipher` is CBC, which already triggers `.legacyCBCEncryption`), so fail-safe in practice, but "not needed" overstates it for a user who pinned e.g. `data-ciphers AES-256-GCM`. Consider "not applied: LockPlus's engine negotiates AES-GCM/ChaCha20 itself" as a not-applied reason, or leave and document. Judgement call.

### NIT — misleading reason text for `ping-exit` and `route-gateway`
- `OVPNNormalizer.swift:63` maps `ping-exit` and `route-gateway` to `.setByServer` ("set by the server"). Both are legitimate client-side options in OpenVPN 2.x (`--ping-exit n`, `--route-gateway gw`). Behaviour is harmless (LockPlus appends its own ping/ping-restart floor; routes are rewritten to `vpn_gateway`), but the explanation is wrong. Give them `.engineIgnores`-style wording or a dedicated reason.

### NIT — "Copy Report" still merges both groups
- `ImportReport.swift:70-84` `plainText` groups by `ImportReportGroup` only: not-applied and not-needed are both printed under "Will be ignored". A user pasting the report to an admin loses the amber distinction the UI now makes. Split the `.ignored` group in `plainText` into "Not applied" / "Not needed".

### NIT — dead harmless entry
- `.wgSemicolonLineSkipped` is in the harmless set (`ImportReport.swift:202`) but `WGConfig.swift:121` emits it as `.note`, never `.ignored`, so `isHarmlessIgnored` is never true for it; the test `everyIgnoredReasonTextIsDefined` also lists it as an ignored reason. Remove from the set or emit as `.ignored` consistently.

### NIT — `verify-hash` copy
- "not supported; the certificate chain is still verified" is accurate but could point users to the supported replacement: `peer-fingerprint` is `.mapped` (generated table :73) and suppresses `.serverIdentityNotPinned`. Suggest "…use `peer-fingerprint` to pin the server".

## Answers to the questions

1. Per-reason audit of the harmless set: `.loggingManaged` (verb/mute/mute-replay-warnings), `.reconnectManaged` (resolv-retry/connect-retry*/connect-timeout/explicit-exit-notify/auth-retry), `.persistenceNotNeeded`, `.localBindingNotUsed` (nobind/bind/lport/local/sndbuf/rcvbuf/fast-io/socket-flags), `.windowsOnly` (incl. `block-outside-dns` — OpenVPN 2.x on macOS ignores it too, and LockPlus sets `matchDomains [""]` for full tunnels / `dnsMode == .tunnelOnly`, `NetworkSettingsBuilder.swift:89-90`), `.unixAccountNotUsed`, `.serverOnlyOption` (dh), `.dnsManagedByLockPlus` (only `dns-updown disable` passes the allowlist), `.keepaliveTakesPrecedence`, `.legacyProvidersNeverLoaded` (fail-closed), `.pingTimerRemNotNeeded`, `.setByServer` (topology/route-gateway/route-ipv6-gateway/ping-exit — harmless, wording NIT above): all genuinely harmless. Not harmless: `.engineIgnores` (MEDIUM), `.compressionPolicyManaged` for `no` (LOW), `.cipherNegotiationAutomatic` (LOW/judgement). Correctly NOT harmless: `.scriptsNeverRun`, `.verifyHashNotSupported`, `.webSignInNotSupported`, `.wgHookNeverRun`, `.wgSettingNotApplied` (Table/FwMark/SaveConfig), `.wgUnknownKeyPreserved`. TLS/cert verification directives (remote-cert-tls/ku/eku, verify-x509-name, ns-cert-type, tls-auth/crypt/crypt-v2, peer-fingerprint, tls-version-min, tls-cipher/ciphersuites, crl-verify), auth-user-pass, pull-filter, route-nopull, redirect-gateway, reneg-sec, WG PrivateKey/PresharedKey/MTU/DNS/AllowedIPs/Endpoint/PersistentKeepalive are all `.mapped`/applied, never in the ignored group. Script directives (up/down/route-up/tls-verify/ipchange/client-connect/plugin/…) are not on the allowlist → `.forbidden` → `.notSupported` → import rejected; the test's `up`→`.scriptsNeverRun` is synthetic only.

2. Verdict downgrade: every consumer of `verdict` gates on `!= .rejected` only (`ImportCoordinator.swift:119-130,249`, `GoAppMigrator.swift:102,414-422`, `EditorModel.swift:301,368`, `OVPNImporter.swift:137`, `WGImporter.swift:82`, `GoAppMigration.swift:319`). The only `.importedWithWarnings` consumer is the batch row icon (`ImportSheets.swift:279`), which is the intended UX change. `hasWarnings` has zero callers in App/Packages (dead API). `GoAppMigrator.classify` (`:272-283`) uses `isNotApplied`/`isHarmlessIgnored`, the same set as the deleted `harmlessIgnored` — no migration behaviour change; `ProfilesStore.verifyPending` switches on the engine verdict, not the import verdict. Nothing hidden, no connect gating keyed on warnings.

3. Switch defaults: `isHarmlessWhenIgnored` → `default: false` (safe); `localizedMessage` is now exhaustive (compile-time). The unsafe default is upstream in `OVPNNormalizer.ignoredReason` (MEDIUM above).

4. Enforcement vs display: the commit touches no LPParsing/Tunnel code (stat confirms). Classification is a computed property on the persisted `reason`, so previously imported profiles are re-grouped consistently on display. Pure display change.

5. Other: `vpnConfigurationExists = !env.managers.managers.isEmpty` (`UIBinder.swift:226`) is backed by `ManagerStore.byID`, which is filtered to our `providerBundleIdentifier` and this uid (strays excluded, `ManagerStore.swift:174-184`) — correct source; only drives onboarding copy; before `loadAll` completes it is false and the hint shows "macOS asks", which is benign. Onboarding copy changes, ForEach-by-offset, PreviewFixtures, localisation test: clean.

## Checked and clean
- All `.mapped` security directives listed in Q1 above are applied, not ignored.
- Script/plugin directives rejected via allowlist, never "ignored".
- `setenv IV_SSO` → not harmless; safe `setenv` names allowlisted.
- `verdict`/`hasWarnings` consumers (none change gating); migrator concern/info sets unchanged.
- WG ignored emission (`WGConfig.swift:175-197,220-222`) all non-harmless; WG keys/PSK/MTU/DNS/AllowedIPs applied.
- DNS enforcement (`NetworkSettingsBuilder.swift:83-101`) supports the "DNS managed by LockPlus" claim for full tunnels and tunnel-only mode.
- `vpnConfigurationExists` source and scope; onboarding step-3/step-4 branches.
- No parser/enforcement changes in the diff.

---

**Fixes** (`b418aba6`): engine-ignored options without an explicit reason now fail safe to "not applied"; reneg-bytes, reneg-pkts and replay-window, the cipher list and `allow-compression no` are reported as not applied; every ignored option in the engine table has an explicit reason (tested); the copied report separates "Not applied" and "Not needed"; the verify-hash text points to `peer-fingerprint`. Re-checked below.
