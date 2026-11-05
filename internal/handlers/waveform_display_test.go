package handlers

import (
	"encoding/json"
	"testing"
)

func TestDisplayWaveformStretchesAndToleratesBadData(t *testing.T) {
	got := displayWaveform(json.RawMessage(`[0,70,100]`))
	if string(got) != `[0,12,100]` {
		t.Fatalf("got %s", got)
	}
	if got := displayWaveform(nil); got != nil {
		t.Fatalf("absent stays absent, got %s", got)
	}
	if got := displayWaveform(json.RawMessage(`["x"]`)); got != nil {
		t.Fatalf("bad data is omitted, got %s", got)
	}
}
