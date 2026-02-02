// Package transcript handles YouTube transcript extraction using yt-dlp.
//
// Go Pattern: This package defines a Service with an interface, making it
// easy to test (you can mock the interface) and swap implementations.
// In Go, interfaces are satisfied implicitly — you don't need to declare
// "implements". If a struct has the right methods, it satisfies the interface.
package transcript

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// Extractor defines the interface for transcript extraction.
// Go Pattern: Define interfaces where they're USED, not where they're
// implemented. This is opposite to Java/C# — and it's one of Go's
// most powerful design patterns. Small interfaces (1-3 methods) are preferred.
type Extractor interface {
	Extract(ctx context.Context, videoID string) (*Result, error)
}

// Result holds the extracted transcript and video metadata.
type Result struct {
	VideoID      string
	Title        string
	ChannelName  string
	Duration     int    // seconds
	Language     string
	Transcript   string
	WordCount    int
}

// YtDlpExtractor uses the yt-dlp CLI tool to extract transcripts.
// Go Pattern: This struct implements the Extractor interface (implicitly).
type YtDlpExtractor struct {
	ytDlpPath string
}

// NewExtractor creates a new yt-dlp based extractor.
// Go Pattern: Constructor functions are named New<Type> or New<Package>.
func NewExtractor(ytDlpPath string) *YtDlpExtractor {
	return &YtDlpExtractor{ytDlpPath: ytDlpPath}
}

// ytDlpMetadata represents the JSON output from yt-dlp --dump-json.
type ytDlpMetadata struct {
	ID          string  `json:"id"`
	Title       string  `json:"title"`
	Channel     string  `json:"channel"`
	Duration    float64 `json:"duration"`
	Subtitles   map[string][]subtitle `json:"subtitles"`
	AutoCaptions map[string][]subtitle `json:"automatic_captions"`
}

type subtitle struct {
	URL  string `json:"url"`
	Ext  string `json:"ext"`
}

// Extract downloads the transcript for a YouTube video.
// It first tries manual subtitles, then falls back to auto-generated captions.
func (e *YtDlpExtractor) Extract(ctx context.Context, videoID string) (*Result, error) {
	url := fmt.Sprintf("https://www.youtube.com/watch?v=%s", videoID)

	// Step 1: Get video metadata (title, channel, duration, available subtitles)
	log.Printf("🎬 Extracting metadata for video: %s", videoID)
	metadata, err := e.getMetadata(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("failed to get video metadata: %w", err)
	}

	// Step 2: Extract subtitle text
	log.Printf("📝 Extracting transcript for: %s", metadata.Title)
	transcript, lang, err := e.getTranscript(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("no transcript available: %w", err)
	}

	// Step 3: Clean up the transcript text
	cleaned := cleanTranscript(transcript)
	wordCount := countWords(cleaned)

	return &Result{
		VideoID:     videoID,
		Title:       metadata.Title,
		ChannelName: metadata.Channel,
		Duration:    int(metadata.Duration),
		Language:    lang,
		Transcript:  cleaned,
		WordCount:   wordCount,
	}, nil
}

// getMetadata fetches video info using yt-dlp --dump-json.
func (e *YtDlpExtractor) getMetadata(ctx context.Context, url string) (*ytDlpMetadata, error) {
	// exec.CommandContext cancels the command if the context is cancelled.
	// This prevents runaway processes — important for a web server!
	cmd := exec.CommandContext(ctx, e.ytDlpPath,
		"--dump-json",        // Output video info as JSON
		"--no-download",      // Don't download the video itself
		"--no-warnings",      // Suppress warning messages
		url,
	)

	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("yt-dlp metadata failed: %w", err)
	}

	var meta ytDlpMetadata
	if err := json.Unmarshal(output, &meta); err != nil {
		return nil, fmt.Errorf("failed to parse yt-dlp output: %w", err)
	}

	return &meta, nil
}

