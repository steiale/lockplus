package farewell

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

const (
	// TeamID is the Developer ID team both LockPlus generations are signed by.
	TeamID = "M53GHX9FAY"
	// NativeBundleID is LockPlus 2's bundle identifier.
	NativeBundleID = "io.github.steiale.lockplus.mac"

	// appRequirement is LockPlus 2's designated requirement (Developer ID
	// Application issued by Apple, our team, its bundle ID).
	appRequirement = `identifier "` + NativeBundleID + `" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "` + TeamID + `"`
	// dmgRequirement: the disk image itself is Developer ID–signed by our team.
	dmgRequirement = `anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "` + TeamID + `"`

	maxDMGSize = 400 << 20 // LockPlus 2's DMG is ~10 MB
	minDMGSize = 1 << 20
)

// Download fetches the LockPlus 2 DMG into destDir (created 0700) and returns
// its path. HTTPS only, every redirect included. The file is tagged with
// com.apple.quarantine like a browser download, so Gatekeeper assesses the
// app on first launch as well.
func Download(ctx context.Context, rawURL, destDir string) (string, error) {
	if !httpsURL(rawURL) {
		return "", fmt.Errorf("refusing non-HTTPS download URL %q", rawURL)
	}
	if err := os.MkdirAll(destDir, 0o700); err != nil {
		return "", err
	}
	sweep(destDir)
	client := &http.Client{
		Timeout: 10 * time.Minute,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("too many redirects")
			}
			if !httpsURL(req.URL.String()) {
				return fmt.Errorf("refusing redirect to non-HTTPS URL %q", req.URL.String())
			}
			return nil
		},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("downloading LockPlus 2: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("downloading LockPlus 2: HTTP %d", resp.StatusCode)
	}
	if resp.ContentLength > maxDMGSize {
		return "", fmt.Errorf("download is %d bytes, more than the %d limit", resp.ContentLength, maxDMGSize)
	}
	f, err := os.CreateTemp(destDir, "LockPlus-2-*.dmg.part")
	if err != nil {
		return "", err
	}
	part := f.Name()
	n, err := io.Copy(f, io.LimitReader(resp.Body, maxDMGSize+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil && (n > maxDMGSize || n < minDMGSize) {
		err = fmt.Errorf("download is %d bytes, not a LockPlus 2 disk image", n)
	}
	if err != nil {
		os.Remove(part)
		return "", err
	}
	// Quarantine before the final name exists, so the DMG is never there
	// without it.
	q := fmt.Sprintf("0083;%x;LockPlus;", time.Now().Unix())
	if err := unix.Setxattr(part, "com.apple.quarantine", []byte(q), 0); err != nil {
		os.Remove(part)
		return "", fmt.Errorf("setting quarantine attribute: %w", err)
	}
	dmg := filepath.Join(destDir, "LockPlus-2.dmg")
	if err := os.Rename(part, dmg); err != nil {
		os.Remove(part)
		return "", err
	}
	slog.Info("farewell: LockPlus 2 downloaded", "bytes", n)
	return dmg, nil
}

// sweep removes leftovers of earlier runs in the private download dir: a
// partial download, an old DMG, empty mount points.
func sweep(dir string) {
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		switch {
		case strings.HasSuffix(e.Name(), ".part"), e.Name() == "LockPlus-2.dmg":
			os.Remove(p)
		case e.IsDir() && strings.HasPrefix(e.Name(), "mnt-"):
			os.Remove(p) // only succeeds when empty (not mounted)
		}
	}
}

// VerifyAndOpen re-verifies dmg and opens it in Finder, refusing if the file
// was replaced while it was being verified.
func VerifyAndOpen(ctx context.Context, dmg string) error {
	before, err := os.Lstat(dmg)
	if err != nil {
		return err
	}
	if !before.Mode().IsRegular() {
		return errors.New("the disk image is not a regular file")
	}
	sumBefore, err := fileSHA256(dmg)
	if err != nil {
		return err
	}
	if _, err := Verify(ctx, dmg); err != nil {
		return err
	}
	after, err := os.Lstat(dmg)
	if err != nil {
		return err
	}
	if !os.SameFile(before, after) || !before.ModTime().Equal(after.ModTime()) || before.Size() != after.Size() {
		return errors.New("the disk image changed while it was being verified")
	}
	// Content check right before opening: an in-place rewrite keeps the
	// inode and can fake size and mtime. (Gatekeeper still assesses the
	// quarantined image and app on open; a same-user attacker could swap
	// the file after this point, which nothing here can prevent.)
	if sumAfter, err := fileSHA256(dmg); err != nil || sumAfter != sumBefore {
		return errors.New("the disk image changed while it was being verified")
	}
	if out, err := run(ctx, "/usr/bin/open", dmg); err != nil {
		return fmt.Errorf("opening the disk image: %v (%s)", err, out)
	}
	return nil
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func httpsURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme == "https" && u.Host != ""
}

