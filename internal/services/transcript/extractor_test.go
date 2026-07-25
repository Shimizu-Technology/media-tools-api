// extractor_test.go — Unit tests for YouTube URL parsing and VTT parsing.
//
// Go Pattern: Test files live alongside the code they test and end in _test.go.
// Go's testing package is built-in — no need for third-party frameworks like
// Jest or RSpec. Run tests with: go test ./...
//
// Test function names follow the pattern: TestFunctionName_Scenario
package transcript

import (
	"context"
	"strings"
	"testing"
)

// TestParseYouTubeURL tests all supported YouTube URL formats.
//
// Go Pattern: Table-driven tests are the standard Go pattern for testing
// multiple inputs. Define a slice of test cases, then loop through them.
// This is cleaner than writing separate test functions for each case.
func TestParseVideoURLDoesNotTrustPlatformNamesOnOtherHosts(t *testing.T) {
	tests := []string{
		"http://127.0.0.1/youtube.com/watch?v=dQw4w9WgXcQ",
		"http://127.0.0.1/vimeo.com/123456789",
	}

	for _, raw := range tests {
		t.Run(raw, func(t *testing.T) {
			parsed, err := ParseVideoURL(raw)
			if err != nil {
				t.Fatalf("ParseVideoURL(%q) unexpected error: %v", raw, err)
			}
			if parsed.Source != SourceOther {
				t.Fatalf("ParseVideoURL(%q) source = %q, want %q", raw, parsed.Source, SourceOther)
			}
		})
	}
}

func TestValidateExternalVideoURLBlocksUnsafeTargets(t *testing.T) {
	tests := []string{
		"http://localhost/video",
		"http://127.0.0.1/video",
		"http://10.0.0.5/video",
		"http://172.16.0.1/video",
		"http://192.168.1.10/video",
		"http://100.64.0.1/video",
		"http://100.127.255.254/video",
		"http://[::1]/video",
	}

	for _, raw := range tests {
		t.Run(raw, func(t *testing.T) {
			if err := ValidateExternalVideoURL(context.Background(), raw); err == nil {
				t.Fatalf("ValidateExternalVideoURL(%q) expected error, got nil", raw)
			}
		})
	}
}

func TestValidateExternalVideoURLAllowsPublicLiteralIP(t *testing.T) {
	if err := ValidateExternalVideoURL(context.Background(), "https://93.184.216.34/video"); err != nil {
		t.Fatalf("ValidateExternalVideoURL() unexpected error: %v", err)
	}
}

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

func TestParseVTTSegmentsPreservesSeekableTimingAndDeduplicatesRollingCaptions(t *testing.T) {
	vtt := `WEBVTT

00:00:01.250 --> 00:00:03.000
Welcome to the project

00:00:02.750 --> 00:00:05.500
Welcome to the project overview

01:02:03.400 --> 01:02:05.000
This starts after an hour`

	segments := parseVTTSegments(vtt)
	if len(segments) != 2 {
		t.Fatalf("parseVTTSegments() returned %d segments, want 2: %#v", len(segments), segments)
	}
	if segments[0].StartMS != 1_250 || segments[0].EndMS != 5_500 {
		t.Fatalf("first timing = %d-%d, want 1250-5500", segments[0].StartMS, segments[0].EndMS)
	}
	if segments[0].Text != "Welcome to the project overview" {
		t.Fatalf("first text = %q, want rolling caption text without duplicate prefix", segments[0].Text)
	}
	if segments[1].StartMS != 3_723_400 || segments[1].EndMS != 3_725_000 {
		t.Fatalf("hour timing = %d-%d, want 3723400-3725000", segments[1].StartMS, segments[1].EndMS)
	}
}

