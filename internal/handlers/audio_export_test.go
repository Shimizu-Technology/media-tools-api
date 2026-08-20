package handlers

import (
	"strings"
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestAudioTranscriptText(t *testing.T) {
	tests := []struct {
		name   string
		source string
		item   models.AudioTranscription
		want   string
	}{
		{
			name:   "readable defaults to completed formatted transcript",
			source: "readable",
			item: models.AudioTranscription{
				TranscriptText:      "hello world",
				FormattedTranscript: "Hello, world.",
				FormattingStatus:    "completed",
			},
			want: "Hello, world.",
		},
		{
			name:   "original always remains verbatim",
			source: "original",
			item: models.AudioTranscription{
				TranscriptText:      "hello world",
				FormattedTranscript: "Hello, world.",
				FormattingStatus:    "completed",
			},
			want: "hello world",
		},
		{
			name:   "pending formatting falls back to original",
			source: "readable",
			item: models.AudioTranscription{
				TranscriptText:      "hello world",
				FormattedTranscript: "stale value",
				FormattingStatus:    "pending",
			},
			want: "hello world",
		},
		{
			name:   "blank formatted result falls back to original",
			source: "readable",
			item: models.AudioTranscription{
				TranscriptText:      "hello world",
				FormattedTranscript: "   ",
				FormattingStatus:    "completed",
			},
			want: "hello world",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := audioTranscriptText(&tt.item, tt.source); got != tt.want {
				t.Fatalf("audioTranscriptText() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestMarkdownExportUsesReadableTranscriptByDefault(t *testing.T) {
	item := &models.AudioTranscription{
		OriginalName:        "meeting.m4a",
		TranscriptText:      "hello world",
		FormattedTranscript: "Hello, world.",
		FormattingStatus:    "completed",
	}

	readable := buildMarkdownExport(item)
	if !strings.Contains(readable, "Hello, world.") {
		t.Fatalf("default markdown export did not contain readable transcript: %q", readable)
	}

	original := buildMarkdownExportWithSource(item, "original")
	if !strings.Contains(original, "hello world") || strings.Contains(original, "Hello, world.") {
		t.Fatalf("original markdown export did not preserve the verbatim transcript: %q", original)
	}
}
