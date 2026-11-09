package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/steiale/wireguide/internal/elevate"
	"github.com/steiale/wireguide/internal/farewell"
	"github.com/steiale/wireguide/internal/ipc"
	"github.com/steiale/wireguide/internal/legacy"
	"github.com/steiale/wireguide/internal/update"
)

// v1.2.0 "Farewell" — the Wails-bound side of moving to LockPlus 2.
//
// Order of "Move to LockPlus 2 now":
//  1. retire the helper: no IPC client, no health-monitor reinstall, and wait
//     for an install prompt already on screen to finish;
//  2. record "moved" BEFORE removing anything (a quit mid-removal must never
//     lead to a silent reinstall on the next launch); rolled back on cancel;
//  3. disconnect every tunnel over a short-lived IPC client;
//  4. remove the helper as root (one admin prompt; elevate.UninstallHelper);
//  5. remove the login items (1.0.x LaunchAgent, 1.1.0 SMAppService item);
//  6. download + verify LockPlus 2 and hand over.
//
// User data (~/Library/Application Support/lockplus, keychain items) is never
// touched: LockPlus 2 copies it.

// FarewellHooks are provided by internal/gui, which owns the helper lifecycle.
type FarewellHooks struct {
	// StartHelper connects to (installing or upgrading if needed) the helper
	// in the background, like a normal launch. onCancel, if set, runs instead
	// of the Retry/Quit dialog when the user cancels the admin prompt.
	StartHelper func(onCancel func())
	// RetireHelper stops all use of the helper (closes the IPC client, keeps
	// the health monitor from reinstalling it) and returns once no helper
	// install is in flight.
	RetireHelper func()
}

// farewellRuntime is the Go-side state of the farewell flow.
type farewellRuntime struct {
	mu        sync.Mutex
	hooks     FarewellHooks
	configDir string
	busy      bool
	verified  *farewell.Verified
}

// SetFarewell wires the farewell flow (internal/gui calls it once).
func SetFarewell(s *TunnelService, configDir string, hooks FarewellHooks) {
	s.farewell.mu.Lock()
	defer s.farewell.mu.Unlock()
	s.farewell.configDir = configDir
	s.farewell.hooks = hooks
}

// FarewellStatus is what the "LockPlus 2 is here" screen shows.
type FarewellStatus struct {
	// Choice: "" (not answered), "later", "moved".
	Choice string `json:"choice"`
	// HelperInstalled: the LaunchDaemon plist exists.
	HelperInstalled bool `json:"helper_installed"`
	// Remnants: helper files/state still on disk (empty = clean, as far as
	// LockPlus 2 can tell).
	Remnants []string `json:"remnants"`
	// DownloadReady: a verified LockPlus 2 DMG is waiting to be opened.
	DownloadReady bool   `json:"download_ready"`
	NewVersion    string `json:"new_version,omitempty"`
	// Busy: a move or download is running.
	Busy bool `json:"busy"`
	// Cancelled: the last move stopped at the admin prompt; nothing removed.
	Cancelled bool `json:"cancelled,omitempty"`
	// Brew: installed with Homebrew (the hand-over text differs).
	Brew bool `json:"brew"`
	// Supported: this Mac runs LockPlus 2 (macOS 26+). Otherwise "Move" is
	// never offered and nothing is removed; 1.x keeps working.
	Supported bool `json:"supported"`
	// Blocked: the last move was refused before anything changed:
	// "wgplus_running" (the old WireGuide+ app is open) or "wgplus_busy"
	// (WireGuide+ has a tunnel or its kill switch up).
	Blocked string `json:"blocked,omitempty"`
	// OldApps: installed WireGuide+.app bundles the user may trash.
	OldApps []string `json:"old_apps"`
}

// GetFarewellStatus returns the current farewell state.
func (s *TunnelService) GetFarewellStatus() FarewellStatus {
	s.farewell.mu.Lock()
	defer s.farewell.mu.Unlock()
	return s.farewellStatusLocked()
}

