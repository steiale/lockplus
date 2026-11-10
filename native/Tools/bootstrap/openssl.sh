#!/bin/zsh
# OpenSSL 3.5 LTS -> Vendor/build/OpenSSL.xcframework (static, arm64, minos 26.0), consumed by OpenVPN3Shim as a
# local binaryTarget (DESIGN §2.2, confirmed by S14). Built BEFORE Xcode: a local package can't consume an
# External Build System target's output at compile time, and openvpn3 needs OpenSSL's generated headers.
# no-autoload-config: no openssl.cnf read on first use (D7-5, §8.1).
set -euo pipefail
source "${0:A:h}/pins.sh"
assert_toolchain
MIN_MACOS=26.0

TARBALL="$VENDOR_DL/openssl-$OPENSSL_VERSION.tar.gz"
fetch "$OPENSSL_URL" "$OPENSSL_SHA256" "$TARBALL"

SRC="$VENDOR/openssl"
XCF="$VENDOR_BUILD/OpenSSL.xcframework"
STAMP="$VENDOR_BUILD/openssl.stamp"
WANT="$OPENSSL_VERSION $OPENSSL_SHA256 $MIN_MACOS $(shasum -a 256 "${0:A}" | cut -d' ' -f1)"
LIB="$XCF/macos-arm64/libOpenSSL.a"
# The stamp also records the shasum of libOpenSSL.a itself, so a stale, truncated or tampered cached
# Vendor/build (CI restores it from actions/cache) is rebuilt instead of trusted.
lib_sha() { shasum -a 256 "$LIB" | cut -d' ' -f1; }
assert_lib() {   # arm64-only, minos == MIN_MACOS on every object
  local archs minos
  archs=$(lipo -archs "$LIB")
  [[ "$archs" == arm64 ]] || { echo "libOpenSSL.a is not arm64-only: '$archs'"; exit 1; }
  minos=$(otool -l "$LIB" | awk '$1 == "minos" {print $2}' | sort -u)
  [[ "$minos" == "$MIN_MACOS" ]] || { echo "libOpenSSL.a minos is '$(print -r -- $minos)', want $MIN_MACOS only"; exit 1; }
}
if [[ -d "$XCF" && -f "$STAMP" && -f "$LIB" && "$(cat "$STAMP")" == "$WANT $(lib_sha)" ]]; then
  assert_lib; echo "OpenSSL.xcframework up to date"; exit 0
fi

rm -rf "$SRC" "$VENDOR_BUILD/openssl-install" "$VENDOR_BUILD/openssl-stage" "$XCF" "$STAMP"
mkdir -p "$SRC" "$VENDOR_BUILD"
tar -xzf "$TARBALL" -C "$SRC" --strip-components 1

# Reproducibility: fixed build date from the tarball's top directory (a submodule would use its commit time).
export SOURCE_DATE_EPOCH=$(stat -f %m "$SRC/VERSION.dat")

# No absolute build path may reach the binary (verify.sh static greps every Mach-O for /Users, /Volumes, /private/var/folders).
# OpenSSL embeds two things: ENGINESDIR/MODULESDIR (from --prefix) and the full compiler command line (buildinf.h).
#   - the prefix is a fixed logical path; `install_dev` stages it under DESTDIR (nothing is ever installed there);
#   - the path-prefix map goes into a CC wrapper found via PATH, so the command line OpenSSL records is just `lp-cc ...`.
LOGICAL_PREFIX=/usr/local/lockplus-openssl
STAGE="$VENDOR_BUILD/openssl-stage"
PREFIX="$STAGE$LOGICAL_PREFIX"
CCBIN="$VENDOR_BUILD/cc-bin"
rm -rf "$STAGE" "$CCBIN"; mkdir -p "$CCBIN"
printf '#!/bin/sh\nexec cc "-ffile-prefix-map=%s=openssl-%s" "$@"\n' "$SRC" "$OPENSSL_VERSION" > "$CCBIN/lp-cc"
chmod +x "$CCBIN/lp-cc"
export PATH="$CCBIN:$PATH"

cd "$SRC"
./Configure darwin64-arm64-cc CC=lp-cc no-shared no-module no-tests no-docs no-autoload-config \
  --prefix="$LOGICAL_PREFIX" --openssldir=/private/etc/ssl --libdir=lib \
  -mmacosx-version-min=$MIN_MACOS >"$VENDOR_BUILD/openssl-build.log" 2>&1
make -j"$(sysctl -n hw.ncpu)" build_libs >>"$VENDOR_BUILD/openssl-build.log" 2>&1
make install_dev DESTDIR="$STAGE" >>"$VENDOR_BUILD/openssl-build.log" 2>&1

ZERO_AR_DATE=1 libtool -static -D -o "$PREFIX/libOpenSSL.a" "$PREFIX/lib/libssl.a" "$PREFIX/lib/libcrypto.a" 2>/dev/null
mkdir -p "$PREFIX/Headers"
cp -R "$PREFIX/include/openssl" "$PREFIX/Headers/"
xcodebuild -create-xcframework -library "$PREFIX/libOpenSSL.a" -headers "$PREFIX/Headers" -output "$XCF" >/dev/null

assert_lib
echo "libOpenSSL.a: arm64 only, minos $MIN_MACOS"
grep -m1 OPENSSL_FULL_VERSION_STR "$XCF"/macos-arm64/Headers/openssl/opensslv.h
print -r -- "$WANT $(lib_sha)" > "$STAMP"
echo "OpenSSL.xcframework OK"
