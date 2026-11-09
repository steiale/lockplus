package legacy

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestDialIdle(t *testing.T) {
	op := func(e error) error {
		return &net.OpError{Op: "dial", Net: "unix", Err: os.NewSyscallError("connect", e)}
	}
	for err, want := range map[error]bool{
		op(syscall.ECONNREFUSED):  true,
		op(syscall.ENOENT):        true,
		op(syscall.EAGAIN):        false,
		op(syscall.ETIMEDOUT):     false,
		fmt.Errorf("i/o timeout"): false,
	} {
		if got := dialIdle(err); got != want {
			t.Errorf("%v: got %v want %v", err, got, want)
		}
	}
}

// A socket file nobody listens on is idle; a missing one too.
func TestBusyRefusedSocketIsIdle(t *testing.T) {
	dir, err := os.MkdirTemp("", "lpw") // short path: sun_path is 104 bytes
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sock := filepath.Join(dir, "s.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	l.(*net.UnixListener).SetUnlinkOnClose(false)
	l.Close()
	busy, reachable, err := Busy(context.Background(), sock)
	if busy || reachable || err != nil {
		t.Fatalf("refused socket: busy=%v reachable=%v err=%v", busy, reachable, err)
	}
	if busy, reachable, err := Busy(context.Background(), filepath.Join(dir, "none.sock")); busy || reachable || err != nil {
		t.Fatalf("missing socket: %v %v %v", busy, reachable, err)
	}
}
