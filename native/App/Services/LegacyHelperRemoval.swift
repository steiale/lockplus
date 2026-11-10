import Carbon.OpenScripting
import Foundation
import os
import Synchronization

/// E2E-5 F1 (DESIGN §13.3a): native 2.0 removes a leftover Go root helper itself, for users who never ran the Go
/// v1.2.0 "Farewell". One privileged action after ONE administrator authentication, through
/// `do shell script … with administrator privileges` (osascript): the only supported one-shot elevation for an app
/// (`AuthorizationExecuteWithPrivileges` is deprecated and unavailable in Swift; an `SMAppService` daemon would install
/// a permanent root helper, the opposite of the goal).
///
/// The shell script is a compile-time constant in the signed binary and is handed to osascript as an argument (no
/// file in the user-writable bundle, no interpolation, no AppleScript quoting). Nothing from the user, the Go app or
/// the file system is ever put into it. It is idempotent and refuses rather than guesses:
/// - a Go tunnel or its kill switch is up (tunnel-state files, unless `tunnelstale`, or rules in the pf anchor
///   `com.apple/wireguide` or its legacy `/dns` sub-anchor) → `busy` (§4.5: never while the old helper protects the Mac);
/// - the helper isn't loaded but its DNS journal exists (its startup would replay it; after the removal nothing would)
///   → `dns-unrestored` (review E2E-5 F1-2);
/// - the plist isn't a root-owned regular file whose `Label` and `ProgramArguments[0]` are the Go helper's → `not-go-plist`;
/// - the binary isn't a root-owned regular file signed by team M53GHX9FAY with identifier `lockplus-helper` (the
///   requirement the Go installer pins, `internal/elevate/spawn_darwin.go`) → `not-go-binary`.
/// Then `launchctl bootout` (the helper's SIGTERM handler flushes its pf anchor and restores DNS from its journal),
/// a wait until launchd no longer knows the label, and removal at the exact known paths only: the plist, the binary,
/// the bundled `openvpn` (only if signed as the Go app's `openvpn`), the socket and its directory, the root-only log,
/// the helper's `tunnel-states` and `ovpn-run` (generated profiles with keys), and its data directory unless it still
/// holds a DNS journal or `pf-was-enabled` (the §4.5 banner then names DNS and System Settings). It ends with a verification and one `LP_RESULT=` line.
///
/// Migration matrix (2026-11-09): every generation of the old helper is handled in the same run. LockPlus 1.0.57–1.1.0's
/// as above; WireGuide+ 1.0.1–1.0.56's `io.github.steiale.wireguide-plus.helper` (plist, binary, `/var/run/wireguide-plus`,
/// `/var/log/wireguide-plus-helper.log`, `/Library/Application Support/wireguide-plus`), identified by its exact label,
/// program path and root ownership (early builds weren't Developer ID signed); and `com.wireguide.helper` only when its
/// binary is signed by our team (WireGuide+ 1.0.0): otherwise it is upstream WireGuide's live helper and stays untouched,
/// as does everything else of upstream's. The busy, DNS-journal and old-app refusals apply to all of them.
///
/// E2E-7 F3 review N1: the body starts with `cd /` (no relative path resolves under the caller's directory) and `set -f`
/// (no globbing anywhere; the functions' unquoted, newline-split lists rely on it).
///
/// Fable pre-release A-1: `script` runs `body` under `env -i` with a fixed PATH (a quoted heredoc, so nothing is
/// expanded on the way): the root shell never sees this app's environment (`SHELLOPTS`, `BASH_XTRACEFD`, `ENV`, …),
/// whichever runner started it. A-3: as root, the body refuses while the old app runs (`old-app-running`), right before
/// the bootout (the app's own check can be stale by then).
enum LegacyHelperRemoval {
    /// The exact environment of the root shell.
    static let cleanPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let script = wrapped(body)
    /// Fable follow-up LOW-2: the body is one single-quoted `sh -c` argument (each `'` becomes `'\''`), so no
    /// here-document and no temp file is involved anywhere.
    static func wrapped(_ body: String) -> String {
        "exec /usr/bin/env -i PATH=\(cleanPath) /bin/sh -c '" + body.replacingOccurrences(of: "'", with: #"'\''"#) + "'\n"
    }
    /// The old app's executable, as root sees it in `pgrep -f` (A-3).
    static let oldAppPattern = "/Contents/MacOS/(lockplus|wireguide-plus)( |$)"
    /// WireGuide+ 1.0.0's executable (`wireguide`, as upstream WireGuide's): checked only when its helper is ours (U3),
    /// so a running upstream WireGuide never blocks a removal (Fable follow-up INFO).
    static let wireGuide100Pattern = "/Contents/MacOS/wireguide( |$)"

    /// E2E-6 N1: `journalstale <journal>` exits 0 when an un-replayed DNS journal would restore nothing, so it can go.
    /// Per network service it recorded (review 650b251):
    /// - recorded nothing (`null`, as Go 1.1.0 writes an Automatic baseline, or `[]`): fine while the service shows
    ///   Automatic; any resolver there now is the VPN's → 1 ("set DNS to Automatic and try again" works);
    /// - recorded servers (the user's own, e.g. a Pi-hole): fine only while exactly those are set again; anything else →
    ///   2: only the old helper can put them back, at its next start ("Restart your Mac …"). LockPlus never replays it.
    /// Exits 1 (fail closed) on anything unexpected: not a dictionary, a value that is neither null nor an array of
    /// ≤ 64 strings, a service name plutil can't address (`.`, `@`, empty), or a networksetup error (non-zero exit, or
    /// an error line). networksetup's text is localized, so its stdout counts only through IPv4/IPv6 literal lines;
    /// none (exit 0) is Automatic. Its stderr (CFPreferences warnings) is discarded, never compared. The journal's search
    /// domains aren't checked (DESIGN §13.3a).
    /// Relies on the body's `set -f` (a service name is never globbed).
    static let journalStaleFunction = #"""
    journalstale() {
      J=$1
      plutil -extract dns raw -expect dictionary -o - "$J" >/dev/null 2>&1 || return 1
      K=$(plutil -extract dns raw -o - "$J" 2>/dev/null) || return 1
      [ -n "$K" ] || return 0
      NL='
    '
      R=0
      OIFS=$IFS
      IFS=$NL
      for svc in $K; do
        case "$svc" in ''|*.*|@*) IFS=$OIFS; return 1;; esac
        t=$(plutil -type "dns.$svc" "$J" 2>/dev/null) || { IFS=$OIFS; return 1; }
        want=""
        case "$t" in
          "(any)") ;;
          array)
            c=$(plutil -extract "dns.$svc" raw -expect array -o - "$J" 2>/dev/null) || { IFS=$OIFS; return 1; }
            case "$c" in ''|*[!0-9]*) IFS=$OIFS; return 1;; esac
            [ "$c" -le 64 ] || { IFS=$OIFS; return 1; }
            i=0
            while [ "$i" -lt "$c" ]; do
              v=$(plutil -extract "dns.$svc.$i" raw -expect string -o - "$J" 2>/dev/null) || { IFS=$OIFS; return 1; }
              want="$want$v;"
              i=$((i + 1))
            done
            ;;
          *) IFS=$OIFS; return 1 ;;
        esac
        have=$(networksetup -getdnsservers "$svc" 2>/dev/null) || { IFS=$OIFS; return 1; }
        case "$have" in *"** Error"*|*"not a recognized"*) IFS=$OIFS; return 1 ;; esac
        got=""
        for line in $have; do
          if printf '%s\n' "$line" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*(%[A-Za-z0-9]+)?$'; then got="$got$line;"; fi
        done
        if [ -z "$want" ]; then
          [ -z "$got" ] || { IFS=$OIFS; return 1; }
        elif [ "$got" != "$want" ]; then
          R=2
        fi
      done
      IFS=$OIFS
      return $R
    }
    """#

    /// E2E-6 N2: `dnsonly <rules>` succeeds when every pf rule is a port-53 rule (Go 1.0.x's DNS protection, left on
    /// after its tunnel ended), so a non-empty anchor isn't a kill switch.
    static let dnsOnlyFunction = #"""
    dnsonly() {
      [ -n "$1" ] || return 1
      if printf '%s\n' "$1" | grep -v -E 'port = (53|domain)( |$)' | grep -q .; then return 1; fi
      return 0
    }
    """#

    /// E2E-7 F3: `tunnelstale <data dir> <label> <binary> [<app pattern>]` exits 0 when the tunnel-state files outlived a
    /// hard-killed helper, so they don't mean "busy". Go 1.x writes `{"tunnel_name":…,"interface_name":"utunN"}` (no pid,
    /// `internal/tunnel/recovery.go`) right after its engine created the utun, which dies with the helper; only its crash
    /// recovery, at its next start, clears the file. Stale only while launchd doesn't know the label (`launchctl print`
    /// exit 113 exactly; a loaded job is busy even when it runs nothing, exit 0 without a PID), `pgrep` finds neither the
    /// helper nor the old app (exit 1 exactly), `tunnel-states` is a root-owned directory and every `*.json` in it is a
    /// root-owned regular file directly inside it whose `interface_name` is exactly `utun` + 1–3 digits (compared raw:
    /// `$(…)` would strip trailing newlines) and absent from `ifconfig -l`, which must list `lo0`. Anything else, any
    /// error included, exits 1 (busy). pf rules are judged after it, as before (DESIGN §13.3a). Relies on the body's
    /// `set -f` (no globbing of file names).
    static let tunnelStaleFunction = #"""
    tunnelstale() {
      Q=$1
      launchctl print "system/$2" >/dev/null 2>&1; [ $? = 113 ] || return 1
      pgrep -f "^$3"'( |$)' >/dev/null 2>&1; [ $? = 1 ] || return 1
      pgrep -f '\#(oldAppPattern)' >/dev/null 2>&1; [ $? = 1 ] || return 1
      if [ -n "$4" ]; then pgrep -f "$4" >/dev/null 2>&1; [ $? = 1 ] || return 1; fi
      [ ! -L "$Q/tunnel-states" ] && [ -d "$Q/tunnel-states" ] && [ "$(stat -f %u "$Q/tunnel-states")" = 0 ] || return 1
      I=$(ifconfig -l) || return 1
      case " $I " in *" lo0 "*) ;; *) return 1 ;; esac
      F=$(find "$Q/tunnel-states" -maxdepth 1 -name '*.json' 2>/dev/null) || return 1
      [ -n "$F" ] || return 1
      NL='
    '
      OIFS=$IFS
      IFS=$NL
      for f in $F; do
        case "$f" in "$Q/tunnel-states/"*) ;; *) IFS=$OIFS; return 1 ;; esac
        rootfile "$f" || { IFS=$OIFS; return 1; }
        i=$(plutil -extract interface_name raw -expect string -o - "$f" 2>/dev/null && echo x) || { IFS=$OIFS; return 1; }
        i=${i%x}
        i=${i%"$NL"}
        case "$i" in utun[0-9]|utun[0-9][0-9]|utun[0-9][0-9][0-9]) ;; *) IFS=$OIFS; return 1 ;; esac
        case " $I " in *" $i "*) IFS=$OIFS; return 1 ;; esac
      done
      IFS=$OIFS
      return 0
    }
    """#

    static let body = #"""
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    umask 077
    cd /
    set -f
    L=io.github.steiale.lockplus.helper
    P=/Library/LaunchDaemons/io.github.steiale.lockplus.helper.plist
    B=/Library/PrivilegedHelperTools/io.github.steiale.lockplus.helper
    D='/Library/Application Support/lockplus'
    S=/var/run/lockplus
    G=/var/log/lockplus-helper.log
    L2=io.github.steiale.wireguide-plus.helper
    P2=/Library/LaunchDaemons/io.github.steiale.wireguide-plus.helper.plist
    B2=/Library/PrivilegedHelperTools/io.github.steiale.wireguide-plus.helper
    D2='/Library/Application Support/wireguide-plus'
    S2=/var/run/wireguide-plus
    G2=/var/log/wireguide-plus-helper.log
    L3=com.wireguide.helper
    P3=/Library/LaunchDaemons/com.wireguide.helper.plist
    B3=/Library/PrivilegedHelperTools/com.wireguide.helper
    D3='/Library/Application Support/wireguide'
    S3=/var/run/wireguide
    G3=/var/log/wireguide-helper.log
    O=/Library/PrivilegedHelperTools/openvpn
    T='anchor apple generic and certificate leaf[subject.OU] = "M53GHX9FAY"'
    result() { echo "LP_RESULT=$1"; exit 0; }
    present() { [ -e "$1" ] || [ -L "$1" ]; }
    rootfile() { [ ! -L "$1" ] && [ -f "$1" ] && [ "$(stat -f %u "$1")" = 0 ]; }
    signedas() { codesign --verify --strict -R="$T and identifier \"$2\"" "$1" >/dev/null 2>&1; }
    signedbyus() { codesign --verify --strict -R="$T" "$1" >/dev/null 2>&1; }
    plistis() { [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$1" 2>/dev/null)" = "$2" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$1" 2>/dev/null)" = "$3" ]; }
    known() { launchctl print "system/$1" >/dev/null 2>&1; }
    \#(journalStaleFunction)
    \#(dnsOnlyFunction)
    \#(tunnelStaleFunction)
    tunnelup() { Q=$1; [ -d "$Q/tunnel-states" ] && [ -n "$(find "$Q/tunnel-states" -maxdepth 1 -name '*.json' 2>/dev/null)" ]; }
    # com.wireguide.helper is upstream WireGuide's live label: ours (WireGuide+ 1.0.0) only if our team signed it.
    U3=no
    if rootfile "$B3" && signedbyus "$B3"; then U3=yes; fi
    # E2E-7 F3: state files a hard-killed helper left (no job, no process, no utun) aren't a tunnel; cleandata removes
    # them, and LP_STALE tells the app that the helper's crash recovery (its endpoint routes) never ran: a restart clears them.
    ST=no
    # The functions share the globals Q and ST on purpose; nothing reads Q after a tunnelcheck.
    # Review L5: each busy prints a constant reason first (LP_BUSY=tunnel or pf), so the app explains the right one.
    tunnelcheck() { tunnelup "$1" || return 0; tunnelstale "$@" || { echo "LP_BUSY=tunnel"; result busy; }; ST=yes; }
    tunnelcheck "$D" "$L" "$B"
    tunnelcheck "$D2" "$L2" "$B2"
    if [ "$U3" = yes ]; then tunnelcheck "$D3" "$L3" "$B3" '\#(wireGuide100Pattern)'; fi
    PF=$(pfctl -a com.apple/wireguide -s rules 2>/dev/null)
    PFD=$(pfctl -a com.apple/wireguide/dns -s rules 2>/dev/null)
    if [ -n "$PF$PFD" ]; then
      # E2E-6 N2: only port-53 rules = DNS protection left on by 1.0.x after its tunnel ended (no tunnel is up: checked
      # above); a restart clears it. Anything else is a kill switch.
      if { [ -z "$PF" ] || dnsonly "$PF"; } && { [ -z "$PFD" ] || dnsonly "$PFD"; }; then result dns-protection-left; fi
      echo "LP_BUSY=pf"
      result busy
    fi
    if present "$P"; then
      rootfile "$P" || result not-go-plist
      plistis "$P" "$L" "$B" || result not-go-plist
    fi
    if present "$B"; then
      rootfile "$B" || result not-go-binary
      signedas "$B" lockplus-helper || result not-go-binary
    fi
    # WireGuide+ 1.0.1–1.0.56: early builds weren't Developer ID signed; exact label, program path and root owner.
    if present "$P2"; then
      rootfile "$P2" || result not-go-plist
      plistis "$P2" "$L2" "$B2" || result not-go-plist
    fi
    if present "$B2"; then rootfile "$B2" || result not-go-binary; fi
    if [ "$U3" = yes ] && present "$P3"; then
      rootfile "$P3" || result not-go-plist
      plistis "$P3" "$L3" "$B3" || result not-go-plist
    fi
    # E2E-6 N1: an un-replayed journal refuses unless it is stale (it would restore nothing); a stale one goes with
    # the data directory below.
    SJ=""
    # Review 650b251: 2 = the journal holds the user's own servers, which only the old helper restores (restart).
    journalcheck() {
      Q=$1; J=$Q/dns-journal.json
      rootfile "$J" || result dns-unrestored
      journalstale "$J"
      r=$?
      if [ "$r" = 0 ]; then SJ="$SJ$J;"; elif [ "$r" = 2 ]; then result dns-unrestored-manual; else result dns-unrestored; fi
    }
    if [ -e "$D/dns-journal.json" ] && ! known "$L"; then journalcheck "$D"; fi
    if [ -e "$D2/dns-journal.json" ] && ! known "$L2"; then journalcheck "$D2"; fi
    if [ "$U3" = yes ] && [ -e "$D3/dns-journal.json" ] && ! known "$L3"; then journalcheck "$D3"; fi
    if pgrep -f '\#(oldAppPattern)' >/dev/null 2>&1; then result old-app-running; fi
    if [ "$U3" = yes ] && pgrep -f '\#(wireGuide100Pattern)' >/dev/null 2>&1; then result old-app-running; fi
    launchctl bootout "system/$L" >/dev/null 2>&1
    launchctl bootout "system/$L2" >/dev/null 2>&1
    if [ "$U3" = yes ]; then launchctl bootout "system/$L3" >/dev/null 2>&1; fi
    n=0
    while known "$L" || known "$L2" || { [ "$U3" = yes ] && known "$L3"; }; do
      n=$((n + 1))
      [ "$n" -gt 20 ] && result still-running
      sleep 0.5
    done
    left=no
    cleandata() {
      C=$1
      case "$SJ" in *"$C/dns-journal.json;"*) rm -f "$C/dns-journal.json";; esac
      if [ -d "$C" ] && [ ! -L "$C" ] && [ "$(stat -f %u "$C")" = 0 ]; then
        for x in tunnel-states ovpn-run; do
          if [ -d "$C/$x" ] && [ ! -L "$C/$x" ]; then rm -rf "$C/$x"; fi
        done
        if [ -e "$C/dns-journal.json" ] || [ -e "$C/pf-was-enabled" ]; then
          left=yes
          # E2E-6 N3: the app can't see into a root 0700 directory (1.0.x): the kept files are reported here.
          if [ -e "$C/dns-journal.json" ]; then echo "LP_KEPT=dns-journal $C/dns-journal.json"; fi
          if [ -e "$C/pf-was-enabled" ]; then echo "LP_KEPT=pf-was-enabled $C/pf-was-enabled"; fi
        else
          rmdir "$C" 2>/dev/null
        fi
      fi
    }
    if present "$P"; then rm -f "$P"; fi
    if present "$B"; then rm -f "$B"; fi
    if present "$P2"; then rm -f "$P2"; fi
    if present "$B2"; then rm -f "$B2"; fi
    if [ "$U3" = yes ]; then
      if present "$P3"; then rm -f "$P3"; fi
      rm -f "$B3"
    fi
    if rootfile "$O" && signedas "$O" openvpn; then rm -f "$O"; fi
    if [ -S "$S/lockplus.sock" ]; then rm -f "$S/lockplus.sock"; fi
    if [ -d "$S" ] && [ ! -L "$S" ]; then rmdir "$S" 2>/dev/null; fi
    if [ -S "$S2/wireguide-plus.sock" ]; then rm -f "$S2/wireguide-plus.sock"; fi
    if [ -d "$S2" ] && [ ! -L "$S2" ]; then rmdir "$S2" 2>/dev/null; fi
    if rootfile "$G"; then rm -f "$G"; fi
    if rootfile "$G2"; then rm -f "$G2"; fi
    cleandata "$D"
    cleandata "$D2"
    if [ "$U3" = yes ]; then
      if [ -S "$S3/wireguide.sock" ]; then rm -f "$S3/wireguide.sock"; fi
      if [ -d "$S3" ] && [ ! -L "$S3" ]; then rmdir "$S3" 2>/dev/null; fi
      if rootfile "$G3"; then rm -f "$G3"; fi
      cleandata "$D3"
    fi
    if present "$P" || present "$B" || present "$P2" || present "$B2" || known "$L" || known "$L2"; then result incomplete; fi
    if [ "$U3" = yes ] && { present "$P3" || present "$B3" || known "$L3"; }; then result incomplete; fi
    if [ "$ST" = yes ]; then echo "LP_STALE=tunnel-states"; fi
    if [ "$left" = yes ]; then result removed-left-state; fi
    result removed
    """#

    /// What the script reported (its last `LP_RESULT=` line).
    enum Outcome: String, Sendable, Equatable {
        case removed
        case removedLeftState = "removed-left-state"
        case busy
        /// The helper isn't running, so nothing would replay its DNS journal: refused before anything is removed.
        case dnsUnrestored = "dns-unrestored"
        /// Review 650b251: the journal holds the user's own DNS servers; a restart lets the old helper restore them.
        case dnsUnrestoredManual = "dns-unrestored-manual"
        /// E2E-6 N2: only port-53 rules in the anchor (1.0.x's DNS protection left on): a restart clears them.
        case dnsProtectionLeft = "dns-protection-left"
        /// The old app (its executable `lockplus`, or WireGuide+'s `wireguide-plus`) runs: it would reinstall the helper.
        case oldAppRunning = "old-app-running"
        case notGoPlist = "not-go-plist"
        case notGoBinary = "not-go-binary"
        case stillRunning = "still-running"
        case incomplete
    }

    /// E2E-6 N3: the network-state files the script kept, with why (`dns-journal`, `pf-was-enabled`).
    static func kept(in output: String) -> [(kind: String, path: String)] {
        output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line in
            guard line.hasPrefix("LP_KEPT=") else { return nil }
            let rest = line.dropFirst("LP_KEPT=".count)
            guard let space = rest.firstIndex(of: " ") else { return nil }
            return (String(rest[..<space]), String(rest[rest.index(after: space)...]))
        }
    }

    /// E2E-7 F3 review L3: the busy check judged the tunnel-state files stale, so the old helper's crash recovery never
    /// ran (its endpoint routes stay until a restart).
    static func staleTunnel(in output: String) -> Bool {
        output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).contains { $0 == "LP_STALE=tunnel-states" }
    }

    /// E2E-7 F3 review L5: root said busy because of a tunnel-state file (not pf rules): only then can LockPlus's own
    /// tunnel be the cause (its utun reusing the recorded number).
    static func busyFromTunnelState(in output: String) -> Bool {
        output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).contains { $0 == "LP_BUSY=tunnel" }
    }

    static func outcome(of output: String) -> Outcome? {
        let lines = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        guard let last = lines.last(where: { $0.hasPrefix("LP_RESULT=") }) else { return nil }
        return Outcome(rawValue: String(last.dropFirst("LP_RESULT=".count)))
    }

    /// The administrator dialog's line. Run in-process (`InProcessAppleScriptRunner`), macOS titles the dialog with this
    /// app ("LockPlus wants to make changes."); through `/usr/bin/osascript` it would name osascript (review E2E-5 F1-4).
    static var prompt: String {
        String(localized: "LockPlus wants to remove the helper of the old LockPlus (1.x).", comment: "Administrator dialog prompt (E2E-5 F1)")
    }
}

/// How the one privileged run ended.
enum PrivilegedRunResult: Sendable, Equatable {
    /// The script ran as root; its standard output.
    case finished(output: String)
    /// The user cancelled the administrator dialog.
    case cancelled
    /// The authorization or the run failed (the system's message, for the details line).
    case failed(String)
}

/// Runs a fixed script as root after one administrator authentication. Tests and preview mode use fakes: the real
/// runner is never called outside the live app.
protocol PrivilegedScriptRunning: Sendable {
    func runAsAdministrator(script: String, prompt: String) async -> PrivilegedRunResult
}

/// The live runner (review E2E-5 F1-4): the same constant handler, compiled and called IN this process, so the
/// authorization dialog names LockPlus instead of "osascript" (users shouldn't learn to approve an osascript admin
/// prompt). The script and the prompt are the parameters of one subroutine Apple event (`ascr`/`psbr`), never part
/// of the AppleScript source. `NSAppleScript` is used on the main actor only (its documented contract); the call
/// blocks while the system dialog is up, which is modal anyway. Fable pre-release A-2: the osascript runner is the
/// fallback only when the handler can't be built here (no `NSAppleScript`, a compile error); every execution error is
/// the answer (cancel, or `.failed` with the system's message), so a failure never leads to a second administrator
/// dialog. Every error and every fallback is logged with its number.
struct InProcessAppleScriptRunner: PrivilegedScriptRunning {
    private static let log = Logger(subsystem: "io.github.steiale.lockplus.mac", category: "lifecycle")
    /// A-1: the shell options bash (`/bin/sh`) honours from the environment; unset before the in-process run as well
    /// (the `env -i` wrapper covers the root script, this covers the `sh -c` that starts it).
    static let shellEnvironment = ["SHELLOPTS", "BASH_XTRACEFD", "BASH_ENV", "ENV", "CDPATH", "GLOBIGNORE", "POSIXLY_CORRECT", "TMPDIR"]
    static let handlerName = "lockplus_remove_helper"
    static let source = """
    on lockplus_remove_helper(theScript, thePrompt)
    	return do shell script theScript with prompt thePrompt with administrator privileges without altering line endings
    end lockplus_remove_helper
    """
    var fallback: any PrivilegedScriptRunning = OsascriptPrivilegedRunner()

    /// The subroutine event: handler name and the two text parameters.
    static func event(script: String, prompt: String) -> NSAppleEventDescriptor {
        let target = NSAppleEventDescriptor.currentProcess()
        let e = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                       targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                       transactionID: AETransactionID(kAnyTransactionID))
        e.setDescriptor(NSAppleEventDescriptor(string: handlerName), forKeyword: AEKeyword(keyASSubroutineName))
        let params = NSAppleEventDescriptor.list()
        params.insert(NSAppleEventDescriptor(string: script), at: 1)
        params.insert(NSAppleEventDescriptor(string: prompt), at: 2)
        e.setDescriptor(params, forKeyword: AEKeyword(keyDirectObject))
        return e
    }

    /// The run's answer: a cancel, or any other error as `.failed` with the system's message (never a fallback).
    static func result(_ reply: NSAppleEventDescriptor?, error: NSDictionary?) -> PrivilegedRunResult {
        if let error {
            let n = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? ""
            log.notice("in-process administrator run failed: \(n, privacy: .public) \(message, privacy: .public)")
            if n == -128 { return .cancelled }
            return .failed(message.isEmpty ? "AppleScript error \(n)" : message)
        }
        return .finished(output: reply?.stringValue ?? "")
    }

    func runAsAdministrator(script: String, prompt: String) async -> PrivilegedRunResult {
        let inProcess: PrivilegedRunResult? = await MainActor.run {
            guard let s = NSAppleScript(source: Self.source) else {
                Self.log.notice("in-process administrator run unavailable (no NSAppleScript); osascript fallback")
                return nil
            }
            var error: NSDictionary?
            guard s.compileAndReturnError(&error) else {
                let n = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
                Self.log.notice("in-process handler didn't compile (\(n, privacy: .public)); osascript fallback")
                return nil
            }
            for name in Self.shellEnvironment { unsetenv(name) }
            let reply = s.executeAppleEvent(Self.event(script: script, prompt: prompt), error: &error)
            return Self.result(reply, error: error)
        }
        if let inProcess { return inProcess }
        return await fallback.runAsAdministrator(script: script, prompt: prompt)
    }
}

/// The fallback runner: `/usr/bin/osascript` with the script and the prompt as `argv` of a constant AppleScript handler,
/// so neither is ever parsed as AppleScript source. No timeout: the administrator dialog waits for the user.
struct OsascriptPrivilegedRunner: PrivilegedScriptRunning {
    private final class Collector: Sendable {
        let data = Mutex(Data())
        func append(_ d: Data) { data.withLock { if $0.count < 64 << 10 { $0.append(d.prefix((64 << 10) - $0.count)) } } }
        var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }
    }

    static let handler = [
        "-e", "on run argv",
        "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges without altering line endings",
        "-e", "end run",
    ]

    func runAsAdministrator(script: String, prompt: String) async -> PrivilegedRunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = Self.handler + [script, prompt]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let o = Collector(), e = Collector()
        out.fileHandleForReading.readabilityHandler = { @Sendable h in o.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { @Sendable h in e.append(h.availableData) }
        return await withCheckedContinuation { (k: CheckedContinuation<PrivilegedRunResult, Never>) in
            p.terminationHandler = { @Sendable proc in
                for (pipe, c) in [(out, o), (err, e)] {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? pipe.fileHandleForReading.readToEnd() { c.append(rest) }
                }
                k.resume(returning: Self.result(status: proc.terminationStatus, output: o.text, error: e.text))
            }
            do { try p.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                k.resume(returning: .failed(error.localizedDescription))
            }
        }
    }

    /// osascript exits non-zero with "execution error: … (-128)" when the dialog is cancelled.
    static func result(status: Int32, output: String, error: String) -> PrivilegedRunResult {
        if status == 0 { return .finished(output: output) }
        if error.contains("(-128)") { return .cancelled }
        let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(detail.isEmpty ? "osascript \(status)" : String(detail.prefix(300)))
    }
}

/// Tests and the default backend: never elevates. Records the requests and answers from a script.
final class FakePrivilegedRunner: PrivilegedScriptRunning {
    struct State { var runs: [(script: String, prompt: String)] = []; var answer: PrivilegedRunResult = .cancelled }
    let state = Mutex(State())
    /// Runs inside each request (the "root" side of a test: e.g. the helper's files disappear).
    let onRun: @Sendable () -> Void
    init(answer: PrivilegedRunResult = .cancelled, onRun: @escaping @Sendable () -> Void = {}) {
        state.withLock { $0.answer = answer }
        self.onRun = onRun
    }
    var runs: Int { state.withLock { $0.runs.count } }
    var lastPrompt: String? { state.withLock { $0.runs.last?.prompt } }
    var lastScript: String? { state.withLock { $0.runs.last?.script } }
    func answer(_ a: PrivilegedRunResult) { state.withLock { $0.answer = a } }
    func runAsAdministrator(script: String, prompt: String) async -> PrivilegedRunResult {
        let a = state.withLock { $0.runs.append((script, prompt)); return $0.answer }
        if case .finished = a { onRun() }
        return a
    }
}
