#!/bin/zsh
# Fetches the pinned engine sources into native/Vendor (git-ignored), verifies every pin, applies the carried
# patches and seeds the Go module cache. Run before the first Xcode build and after any pin change.
#
#   Vendor/openvpn3          openvpn3 release/3.11.8 (commit asserted) + Vendor/patches/openvpn3/*.patch on branch `lockplus`
#   Vendor/asio              asio 1.24.0 tarball (SHA-256 == openvpn3 ASIO_CSUM) + openvpn3 deps/asio/patches
#   Vendor/lz4               lz4 1.11.0
#   Vendor/wireguard-apple   upstream 2fec12a + Vendor/patches/wireguard-apple/*.patch on branch `lockplus`
#                            (= the local SPM package; product WireGuardKitGo only, W13; DESIGN §2.2, §9.2)
#   Vendor/gomodcache        Go modules for libwg-go.a (GoBridge.xcconfig builds offline with GOPROXY=off)
#
# DESIGN §2.1 plans git submodules (openvpn3, openssl, a github.com/steiale/wireguard-apple fork). Until the owner
# creates the fork repository, this script is the pinned, hash-checked equivalent. Offline runs reuse the P1 spike
# cache (LP_VENDOR_SEED, default native/spike/s14-build/_deps). Never /tmp.
set -euo pipefail
source "${0:A:h}/pins.sh"
assert_toolchain
mkdir -p "$VENDOR_DL"

# --- openvpn3 ---------------------------------------------------------------------------------------------------
OV="$VENDOR/openvpn3"
if [[ ! -d "$OV/.git" ]]; then
  if [[ -d "$LP_VENDOR_SEED/src/openvpn3/.git" ]]; then git clone -q --no-hardlinks "$LP_VENDOR_SEED/src/openvpn3" "$OV"
  else git clone -q --depth 1 --branch "$OPENVPN3_TAG" "$OPENVPN3_URL" "$OV"; fi
