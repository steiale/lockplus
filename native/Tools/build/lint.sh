#!/bin/zsh
# The .swiftlint.yml custom rules, implemented with perl so they run without SwiftLint (DESIGN §12.4), plus the
# SAFETY-marker check (Conventions, ref/swift-concurrency §0 rule 10). CI runs this AND `swiftlint lint --strict`.
set -euo pipefail
ROOT="${0:A:h:h:h}"; cd "$ROOT"
FILES=(${(f)"$(git ls-files -co --exclude-standard -- 'App/*.swift' 'App/**/*.swift' 'Tunnel/*.swift' 'Shared/*.swift' \
  'Tests/**/*.swift' 'Packages/LockPlusCore/Sources/**/*.swift' 'Packages/LockPlusCore/Tests/**/*.swift' \
  'Packages/TunnelEngine/Sources/**/*.swift' 'Packages/TunnelEngine/Tests/**/*.swift' | grep -v '\.generated\.swift$')"})
fails=0
rule() {   # name, perl regex (matched per line, comments stripped), message, [file filter ERE], [file exclude ERE]
  local name=$1 re=$2 msg=$3 filt=${4:-.} excl=${5:-}
  local hits
  hits=$(for f in $FILES; do [[ "$f" =~ $filt ]] || continue; [[ -n "$excl" && "$f" =~ $excl ]] && continue
    perl -ne 'BEGIN{$re=shift} my $l=$_; $l =~ s{//.*$}{}; print "$ARGV:$.: $_" if $l =~ /$re/; close ARGV if eof' "$re" "$f"; done)
  if [[ -n "$hits" ]]; then print -r -- "error: [$name] $msg"; print -r -- "$hits" | sed 's/^/  /'; fails=$((fails + 1)); fi
}
rule lp_sendable_framework_closure \
  '((saveToPreferences|loadFromPreferences|removeFromPreferences|loadAllFromPreferences|sendProviderMessage|setTunnelNetworkSettings|addObserver)\s*(\((?:[^()]|\([^()]*\))*\))?|remoteObjectProxyWithErrorHandler\s*\(?|(interruptionHandler|invalidationHandler)\s*=|fetchLastDisconnectError|setEventHandler\s*\(?|setCancelHandler\s*\(?|setRegistrationHandler\s*\(?|\.async(After)?\s*(\((?:[^()]|\([^()]*\))*\))?)\s*\{(?!\s*\@Sendable)' \
  'Closures handed to XPC/NE/Dispatch must be @Sendable (§0 MUST; S5/S15 crashes)'
rule lp_main_swift_closure '\{' 'No closure literals in main.swift (D73-11)' '/main\.swift$'
rule lp_c_callback_nonisolated '^(?!.*\bnonisolated\b)(?!.*SAFETY).*\@convention\(c\)' '@convention(c) closures must be nonisolated (§0)'
rule lp_no_filepath '#filePath' '#filePath leaks absolute paths into shipped binaries' '^(App|Tunnel|Shared|Packages/[^/]+/Sources)/'
rule lp_no_exit_in_tunnel '\bexit\s*\(' 'Never exit() in the extension' '^(Tunnel/|Packages/TunnelEngine/Sources/)'
rule lp_no_settings_level_policy '(NetworkSettings|networkSettings|settings)\.(includeAllNetworks|excludeLocalNetworks|enforceRoutes)\b' 'Kill-switch flags only on the protocol (invariant 4)'
rule lp_no_cancellation_shield 'withTaskCancellationShield' 'withTaskCancellationShield is unused (§7.1)'
rule lp_no_secret_in_logger '(log|logger|Logger)\b.*\\\([^)]*(password|passphrase|secret|privateKey|private_key|presharedKey|psk|token|credential)' 'No secrets in Logger (invariant 1)'
# Draft 9 (S2): the extension's deadlines run on the injected (in production: strict) clock; `asyncAfter` fired 3–5 s
# late at 50–300 s in the sysex, and `Task.sleep` has the same leeway. Test support is exempt.
rule lp_strict_deadlines '\.asyncAfter\b|\bTask\.sleep\b|DispatchQueue\.[a-z]+\(\)\.asyncAfter|\bSuspendingClock\(\)' \
  'Extension deadlines use the injected clock (StrictSuspendingClock in production), never asyncAfter/Task.sleep/SuspendingClock() (S2)' \
  '^(Tunnel/|Packages/TunnelEngine/Sources/TunnelEngine/)' 'Core/StrictClock\.swift$'
