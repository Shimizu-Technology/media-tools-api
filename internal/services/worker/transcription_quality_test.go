package worker

import (
	"fmt"
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

func TestValidateTranscriptionQualityAllowsLongMeetingWithRecurringPhrases(t *testing.T) {
	topics := []string{
		"timeline", "budget", "design", "implementation", "testing", "deployment",
		"feedback", "training", "support", "reporting", "integration", "migration",
	}
	verbs := []string{
		"review", "clarify", "prioritize", "document", "schedule", "confirm",
		"compare", "prepare", "share", "update", "validate", "coordinate",
	}
	parts := make([]string, 0, 240)
	for i := 0; i < 240; i++ {
		parts = append(parts, fmt.Sprintf(
			"I think we should %s the %s with the team because the client asked about requirements, blockers, ownership, risks, decisions, follow up, and next steps during the meeting.",
			verbs[i%len(verbs)],
			topics[(i*5)%len(topics)],
		))
	}

	if err := validateTranscriptionQuality(strings.Join(parts, " "), 2*60*60, nil); err != nil {
		t.Fatalf("expected long natural meeting with recurring phrases to pass quality check, got %v", err)
	}
}

func TestForEachWordWindowVisitsFullTailWindow(t *testing.T) {
	words := []string{"w0", "w1", "w2", "w3", "w4", "w5", "w6", "w7", "w8", "w9", "w10"}
	var windows [][]string
	forEachWordWindow(words, 4, func(window []string) {
		copied := append([]string(nil), window...)
		windows = append(windows, copied)
	})

	if len(windows) == 0 {
		t.Fatal("expected at least one visited window")
	}
	last := windows[len(windows)-1]
	if len(last) != 4 {
		t.Fatalf("last window length = %d, want full window length 4", len(last))
	}
	if got, want := strings.Join(last, " "), "w7 w8 w9 w10"; got != want {
		t.Fatalf("last window = %q, want %q", got, want)
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

func TestSanitizeTranscriptionResultRemovesRepeatedWhisperLoop(t *testing.T) {
	segments := []audio.TranscriptionSegment{
		{Text: "Before the loop we discussed the school."},
	}
	for i := 0; i < 35; i++ {
		segments = append(segments, audio.TranscriptionSegment{
			Text:             "We're at Harvest.",
			CompressionRatio: 12,
			NoSpeechProb:     0.85,
		})
	}
	segments = append(segments, audio.TranscriptionSegment{Text: "After the loop the conversation continued."})

	text, cleanedSegments, removed := sanitizeTranscriptionResult(&audio.TranscriptionResult{
		Text:     transcriptionTextFromSegments(segments),
		Segments: segments,
	})

	if removed != 34 {
		t.Fatalf("removed segments = %d, want 34", removed)
	}
	if len(cleanedSegments) != 3 {
		t.Fatalf("cleaned segment count = %d, want 3", len(cleanedSegments))
	}
	if strings.Count(text, "We're at Harvest.") != 1 {
		t.Fatalf("expected repeated phrase to be kept once, got text %q", text)
	}
	if err := validateTranscriptionQuality(text, 15*60, cleanedSegments); err != nil {
		t.Fatalf("expected cleaned transcript to pass quality check, got %v", err)
	}
}

func TestSanitizeStitchedTranscriptionCollapsesCrossChunkLengthOnlyLoop(t *testing.T) {
	chunkA := []audio.TranscriptionSegment{{Text: "Before the boundary loop we discussed the meeting.", Start: 270, End: 275}}
	for i := 0; i < 10; i++ {
		chunkA = append(chunkA, audio.TranscriptionSegment{Text: "I know.", Start: float64(280 + i), End: float64(281 + i)})
	}
	chunkB := make([]audio.TranscriptionSegment, 0, 11)
	for i := 0; i < 10; i++ {
		chunkB = append(chunkB, audio.TranscriptionSegment{Text: "I know.", Start: float64(i), End: float64(i + 1)})
	}
	chunkB = append(chunkB, audio.TranscriptionSegment{Text: "After the loop the call continued.", Start: 10, End: 15})

	if _, _, removed := sanitizeTranscriptionResult(&audio.TranscriptionResult{Text: transcriptionTextFromSegments(chunkA), Segments: chunkA}); removed != 0 {
		t.Fatalf("first chunk removed %d segment(s), want 0", removed)
	}
	if _, _, removed := sanitizeTranscriptionResult(&audio.TranscriptionResult{Text: transcriptionTextFromSegments(chunkB), Segments: chunkB}); removed != 0 {
		t.Fatalf("second chunk removed %d segment(s), want 0", removed)
	}

	stitchedSegments := append(append([]audio.TranscriptionSegment{}, chunkA...), chunkB...)
	text, cleanedSegments, removed := sanitizeStitchedTranscription(transcriptionTextFromSegments(stitchedSegments), stitchedSegments)

	if removed != 19 {
		t.Fatalf("stitched removed segments = %d, want 19", removed)
	}
	if len(cleanedSegments) != 3 {
		t.Fatalf("cleaned stitched segment count = %d, want 3", len(cleanedSegments))
	}
	if strings.Count(text, "I know.") != 1 {
		t.Fatalf("expected length-only repeated phrase to be kept once, got text %q", text)
	}
	if !strings.Contains(text, "I know.\n\nAfter the loop") {
		t.Fatalf("expected chunk paragraph break to be preserved after post-stitch cleanup, got text %q", text)
	}
}

func TestSanitizeTranscriptionResultKeepsNormalAcknowledgements(t *testing.T) {
	segments := []audio.TranscriptionSegment{
		{Text: "Yeah."},
		{Text: "Yeah."},
		{Text: "Yeah."},
		{Text: "That makes sense."},
		{Text: "Let's move on to the next topic."},
	}

	_, cleanedSegments, removed := sanitizeTranscriptionResult(&audio.TranscriptionResult{
		Text:     transcriptionTextFromSegments(segments),
		Segments: segments,
	})

	if removed != 0 {
		t.Fatalf("removed segments = %d, want 0", removed)
	}
	if len(cleanedSegments) != len(segments) {
		t.Fatalf("cleaned segment count = %d, want %d", len(cleanedSegments), len(segments))
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
