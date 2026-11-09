//go:build farewell_e2e

package farewell

import (
	"os"
	"strings"
)

// testURLOverride lets E2E builds (EXTRA_TAGS=farewell_e2e) point the
// download at a local test server. Never compiled into release builds.
func testURLOverride() string {
	return strings.TrimSpace(os.Getenv("LOCKPLUS_FAREWELL_DMG_URL"))
}
