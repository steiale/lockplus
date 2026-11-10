# Shared by Tools/release/*.sh and Tools/build/*.sh (sourced, zsh). Never /tmp: build output lives under $LP_BUILD_ROOT.
NATIVE_ROOT="${${(%):-%x}:A:h:h:h}"
source "$NATIVE_ROOT/Tools/lib/paths.sh"   # LP_BUILD_ROOT (default ~/Code/lockplus-build)
TEAM=M53GHX9FAY
APP_ID=io.github.steiale.lockplus.mac
EXT_ID=$APP_ID.tunnel
APP_GROUP=$TEAM.$APP_ID
APP_NAME=LockPlus
IDENTITY="${LP_IDENTITY:-Developer ID Application: Alexander Steiner (M53GHX9FAY)}"
GOLD="$NATIVE_ROOT/Config/Entitlements/Release"
SRC_ENT="$NATIVE_ROOT/Config/Entitlements"
PROFILES="${LP_PROFILES:-$HOME/Library/Developer/LockPlus/profiles}"
APP_PROFILE="$PROFILES/LockPlus_Developer_ID.provisionprofile"
EXT_PROFILE="$PROFILES/LockPlus_Tunnel_Developer_ID.provisionprofile"

# DESIGN §5.3 Release requirement strings; identical to the literals in Tests/RequirementTests/RequirementTests.swift
# (verify.sh static checks that). The dev clause never appears here.
SIGNER='(certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13])'
APP_REQ="anchor apple generic and identifier \"$APP_ID\" and $SIGNER and certificate leaf[subject.OU] = \"$TEAM\""
EXT_REQ="anchor apple generic and identifier \"$EXT_ID\" and $SIGNER and certificate leaf[subject.OU] = \"$TEAM\""
DEV_OID='113635.100.6.2.1'
# Debug/FaultInjection (LP_DEV_SIGNING) strings, for signed dev builds only (Tools/dev/build.sh).
DEV_SIGNER='((certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]) or (certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[field.1.2.840.113635.100.6.1.12]))'
DEV_APP_REQ="anchor apple generic and identifier \"$APP_ID\" and $DEV_SIGNER and certificate leaf[subject.OU] = \"$TEAM\""
DEV_EXT_REQ="anchor apple generic and identifier \"$EXT_ID\" and $DEV_SIGNER and certificate leaf[subject.OU] = \"$TEAM\""

step() { print -P "%F{cyan}==> $*%f"; }
ok()   { print -P "  %F{green}ok%f $*"; }
fail() { print -P "%F{red}FAIL: $*%f" >&2; exit 1; }

# Bundle paths from an .app, an .xcarchive or a build products directory.
resolve_app() {   # $1 → prints the .app path
  local p=$1
  if [[ "$p" == *.xcarchive ]]; then print -r -- "$p/Products/Applications/$APP_NAME.app"
  elif [[ "$p" == *.app ]]; then print -r -- "$p"
  else print -r -- "$p/$APP_NAME.app"; fi
}
ext_of() { print -r -- "$1/Contents/Library/SystemExtensions/$EXT_ID.systemextension"; }
ext_bin_of() { print -r -- "$(ext_of "$1")/Contents/MacOS/$EXT_ID"; }
# DESIGN §2.1, Conflicts bd (PENDING-FOLD 27): folder-level membershipExceptions are ignored by xcodebuild 27.1, so a
# non-target folder under App/ is compiled (or copied) into the app. These two must never exist again.
check_no_stray_source_dirs() {
  local d
  for d in App/UI/Tests App/UI/Tools; do
    [[ ! -e "$NATIVE_ROOT/$d" ]] || fail "native/$d exists: non-target files must live outside App/ and Tunnel/ (tests under Tests/, tools under Tools/)"
  done
}
# The FaultInjection-only switch keys (Shared/FaultInjectionSwitches.swift); never in a Release Mach-O.
FI_KEYS=(lp.fi.dataPlane)
norm_plist() { plutil -convert json -o - "$1" | jq -S .; }
