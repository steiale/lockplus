package farewell

import (
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// MinMacOSMajor is the oldest macOS LockPlus 2 runs on. (1.x and 1.2.0 are
// arm64-only, so there is no CPU check.)
const MinMacOSMajor = 26

// osProductVersion is a var for tests.
var osProductVersion = func() string {
	v, _ := unix.Sysctl("kern.osproductversion")
	return v
}

// MacOSMajor returns the running macOS major version (0 if unknown). The
// 16.x compatibility version some APIs report for macOS 26 maps to 26.
func MacOSMajor() int {
	v := strings.TrimSpace(osProductVersion())
	major, err := strconv.Atoi(strings.SplitN(v, ".", 2)[0])
	if err != nil {
		return 0
	}
	if major == 16 {
		return 26
	}
	return major
}

// LockPlus2Supported reports whether this Mac can run LockPlus 2. Unknown
// counts as unsupported: "Move" removes the helper, so it must never be
// offered on a Mac where LockPlus 2 can't launch.
func LockPlus2Supported() bool { return MacOSMajor() >= MinMacOSMajor }
