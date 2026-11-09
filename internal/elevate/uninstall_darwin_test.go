package elevate

import (
	"errors"
	"os/exec"
	"regexp"
	"strings"
	"testing"

	"github.com/steiale/wireguide/internal/legacy"
)

func TestUninstallScriptOrderAndScope(t *testing.T) {
	exe := "/Applications/Lock'Plus $(id).app/Contents/MacOS/lockplus-helper"
	script := buildUninstallScript(exe)

	if out, err := exec.Command("/bin/sh", "-n", "-c", script).CombinedOutput(); err != nil {
		t.Fatalf("uninstall script has a shell syntax error: %v\n%s", err, out)
	}
	if !strings.Contains(script, shellQuote(exe)) || strings.Contains(script, `"`+exe) {
		t.Error("the bundle path must only appear single-quoted")
	}

	idx := func(s string) int {
		i := strings.Index(script, s)
		if i < 0 {
			t.Fatalf("script lacks %q", s)
		}
		return i
	}
	verify := idx(`-R=` + shellQuote(codeSignRequirement(helperIdentifier)) + " " + shellQuote(cleanupBinary+".new"))
	bootout := idx("launchctl bootout system/" + daemonLabel)
	cleanup := idx(shellQuote(cleanupBinary) + " --cleanup-only")
	abort := idx("cleanup pass failed")
	// A helper still running after the wait aborts before the cleanup pass
	// (no pf flush under a live process).
	if still := idx("helper still running after bootout"); !(bootout < still && still < cleanup) {
		t.Error("still-running abort must sit between bootout and the cleanup pass")
	}
	rm := idx("rm -f " + shellQuote(daemonPlist))
	ok := idx("echo UNINSTALL_OK")
	if !(verify < bootout && bootout < cleanup && cleanup < abort && abort < rm && rm < ok) {
		t.Errorf("want verify < bootout < cleanup < abort-check < rm < verify-ok, got %d %d %d %d %d %d", verify, bootout, cleanup, abort, rm, ok)
	}
	// A failed cleanup pass must put the helper back, not delete it.
	abortBlock := script[cleanup:rm]
	if !strings.Contains(abortBlock, "launchctl bootstrap system "+shellQuote(daemonPlist)) || !strings.Contains(abortBlock, "exit 6") {
		t.Error("a failed cleanup pass must re-bootstrap the helper and exit")
	}
	// ...and if launchd won't take it back, flush the anchors (no fail-closed Mac).
	down := strings.Index(abortBlock, "UNINSTALL_ABORTED_HELPER_DOWN")
	flush := strings.Index(abortBlock, "pfctl -a com.apple/wireguide -Fa")
	if down < 0 || flush < 0 || flush > down {
		t.Error("abort without a restored helper must flush pf before reporting HELPER_DOWN")
	}
	for _, f := range []string{daemonPlist, daemonBinary, openvpnDst, cleanupBinary, helperLogPath, legacyPlist, legacyBinary} {
		if !strings.Contains(script[rm:ok], shellQuote(f)) {
			t.Errorf("script doesn't remove/verify %s", f)
		}
	}
	// The DNS journal holds the user's original DNS: never deleted blindly.
	if !strings.Contains(script, "if [ -e "+shellQuote(dnsJournal)+" ]; then echo \"DNS_JOURNAL_LEFT\"; else rm -rf "+shellQuote(systemDataDir)) {
		t.Error("data dir may only be removed when no DNS journal is left")
	}
	// Scope: nothing of the user's data or keychain.
	for _, bad := range []string{"~", "/Users", "Library/Application Support/lockplus/tunnels", "security ", "LaunchAgents", "Keychain"} {
		if strings.Contains(script, bad) {
			t.Errorf("uninstall script must not touch %q", bad)
		}
	}
}

func TestHelperProcRE(t *testing.T) {
	re := regexp.MustCompile(helperProcRE)
	script := buildUninstallScript("/Applications/LockPlus.app/Contents/MacOS/lockplus-helper")
	for cmd, want := range map[string]bool{
		"/bin/sh -c " + script: false, // the uninstall script itself
		daemonBinary + " --helper --socket=/var/run/lockplus/lockplus.sock": true,
		daemonBinary: true,
		"/Applications/LockPlus.app/Contents/MacOS/lockplus --helper --socket=x": true,
		cleanupBinary + " --cleanup-only":                                        false,
		"/Applications/LockPlus.app/Contents/MacOS/lockplus":                     false,
	} {
		if got := re.MatchString(cmd); got != want {
			t.Errorf("match(%.80q) = %v, want %v", cmd, got, want)
		}
	}
}

func TestInterpretUninstallOutput(t *testing.T) {
	exitErr := errors.New("exit status 1")
	cases := []struct {
		out  string
		err  error
		want func(error) bool
	}{
		{"CLEANUP: ok\nUNINSTALL_OK", nil, func(e error) bool { return e == nil }},
		{"SIGNATURE_INVALID: x", exitErr, func(e error) bool { var s *SignatureError; return errors.As(e, &s) }},
		{"UNINSTALL_ABORTED: cleanup pass failed (1)", exitErr, func(e error) bool {
			var u *UninstallError
			return errors.As(e, &u) && u.Aborted
		}},
		{"UNINSTALL_ABORTED_HELPER_DOWN: x\nUNINSTALL_ABORTED: cleanup pass failed (1)", exitErr, func(e error) bool {
			var u *UninstallError
			return errors.As(e, &u) && u.Aborted && u.HelperDown
		}},
		{"context canceled", exitErr, func(e error) bool { return !errors.Is(e, ErrUserCancelled) }},
		{"UNINSTALL_ABORTED_LEGACY_PROBE: x", exitErr, func(e error) bool { return errors.Is(e, ErrLegacyProbe) }},
		{"UNINSTALL_ABORTED_LEGACY_BUSY: x", exitErr, func(e error) bool { return errors.Is(e, ErrLegacyBusy) }},
		{"UNINSTALL_INCOMPLETE: SHARED_ANCHOR_RULES_LEFT", exitErr, func(e error) bool {
			var u *UninstallError
			return errors.As(e, &u) && !u.Aborted && strings.Contains(u.Output, "restart your Mac")
		}},
		{"UNINSTALL_INCOMPLETE: pf:com.apple/wireguide", exitErr, func(e error) bool {
			var u *UninstallError
			return errors.As(e, &u) && !u.Aborted
		}},
		{"execution error: User canceled. (-128)", exitErr, func(e error) bool { return errors.Is(e, ErrUserCancelled) }},
		{"", nil, func(e error) bool { var u *UninstallError; return errors.As(e, &u) }},
	}
	for _, c := range cases {
		if got := interpretUninstallOutput(c.out, c.err); !c.want(got) {
			t.Errorf("%q: unexpected %v", c.out, got)
		}
	}
}

