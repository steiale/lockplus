package elevate

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"
)

// v1.2.0 "Farewell": removing the privileged helper so LockPlus 2 (native,
// NetworkExtension) finds a clean Mac. Everything removed here was created by
// installAndLoadDaemon (or by the helper it installed); nothing else is
// touched — in particular not the user's ~/Library/Application Support/lockplus
// (tunnels, settings, history) or the keychain items LockPlus 2 imports.

const (
	// cleanupBinary is a root-owned, codesign-verified copy of THIS app's
	// helper binary, run once with --cleanup-only and deleted again. Using the
	// bundled 1.2.0 code (not the installed daemon, which may be a 1.0.x
	// build without a SIGTERM handler) means the same recovery runs no matter
	// which version was installed or whether it shut down cleanly.
	cleanupBinary = daemonBinary + ".cleanup"

	// systemDataDir is the helper's --data-dir (crash-recovery state, DNS
	// journal, pf-was-enabled, openvpn runtime dir).
	systemDataDir = "/Library/Application Support/lockplus"
	dnsJournal    = systemDataDir + "/dns-journal.json"
	pfWasEnabled  = systemDataDir + "/pf-was-enabled"
	socketDir     = "/var/run/lockplus"
	socketPath    = socketDir + "/lockplus.sock"
	openvpnDst    = "/Library/PrivilegedHelperTools/openvpn"

	// The helper name before v1.0.57 (WireGuide+). The install script
	// already removes it; listed so an old leftover can't survive the
	// farewell either.
	legacyLabel  = "com.wireguide.helper"
	legacyPlist  = "/Library/LaunchDaemons/" + legacyLabel + ".plist"
	legacyBinary = "/Library/PrivilegedHelperTools/" + legacyLabel
)

// helperProcRE matches a running helper: the PrivilegedHelperTools daemon
// and the pre-1.0.22 single binary started as "<bundle>/lockplus --helper"
// (not the .cleanup copy).
//
// "[l]ockplus" keeps the uninstall script's own `sh -c <script>` argv (which
// contains this pattern literally) from matching it.
var helperProcRE = "^(" + regexpQuote(daemonBinary) + "( |$)|/.*/Contents/MacOS/[l]ockplus --helper( |$))"

func regexpQuote(s string) string { return strings.ReplaceAll(s, ".", `\.`) }

// helperFiles are the root-owned files the helper install creates. Checked
// (unprivileged) by HelperRemnants and removed by the uninstall script.
var helperFiles = []string{
	daemonPlist,
	daemonBinary,
	daemonBinary + ".new",
	openvpnDst,
	openvpnDst + ".new",
	cleanupBinary,
	cleanupBinary + ".new",
	legacyPlist,
	legacyBinary,
}

// HelperInstalled reports whether the LaunchDaemon plist exists — the same
// test LockPlus 2's LegacyAppDetector uses for its "old helper" banner.
func HelperInstalled() bool {
	_, err := os.Lstat(daemonPlist)
	return err == nil
}

// HelperRemnants lists everything of the helper still present, checked
// without privileges: files, the socket, and the two state files LockPlus 2
// treats as "the old LockPlus left network settings behind". Empty means the
// removal is complete as far as LockPlus 2 can tell. (pf rules and the
// launchd registration need root to read; the uninstall script checks them.)
func HelperRemnants() []string {
	var left []string
	// The helper log is removed by the script too, but a leftover log is not
	// something LockPlus 2 (or the user) needs to hear about.
	for _, p := range append(append([]string{}, helperFiles...), socketPath, dnsJournal, pfWasEnabled) {
		if _, err := os.Lstat(p); err == nil {
			left = append(left, p)
		}
	}
	return left
}

// UninstallError means the root script ran but could not finish the removal.
// Aborted reports that it put the helper back (the cleanup pass failed, so
// deleting the helper would have left pf/DNS changes nobody can undo).
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

