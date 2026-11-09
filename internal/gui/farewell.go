package gui

import (
	"sync"
	"sync/atomic"

	wgapp "github.com/steiale/wireguide/internal/app"
	"github.com/steiale/wireguide/internal/ipc"
	"github.com/steiale/wireguide/internal/storage"
	"github.com/wailsapp/wails/v3/pkg/application"
)

// helperControl starts and retires the helper for the v1.2.0 farewell flow.
// Until the user answers "LockPlus 2 is here" the helper isn't started at all
// (so "Move now" never first upgrades a helper it then removes); after a move
// it is "retired": nothing in this process may reinstall it — not the
// bootstrap, not the health monitor's recovery.
type helperControl struct {
	app           *application.App
	clients       *ipc.ClientHolder
	bridge        *eventBridge
	settingsStore *storage.SettingsStore
	dataDir       string

	retired  atomic.Bool
	starting atomic.Bool
	// installMu is held around every ensureHelper call (which may run the
	// admin-prompt install), so retire() can wait until no install is in
	// flight before the helper is removed.
	installMu sync.Mutex
}

// helperCtl is set once by Run before any goroutine reads it.
var helperCtl *helperControl

func (h *helperControl) isRetired() bool { return h != nil && h.retired.Load() }

// lockInstall/unlockInstall bracket ensureHelper; no-ops without a control.
func (h *helperControl) lockInstall() {
	if h != nil {
		h.installMu.Lock()
	}
}

func (h *helperControl) unlockInstall() {
	if h != nil {
		h.installMu.Unlock()
	}
}

// start bootstraps the helper in the background (connect, or install/upgrade
// with the admin prompt) unless it is connected or already starting. onCancel
// replaces the Retry/Quit dialog when the user cancels the admin prompt.
func (h *helperControl) start(onCancel func()) {
	if h.clients.Get() != nil {
		h.retired.Store(false)
		return
	}
	if !h.starting.CompareAndSwap(false, true) {
		return
	}
	h.retired.Store(false)
	go func() {
		defer h.starting.Store(false)
		bootstrapHelper(h.app, h.clients, h.bridge, h.settingsStore, h.dataDir, onCancel)
	}()
}

// markRetired: the helper was removed earlier (state "moved").
func (h *helperControl) markRetired() { h.retired.Store(true) }

// retire stops all use of the helper before it is removed, and returns once
// no install started by this process is still running.
func (h *helperControl) retire() {
	h.retired.Store(true)
	h.clients.Close()
	h.app.Event.Emit("helper", HelperEvent{Alive: false})
	h.installMu.Lock()
	h.installMu.Unlock() //nolint:staticcheck // wait for an in-flight install
}

// UninstallHelperCLI is `lockplus --uninstall-helper`: disconnect, remove the
// helper as root (admin prompt), remove the 1.0.x LaunchAgent, and record the
// move so a later GUI launch doesn't reinstall it. (The 1.1.0 SMAppService
// login item needs the running app; the GUI's move removes it.)
func UninstallHelperCLI() error {
	paths, err := storage.GetPaths()
	if err != nil {
		return err
	}
	return wgapp.UninstallHelperCLI(paths.ConfigDir)
}
