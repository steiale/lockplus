//go:build !farewell_e2e

package farewell

// testURLOverride: release builds have no download URL override.
func testURLOverride() string { return "" }
