package elevate

import (
	"errors"
	"os/exec"
	"regexp"
	"strings"
	"testing"
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
