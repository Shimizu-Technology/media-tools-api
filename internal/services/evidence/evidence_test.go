package evidence

import (
	"strings"
	"testing"
)

func TestChunkTextBoundsLegacyEvidenceWithoutInventingLocations(t *testing.T) {
	segments := ChunkText("one two three four five six", 10)
	if len(segments) < 2 {
		t.Fatalf("ChunkText() returned %d segments, want multiple bounded segments", len(segments))
	}
	for _, segment := range segments {
		if len(segment.Text) > 10 {
			t.Fatalf("segment %q has %d characters, want at most 10", segment.Text, len(segment.Text))
		}
		if segment.StartMS != nil || segment.EndMS != nil || segment.PageNumber != nil {
			t.Fatalf("legacy segment invented a source location: %#v", segment)
		}
	}
	joined := strings.TrimSpace(strings.Join([]string{segments[0].Text, segments[1].Text}, " "))
	if !strings.HasPrefix(joined, "one two three") {
		t.Fatalf("ChunkText() changed source order: %q", joined)
	}
}

func TestChunkTextKeepsSingleWordLargerThanSoftLimit(t *testing.T) {
	segments := ChunkText("extraordinary", 5)
	if len(segments) != 1 || segments[0].Text != "extraordinary" {
		t.Fatalf("ChunkText() = %#v, want the source word intact", segments)
	}
}
