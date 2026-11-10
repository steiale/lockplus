# Fable security re-check: import report fixes (`b418aba6`)

Security re-check of b418aba6 (read-only). Verdict: clean on the security-relevant points; one LOW (fail-safe gap in a sub-switch) and a few NITs. No HIGH/MEDIUM.

## Findings

**LOW-1 — `allow-compression <unknown value>` is classified harmless (fail-safe gap)**
native/Packages/LockPlusCore/Sources/LPParsing/OpenVPN/OVPNNormalizer.swift:82-86
```swift
case "allow-compression":
    switch args.first {
    case nil, "no": .compressionNotEnforced
    default: .compressionPolicyManaged      // ← harmless is the default branch
    }
```
Scenario: `allow-compression NO`, `allow-compression none`, `allow-compression no extra` → `.compressionPolicyManaged` (green, "LockPlus decides compression itself"). OpenVPN 2.6 options.c rejects any value other than exactly `yes|no|asym` (`goto err`), so nothing is lost functionally, but the commit's own rule is "unreviewed → not applied", and here the catch-all is the harmless branch. The new test only probes `[]`, `no`, `asym`, `yes`, so this isn't caught.
Fix: invert — `case "yes", "asym": .compressionPolicyManaged; default: .compressionNotEnforced` — and add `#expect(!ignoredReason("allow-compression", args: ["NO"]).isHarmlessWhenIgnored)` to `allowCompressionNoOrBareIsNotApplied_asymAndYesAreHarmless`.

**NIT-1 — comment claims bare `allow-compression` "means `no` in 2.x"** (OVPNNormalizer.swift:80-81)
Verified against release/2.6 options.c: the parse condition is `streq(p[0],"allow-compression") && p[1] && !p[2]`; a bare directive falls to "Unrecognized option or missing or extra parameter(s)". The not-applied classification is still the right conservative choice; only the comment is wrong.

**NIT-2 — comment "the engine and the appended mssfix floor decide" is inaccurate for `link-mtu`** (OVPNNormalizer.swift:92 vs :390)
When `link-mtu` is present the floor is NOT appended (line 390 excludes it) and `link-mtu` itself is dropped. What actually applies is openvpn3's own default: `mssparms.hpp:75 mssfix_default = true` → `proto.hpp:689` sets mssfix 1492 (or tun-mtu). So harmless still holds (an MSS clamp is always active; NE MTU comes from `NetworkSettingsBuilder` `policy.mtuOverride ?? plan.mtu ?? 1420`), but the stated reason is wrong. Optional follow-up (behaviour change, out of this commit's scope): drop `link-mtu` from the floor condition since it never reaches the engine.

**NIT-3 — `.cipherListNotApplied` text slightly overclaims** (ImportReport.swift:301, ImportSheets.swift:184, DE in xcstrings)
"LockPlus negotiates AES-GCM or ChaCha20 itself": with `cipher AES-256-CBC` the normalizer sets `enableNonPreferredDCAlgorithms`,, so CBC can be negotiated. The separate `.legacyCBCEncryption` warning covers the security side. Suggest "LockPlus's engine negotiates the cipher itself" (DE: "die Engine von LockPlus handelt die Verschlüsselung selbst aus").

**NIT-4 — xcstrings comment drift**: "Not supported" exists with comment "Batch item"; the new `sectionTitle` uses comment "Copy Report heading". Same key/same German, so no functional effect, but the next Xcode string extraction will rewrite the catalogue (dirty working tree).

**NIT-5 — test uses `!`/`[1]`** (EngineSupportGenerator.swift:211-212): a regression would crash the test process instead of failing one test. Use `try #require(t.range(of:))`.

## Verification results

