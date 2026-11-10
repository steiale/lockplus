# Fable security review — native code at 79cc980 (2026-10-26)

Read-only review. The verdict on the dev requirement clause (`Shared/ActiveRequirements.swift:10`): **sound and Release-excluded. Signed off.** Optional tightening: add `and certificate leaf[field.1.2.840.113635.100.6.1.12]` to the dev branch.

## Findings (fix ALL)

### H1: cross-user profile substitution / provision DoS via UUID squatting
- **Where:**
  - `TunnelEngine/Controller/TunnelController.swift:201-212`: start loads the payload by UUID and never compares `entry.ownerUID` with `cfg.ownerUID`.
  - `Service/EngineServiceBackend.swift:117-124`: the first uid to provision a UUID owns it.
- **Scenario:** user B learns A's UUIDs (keychain attributes and NE prefs are world-readable), then provisions A's UUID with B's payload. A gets `.notOwner` forever, and A's tunnel can terminate at B's server.
- **Fix:**
  1. `runStarting` requires `entry.ownerUID == cfg.ownerUID`, else `.profileNotProvisioned`.
  2. Namespace the store by uid (account `"\(uid)/\(uuid)"` or a per-uid service).
  3. Test: mallory provisions alice's UUID first.

### M1: `recentLogs` / `setLogLevel` are not uid-scoped
`EngineServiceBackend.swift:73-78, 83-86`. Another uid reads A's openvpn3/wg log lines and raises the log level; `OVPNLogRedactor` is only a substring filter. **Fix:** drop both from the v2.0 XPC surface and deliver logs via the owner's diagnostics bundle (preferred), or tag lines with ownerUID and filter.

### M2: `tunnelSnapshot` discloses the running session to any profile owner
`TunnelController.swift:829-838`. **Fix:** if the running session's profile ≠ the requested one, return the requested profile's latch/lastError and a detail-free phase only.

### M3: the client hello gate can send a secret-bearing call on a fresh, unvalidated connection
`LPXPCClient/TunnelServiceClient.swift:226-233, 250-253, 263-265`. An invalidation between hello and send makes `currentConnection()` create a new connection. **Fix:** non-hello sends use only the hello-validated connection (`guard let c = connection, helloTask != nil, !interruptedSinceHello`) and never call `currentConnection()`. Test: invalidate between hello and the call.

### M4: pushed excluded routes are unbounded (traffic bypass with the kill switch off)
`OpenVPN3Shim/core/ovpn_core.cpp:117-121`, `OpenVPNClientShim.swift:152-153`, `Plan/NetworkPlan.swift:66-81`, `NetworkSettingsBuilder.swift:43-44,57`. A server pushes `route 0.0.0.0 128.0.0.0 net_gateway` + `128.0.0.0/1`, so everything bypasses the tunnel while the UI shows "Protected". **Fix:** accept pushed excluded routes only if the profile itself declares that `net_gateway` route; otherwise reject any excluded route shorter than /16 on a full tunnel with `.pushedOptionRejected`. Document in §8.5. Also apply or delete the unused `RedirectGateway.flags`/`blocksLocal`.

### L1: `wipeAllSecrets` clears every uid's start latches
`TunnelController.swift:975-977`. **Fix:** latches carry ownerUID; clear only the caller's.

### L2: credential records are re-written with an owner taken from `providerConfiguration`
`TunnelController.swift:344-353, 940-947`. **Fix:** take the owner from the existing index entry; the NE config's ownerUID is only a hint.

### L3: PacketFlowPump traps on an empty packet
`DataPlane/PacketFlowPump.swift:109-112`. **Fix:** `guard !p.isEmpty else { continue }`.

### L4: provision index metadata lives in world-readable keychain attributes
`Secrets/SystemKeychainSecretStore.swift:35-37, 40-48`: UUID, ownerUID and payload digest. **Fix:** keep the index inside `kSecValueData`, or HMAC the digest with a per-install key, and use random account names.

### L5: openvpn3's raw `eval_config` message goes into `LPTunnelError.detail`
`Tunnel/OpenVPN3ShimClient.swift:27-29`. **Fix:** use `category()` truncation as in `PayloadValidation.swift:109-113`.

### L6: in-flight handlers per connection are unbounded
`XPC/TunnelServiceListener.swift:139-148`. **Fix:** cap in-flight requests per connection (e.g. 8 → `.extensionBusy`).

### L7: the DESIGN §12.4 CI jobs are missing
- `engine-support` regeneration + diff.
- The `_execv*`/MacTun symbol and strings grep, enforcing the PENDING-FOLD 29 `_execve`-only-from-libwg-go rule.
- `fuzz-smoke`.
- `check-symbols.sh` checks duplicates only.

### Nits
- `Controller/StartRequest.swift:17-23`: `lp.manual` is never checked.
- `Adapters/WireGuard/WireGuardBackend.swift:98-121`: `WGUAPI.build` grows a `[UInt8]` and leaves unzeroed copies of the hex keys. Size it first.
- `OpenVPNAdapter.swift:324`: the CRV1 cookie arrives as a `String`. Residual like PENDING-FOLD 34; document it.
- `OpenVPN3Shim.mm:28 evaluateProfile:(NSString*)` and `OpenVPN3Options.mm parseProfile:(NSString*)` take key-bearing text as NSString. Move [6] to bytes, or document.
- `Host/ProviderHost.swift:41-46` / `Tunnel/EngineAssembly.swift:68-72`: make `apply` non-optional and delete the nil branch.
- `verify.sh static:38-43`: `-showBuildSettings` without `-xcconfig`. Note that the `strings` grep is the real backstop.
- CI cache of `Vendor/build`: add `shasum libOpenSSL.a` to the stamp.

### Simplifications (attack-surface reduction)
1. Namespace the store by uid (H1).
2. Drop `recentLogs`/`setLogLevel` from XPC (M1).
3. Remove the `wgGetConfig`/`wgSetConfig` exports (unused upstream-adapter surface) and adjust `WG_EXPORT_COUNT`.
4. Make `ProviderHost.apply` non-optional.
5. Fold `TunnelServiceRouter.validateProfile` into `EngineServiceBackend`.
6. Remove the NSString shim entry points.

### Not verified
- Runtime `setConnectionCodeSigningRequirement` behaviour with macOS 27 dual signatures.
- Whether NE honours `excludedRoutes` under `includeAllNetworks`.
- openvpn3's `net_gateway` pull path.
- The app-side credential flow, which isn't implemented yet.
