package legacy

import "testing"

func TestStatusBusy(t *testing.T) {
	for raw, want := range map[string]bool{
		`{"state":"disconnected"}`:                            false,
		`{"state":"connected","tunnel_name":"x"}`:             true,
		`{"state":"connecting"}`:                              true,
		`{"state":"disconnected","kill_switch_blocked":true}`: true,
		`{"state":"disconnected","active_tunnels":["a"]}`:     true,
		`{"state":"","tunnels":[{"state":"reconnecting"}]}`:   true,
		`{"state":"","tunnels":[{"state":"error"}]}`:          false,
		`not json`: false,
	} {
		if got := StatusBusy([]byte(raw)); got != want {
			t.Errorf("%s: got %v want %v", raw, got, want)
		}
	}
}
