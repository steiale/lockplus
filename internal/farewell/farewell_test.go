package farewell

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStateRoundTrip(t *testing.T) {
	dir := t.TempDir()
	if got := LoadState(dir).Choice; got != ChoiceNone {
		t.Fatalf("missing file: got %q", got)
	}
	for _, c := range []Choice{ChoiceLater, ChoiceMoved} {
		if err := SaveState(dir, c); err != nil {
			t.Fatal(err)
		}
		if got := LoadState(dir).Choice; got != c {
			t.Fatalf("got %q, want %q", got, c)
		}
	}
	if err := SaveState(dir, Choice("bogus")); err == nil {
		t.Fatal("invalid choice accepted")
	}
	if err := os.WriteFile(filepath.Join(dir, stateFile), []byte(`{"choice":"bogus"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := LoadState(dir).Choice; got != ChoiceNone {
		t.Fatalf("unknown choice must read as none, got %q", got)
	}
}

func TestDownloadRefusesHTTP(t *testing.T) {
	if _, err := Download(context.Background(), "http://example.com/x.dmg", t.TempDir()); err == nil {
		t.Fatal("plain HTTP accepted")
	}
}

// Verify must reject an image that isn't ours: here, a valid but unsigned DMG.
func TestVerifyRejectsUnsignedImage(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	if err := os.MkdirAll(filepath.Join(src, "LockPlus.app", "Contents"), 0o755); err != nil {
		t.Fatal(err)
	}
	dmg := filepath.Join(dir, "x.dmg")
	if out, err := run(context.Background(), "/usr/bin/hdiutil", "create", "-quiet", "-fs", "HFS+", "-srcfolder", src, "-format", "UDZO", dmg); err != nil {
		t.Skipf("hdiutil unavailable: %v %s", err, out)
	}
	_, err := Verify(context.Background(), dmg)
	if err == nil || !strings.Contains(err.Error(), "signature") {
		t.Fatalf("unsigned image: got %v", err)
	}
}

// LOCKPLUS2_DMG=<path> runs Verify against a real LockPlus 2 release DMG.
func TestVerifyRealImage(t *testing.T) {
	p := os.Getenv("LOCKPLUS2_DMG")
	if p == "" {
		t.Skip("set LOCKPLUS2_DMG to a LockPlus 2 release DMG")
	}
	v, err := Verify(context.Background(), p)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(v.Version, "2.") {
		t.Fatalf("version %q", v.Version)
	}
}