func (s *TunnelService) farewellStatusLocked() FarewellStatus {
	st := FarewellStatus{
		Choice:          string(farewell.LoadState(s.farewell.configDir).Choice),
		HelperInstalled: elevate.HelperInstalled(),
		Remnants:        elevate.HelperRemnants(),
		Busy:            s.farewell.busy,
		Brew:            update.IsBrewInstall(),
		Supported:       farewell.LockPlus2Supported(),
		OldApps:         legacy.OldApps(bundleIDOf),
	}
	if st.Remnants == nil {
		st.Remnants = []string{}
	}
	if st.OldApps == nil {
		st.OldApps = []string{}
	}
	if v := s.farewell.verified; v != nil {
		if _, err := os.Stat(v.DMG); err == nil {
			st.DownloadReady = true
			st.NewVersion = v.Version
		}
	}
	return st
}

// statusIdle is the status a finishing operation returns: Busy is cleared
// by its deferred clearBusy right after, so report it as idle already.
func (s *TunnelService) statusIdle() FarewellStatus {
	st := s.GetFarewellStatus()
	st.Busy = false
	return st
}

// tryBusy marks the flow busy; false if something already runs.
func (s *TunnelService) tryBusy() bool {
	s.farewell.mu.Lock()
	defer s.farewell.mu.Unlock()
	if s.farewell.busy {
		return false
	}
	s.farewell.busy = true
	return true
}

func (s *TunnelService) clearBusy() {
	s.farewell.mu.Lock()
	s.farewell.busy = false
	s.farewell.mu.Unlock()
}

// FarewellLater keeps LockPlus 1 running as before (helper started, upgraded
// if needed) and remembers the answer; the app shows a banner instead. A
// failed state write is reported but never keeps the VPN from starting.
func (s *TunnelService) FarewellLater() error {
	if !s.tryBusy() {
		return nil // a move/download runs; the screen shows it
	}
	defer s.clearBusy()
	return s.keepUsingV1(nil)
}

// KeepUsingLockPlus1 undoes a move: reinstalls the helper (admin prompt) and
// the login item if "Launch at startup" is still on. A cancelled admin prompt
// returns to the "moved" state instead of the Retry/Quit dialog.
func (s *TunnelService) KeepUsingLockPlus1() error {
	if !s.tryBusy() {
		return nil
	}
	defer s.clearBusy()
	err := s.keepUsingV1(func() {
		slog.Info("farewell: helper reinstall cancelled; staying moved")
		if err := farewell.SaveState(s.farewell.configDir, farewell.ChoiceMoved); err != nil {
			slog.Warn("farewell: saving state failed", "error", err)
		}
		if h := s.farewell.hooks.RetireHelper; h != nil {
			h()
		}
		if s.app != nil {
			s.app.Event.Emit("farewell", struct{}{})
		}
	})
	if st, lerr := s.settingsStore.Load(); lerr == nil && st != nil && st.AutoStart {
		if aerr := s.setAutostart(true); aerr != nil {
			slog.Warn("farewell: re-enabling launch at login failed", "error", aerr)
		}
	}
	return err
}

func (s *TunnelService) keepUsingV1(onCancel func()) error {
	err := farewell.SaveState(s.farewell.configDir, farewell.ChoiceLater)
	if err != nil {
		slog.Warn("farewell: saving state failed; starting the helper anyway", "error", err)
	}
	if h := s.farewell.hooks.StartHelper; h != nil {
		h(onCancel)
	}
	go s.migrateAutostart()
	return err
}

