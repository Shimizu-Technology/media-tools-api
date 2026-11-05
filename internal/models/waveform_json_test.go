package models

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRecordingJSONShapesItsWaveform(t *testing.T) {
	peaks := make([]int, 200)
	for i := range peaks {
		peaks[i] = 70 + i%31
	}
	raw, err := json.Marshal(peaks)
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(AudioTranscription{ID: "a", Waveform: raw})
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Waveform []int `json:"waveform"`
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Waveform) != 200 || got.Waveform[0] != 12 || got.Waveform[30] != 100 {
		t.Fatalf("waveform not shaped: %v", got.Waveform[:31])
	}
}

func TestRecordingJSONOmitsOrNullsUnusableWaveforms(t *testing.T) {
	absent, err := json.Marshal(AudioTranscription{ID: "a"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(absent), `"waveform"`) {
		t.Fatalf("absent waveform must be omitted: %s", absent)
	}
	for _, stored := range []string{`["x"]`, `null`, `[]`, `[1,2,3]`} {
		body, err := json.Marshal(AudioTranscription{ID: "a", Waveform: WaveformPeaks(stored)})
		if err != nil {
			t.Fatalf("%s: %v", stored, err)
		}
		if !strings.Contains(string(body), `"waveform":null`) {
			t.Fatalf("%s: %s", stored, body)
		}
	}
}
