// export.go handles transcript export in multiple formats (MTA-9).
//
// Supported formats:
//   - txt  — Plain text transcript
//   - md   — Markdown with metadata header
//   - srt  — SubRip subtitle format with timestamps
//   - json — Full JSON with all metadata
//
// Go Pattern: Each export format is its own function. This makes it easy
// to add new formats later — just add a case to the switch and a new
// formatter function. This is the "Strategy pattern" without the ceremony.
package handlers

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// ExportTranscript exports a transcript in the requested format.
// GET /api/v1/transcripts/:id/export?format=txt|md|srt|json
//
// Response headers are set for file download:
//   - Content-Type: appropriate MIME type
//   - Content-Disposition: attachment with filename
func (h *Handler) ExportTranscript(c *gin.Context) {
	id := c.Param("id")
	format := c.DefaultQuery("format", "txt")

	// Validate format before doing any database work
	validFormats := map[string]bool{"txt": true, "md": true, "srt": true, "json": true}
	if !validFormats[format] {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_format",
			Message: "Supported formats: txt, md, srt, json",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Get the transcript
	t, err := h.DB.GetTranscript(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Transcript not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	// Only export completed transcripts
	if t.Status != models.StatusCompleted {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_ready",
			Message: "Transcript is not completed (status: " + string(t.Status) + ")",
			Code:    http.StatusNotFound,
		})
		return
	}

	// Generate a clean filename from the title
	// Go Pattern: We sanitize the title for use in filenames. This prevents
	// issues with special characters in Content-Disposition headers.
	filename := sanitizeFilename(t.Title)
	if filename == "" {
		filename = t.YouTubeID
	}

	// Route to the appropriate formatter
	// Go Pattern: Switch on the format string — clean and extensible.
	switch format {
	case "txt":
		exportTXT(c, t, filename)
	case "md":
		exportMarkdown(c, t, filename)
	case "srt":
		exportSRT(c, t, filename)
	case "json":
		exportJSON(c, t, filename)
	}
}

// exportTXT returns the transcript as plain text.
func exportTXT(c *gin.Context, t *models.Transcript, filename string) {
	c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.txt"`, filename))
	c.Data(http.StatusOK, "text/plain; charset=utf-8", []byte(t.TranscriptText))
}

// exportMarkdown returns the transcript as Markdown with a metadata header.
// The header includes video title, channel, duration, URL, and word count.
func exportMarkdown(c *gin.Context, t *models.Transcript, filename string) {
	// Build a Markdown document with YAML-like frontmatter
	var sb strings.Builder

	sb.WriteString(fmt.Sprintf("# %s\n\n", t.Title))
	sb.WriteString("| Field | Value |\n")
	sb.WriteString("|-------|-------|\n")
	sb.WriteString(fmt.Sprintf("| Channel | %s |\n", t.ChannelName))
	sb.WriteString(fmt.Sprintf("| Duration | %s |\n", formatDuration(t.Duration)))
	sb.WriteString(fmt.Sprintf("| Words | %d |\n", t.WordCount))
	sb.WriteString(fmt.Sprintf("| Language | %s |\n", t.Language))
	sb.WriteString(fmt.Sprintf("| URL | %s |\n", t.YouTubeURL))
	sb.WriteString(fmt.Sprintf("| Extracted | %s |\n", t.CreatedAt.Format("2006-01-02 15:04:05 MST")))
	sb.WriteString("\n---\n\n")
	sb.WriteString("## Transcript\n\n")
	sb.WriteString(t.TranscriptText)
	sb.WriteString("\n")

	c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.md"`, filename))
	c.Data(http.StatusOK, "text/markdown; charset=utf-8", []byte(sb.String()))
}