// MoveToLockPlus2 removes the helper and the login items. Idempotent: with
// nothing left to remove it skips the admin prompt. A cancelled prompt
// returns a status with Cancelled set (no error) and leaves LockPlus 1 as it
// was (tunnels stay disconnected).
func (s *TunnelService) MoveToLockPlus2() (FarewellStatus, error) {
	if !s.tryBusy() {
		return s.GetFarewellStatus(), nil // Busy set: the screen shows it
	}
	defer s.clearBusy()
	dir := s.farewell.configDir
	prev := farewell.LoadState(dir).Choice
	hooks := s.farewell.hooks
	if !farewell.LockPlus2Supported() {
		return s.statusIdle(), fmt.Errorf("LockPlus 2 needs macOS %d", farewell.MinMacOSMajor)
	}
	// WireGuide+ (1.0.1–1.0.56) checks, before anything changes: its app
	// would reinstall its helper, and its tunnel/kill switch must not be cut.
	if blocked := wireGuidePlusBlocked(); blocked != "" {
		st := s.statusIdle()
		st.Blocked = blocked
		return st, nil
	}
	slog.Info("farewell: moving to LockPlus 2", "previous_choice", prev)

	if hooks.RetireHelper != nil {
		hooks.RetireHelper()
	}
	if err := farewell.SaveState(dir, farewell.ChoiceMoved); err != nil {
		s.rollbackMove(prev, false)
		return s.statusIdle(), fmt.Errorf("saving the move: %w", err)
	}
	s.disconnectAllForFarewell()

	if elevate.HelperInstalled() || len(elevate.HelperRemnants()) > 0 {
		// Re-check WireGuide+ right before the prompt (it may have been
		// opened or connected meanwhile).
		if blocked := wireGuidePlusBlocked(); blocked != "" {
			s.rollbackMove(prev, false)
			st := s.statusIdle()
			st.Blocked = blocked + "_late"
			return st, nil
		}
		if err := elevate.UninstallHelper(); err != nil {
			var ue *elevate.UninstallError
			switch {
			case errors.Is(err, elevate.ErrLegacyBusy), errors.Is(err, elevate.ErrLegacyProbe):
				// Refused by the root script before anything was stopped —
				// but our own tunnels were already disconnected.
				s.rollbackMove(prev, false)
				st := s.statusIdle()
				st.Blocked = "wgplus_busy_late"
				if errors.Is(err, elevate.ErrLegacyProbe) {
					st.Blocked = "wgplus_probe"
				}
				return st, nil
			case errors.Is(err, elevate.ErrUserCancelled):
				s.rollbackMove(prev, false)
				st := s.statusIdle()
				st.Cancelled = true
				return st, nil
			case errors.As(err, &ue) && !ue.Aborted && !elevate.HelperInstalled():
				// The helper is gone but something was left over: stay
				// "moved" (never reinstall behind the user's back); the
				// screen lists the remnants and offers a retry.
				s.removeLoginItems()
				return s.statusIdle(), err
			default:
				// Aborted (helper restored, or down: then start it so its
				// startup recovery undoes pf/DNS) or failed before removal.
				s.rollbackMove(prev, errors.As(err, &ue) && ue.HelperDown)
				return s.statusIdle(), err
			}
		}
	} else {
		slog.Info("farewell: helper already removed, nothing to uninstall")
	}
	s.removeLoginItems()
	slog.Info("farewell: helper removed", "remnants", elevate.HelperRemnants())
	return s.statusIdle(), nil
}

// rollbackMove restores the previous choice; a "later" user (or one whose
// helper is down after an aborted removal) gets the helper started again.
func (s *TunnelService) rollbackMove(prev farewell.Choice, helperDown bool) {
	if err := farewell.SaveState(s.farewell.configDir, prev); err != nil {
		slog.Warn("farewell: restoring state failed", "error", err)
	}
	// After a failed re-bootstrap the helper is started (its recovery
	// restores DNS) — but only if there still is one to start.
	helperDown = helperDown && elevate.HelperInstalled()
	if (prev == farewell.ChoiceLater || helperDown) && s.farewell.hooks.StartHelper != nil {
		s.farewell.hooks.StartHelper(nil)
	}
}

// disconnectAllForFarewell disconnects every tunnel the running helper (any
// version) tracks, over a short-lived client: the app's own client is already
// retired, so no tray or Wi-Fi rule can reconnect in between. Best effort:
// the root removal tears down whatever is left.
func (s *TunnelService) disconnectAllForFarewell() {
	defer s.closeHistorySessions("user")
	addr, _ := ipc.DefaultSocketPath()
	if !ipc.SocketLive(addr) {
		return
	}
	c, err := ipc.NewClient(addr)
	if err != nil {
		return
	}
	defer c.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	var active ipc.ActiveTunnelsResponse
	if err := c.CallWithContext(ctx, ipc.MethodActiveTunnels, nil, &active); err != nil {
		slog.Warn("farewell: cannot list tunnels of the running helper", "error", err)
		return
	}
	names := slices.Clone(active.Names)
	for _, n := range active.Protected {
		if !slices.Contains(names, n) {
			names = append(names, n)
		}
	}
	for _, n := range names {
		if err := c.CallWithContext(ctx, ipc.MethodDisconnect, ipc.DisconnectRequest{TunnelName: n}, nil); err != nil {
			slog.Warn("farewell: disconnect failed", "tunnel", n, "error", err)
		}
	}
}

