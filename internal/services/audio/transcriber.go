// Package audio provides transcription for uploaded media files via OpenAI's
// speech-to-text API (MTA-16).
//
// Go Pattern: We use the standard net/http package to make API calls.
// Unlike JavaScript's fetch, Go's http.Client gives us full control
// over timeouts, retries, and connection reuse.
//
// The transcription API accepts multipart form uploads for supported media
// files containing audio and returns transcribed text. Max file size is 25MB.
package audio

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"strings"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcript"
)

// WhisperAPIError is a structured error from the Whisper API.
// Used by the worker's retry logic to classify errors by status code
// instead of parsing error message strings.
type WhisperAPIError struct {
	StatusCode int
	Body       string
}

func (e *WhisperAPIError) Error() string {
	return fmt.Sprintf("Whisper API returned status %d: %s", e.StatusCode, e.Body)
}

// TranscriptionResult holds the output from a Whisper API call.
type TranscriptionResult struct {
	Text     string  `json:"text"`
	Language string  `json:"language"`
	Duration float64 `json:"duration"`
}

// whisperResponse is the JSON shape returned by the Whisper API
// when response_format is "verbose_json".
type whisperResponse struct {
	Text     string  `json:"text"`
	Language string  `json:"language"`
	Duration float64 `json:"duration"`
}

// Transcriber handles media transcription via OpenAI's transcription API.
type Transcriber struct {
	apiKey     string
	httpClient *http.Client
}

// NewTranscriber creates a new Transcriber with the given OpenAI API key.
func NewTranscriber(apiKey string) *Transcriber {
	return &Transcriber{
		apiKey: apiKey,
		httpClient: &http.Client{
			// Transcription can take a while for long recordings.
			Timeout: 5 * time.Minute,
		},
	}
}

// IsConfigured returns true if the OpenAI API key is set.
func (t *Transcriber) IsConfigured() bool {
	return t.apiKey != ""
}

// Transcribe sends a media file containing audio to the transcription API and
// returns the transcription.
//
// Go Pattern: We build a multipart form body manually. In Go, multipart.Writer
// handles the boundary generation and MIME encoding — similar to FormData in JS.
func (t *Transcriber) Transcribe(ctx context.Context, audioData io.Reader, filename string) (*TranscriptionResult, error) {
	if !t.IsConfigured() {
		return nil, fmt.Errorf("OpenAI API key not configured; set OPENAI_API_KEY environment variable")
	}

	// Build multipart form body
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)

	// Add the audio file. Include a concrete part MIME type because some audio
	// APIs inspect both the multipart filename and Content-Type when validating
	// media formats.
	partHeader := make(textproto.MIMEHeader)
	partHeader.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename="%s"`, escapeQuotes(filename)))
	partHeader.Set("Content-Type", whisperContentType(filename))
	part, err := writer.CreatePart(partHeader)
	if err != nil {
		return nil, fmt.Errorf("failed to create form file: %w", err)
	}

	if _, err := io.Copy(part, audioData); err != nil {
		return nil, fmt.Errorf("failed to copy audio data: %w", err)
	}

	// Keep the existing model choice for now; Phase 1 Zoom support is only about
	// input compatibility, not changing transcription models.
	if err := writer.WriteField("model", "whisper-1"); err != nil {
		return nil, fmt.Errorf("failed to write model field: %w", err)
	}

	// Request verbose JSON for language detection and duration
	if err := writer.WriteField("response_format", "verbose_json"); err != nil {
		return nil, fmt.Errorf("failed to write response_format field: %w", err)
	}

	// Close the writer to finalize the multipart body
	if err := writer.Close(); err != nil {
		return nil, fmt.Errorf("failed to close multipart writer: %w", err)
	}

	// Create the HTTP request
	req, err := http.NewRequestWithContext(ctx, "POST", "https://api.openai.com/v1/audio/transcriptions", &body)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+t.apiKey)
	req.Header.Set("Content-Type", writer.FormDataContentType())

	// Send the request
	resp, err := t.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("Whisper API request failed: %w", err)
	}
	defer resp.Body.Close()

	// Read response body
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	// Check for API errors
	if resp.StatusCode != http.StatusOK {
		return nil, &WhisperAPIError{StatusCode: resp.StatusCode, Body: string(respBody)}
	}

	// Parse the response
	var whisperResp whisperResponse
	if err := json.Unmarshal(respBody, &whisperResp); err != nil {
		return nil, fmt.Errorf("failed to parse Whisper response: %w", err)
	}

	return &TranscriptionResult{
		Text:     whisperResp.Text,
		Language: whisperResp.Language,
		Duration: whisperResp.Duration,
	}, nil
}

func whisperContentType(filename string) string {
	lower := strings.ToLower(filename)
	switch {
	case strings.HasSuffix(lower, ".mp3") || strings.HasSuffix(lower, ".mpga"):
		return "audio/mpeg"
	case strings.HasSuffix(lower, ".mpeg"):
		return "video/mpeg"
	case strings.HasSuffix(lower, ".aac"):
		return "audio/aac"
	case strings.HasSuffix(lower, ".m4a"):
		return "audio/mp4"
	case strings.HasSuffix(lower, ".mp4"):
		return "video/mp4"
	case strings.HasSuffix(lower, ".ogg") || strings.HasSuffix(lower, ".oga"):
		return "audio/ogg"
	case strings.HasSuffix(lower, ".wav"):
		return "audio/wav"
	case strings.HasSuffix(lower, ".flac"):
		return "audio/flac"
	case strings.HasSuffix(lower, ".webm"):
		return "audio/webm"
	default:
		return "application/octet-stream"
	}
}

func escapeQuotes(s string) string {
	return strings.NewReplacer("\\", "\\\\", "\"", "\\\"").Replace(s)
}

// CountWords counts the number of words in a text string.
func CountWords(text string) int {
	words := strings.Fields(text)
	return len(words)
}

// WhisperAdapter wraps Transcriber to implement the transcript.WhisperTranscriber interface.
// This enables Whisper as a fallback when YouTube subtitle extraction fails.
type WhisperAdapter struct {
	*Transcriber
}

// TranscribeForYouTube implements the transcript.WhisperTranscriber interface.
// It transcribes audio and returns a result compatible with the transcript package.
func (a *WhisperAdapter) TranscribeForYouTube(ctx context.Context, audioData io.Reader, filename string) (*transcript.WhisperResult, error) {
	result, err := a.Transcriber.Transcribe(ctx, audioData, filename)
	if err != nil {
		return nil, err
	}
	return &transcript.WhisperResult{
		Text:     result.Text,
		Language: result.Language,
		Duration: result.Duration,
	}, nil
}

// NewWhisperAdapter creates an adapter for use with the transcript package.
func NewWhisperAdapter(t *Transcriber) *WhisperAdapter {
	return &WhisperAdapter{Transcriber: t}
}
