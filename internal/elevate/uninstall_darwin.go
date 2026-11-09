package elevate

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"

	"github.com/steiale/wireguide/internal/legacy"
)

// v1.2.0 "Farewell": removing the privileged helper so LockPlus 2 (native,
// NetworkExtension) finds a clean Mac. Removed: the LockPlus helper (created
// by installAndLoadDaemon or the helper it installed); the WireGuide+
// (1.0.1–1.0.56) helper, identified by exact paths, plist Label and
// ProgramArguments and root ownership; and com.wireguide.helper only when its
// binary is signed by our team — that label is upstream WireGuide's live
// helper, which stays fully untouched (including its pf anchor). Nothing else
// is touched — in particular not ~/Library/Application Support/lockplus
// (tunnels, settings, history) or the keychain items LockPlus 2 imports.

const (
	// cleanupBinary is a root-owned, codesign-verified copy of THIS app's
	// helper binary, run with --probe-wgplus and --cleanup-only and deleted
	// again. Using the bundled 1.2.0 code (not the installed daemon, which may
	// be a 1.0.x build without a SIGTERM handler) means the same recovery
	// runs no matter which version was installed or how it shut down.
	cleanupBinary = daemonBinary + ".cleanup"

	// systemDataDir is the helper's --data-dir (crash-recovery state, DNS
	// journal, pf-was-enabled, openvpn runtime dir).
	systemDataDir = "/Library/Application Support/lockplus"
	dnsJournal    = systemDataDir + "/dns-journal.json"
	pfWasEnabled  = systemDataDir + "/pf-was-enabled"
	socketDir     = "/var/run/lockplus"
	socketPath    = socketDir + "/lockplus.sock"
	openvpnDst    = "/Library/PrivilegedHelperTools/openvpn"

	// The 1.0.0 helper name, and upstream WireGuide's current one.
	legacyLabel  = "com.wireguide.helper"
	legacyPlist  = "/Library/LaunchDaemons/" + legacyLabel + ".plist"
	legacyBinary = "/Library/PrivilegedHelperTools/" + legacyLabel

	// sharedAnchor is LockPlus 1.0.63+'s pf anchor — and upstream WireGuide's.
	sharedAnchor = "com.apple/wireguide"
)

// helperProcRE matches a running LockPlus helper: the PrivilegedHelperTools
// daemon and the pre-1.0.22 single binary started as "<bundle>/lockplus
// --helper" (not the .cleanup copy). "[l]ockplus" keeps the uninstall
// script's own `sh -c <script>` argv (which contains this pattern) from
// matching; the other alternatives are anchored at the start of argv.
var helperProcRE = "^(" + regexpQuote(daemonBinary) + "( |$)|/.*/Contents/MacOS/[l]ockplus --helper( |$))"

// wgpProcRE matches a running WireGuide+ helper (always started from its
// PrivilegedHelperTools copy).
var wgpProcRE = "^" + regexpQuote(legacy.WGPlusBinary) + "( |$)"

func regexpQuote(s string) string { return strings.ReplaceAll(s, ".", `\.`) }

// helperFiles are the root-owned files the LockPlus helper install creates.
// Checked (unprivileged) by HelperRemnants and removed by the uninstall script.
var helperFiles = []string{
	daemonPlist,
	daemonBinary,
	daemonBinary + ".new",
	openvpnDst,
	openvpnDst + ".new",
	cleanupBinary,
	cleanupBinary + ".new",
}

// HelperInstalled reports whether the LockPlus LaunchDaemon plist exists —
// the same test LockPlus 2's LegacyAppDetector uses for its banner.
func HelperInstalled() bool {
	_, err := os.Lstat(daemonPlist)
	return err == nil
}

// ourTeamRequirement: signed by our Developer ID team (any identifier).
const ourTeamRequirement = teamRequirement

// legacyHelperIsOurs reports whether com.wireguide.helper's binary is signed
// by our team (LockPlus 1.0.0). Anything else is upstream WireGuide's.
var legacyHelperIsOurs = func() bool {
	fi, err := os.Lstat(legacyBinary)
	if err != nil || !fi.Mode().IsRegular() {
		return false
	}
	return exec.Command("/usr/bin/codesign", "--verify", "--strict", "-R="+ourTeamRequirement, legacyBinary).Run() == nil
}