**(1) Harmless set — each checked against LockPlus/openvpn3:**
- link-mtu / tun-mtu-extra / mtu-disc: all `ignoredWarn` in cliopt.hpp; NE MTU is set by `NetworkSettingsBuilder` (1420 default / tun-mtu via plan.mtu); engine default mssfix always active. Harmless (see NIT-2 for the comment).
- route-delay / allow-pull-fqdn / allow-recursive-routing: NE applies routes atomically, routes carry no gateway, server exclusion route is LockPlus's. Ignoring is neutral/stricter. (allow-pull-fqdn: if a server pushes an FQDN route openvpn3 throws `tun_prop_route_error` → visible connect failure, not a silent weakening.)
- disable-occ / disable-dco: userspace engine, no DCO on macOS, OCC mismatch only logged. Harmless.
- tun-ipv6: no-op since 2.4, `ignoredSilent`. Harmless.
- tls-version-max: cap only; OpenSSL 3.5 default max applies; `tls-version-min` is mapped. Harmless.
- ping-exit: `dropped`; LockPlus reconnects instead of exiting — the more-connected behaviour under its kill switch. Harmless.
- route-gateway: dropped from canonical text (never reaches openvpn3's tunprop.hpp:245); NE routes have no gateway and literal `route` gateways are rewritten to `vpn_gateway`. Harmless.
- allow-compression yes/asym: shim `compressionMode = "asym"` (OpenVPNClientShim.swift:74) → `CompressContext(meth, asym=true)` (proto.hpp:659/917): never compresses uplink, decompresses downlink. `yes` in 2.x permits uplink compression (the VORACLE side), so asym is strictly no less safe than what the user asked for; LZO/LZ4 framing is per-packet so an uncompressed uplink interoperates with any server. `asym` is identical. The `.compressionEnabled` warning still fires whenever `comp-lzo`/`compress` enable compression. Harmless is correct. `no` → not-applied is correct; note openvpn3 even in mode "no" degrades to asym on a pushed compressor (proto.hpp:921-927), so "no" is unenforceable in this engine regardless.
- data-ciphers / ncp-ciphers / data-ciphers-fallback, reneg-bytes / reneg-pkts / replay-window: correctly not-applied (openvpn3 honours only reneg-sec, proto.hpp:1247; replay window is a compile-time constant, packet_id_control.hpp:176-182).

**(2) Fail-safe:** `ignoredReason` default → `.engineIgnores`; `isHarmlessWhenIgnored` default → false; `.engineIgnores` removed from the harmless list; `isNotApplied = ignored && !harmless` so every ignored item lands in exactly one plainText section. Only gap: LOW-1.

**(3) Tests:** ran `swift test --filter EngineSupportTests` in LockPlusCore (scratch under <build dir>) — 8/8 pass incl. the 4 new ones. They do enforce the properties: re-adding `.engineIgnores` to the harmless set, adding an unclassified table key, or making `allow-compression no` harmless each fails an `#expect`. `everyIgnoredReasonTextIsDefined`: LockPlusTests is app-hosted (native/Config/AppTests.xcconfig: `TEST_HOST = …/LockPlus.app/Contents/MacOS/LockPlus`), so `Bundle.main` is the app and `de.lproj` exists; sentinel + `value != key` make it fail on a missing or untranslated string. The 9 new reasons are all in the test's list.

**(4) Strings:** EN/DE accurate and matched; "du" form consistent with the catalogue (68 du-forms vs 1 Sie). `peer-fingerprint` advice is valid (mapped; openvpn/ssl/peer_fingerprint.hpp). Only NIT-3 overclaims slightly.

**(5) No behaviour change beyond display:** `ignoredReason` gained an `args` parameter used only for allow-compression; ignored/dropped still `continue` before emission; canonical text, `present`, floors, security warnings untouched. `.wgSemicolonLineSkipped` is a `.note` item (WGConfig.swift:121), so its removal from the harmless set is a no-op. Downstream effects (ImportVerdict → importedWithWarnings, GoAppMigrator "needs attention", batch amber icon) for data-ciphers/reneg-*/allow-compression-no profiles are display/triage only — no import is blocked, nothing parsed or enforced differently.

Files: native/Packages/LockPlusCore/Sources/LPParsing/OpenVPN/OVPNNormalizer.swift, native/Packages/LockPlusCore/Sources/LPModel/ImportReport.swift, native/Packages/LockPlusCore/Tests/LPParsingTests/EngineSupportGenerator.swift, native/App/UI/Sheets/ImportSheets.swift, native/App/UI/Localizable.xcstrings, native/Tests/LockPlusTests/OwnerTest1UITests.swift.

---

**Fixes** (`00e48b55`, `66e6eff0`): only `allow-compression yes` and `asym` are harmless, any other value is "not applied" (tested with unreviewed values); comments for bare `allow-compression` and `link-mtu` corrected; the cipher-list text says the engine negotiates the cipher itself; the tests use `#require`; the shared catalogue key has one comment.
