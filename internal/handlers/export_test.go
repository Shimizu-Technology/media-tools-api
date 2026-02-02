// export_test.go contains tests for the export format handlers (MTA-9).
//
// Go Pattern: Table-driven tests are the standard Go testing pattern.
// You define a slice of test cases (each with a name, inputs, and expected
// outputs), then loop through them. This makes it easy to add new cases
// and keeps the test logic DRY.
package handlers

import (
	"strings"
	"testing"
)

// TestFormatSRTTime verifies the SRT timestamp formatting.
// SRT format requires: HH:MM:SS,mmm (note: comma, not period)
func TestFormatSRTTime(t *testing.T) {
	// Go Pattern: Table-driven tests — each case is a struct with inputs
	// and expected outputs. The test runner loops through them all.
	tests := []struct {
		name     string
		seconds  float64
		expected string
	}{
		{
			name:     "zero seconds",
			seconds:  0,
			expected: "00:00:00,000",
		},
		{
			name:     "fractional seconds",
			seconds:  1.5,
			expected: "00:00:01,500",
		},
		{
			name:     "one minute",
			seconds:  60,
			expected: "00:01:00,000",
		},
		{
			name:     "one hour",
			seconds:  3600,
			expected: "01:00:00,000",
		},
		{
			name:     "complex time",
			seconds:  3723.456,
			expected: "01:02:03,456",
		},
		{
			name:     "just under a minute",
			seconds:  59.999,
			expected: "00:00:59,999",
		},
	}

	for _, tt := range tests {
		// Go Pattern: t.Run creates a sub-test with its own name.
		// This makes test output clearer: "TestFormatSRTTime/one_minute"
		t.Run(tt.name, func(t *testing.T) {
			result := formatSRTTime(tt.seconds)
			if result != tt.expected {
				t.Errorf("formatSRTTime(%f) = %q, want %q", tt.seconds, result, tt.expected)
			}
		})
	}
}

// TestFormatDuration verifies human-readable duration formatting.
func TestFormatDuration(t *testing.T) {
	tests := []struct {
		name     string
		seconds  int
		expected string
	}{
		{"zero", 0, "0s"},
		{"seconds only", 45, "45s"},
		{"minutes and seconds", 125, "2m 5s"},
		{"hours minutes seconds", 3723, "1h 2m 3s"},
		{"exact hour", 3600, "1h 0m 0s"},
		{"exact minute", 60, "1m 0s"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := formatDuration(tt.seconds)
			if result != tt.expected {
				t.Errorf("formatDuration(%d) = %q, want %q", tt.seconds, result, tt.expected)
			}
		})
	}
}

// TestSanitizeFilename verifies filename sanitization.
func TestSanitizeFilename(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "clean filename",
			input:    "My Video Title",
			expected: "My Video Title",
		},
		{
			name:     "slashes and colons",
			input:    "Part 1/2: The Beginning",
			expected: "Part 1-2- The Beginning",
		},
		{
			name:     "special characters",
			input:    "What is Go? <A Guide>",
			expected: "What is Go- -A Guide-",
		},
		{
			name:     "empty string",
			input:    "",
			expected: "",
		},
		{
			name:     "long title gets truncated",
			input:    strings.Repeat("a", 200),
			expected: strings.Repeat("a", 100),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := sanitizeFilename(tt.input)
			if result != tt.expected {
				t.Errorf("sanitizeFilename(%q) = %q, want %q", tt.input, result, tt.expected)
			}
		})
	}
}
