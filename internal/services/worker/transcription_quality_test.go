package worker

import (
	"strings"
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
)

func TestValidateTranscriptionQualityRejectsRepetitiveHallucination(t *testing.T) {
	bad := strings.Repeat("1 tbsp of cornstarch 1 tbsp of water ", 80)

	if err := validateTranscriptionQuality(bad, 15*60, nil); err == nil {
		t.Fatal("expected repetitive hallucination to fail quality check")
	}
}

func TestValidateTranscriptionQualityRejectsMixedRepeatedPatterns(t *testing.T) {
	pattern := "alpha beta gamma delta flour sugar salt oil monday tuesday wednesday thursday red blue green yellow north south east west one two three four "
	bad := strings.Repeat(pattern, 10)

	if err := validateTranscriptionQuality(bad, 12*60, nil); err == nil {
		t.Fatal("expected mixed repeated hallucination patterns to fail quality check")
	}
}

func TestValidateTranscriptionQualityAllowsNaturalMeetingText(t *testing.T) {
	text := strings.Join([]string{
		"Leon walked through the updated authentication flow and explained how Clerk should own the browser session.",
		"The team discussed direct uploads, saved recordings, transcription retries, summaries, action items, and collection chat.",
		"Next steps are to deploy the audio normalization fix, reprocess the meeting, and verify the summary before sharing it.",
		"Everyone agreed that failed or suspicious transcripts should surface a clear retry path instead of pretending the result is complete.",
		"The recording playback should remain available so the team can validate whether the issue is capture quality or transcription quality.",
	}, " ")

	if err := validateTranscriptionQuality(text, 10*60, nil); err != nil {
		t.Fatalf("expected natural meeting text to pass quality check, got %v", err)
	}
}

func TestValidateTranscriptionQualityRejectsBadSegments(t *testing.T) {
	segments := []audio.TranscriptionSegment{
		{Text: "bad one", CompressionRatio: 3.1, AvgLogprob: -0.2},
		{Text: "bad two", CompressionRatio: 3.0, AvgLogprob: -0.3},
		{Text: "ok", CompressionRatio: 1.1, AvgLogprob: -0.1},
	}

	if err := validateTranscriptionQuality("This has enough text to avoid the empty transcript branch.", 90, segments); err == nil {
		t.Fatal("expected bad segment compression to fail quality check")
	}
}
