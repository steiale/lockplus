#!/bin/zsh
# Verification gates (DESIGN §12.4, ref/toolchain §8).
#   verify.sh static <LockPlus.xcarchive|LockPlus.app> [--asan]  CI + release.sh: unsigned build checks
#   verify.sh pre  <signed LockPlus.app>                          release.sh: before notarization upload
#   verify.sh post <stapled LockPlus.app> [LockPlus.dmg]          release.sh: after stapling
set -euo pipefail
source "${0:A:h}/common.sh"
HERE="${0:A:h}"
MODE=${1:?usage: verify.sh static|pre|post <bundle>}; TARGET=${2:?bundle}
APP=$(resolve_app "$TARGET"); EXT=$(ext_of "$APP"); X=$(ext_bin_of "$APP"); AX="$APP/Contents/MacOS/$APP_NAME"
ASAN=0; [[ "${3:-}" == --asan ]] && ASAN=1
[[ -x "$X" && -x "$AX" ]] || fail "not a LockPlus bundle with an embedded extension: $APP"
# Capture-then-test everywhere in this file: `! a | grep -q X` under pipefail turns grep's early exit (SIGPIPE 141 in `a`)
# into a silent PASS. Never pipe into `grep -q`/`head` here.
machos() { find "$APP" -type f -print0 | while IFS= read -r -d '' f; do if [[ "$(file -b "$f")" == Mach-O* ]]; then print -r -- "$f"; fi; done; }

