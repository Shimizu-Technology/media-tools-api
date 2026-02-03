// Package transcript handles YouTube transcript extraction using yt-dlp.
//
// Go Pattern: This package defines a Service with an interface, making it
// easy to test (you can mock the interface) and swap implementations.
// In Go, interfaces are satisfied implicitly — you don't need to declare
// "implements". If a struct has the right methods, it satisfies the interface.
package transcript

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
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

// WhisperResult holds the output from a Whisper API call.
type WhisperResult struct {
	Text     string
	Language string
	Duration float64
}

// WhisperTranscriber is an interface for audio transcription (used as fallback).
// This allows the transcript package to use Whisper without importing the audio package.
// The TranscribeForYouTube method is specifically for YouTube fallback and returns our WhisperResult.
type WhisperTranscriber interface {
	TranscribeForYouTube(ctx context.Context, audioData io.Reader, filename string) (*WhisperResult, error)
	IsConfigured() bool
}

// YtDlpExtractor uses the yt-dlp CLI tool to extract transcripts.
// Go Pattern: This struct implements the Extractor interface (implicitly).
type YtDlpExtractor struct {
	ytDlpPath  string
	whisper    WhisperTranscriber // Optional: fallback to Whisper if subtitles fail
}

// NewExtractor creates a new yt-dlp based extractor.
// Go Pattern: Constructor functions are named New<Type> or New<Package>.
func NewExtractor(ytDlpPath string) *YtDlpExtractor {
	return &YtDlpExtractor{ytDlpPath: ytDlpPath}
}