func TestUninstallScriptLegacyHelpers(t *testing.T) {
	script := buildUninstallScript("/Applications/LockPlus.app/Contents/MacOS/lockplus-helper")
	idx := func(s string) int {
		i := strings.Index(script, s)
		if i < 0 {
			t.Fatalf("script lacks %q", s)
		}
		return i
	}
	firstBootout := idx("launchctl bootout")
	// WireGuide+ identification and the busy refusal happen before anything is stopped.
	for _, s := range []string{
		"plutil -extract Label raw -o - " + shellQuote(legacy.WGPlusPlist),
		"plutil -extract ProgramArguments.0 raw -o - " + shellQuote(legacy.WGPlusPlist),
		`"$(stat -f %u ` + shellQuote(legacy.WGPlusPlist) + `)" = 0`,
		"pfctl -a " + shellQuote(legacy.WGPlusAnchor) + " -sr",
		shellQuote(cleanupBinary) + " --probe-wgplus",
		"UNINSTALL_ABORTED_LEGACY_BUSY",
		"/usr/bin/codesign --verify --strict -R=" + shellQuote(ourTeamRequirement) + " " + shellQuote(legacyBinary),
	} {
		if i := idx(s); i > firstBootout {
			t.Errorf("%q must come before the first bootout", s)
		}
	}
	// Upstream WireGuide's helper is only touched when it is ours.
	if !strings.Contains(script, "[ $CWG_OURS = 1 ] && launchctl bootout system/"+legacyLabel) ||
		!strings.Contains(script, "[ $CWG_OURS = 1 ] && rm -f "+shellQuote(legacyPlist)+" "+shellQuote(legacyBinary)) {
		t.Error("com.wireguide.helper must only be booted out and removed when CWG_OURS")
	}
	if strings.Contains(script, "launchctl bootout system/"+legacyLabel) && strings.Count(script, "bootout system/"+legacyLabel) != 1 {
		t.Error("unguarded bootout of com.wireguide.helper")
	}
	// The shared anchor is never flushed while upstream is installed.
	for _, m := range regexp.MustCompile(`[^;]*pfctl -a com\.apple/wireguide -Fa`).FindAllString(script, -1) {
		if !strings.Contains(m, "FOREIGN = 0") && !strings.Contains(script[max(0, strings.Index(script, m)-200):strings.Index(script, m)], "FOREIGN = 0") {
			t.Errorf("unguarded flush of the shared anchor: %q", m)
		}
	}
	// rm -rf only on our own two directories.
	for _, m := range regexp.MustCompile(`rm -rf [^;]*`).FindAllString(script, -1) {
		if m != "rm -rf "+shellQuote(socketDir) && m != "rm -rf "+shellQuote(systemDataDir) && m != "rm -rf "+shellQuote(legacy.WGPlusDataDir) {
			t.Errorf("rm -rf outside the known paths: %q", m)
		}
	}
	// WireGuide+ socket dir only via rmdir; its data dir only when it is a
	// real root-owned directory.
	if !strings.Contains(script, "rmdir "+shellQuote(legacy.WGPlusSocketDir)) {
		t.Error("WireGuide+ socket dir must be removed with rmdir")
	}
	d := shellQuote(legacy.WGPlusDataDir)
	if !strings.Contains(script, "if [ ! -L "+d+" ] && [ -d "+d+" ] && [ \"$(stat -f %u "+d+")\" = 0 ]; then rm -rf "+d+"; fi") {
		t.Error("WireGuide+ data dir rm -rf must be guarded (not a symlink, a directory, root-owned)")
	}
	// Its stale pf-was-enabled is never acted on.
	if strings.Contains(script, "cat "+shellQuote(legacy.WGPlusPfWasOn)) {
		t.Error("WireGuide+ pf-was-enabled must not drive pfctl -d")
	}
	// An unexpected plist blocks the binary removal too.
	if !strings.Contains(script, "WGP_UNKNOWN=1") || !strings.Contains(script, "if [ $WGP_UNKNOWN = 0 ] &&") {
		t.Error("an unexpected WireGuide+ plist must make the install unknown")
	}
	// Probe: 10 busy, anything else non-zero fails closed.
	if !strings.Contains(script, "if [ $PRC -eq 10 ]; then") || !strings.Contains(script, "UNINSTALL_ABORTED_LEGACY_PROBE") {
		t.Error("probe exit codes must fail closed")
	}
	re := regexp.MustCompile(wgpProcRE)
	if !re.MatchString(legacy.WGPlusBinary+" --helper --socket=x") || re.MatchString("/bin/sh -c "+script) {
		t.Error("wgpProcRE must match the daemon and not the script itself")
	}
}
