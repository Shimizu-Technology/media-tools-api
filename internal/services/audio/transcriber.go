// Package audio provides audio transcription via OpenAI's Whisper API (MTA-16).
//
// Go Pattern: We use the standard net/http package to make API calls.
// Unlike JavaScript's fetch, Go's http.Client gives us full control
// over timeouts, retries, and connection reuse.
//
// The Whisper API accepts multipart form uploads (audio files) and
// returns transcribed text. Max file size is 25MB.
package audio

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"strings"
	"time"
)

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

// Transcriber handles audio transcription via the OpenAI Whisper API.
type Transcriber struct {
	apiKey     string
	httpClient *http.Client
}

// NewTranscriber creates a new Transcriber with the given OpenAI API key.
func NewTranscriber(apiKey string) *Transcriber {
	return &Transcriber{
		apiKey: apiKey,
		httpClient: &http.Client{
			// Whisper can take a while for long audio files
			Timeout: 5 * time.Minute,
		},
	}
}

// IsConfigured returns true if the OpenAI API key is set.
func (t *Transcriber) IsConfigured() bool {
	return t.apiKey != ""
}

// Transcribe sends an audio file to the Whisper API and returns the transcription.
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

	// Add the audio file
	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		return nil, fmt.Errorf("failed to create form file: %w", err)
	}

	if _, err := io.Copy(part, audioData); err != nil {
		return nil, fmt.Errorf("failed to copy audio data: %w", err)
	}

	// Add the model parameter (whisper-1 is currently the only model)
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
		return nil, fmt.Errorf("Whisper API returned status %d: %s", resp.StatusCode, string(respBody))
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

// CountWords counts the number of words in a text string.
func CountWords(text string) int {
	words := strings.Fields(text)
	return len(words)
}
