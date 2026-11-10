# Pinned vendor inputs (DESIGN §2.2 "Pins recorded by S14"). Sourced by the bootstrap scripts.
# Never /tmp: downloads go to Vendor/dl, sources to Vendor/<name>, build products to Vendor/build (all git-ignored).
# Toolchain pins live in Config/toolchain.lock; this file only pins sources.

NATIVE_ROOT="${${(%):-%x}:A:h:h:h}"
VENDOR="$NATIVE_ROOT/Vendor"
VENDOR_DL="$VENDOR/dl"
VENDOR_BUILD="$VENDOR/build"
source "$NATIVE_ROOT/Config/toolchain.lock"
export GOTOOLCHAIN=local

# Optional offline seed: the P1 spike's download cache (native/spike/s14-build/_deps), if present.
LP_VENDOR_SEED="${LP_VENDOR_SEED:-$NATIVE_ROOT/spike/s14-build/_deps}"

# OpenSSL 3.5 LTS
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"

# openvpn3: release branch tag only, never master
OPENVPN3_TAG=release/3.11.8
OPENVPN3_COMMIT=4f3bdef73245d4ee9e8216c5d65baccc9568f6ef
OPENVPN3_URL=https://github.com/OpenVPN/openvpn3

# asio as pinned by openvpn3 deps/lib-versions (asserted), plus openvpn3's deps/asio/patches
ASIO_TAG=asio-1-24-0
ASIO_SHA256=cbcaaba0f66722787b1a7c33afe1befb3a012b5af3ad7da7ff0f6b8c9b7a8a5b
ASIO_URL="https://github.com/chriskohlhoff/asio/archive/refs/tags/$ASIO_TAG.tar.gz"

# lz4 (openvpn3's lib-versions still names 1.8.3)
LZ4_VERSION=1.11.0
LZ4_SHA256=247e5fa64da5f7b75ee3dd3bed484076396c9ebe8254d9ccf693eb62800c5e26
LZ4_URL="https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VERSION.tar.gz"

# wireguard-apple upstream tip + Vendor/patches/wireguard-apple (W0, W1, W10, 26.0 floor, W4-W7, W11, W12, W13, W14 = bridge x/* deps; W9 dropped with the Swift WireGuardKit)
WGAPPLE_COMMIT=2fec12a6e1f6e3460b6ee483aa00ad29cddadab1
WGAPPLE_URL=https://git.zx2c4.com/wireguard-apple
# wireguard-go master by pseudo-version (includes 2631ce9 and b3bc704), set by patch W1
WGGO_PSEUDO=v0.0.0-20261024220952-b3bc704ef0ee
WG_EXPORT_COUNT=11           # nm -gU libwg-go.a | grep -c ' T _wg', asserted by Tools/build/check-symbols.sh (6 upstream: wgSetLogger, wgTurnOn, wgTurnOff, wgBumpSockets, wgDisableSomeRoamingForBrokenMobileSemantics, wgVersion; W11 removed wgSetConfig/wgGetConfig; + W10 wgTurnOnPF + W4 wgSendHandshake, wgSetEndpoint + W5 wgGetStats + W6 wgIsClosed; FaultInjection adds wgDebugCloseDevice)

fetch() { # url sha256 dest — uses the seed cache when it has the file, verifies the hash either way
  local url=$1 sha=$2 dest=$3
  if [[ ! -f "$dest" ]]; then
    mkdir -p "${dest:h}"
    if [[ -f "$LP_VENDOR_SEED/dl/${dest:t}" ]]; then cp "$LP_VENDOR_SEED/dl/${dest:t}" "$dest"
    else curl -fsSL -o "$dest.part" "$url" && mv "$dest.part" "$dest"; fi
  fi
  echo "$sha  $dest" | shasum -a 256 -c - >/dev/null || { echo "SHA-256 mismatch: $dest"; exit 1; }
}

assert_toolchain() {
  # From the build root, not the checkout (check-toolchain.sh: xcodebuild's relative spec cache); LP_TOOLCHAIN_CI=1
  # accepts another build of the pinned version, as check-toolchain.sh does (CI only; release.sh refuses it).
  local root="${LP_BUILD_ROOT:-$HOME/Code/lockplus-build}" xv; mkdir -p "$root"; xv=$(cd "$root" && xcodebuild -version)
  grep -qx "Build version $XCODE_BUILD" <<<"$xv" \
    || { [[ "${LP_TOOLCHAIN_CI:-}" == 1 ]] && grep -qx "Xcode $XCODE_VERSION" <<<"$xv"; } \
    || { echo "need Xcode $XCODE_VERSION ($XCODE_BUILD)"; exit 1; }
  [[ "$(go env GOVERSION)" == "go$GO_VERSION" ]] || { echo "need go$GO_VERSION"; exit 1; }
}

# ZIPFoundation (app target only; SPM exact pin in LockPlus.xcodeproj + Package.resolved, review
# docs/native/reviews/2026-10-27-zipfoundation.md). Also fetched by Tools/fuzz/build.sh for fuzz_zip_import.
ZIPFOUNDATION_VERSION=0.9.20
ZIPFOUNDATION_COMMIT=22787ffb59de99e5dc1fbfe80b19c97a904ad48d
ZIPFOUNDATION_URL=https://github.com/weichsel/ZIPFoundation