// getTranscript extracts the subtitle text using yt-dlp.
// Returns the transcript text and the language code.
func (e *YtDlpExtractor) getTranscript(ctx context.Context, url string) (string, string, error) {
	// Create a temp directory for subtitle files
	// Go Pattern: We use a context with timeout to prevent hanging.
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel() // Always call cancel to release resources

	// Try manual subtitles first (higher quality), then auto-generated
	for _, subType := range []string{"--write-subs", "--write-auto-subs"} {
		cmd := exec.CommandContext(ctx, e.ytDlpPath,
			"--skip-download",        // Don't download video
			subType,                  // Which subtitle type to get
			"--sub-langs", "en.*,en", // Prefer English
			"--sub-format", "vtt",    // WebVTT format (easiest to parse)
			"--output", "/tmp/mta-%(id)s",
			"--no-warnings",
			url,
		)

		output, err := cmd.CombinedOutput()
		if err != nil {
			log.Printf("⚠️  Subtitle extraction (%s) failed: %s", subType, string(output))
			continue
		}

		// Find the generated subtitle file
		findCmd := exec.CommandContext(ctx, "find", "/tmp", "-name", "mta-*.vtt", "-newer", "/tmp", "-type", "f")
		files, err := findCmd.Output()

		// Alternative: use glob pattern
		globCmd := exec.CommandContext(ctx, "bash", "-c", "ls -t /tmp/mta-*.vtt 2>/dev/null | head -1")
		fileOutput, err := globCmd.Output()
		if err != nil || len(strings.TrimSpace(string(fileOutput))) == 0 {
			continue
		}

		subtitleFile := strings.TrimSpace(string(fileOutput))
		_ = files // suppress unused warning

		// Read the subtitle file
		catCmd := exec.CommandContext(ctx, "cat", subtitleFile)
		content, err := catCmd.Output()
		if err != nil {
			continue
		}

		// Clean up temp file
		exec.CommandContext(ctx, "rm", "-f", subtitleFile).Run()

		// Detect language from filename (e.g., mta-abc123.en.vtt)
		lang := "en"
		parts := strings.Split(subtitleFile, ".")
		if len(parts) >= 3 {
			lang = parts[len(parts)-2] // Get the language code part
		}

		text := parseVTT(string(content))
		if text != "" {
			return text, lang, nil
		}
	}

	return "", "", fmt.Errorf("no subtitles available for this video")
}

// parseVTT extracts plain text from a WebVTT subtitle file.
// WebVTT format:
//
//	WEBVTT
//	00:00:01.000 --> 00:00:04.000
//	Hello, welcome to the video.
//
//	00:00:04.500 --> 00:00:08.000
//	Today we're going to talk about...
func parseVTT(vtt string) string {
	lines := strings.Split(vtt, "\n")
	var textLines []string
	seen := make(map[string]bool) // Deduplicate repeated lines

	// Regex to match timestamp lines like "00:00:01.000 --> 00:00:04.000"
	timestampRegex := regexp.MustCompile(`^\d{2}:\d{2}:\d{2}`)
	// Regex to match VTT tags like <c> and position info
	tagRegex := regexp.MustCompile(`<[^>]+>`)

	for _, line := range lines {
		line = strings.TrimSpace(line)

		// Skip empty lines, WEBVTT header, timestamp lines, and NOTE lines
		if line == "" || line == "WEBVTT" || strings.HasPrefix(line, "Kind:") ||
			strings.HasPrefix(line, "Language:") || strings.HasPrefix(line, "NOTE") ||
			timestampRegex.MatchString(line) {
			continue
		}

		// Skip numeric cue identifiers
		if regexp.MustCompile(`^\d+$`).MatchString(line) {
			continue
		}

		// Remove VTT formatting tags
		line = tagRegex.ReplaceAllString(line, "")
		line = strings.TrimSpace(line)

		if line != "" && !seen[line] {
			seen[line] = true
			textLines = append(textLines, line)
		}
	}

	return strings.Join(textLines, " ")
}

// cleanTranscript normalizes whitespace and cleans up common transcript artifacts.
func cleanTranscript(text string) string {
	// Replace multiple spaces with single space
	spaceRegex := regexp.MustCompile(`\s+`)
	text = spaceRegex.ReplaceAllString(text, " ")

	// Remove common artifacts
	text = strings.ReplaceAll(text, "[Music]", "")
	text = strings.ReplaceAll(text, "[Applause]", "")
	text = strings.ReplaceAll(text, "[Laughter]", "")

	return strings.TrimSpace(text)
}

// countWords counts the number of words in a text string.
func countWords(text string) int {
	if text == "" {
		return 0
	}
	return len(strings.Fields(text)) // Fields splits on any whitespace
}

// ParseYouTubeURL extracts the video ID from various YouTube URL formats.
// Supports:
//   - https://www.youtube.com/watch?v=VIDEO_ID
//   - https://youtu.be/VIDEO_ID
//   - https://youtube.com/watch?v=VIDEO_ID&list=...
//   - Just the video ID itself (11 characters)
func ParseYouTubeURL(input string) (string, string, error) {
	input = strings.TrimSpace(input)

	// If it looks like a plain video ID (11 alphanumeric chars + - and _)
	videoIDRegex := regexp.MustCompile(`^[a-zA-Z0-9_-]{11}$`)
	if videoIDRegex.MatchString(input) {
		return fmt.Sprintf("https://www.youtube.com/watch?v=%s", input), input, nil
	}

	// Try to extract video ID from URL
	patterns := []*regexp.Regexp{
		regexp.MustCompile(`(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|youtube\.com/v/)([a-zA-Z0-9_-]{11})`),
		regexp.MustCompile(`(?:youtube\.com/shorts/)([a-zA-Z0-9_-]{11})`),
	}

	for _, pattern := range patterns {
		matches := pattern.FindStringSubmatch(input)
		if len(matches) >= 2 {
			videoID := matches[1]
			return fmt.Sprintf("https://www.youtube.com/watch?v=%s", videoID), videoID, nil
		}
	}

	return "", "", fmt.Errorf("invalid YouTube URL or video ID: %s", input)
}
