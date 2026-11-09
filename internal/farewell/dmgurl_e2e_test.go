//go:build farewell_e2e

package farewell

import "testing"

// E2E builds take an HTTPS override and ignore anything else.
func TestDMGURLOverrideInE2E(t *testing.T) {
	t.Setenv("LOCKPLUS_FAREWELL_DMG_URL", "http://example.com/x.dmg")
	if DMGURL() != LockPlus2DMGURL {
		t.Error("non-HTTPS override accepted")
	}
	t.Setenv("LOCKPLUS_FAREWELL_DMG_URL", "https://example.com/x.dmg")
	if DMGURL() != "https://example.com/x.dmg" {
		t.Error("HTTPS override ignored")
	}
}
