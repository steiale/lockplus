#!/bin/zsh
# S7 duplicate-symbol check (DESIGN §9.2, §12.4): strong global definitions (nm -gUm, incl. hidden "private
# external", which still clash in a static link) compared pairwise across libwg-go.a, OpenSSL,
# openvpn3+asio, lz4 and the ObjC++ wrapper; openvpn3's weak symbols against every strong list. Expected: 0.
# Also (DESIGN §8.1, PENDING-FOLD 29): no MacTun/TunMac/MacLifeCycle symbols, no undefined _system/_popen/_exec*/_posix_spawn*/
# _fork/_vfork and no /sbin/route|ifconfig strings. `_execve` alone is allowed, and only when `nm -A -u` attributes it
# exclusively to libwg-go.a members (Go's runtime/syscall; present before our patches). libwg-go.a export count == WG_EXPORT_COUNT.
# (The "ifconfig" word alone is openvpn3's option text, so the string check is on the tool paths.)
# Usage: check-symbols.sh <derivedDataPath or archive DerivedData> [extension-binary]
set -euo pipefail
source "${0:A:h:h}/release/common.sh"
DD=${1:?usage: check-symbols.sh <derivedDataPath> [extension-binary]}; EXT=${2:-}
source "${0:A:h:h}/bootstrap/pins.sh"   # WG_EXPORT_COUNT
OUT="$LP_BUILD_ROOT/symbols"; rm -rf "$OUT"; mkdir -p "$OUT"
# Active arch only (arm64): Xcode keeps x86_64 intermediates next to the arm64 ones; never sample "the first" object.
ARCH_RE='/Objects-normal/arm64/'
allfind() { local out; out=$(find "$DD" "$@" -print 2>/dev/null) || true; print -r -- "$out"; }   # capture, no `| head`
objs_in() { allfind -type f -name '*.o' -path "*$1*" -path "*$ARCH_RE*" ! -path '*/Binary/*'; }  # $1: path fragment
WGL=(${(f)"$(allfind -type f -name libwg-go.a)"}); WG=${WGL[1]:-}
SSL="$NATIVE_ROOT/Vendor/build/OpenSSL.xcframework/macos-arm64/libOpenSSL.a"
COREL=(${(f)"$(allfind -type f -path '*OpenVPN3Shim*' -path "*$ARCH_RE*" ! -path '*/Binary/*' -name ovpn_core.o)"}); CORE=${COREL[1]:-}
OBJDIR=${CORE:h}
ALLOBJS=(${(f)"$(allfind -type f -name '*.o' -path "*$ARCH_RE*" ! -path '*/Binary/*')"})
for f in "$WG" "$SSL" "$CORE"; do [[ -n "$f" && -e "$f" ]] || fail "input missing under $DD (build the LockPlus scheme first): ${f:-?}"; done
# W13: the Swift WireGuardKit and WireGuardKitC are not built at all; their objects must not appear.
(( ${#${(f)"$(objs_in WireGuardKitC)"}} == 0 )) || fail "WireGuardKitC objects present (W13 says they are not built)"

defs() { nm -gUm "$@" 2>/dev/null | grep -v '^$' | grep -v ':$' | grep -v ' weak ' | awk '{print $NF}' | sort -u; }
weak() { nm -gUm "$@" 2>/dev/null | grep ' weak ' | awk '{print $NF}' | sort -u; }
defs "$WG" > "$OUT/wg-go.txt"
defs "$SSL" > "$OUT/openssl.txt"
defs "$OBJDIR/ovpn_core.o" "$OBJDIR/data_epoch_unity.o" > "$OUT/openvpn3+asio.txt"
defs "$OBJDIR/lz4_unity.o" > "$OUT/lz4.txt"
defs "$OBJDIR/OpenVPN3Shim.o" > "$OUT/shim-objc.txt"
weak "$OBJDIR/ovpn_core.o" "$OBJDIR/data_epoch_unity.o" > "$OUT/openvpn3+asio.weak.txt"

dups=0
files=("$OUT"/wg-go.txt "$OUT"/openssl.txt "$OUT"/openvpn3+asio.txt "$OUT"/lz4.txt "$OUT"/shim-objc.txt "$OUT"/openvpn3+asio.weak.txt)
for ((i = 1; i <= ${#files}; i++)); do
  for ((j = i + 1; j <= ${#files}; j++)); do
    n=$(comm -12 "${files[i]}" "${files[j]}" | wc -l | tr -d ' ')
    if (( n > 0 )); then
      print "  ${files[i]:t:r} x ${files[j]:t:r}: $n"; comm -12 "${files[i]}" "${files[j]}" | sed -n '1,10p' | sed 's/^/    /'
      dups=$((dups + n))
    fi
  done
done
# Watch list (§9.2): generic C names libwg-go.a exports; _x_crosscall2_ptr included.
for s in _fatalf _threadentry _crosscall1 _crosscall2 _x_crosscall2_ptr; do
  owners=$(grep -lx -- "$s" "$OUT"/*.txt 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ' || true)
  [[ -z "$owners" || "$owners" == "wg-go.txt " ]] || { print "  watch-list symbol $s defined in: $owners"; dups=$((dups + 1)); }
done
(( dups == 0 )) || fail "$dups duplicate strong symbols"
ok "0 duplicate strong symbols ($(wc -l < "$OUT/wg-go.txt" | tr -d ' ') wg-go, $(wc -l < "$OUT/openssl.txt" | tr -d ' ') OpenSSL, $(wc -l < "$OUT/openvpn3+asio.txt" | tr -d ' ') openvpn3+asio)"

# --- §8.1 forbidden symbols / strings -------------------------------------------------------------------------------
step "forbidden symbols and strings (DESIGN §8.1, PENDING-FOLD 29)"
FORBID_RE='_(system|popen|exec[a-z]*|posix_spawn[a-z]*|fork|vfork)'
undef=""   # lines: <symbol>\t<owner = archive:member or object file>
for f in "${ALLOBJS[@]}" "$WG" "$SSL"; do
  u=$(nm -A -u "$f" 2>/dev/null | awk -v re="^$FORBID_RE\$" '$NF ~ re {s=$NF; $NF=""; sub(/ +$/, ""); sub(/:$/, ""); print s "\t" $0}' || true)
  [[ -z "$u" ]] || undef+="$u"$'\n'
done
print -r -- "$undef" | sed '/^$/d' | sort -u > "$OUT/forbidden-undefined.txt"
# allowed: _execve attributed to a libwg-go.a member; everything else is a violation
viol=$(awk -F'\t' '!($1 == "_execve" && $2 ~ /libwg-go\.a/)' "$OUT/forbidden-undefined.txt")
if [[ -n "$viol" ]]; then print "  forbidden undefined symbols:"; print -r -- "$viol" | sed 's/^/    /'; fail "forbidden symbol reference outside the allowlist"; fi
n_exec=$(grep -c '^_execve	' "$OUT/forbidden-undefined.txt" || true)
ok "no _system/_popen/_exec*/_posix_spawn*/_fork/_vfork reference (${n_exec} _execve, all from libwg-go.a)"

mactun=""
for f in "${ALLOBJS[@]}" $EXT; do
  [[ -f "$f" ]] || continue
  m=$(nm -a "$f" 2>/dev/null | grep -E 'MacTun|TunMac|MacLifeCycle' | sed -n '1,3p' || true)
  [[ -z "$m" ]] || mactun+="${f:t}: $m"$'\n'
done
[[ -z "$mactun" ]] || { print -r -- "$mactun" | sed 's/^/    /'; fail "MacTun/TunMac/MacLifeCycle symbols present (openvpn/tun/mac must be excluded, USE_TUN_BUILDER set)"; }
ok "no MacTun/TunMac/MacLifeCycle symbols in ${#ALLOBJS} arm64 objects${EXT:+ and the extension}"

if [[ -n "$EXT" ]]; then
  [[ -f "$EXT" ]] || fail "extension binary not found: $EXT"
  # The linked binary cannot be attributed per object: any forbidden import other than _execve fails, and _execve is only
  # tolerated because the object scan above attributed it to libwg-go.a.
  eu=$(nm -u "$EXT" 2>/dev/null | awk -v re="^$FORBID_RE\$" '$NF ~ re {print $NF}' | sort -u || true)
  bad=$(grep -vx '_execve' <<<"$eu" || true)
  [[ -z "$bad" ]] || fail "extension imports forbidden symbols: $(print -r -- $bad)"
  if grep -qx '_execve' <<<"$eu"; then (( n_exec > 0 )) || fail "extension imports _execve but no libwg-go.a object accounts for it"; fi
  es=$(strings -a "$EXT"); [[ -n "$es" ]] || fail "strings produced no output for $EXT"
  ! grep -Eq '/sbin/route|/sbin/ifconfig|/usr/sbin/route' <<<"$es" || fail "extension contains /sbin/route or ifconfig strings"
  ok "extension: only _execve (libwg-go), no /sbin/route or ifconfig strings"
fi

# --- ZIPFoundation is app-only (DESIGN §2.2, draft 9.1) ------------------------------------------------------------------
step "ZIPFoundation never in the extension (§2.2)"
EXTS=(${(f)"$(allfind -type f -path '*.systemextension/Contents/MacOS/*')"}); [[ -n "$EXT" ]] && EXTS+=("$EXT")
nx=0
for x in "${EXTS[@]}"; do
  [[ -n "$x" && -f "$x" ]] || continue
  xs=$(nm -a "$x" 2>/dev/null || true); xs+=$(strings -a "$x")
  [[ -n "$xs" ]] || fail "nm/strings produced no output for $x"
  ! grep -q 'ZIPFoundation' <<<"$xs" || fail "ZIPFoundation symbols or strings in the extension: $x"
  [[ -z "$(find "${x:h:h}" -iname '*ZIPFoundation*' -print)" ]] || fail "ZIPFoundation resources in the extension bundle: ${x:h:h}"
  nx=$((nx + 1))
done
(( nx > 0 )) || fail "no extension binary under $DD${EXT:+ or $EXT} to check for ZIPFoundation"
ok "no ZIPFoundation in $nx extension binary/binaries"

# --- libwg-go.a export surface (pins.sh WG_EXPORT_COUNT) -----------------------------------------------------------------
wgsyms=$(nm -gU "$WG" 2>/dev/null | grep ' T _wg' || true)
n_wg=$(grep -c . <<<"$wgsyms" || true)
if grep -q ' _wgDebugCloseDevice$' <<<"$wgsyms"; then
  [[ "$WG" == *FaultInjection* ]] || fail "wgDebugCloseDevice exported from a non-FaultInjection libwg-go.a ($WG)"
  n_wg=$((n_wg - 1))
fi
! grep -Eq ' _wg(Get|Set)Config$' <<<"$wgsyms" || fail "libwg-go.a still exports wgGetConfig/wgSetConfig (patch W11)"
(( n_wg == WG_EXPORT_COUNT )) || fail "libwg-go.a exports $n_wg wg* functions, pins.sh WG_EXPORT_COUNT=$WG_EXPORT_COUNT (stale libwg-go.a, or update the pin deliberately)"
ok "libwg-go.a exports $n_wg wg* functions (== WG_EXPORT_COUNT)"
