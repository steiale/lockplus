#!/bin/zsh
# Asserts the pinned toolchain from Config/toolchain.lock (DESIGN §2.1, §12.4). Used by CI and release.sh.
# Usage: check-toolchain.sh [--no-go]   (--no-go: jobs that never build libwg-go.a)
# LP_TOOLCHAIN_CI=1 (CI workflows only): the hosted xcode-27 image may carry another build of the pinned Xcode version
# (27.2 RC 27B48 vs the pinned 27B52); CI then accepts the same version with a warning. release.sh refuses the variable,
# so release builds stay pinned to the exact build.
set -euo pipefail
ROOT="${0:A:h:h:h}"
source "$ROOT/Config/toolchain.lock"
source "$ROOT/Tools/lib/paths.sh"
# Run from the build root, never from the checkout: on the first run of a new Xcode, xcodebuild can write its spec
# cache relative to the cwd (native/27.2-27B52/Xcode/CachedSpecifications-xcodebuild, 2026-10-30).
mkdir -p "$LP_BUILD_ROOT"
XV=$(cd "$LP_BUILD_ROOT" && xcodebuild -version)   # capture first: grep -q on a pipe can SIGPIPE under pipefail
if ! grep -qx "Build version $XCODE_BUILD" <<<"$XV"; then
  if [[ "${LP_TOOLCHAIN_CI:-}" == 1 ]] && grep -qx "Xcode $XCODE_VERSION" <<<"$XV"; then
    echo "::warning::CI runs Xcode $XCODE_VERSION build $(sed -n 's/^Build version //p' <<<"$XV"), not the pinned $XCODE_BUILD (release builds stay pinned)"
  else
    echo "need Xcode $XCODE_VERSION ($XCODE_BUILD), have: $(tr '\n' ' ' <<<"$XV")"; exit 1
  fi
fi
if [[ "${1:-}" != --no-go ]]; then
  export GOTOOLCHAIN=local
  [[ "$(go env GOVERSION)" == "go$GO_VERSION" ]] || { echo "need go$GO_VERSION, have $(go env GOVERSION)"; exit 1; }
fi
echo "toolchain OK: Xcode $XCODE_VERSION ($(sed -n 's/^Build version //p' <<<"$XV"))"
