#!/bin/zsh
# The ONE archive invocation, shared by CI and release.sh (DESIGN §12.4, ref/toolchain §7.3): unsigned Release
# archive with Repro.xcconfig. Output: $LP_OUT/LockPlus.xcarchive (default $LP_BUILD_ROOT/release).
# Usage: build-unsigned.sh [--asan]     --asan: test-only ASan build (never released; §2.2)
set -euo pipefail
source "${0:A:h:h}/release/common.sh"
cd "$NATIVE_ROOT"
OUT="${LP_OUT:-$LP_BUILD_ROOT/release}"; OUT="${OUT:A}"
mkdir -p "$OUT"
check_no_stray_source_dirs
Tools/build/check-toolchain.sh
Tools/bootstrap/vendor.sh   # unconditional: re-verifies every pin and re-applies the patches (cheap when cached)
Tools/bootstrap/openssl.sh

XC="$NATIVE_ROOT/Config/Repro.xcconfig"
if [[ "${1:-}" == --asan ]]; then
  # -xcconfig takes one file: combine Repro + ASan in the build dir (never /tmp).
  XC="$OUT/ReproASan.xcconfig"
  print "#include \"$NATIVE_ROOT/Config/Repro.xcconfig\"\n#include \"$NATIVE_ROOT/Config/ASan.xcconfig\"" > "$XC"
fi
RESOLVED=()
[[ -f LockPlus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved ]] && RESOLVED=(-onlyUsePackageVersionsFromResolvedFile)

step "xcodebuild archive (Release, unsigned, $(basename "$XC"))"
rm -rf "$OUT/LockPlus.xcarchive"
xcodebuild archive -project LockPlus.xcodeproj -scheme LockPlus -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$OUT/LockPlus.xcarchive" \
  -derivedDataPath "$OUT/DerivedData" \
  -clonedSourcePackagesDirPath "$OUT/SourcePackages" \
  "${RESOLVED[@]}" \
  -xcconfig "$XC" \
  LP_CHECKOUT_ROOT="${NATIVE_ROOT:h}" LP_BUILD_ROOT="$OUT" \
  CODE_SIGNING_ALLOWED=NO > "$OUT/archive.log" 2>&1 || { grep -E 'error:' "$OUT/archive.log" | sort -u | sed -n '1,30p'; fail "archive (log: $OUT/archive.log)"; }
APP=$(resolve_app "$OUT/LockPlus.xcarchive")
[[ -x "$(ext_bin_of "$APP")" ]] || fail "archive lacks the embedded extension (Generic Xcode Archive?)"
# DESIGN §2.3 / ref/sparkle C10: a non-sandboxed app ships no Sparkle XPC services. Stripped here, on the unsigned
# archive (an Xcode Run Script phase runs before SPM embeds the framework, so it can't do this); sign-inside-out.sh
# signs the framework afterwards and refuses a bundle that still has them.
SPK="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPK/Versions/B" ]] || fail "Sparkle.framework missing from the archive"
rm -rf "$SPK/Versions/B/XPCServices" "$SPK/XPCServices"
[[ ! -e "$SPK/Versions/B/XPCServices" ]] || fail "Sparkle XPCServices still present"
ok "$APP (Sparkle XPCServices stripped)"
