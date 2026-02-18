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
	ExtractFromURL(ctx context.Context, videoURL, videoID string) (*Result, error)
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
// The TranscribeForYouTube method is used as a fallback when subtitles are unavailable and returns our WhisperResult.
type WhisperTranscriber interface {
	TranscribeForYouTube(ctx context.Context, audioData io.Reader, filename string) (*WhisperResult, error)
	IsConfigured() bool
}

// YtDlpExtractor uses the yt-dlp CLI tool to extract transcripts.
// Go Pattern: This struct implements the Extractor interface (implicitly).
type YtDlpExtractor struct {
	ytDlpPath string
	proxyURL  string             // Optional: residential proxy for YouTube
	whisper   WhisperTranscriber // Optional: fallback to Whisper if subtitles fail
}

// NewExtractor creates a new yt-dlp based extractor.
// Go Pattern: Constructor functions are named New<Type> or New<Package>.
func NewExtractor(ytDlpPath string) *YtDlpExtractor {
	return &YtDlpExtractor{ytDlpPath: ytDlpPath}
}

// SetProxy configures a proxy for yt-dlp requests.
// Use a residential proxy to bypass YouTube's datacenter IP blocks.
// Format: http://user:pass@host:port
func (e *YtDlpExtractor) SetProxy(proxyURL string) {
	e.proxyURL = proxyURL
}

// SetWhisperFallback enables Whisper-based transcription as a fallback
// when subtitle extraction fails (e.g., due to YouTube bot detection).
func (e *YtDlpExtractor) SetWhisperFallback(w WhisperTranscriber) {
	e.whisper = w
}

