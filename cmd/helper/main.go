// Command helper is the privileged background service for LockPlus.
//
// This is a minimal binary that ONLY imports internal/helper — deliberately
// excluding the Wails/AppKit/WebKit GUI stack so it can run as a root
// LaunchDaemon without a window server (those frameworks crash in headless
// context when run as root).
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/user"
	"strconv"
	"syscall"

	"github.com/steiale/wireguide/internal/helper"
	"github.com/steiale/wireguide/internal/legacy"
)

func main() {
	// --helper is accepted but unused: the GUI binary used this flag to switch
	// between GUI and helper modes in a single binary. This binary is always the
	// helper, so the flag is a no-op kept for backward compatibility with plists
	// written by older GUI versions.
	flag.Bool("helper", false, "no-op: this binary is always the helper")
	socketPath := flag.String("socket", "", "socket path for IPC")
	socketUID := flag.Int("uid", -1, "socket owner UID")
	dataDir := flag.String("data-dir", "", "data directory")
	// --cleanup-only: the v1.2.0 farewell uninstall runs a codesign-verified,
	// root-owned copy of this binary once, after `launchctl bootout`, to undo
	// whatever the stopped helper left behind (pf, routes, DNS, openvpn), then
	// exits. Never serves IPC.
	cleanupOnly := flag.Bool("cleanup-only", false, "run crash recovery once and exit (uninstall)")
	keepShared := flag.Bool("keep-shared-anchor", false, "with --cleanup-only: leave pf anchor com.apple/wireguide and pf state alone (upstream WireGuide installed)")
	// --probe-wgplus: the farewell uninstall asks, before touching anything,
	// whether the WireGuide+ helper still has a tunnel up or its kill switch
	// on. That helper only answers its owner uid, so a root caller drops to
	// the uid owning its socket first. Exit 10 = busy, 0 = idle/unreachable.
	probeWGPlus := flag.Bool("probe-wgplus", false, "exit 10 if the WireGuide+ helper is busy (uninstall)")
	flag.Parse()

	if *probeWGPlus {
		os.Exit(probeWireGuidePlus())
	}

	if *socketPath == "" {
		log.Fatal("--socket required in helper mode")
	}
	if *dataDir == "" {
		*dataDir = systemDataDir()
	}
	if *cleanupOnly {
		if err := helper.RecoverOnly(*socketPath, *dataDir, *keepShared); err != nil {
			log.Fatal("cleanup error:", err)
		}
		log.Println("LockPlus helper cleanup complete")
		return
	}
	log.Println("LockPlus helper starting...")
	if err := helper.Run(*socketPath, *socketUID, *dataDir); err != nil {
		log.Fatal("helper error:", err)
	}
}

func systemDataDir() string {
	return "/Library/Application Support/lockplus"
}

// probeWireGuidePlus implements --probe-wgplus. Exit 0 = idle (no socket or
// nothing listening), 10 = busy, 11 = couldn't switch to the socket owner,
// 12 = a live helper that couldn't be asked (callers fail closed on 11/12).
// As root it first becomes the (non-root) owner of the WireGuide+ socket,
// the only peer that helper answers; a root-owned socket is asked as root.
// The socket path is a constant under /var/run (root:daemon 775, not
// writable by users).
func probeWireGuidePlus() int {
	if os.Geteuid() == 0 {
		fi, err := os.Lstat(legacy.WGPlusSocket)
		if err != nil || fi.Mode()&os.ModeSocket == 0 {
			return 0
		}
		st, ok := fi.Sys().(*syscall.Stat_t)
		if !ok {
			return 11
		}
		if st.Uid != 0 {
			uid := int(st.Uid)
			gid := -1
			if u, err := user.LookupId(strconv.Itoa(uid)); err == nil {
				if g, err := strconv.Atoi(u.Gid); err == nil {
					gid = g
				}
			}
			if gid < 0 {
				gid = 20 // staff
			}
			if err := syscall.Setgroups([]int{gid}); err != nil {
				log.Println("probe: setgroups:", err)
				return 11
			}
			if err := syscall.Setgid(gid); err != nil {
				log.Println("probe: setgid:", err)
				return 11
			}
			if err := syscall.Setuid(uid); err != nil {
				log.Println("probe: setuid:", err)
				return 11
			}
			if syscall.Getuid() != uid || syscall.Geteuid() != uid || syscall.Getgid() != gid || syscall.Getegid() != gid {
				log.Println("probe: privilege drop incomplete")
				return 11
			}
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), legacy.DefaultProbeTimeout)
	defer cancel()
	busy, reachable, err := legacy.Busy(ctx, legacy.WGPlusSocket)
	switch {
	case busy:
		return 10
	case reachable && err != nil:
		log.Println("probe:", err)
		return 12
	}
	return 0
}
