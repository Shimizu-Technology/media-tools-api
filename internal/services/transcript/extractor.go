// Package transcript handles video transcript extraction using yt-dlp.
// Supports YouTube, Vimeo, and any other yt-dlp-supported video platform.
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
	"html"
	"io"
	"log"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
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
	VideoID     string
	Title       string
	ChannelName string
	Duration    int // seconds
	Language    string
	Transcript  string
	WordCount   int
	Segments    []Segment
}

// Segment is a seekable source passage. Milliseconds are used throughout the
// persistence/API layer to avoid floating-point drift in browser players.
type Segment struct {
	StartMS int64
	EndMS   int64
	Text    string
}

// WhisperResult holds the output from a Whisper API call.
type WhisperResult struct {
	Text     string
	Language string
	Duration float64
	Segments []Segment
}

// WhisperTranscriber is an interface for audio transcription (used as fallback).
// This allows the transcript package to use Whisper without importing the audio package.
// The TranscribeForYouTube method is used as a fallback when subtitles are unavailable.
type WhisperTranscriber interface {
	TranscribeForYouTube(ctx context.Context, audioData io.Reader, filename string) (*WhisperResult, error)
	IsConfigured() bool
}

// YtDlpExtractor uses the yt-dlp CLI tool to extract transcripts.
// Go Pattern: This struct implements the Extractor interface (implicitly).
type YtDlpExtractor struct {
	ytDlpPath   string
	proxyURL    string             // Optional: residential proxy for YouTube
	cookiesFile string             // Optional: Netscape cookies.txt for login-required sites
	whisper     WhisperTranscriber // Optional: fallback to Whisper if subtitles fail
	jsSolver    bool               // Whether this yt-dlp build supports the JS challenge flags
}

// NewExtractor creates a new yt-dlp based extractor.
// Go Pattern: Constructor functions are named New<Type> or New<Package>.
func NewExtractor(ytDlpPath string) *YtDlpExtractor {
	help, err := exec.Command(ytDlpPath, "--help").Output()
	jsSolver := err == nil && bytes.Contains(help, []byte("--js-runtimes")) && bytes.Contains(help, []byte("--remote-components"))
	return &YtDlpExtractor{ytDlpPath: ytDlpPath, jsSolver: jsSolver}
}

// SetProxy configures a proxy for yt-dlp requests.
// Use a residential proxy to bypass YouTube's datacenter IP blocks.
// Format: http://user:pass@host:port
func (e *YtDlpExtractor) SetProxy(proxyURL string) {
	e.proxyURL = proxyURL
}

// SetCookiesFile configures a Netscape-format cookie jar for yt-dlp.
// This enables access to login-required/private videos (e.g., Vimeo private links).
func (e *YtDlpExtractor) SetCookiesFile(path string) {
	e.cookiesFile = strings.TrimSpace(path)
}

// SetWhisperFallback enables Whisper-based transcription as a fallback
// when subtitle extraction fails (e.g., due to bot detection or missing subtitles).
func (e *YtDlpExtractor) SetWhisperFallback(w WhisperTranscriber) {
	e.whisper = w
}