// removeLoginItems removes the 1.0.x LaunchAgent and the 1.1.0 SMAppService
// login item WITHOUT changing auto_start in config.json: LockPlus 2 reads it
// to offer "Launch at login". (A LaunchAgent already loaded for this login
// session stays loaded but never runs again: it is RunAtLoad-only.)
func (s *TunnelService) removeLoginItems() {
	removeLegacyLaunchAgent()
	removeWireGuidePlusAgent()
	if s.app != nil {
		if err := s.app.Autostart.Disable(); err != nil {
			slog.Warn("farewell: removing the login item failed", "error", err)
		}
	}
}

// DownloadLockPlus2 downloads and verifies LockPlus 2 (Developer ID team,
// bundle ID, notarization). On failure the frontend offers the browser.
func (s *TunnelService) DownloadLockPlus2() (FarewellStatus, error) {
	if !s.tryBusy() {
		return s.GetFarewellStatus(), nil
	}
	s.farewell.mu.Lock()
	s.farewell.verified = nil
	s.farewell.mu.Unlock()

	v, err := downloadAndVerify()

	s.farewell.mu.Lock()
	s.farewell.busy = false
	s.farewell.verified = v
	st := s.farewellStatusLocked()
	s.farewell.mu.Unlock()
	if err != nil {
		slog.Warn("farewell: LockPlus 2 download failed", "error", err)
	}
	return st, err
}

func farewellCacheDir() (string, error) {
	cache, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(cache, "io.github.steiale.lockplus", "LockPlus2"), nil
}

func downloadAndVerify() (*farewell.Verified, error) {
	dir, err := farewellCacheDir()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	dmg, err := farewell.Download(ctx, farewell.DMGURL(), dir)
	if err != nil {
		return nil, err
	}
	v, err := farewell.Verify(ctx, dmg)
	if err != nil {
		os.Remove(dmg)
		return nil, err
	}
	return v, nil
}

