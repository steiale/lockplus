#!/bin/zsh
# Signed Debug (Apple Development) build on the dev Mac (DESIGN §2.4, §2.6). Needs the development profiles from
# native/scripts/provision-product.sh. Never passes -allowProvisioningUpdates (that is provisioning, Terminal.app only).
# Stamps CFBundleVersion = LP_BUILD_NUMBER.<unix minutes>, so every dev build is a new extension version.
# Usage: Tools/dev/build.sh [Debug|FaultInjection]
set -euo pipefail
source "${0:A:h:h}/release/common.sh"
cd "$NATIVE_ROOT"
CONF=${1:-Debug}
[[ "$CONF" == Debug || "$CONF" == FaultInjection ]] || fail "dev builds are Debug or FaultInjection (Release is release.sh)"
mkdir -p "$LP_BUILD_ROOT"
STAMP=$(( $(date +%s) / 60 ))
xcodebuild build -project LockPlus.xcodeproj -scheme LockPlus -configuration "$CONF" \
  -derivedDataPath "$LP_BUILD_ROOT/dev" LP_DEV_STAMP=$STAMP > "$LP_BUILD_ROOT/dev-build.log" 2>&1 \
  || { grep -E 'error:' "$LP_BUILD_ROOT/dev-build.log" | sort -u; fail "build (log: $LP_BUILD_ROOT/dev-build.log)"; }
APP="$LP_BUILD_ROOT/dev/Build/Products/$CONF/LockPlus.app"
Tools/release/version-check.sh --app "$APP" --signed
ok "$APP ($CONF, CFBundleVersion $(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist"))"
