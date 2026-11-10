#!/bin/zsh
# Exports the Go tokenizer's test vectors for the native LPParsing differential tests (DESIGN §15.1) and seeds
# the fuzz corpus. The exporter is injected into internal/ovpn with `go test -overlay`; the Go tree is not modified.
#
#   native/Tools/fuzz/govectors/export.sh
#
# Writes native/Packages/LockPlusCore/Tests/LPParsingTests/GoVectors.generated.swift and
# native/Tools/fuzz/corpus/ovpn/go-*. Scratch files go to $LP_BUILD_ROOT/govectors, never /tmp.
set -euo pipefail
here=${0:A:h}
source ${here:h:h}/lib/paths.sh
repo=${here:h:h:h:h}
scratch=$LP_BUILD_ROOT/govectors
mkdir -p $scratch
cat > $scratch/overlay.json <<EOF
{"Replace": {"$repo/internal/ovpn/zz_lpparsing_export_test.go": "$here/lpparsing_export_test.go"}}
EOF
cd $repo
GOFLAGS= GOTMPDIR=$scratch \
LP_VECTORS_SWIFT=$repo/native/Packages/LockPlusCore/Tests/LPParsingTests/GoVectors.generated.swift \
LP_VECTORS_CORPUS=$repo/native/Tools/fuzz/corpus/ovpn \
  go test -count=1 -overlay $scratch/overlay.json -run '^TestExportLPParsingVectors$' -v ./internal/ovpn | tail -3
