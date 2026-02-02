// extractor_test.go — Unit tests for YouTube URL parsing and VTT parsing.
//
// Go Pattern: Test files live alongside the code they test and end in _test.go.
// Go's testing package is built-in — no need for third-party frameworks like
// Jest or RSpec. Run tests with: go test ./...
//
// Test function names follow the pattern: TestFunctionName_Scenario
package transcript

import (
	"testing"
)

// TestParseYouTubeURL tests all supported YouTube URL formats.
//
// Go Pattern: Table-driven tests are the standard Go pattern for testing
// multiple inputs. Define a slice of test cases, then loop through them.
// This is cleaner than writing separate test functions for each case.
func TestParseYouTubeURL(t *testing.T) {
	// Define test cases as a slice of anonymous structs
	tests := []struct {
		name      string // Description of the test case
		input     string // Input to the function
		wantURL   string // Expected YouTube URL
		wantID    string // Expected video ID
		wantError bool   // Whether we expect an error
	}{
		// Standard YouTube URLs
		{
			name:    "standard youtube.com URL",
			input:   "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantID:  "dQw4w9WgXcQ",
		},
		{
			name:    "youtube.com without www",
			input:   "https://youtube.com/watch?v=dQw4w9WgXcQ",
			wantURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantID:  "dQw4w9WgXcQ",
		},
		{
			name:    "youtube.com with extra params",
			input:   "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf&index=2",
			wantURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantID:  "dQw4w9WgXcQ",
		},

		// Short URLs
		{
			name:    "youtu.be short URL",
			input:   "https://youtu.be/dQw4w9WgXcQ",
			wantURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantID:  "dQw4w9WgXcQ",
		},

		// Embed URLs
		{
			name:    "embed URL",
			input:   "https://www.youtube.com/embed/dQw4w9WgXcQ",
			wantURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantID:  "dQw4w9WgXcQ",
		},

		// Shorts URLs
		{
			name:    "shorts URL",
			input:   "https://www.youtube.com/shorts/dQw4w9WgXcQ",
			wantURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantID:  "dQw4w9WgXcQ",
		},

		// Plain video ID
		{
			name:    "plain video ID",
			input:   "dQw4w9WgXcQ",
			wantURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantID:  "dQw4w9WgXcQ",
		},
		{
			name:    "video ID with dashes and underscores",
			input:   "a-B_c1D2e3F",
			wantURL: "https://www.youtube.com/watch?v=a-B_c1D2e3F",
			wantID:  "a-B_c1D2e3F",
		},

		// Whitespace handling
		{
			name:    "URL with leading/trailing whitespace",
			input:   "  https://www.youtube.com/watch?v=dQw4w9WgXcQ  ",
			wantURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantID:  "dQw4w9WgXcQ",
		},

		// Error cases
		{
			name:      "empty string",
			input:     "",
			wantError: true,
		},
		{
			name:      "random URL",
			input:     "https://www.google.com",
			wantError: true,
		},
		{
			name:      "too short for video ID",
			input:     "abc",
			wantError: true,
		},
	}

	// Go Pattern: t.Run creates a sub-test for each case.
	// If one fails, the others still run. Output shows which case failed.
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotURL, gotID, err := ParseYouTubeURL(tt.input)

			if tt.wantError {
				if err == nil {
					t.Errorf("ParseYouTubeURL(%q) expected error, got URL=%q, ID=%q", tt.input, gotURL, gotID)
				}
				return
			}

			if err != nil {
				t.Errorf("ParseYouTubeURL(%q) unexpected error: %v", tt.input, err)
				return
			}

			if gotURL != tt.wantURL {
				t.Errorf("ParseYouTubeURL(%q) URL = %q, want %q", tt.input, gotURL, tt.wantURL)
			}
			if gotID != tt.wantID {
				t.Errorf("ParseYouTubeURL(%q) ID = %q, want %q", tt.input, gotID, tt.wantID)
			}
		})
	}
}

// TestParseVTT tests WebVTT subtitle parsing.
func TestParseVTT(t *testing.T) {
	tests := []struct {
		name string
		vtt  string
		want string
	}{
		{
			name: "basic VTT",
			vtt: `WEBVTT

00:00:01.000 --> 00:00:04.000
Hello, welcome to the video.

00:00:04.500 --> 00:00:08.000
Today we talk about Go.`,
			want: "Hello, welcome to the video. Today we talk about Go.",
		},
		{
			name: "VTT with duplicate lines",
			vtt: `WEBVTT

00:00:01.000 --> 00:00:04.000
Hello world

00:00:04.000 --> 00:00:06.000
Hello world

00:00:06.000 --> 00:00:08.000
Goodbye world`,
			want: "Hello world Goodbye world",
		},
		{
			name: "VTT with tags",
			vtt: `WEBVTT

00:00:01.000 --> 00:00:04.000
<c.colorCCCCCC>Hello</c> from <b>YouTube</b>`,
			want: "Hello from YouTube",
		},
		{
			name: "VTT with header metadata",
			vtt: `WEBVTT
Kind: captions
Language: en

00:00:01.000 --> 00:00:04.000
Test content`,
			want: "Test content",
		},
		{
			name: "empty VTT",
			vtt:  "WEBVTT",
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseVTT(tt.vtt)
			if got != tt.want {
				t.Errorf("parseVTT() = %q, want %q", got, tt.want)
			}
		})
	}
}

// TestCleanTranscript tests transcript text cleanup.
func TestCleanTranscript(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "removes music tags",
			input: "Hello [Music] world",
			want:  "Hello world",
		},
		{
			name:  "collapses whitespace",
			input: "Hello    world   again",
			want:  "Hello world again",
		},
		{
			name:  "trims edges",
			input: "  Hello world  ",
			want:  "Hello world",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := cleanTranscript(tt.input)
			if got != tt.want {
				t.Errorf("cleanTranscript(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

// TestCountWords tests word counting.
func TestCountWords(t *testing.T) {
	tests := []struct {
		input string
		want  int
	}{
		{"", 0},
		{"hello", 1},
		{"hello world", 2},
		{"the quick brown fox jumps", 5},
		{"  spaces  everywhere  ", 2},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := countWords(tt.input)
			if got != tt.want {
				t.Errorf("countWords(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}