// buildBaseArgs returns the common yt-dlp arguments including proxy if configured.
func (e *YtDlpExtractor) buildBaseArgs() []string {
	args := []string{
		"--js-runtimes", "node",              // Required for YouTube extraction
		"--remote-components", "ejs:github",  // Download JS challenge solver from GitHub
	}
	if e.proxyURL != "" {
		args = append(args, "--proxy", e.proxyURL)
		// Use android_vr client - doesn't require PO Token (unlike ios/web/mweb)
		// See: https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide
		args = append(args, "--extractor-args", "youtube:player_client=android_vr")
	}
	return args
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

// ExtractFromURL downloads the transcript for any video URL supported by yt-dlp.
// It first tries subtitles, then falls back to Whisper audio transcription.
func (e *YtDlpExtractor) ExtractFromURL(ctx context.Context, videoURL, videoID string) (*Result, error) {
	// Step 1: Get video metadata (title, channel, duration, available subtitles)
	log.Printf("🎬 Extracting metadata for video: %s", videoURL)
	metadata, metadataErr := e.getMetadata(ctx, videoURL)

	// Step 2: Try subtitle extraction first
	if metadataErr == nil {
		log.Printf("📝 Extracting transcript for: %s", metadata.Title)
		transcript, lang, err := e.getTranscript(ctx, videoURL)
		if err == nil {
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
		log.Printf("🎤 Falling back to Whisper transcription for: %s", videoURL)
		return e.extractWithWhisper(ctx, videoURL, videoID, metadata)
	}

	if metadataErr != nil {
		return nil, fmt.Errorf("failed to get video metadata: %w", metadataErr)
	}
	return nil, fmt.Errorf("no transcript available and Whisper fallback not configured")
}

// Extract downloads the transcript for a YouTube video by ID.
// Deprecated: Use ExtractFromURL for universal video support.
func (e *YtDlpExtractor) Extract(ctx context.Context, videoID string) (*Result, error) {
	url := fmt.Sprintf("https://www.youtube.com/watch?v=%s", videoID)
	return e.ExtractFromURL(ctx, url, videoID)
}

// extractWithWhisper downloads audio from a video URL and transcribes with Whisper.
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

	// Build command with base args (includes proxy if configured)
	args := e.buildBaseArgs()
	args = append(args,
		"--extract-audio",
		"--audio-format", "mp3",
		"--audio-quality", "0",
		"--output", audioPath,
		"--no-playlist",
		"--quiet",
		url,
	)
	cmd := exec.CommandContext(ctx, e.ytDlpPath, args...)

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
	// Build command with base args (includes proxy if configured)
	args := e.buildBaseArgs()
	args = append(args,
		"--dump-json",    // Output video info as JSON
		"--no-download",  // Don't download the video itself
		"--no-warnings",  // Suppress warning messages
		url,
	)

	// exec.CommandContext cancels the command if the context is cancelled.
	// This prevents runaway processes — important for a web server!
	cmd := exec.CommandContext(ctx, e.ytDlpPath, args...)

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
		// Build command with base args (includes proxy if configured)
		args := e.buildBaseArgs()
		args = append(args,
			"--skip-download",        // Don't download video
			subType,                  // Which subtitle type to get
			"--sub-langs", "en.*,en", // Prefer English
			"--sub-format", "vtt",    // WebVTT format (easiest to parse)
			"--output", filepath.Join(tmpDir, "%(id)s"),
			"--no-warnings",
			url,
		)
		cmd := exec.CommandContext(ctx, e.ytDlpPath, args...)

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

// Pre-compiled regex patterns for URL parsing (compiled once at package init, not per-call).
var (
	plainVideoIDRegex = regexp.MustCompile(`^[a-zA-Z0-9_-]{11}$`)
	ytURLPatterns     = []*regexp.Regexp{
		regexp.MustCompile(`(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|youtube\.com/v/)([a-zA-Z0-9_-]{11})`),
		regexp.MustCompile(`(?:youtube\.com/shorts/)([a-zA-Z0-9_-]{11})`),
	}
	vimeoURLPatterns = []*regexp.Regexp{
		regexp.MustCompile(`vimeo\.com/(?:video/)?(\d+)(?:\?|$|/)`),
		regexp.MustCompile(`vimeo\.com/channels/[^/]+/(\d+)(?:\?|$|/)`),
		regexp.MustCompile(`vimeo\.com/groups/[^/]+/videos/(\d+)(?:\?|$|/)`),
		regexp.MustCompile(`player\.vimeo\.com/video/(\d+)(?:\?|$|/)`),
	}
)

// VideoSource identifies which platform a video URL belongs to.
type VideoSource string

const (
	SourceYouTube VideoSource = "youtube"
	SourceVimeo   VideoSource = "vimeo"
	SourceOther   VideoSource = "other" // Any other yt-dlp-supported site
)

// ParsedVideo holds the parsed video URL, identifier, and source platform.
type ParsedVideo struct {
	URL      string
	VideoID  string
	Source   VideoSource
}

// ParseVideoURL parses a video URL from YouTube, Vimeo, or any yt-dlp-supported site.
// Returns the canonical URL, a video identifier, and the source platform.
//
// Supported formats:
//   - YouTube: youtube.com/watch?v=ID, youtu.be/ID, shorts/ID, plain 11-char ID
//   - Vimeo: vimeo.com/ID, vimeo.com/channels/NAME/ID, player.vimeo.com/video/ID
//   - Other: Any URL that yt-dlp can handle (Dailymotion, Twitch VODs, etc.)
func ParseVideoURL(input string) (*ParsedVideo, error) {
	input = strings.TrimSpace(input)
	if input == "" {
		return nil, fmt.Errorf("empty URL or video ID")
	}

	// YouTube: plain video ID (11 alphanumeric chars + - and _)
	if plainVideoIDRegex.MatchString(input) {
		return &ParsedVideo{
			URL:     fmt.Sprintf("https://www.youtube.com/watch?v=%s", input),
			VideoID: input,
			Source:  SourceYouTube,
		}, nil
	}

	// YouTube URL patterns
	for _, pattern := range ytURLPatterns {
		matches := pattern.FindStringSubmatch(input)
		if len(matches) >= 2 {
			return &ParsedVideo{
				URL:     fmt.Sprintf("https://www.youtube.com/watch?v=%s", matches[1]),
				VideoID: matches[1],
				Source:  SourceYouTube,
			}, nil
		}
	}

	// Vimeo URL patterns (anchored to avoid matching manage/settings paths)
	for _, pattern := range vimeoURLPatterns {
		matches := pattern.FindStringSubmatch(input)
		if len(matches) >= 2 {
			// Preserve original URL for yt-dlp — private/unlisted Vimeo videos
			// use URLs like vimeo.com/123456789/abc123def where the trailing
			// segment is a privacy hash required for access. Constructing a
			// canonical URL would strip this hash and break private video access.
			return &ParsedVideo{
				URL:     input,
				VideoID: matches[1],
				Source:  SourceVimeo,
			}, nil
		}
	}

	// Any other URL — let yt-dlp try to handle it
	if strings.HasPrefix(input, "http://") || strings.HasPrefix(input, "https://") {
		// Extract a stable identifier: host + path (no scheme, no query params)
		// This ensures http:// vs https:// and ?ref=share vs no query produce the same ID
		videoID := input
		parts := strings.SplitN(input, "://", 2)
		if len(parts) == 2 {
			videoID = parts[1]
		}
		// Strip query parameters and fragments for stable deduplication
		if idx := strings.IndexAny(videoID, "?#"); idx != -1 {
			videoID = videoID[:idx]
		}
		// Remove trailing slash
		videoID = strings.TrimRight(videoID, "/")
		return &ParsedVideo{
			URL:     input,
			VideoID: videoID,
			Source:  SourceOther,
		}, nil
	}

	return nil, fmt.Errorf("invalid video URL: %s (supported: YouTube, Vimeo, or any yt-dlp-compatible URL)", input)
}

// ParseYouTubeURL is a backward-compatible wrapper around ParseVideoURL.
// Only accepts YouTube URLs/IDs — rejects other platforms to preserve existing behavior.
// Deprecated: Use ParseVideoURL instead.
func ParseYouTubeURL(input string) (string, string, error) {
	parsed, err := ParseVideoURL(input)
	if err != nil {
		return "", "", err
	}
	if parsed.Source != SourceYouTube {
		return "", "", fmt.Errorf("invalid YouTube URL or video ID: %s", input)
	}
	return parsed.URL, parsed.VideoID, nil
}
