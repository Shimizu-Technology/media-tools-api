package handlers

import (
	"strings"
	"testing"

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