// SetWhisperFallback enables Whisper-based transcription as a fallback
// when subtitle extraction fails (e.g., due to YouTube bot detection).
func (e *YtDlpExtractor) SetWhisperFallback(w WhisperTranscriber) {
	e.whisper = w
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
// It first tries manual subtitles, then auto-generated captions.
// If both fail and Whisper is configured, it downloads audio and transcribes with Whisper.
func (e *YtDlpExtractor) Extract(ctx context.Context, videoID string) (*Result, error) {
	url := fmt.Sprintf("https://www.youtube.com/watch?v=%s", videoID)

	// Step 1: Get video metadata (title, channel, duration, available subtitles)
	log.Printf("🎬 Extracting metadata for video: %s", videoID)
	metadata, metadataErr := e.getMetadata(ctx, url)

	// Step 2: Try subtitle extraction first
	if metadataErr == nil {
		log.Printf("📝 Extracting transcript for: %s", metadata.Title)
		transcript, lang, err := e.getTranscript(ctx, url)
		if err == nil {
			// Success! Clean up and return
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
		log.Printf("⚠️  Subtitle extraction failed: %v", err)
	} else {
		log.Printf("⚠️  Metadata extraction failed: %v", metadataErr)
	}

	// Step 3: Fallback to Whisper if configured
	if e.whisper != nil && e.whisper.IsConfigured() {
		log.Printf("🎤 Falling back to Whisper transcription for video: %s", videoID)
		return e.extractWithWhisper(ctx, url, videoID, metadata)
	}

	// No Whisper fallback available
	if metadataErr != nil {
		return nil, fmt.Errorf("failed to get video metadata: %w", metadataErr)
	}
	return nil, fmt.Errorf("no transcript available and Whisper fallback not configured")
}

// extractWithWhisper downloads audio from YouTube and transcribes with Whisper.
func (e *YtDlpExtractor) extractWithWhisper(ctx context.Context, url, videoID string, metadata *ytDlpMetadata) (*Result, error) {
	// Create temp directory for audio
	tmpDir, err := os.MkdirTemp("", "mta-audio-*")
	if err != nil {
		return nil, fmt.Errorf("failed to create temp directory: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	audioPath := filepath.Join(tmpDir, "audio.mp3")

	// Download audio using yt-dlp
	log.Printf("📥 Downloading audio for Whisper transcription...")
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	cmd := exec.CommandContext(ctx, e.ytDlpPath,
		"--js-runtimes", "node", // Required for YouTube extraction
		"--extractor-args", "youtube:player_client=tv", // Use TV client to avoid PO token requirement
		"--extract-audio",
		"--audio-format", "mp3",
		"--audio-quality", "0",
		"--output", audioPath,
		"--no-playlist",
		"--quiet",
		url,
	)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("failed to download audio: %s - %v", string(output), err)
	}

	// Check if audio file was created
	if _, err := os.Stat(audioPath); os.IsNotExist(err) {
		// yt-dlp might have added extension, check for any audio file
		matches, _ := filepath.Glob(filepath.Join(tmpDir, "audio.*"))
		if len(matches) == 0 {
			return nil, fmt.Errorf("no audio file found after download")
		}
		audioPath = matches[0]
	}

	log.Printf("✅ Audio downloaded: %s", audioPath)

	// Open audio file for Whisper
	audioFile, err := os.Open(audioPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open audio file: %w", err)
	}
	defer audioFile.Close()

	// Transcribe with Whisper
	log.Printf("🎤 Transcribing with Whisper...")
	result, err := e.whisper.TranscribeForYouTube(ctx, audioFile, "audio.mp3")
	if err != nil {
		return nil, fmt.Errorf("Whisper transcription failed: %w", err)
	}

	log.Printf("✅ Whisper transcription complete: %d chars", len(result.Text))

	// Build result
	title := videoID
	channel := ""
	duration := int(result.Duration)

	if metadata != nil {
		title = metadata.Title
		channel = metadata.Channel
		if metadata.Duration > 0 {
			duration = int(metadata.Duration)
		}
	}

	cleaned := cleanTranscript(result.Text)
	wordCount := countWords(cleaned)

	return &Result{
		VideoID:     videoID,
		Title:       title,
		ChannelName: channel,
		Duration:    duration,
		Language:    result.Language,
		Transcript:  cleaned,
		WordCount:   wordCount,
	}, nil
}

// getMetadata fetches video info using yt-dlp --dump-json.
func (e *YtDlpExtractor) getMetadata(ctx context.Context, url string) (*ytDlpMetadata, error) {
	// exec.CommandContext cancels the command if the context is cancelled.
	// This prevents runaway processes — important for a web server!
	cmd := exec.CommandContext(ctx, e.ytDlpPath,
		"--js-runtimes", "node", // Required for YouTube extraction
		"--extractor-args", "youtube:player_client=tv", // Use TV client to avoid PO token requirement
		"--dump-json",             // Output video info as JSON
		"--no-download",           // Don't download the video itself
		"--no-warnings",           // Suppress warning messages
		url,
	)

	// Go Pattern: CombinedOutput() captures both stdout and stderr.
	// cmd.Output() only captures stdout — if yt-dlp fails, we'd miss
	// the error message. We separate them manually for better handling.
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err != nil {
		errMsg := strings.TrimSpace(stderr.String())
		if errMsg == "" {
			errMsg = err.Error()
		}
		return nil, fmt.Errorf("yt-dlp metadata failed: %s", errMsg)
	}

	output := stdout.Bytes()

	var meta ytDlpMetadata
	if err := json.Unmarshal(output, &meta); err != nil {
		return nil, fmt.Errorf("failed to parse yt-dlp output: %w", err)
	}

	return &meta, nil
}

// getTranscript extracts the subtitle text using yt-dlp.
// Returns the transcript text and the language code.
func (e *YtDlpExtractor) getTranscript(ctx context.Context, url string) (string, string, error) {
	// Go Pattern: We use a context with timeout to prevent hanging processes.
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel() // Always call cancel to release resources

	// Go Pattern: os.MkdirTemp creates a unique temporary directory.
	// This is safer than writing to /tmp directly — no filename collisions.
	tmpDir, err := os.MkdirTemp("", "mta-subs-*")
	if err != nil {
		return "", "", fmt.Errorf("failed to create temp directory: %w", err)
	}
	defer os.RemoveAll(tmpDir) // Clean up when done, no matter what

	// Try manual subtitles first (higher quality), then auto-generated
	for _, subType := range []string{"--write-subs", "--write-auto-subs"} {
		cmd := exec.CommandContext(ctx, e.ytDlpPath,
			"--js-runtimes", "node", // Required for YouTube extraction
			"--extractor-args", "youtube:player_client=tv", // Use TV client to avoid PO token requirement
			"--skip-download",         // Don't download video
			subType,                   // Which subtitle type to get
			"--sub-langs", "en.*,en",  // Prefer English
			"--sub-format", "vtt",     // WebVTT format (easiest to parse)
			"--output", filepath.Join(tmpDir, "%(id)s"),
			"--no-warnings",
			url,
		)

		output, err := cmd.CombinedOutput()
		if err != nil {
			log.Printf("⚠️  Subtitle extraction (%s) failed: %s", subType, string(output))
			continue
		}

		// Find the generated .vtt subtitle file in our temp directory
		// Go Pattern: filepath.Glob is the safe way to find files by pattern.
		matches, err := filepath.Glob(filepath.Join(tmpDir, "*.vtt"))
		if err != nil || len(matches) == 0 {
			// Also check for .srt files as fallback
			matches, _ = filepath.Glob(filepath.Join(tmpDir, "*.srt"))
		}
		if len(matches) == 0 {
			continue
		}

		subtitleFile := matches[0]

		// Read the subtitle file content
		// Go Pattern: os.ReadFile reads the entire file into memory.
		// For subtitle files (typically < 1MB), this is fine.
		content, err := os.ReadFile(subtitleFile)
		if err != nil {
			log.Printf("⚠️  Failed to read subtitle file: %v", err)
			continue
		}

		// Detect language from filename (e.g., abc123.en.vtt)
		lang := "en"
		base := filepath.Base(subtitleFile)
		parts := strings.Split(base, ".")
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
	// Remove common auto-caption artifacts FIRST (before collapsing whitespace)
	text = strings.ReplaceAll(text, "[Music]", "")
	text = strings.ReplaceAll(text, "[Applause]", "")
	text = strings.ReplaceAll(text, "[Laughter]", "")

	// Then collapse multiple spaces into one
	spaceRegex := regexp.MustCompile(`\s+`)
	text = spaceRegex.ReplaceAllString(text, " ")

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