// Verified describes a disk image that passed Verify.
type Verified struct {
	DMG     string `json:"dmg"`
	Version string `json:"version"`
}

// Verify checks a downloaded DMG before LockPlus offers to open it:
//  1. the image is signed by our Developer ID team and Gatekeeper accepts it
//     as notarized;
//  2. mounted read-only (not shown in Finder), it contains LockPlus.app
//     signed with LockPlus 2's designated requirement (bundle ID + team);
//  3. Gatekeeper accepts that app as "Notarized Developer ID".
//
// The image is detached again before returning.
func Verify(ctx context.Context, dmg string) (*Verified, error) {
	if err := codesignVerify(ctx, dmg, dmgRequirement, false); err != nil {
		return nil, fmt.Errorf("disk image signature: %w", err)
	}
	if err := spctlNotarized(ctx, dmg, "open", "--context", "context:primary-signature"); err != nil {
		return nil, fmt.Errorf("disk image notarization: %w", err)
	}

	mnt, err := os.MkdirTemp(filepath.Dir(dmg), "mnt-")
	if err != nil {
		return nil, err
	}
	defer os.Remove(mnt)
	if out, err := run(ctx, "/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
		"-mountpoint", mnt, dmg); err != nil {
		return nil, fmt.Errorf("mounting the disk image: %v (%s)", err, out)
	}
	defer func() {
		dctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if _, err := run(dctx, "/usr/bin/hdiutil", "detach", mnt); err != nil {
			_, _ = run(dctx, "/usr/bin/hdiutil", "detach", "-force", mnt)
		}
	}()

	app := filepath.Join(mnt, "LockPlus.app")
	if fi, err := os.Lstat(app); err != nil || !fi.IsDir() {
		return nil, errors.New("the disk image doesn't contain LockPlus.app")
	}
	if err := codesignVerify(ctx, app, appRequirement, true); err != nil {
		return nil, fmt.Errorf("app signature: %w", err)
	}
	if err := spctlNotarized(ctx, app, "execute"); err != nil {
		return nil, fmt.Errorf("app notarization: %w", err)
	}
	ver, err := bundleVersion(filepath.Join(app, "Contents", "Info.plist"))
	if err != nil {
		return nil, err
	}
	if major, err := strconv.Atoi(strings.SplitN(ver, ".", 2)[0]); err != nil || major < 2 {
		return nil, fmt.Errorf("the disk image holds LockPlus %s, not LockPlus 2", ver)
	}
	slog.Info("farewell: LockPlus 2 disk image verified", "version", ver)
	return &Verified{DMG: dmg, Version: ver}, nil
}

func codesignVerify(ctx context.Context, path, requirement string, deep bool) error {
	args := []string{"--verify", "--strict"}
	if deep {
		args = append(args, "--deep")
	}
	args = append(args, "-R="+requirement, path)
	if out, err := run(ctx, "/usr/bin/codesign", args...); err != nil {
		return fmt.Errorf("%v (%s)", err, out)
	}
	return nil
}

// spctlNotarized requires Gatekeeper's verdict "accepted" with source
// "Notarized Developer ID" (a merely Developer ID–signed, un-notarized
// build is rejected).
func spctlNotarized(ctx context.Context, path, typ string, extra ...string) error {
	args := append([]string{"--assess", "--type", typ, "-vv"}, extra...)
	args = append(args, path)
	out, err := run(ctx, "/usr/sbin/spctl", args...)
	if err != nil {
		return fmt.Errorf("Gatekeeper rejected it: %v (%s)", err, out)
	}
	accepted, notarized := false, false
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasSuffix(line, ": accepted") {
			accepted = true
		}
		if line == "source=Notarized Developer ID" {
			notarized = true
		}
	}
	if !accepted || !notarized {
		return fmt.Errorf("not notarized (%s)", out)
	}
	return nil
}

func run(ctx context.Context, name string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// bundleVersion reads CFBundleShortVersionString via plutil (handles binary
// and XML plists).
func bundleVersion(plist string) (string, error) {
	out, err := exec.Command("/usr/bin/plutil", "-convert", "xml1", "-o", "-", plist).Output()
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", plist, err)
	}
	var doc struct {
		Dict struct {
			Items []struct {
				XMLName xml.Name
				Value   string `xml:",chardata"`
			} `xml:",any"`
		} `xml:"dict"`
	}
	if err := xml.Unmarshal(out, &doc); err != nil {
		return "", err
	}
	items := doc.Dict.Items
	for i := 0; i+1 < len(items); i++ {
		if items[i].XMLName.Local == "key" && items[i].Value == "CFBundleShortVersionString" {
			return strings.TrimSpace(items[i+1].Value), nil
		}
	}
	return "", errors.New("LockPlus.app has no version")
}
