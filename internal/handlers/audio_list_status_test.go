package handlers

import "testing"

func TestIsSupportedAudioListStatus(t *testing.T) {
	t.Parallel()

	tests := []struct {
		status   string
		expected bool
	}{
		{status: "", expected: true},
		{status: "active", expected: true},
		{status: "pending", expected: true},
		{status: "processing", expected: true},
		{status: "completed", expected: true},
		{status: "failed", expected: true},
		{status: "all", expected: false},
		{status: "PROCESSING", expected: false},
	}

	for _, tt := range tests {
		t.Run(tt.status, func(t *testing.T) {
			t.Parallel()
			if got := isSupportedAudioListStatus(tt.status); got != tt.expected {
				t.Fatalf("isSupportedAudioListStatus(%q) = %v, want %v", tt.status, got, tt.expected)
			}
		})
	}
}