// HelperRemnants lists everything of the LockPlus and WireGuide+ helpers
// still present, checked without privileges: files, sockets, and the state
// files LockPlus 2 treats as "the old LockPlus left network settings
// behind" (plus com.wireguide.helper when it is ours). Empty means the
// removal is complete as far as LockPlus 2 can tell. (pf rules and launchd
// registrations need root to read; the uninstall script checks them.)
func HelperRemnants() []string {
	var left []string
	paths := append(append([]string{}, helperFiles...), socketPath, dnsJournal, pfWasEnabled)
	paths = append(paths, legacy.WGPlusPaths...)
	for _, p := range paths {
		if _, err := os.Lstat(p); err == nil {
			left = append(left, p)
		}
	}
	if legacyHelperIsOurs() {
		left = append(left, legacyBinary)
		if _, err := os.Lstat(legacyPlist); err == nil {
			left = append(left, legacyPlist)
		}
	}
	return left
}

// ErrLegacyBusy: the WireGuide+ helper still has a tunnel up or its kill
// switch on; nothing was changed. Disconnect in WireGuide+ first.
var ErrLegacyBusy = errors.New("WireGuide+ still has a tunnel connected or its kill switch on")

// UninstallError means the root script ran but could not finish the removal.
// Aborted reports that nothing was removed and the helper is back (or never
// stopped).
type UninstallError struct {
	Output  string
	Aborted bool
	// HelperDown: aborted, and launchd refused to start the helper again;
	// the script flushed its pf anchors so the Mac isn't left fail-closed.
	// The caller should start the helper (its startup recovery restores DNS).
	HelperDown bool
	Err        error
}

func (e *UninstallError) Error() string {
	if e.Aborted {
		return fmt.Sprintf("helper removal aborted, the helper was restored: %s", e.Output)
	}
	return fmt.Sprintf("helper removal incomplete: %s", e.Output)
}

func (e *UninstallError) Unwrap() error { return e.Err }

