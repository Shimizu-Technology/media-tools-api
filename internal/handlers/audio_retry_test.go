package handlers

import (
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestAudioSourceRetryBlockedOnlyForPermanentSourceFailure(t *testing.T) {
	t.Parallel()

	for _, test := range []struct {
		stage   string
		message string
		want    bool
	}{
		{stage: "invalid_source", want: true},
		{stage: "failed", message: "ffmpeg transcode failed: moov atom not found", want: true},
		{stage: "failed", want: false},
		{stage: "transcribing", want: false},
		{stage: "", want: false},
	} {
		t.Run(test.stage, func(t *testing.T) {
			t.Parallel()
			item := &models.AudioTranscription{
				ProcessingStage: test.stage,
				ErrorMessage:    test.message,
			}
			if got := audioSourceRetryBlocked(item); got != test.want {
				t.Fatalf("audioSourceRetryBlocked(%q) = %t, want %t", test.stage, got, test.want)
			}
		})
	}
}
