#!/bin/zsh
# Builds the LPParsing fuzz targets (DESIGN §15.4) into $LP_BUILD_ROOT/fuzz/ (default ~/Code/lockplus-build/fuzz; never /tmp).
#
#   native/Tools/fuzz/build.sh            build all targets
#   native/Tools/fuzz/build.sh run        build, then run each target over its corpus (smoke run)
#
# libFuzzer mode: `-sanitize=fuzzer,address` when the Swift toolchain supports it (a swift.org toolchain, selected
# with TOOLCHAINS=… or LP_FUZZ_SWIFTC=/path/to/swiftc). Xcode 27.1's swiftc rejects -sanitize=fuzzer, so the
# fallback builds the same LLVMFuzzerTestOneInput entry points with ASan + SanitizerCoverage and the bundled
# StandaloneDriver.swift (corpus replay + seeded mutations). Corpus: corpus/<ovpn|wg|keychain|zip>/; crashes become
# fixtures under corpus/regressions/.
# fuzz_zip_import (draft 9.1, 2.0.2) compiles Packages/ProfileValidator/Sources/LPValidatorService/ArchiveReader.swift (+ LPModel/ZipModel.swift) against ZIPFoundation at the pins.sh pin, fetched
# into $LP_BUILD_ROOT/fuzz/ZIPFoundation (commit-checked) and built as its own Swift 5 module with the same sanitizers.
set -euo pipefail
here=${0:A:h}
source $here/../lib/paths.sh
pkg=$here/../../Packages/LockPlusCore/Sources
out=$LP_BUILD_ROOT/fuzz
mkdir -p $out
swiftc=${LP_FUZZ_SWIFTC:-$(xcrun -f swiftc)}
common=(-O -g -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macosx26.0 -swift-version 6 -module-name LPParsingFuzz
        -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances
        -enable-upcoming-feature MemberImportVisibility)
# LPModel and LPParsing are compiled as ONE module here, so LPParsing's `import LPModel` lines are dropped from
# copies under $LP_BUILD_ROOT/fuzz/src (the package sources are never edited).
src=$out/src; rm -rf $src; mkdir -p $src
for f in $pkg/LPModel/**/*.swift(N) $pkg/LPParsing/**/*.swift(N); do
  rel=${f#$pkg/}; mkdir -p $src/${rel:h}
  sed -E '/^import LPModel$/d' $f > $src/$rel
done
srcs=($src/**/*.swift(N))

probe=$out/.probe.swift
print '@_cdecl("LLVMFuzzerTestOneInput") public func f(_ d: UnsafePointer<UInt8>, _ n: Int) -> Int32 { 0 }' > $probe
if $swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -parse-as-library -sanitize=fuzzer,address $probe -o $out/.probe 2>/dev/null; then
  mode=libfuzzer
else
  mode=standalone
fi
rm -f $probe $out/.probe
print "fuzz build mode: $mode ($swiftc)"

typeset -A corpus=(fuzz_ovpn_tokenizer ovpn fuzz_ovpn_import ovpn fuzz_wg_parser wg fuzz_legacy_keychain keychain)
for t in ${(k)corpus}; do
  if [[ $mode == libfuzzer ]]; then
    $swiftc $common -parse-as-library -sanitize=fuzzer,address $srcs $here/targets/$t.swift -o $out/$t
  else
    $swiftc $common -sanitize=address -sanitize-coverage=edge,trace-cmp $srcs $here/targets/$t.swift \
      $here/driver/main.swift -o $out/$t
  fi
  print "built $out/$t"
done

# --- fuzz_zip_import: ZIPFoundation (Swift 5 module) + ProfileZip.swift ------------------------------------------------
source $here/../bootstrap/pins.sh
zf=$out/ZIPFoundation
if [[ ! -d $zf/.git ]] || [[ "$(git -C $zf rev-parse HEAD)" != $ZIPFOUNDATION_COMMIT ]]; then
  rm -rf $zf
  git clone -q --depth 1 --branch $ZIPFOUNDATION_VERSION $ZIPFOUNDATION_URL $zf 2>/dev/null
fi
[[ "$(git -C $zf rev-parse HEAD)" == $ZIPFOUNDATION_COMMIT ]] || { print "ZIPFoundation $ZIPFOUNDATION_VERSION is not $ZIPFOUNDATION_COMMIT"; exit 1; }
zmod=$out/zipmod; rm -rf $zmod; mkdir -p $zmod
if [[ $mode == libfuzzer ]]; then san=(-sanitize=fuzzer,address -parse-as-library); else san=(-sanitize=address -sanitize-coverage=edge,trace-cmp); fi
$swiftc -O -g -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-macosx26.0 -swift-version 5 -parse-as-library \
  -module-name ZIPFoundation -emit-module -emit-module-path $zmod/ZIPFoundation.swiftmodule -emit-library -static \
  -o $zmod/libZIPFoundation.a ${san:#-parse-as-library} $zf/Sources/ZIPFoundation/*.swift
zcommon=(${common:#LPParsingFuzz}); zcommon=(${zcommon:#-module-name} -module-name LPZipFuzz -I $zmod -L $zmod -lZIPFoundation)
# 2.0.2: the zip reader lives in the validator service package (ArchiveReader.swift); it imports LPModel for the zip
# model types (LPModel/ZipModel.swift); both are compiled as one module.
sed -E '/^import LPModel$/d' $here/../../Packages/ProfileValidator/Sources/LPValidatorService/ArchiveReader.swift > $src/ArchiveReader.swift
zsrcs=($src/ArchiveReader.swift $src/LPModel/ZipModel.swift $src/LPModel/ImportLimits.swift $here/targets/fuzz_zip_import.swift)   # round 1: ZipCaps defaults use OVPNImportLimits
if [[ $mode == libfuzzer ]]; then
  $swiftc $zcommon -parse-as-library -sanitize=fuzzer,address $zsrcs -o $out/fuzz_zip_import
else
  $swiftc $zcommon -sanitize=address -sanitize-coverage=edge,trace-cmp $zsrcs $here/driver/main.swift -o $out/fuzz_zip_import
fi
print "built $out/fuzz_zip_import"
corpus[fuzz_zip_import]=zip

if [[ ${1:-} == run ]]; then
  for t in ${(k)corpus}; do
    dirs=($here/corpus/${corpus[$t]} $here/corpus/regressions/$t(N))
    if [[ $mode == libfuzzer ]]; then
      $out/$t -runs=${FUZZ_ITERATIONS:-20000} -max_len=65536 $dirs
    else
      $out/$t $dirs
    fi
  done
fi