// buildBaseArgs returns the common yt-dlp arguments including proxy if configured.
func (e *YtDlpExtractor) buildBaseArgs() []string {
	var args []string
	if e.jsSolver {
		args = append(args,
			"--js-runtimes", "node",
			"--remote-components", "ejs:github",
		)
	}
	if e.cookiesFile != "" {
		args = append(args, "--cookies", e.cookiesFile)
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
	ID           string                `json:"id"`
	Title        string                `json:"title"`
	Channel      string                `json:"channel"`
	Duration     float64               `json:"duration"`
	Subtitles    map[string][]subtitle `json:"subtitles"`
	AutoCaptions map[string][]subtitle `json:"automatic_captions"`
}

type subtitle struct {
	URL string `json:"url"`
	Ext string `json:"ext"`
}

// ExtractFromURL downloads the transcript for any yt-dlp-supported video URL (YouTube, Vimeo, etc.).
// It first tries subtitles, then falls back to Whisper audio transcription.
func (e *YtDlpExtractor) ExtractFromURL(ctx context.Context, videoURL, videoID string) (*Result, error) {
	// Step 1: Get video metadata (title, channel, duration, available subtitles)
	log.Printf("🎬 Extracting metadata for video: %s", videoURL)
	metadata, metadataErr := e.getMetadata(ctx, videoURL)

	// Step 2: Try subtitle extraction first
	if metadataErr == nil {
		log.Printf("📝 Extracting transcript for: %s", metadata.Title)
		segments, lang, err := e.getTranscript(ctx, videoURL)
		if err == nil {
			cleaned := transcriptFromSegments(segments)
			wordCount := countWords(cleaned)
			return &Result{
				VideoID:     videoID,
				Title:       metadata.Title,
				ChannelName: metadata.Channel,
				Duration:    int(metadata.Duration),
				Language:    lang,
				Transcript:  cleaned,
				WordCount:   wordCount,
				Segments:    segments,
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
		// 64K mono speech is ample input quality for Whisper and avoids
		// downloading/uploading a much larger highest-quality MP3.
		"--audio-quality", "64K",
		"--postprocessor-args", "ffmpeg:-ac 1 -ar 16000",
		"--output", audioPath,
		"--no-playlist",
		"--quiet",
		url,
	)
	cmd := exec.CommandContext(ctx, e.ytDlpPath, args...)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, ytDlpError("failed to download audio", string(output), err)
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

	segments := groupTimedSegments(result.Segments, 30*time.Second, 700)
	cleaned := transcriptFromSegments(segments)
	if cleaned == "" {
		cleaned = cleanTranscript(result.Text)
	}
	wordCount := countWords(cleaned)

	return &Result{
		VideoID:     videoID,
		Title:       title,
		ChannelName: channel,
		Duration:    duration,
		Language:    result.Language,
		Transcript:  cleaned,
		WordCount:   wordCount,
		Segments:    segments,
	}, nil
}

// getMetadata fetches video info using yt-dlp --dump-json.
func (e *YtDlpExtractor) getMetadata(ctx context.Context, url string) (*ytDlpMetadata, error) {
	// Build command with base args (includes proxy if configured)
	args := e.buildBaseArgs()
	args = append(args,
		"--dump-json",   // Output video info as JSON
		"--no-download", // Don't download the video itself
		"--no-warnings", // Suppress warning messages
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
		return nil, ytDlpError("yt-dlp metadata failed", errMsg, err)
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
func (e *YtDlpExtractor) getTranscript(ctx context.Context, url string) ([]Segment, string, error) {
	// Go Pattern: We use a context with timeout to prevent hanging processes.
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel() // Always call cancel to release resources

	// Go Pattern: os.MkdirTemp creates a unique temporary directory.
	// This is safer than writing to /tmp directly — no filename collisions.
	tmpDir, err := os.MkdirTemp("", "mta-subs-*")
	if err != nil {
		return nil, "", fmt.Errorf("failed to create temp directory: %w", err)
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
			"--sub-format", "vtt", // WebVTT format (easiest to parse)
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

		segments := parseVTTSegments(string(content))
		if len(segments) > 0 {
			return segments, lang, nil
		}
	}

	return nil, "", fmt.Errorf("no subtitles available for this video")
}

// parseVTT keeps the legacy plain-text helper used by tests and callers that do
// not need timing. New ingestion uses parseVTTSegments so cue timing survives.
// WebVTT format:
//
//	WEBVTT
//	00:00:01.000 --> 00:00:04.000
//	Hello, welcome to the video.
//
//	00:00:04.500 --> 00:00:08.000
//	Today we're going to talk about...
func parseVTT(vtt string) string {
	return transcriptFromSegments(parseVTTSegments(vtt))
}

var (
	vttTimestampLine = regexp.MustCompile(`^((?:\d{2}:)?\d{2}:\d{2}[.,]\d{3})\s+-->\s+((?:\d{2}:)?\d{2}:\d{2}[.,]\d{3})`)
	vttTag           = regexp.MustCompile(`<[^>]+>`)
	vttCueIdentifier = regexp.MustCompile(`^\d+$`)
)

func parseVTTSegments(vtt string) []Segment {
	lines := strings.Split(strings.ReplaceAll(vtt, "\r\n", "\n"), "\n")
	cues := make([]Segment, 0, len(lines)/3)
	var current *Segment
	var cueLines []string

	flush := func() {
		if current == nil {
			cueLines = cueLines[:0]
			return
		}
		text := cleanCueText(strings.Join(cueLines, " "))
		if text != "" && current.EndMS >= current.StartMS {
			current.Text = text
			cues = append(cues, *current)
		}
		current = nil
		cueLines = cueLines[:0]
	}

	for _, raw := range lines {
		line := strings.TrimSpace(raw)
		if match := vttTimestampLine.FindStringSubmatch(line); len(match) == 3 {
			flush()
			start, startErr := parseVTTTimestamp(match[1])
			end, endErr := parseVTTTimestamp(match[2])
			if startErr == nil && endErr == nil {
				current = &Segment{StartMS: start, EndMS: end}
			}
			continue
		}
		if line == "" {
			flush()
			continue
		}
		if current == nil {
			// Headers, NOTE blocks, and cue identifiers are outside timed cues.
			continue
		}
		if vttCueIdentifier.MatchString(line) {
			continue
		}
		cueLines = append(cueLines, line)
	}
	flush()

	return groupTimedSegments(cues, 30*time.Second, 700)
}

func parseVTTTimestamp(value string) (int64, error) {
	normalized := strings.ReplaceAll(value, ",", ".")
	parts := strings.Split(normalized, ":")
	if len(parts) != 2 && len(parts) != 3 {
		return 0, fmt.Errorf("invalid VTT timestamp %q", value)
	}
	var hours int64
	var minutes int64
	var secondsPart string
	if len(parts) == 3 {
		parsedHours, err := strconv.ParseInt(parts[0], 10, 64)
		if err != nil {
			return 0, err
		}
		hours = parsedHours
		parsedMinutes, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			return 0, err
		}
		minutes = parsedMinutes
		secondsPart = parts[2]
	} else {
		parsedMinutes, err := strconv.ParseInt(parts[0], 10, 64)
		if err != nil {
			return 0, err
		}
		minutes = parsedMinutes
		secondsPart = parts[1]
	}
	seconds, err := strconv.ParseFloat(secondsPart, 64)
	if err != nil {
		return 0, err
	}
	return hours*3_600_000 + minutes*60_000 + int64(seconds*1000), nil
}

func cleanCueText(value string) string {
	value = html.UnescapeString(vttTag.ReplaceAllString(value, ""))
	return cleanTranscript(value)
}

func groupTimedSegments(cues []Segment, targetDuration time.Duration, maxChars int) []Segment {
	if len(cues) == 0 {
		return nil
	}
	targetMS := targetDuration.Milliseconds()
	grouped := make([]Segment, 0, len(cues))
	var current Segment

	flush := func() {
		current.Text = cleanTranscript(current.Text)
		if current.Text != "" {
			grouped = append(grouped, current)
		}
		current = Segment{}
	}

	for _, cue := range cues {
		cue.Text = cleanCueText(cue.Text)
		if cue.Text == "" {
			continue
		}
		if current.Text == "" {
			current = cue
			continue
		}
		gap := cue.StartMS - current.EndMS
		novel := appendNovelCaptionText(current.Text, cue.Text)
		wouldExceedDuration := cue.EndMS-current.StartMS > targetMS
		wouldExceedChars := len(novel) > maxChars
		if gap > 3_000 || wouldExceedDuration || wouldExceedChars {
			flush()
			current = cue
			continue
		}
		current.Text = novel
		if cue.EndMS > current.EndMS {
			current.EndMS = cue.EndMS
		}
	}
	flush()
	return grouped
}

func appendNovelCaptionText(existing, next string) string {
	existingWords := strings.Fields(existing)
	nextWords := strings.Fields(next)
	maxOverlap := min(len(existingWords), len(nextWords), 30)
	for overlap := maxOverlap; overlap > 0; overlap-- {
		if equalWordsFold(existingWords[len(existingWords)-overlap:], nextWords[:overlap]) {
			if overlap == len(nextWords) {
				return existing
			}
			return strings.Join(append(existingWords, nextWords[overlap:]...), " ")
		}
	}
	return strings.TrimSpace(existing + " " + next)
}

func equalWordsFold(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if !strings.EqualFold(left[index], right[index]) {
			return false
		}
	}
	return true
}

func transcriptFromSegments(segments []Segment) string {
	parts := make([]string, 0, len(segments))
	for _, segment := range segments {
		if text := cleanTranscript(segment.Text); text != "" {
			parts = append(parts, text)
		}
	}
	return cleanTranscript(strings.Join(parts, " "))
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
	URL     string
	VideoID string
	Source  VideoSource
}

func parseAbsoluteVideoURL(input string) (bool, string) {
	u, err := url.Parse(input)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return false, ""
	}
	return true, strings.ToLower(u.Hostname())
}

func isYouTubeHost(host string) bool {
	return host == "youtube.com" || strings.HasSuffix(host, ".youtube.com") || host == "youtu.be"
}

func isVimeoHost(host string) bool {
	return host == "vimeo.com" || strings.HasSuffix(host, ".vimeo.com")
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

	absURL, absHost := parseAbsoluteVideoURL(input)

	// YouTube URL patterns. For absolute URLs, only trust matches from real
	// YouTube hosts; otherwise an internal URL containing "youtube.com/watch" in
	// a path/query could bypass generic URL SSRF validation.
	if !absURL || isYouTubeHost(absHost) {
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
	}

	// Vimeo URL patterns. For absolute URLs, only trust matches from real Vimeo
	// hosts for the same SSRF reason described above.
	if !absURL || isVimeoHost(absHost) {
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

// ValidateExternalVideoURL blocks obvious SSRF targets before a generic URL is
// handed to yt-dlp. yt-dlp itself performs its own network requests and resolves
// hostnames again, so this is a defense-in-depth preflight for user-supplied
// non-YouTube/Vimeo URLs. Production should still pair this with network egress
// controls/sandboxing around yt-dlp for full DNS-rebinding protection.
func ValidateExternalVideoURL(ctx context.Context, raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("malformed URL")
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("only http and https video URLs are allowed")
	}
	if u.Host == "" {
		return fmt.Errorf("missing host")
	}
	hostname := strings.ToLower(u.Hostname())
	if hostname == "" || hostname == "localhost" {
		return fmt.Errorf("localhost is not allowed")
	}

	if ip := net.ParseIP(hostname); ip != nil {
		if isBlockedVideoIP(ip) {
			return fmt.Errorf("private or local network video URLs are not allowed")
		}
		return nil
	}

	resolveCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	ips, err := net.DefaultResolver.LookupIPAddr(resolveCtx, hostname)
	if err != nil || len(ips) == 0 {
		return fmt.Errorf("failed to resolve video host")
	}
	for _, resolved := range ips {
		if isBlockedVideoIP(resolved.IP) {
			return fmt.Errorf("private or local network video URLs are not allowed")
		}
	}
	return nil
}

func isBlockedVideoIP(ip net.IP) bool {
	return ip.IsLoopback() ||
		ip.IsPrivate() ||
		isCarrierGradeNAT(ip) ||
		ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() ||
		ip.IsUnspecified()
}

// isCarrierGradeNAT blocks the IANA Shared Address Space (RFC 6598) used for
// carrier-grade NAT. net.IP.IsPrivate only covers RFC 1918 IPv4 and IPv6 ULA.
func isCarrierGradeNAT(ip net.IP) bool {
	ipv4 := ip.To4()
	return ipv4 != nil && ipv4[0] == 100 && ipv4[1]&0xc0 == 64
}

func ytDlpError(prefix, details string, cause error) error {
	msg := strings.TrimSpace(details)
	if strings.Contains(msg, "works when logged-in") || strings.Contains(msg, "cookies-from-browser") {
		return fmt.Errorf(
			"%s: %s. This video requires authentication. Configure YT_DLP_COOKIES_FILE to a valid cookies.txt with Vimeo login session",
			prefix, msg,
		)
	}
	return fmt.Errorf("%s: %s - %v", prefix, msg, cause)
}
