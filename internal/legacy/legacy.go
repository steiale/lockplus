// Package legacy knows the WireGuide+ (LockPlus 1.0.1–1.0.56) root helper,
// which v1.2.0 "Farewell" removes together with the LockPlus helper. Its
// helpers predate Developer ID signing, so they are identified by exact
// paths, plist Label/ProgramArguments and root ownership (checked as root in
// the uninstall script), never by signature.
package legacy

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/steiale/wireguide/internal/ipc"
)

const (
	WGPlusLabel      = "io.github.steiale.wireguide-plus.helper"
	WGPlusPlist      = "/Library/LaunchDaemons/" + WGPlusLabel + ".plist"
	WGPlusBinary     = "/Library/PrivilegedHelperTools/" + WGPlusLabel
	WGPlusSocketDir  = "/var/run/wireguide-plus"
	WGPlusSocket     = WGPlusSocketDir + "/wireguide-plus.sock"
	WGPlusLog        = "/var/log/wireguide-plus-helper.log"
	WGPlusDataDir    = "/Library/Application Support/wireguide-plus"
	WGPlusPfWasOn    = WGPlusDataDir + "/pf-was-enabled"
	WGPlusAnchor     = "com.apple.wireguide" // dot: never evaluated by pf, so inert
	WGPlusAnchorDNS  = WGPlusAnchor + "/dns"
	WGPlusBundleID   = "io.github.steiale.wireguide-plus"
	WGPlusExecutable = "wireguide-plus"
	WGPlusAgentLabel = "io.github.steiale.wireguide-plus.gui"
)

// WGPlusPaths are the WireGuide+ helper paths LockPlus 2 would report as
// left behind (the log is removed too but not reported).
var WGPlusPaths = []string{WGPlusPlist, WGPlusBinary, WGPlusSocketDir, WGPlusDataDir}

// Busy reports whether the helper serving socket has a tunnel up (connecting,
// connected, reconnecting) or its kill switch holding traffic. Only "no socket"
// or "nothing listening" is a definite idle (its tunnels die with it:
// wireguard-go runs in-process); a live helper that can't be asked returns
// reachable=true with err set, which callers deciding about removal must
// treat as "can't tell". The helper only answers its owner uid, so call this
// as that user.
func Busy(ctx context.Context, socket string) (busy, reachable bool, err error) {
	if fi, lerr := os.Lstat(socket); lerr != nil || fi.Mode()&os.ModeSocket == 0 {
		return false, false, nil
	}
	if !ipc.SocketLive(socket) {
		return false, false, nil
	}
	c, err := ipc.NewClient(socket)
	if err != nil {
		return false, true, err
	}
	defer c.Close()
	var st json.RawMessage
	if err := c.CallWithContext(ctx, ipc.MethodStatus, nil, &st); err != nil {
		return false, true, err
	}
	return StatusBusy(st), true, nil
}

// StatusBusy interprets a Tunnel.Status reply of any 1.x version.
func StatusBusy(raw []byte) bool {
	var s struct {
		State             string   `json:"state"`
		KillSwitchBlocked bool     `json:"kill_switch_blocked"`
		ActiveTunnels     []string `json:"active_tunnels"`
		Tunnels           []struct {
			State string `json:"state"`
		} `json:"tunnels"`
	}
	if json.Unmarshal(raw, &s) != nil {
		return false
	}
	active := func(st string) bool {
		switch strings.ToLower(st) {
		case "connected", "connecting", "reconnecting":
			return true
		}
		return false
	}
	if active(s.State) || s.KillSwitchBlocked || len(s.ActiveTunnels) > 0 {
		return true
	}
	for _, t := range s.Tunnels {
		if active(t.State) {
			return true
		}
	}
	return false
}

// DefaultProbeTimeout bounds one Busy probe.
const DefaultProbeTimeout = 5 * time.Second

// OldApps returns installed WireGuide+ app bundles (verified by bundle ID)
// in /Applications and ~/Applications.
func OldApps(bundleID func(plist string) string) []string {
	dirs := []string{"/Applications"}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, "Applications"))
	}
	var out []string
	for _, d := range dirs {
		p := filepath.Join(d, "WireGuide+.app")
		fi, err := os.Lstat(p)
		if err != nil || !fi.IsDir() {
			continue
		}
		if bundleID(filepath.Join(p, "Contents", "Info.plist")) == WGPlusBundleID {
			out = append(out, p)
		}
	}
	return out
}