// UninstallHelper stops and removes the privileged helpers as root, behind
// one macOS administrator prompt. Idempotent: on a Mac without them it only
// re-checks and reports success. The caller should disconnect tunnels over
// IPC first (orderly teardown, history), but correctness doesn't depend on
// it: the daemon's SIGTERM cleanup and the --cleanup-only pass both run.
func UninstallHelper() error {
	exe, err := helperBinaryPath()
	if err != nil {
		return err
	}
	script := buildUninstallScript(exe)
	escaped := strings.ReplaceAll(script, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	osascriptCmd := fmt.Sprintf(
		`do shell script "%s" with administrator privileges with prompt "LockPlus needs administrator access to remove its VPN helper service.\n\nLockPlus 2 doesn't need it. Your tunnels and settings stay on this Mac for LockPlus 2 to copy."`,
		escaped,
	)
	slog.Info("removing the privileged helper (admin prompt)")
	out, err := exec.Command("/usr/bin/osascript", "-e", osascriptCmd).CombinedOutput()
	return interpretUninstallOutput(strings.TrimSpace(string(out)), err)
}

// buildUninstallScript returns the root shell script. Every interpolated
// value is a package constant or goes through shellQuote (exe is the
// user-writable bundle path), never inside double quotes. All removed paths
// are exact constants in root-owned directories; `rm -rf` only ever targets
// our own /var/run/lockplus and /Library/Application Support/lockplus.
func buildUninstallScript(exe string) string {
	q := shellQuote
	var b strings.Builder
	w := func(f string, a ...any) { fmt.Fprintf(&b, f, a...) }
	isRootFile := func(p string) string { // regular file, not a symlink, owned by root
		return fmt.Sprintf(`{ [ ! -L %s ] && [ -f %s ] && [ "$(stat -f %%u %s)" = 0 ]; }`, q(p), q(p), q(p))
	}
	b.WriteString(`export PATH="/usr/bin:/bin:/usr/sbin:/sbin"; `)

	// 1. Root-owned, verified copy of the bundled helper for the probe and
	//    the cleanup pass (same snippet and checks as the install). A tampered
	//    bundle aborts here with SIGNATURE_INVALID before anything is stopped.
	b.WriteString(`set -e; mkdir -p /Library/PrivilegedHelperTools; `)
	b.WriteString(installBinarySnippet(exe, cleanupBinary, helperIdentifier))
	b.WriteString(`set +e; `)
	abortUntouched := func(marker string) string {
		return fmt.Sprintf(`rm -f %s; echo %s; exit 8`, q(cleanupBinary), q(marker))
	}

	// 2. Decide what is ours, before changing anything.
	//    WireGuide+: plist (root-owned regular file, exact Label, exact
	//    ProgramArguments[0]) and/or binary (root-owned regular file).
	b.WriteString(`WGP_PLIST=0; WGP_BIN=0; `)
	w(`if [ -e %s ] || [ -L %s ]; then if %s && [ "$(plutil -extract Label raw -o - %s 2>/dev/null)" = %s ] && [ "$(plutil -extract ProgramArguments.0 raw -o - %s 2>/dev/null)" = %s ]; then WGP_PLIST=1; else echo "WGPLUS_SKIPPED: unexpected plist"; fi; fi; `,
		q(legacy.WGPlusPlist), q(legacy.WGPlusPlist), isRootFile(legacy.WGPlusPlist), q(legacy.WGPlusPlist), q(legacy.WGPlusLabel), q(legacy.WGPlusPlist), q(legacy.WGPlusBinary))
	w(`if [ -e %s ] || [ -L %s ]; then if %s; then WGP_BIN=1; else echo "WGPLUS_SKIPPED: unexpected binary"; fi; fi; `,
		q(legacy.WGPlusBinary), q(legacy.WGPlusBinary), isRootFile(legacy.WGPlusBinary))
	//    Refuse while WireGuide+ has a tunnel or kill switch up: rules in its
	//    anchors, or its helper says so (asked as the socket's owner).
	w(`if [ $WGP_PLIST = 1 ] || [ $WGP_BIN = 1 ]; then `)
	w(`if [ -n "$(pfctl -a %s -sr 2>/dev/null)$(pfctl -a %s -sr 2>/dev/null)" ]; then %s; fi; `,
		q(legacy.WGPlusAnchor), q(legacy.WGPlusAnchorDNS), abortUntouched("UNINSTALL_ABORTED_LEGACY_BUSY: wireguide-plus firewall"))
	w(`%s --probe-wgplus >/dev/null 2>&1; PRC=$?; if [ $PRC -ne 0 ]; then %s; fi; fi; `,
		q(cleanupBinary), abortUntouched("UNINSTALL_ABORTED_LEGACY_BUSY: wireguide-plus tunnel"))
	//    com.wireguide.helper: ours only if its binary is signed by our team.
	//    Otherwise it is upstream WireGuide's (or unknowable): leave it and
	//    its pf anchor (shared with us) completely alone.
	b.WriteString(`CWG_OURS=0; FOREIGN=0; `)
	w(`if [ -e %s ] || [ -L %s ] || [ -e %s ] || [ -L %s ]; then if %s && /usr/bin/codesign --verify --strict -R=%s %s >/dev/null 2>&1; then CWG_OURS=1; else FOREIGN=1; echo "UPSTREAM_WIREGUIDE_LEFT_ALONE"; fi; fi; `,
		q(legacyPlist), q(legacyPlist), q(legacyBinary), q(legacyBinary), isRootFile(legacyBinary), q(ourTeamRequirement), q(legacyBinary))

	// 3. Stop the daemons. bootout sends SIGTERM (1.1.0+ tears tunnels, pf
	//    and DNS down on it) and waits; the loop covers a slow exit.
	w(`launchctl bootout system/%s >/dev/null 2>&1; `, daemonLabel)
	w(`[ $WGP_PLIST = 1 ] || [ $WGP_BIN = 1 ] && launchctl bootout system/%s >/dev/null 2>&1; `, legacy.WGPlusLabel)
	w(`[ $CWG_OURS = 1 ] && launchctl bootout system/%s >/dev/null 2>&1; `, legacyLabel)
	running := fmt.Sprintf(`{ launchctl print system/%s >/dev/null 2>&1 || pgrep -f %s >/dev/null 2>&1 || { { [ $WGP_PLIST = 1 ] || [ $WGP_BIN = 1 ]; } && { launchctl print system/%s >/dev/null 2>&1 || pgrep -f %s >/dev/null 2>&1; }; }; }`,
		daemonLabel, q(helperProcRE), legacy.WGPlusLabel, q(wgpProcRE))
	w(`i=0; while [ $i -lt 60 ] && %s; do sleep 0.5; i=$((i+1)); done; `, running)
	// Still running after the wait (a teardown slower than 30 s): abort
	// before the cleanup pass. Flushing pf now would drop the kill switch
	// while the old process may still hold its utun and routes.
	w(`if %s; then rm -f %s; echo "UNINSTALL_ABORTED: helper still running after bootout"; exit 6; fi; `, running, q(cleanupBinary))

	// 4. Recovery pass with the 1.2.0 code: orphaned openvpn, pf anchors +
	//    pf enable state (unless upstream shares the anchor), orphaned
	//    routes, DNS journal. If it fails, put the helper back instead of
	//    deleting it: its next start retries, and LockPlus 1 keeps working.
	b.WriteString(`KEEP=""; [ $FOREIGN = 1 ] && KEEP="--keep-shared-anchor"; `)
	w(`CLOUT=$(%s --cleanup-only $KEEP --socket=%s --data-dir=%s 2>&1); CLRC=$?; `,
		q(cleanupBinary), q(socketPath), q(systemDataDir))
	b.WriteString(`printf '%s\n' "$CLOUT" | tail -n 20 | sed 's/^/CLEANUP: /'; `)
	w(`if [ $CLRC -ne 0 ]; then rm -f %s; `, q(cleanupBinary))
	// Put the helper back (if its plist is still there), tracking the exit
	// status separately: a failing bootstrap may print nothing.
	w(`BRC=0; if [ -f %s ]; then launchctl enable system/%s >/dev/null 2>&1; BOOTERR=$(launchctl bootstrap system %s 2>&1); BRC=$?; fi; `,
		q(daemonPlist), daemonLabel, q(daemonPlist))
	// No helper job is loaded now (bootstrap failed, or there was no plist):
	// don't leave its kill switch blocking the Mac. Never flushed under a
	// job launchd still has (that helper owns its rules), nor when upstream
	// WireGuide shares the anchor.
	w(`if ! launchctl print system/%s >/dev/null 2>&1 && [ $FOREIGN = 0 ]; then pfctl -a %s -Fa >/dev/null 2>&1; pfctl -a %s/dns -Fa >/dev/null 2>&1; [ "$(cat %s 2>/dev/null)" = 0 ] && pfctl -d >/dev/null 2>&1; `,
		daemonLabel, sharedAnchor, sharedAnchor, q(pfWasEnabled))
	// HELPER_DOWN only when a helper exists that the GUI could start again.
	w(`[ -f %s ] && echo "UNINSTALL_ABORTED_HELPER_DOWN: bootstrap exit $BRC $BOOTERR"; fi; `, q(daemonPlist))
	b.WriteString(`echo "UNINSTALL_ABORTED: cleanup pass failed ($CLRC)"; exit 6; fi; `)
	// Safety net for our anchors (cheap, idempotent; pf enable state was
	// restored by the cleanup pass from pf-was-enabled).
	w(`[ $FOREIGN = 0 ] && { pfctl -a %s -Fa >/dev/null 2>&1; pfctl -a %s/dns -Fa >/dev/null 2>&1; }; `, sharedAnchor, sharedAnchor)

	// 5. WireGuide+ leftovers: its (inert, dot-named) anchors, and the pf
	//    enable state it recorded — restored only if upstream doesn't use pf
	//    through the shared anchor right now.
	w(`if [ $WGP_PLIST = 1 ] || [ $WGP_BIN = 1 ]; then pfctl -a %s -Fa >/dev/null 2>&1; pfctl -a %s -Fa >/dev/null 2>&1; `,
		q(legacy.WGPlusAnchor), q(legacy.WGPlusAnchorDNS))
	w(`if %s && [ "$(cat %s 2>/dev/null)" = 0 ] && [ $FOREIGN = 0 ]; then pfctl -d >/dev/null 2>&1; fi; `, isRootFile(legacy.WGPlusPfWasOn), q(legacy.WGPlusPfWasOn))
	w(`[ $WGP_PLIST = 1 ] && rm -f %s; [ $WGP_BIN = 1 ] && rm -f %s; `, q(legacy.WGPlusPlist), q(legacy.WGPlusBinary))
	w(`rm -f %s %s %s; rmdir %s %s 2>/dev/null; fi; `,
		q(legacy.WGPlusSocket), q(legacy.WGPlusLog), q(legacy.WGPlusPfWasOn), q(legacy.WGPlusSocketDir), q(legacy.WGPlusDataDir))
	//    Our own com.wireguide.helper (1.0.0).
	w(`[ $CWG_OURS = 1 ] && rm -f %s %s; `, q(legacyPlist), q(legacyBinary))

	// 6. Remove what the LockPlus install created.
	b.WriteString(`rm -f`)
	for _, f := range append(append([]string{}, helperFiles...), helperLogPath) {
		b.WriteString(" " + q(f))
	}
	b.WriteString(`; `)
	w(`rm -rf %s; `, q(socketDir))
	// The data dir holds only helper state; the cleanup pass emptied what
	// matters. A DNS journal that is still there could not be restored: keep
	// it (it's the user's original DNS) and report it.
	w(`if [ -e %s ]; then echo "DNS_JOURNAL_LEFT"; else rm -rf %s; fi; `, q(dnsJournal), q(systemDataDir))

	// 7. Verify as root.
	b.WriteString(`FAIL=""; `)
	w(`launchctl print system/%s >/dev/null 2>&1 && FAIL="$FAIL launchd:%s"; `, daemonLabel, daemonLabel)
	w(`pgrep -f %s >/dev/null 2>&1 && FAIL="$FAIL process"; `, q(helperProcRE))
	w(`pgrep -f %s >/dev/null 2>&1 && FAIL="$FAIL openvpn"; `, q("^"+regexpQuote(openvpnDst)+"( |$)"))
	for _, f := range append(append([]string{}, helperFiles...), helperLogPath, socketDir, pfWasEnabled) {
		w(`[ -e %s ] && FAIL="$FAIL "%s; `, q(f), q(f))
	}
	w(`[ $FOREIGN = 0 ] && for A in %s %s/dns; do [ -n "$(pfctl -a $A -sr 2>/dev/null)" ] && FAIL="$FAIL pf:$A"; done; `, sharedAnchor, sharedAnchor)
	w(`if [ $WGP_PLIST = 1 ] || [ $WGP_BIN = 1 ]; then launchctl print system/%s >/dev/null 2>&1 && FAIL="$FAIL launchd:%s"; pgrep -f %s >/dev/null 2>&1 && FAIL="$FAIL wgp-process"; `,
		legacy.WGPlusLabel, legacy.WGPlusLabel, q(wgpProcRE))
	for _, f := range []string{legacy.WGPlusPlist, legacy.WGPlusBinary, legacy.WGPlusSocket, legacy.WGPlusPfWasOn} {
		w(`[ -e %s ] && FAIL="$FAIL "%s; `, q(f), q(f))
	}
	b.WriteString(`fi; `)
	w(`[ $CWG_OURS = 1 ] && { [ -e %s ] || [ -e %s ]; } && FAIL="$FAIL com.wireguide.helper"; `, q(legacyPlist), q(legacyBinary))
	b.WriteString(`if [ -z "$FAIL" ]; then echo UNINSTALL_OK; else echo "UNINSTALL_INCOMPLETE:$FAIL"; exit 7; fi`)
	return b.String()
}

// interpretUninstallOutput maps the script's markers and osascript's exit
// error to typed errors (ErrUserCancelled, *SignatureError, *UninstallError).
func interpretUninstallOutput(out string, err error) error {
	if err == nil && strings.Contains(out, "UNINSTALL_OK") {
		slog.Info("helper removed and verified", "output", out)
		return nil
	}
	switch {
	case strings.Contains(out, "SIGNATURE_INVALID"):
		slog.Error("helper removal aborted: code signature verification failed", "output", out)
		return &SignatureError{Output: out, Err: err}
	case strings.Contains(out, "UNINSTALL_ABORTED_LEGACY_BUSY"):
		slog.Warn("helper removal refused: WireGuide+ is busy", "output", out)
		return ErrLegacyBusy
	case strings.Contains(out, "UNINSTALL_ABORTED"):
		down := strings.Contains(out, "UNINSTALL_ABORTED_HELPER_DOWN")
		slog.Error("helper removal aborted", "helper_down", down, "output", out)
		return &UninstallError{Output: out, Aborted: true, HelperDown: down, Err: err}
	case strings.Contains(out, "UNINSTALL_INCOMPLETE"):
		slog.Error("helper removal incomplete", "output", out)
		return &UninstallError{Output: out, Err: err}
	case err != nil && strings.Contains(out, "(-128)"):
		return ErrUserCancelled
	case err != nil:
		return fmt.Errorf("osascript uninstall failed: %s (%w)", out, err)
	}
	slog.Error("helper removal produced no success marker", "output", out)
	return &UninstallError{Output: out, Err: fmt.Errorf("removal did not confirm success")}
}
