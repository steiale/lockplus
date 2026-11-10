#!/bin/zsh
# "No extension" preview mode (docs/native/APP-ROOT.md): unsigned Debug build, launched with LP_PREVIEW_MODE=1.
# The real app root and UI run over simulated NE/XPC/system-extension backends. Touches no keychain, no VPN
# configuration, no system extension and no Go-app data. Data lives in
# ~/Library/Application Support/io.github.steiale.lockplus.mac.preview/ and is reset at every preview launch.
# Usage: Tools/dev/preview.sh [--no-build]
set -euo pipefail
source "${0:A:h:h}/release/common.sh"
cd "$NATIVE_ROOT"
mkdir -p "$LP_BUILD_ROOT"
DD="$LP_BUILD_ROOT/preview-dd"
if [[ "${1:-}" != --no-build ]]; then
  xcodebuild build -project LockPlus.xcodeproj -scheme LockPlus -configuration Debug -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO > "$LP_BUILD_ROOT/preview-build.log" 2>&1 \
    || { grep -E 'error:' "$LP_BUILD_ROOT/preview-build.log" | sort -u; fail "build (log: $LP_BUILD_ROOT/preview-build.log)"; }
fi
APP="$DD/Build/Products/Debug/LockPlus.app"
open -n --env LP_PREVIEW_MODE=1 "$APP"
ok "preview mode: $APP"
