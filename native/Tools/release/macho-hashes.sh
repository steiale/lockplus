#!/bin/zsh
# Relative path + SHA-256 of every Mach-O in a bundle, sorted (DESIGN §12.4 `repro`, ref/toolchain §9.3).
set -euo pipefail
cd "${1:?usage: macho-hashes.sh <bundle>}"
find . -type f -print0 | sort -z | while IFS= read -r -d '' f; do
  if [[ "$(file -b "$f")" == Mach-O* ]]; then printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"; fi
done