fi
git -C "$OV" checkout -q -f -B lockplus "$OPENVPN3_COMMIT"
git -C "$OV" clean -qfdx
[[ "$(git -C "$OV" rev-parse HEAD)" == "$OPENVPN3_COMMIT" ]] || { echo "openvpn3 not at $OPENVPN3_COMMIT"; exit 1; }
grep -q "ASIO_CSUM=$ASIO_SHA256" "$OV/deps/lib-versions" || { echo "asio pin differs from openvpn3 deps/lib-versions"; exit 1; }
# Carried patch (branch `lockplus`): 0001 ClientOptions::Config::apply_process_globals + serialized constructions,
# so a profile evaluation beside a live session neither races nor rewrites openvpn3's process-wide state (TSan).
git -C "$OV" -c user.name="LockPlus Vendor" -c user.email=vendor@localhost am -q "$VENDOR"/patches/openvpn3/*.patch
grep -q "bool apply_process_globals = true;" "$OV/openvpn/client/cliopt.hpp" || { echo "openvpn3 patch 0001 not applied"; exit 1; }
echo "openvpn3 $OPENVPN3_TAG = ${OPENVPN3_COMMIT:0:8} + $(ls "$VENDOR"/patches/openvpn3/*.patch | wc -l | tr -d ' ') patch(es)"

# --- asio + openvpn3's patches (fresh extract every run) --------------------------------------------------------
fetch "$ASIO_URL" "$ASIO_SHA256" "$VENDOR_DL/$ASIO_TAG.tar.gz"
rm -rf "$VENDOR/asio" && mkdir -p "$VENDOR/asio"
tar -xzf "$VENDOR_DL/$ASIO_TAG.tar.gz" -C "$VENDOR/asio" --strip-components 1
n=0; for p in "$OV"/deps/asio/patches/*.patch; do patch -s -p1 -d "$VENDOR/asio" < "$p"; n=$((n+1)); done
[[ $n -eq 7 ]] || { echo "expected 7 asio patches, applied $n"; exit 1; }
echo "asio $ASIO_TAG + $n patches"

# --- lz4 --------------------------------------------------------------------------------------------------------
fetch "$LZ4_URL" "$LZ4_SHA256" "$VENDOR_DL/lz4-$LZ4_VERSION.tar.gz"
rm -rf "$VENDOR/lz4" && mkdir -p "$VENDOR/lz4"
tar -xzf "$VENDOR_DL/lz4-$LZ4_VERSION.tar.gz" -C "$VENDOR/lz4" --strip-components 1
echo "lz4 $LZ4_VERSION"

# --- wireguard-apple (WireGuardKit) -----------------------------------------------------------------------------
WG="$VENDOR/wireguard-apple"
if [[ ! -d "$WG/.git" ]]; then
  if [[ -d "$LP_VENDOR_SEED/src/wireguard-apple/.git" ]]; then git clone -q --no-hardlinks "$LP_VENDOR_SEED/src/wireguard-apple" "$WG"
  else git clone -q "$WGAPPLE_URL" "$WG"; fi
fi
git -C "$WG" cat-file -e "$WGAPPLE_COMMIT^{commit}" 2>/dev/null || git -C "$WG" fetch -q "$WGAPPLE_URL"
git -C "$WG" checkout -q -f -B lockplus "$WGAPPLE_COMMIT"
git -C "$WG" clean -qfdx
git -C "$WG" -c user.name="LockPlus Vendor" -c user.email=vendor@localhost am -q "$VENDOR"/patches/wireguard-apple/*.patch
grep -q "$WGGO_PSEUDO" "$WG/Sources/WireGuardKitGo/go.mod" || { echo "wireguard-go pin missing from go.mod"; exit 1; }
grep -q '\.macOS("26.0")' "$WG/Package.swift" || { echo "W0 26.0 floor missing"; exit 1; }
# Exported C surface (W11): source-level count of //export lines, FaultInjection-only api-apple-fault.go excluded.
# check-symbols.sh asserts the same number against the built libwg-go.a.
WG_GO="$WG/Sources/WireGuardKitGo"
exports=$(cat "$WG_GO"/api-apple*.go | grep -c '^//export wg' || true)   # whole file read, no early exit
exports_fault=$(grep -c '^//export wg' "$WG_GO/api-apple-fault.go" || true)
(( exports - exports_fault == WG_EXPORT_COUNT )) || { echo "wireguard-go exports: $((exports - exports_fault)) in source, pins.sh WG_EXPORT_COUNT=$WG_EXPORT_COUNT"; exit 1; }
! grep -rqE 'wgGetConfig|wgSetConfig' "$WG_GO/wireguard.h" "$WG_GO"/api-apple*.go 2>/dev/null \
  || { echo "W11 not applied: wgGetConfig/wgSetConfig still present"; exit 1; }
[[ ! -e "$WG/Sources/WireGuardKit" && ! -e "$WG/Sources/WireGuardKitC" ]] || { echo "W13 not applied: Swift WireGuardKit present"; exit 1; }
echo "wireguard-apple ${WGAPPLE_COMMIT:0:7} + $(ls "$VENDOR"/patches/wireguard-apple/*.patch | wc -l | tr -d ' ') patches"

# --- Go modules (offline afterwards: GoBridge.xcconfig sets GOPROXY=off) ----------------------------------------
export GOMODCACHE="$VENDOR/gomodcache" GOFLAGS=-modcacherw
if [[ ! -d "$GOMODCACHE/cache" && -d "$LP_VENDOR_SEED/gomodcache/cache" ]]; then
  mkdir -p "$GOMODCACHE"; cp -R "$LP_VENDOR_SEED/gomodcache/" "$GOMODCACHE/"
fi
( cd "$WG/Sources/WireGuardKitGo" && GOPROXY="${LP_GOPROXY:-file://$GOMODCACHE/cache/download,https://proxy.golang.org}" go mod download && go mod verify >/dev/null )
# W12 tests: pfTun.Close wakes a blocked reader (T5), handles are never reused (T13). Offline (GOPROXY=off via the module cache).
( cd "$WG/Sources/WireGuardKitGo" && GOPROXY=off go test -count=1 . ) || { echo "wireguard-go fork tests failed"; exit 1; }
echo "go modules OK ($GOMODCACHE), fork tests OK"
echo "vendor OK"