static_checks() {
  step "linkage (invariant 5, §2.2)"
  local libs bad
  libs=$(otool -L "$X")
  [[ -n "$libs" ]] || fail "otool -L produced no output for $X"
  ! grep -Eq 'AppKit|SwiftUI|Sparkle|ZIPFoundation' <<<"$libs" || fail "GUI/app framework linked into the extension"
  bad=$(tail -n +2 <<<"$libs" | awk '{print $1}' | grep -vE '^(/System/Library/|/usr/lib/)' || true)
  if (( ASAN )); then bad=$(print -r -- "$bad" | grep -v 'libclang_rt.asan_osx_dynamic.dylib' || true); fi
  [[ -z "$bad" ]] || fail "non-system dylib in the extension: $bad"
  ok "extension links only /System and /usr/lib$( (( ASAN )) && print ' (+ ASan runtime)')"
  local rp; rp=$(otool -l "$X" | grep -A2 LC_RPATH | awk '/ path /{print $2}' | sort -u)
  grep -qx '@executable_path/../Frameworks' <<<"$rp" || fail "extension LC_RPATH lacks @executable_path/../Frameworks"
  [[ -z "$(print -r -- "$rp" | grep -vxE '@executable_path/\.\./Frameworks|/usr/lib/swift' || true)" ]] \
    || fail "unexpected extension LC_RPATH: $(print -r -- "$rp" | tr '\n' ' ')"
  ok "extension LC_RPATH: $(print -r -- "$rp" | tr '\n' ' ')"

  step "ZIPFoundation: linked into the app only (§2.2, draft 9.1)"
  local xs as
  xs=$(nm -a "$X" 2>/dev/null || true); xs+=$(strings -a "$X")
  [[ -n "$xs" ]] || fail "nm/strings produced no output for $X"
  ! grep -q 'ZIPFoundation' <<<"$xs" || fail "ZIPFoundation symbols or strings in the extension"
  [[ -z "$(find "$EXT" -iname '*ZIPFoundation*' -print)" ]] || fail "ZIPFoundation resources in the extension bundle"
  as=$(nm -a "$AX" 2>/dev/null || true); as+=$(strings -a "$AX")
  grep -q 'ZIPFoundation' <<<"$as" || fail "ZIPFoundation not found in the app binary (SPM pin not linked?)"
  ok "ZIPFoundation in the app, not in the extension"

  step "Release content (invariant 11, §5.3)"
  local mlist; mlist=("${(@f)$(machos)}")
  (( ${#mlist} > 0 )) && [[ -n "${mlist[1]}" ]] || fail "no Mach-O found in $APP"
  local m str syms k
  for m in $mlist; do
    str=$(strings -a "$m"); [[ -n "$str" ]] || fail "strings produced no output for ${m#$APP/}"
    syms=$(nm -m "$m" 2>&1 || true)
    ! grep -q -- "$DEV_OID" <<<"$str" || fail "Apple Development requirement clause in ${m#$APP/}"
    ! grep -q debugInjectFault <<<"$syms" || fail "debugInjectFault in ${m#$APP/}"
    for k in $FI_KEYS; do ! grep -qF -- "$k" <<<"$str" || fail "FaultInjection switch key '$k' in ${m#$APP/}"; done
    ! grep -Eq '/Users/|/Volumes/|/private/var/folders/' <<<"$str" || fail "absolute build path in ${m#$APP/} (Repro.xcconfig missing?)"
  done
  ok "no $DEV_OID, no debugInjectFault, no FaultInjection keys, no absolute paths in ${#mlist} Mach-Os"
  # The key list must name what the source compiles under LP_FAULT_INJECTION, or the grep above checks nothing.
  local fis="$NATIVE_ROOT/Shared/FaultInjectionSwitches.swift"
  for k in $FI_KEYS; do grep -qF -- "\"$k\"" "$fis" || fail "FI_KEYS entry '$k' not found in $fis"; done

  local cbv; cbv=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")
  [[ -n "$cbv" && "$cbv" != *.* ]] || fail "Release CFBundleVersion missing or has a dev stamp: '$cbv'"

  step "bundle content: no .py, test bundles or Screenshots; no App/UI/Tests or App/UI/Tools (§2.1, Conflicts bd)"
  check_no_stray_source_dirs
  local stray
  stray=$(find "$APP" \( -iname '*.py' -o -iname '*.pyc' -o -iname '*.xctest' -o -iname '*.xctestplan' -o -iname '*Screenshot*' \) -print)
  [[ -z "$stray" ]] || fail "non-product files in the bundle: ${stray//$APP\//}"
  ok "app and extension bundles carry no .py, test or Screenshots files"

  step "LP_DEV_SIGNING never in Release build settings (draft 6)"
  # Evaluated with the same -xcconfig as build-unsigned.sh. This is a convenience early signal only: the `strings` grep
  # for $DEV_OID over every Mach-O above is the real backstop (packages' settings are not visible here, Conflicts aq).
  local bs t
  for t in LockPlus LockPlusTunnel RequirementTests; do
    bs=$(xcodebuild -project "$NATIVE_ROOT/LockPlus.xcodeproj" -target "$t" -configuration Release \
      -xcconfig "$NATIVE_ROOT/Config/Repro.xcconfig" -showBuildSettings 2>&1) || fail "xcodebuild -showBuildSettings failed for $t"
    # Release.xcconfig sets SWIFT_ACTIVE_COMPILATION_CONDITIONS empty and xcodebuild omits empty settings, so assert real
    # Release settings are present instead; otherwise a failed/empty xcodebuild would make the LP_DEV_SIGNING check vacuous.
    grep -Eq '^ +CONFIGURATION = Release$' <<<"$bs" && grep -Eq '^ +SWIFT_OPTIMIZATION_LEVEL = ' <<<"$bs" \
      || fail "$t: -showBuildSettings output is empty or not the Release configuration"
    ! grep -q LP_DEV_SIGNING <<<"$bs" || fail "$t Release build settings contain LP_DEV_SIGNING"
  done
  ok "LockPlus, LockPlusTunnel, RequirementTests"

  step "Sparkle feed and key are real; no preview mode (Fable M3, M1)"
  # The same rule as UpdateController.isConfigured: SUFeedURL is https with a non-.invalid host, SUPublicEDKey is
  # base64 of exactly 32 bytes. LP_ALLOW_SPARKLE_PLACEHOLDERS=1 is for CI builds before the owner's decision only;
  # release.sh never sets it.
  local plist="$APP/Contents/Info.plist" feed key host klen
  feed=$(plutil -extract SUFeedURL raw -o - "$plist" 2>/dev/null || true)
  key=$(plutil -extract SUPublicEDKey raw -o - "$plist" 2>/dev/null || true)
  host=$(print -r -- "$feed" | sed -nE 's#^https://([^/:]+).*#\1#p')
  klen=$(print -rn -- "$key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')
  if [[ -z "$host" || "$host" == *.invalid || "$klen" != 32 ]]; then
    [[ "${LP_ALLOW_SPARKLE_PLACEHOLDERS:-0}" == 1 ]] || fail "SUFeedURL/SUPublicEDKey are placeholders or invalid (feed '$feed', key ${klen:-0} bytes)"
    print "  warning: Sparkle placeholders allowed by LP_ALLOW_SPARKLE_PLACEHOLDERS=1 (not a releasable build)"
  else
    ok "SUFeedURL https://$host, SUPublicEDKey 32 bytes"
  fi
  local axs; axs=$(strings -a "$AX")
  [[ -n "$axs" ]] || fail "strings produced no output for the app binary"
  ! grep -Eq 'LP_PREVIEW_MODE|LPPreviewMode|PreviewManagerStore' <<<"$axs" || fail "preview mode is compiled into the Release app"
  ok "no preview mode in the Release app"

  step "requirement literals agree (common.sh ≡ RequirementTests)"
  local rt="$NATIVE_ROOT/Tests/RequirementTests/RequirementTests.swift"
  grep -qF -- "$APP_REQ" "$rt" && grep -qF -- "$EXT_REQ" "$rt" || fail "Release requirement strings drifted between common.sh and $rt"
  ok "APP_REQ, EXT_REQ"

  "$HERE/check-entitlement-sources.sh"
  "$HERE/version-check.sh" --app "$APP"
  # S7 duplicate-symbol check over the archive's intermediates (build-unsigned.sh keeps DerivedData next to it).
  if [[ "$TARGET" == *.xcarchive && -d "${TARGET:A:h}/DerivedData" ]]; then
    "$NATIVE_ROOT/Tools/build/check-symbols.sh" "${TARGET:A:h}/DerivedData" "$X"
  fi
}

pre_checks() {
  step "signature (pre-notarization)"
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
  local d
  for B in "$EXT" "$APP"; do
    d=$(codesign -dvvv "$B" 2>&1)
    grep -qF -- "Authority=$IDENTITY" <<<"$d" || fail "$B: wrong authority"
    grep -q '^Timestamp=' <<<"$d" || fail "$B: no secure timestamp"
    grep -qF 'flags=0x10000(runtime)' <<<"$d" || fail "$B: no hardened runtime"
    grep -Eq 'CodeDirectory v=20[4-9]' <<<"$d" || fail "$B: CodeDirectory too old"
  done
  ok "Developer ID, secure timestamp, runtime, CodeDirectory ≥ 20400"
  local OUT="$LP_BUILD_ROOT/verify"; mkdir -p "$OUT"
  codesign -d --entitlements - --xml "$EXT" > "$OUT/ext.ent" 2>/dev/null
  codesign -d --entitlements - --xml "$APP" > "$OUT/app.ent" 2>/dev/null
  diff <(norm_plist "$OUT/ext.ent") <(norm_plist "$GOLD/LockPlusTunnel.entitlements") || fail "extension entitlements != golden"
  diff <(norm_plist "$OUT/app.ent") <(norm_plist "$GOLD/LockPlus.entitlements") || fail "app entitlements != golden"
  ! grep -q 'com.apple.security.cs.' "$OUT/ext.ent" || fail "hardened-runtime exception on the extension"
  ! grep -q 'get-task-allow' "$OUT/ext.ent" "$OUT/app.ent" || fail "get-task-allow present"
  ok "entitlements == golden"
  # `-R <req>` as two words: in the `-R=<req>` form codesign takes the "=" as part of the requirement text, and a
  # syntax error (exit 1) would also make the negative check below pass. Not satisfied is exit 3.
  codesign --verify -R "=$APP_REQ" "$APP" || fail "APP_REQ does not match the app"
  codesign --verify -R "=$EXT_REQ" "$EXT" || fail "EXT_REQ does not match the extension"
  local rc=0; codesign --verify -R "=$APP_REQ" "$EXT" 2>/dev/null || rc=$?
  (( rc == 3 )) || fail "APP_REQ on the extension: want 'does not satisfy' (3), got $rc"
  ok "Release requirements match (and are not interchangeable)"
  for B in "$APP" "$EXT"; do
    local prof pad
    prof=$(security cms -D -i "$B/Contents/embedded.provisionprofile" 2>/dev/null) || fail "$B: cannot decode embedded profile"
    pad=$(plutil -extract ProvisionsAllDevices raw -o - - <<<"$prof" 2>/dev/null || true)
    [[ "$pad" == true ]] || fail "$B: embedded profile is not Developer ID"
  done
  ok "embedded Developer ID profiles"
  static_checks
  # syspolicy_check notary-submission (the only check besides check-profile.sh that catches a missing or mismatched
  # profile). On macOS 27.0.1 it also reports every unnotarized Developer ID executable as a Fatal "Codesign Error:
  # Gatekeeper rejected this file" (-67018, seen on the P1 spike's bundle and on 2.0.0 (200000)); that one finding is
  # expected before notarization and tolerated, any other finding fails, and the AMFI preflight must have passed.
  local spc src=0 other
  spc=$(syspolicy_check notary-submission "$APP" --verbose 2>&1) || src=$?
  print -r -- "$spc" | grep -vE 'Progress:|^\s*$' | grep -vE 'policy match|Running PolicyScanner' || true
  grep -q 'Passed amfi_preflight' <<<"$spc" || fail "syspolicy_check notary-submission: AMFI preflight did not pass"
  if (( src != 0 )); then
    other=$(awk '/^[A-Z][A-Za-z ]+$/ {name=$0} /Full Error:/ {getline nxt; line=$0 " " nxt; if (!(name=="Codesign Error" && line ~ /Gatekeeper rejected/)) print name": "line}' <<<"$spc")
    [[ -z "$other" ]] || fail "syspolicy_check notary-submission: $other"
    grep -q 'Gatekeeper rejected' <<<"$spc" || fail "syspolicy_check notary-submission failed (rc $src) without a parsable finding"
    print "  note: syspolicy_check's pre-notarization 'Gatekeeper rejected' finding tolerated (unnotarized Developer ID)"
  fi
  ok "syspolicy_check notary-submission: AMFI preflight passed, no profile/certificate/entitlement findings"
}

post_checks() {
  step "post-staple"
  xcrun stapler validate "$APP"
  syspolicy_check distribution "$APP" || fail "syspolicy_check distribution"
  spctl -a -t exec -vvv "$APP" 2>&1 | tail -2           # secondary, "much less accurate"
  codesign -vvvv -R "=notarized" --check-notarization "$EXT" || fail "extension notarization check"
  if [[ -n "${3:-}" ]]; then spctl -a -t open -vvv --context context:primary-signature "$3" || fail "DMG assessment"; fi
  ok "stapled and assessed"
}

case $MODE in
  static) static_checks ;;
  pre) pre_checks ;;
  post) post_checks "$@" ;;
  *) fail "unknown mode $MODE" ;;
esac
print -P "%F{green}verify $MODE: PASS%f"
