package handlers

import (
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

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
