// Package farewell is LockPlus 1.2.0 "Farewell", the last Go release: it
// remembers the user's choice about moving to LockPlus 2 and fetches and
// verifies the LockPlus 2 disk image. Removing the privileged helper lives in
// internal/elevate (UninstallHelper); the orchestration in internal/gui.
package farewell

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/steiale/wireguide/internal/storage"
)

// LockPlus2DMGURL is where LockPlus 2 is downloaded from — the ONE place the
// URL lives. The owner sets the final HTTPS URL of the notarized LockPlus 2
// DMG before release (the release task refuses the .invalid placeholder).
// Whatever it points at, the download is only opened after it passes Verify
// (Developer ID team M53GHX9FAY, LockPlus 2's bundle ID, Gatekeeper
// "Notarized Developer ID"); the browser fallback opens the same URL.
const LockPlus2DMGURL = "https://github.com/steiale/lockplus-updates/releases/latest/download/LockPlus.dmg"

// DMGURL returns the LockPlus 2 download URL: the constant, or — only in
// builds with the farewell_e2e tag — an HTTPS test override (dmgurl_e2e.go).
func DMGURL() string {
	if v := testURLOverride(); strings.HasPrefix(v, "https://") {
		return v
	}
	return LockPlus2DMGURL
}

// Choice is the user's answer to "LockPlus 2 is here".
type Choice string

const (
	// ChoiceNone: not answered yet. The helper is NOT started (nor upgraded)
	// until the user decides, so "Move now" costs one admin prompt, not two.
	ChoiceNone Choice = ""
	// ChoiceLater: keep using LockPlus 1 for now; the helper runs as before.
	ChoiceLater Choice = "later"
	// ChoiceMoved: the helper was removed. LockPlus 1 never reinstalls it on
	// its own again; only the explicit "Keep using LockPlus 1" does.
	ChoiceMoved Choice = "moved"
)

// State is persisted as farewell.json next to config.json. A separate file
// (not a Settings field) so the frontend's full-struct settings saves can't
// clobber it and LockPlus 2's config.json reader never sees it.
type State struct {
	Choice    Choice    `json:"choice"`
	UpdatedAt time.Time `json:"updated_at"`
}

const stateFile = "farewell.json"

// LoadState reads the persisted choice; a missing or unreadable file is
// ChoiceNone (the screen shows again, which is the safe default).
func LoadState(configDir string) State {
	var st State
	data, err := os.ReadFile(filepath.Join(configDir, stateFile))
	if err != nil {
		return State{}
	}
	if json.Unmarshal(data, &st) != nil {
		return State{}
	}
	switch st.Choice {
	case ChoiceLater, ChoiceMoved:
		return st
	}
	return State{}
}

// SaveState persists c atomically.
func SaveState(configDir string, c Choice) error {
	// ChoiceNone is valid: an aborted move rolls back to "not answered".
	if c != ChoiceLater && c != ChoiceMoved && c != ChoiceNone {
		return errors.New("farewell: invalid choice")
	}
	data, err := json.MarshalIndent(State{Choice: c, UpdatedAt: time.Now().UTC()}, "", "  ")
	if err != nil {
		return err
	}
	return storage.WriteFileAtomic(filepath.Join(configDir, stateFile), data)
}
