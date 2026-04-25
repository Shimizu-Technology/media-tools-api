package handlers

import "testing"

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
