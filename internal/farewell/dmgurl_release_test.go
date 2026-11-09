//go:build !farewell_e2e

package farewell

import "testing"

// Release builds (no farewell_e2e tag) ignore the test override.
func TestDMGURLNoOverrideInRelease(t *testing.T) {
	t.Setenv("LOCKPLUS_FAREWELL_DMG_URL", "https://example.com/x.dmg")
	if DMGURL() != LockPlus2DMGURL {
		t.Error("release build honoured the test URL override")
	}
}
