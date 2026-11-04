package worker

import (
	"errors"
	"fmt"
	"testing"
)

func TestPublicAudioFailureMessageHidesInternalDetail(t *testing.T) {
	internal := fmt.Errorf("failed to stat temp file /tmp/abc.caf: %w", errors.New("no such file"))
	if got := publicAudioFailureMessage(internal); got != genericAudioFailureMessage {
		t.Fatalf("internal detail reached the user: %q", got)
	}
	want := "This video has no audio track. Upload a video that contains audio."
	wrapped := fmt.Errorf("prepare: %w", newPublicAudioError(want))
	if got := publicAudioFailureMessage(wrapped); got != want {
		t.Fatalf("public message lost: %q", got)
	}
}

func TestIsGeneratedRecordingName(t *testing.T) {
	for _, name := range []string{
		"Recording — Nov 4, 2026 at 8:28 PM",
		"New Recording 5.m4a",
		"Recording",
		"3f1c9f1e-7a56-4a1b-9c1e-1234567890ab.caf",
		"2026-11-04 08.30.12.m4a",
		"Voice Memo",
	} {
		if !isGeneratedRecordingName(name) {
			t.Errorf("%q should count as generated", name)
		}
	}
	for _, name := range []string{"Payroll call v2.1", "Meeting with Dana", "Recording of the board call", "Tumon Bay Rd 5.m4a"} {
		if isGeneratedRecordingName(name) {
			t.Errorf("%q is a name a person chose", name)
		}
	}
}
