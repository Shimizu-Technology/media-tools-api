// Package evidence contains format-neutral helpers for turning stored source
// passages into bounded AI context.
package evidence

import (
	"strings"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
)

// ChunkText creates untimed evidence for legacy records that predate segment
// persistence. It never fabricates timestamps.
func ChunkText(text string, maxChars int) []models.MediaSegment {
	if maxChars <= 0 {
		maxChars = 1_200
	}
	words := strings.Fields(text)
	if len(words) == 0 {
		return nil
	}
	segments := make([]models.MediaSegment, 0, len(text)/maxChars+1)
	var builder strings.Builder
	flush := func() {
		value := strings.TrimSpace(builder.String())
		if value != "" {
			segments = append(segments, models.MediaSegment{Text: value})
		}
		builder.Reset()
	}
	for _, word := range words {
		added := len(word)
		if builder.Len() > 0 {
			added++
		}
		if builder.Len() > 0 && builder.Len()+added > maxChars {
			flush()
		}
		if builder.Len() > 0 {
			builder.WriteByte(' ')
		}
		builder.WriteString(word)
	}
	flush()
	return segments
}

func ToSummarySegments(segments []models.MediaSegment, itemTitle string) []summary.EvidenceSegment {
	result := make([]summary.EvidenceSegment, 0, len(segments))
	for _, segment := range segments {
		result = append(result, summary.EvidenceSegment{
			ID:         segment.ID,
			ItemType:   segment.ItemType,
			ItemID:     segment.ItemID,
			ItemTitle:  itemTitle,
			Ordinal:    segment.Ordinal,
			StartMS:    segment.StartMS,
			EndMS:      segment.EndMS,
			PageNumber: segment.PageNumber,
			Text:       segment.Text,
		})
	}
	return result
}
