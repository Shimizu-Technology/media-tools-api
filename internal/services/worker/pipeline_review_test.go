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
		"recording-2026-02-03-14-22-01.webm",
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

// Names copied in shape from production, where migration 055 flagged every old row.
func TestLegacyPlaceholderNameOnlyMatchesGeneratedFormats(t *testing.T) {
	for _, name := range []string{
		"recording-2026-02-03-14-22-01.webm",
		"Recording — Aug 26, 2026 at 10:35 AM.m4a",
		"New Recording 42.m4a",
		"3F1C9F1E-7A56-4A1B-9C1E-1234567890AB.caf",
	} {
		if !isLegacyPlaceholderName(name) || !isGeneratedRecordingName(name) {
			t.Errorf("%q should qualify", name)
		}
	}
	for _, name := range []string{
		"New Recording Mr. Mon Mendiola for UOG and Coffee.m4a",
		"Recording of the 2024 budget meeting.m4a",
		"Recording 2026 goals.m4a",
		"Audio 3.m4a",
		"Hafa Baby updates",
	} {
		if isLegacyPlaceholderName(name) {
			t.Errorf("%q may have been typed by a person", name)
		}
	}
}

func TestRecordingTitleSafetyRegression(t *testing.T) {
	for _, name := range []string{
		"New Recording 12. Mon Mendiola", "Recording. Dad's story about Guam", "Untitled. Call with the bank",
		"Voice Memo 3.Hafa Baby", "New Recording 7.Baby's first words", "Recording — Mayor interview 2026 at 10:35 AM",
		"New Recording Mr. Mon Mendiola for UOG and Coffee.m4a", "Recording — Feb 30, 2026 at 10:35 AM",
		"Recording — Aug 26, 2026 at 25:35", "Recording — Aug 26, 2026 at 0:35 AM",
	} {
		for _, test := range []struct {
			name  string
			match func(string) bool
		}{{"automatic", isGeneratedRecordingName}, {"legacy", isLegacyPlaceholderName}} {
			if test.match(name) {
				t.Errorf("%s would overwrite chosen name %q", test.name, name)
			}
		}
	}
	for _, name := range []string{
		"Recording — Aug 26, 2026 at 10:35 AM.m4a",
		"Recording — Aug 26, 2026 at 10:35\u00a0AM.m4a",
		"Recording — Aug 26, 2026 at 10:35 AM.m4a", // literal U+202F from production's format
		"Recording — Aug 26, 2026 at 22:35.M4A",
		"Recording — Nov 4, 2026 at 8:28\u202fPM",
		"New Recording 42.FLAC", "Voice Memo 3.OPUS",
	} {
		if !isGeneratedRecordingName(name) || !isLegacyPlaceholderName(name) {
			t.Errorf("actual placeholder rejected %q", name)
		}
	}
}
