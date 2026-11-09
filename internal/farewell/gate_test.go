package farewell

import "testing"

func TestLockPlus2Supported(t *testing.T) {
	orig := osProductVersion
	defer func() { osProductVersion = orig }()
	for v, want := range map[string]bool{"26.0": true, "26.6.2": true, "27.0.1": true, "16.0": true, "15.7.1": false, "13.0": false, "": false, "x": false} {
		osProductVersion = func() string { return v }
		if got := LockPlus2Supported(); got != want {
			t.Errorf("%q: got %v want %v", v, got, want)
		}
	}
}