// OpenLockPlus2Installer re-verifies the downloaded DMG, opens that same file
// in Finder and quits LockPlus 1, so dragging LockPlus 2 onto Applications can
// replace it (Finder refuses to replace a running app).
func (s *TunnelService) OpenLockPlus2Installer() error {
	s.farewell.mu.Lock()
	v := s.farewell.verified
	s.farewell.mu.Unlock()
	if v == nil {
		return errors.New("LockPlus 2 has not been downloaded yet")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	if err := farewell.VerifyAndOpen(ctx, v.DMG); err != nil {
		return fmt.Errorf("the downloaded LockPlus 2 no longer verifies: %w", err)
	}
	if s.app != nil {
		s.app.Quit()
	}
	return nil
}

// OpenLockPlus2DownloadPage opens the LockPlus 2 download in the browser (the
// fallback when the in-app download can't be used).
func (s *TunnelService) OpenLockPlus2DownloadPage() error {
	if s.app == nil {
		return errors.New("app not initialized")
	}
	return s.app.Browser.OpenURL(farewell.LockPlus2DMGURL)
}

// UninstallHelperCLI is the GUI-less removal behind `lockplus --uninstall-helper`.
func UninstallHelperCLI(configDir string) error {
	if !farewell.LockPlus2Supported() {
		return fmt.Errorf("LockPlus 2 needs macOS %d; nothing was removed", farewell.MinMacOSMajor)
	}
	switch wireGuidePlusBlocked() {
	case "wgplus_running":
		return errors.New("quit WireGuide+ first; nothing was removed")
	case "wgplus_busy":
		return errors.New("disconnect in WireGuide+ first; nothing was removed")
	}
	prev := farewell.LoadState(configDir).Choice
	if err := farewell.SaveState(configDir, farewell.ChoiceMoved); err != nil {
		return err
	}
	// Same guard as the GUI: nothing left to remove → no admin prompt, no
	// root work.
	if !elevate.HelperInstalled() && len(elevate.HelperRemnants()) == 0 {
		removeLegacyLaunchAgent()
		removeWireGuidePlusAgent()
		return nil
	}
	(&TunnelService{}).disconnectAllForFarewell()
	if err := elevate.UninstallHelper(); err != nil {
		var ue *elevate.UninstallError
		if !(errors.As(err, &ue) && !ue.Aborted && !elevate.HelperInstalled()) {
			_ = farewell.SaveState(configDir, prev)
		}
		return err
	}
	removeLegacyLaunchAgent()
	removeWireGuidePlusAgent()
	return nil
}

// --- WireGuide+ (1.0.1–1.0.56) leftovers ---

// bundleIDOf reads CFBundleIdentifier from an Info.plist ("" on error).
func bundleIDOf(plist string) string {
	out, err := exec.Command("/usr/bin/plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", plist).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// wireGuidePlusRunning: the old WireGuide+ app is open (its process is named
// after its executable). It would reinstall its helper behind our back.
var wireGuidePlusRunning = func() bool {
	return exec.Command("/usr/bin/pgrep", "-x", legacy.WGPlusExecutable).Run() == nil
}

// wireGuidePlusBlocked returns why the WireGuide+ helper can't be removed now
// ("" if it can): the old app is open, or its helper has a tunnel or its kill
// switch up (asked as this user, the helper's owner). The root script checks
// the helper again right before stopping anything.
func wireGuidePlusBlocked() string {
	if wireGuidePlusRunning() {
		return "wgplus_running"
	}
	ctx, cancel := context.WithTimeout(context.Background(), legacy.DefaultProbeTimeout)
	defer cancel()
	// Lenient here (a live helper that can't be asked passes); the root
	// script's probe, run right before anything is stopped, fails closed.
	if busy, _, _ := legacy.Busy(ctx, legacy.WGPlusSocket); busy {
		return "wgplus_busy"
	}
	return ""
}

// removeWireGuidePlusAgent removes WireGuide+'s "Launch at startup"
// LaunchAgent, which keeps launching the old app (and through it its helper).
// Only the exact file is touched, and only if it is a regular file owned by
// this user with the exact Label and a ProgramArguments[0] inside a
// WireGuide+ bundle.
func removeWireGuidePlusAgent() {
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	p := filepath.Join(home, "Library", "LaunchAgents", legacy.WGPlusAgentLabel+".plist")
	fi, err := os.Lstat(p)
	if err != nil || !fi.Mode().IsRegular() {
		return
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); !ok || int(st.Uid) != os.Getuid() {
		slog.Warn("farewell: WireGuide+ login item not owned by this user; left alone", "path", p)
		return
	}
	read := func(key string) string {
		out, err := exec.Command("/usr/bin/plutil", "-extract", key, "raw", "-o", "-", p).Output()
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(out))
	}
	if read("Label") != legacy.WGPlusAgentLabel || !strings.HasSuffix(read("ProgramArguments.0"), ".app/Contents/MacOS/"+legacy.WGPlusExecutable) {
		slog.Warn("farewell: unexpected WireGuide+ login item; left alone", "path", p)
		return
	}
	_ = exec.Command("/bin/launchctl", "bootout", fmt.Sprintf("gui/%d/%s", os.Getuid(), legacy.WGPlusAgentLabel)).Run()
	if err := os.Remove(p); err != nil {
		slog.Warn("farewell: removing the WireGuide+ login item failed", "error", err)
		return
	}
	slog.Info("farewell: removed the WireGuide+ login item")
}

// TrashOldApp moves the old WireGuide+.app to the Trash (the frontend asks
// for confirmation first). Finder does the move, so macOS may ask once
// whether LockPlus may control Finder; if that's refused, the app is shown in
// Finder instead. Only bundles found by legacy.OldApps (exact path, bundle ID
// io.github.steiale.wireguide-plus) are touched, and never while it runs.
func (s *TunnelService) TrashOldApp() (FarewellStatus, error) {
	if !s.tryBusy() {
		return s.GetFarewellStatus(), nil
	}
	defer s.clearBusy()
	if wireGuidePlusRunning() {
		st := s.statusIdle()
		st.Blocked = "wgplus_running"
		return st, nil
	}
	for _, app := range legacy.OldApps(bundleIDOf) {
		cmd := exec.Command("/usr/bin/osascript",
			"-e", "on run argv",
			"-e", `tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)`,
			"-e", "end run", app)
		if out, err := cmd.CombinedOutput(); err != nil {
			slog.Warn("farewell: moving WireGuide+ to the Trash failed; revealing it", "app", app, "error", err, "output", strings.TrimSpace(string(out)))
			_ = exec.Command("/usr/bin/open", "-R", app).Run()
			return s.statusIdle(), fmt.Errorf("couldn't move %s to the Trash; it is shown in Finder", filepath.Base(app))
		}
		slog.Info("farewell: moved the old app to the Trash", "app", app)
	}
	return s.statusIdle(), nil
}
