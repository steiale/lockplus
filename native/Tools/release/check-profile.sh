#!/bin/zsh
# Required gate before signing (DESIGN §2.7, ref/toolchain §4.3): notarization ACCEPTS a bundle whose restricted NE
# entitlements have no profile, and it then fails to launch (AMFI, POSIX 163). Checks: App ID, ProvisionsAllDevices
# (Developer ID), the -systemextension NE value, expiry > 1 year, and that it lists the keychain identity's certificate (SHA-1).
# Usage: check-profile.sh <profile> <bundle-id>
set -euo pipefail
source "${0:A:h}/common.sh"
P=${1:?usage: check-profile.sh <profile> <bundle-id>}; ID=${2:?bundle id}
[[ -f "$P" ]] || fail "no profile at $P (run native/scripts/provision-product.sh from Terminal.app)"
T="$LP_BUILD_ROOT/profile-check"; rm -rf "$T"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
security cms -D -i "$P" -o "$T/p.plist" 2>/dev/null || fail "$P: not a CMS-signed profile"
PB() { /usr/libexec/PlistBuddy -c "Print :$1" "$T/p.plist" 2>/dev/null; }
[[ "$(PB Entitlements:com.apple.application-identifier)" == "$TEAM.$ID" ]] || fail "$P: App ID is $(PB Entitlements:com.apple.application-identifier), want $TEAM.$ID"
[[ "$(PB ProvisionsAllDevices)" == true ]] || fail "$P: not a Developer ID profile (no ProvisionsAllDevices)"
# Capture, then test: `cmd | grep -q` under pipefail can fail on SIGPIPE.
NE=$(PB Entitlements:com.apple.developer.networking.networkextension || true)
grep -q 'packet-tunnel-provider-systemextension' <<<"$NE" \
  || fail "$P: NE entitlement lacks packet-tunnel-provider-systemextension"
if [[ "$ID" == "$APP_ID" ]]; then
  SEI=$(PB Entitlements:com.apple.developer.system-extension.install || true)
  [[ "$SEI" == true ]] || fail "$P: no system-extension.install"
fi
EXP=$(plutil -extract ExpirationDate raw -o - "$T/p.plist")
(( $(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$EXP" +%s) > $(date +%s) + 365*86400 )) || fail "$P: expires $EXP (< 1 year)"
# Match by certificate hash, not by name: two Developer ID certificates of one team share the subject, and a profile
# that lists the other one passes a name check, is accepted by notarization and fails to launch (2026-10-27).
IDS=$(security find-identity -v -p codesigning)
KEYS=$(awk -v id="\"$IDENTITY\"" 'index($0, id) {print $2}' <<<"$IDS")
[[ -n "$KEYS" ]] || fail "identity not in keychain: $IDENTITY"
(( $(wc -l <<<"$KEYS") == 1 )) || fail "more than one keychain identity named \"$IDENTITY\": codesign -s by name is ambiguous"
found=0; listed=(); i=0
while plutil -extract "DeveloperCertificates.$i" raw -o - "$T/p.plist" > "$T/c.b64" 2>/dev/null; do
  base64 -D -i "$T/c.b64" -o "$T/c.cer"
  sha=$(shasum -a 1 "$T/c.cer" | awk '{print toupper($1)}')
  ser=$(openssl x509 -inform der -in "$T/c.cer" -noout -serial 2>/dev/null || true)
  listed+=("${ser#serial=} ($sha)")
  [[ "$sha" == "$KEYS" ]] && found=1
  i=$((i + 1))
done
(( found )) || fail "$P: lists ${listed[*]:-no certificate}, but the keychain identity \"$IDENTITY\" is $KEYS (regenerate the profile with that certificate)"
ok "$ID: $(PB Name), expires $EXP"