func TestParseVTTSegmentsSupportsMinuteOnlyTimestampsAndCueSettings(t *testing.T) {
	vtt := `WEBVTT

00:59.900 --> 01:01.250 align:start position:0%
Before and after the minute`
	segments := parseVTTSegments(vtt)
	if len(segments) != 1 {
		t.Fatalf("parseVTTSegments() returned %d segments, want 1", len(segments))
	}
	if segments[0].StartMS != 59_900 || segments[0].EndMS != 61_250 {
		t.Fatalf("timing = %d-%d, want 59900-61250", segments[0].StartMS, segments[0].EndMS)
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

func TestParseVideoURL(t *testing.T) {
	tests := []struct {
		name       string
		url        string
		wantSource VideoSource
		wantID     string
		wantURL    string
		wantErr    bool
	}{
		// YouTube URLs (should still work)
		{
			name:       "standard YouTube",
			url:        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantSource: SourceYouTube,
			wantID:     "dQw4w9WgXcQ",
			wantURL:    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},
		{
			name:       "YouTube short URL",
			url:        "https://youtu.be/dQw4w9WgXcQ",
			wantSource: SourceYouTube,
			wantID:     "dQw4w9WgXcQ",
			wantURL:    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},
		// Vimeo URLs
		{
			name:       "standard Vimeo",
			url:        "https://vimeo.com/123456789",
			wantSource: SourceVimeo,
			wantID:     "123456789",
			wantURL:    "https://vimeo.com/123456789",
		},
		{
			name:       "Vimeo /video/ path",
			url:        "https://vimeo.com/video/123456789",
			wantSource: SourceVimeo,
			wantID:     "123456789",
			wantURL:    "https://vimeo.com/video/123456789",
		},
		{
			name:       "Vimeo player embed",
			url:        "https://player.vimeo.com/video/123456789",
			wantSource: SourceVimeo,
			wantID:     "123456789",
			wantURL:    "https://player.vimeo.com/video/123456789",
		},
		{
			name:       "Vimeo channel video",
			url:        "https://vimeo.com/channels/staffpicks/123456789",
			wantSource: SourceVimeo,
			wantID:     "123456789",
			wantURL:    "https://vimeo.com/channels/staffpicks/123456789",
		},
		{
			name:       "Vimeo private share link preserves hash",
			url:        "https://vimeo.com/123456789/abc123def456",
			wantSource: SourceVimeo,
			wantID:     "123456789",
			wantURL:    "https://vimeo.com/123456789/abc123def456",
		},
		// Generic URLs (yt-dlp supported)
		{
			name:       "Dailymotion",
			url:        "https://www.dailymotion.com/video/x7zzrmj",
			wantSource: SourceOther,
			wantID:     "www.dailymotion.com/video/x7zzrmj",
			wantURL:    "https://www.dailymotion.com/video/x7zzrmj",
		},
		{
			name:       "generic https URL",
			url:        "https://example.com/video/12345",
			wantSource: SourceOther,
			wantID:     "example.com/video/12345",
			wantURL:    "https://example.com/video/12345",
		},
		{
			name:       "strips query params from other URLs",
			url:        "https://example.com/video/12345?ref=share&t=30",
			wantSource: SourceOther,
			wantID:     "example.com/video/12345",
			wantURL:    "https://example.com/video/12345?ref=share&t=30",
		},
		// Invalid inputs
		{
			name:    "empty string",
			url:     "",
			wantErr: true,
		},
		{
			name:    "not a URL",
			url:     "just some text",
			wantErr: true,
		},
		{
			name:       "http URL (also accepted by yt-dlp)",
			url:        "http://example.com/video",
			wantSource: SourceOther,
			wantID:     "example.com/video",
			wantURL:    "http://example.com/video",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := ParseVideoURL(tt.url)
			if tt.wantErr {
				if err == nil {
					t.Errorf("ParseVideoURL(%q) expected error, got nil", tt.url)
				}
				return
			}
			if err != nil {
				t.Errorf("ParseVideoURL(%q) unexpected error: %v", tt.url, err)
				return
			}
			if result.Source != tt.wantSource {
				t.Errorf("ParseVideoURL(%q) source = %v, want %v", tt.url, result.Source, tt.wantSource)
			}
			if result.VideoID != tt.wantID {
				t.Errorf("ParseVideoURL(%q) videoID = %q, want %q", tt.url, result.VideoID, tt.wantID)
			}
			if result.URL != tt.wantURL {
				t.Errorf("ParseVideoURL(%q) url = %q, want %q", tt.url, result.URL, tt.wantURL)
			}
		})
	}
}

func TestBuildBaseArgs_IncludesCookiesAndProxy(t *testing.T) {
	e := NewExtractor("/usr/bin/yt-dlp")
	e.SetCookiesFile("/tmp/vimeo-cookies.txt")
	e.SetProxy("http://user:pass@proxy.example.com:8080")

	args := e.buildBaseArgs()
	joined := strings.Join(args, " ")

	if !strings.Contains(joined, "--cookies /tmp/vimeo-cookies.txt") {
		t.Fatalf("expected --cookies arg, got: %v", args)
	}
	if !strings.Contains(joined, "--proxy http://user:pass@proxy.example.com:8080") {
		t.Fatalf("expected --proxy arg, got: %v", args)
	}
}