// UninstallHelper stops and removes the privileged helper as root, behind one
// macOS administrator prompt. Idempotent: on a Mac without the helper it only
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
// user-writable bundle path), never inside double quotes.
func buildUninstallScript(exe string) string {
	q := shellQuote
	var b strings.Builder
	b.WriteString(`export PATH="/usr/bin:/bin:/usr/sbin:/sbin"; `)
	// 1. Root-owned, verified copy of the bundled helper for the cleanup
	//    pass (same snippet and checks as the install). A tampered bundle
	//    aborts here with SIGNATURE_INVALID before anything is stopped.
	b.WriteString(`set -e; mkdir -p /Library/PrivilegedHelperTools; `)
	b.WriteString(installBinarySnippet(exe, cleanupBinary, helperIdentifier))
	b.WriteString(`set +e; `)
	// 2. Stop the daemon. bootout sends SIGTERM (1.1.0+ tears tunnels, pf
	//    and DNS down on it) and waits; the loop covers a slow exit.
	fmt.Fprintf(&b, `launchctl bootout system/%s >/dev/null 2>&1; `, daemonLabel)
	fmt.Fprintf(&b, `launchctl bootout system/%s >/dev/null 2>&1; `, legacyLabel)
	// Wait (≤ 30 s) until launchd forgets the job and no helper process
	// remains: the current layout, and the pre-1.0.22 in-bundle "--helper".
	fmt.Fprintf(&b, `i=0; while [ $i -lt 60 ] && { launchctl print system/%s >/dev/null 2>&1 || pgrep -f %s >/dev/null 2>&1; }; do sleep 0.5; i=$((i+1)); done; `,
		daemonLabel, q(helperProcRE))
	// 3. Recovery pass with the 1.2.0 code: orphaned openvpn, pf anchors +
	//    pf enable state, orphaned routes, DNS journal. If it fails, put the
	//    helper back instead of deleting it: its next start retries the
	//    recovery, and LockPlus 1 keeps working.
	// Still running after the wait (a teardown slower than 30 s): abort
	// before the cleanup pass. Flushing pf now would drop the kill switch
	// while the old process may still hold its utun and routes.
	fmt.Fprintf(&b, `if launchctl print system/%s >/dev/null 2>&1 || pgrep -f %s >/dev/null 2>&1; then rm -f %s; echo "UNINSTALL_ABORTED: helper still running after bootout"; exit 6; fi; `,
		daemonLabel, q(helperProcRE), q(cleanupBinary))
	fmt.Fprintf(&b, `CLOUT=$(%s --cleanup-only --socket=%s --data-dir=%s 2>&1); CLRC=$?; `,
		q(cleanupBinary), q(socketPath), q(systemDataDir))
	b.WriteString(`printf '%s\n' "$CLOUT" | tail -n 20 | sed 's/^/CLEANUP: /'; `)
	fmt.Fprintf(&b, `if [ $CLRC -ne 0 ]; then rm -f %s; `, q(cleanupBinary))
	// Put the helper back (if its plist is still there), tracking the exit
	// status separately: a failing bootstrap may print nothing.
	fmt.Fprintf(&b, `BRC=0; if [ -f %s ]; then launchctl enable system/%s >/dev/null 2>&1; BOOTERR=$(launchctl bootstrap system %s 2>&1); BRC=$?; fi; `,
		q(daemonPlist), daemonLabel, q(daemonPlist))
	// No helper job is loaded now (bootstrap failed, or there was no plist):
	// don't leave its kill switch blocking the Mac. Never flushed under a
	// job launchd still has (that helper owns its rules).
	fmt.Fprintf(&b, `if ! launchctl print system/%s >/dev/null 2>&1; then pfctl -a com.apple/wireguide -Fa >/dev/null 2>&1; pfctl -a com.apple/wireguide/dns -Fa >/dev/null 2>&1; [ "$(cat %s 2>/dev/null)" = 0 ] && pfctl -d >/dev/null 2>&1; `,
		daemonLabel, q(pfWasEnabled))
	// HELPER_DOWN only when a helper exists that the GUI could start again.
	fmt.Fprintf(&b, `[ -f %s ] && echo "UNINSTALL_ABORTED_HELPER_DOWN: bootstrap exit $BRC $BOOTERR"; fi; `, q(daemonPlist))
	b.WriteString(`echo "UNINSTALL_ABORTED: cleanup pass failed ($CLRC)"; exit 6; fi; `)
	// Safety net for the anchors (cheap, idempotent; pf enable state was
	// restored by the cleanup pass from pf-was-enabled).
	b.WriteString(`pfctl -a com.apple/wireguide -Fa >/dev/null 2>&1; pfctl -a com.apple/wireguide/dns -Fa >/dev/null 2>&1; `)
	// 4. Remove what the install created.
	b.WriteString(`rm -f`)
	for _, f := range append(append([]string{}, helperFiles...), helperLogPath) {
		b.WriteString(" " + q(f))
	}
	b.WriteString(`; `)
	fmt.Fprintf(&b, `rm -rf %s; `, q(socketDir))
	// The data dir holds only helper state; the cleanup pass emptied what
	// matters. A DNS journal that is still there could not be restored: keep
	// it (it's the user's original DNS) and report it.
	fmt.Fprintf(&b, `if [ -e %s ]; then echo "DNS_JOURNAL_LEFT"; else rm -rf %s; fi; `, q(dnsJournal), q(systemDataDir))
	// 5. Verify as root.
	b.WriteString(`FAIL=""; `)
	fmt.Fprintf(&b, `launchctl print system/%s >/dev/null 2>&1 && FAIL="$FAIL launchd:%s"; `, daemonLabel, daemonLabel)
	fmt.Fprintf(&b, `pgrep -f %s >/dev/null 2>&1 && FAIL="$FAIL process"; `, q(helperProcRE))
	fmt.Fprintf(&b, `pgrep -f %s >/dev/null 2>&1 && FAIL="$FAIL openvpn"; `, q("^"+regexpQuote(openvpnDst)+"( |$)"))
	for _, f := range append(append([]string{}, helperFiles...), helperLogPath, socketDir, pfWasEnabled) {
		fmt.Fprintf(&b, `[ -e %s ] && FAIL="$FAIL "%s; `, q(f), q(f))
	}
	b.WriteString(`for A in com.apple/wireguide com.apple/wireguide/dns; do [ -n "$(pfctl -a $A -sr 2>/dev/null)" ] && FAIL="$FAIL pf:$A"; done; `)
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
