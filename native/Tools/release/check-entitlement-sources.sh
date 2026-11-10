#!/bin/zsh
# CI: the development entitlement sources and the golden Release files differ ONLY by the NE -systemextension suffix
# and the two profile-derived identity keys (DESIGN §2.4, §12.4). Also the static golden-file rules (ref/toolchain §3.5).
set -euo pipefail
source "${0:A:h}/common.sh"
for n in LockPlus LockPlusTunnel; do
  src="$SRC_ENT/$n.entitlements"; gold="$GOLD/$n.entitlements"
  for f in "$src" "$gold"; do
    plutil -lint "$f" >/dev/null || fail "$f: plutil -lint"
    [[ "$(head -c 5 "$f")" == '<?xml' ]] || fail "$f: not XML (or has a BOM)"
    ! grep -q $'\r' "$f" || fail "$f: CRLF"
    ! grep -q '<false/>' "$f" || fail "$f: <false/> entitlement"
    ! grep -q 'com.apple.security.get-task-allow' "$f" || fail "$f: get-task-allow"
  done
  ! grep -q 'com.apple.security.cs\.' "$SRC_ENT/LockPlusTunnel.entitlements" "$GOLD/LockPlusTunnel.entitlements" \
    || fail "hardened-runtime exception on the extension (invariant 9)"
  grep -q '>packet-tunnel-provider<' "$src" || fail "$src: dev value must be unsuffixed"
  grep -q 'packet-tunnel-provider-systemextension' "$gold" || fail "$gold: Release value must be -systemextension"
  want=$(norm_plist "$src" | jq -S --arg id "$TEAM.$([[ $n == LockPlus ]] && print $APP_ID || print $EXT_ID)" --arg team "$TEAM" \
    '."com.apple.developer.networking.networkextension" = ["packet-tunnel-provider-systemextension"]
     | ."com.apple.application-identifier" = $id | ."com.apple.developer.team-identifier" = $team')
  diff <(print -r -- "$want") <(norm_plist "$gold") || fail "$n: sources and golden differ beyond suffix + identity keys"
  ok "$n entitlements: sources ≡ golden (modulo suffix and identity keys)"
done
