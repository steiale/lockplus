// WireGuide — GUI binary entrypoint.
//
// This binary runs as the current user and hosts the Wails window + tray.
// The privileged helper is a separate binary (cmd/helper) installed as a
// LaunchDaemon — see cmd/helper/main.go.
//
// main.go is intentionally tiny: bootstrap GUI mode only. GUI runtime lives
// in internal/gui.
package main

import (
	"embed"
	"fmt"
	"log"
	"os"

	"github.com/steiale/wireguide/internal/gui"
	"github.com/wailsapp/wails/v3/pkg/application"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	// v1.2.0: `LockPlus.app/Contents/MacOS/lockplus --uninstall-helper`
	// removes the privileged helper without the GUI (e.g. before a Homebrew
	// cask switches to LockPlus 2). Same root script as "Move to LockPlus 2".
	if len(os.Args) == 2 && os.Args[1] == "--uninstall-helper" {
		if os.Geteuid() == 0 {
			// Run as the user: macOS asks for the password itself, and the
			// move must be recorded in that user's LockPlus settings.
			fmt.Fprintln(os.Stderr, "LockPlus: run --uninstall-helper as your user, not with sudo.")
			os.Exit(2)
		}
		if err := gui.UninstallHelperCLI(); err != nil {
			fmt.Fprintln(os.Stderr, "LockPlus: helper removal failed:", err)
			os.Exit(1)
		}
		fmt.Println("LockPlus: the helper was removed.")
		return
	}
	if err := gui.Run(application.AssetFileServerFS(assets), systemDataDir()); err != nil {
		log.Fatal(err)
	}
}

// systemDataDir returns the system-level data directory used by the GUI to
// locate helper-managed state (e.g. crash recovery files written by the
// privileged helper at /Library/Application Support/lockplus on macOS).
func systemDataDir() string {
	return "/Library/Application Support/lockplus"
}
