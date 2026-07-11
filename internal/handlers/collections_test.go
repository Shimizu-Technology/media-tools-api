package handlers

import (
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
)

func TestBuildCollectionContextBalancesItems(t *testing.T) {
	contents := []database.CollectionItemContent{
		{ItemType: "transcript", Title: "First", Text: strings.Repeat("a", 100_000)},
		{ItemType: "audio", Title: "Second", Text: "SECOND-ITEM-CONTENT"},
		{ItemType: "pdf", Title: "Third", Text: "THIRD-ITEM-CONTENT"},
	}
	got := buildCollectionContext(contents, 1000)
	if len(got) > 1000 {
		t.Fatalf("context length = %d, want <= 1000", len(got))
	}
	for _, want := range []string{"First", "SECOND-ITEM-CONTENT", "THIRD-ITEM-CONTENT"} {
		if !strings.Contains(got, want) {
			t.Fatalf("context omitted %q", want)
		}
	}
}

func TestBuildCollectionContextPreservesUTF8(t *testing.T) {
	contents := []database.CollectionItemContent{
		{ItemType: "pdf", Title: "日本語", Text: strings.Repeat("要約🎙️", 100)},
		{ItemType: "audio", Title: "Español", Text: strings.Repeat("información ", 100)},
	}
	got := buildCollectionContext(contents, 257)
	if !utf8.ValidString(got) {
		t.Fatal("collection context contains invalid UTF-8")
	}
	if len(got) > 257 {
		t.Fatalf("context length = %d, want <= 257", len(got))
	}
}