# Draft 9 (S2 E3): cancelTunnelWithError is open under includeAllNetworks and NE never calls stopTunnel after it. Only
# RealProviderHost wraps it; the controller calls it only with the kill switch off, after the teardown.
rule lp_cancel_tunnel_only_in_host 'cancelTunnelWithError' 'cancelTunnelWithError only in RealProviderHost (§7.2, S2 E3)' \
  '^(Tunnel/|Packages/TunnelEngine/Sources/TunnelEngine/)' 'Host/ProviderHost\.swift$'
# Draft 9 (S2 E10): no provider DNS under the flag; the one lookup (kill switch off, 2 s deadline) is GetAddrInfoResolver.
rule lp_no_provider_dns '\bgetaddrinfo\s*\(|\bgethostbyname|DNSServiceGetAddrInfo|\bCFHost' \
  'No name resolution in the extension except GetAddrInfoResolver (§9.3, S2 E10)' \
  '^(Tunnel/|Packages/TunnelEngine/Sources/TunnelEngine/)' 'Adapters/WireGuard/WireGuardBackend\.swift$'
# Draft 9.1 (ZIPFoundation review): every zip read goes through ZipStructure.validate first, so only ProfileZip.swift
# imports ZIPFoundation, and nothing is ever extracted to disk.
rule lp_zip_through_validator '^\s*(@\S+\s+)*import\s+ZIPFoundation\b' 'Only App/Services/ProfileZip.swift imports ZIPFoundation (review 2026-10-27)' \
  '.' '^App/Services/ProfileZip\.swift$'
rule lp_no_unzip_to_disk '\bunzipItem\b|\bzipItem\b|\.extract\([^)]*\bto:' 'Zip entries are read in memory only; never extract to disk (§3.5)'
rule lp_no_sync_xpc_proxy 'synchronousRemoteObjectProxyWithErrorHandler|remoteObjectProxy\b(?!WithErrorHandler)' 'No synchronous XPC proxy (§5.4)'

# SAFETY markers (shipped code; test fakes are exempt): every unsafe escape carries a `SAFETY:` comment within the 10 lines above it or on its line.
safety=$(for f in $FILES; do [[ "$f" =~ '(^Tests/|/Tests/|TestSupport/)' ]] && continue; perl -ne '
  BEGIN { @w = () }
  push @w, $_; shift @w if @w > 11;
  (my $code = $_) =~ s{//.*$}{};
  if ($code =~ /\@unchecked Sendable|nonisolated\(unsafe\)|MainActor\.assumeIsolated|\@preconcurrency|DispatchSemaphore/) {
    print "$ARGV:$.: $_" unless grep { /SAFETY/ } @w;
  }
  if (eof) { @w = (); close ARGV }' "$f"; done)
if [[ -n "$safety" ]]; then print -r -- "error: [lp_safety_marker] unsafe concurrency escape without a SAFETY: comment (Conventions)"; print -r -- "$safety" | sed 's/^/  /'; fails=$((fails + 1)); fi

# Buttons never truncate (owner review 2026-11-09; was the hosted ButtonTruncationTests source scan, which can't read the
# checkout from the test host): no `Button(` statement (its line and the next two) carries `.lineLimit(1)` or a
# truncation mode, the hero's actions are an ActionRow, and strips lay out their actions with StripActionsLayout.
trunc=$(for f in $FILES; do [[ "$f" =~ '^App/UI/' ]] || continue; perl -ne '
  BEGIN { @l = () } push @l, [$., $_]; if (eof) {
    for my $i (0..$#l) { my $t = $l[$i][1]; next unless $t =~ /Button\(/ && $t !~ /^\s*\/\//;
      my $stmt = join(" ", map { $_->[1] } @l[$i .. ($i + 2 > $#l ? $#l : $i + 2)]);
      print "$ARGV:$l[$i][0]: $t" if $stmt =~ /\.lineLimit\(1\)|truncationMode/; }
    @l = (); close ARGV }' "$f"; done)
if [[ -n "$trunc" ]]; then print -r -- "error: [lp_button_truncation] a button title can truncate (owner review 2026-11-09)"; print -r -- "$trunc" | sed 's/^/  /'; fails=$((fails + 1)); fi
grep -q 'ActionRow {' App/UI/Main/ProtectionHero.swift \
  || { print "error: [lp_action_rows] the hero's action row must be an ActionRow"; fails=$((fails + 1)); }
grep -q 'StripActionsLayout(trailing: true, header: true)' App/UI/Components/Strips.swift && grep -q 'StripActionsLayout(trailing: trailing, header: false)' App/UI/Components/Strips.swift \
  || { print "error: [lp_action_rows] InlineStrip and ActionRow must lay out their buttons with StripActionsLayout"; fails=$((fails + 1)); }

(( fails == 0 )) || { print "lint: $fails rule(s) failed"; exit 1; }
print "lint: OK (${#FILES} files)"
