#!/bin/zsh
# Inside-out Developer ID signing with the golden entitlements (DESIGN §12.4, ref/toolchain §6, §7.5).
#   Sparkle Autoupdate → Updater.app → Sparkle.framework (each -o runtime, no entitlements; XPCServices/ must already
#   be stripped) → extension dylibs (--timestamp, no -o runtime; the ASan runtime in ASan test builds only) →
#   .systemextension (-o runtime, golden Tunnel entitlements) → app (-o runtime, golden app entitlements).
# Rules: -f -s <identity> --timestamp (no value: Apple's server; never `--timestamp <url>`), never --deep, never sudo,
# never on a stapled bundle (re-signing invalidates the ticket).
# Usage: sign-inside-out.sh <LockPlus.app> [--embed-profiles] [--asan]
set -euo pipefail
source "${0:A:h}/common.sh"
APP=${1:?usage: sign-inside-out.sh <LockPlus.app> [--embed-profiles] [--asan]}; shift
EMBED=0; ASAN=0
for a in "$@"; do case $a in --embed-profiles) EMBED=1;; --asan) ASAN=1;; *) fail "unknown option $a";; esac; done
EXT=$(ext_of "$APP"); X=$(ext_bin_of "$APP")
[[ -x "$X" ]] || fail "no extension binary at $X"
[[ $EUID -ne 0 ]] || fail "never sign as root"
[[ ! -f "$APP/Contents/CodeResources" ]] || fail "stapled bundle: never re-sign after staple"
xcrun stapler validate "$APP" >/dev/null 2>&1 && fail "bundle already carries a notarization ticket; never re-sign after staple"
IDS=$(security find-identity -v -p codesigning)   # capture first: grep -q on a pipe can SIGPIPE under pipefail
grep -qF "\"$IDENTITY\"" <<<"$IDS" || fail "identity not in keychain: $IDENTITY"
plutil -lint "$GOLD"/*.entitlements >/dev/null

if (( EMBED )); then
  step "embed Developer ID profiles"
  "${0:A:h}/check-profile.sh" "$APP_PROFILE" "$APP_ID"
  "${0:A:h}/check-profile.sh" "$EXT_PROFILE" "$EXT_ID"
  cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
  cp "$EXT_PROFILE" "$EXT/Contents/embedded.provisionprofile"
fi

LIBS=$(otool -L "$X")
if grep -q 'libclang_rt.asan_osx_dynamic.dylib' <<<"$LIBS"; then
  (( ASAN )) || fail "the extension links the ASan runtime but --asan was not given (ASan builds are never released)"
  # Activation copies the extension out of the app, so it needs its own copy of the runtime (D73-10).
  RTS=$(find "$APP/Contents/Frameworks" "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang" \
         -name libclang_rt.asan_osx_dynamic.dylib 2>/dev/null || true)
  RT=${${(f)RTS}[1]:-}
  [[ -n "$RT" ]] || fail "ASan runtime not found"
  mkdir -p "$EXT/Contents/Frameworks"; cp "$RT" "$EXT/Contents/Frameworks/"
  ok "ASan runtime embedded in the extension"
fi

step "sign inside-out as \"$IDENTITY\""
S=(codesign -s "$IDENTITY" -f --timestamp)
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SP" ]]; then
  [[ ! -d "$SP/XPCServices" ]] || fail "Sparkle XPCServices/ present: the install-time strip phase did not run (ref/sparkle C10)"
  "${S[@]}" -o runtime "$SP/Autoupdate"
  "${S[@]}" -o runtime "$SP/Updater.app"
  "${S[@]}" -o runtime "$APP/Contents/Frameworks/Sparkle.framework"
fi
if [[ -d "$EXT/Contents/Frameworks" ]]; then
  find "$EXT/Contents/Frameworks" -name '*.dylib' -print0 | xargs -0 -n1 "${S[@]}"
fi
"${S[@]}" -o runtime --entitlements "$GOLD/LockPlusTunnel.entitlements" "$EXT"
if [[ -d "$APP/Contents/Frameworks" ]]; then
  find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.dylib' -print0 | xargs -0 -n1 "${S[@]}"
fi
"${S[@]}" -o runtime --entitlements "$GOLD/LockPlus.entitlements" "$APP"
ok "signed $APP"
