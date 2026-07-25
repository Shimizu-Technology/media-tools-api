package worker

import (
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestAudioSummaryRecoveryPayloadPreservesRequestedLength(t *testing.T) {
	at := models.AudioTranscription{
		ID:            "audio-123",
		ContentType:   models.ContentMeeting,
		SummaryModel:  "quality-model",
		SummaryLength: "detailed",
	}

	payload := audioSummaryRecoveryPayload(at)

	if payload.Length != "detailed" {
		t.Fatalf("Length = %q, want detailed", payload.Length)
	}
	if payload.AudioID != at.ID {
		t.Fatalf("AudioID = %q, want %q", payload.AudioID, at.ID)
	}
}

func TestAudioSummaryRecoveryPayloadDefaultsLegacyRows(t *testing.T) {
	payload := audioSummaryRecoveryPayload(models.AudioTranscription{ID: "legacy-audio"})

	if payload.Length != "medium" {
		t.Fatalf("Length = %q, want medium", payload.Length)
	}
}
