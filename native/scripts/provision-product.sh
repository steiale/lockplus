#!/bin/zsh
# PRODUCT provisioning for LockPlus Native (DESIGN §2.7, §18 "Prerequisites before P2a").
#
#   RUN THIS FROM Terminal.app YOURSELF, NEVER FROM AN AGENT. An agent-run `xcodebuild -allowProvisioningUpdates`
#   could not reach the Xcode account token and REMOVED the account entry (P1 skeleton §1, 2026-10-26).
#
# Prerequisite: Xcode › Settings… › Accounts shows team "Alexander Steiner (M53GHX9FAY)" (Account Holder or Admin).
#
# What it does (modelled on native/spike/skeleton/scripts/provision.sh, with the product identifiers):
#   1. Debug build with -allowProvisioningUpdates: registers the App IDs io.github.steiale.lockplus.mac (Network
#      Extensions + System Extension) and io.github.steiale.lockplus.mac.tunnel (Network Extensions), registers this
#      Mac, and creates the two "Mac App Development" profiles (Xcode-managed).
#   2. A signed Release archive (Apple Development, automatic) + -exportArchive method developer-id with automatic
#      signing: lets Xcode create the two Developer ID profiles. (The export itself is NOT the release path; release.sh
#      signs inside-out. Its entitlements are diffed against the golden files as S9 evidence only.)
#   3. Copies the Developer ID profiles to ~/Library/Developer/LockPlus/profiles/ under the names check-profile.sh and
#      sign-inside-out.sh expect, runs check-profile.sh on both, and lists every profile Xcode holds for the product IDs.
#
# If step 1 fails to register the App IDs, do it by hand (developer.apple.com › Certificates, IDs & Profiles ›
# Identifiers › "+" › App IDs › App › Explicit):
#   io.github.steiale.lockplus.mac          capabilities: Network Extensions, System Extension
#   io.github.steiale.lockplus.mac.tunnel   capabilities: Network Extensions
#   (the app group M53GHX9FAY.io.github.steiale.lockplus.mac is macOS-style and needs no registration)
# If step 2 cannot create the Developer ID profiles, create them by hand: Profiles › "+" › Distribution › Developer ID ›
# the App ID › "Developer ID Application: Alexander Steiner (M53GHX9FAY)" (G2, expires 2031-05-04). Names exactly
# "LockPlus Developer ID" and "LockPlus Tunnel Developer ID"; download them to
#   ~/Library/Developer/LockPlus/profiles/LockPlus_Developer_ID.provisionprofile
#   ~/Library/Developer/LockPlus/profiles/LockPlus_Tunnel_Developer_ID.provisionprofile
# Never put profiles under /tmp or in the repository.
set -euo pipefail
source "${0:A:h:h}/Tools/release/common.sh"
cd "$NATIVE_ROOT"
[[ -z "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]] || { print "Refusing to run inside an agent session: run from Terminal.app."; exit 1; }
PROV="$LP_BUILD_ROOT/provision"; LOGS="$PROV"; mkdir -p "$LOGS" "$PROFILES"
PP="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
Tools/build/check-toolchain.sh
[[ -d Vendor/wireguard-apple/.git && -d Vendor/openvpn3/.git ]] || Tools/bootstrap/vendor.sh
Tools/bootstrap/openssl.sh

step "1. development build (automatic signing, registers App IDs + this Mac)"
xcodebuild build -project LockPlus.xcodeproj -scheme LockPlus -configuration Debug \
  -derivedDataPath $PROV/DD-dev -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  > "$LOGS/dev.log" 2>&1 || { grep -E 'error:' "$LOGS/dev.log" | sort -u; fail "development build (see $LOGS/dev.log)"; }
ok "development profiles"

step "2a. signed Release archive (Apple Development, automatic)"
rm -rf $PROV/LockPlus.xcarchive
xcodebuild archive -project LockPlus.xcodeproj -scheme LockPlus -configuration Release \
  -destination 'generic/platform=macOS' -archivePath $PROV/LockPlus.xcarchive \
  -derivedDataPath $PROV/DD-archive -allowProvisioningUpdates \
  > "$LOGS/archive.log" 2>&1 || { grep -E 'error:' "$LOGS/archive.log" | sort -u; fail "archive (see $LOGS/archive.log)"; }

step "2b. -exportArchive method developer-id (lets Xcode create the Developer ID profiles)"
rm -rf $PROV/export
if xcodebuild -exportArchive -archivePath $PROV/LockPlus.xcarchive \
     -exportOptionsPlist Config/ExportOptions-DeveloperID.plist -exportPath $PROV/export \
     -allowProvisioningUpdates > "$LOGS/export.log" 2>&1; then
  E=$PROV/export/LockPlus.app; X=$(ext_of "$E")
  codesign -d --entitlements - --xml "$E" > "$LOGS/app.ent" 2>/dev/null
  codesign -d --entitlements - --xml "$X" > "$LOGS/ext.ent" 2>/dev/null
  print "  export vs golden (S9 evidence only):"
  diff <(norm_plist "$LOGS/app.ent") <(norm_plist "$GOLD/LockPlus.entitlements") && print "    app: identical" || true
  diff <(norm_plist "$LOGS/ext.ent") <(norm_plist "$GOLD/LockPlusTunnel.entitlements") && print "    ext: identical" || true
  cp "$E/Contents/embedded.provisionprofile" "$APP_PROFILE"
  cp "$X/Contents/embedded.provisionprofile" "$EXT_PROFILE"
else
  print "  export FAILED (create the Developer ID profiles by hand, see the header):"; grep -E 'error' "$LOGS/export.log" | sort -u
fi

step "3. check the Developer ID profiles"
Tools/release/check-profile.sh "$APP_PROFILE" "$APP_ID"
Tools/release/check-profile.sh "$EXT_PROFILE" "$EXT_ID"

step "profiles Xcode holds for the product IDs"
T="$LOGS/.p.plist"
for f in "$PP"/*(N) "$PROFILES"/*.provisionprofile(N); do
  security cms -D -i "$f" -o "$T" 2>/dev/null || continue
  AID=$(plutil -extract Entitlements.com\\.apple\\.application-identifier raw -o - "$T" 2>/dev/null || true)
  [[ "$AID" == "$TEAM.$APP_ID" || "$AID" == "$TEAM.$EXT_ID" ]] || continue
  print "  ${f:t}: $(plutil -extract Name raw -o - "$T") AppID=$AID AllDevices=$(plutil -extract ProvisionsAllDevices raw -o - "$T" 2>/dev/null || echo no) Expires=$(plutil -extract ExpirationDate raw -o - "$T")"
done
rm -f "$T"
step "done. Next: Tools/release/release.sh (P2c) or, for a dev build, Tools/dev/build.sh"
