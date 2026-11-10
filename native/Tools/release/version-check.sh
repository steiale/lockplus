#!/bin/zsh
# Version gate (DESIGN §2.6). Runs in CI on every build and before the appcast is generated.
#   version-check.sh                      sources only (Version.xcconfig, Info.plist keys)
#   version-check.sh --app <LockPlus.app> also the built bundle
#   version-check.sh --tag native-vX.Y.Z  also the release tag (release.sh)
#   version-check.sh --app <app> --signed also codesign -R with the Release requirements (dev Mac only)
set -euo pipefail
source "${0:A:h}/common.sh"
APP=""; TAG=""; SIGNED=0
while (( $# )); do case $1 in --app) APP=$2; shift 2;; --tag) TAG=$2; shift 2;; --signed) SIGNED=1; shift;; *) fail "unknown $1";; esac; done

V="$NATIVE_ROOT/Config/Version.xcconfig"
MKT=$(awk -F' *= *' '/^LP_MARKETING_VERSION/{print $2}' "$V")
BUILD=$(awk -F' *= *' '/^LP_BUILD_NUMBER/{print $2}' "$V" | awk '{print $1}')
[[ "$MKT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "LP_MARKETING_VERSION must be three integers: $MKT"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "LP_BUILD_NUMBER must be an integer: $BUILD"
EXTP="$NATIVE_ROOT/Config/Info/LockPlusTunnel-Info.plist"
plutil -extract NSSystemExtensionUsageDescription raw -o - "$EXTP" >/dev/null || fail "extension Info.plist lacks NSSystemExtensionUsageDescription"
[[ "$(plutil -extract NetworkExtension.NEMachServiceName raw -o - "$EXTP")" == '$(LP_APP_GROUP).tunnel.v$(CURRENT_PROJECT_VERSION)' ]] \
  || fail "NEMachServiceName source must be \$(LP_APP_GROUP).tunnel.v\$(CURRENT_PROJECT_VERSION)"
ok "sources: $MKT ($BUILD)"

if [[ -n "$APP" ]]; then
  APP=$(resolve_app "$APP"); EXT=$(ext_of "$APP")
  rd() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist"; }
  [[ "$(rd "$APP" CFBundleShortVersionString)" == "$(rd "$EXT" CFBundleShortVersionString)" ]] || fail "app/ext CFBundleShortVersionString differ"
  [[ "$(rd "$APP" CFBundleVersion)" == "$(rd "$EXT" CFBundleVersion)" ]] || fail "app/ext CFBundleVersion differ"
  BV=$(rd "$EXT" CFBundleVersion); MACH=$(rd "$EXT" NetworkExtension.NEMachServiceName)
  [[ "$MACH" == "$APP_GROUP.tunnel.v$BV" ]] || fail "NEMachServiceName $MACH != $APP_GROUP.tunnel.v$BV"
  [[ "$MACH" == "$APP_GROUP."* ]] || fail "NEMachServiceName is not a dot-descendant of $APP_GROUP"
  [[ "$(rd "$APP" LSMinimumSystemVersion)" == 26.0 && "$(rd "$EXT" LSMinimumSystemVersion)" == 26.0 ]] || fail "LSMinimumSystemVersion != 26.0"
  rd "$EXT" NSSystemExtensionUsageDescription >/dev/null || fail "built extension lacks NSSystemExtensionUsageDescription"
  ok "bundle: $(rd "$APP" CFBundleShortVersionString) ($BV), $MACH"
  if (( SIGNED )); then
    AR=$APP_REQ; ER=$EXT_REQ
    [[ "$BV" == *.* ]] && { AR=$DEV_APP_REQ; ER=$DEV_EXT_REQ; }      # stamped = Debug/FaultInjection build
    codesign --verify -R "=$AR" "$APP" || fail "codesign -R APP_REQ"
    codesign --verify -R "=$ER" "$EXT" || fail "codesign -R EXT_REQ"
    E=$(codesign -d --entitlements - --xml "$EXT" 2>/dev/null)
    if [[ "$BV" == *.* ]]; then
      ! grep -q packet-tunnel-provider-systemextension <<<"$E" || fail "dev build carries the -systemextension value"
    else
      grep -q packet-tunnel-provider-systemextension <<<"$E" || fail "Release build lacks the -systemextension value"
    fi
    ok "signed: requirements and NE entitlement value"
  fi
fi

if [[ -n "$TAG" ]]; then
  [[ "$TAG" == "native-v$MKT" ]] || fail "tag $TAG != native-v$MKT"
  [[ "$BUILD" != *.* ]] || fail "Release build number contains a period"
  TAGS=("${(@f)$(git -C "$NATIVE_ROOT" tag --list 'native-v*' --sort=-v:refname)}")
  TAGS=(${TAGS:#$TAG})                       # no `| grep | head -1` pipe: early exit + pipefail
  PREV=${TAGS[1]:-}
  if [[ -n "$PREV" ]]; then
    PB=$(git -C "$NATIVE_ROOT" show "$PREV:native/Config/Version.xcconfig" | awk -F' *= *' '/^LP_BUILD_NUMBER/{print $2}' | awk '{print $1}')
    (( BUILD > PB )) || fail "LP_BUILD_NUMBER $BUILD is not greater than $PREV's $PB (equal versions never reach the replacement callback)"
  fi
  ok "tag $TAG"
fi