// exportSRT returns the transcript in SubRip subtitle format.
//
// Since our transcripts don't have per-word timestamps (yt-dlp gives us
// the full text), we generate approximate timestamps based on word count
// and video duration. Each "cue" is roughly 10 words.
//
// Go Pattern: This is a good example of "make it work with what you have."
// Perfect timestamps would require parsing VTT cue data, but approximate
// timestamps are useful for subtitle overlays and reading along.
func exportSRT(c *gin.Context, t *models.Transcript, filename string) {
	var sb strings.Builder
	words := strings.Fields(t.TranscriptText)

	if len(words) == 0 {
		sb.WriteString("1\n00:00:00,000 --> 00:00:01,000\n(empty transcript)\n\n")
		c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.srt"`, filename))
		c.Data(http.StatusOK, "text/srt; charset=utf-8", []byte(sb.String()))
		return
	}

	// Calculate timing: distribute words evenly across the video duration
	wordsPerCue := 10 // ~10 words per subtitle cue (about 3-4 seconds of speech)
	totalDuration := float64(t.Duration)
	if totalDuration <= 0 {
		// Fallback: estimate ~150 words per minute (average speaking rate)
		totalDuration = float64(len(words)) / 150.0 * 60.0
	}

	secondsPerWord := totalDuration / float64(len(words))
	cueIndex := 1

	for i := 0; i < len(words); i += wordsPerCue {
		end := i + wordsPerCue
		if end > len(words) {
			end = len(words)
		}

		// Calculate start and end times for this cue
		startSec := float64(i) * secondsPerWord
		endSec := float64(end) * secondsPerWord

		// Clamp to video duration
		if endSec > totalDuration {
			endSec = totalDuration
		}

		cueText := strings.Join(words[i:end], " ")

		// SRT format: index, timestamp range, text, blank line
		sb.WriteString(fmt.Sprintf("%d\n", cueIndex))
		sb.WriteString(fmt.Sprintf("%s --> %s\n", formatSRTTime(startSec), formatSRTTime(endSec)))
		sb.WriteString(cueText)
		sb.WriteString("\n\n")

		cueIndex++
	}

	c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.srt"`, filename))
	c.Data(http.StatusOK, "text/srt; charset=utf-8", []byte(sb.String()))
}

// exportJSON returns the full transcript data as JSON.
// This includes all metadata — useful for programmatic consumption.
func exportJSON(c *gin.Context, t *models.Transcript, filename string) {
	// Build a clean export structure (we control what's included)
	exportData := map[string]interface{}{
		"id":              t.ID,
		"youtube_url":     t.YouTubeURL,
		"youtube_id":      t.YouTubeID,
		"title":           t.Title,
		"channel_name":    t.ChannelName,
		"duration":        t.Duration,
		"duration_human":  formatDuration(t.Duration),
		"language":        t.Language,
		"transcript_text": t.TranscriptText,
		"word_count":      t.WordCount,
		"reading_time":    fmt.Sprintf("%d min", int(math.Ceil(float64(t.WordCount)/200.0))),
		"status":          t.Status,
		"created_at":      t.CreatedAt,
		"updated_at":      t.UpdatedAt,
	}

	jsonBytes, err := json.MarshalIndent(exportData, "", "  ")
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "export_error",
			Message: "Failed to generate JSON export",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.json"`, filename))
	c.Data(http.StatusOK, "application/json; charset=utf-8", jsonBytes)
}

// --- Helper Functions ---

// formatSRTTime converts seconds to SRT timestamp format: HH:MM:SS,mmm
func formatSRTTime(seconds float64) string {
	h := int(seconds) / 3600
	m := (int(seconds) % 3600) / 60
	s := int(seconds) % 60
	ms := int((seconds - float64(int(seconds))) * 1000)
	return fmt.Sprintf("%02d:%02d:%02d,%03d", h, m, s, ms)
}

// formatDuration converts seconds to a human-readable duration string.
func formatDuration(seconds int) string {
	h := seconds / 3600
	m := (seconds % 3600) / 60
	s := seconds % 60
	if h > 0 {
		return fmt.Sprintf("%dh %dm %ds", h, m, s)
	}
	if m > 0 {
		return fmt.Sprintf("%dm %ds", m, s)
	}
	return fmt.Sprintf("%ds", s)
}

// sanitizeFilename removes characters that aren't safe for filenames.
// Go Pattern: Keep it simple — replace unsafe characters with hyphens
// and trim the result. We don't need a full filesystem-safe sanitizer
// since this is just for the Content-Disposition header.
func sanitizeFilename(name string) string {
	// Replace common unsafe characters
	replacer := strings.NewReplacer(
		"/", "-", "\\", "-", ":", "-", "*", "-",
		"?", "-", "\"", "-", "<", "-", ">", "-",
		"|", "-", "\n", " ", "\r", "",
	)
	name = replacer.Replace(name)

	// Collapse multiple hyphens/spaces
	for strings.Contains(name, "  ") {
		name = strings.ReplaceAll(name, "  ", " ")
	}
	for strings.Contains(name, "--") {
		name = strings.ReplaceAll(name, "--", "-")
	}

	name = strings.TrimSpace(name)

	// Limit length
	if len(name) > 100 {
		name = name[:100]
	}

	return name
}
