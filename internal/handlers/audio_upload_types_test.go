package handlers

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// TestAudioUploadCompletionRetentionSupportsBackgroundDelivery verifies that
// completion sessions outlive suspended background transfers.
func TestAudioUploadCompletionRetentionSupportsBackgroundDelivery(t *testing.T) {
	t.Parallel()
	if audioUploadCompletionRetention < 24*time.Hour {
		t.Fatalf(
			"audio upload completion retention = %s, want at least 24h for background delivery",
			audioUploadCompletionRetention,
		)
	}
}

func TestIsSupportedTranscriptionUploadExt(t *testing.T) {
	tests := []struct {
		ext      string
		expected bool
	}{
		{ext: ".mp3", expected: true},
		{ext: ".m4a", expected: true},
		{ext: ".mp4", expected: true},
		{ext: ".webm", expected: true},
		{ext: ".MP4", expected: true},
		{ext: ".mov", expected: false},
		{ext: ".txt", expected: false},
	}

	for _, tt := range tests {
		if got := isSupportedTranscriptionUploadExt(tt.ext); got != tt.expected {
			t.Fatalf("isSupportedTranscriptionUploadExt(%q) = %v, want %v", tt.ext, got, tt.expected)
		}
	}
}

func TestParseAudioContentType(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		value    string
		expected models.AudioContentType
		valid    bool
	}{
		{name: "defaults to general", value: "", expected: models.ContentGeneral, valid: true},
		{name: "trims a supported value", value: " meeting ", expected: models.ContentMeeting, valid: true},
		{name: "accepts voice memo", value: "voice_memo", expected: models.ContentVoiceMemo, valid: true},
		{name: "rejects MIME type", value: "audio/mp4", expected: models.AudioContentType("audio/mp4"), valid: false},
		{name: "rejects unknown value", value: "podcast", expected: models.AudioContentType("podcast"), valid: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, valid := parseAudioContentType(tt.value)
			if got != tt.expected || valid != tt.valid {
				t.Fatalf("parseAudioContentType(%q) = (%q, %v), want (%q, %v)", tt.value, got, valid, tt.expected, tt.valid)
			}
		})
	}
}

func TestWriteCompletedAudioUploadResponseReplaysAcceptedTranscription(t *testing.T) {
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	existing := &models.AudioTranscription{ID: "audio-123", Status: "pending"}

	writeCompletedAudioUploadResponse(context, existing, nil)

	if recorder.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusAccepted)
	}
	var response models.AudioTranscription
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.ID != existing.ID {
		t.Fatalf("response id = %q, want %q", response.ID, existing.ID)
	}
}

func TestWriteCompletedAudioUploadResponseConflictsWithoutTranscription(t *testing.T) {
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)

	writeCompletedAudioUploadResponse(context, nil, errors.New("not found"))

	if recorder.Code != http.StatusConflict {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusConflict)
	}
	var response models.ErrorResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Error != "upload_already_completed" {
		t.Fatalf("error = %q, want upload_already_completed", response.Error)
	}
}
