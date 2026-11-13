#!/bin/zsh
# Minimal release chain (DESIGN §12.4, the "Release build" row without the fresh-clone/tag gates, upload, appcast,
# SBOM or git tag): build-unsigned.sh → stage → sign-inside-out.sh --embed-profiles → verify.sh pre → notarize the
# app zip (--wait, always fetch the log, fail on any issue) → staple → zip the stapled app → volume icon from that app → DMG (UDZO, signed,
# notarized, stapled) → verify.sh post <app> <dmg> → SHA256SUMS.txt.
# Usage: release.sh [--skip-build]     --skip-build: reuse $LP_OUT/LockPlus.xcarchive (default $LP_BUILD_ROOT/release)
# Env:   LP_NOTARY_PROFILE (required: the notarytool keychain profile; set it in the environment or in the gitignored
#        Tools/lib/local.zsh); LP_NOTARY_WAIT_MIN (default 30): how long to wait for the
#        notary keychain item (readable only while the owner's Mac is unlocked). Never sets LP_ALLOW_SPARKLE_PLACEHOLDERS.
#        LP_PREV_APP (required, round 1 Fable N4): the previous notarized LockPlus.app; `verify.sh pre` checks that it
#        fails this build's APP_REQ (build floor).
# Output: $LP_OUT/out/{LockPlus.app, LockPlus-<ver>.zip, LockPlus-<ver>.dmg, SHA256SUMS.txt, notary-*.json}
set -euo pipefail
source "${0:A:h}/common.sh"
HERE="${0:A:h}"
cd "$NATIVE_ROOT"
OUT="${LP_OUT:-$LP_BUILD_ROOT/release}"; OUT="${OUT:A}"
FINAL="$OUT/out"; STAGE="$OUT/stage"; NOTE="$OUT/notary"
NOTARY="${LP_NOTARY_PROFILE:-}"
[[ -n "$NOTARY" ]] || fail "set LP_NOTARY_PROFILE (the notarytool keychain profile), e.g. in Tools/lib/local.zsh (gitignored)"
[[ -n "${LP_PREV_APP:-}" && -d "${LP_PREV_APP:-}" ]] || fail "set LP_PREV_APP to the previous notarized LockPlus.app (the build-floor check)"
export LP_RELEASE_RUN=1
SKIP_BUILD=0
for a in "$@"; do case $a in --skip-build) SKIP_BUILD=1;; *) fail "unknown option $a";; esac; done
unset LP_ALLOW_SPARKLE_PLACEHOLDERS
[[ $EUID -ne 0 ]] || fail "never run as root"

# The notary keychain item is readable only while the owner's Mac is unlocked: retry, never touch keychains.
NOTARY_WAIT_MIN=${LP_NOTARY_WAIT_MIN:-30}
notary() {   # notary <notarytool args…>; retries "No Keychain password item" every 60 s for LP_NOTARY_WAIT_MIN (30) min
  local i out rc
  for i in {1..$NOTARY_WAIT_MIN}; do
    rc=0; out=$(xcrun notarytool "$@" --keychain-profile "$NOTARY" 2>&1) || rc=$?
    if (( rc != 0 )) && grep -q 'No Keychain password item' <<<"$out"; then
      print "  notary keychain item unavailable (Mac locked?), retry $i/$NOTARY_WAIT_MIN in 60 s" >&2; sleep 60; continue
    fi
    print -r -- "$out"; return $rc
  done
  fail "notary keychain profile $NOTARY unavailable for $NOTARY_WAIT_MIN min"
}
submit() {   # submit <file> <tag>: notarize with --wait, fetch the log, fail on anything but Accepted with no issues
  local f=$1 tag=$2 json id st
  step "notarize $(basename "$f")"
  json=$(notary submit "$f" --wait --timeout 2h --output-format json) || true
  print -r -- "$json" > "$NOTE/submit-$tag.json"
  id=$(jq -r '.id // empty' <<<"$json" 2>/dev/null || true); st=$(jq -r '.status // empty' <<<"$json" 2>/dev/null || true)
  [[ -n "$id" ]] || fail "no submission id ($tag): $json"
  notary log "$id" "$NOTE/log-$tag.json" >/dev/null
  jq '{status, statusSummary, issues}' "$NOTE/log-$tag.json"
  [[ "$st" == Accepted ]] || fail "notarization of $tag: $st (id $id)"
  jq -e '(.issues // []) | length == 0' "$NOTE/log-$tag.json" >/dev/null || fail "notary log for $tag has issues (id $id)"
  ok "$tag accepted: $id"
  print -r -- "$id" > "$NOTE/id-$tag.txt"
}

