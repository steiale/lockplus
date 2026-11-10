# Single source of truth for build-output locations (sourced, zsh). Never /tmp, never native/build.
# Internal disk and outside the nightly backup of the source volume.
# CI sets LP_BUILD_ROOT=${{ github.workspace }}/native/build so paths stay workspace-relative there.
export LP_BUILD_ROOT="${LP_BUILD_ROOT:-$HOME/Code/lockplus-build}"
# Per-machine settings that never go into the repo (gitignored): e.g. `export LP_NOTARY_PROFILE=<keychain profile>`.
LP_LOCAL_ENV="${${(%):-%x}:A:h}/local.zsh"
# `if`, not `&&`: a missing file must not make the sourced script return 1 (set -e callers exit silently; CI).
if [[ -f "$LP_LOCAL_ENV" ]]; then source "$LP_LOCAL_ENV"; fi
