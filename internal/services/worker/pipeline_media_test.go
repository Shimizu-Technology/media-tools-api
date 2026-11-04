package worker

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestMOVTranscodeAndStreamCopySplit(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Fatal("ffmpeg required:", err)
	}
	dir := t.TempDir()
	source := filepath.Join(dir, "capture.mov")
	prepared := filepath.Join(dir, "prepared.mp3")
	out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:a", "aac", source).CombinedOutput()
	if err != nil {
		t.Fatalf("fixture: %v %s", err, out)
	}
	if !requiresWhisperTranscode(source) {
		t.Fatal("MOV must transcode")
	}
	if err := transcodeForWhisper(context.Background(), source, prepared, nil); err != nil {
		t.Fatal(err)
	}
	parts, err := splitAudioForWhisper(context.Background(), prepared, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(parts) < 3 {
		t.Fatalf("parts=%d", len(parts))
	}
	var total float64
	for _, part := range parts {
		duration, err := probeMediaDuration(context.Background(), part)
		if err != nil {
			info, _ := os.Stat(part)
			t.Fatalf("part %s of %d (%v): %v", filepath.Base(part), len(parts), info.Size(), err)
		}
		total += duration
	}
	if total < 2.9 || total > 3.5 { // Stream copy cuts on packet boundaries, so allow a little rounding.
		t.Fatalf("split duration=%f", total)
	}
}

func TestShortSpeechInLongRecordingSurvives(t *testing.T) {
	if err := validateTranscriptionQuality("Please call me tomorrow morning.", 600, nil); err != nil {
		t.Fatal(err)
	}
}