step "preflight"
[[ -z "${LP_TOOLCHAIN_CI:-}" ]] || fail "LP_TOOLCHAIN_CI is for CI only: a release is built with the exact pinned Xcode build"
Tools/build/check-toolchain.sh
IDS=$(security find-identity -v -p codesigning)
grep -qF "\"$IDENTITY\"" <<<"$IDS" || fail "identity not in keychain: $IDENTITY"
"$HERE/check-profile.sh" "$APP_PROFILE" "$APP_ID"
"$HERE/check-profile.sh" "$EXT_PROFILE" "$EXT_ID"
plutil -lint "$GOLD"/*.entitlements >/dev/null
"$HERE/version-check.sh"
notary history >/dev/null || fail "notarytool history --keychain-profile $NOTARY failed"
ok "notary profile $NOTARY"

if (( ! SKIP_BUILD )); then LP_OUT="$OUT" Tools/build/build-unsigned.sh; fi
ARCHIVE="$OUT/LockPlus.xcarchive"
"$HERE/verify.sh" static "$ARCHIVE"
"$HERE/macho-hashes.sh" "$(resolve_app "$ARCHIVE")" > "$OUT/macho-sha256.txt"

step "stage"
rm -rf "$STAGE" "$FINAL" "$NOTE"; mkdir -p "$STAGE" "$FINAL" "$NOTE"
ditto "$(resolve_app "$ARCHIVE")" "$STAGE/$APP_NAME.app"
APP="$STAGE/$APP_NAME.app"
VER=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
BV=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")

"$HERE/sign-inside-out.sh" "$APP" --embed-profiles
"$HERE/verify.sh" pre "$APP"

ZIP_N="$NOTE/$APP_NAME-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_N"
submit "$ZIP_N" app
step "staple app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

ditto "$APP" "$FINAL/$APP_NAME.app"
APP="$FINAL/$APP_NAME.app"
ZIP="$FINAL/$APP_NAME-$VER.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
TOP=$(zipinfo -1 "$ZIP" | cut -d/ -f1 | grep -vx __MACOSX | sort -u)   # --sequesterRsrc adds __MACOSX/
[[ "$TOP" == "$APP_NAME.app" ]] || fail "zip top level is '$TOP', want $APP_NAME.app (L-DIST-1)"

# A freshly written volume is often still busy (Spotlight, fseventsd ignore -nobrowse): retry, then force (review M7).
detach() {   # detach <mountpoint>
  local i
  for i in {1..5}; do hdiutil detach "$1" >/dev/null 2>&1 && return 0; sleep 2; done
  print "  $1 still busy after 5 tries; detaching with -force" >&2
  hdiutil detach "$1" -force >/dev/null || fail "hdiutil detach $1"
}

step "volume icon"
# Pre-release review B1: rendered from the app being shipped (its macOS-masked icon), never a stale copy.
ICONSET="$OUT/VolumeIcon.iconset"; VOLICON="$OUT/VolumeIcon.icns"
rm -rf "$ICONSET" "$VOLICON"
# An app without its icon (CFBundleIconName) would give the generic icon to the app AND the volume.
[[ "$(plutil -extract CFBundleIconName raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" == AppIcon ]] \
  || fail "$APP_NAME.app has no AppIcon (CFBundleIconName): is App/AppIcon.icon in the build?"
xcrun swiftc -O "$HERE/make-volume-icon.swift" -o "$OUT/make-volume-icon" || fail "compile make-volume-icon.swift"
"$OUT/make-volume-icon" "$APP" "$ICONSET" || fail "make-volume-icon"
iconutil -c icns "$ICONSET" -o "$VOLICON" || fail "iconutil -c icns"
[[ -s "$VOLICON" ]] || fail "no $VOLICON"
cmp -s "$VOLICON" "$HERE/VolumeIcon.icns" \
  || print "  note: Tools/release/VolumeIcon.icns (the committed reference copy) differs from this app's icon; the fresh one is used" >&2
ok "volume icon from $APP_NAME.app"

step "DMG"
DMG="$FINAL/$APP_NAME-$VER.dmg"; SRC="$OUT/dmg-src"
rm -rf "$SRC"; mkdir -p "$SRC"
ditto "$APP" "$SRC/$APP_NAME.app"
ln -s /Applications "$SRC/Applications"
# The Custom-icon flag (C) is set on the mounted volume after create.
cp "$VOLICON" "$SRC/.VolumeIcon.icns"
RW="$OUT/dmg-rw.dmg"; MNT="$OUT/dmg-mnt"
rm -rf "$RW" "$MNT"; mkdir -p "$MNT"
hdiutil create -volname "$APP_NAME $VER" -srcfolder "$SRC" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
hdiutil attach "$RW" -mountpoint "$MNT" -nobrowse -noverify -noautoopen >/dev/null
[[ -s "$MNT/.VolumeIcon.icns" ]] || { detach "$MNT"; fail "the volume has no .VolumeIcon.icns"; }
# xcrun: SetFile from the pinned Xcode, not whatever command line tools are installed (review M7).
xcrun SetFile -a C "$MNT" || { detach "$MNT"; fail "xcrun SetFile -a C"; }
detach "$MNT"
hdiutil convert "$RW" -format UDZO -ov -o "$DMG" >/dev/null
rm -rf "$SRC" "$RW" "$MNT"
hdiutil verify "$DMG" >/dev/null
# Loud check on the final image (review M7): the icon file is there and the volume's Custom-icon flag is set.
CHK="$OUT/dmg-check"; rm -rf "$CHK"; mkdir -p "$CHK"
hdiutil attach "$DMG" -readonly -mountpoint "$CHK" -nobrowse -noverify -noautoopen >/dev/null
icon_ok=1; [[ -s "$CHK/.VolumeIcon.icns" ]] || icon_ok=0
flag=$(xcrun GetFileInfo -aC "$CHK" 2>/dev/null || print 0)
detach "$CHK"; rm -rf "$CHK"
(( icon_ok )) || fail "the DMG has no .VolumeIcon.icns"
[[ "$flag" == 1 ]] || fail "the DMG volume's Custom-icon flag isn't set (GetFileInfo -aC: $flag)"
ok "DMG volume icon present and flagged"
codesign -s "$IDENTITY" --timestamp -i "$APP_ID.dmg" "$DMG"
submit "$DMG" dmg
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

"$HERE/verify.sh" post "$APP" "$DMG"

(cd "$FINAL" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS.txt)
step "done: $VER ($BV)"
print "  app  $APP"
print "  zip  $ZIP"
print "  dmg  $DMG"
print "  notarization: app $(cat "$NOTE/id-app.txt"), dmg $(cat "$NOTE/id-dmg.txt")"
