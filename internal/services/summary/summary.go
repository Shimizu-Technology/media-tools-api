// Package summary handles AI-powered transcript summarization via OpenRouter.
//
// OpenRouter provides a unified API for multiple LLM providers (OpenAI,
// Anthropic, Google, etc.) using a single API key. The request format
// follows the OpenAI chat completions standard.
package summary

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

// Service handles AI summary generation.
type Service struct {
	apiKey     string
	model      string
	httpClient *http.Client
}

// New creates a new summary service.
func New(apiKey, defaultModel string) *Service {
	return &Service{
		apiKey: apiKey,
		model:  defaultModel,
		// Go Pattern: Always configure timeouts on HTTP clients.
		// The default http.Client has NO timeout — requests can hang forever!
		httpClient: &http.Client{
			Timeout: 120 * time.Second, // LLMs can be slow
		},
	}
}

// Options configures how the summary should be generated.
type Options struct {
	Model  string // Override the default model
	Length string // "short", "medium", "detailed"
	Style  string // "bullet", "narrative", "academic"
}

// Result holds the generated summary.
type Result struct {
	Summary   string   `json:"summary"`
	KeyPoints []string `json:"key_points"`
	Model     string   `json:"model"`
	Prompt    string   `json:"prompt"`
}

// --- OpenRouter API types ---
// These match the OpenAI chat completions format used by OpenRouter.

type chatRequest struct {
	Model    string        `json:"model"`
	Messages []chatMessage `json:"messages"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
	Model string `json:"model"`
	Error *struct {
		Message string `json:"message"`
		Code    int    `json:"code"`
	} `json:"error"`
}

// Summarize generates an AI summary of the given transcript text.
func (s *Service) Summarize(ctx context.Context, transcriptText string, opts Options) (*Result, error) {
	if s.apiKey == "" {
		return nil, fmt.Errorf("OpenRouter API key not configured; set OPENROUTER_API_KEY")
	}

	// Use provided model or fall back to default
	model := s.model
	if opts.Model != "" {
		model = opts.Model
	}

	// Set defaults for options
	if opts.Length == "" {
		opts.Length = "medium"
	}
	if opts.Style == "" {
		opts.Style = "bullet"
	}

	// Build the prompt
	prompt := buildPrompt(transcriptText, opts)

	log.Printf("🤖 Generating %s %s summary using %s", opts.Length, opts.Style, model)

	// Make the API request
	reqBody := chatRequest{
		Model: model,
		Messages: []chatMessage{
			{
				Role:    "system",
				Content: "You are a precise and insightful content summarizer. You extract key information from video transcripts and present it clearly.",
			},
			{
				Role:    "user",
				Content: prompt,
			},
		},
	}

	jsonBody, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	// Build the HTTP request
	req, err := http.NewRequestWithContext(ctx, "POST",
		"https://openrouter.ai/api/v1/chat/completions",
		bytes.NewReader(jsonBody),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+s.apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("HTTP-Referer", "https://github.com/Shimizu-Technology/media-tools-api")
	req.Header.Set("X-Title", "Media Tools API")

	// Send the request
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("OpenRouter request failed: %w", err)
	}
	defer resp.Body.Close() // Go Pattern: ALWAYS close response bodies!

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("OpenRouter returned %d: %s", resp.StatusCode, string(body))
	}

	// Parse the response
	var chatResp chatResponse
	if err := json.Unmarshal(body, &chatResp); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	if chatResp.Error != nil {
		return nil, fmt.Errorf("OpenRouter error: %s", chatResp.Error.Message)
	}

	if len(chatResp.Choices) == 0 {
		return nil, fmt.Errorf("no response from model")
	}

	content := chatResp.Choices[0].Message.Content

	// Try to parse structured output (JSON with summary + key_points)
	result := parseStructuredOutput(content)
	result.Model = model
	result.Prompt = prompt

	return result, nil
}

// buildPrompt constructs the AI prompt based on options.
func buildPrompt(transcript string, opts Options) string {
	lengthGuide := map[string]string{
		"short":    "2-3 sentences",
		"medium":   "1-2 paragraphs",
		"detailed": "3-5 paragraphs with section headers",
	}

	styleGuide := map[string]string{
		"bullet":    "Use bullet points for key information.",
		"narrative": "Write in flowing prose, like a brief article.",
		"academic":  "Use formal academic tone with structured analysis.",
	}

	length := lengthGuide[opts.Length]
	if length == "" {
		length = lengthGuide["medium"]
	}

	style := styleGuide[opts.Style]
	if style == "" {
		style = styleGuide["bullet"]
	}

	// Truncate very long transcripts to avoid token limits
	maxLen := 15000
	truncated := transcript
	if len(transcript) > maxLen {
		truncated = transcript[:maxLen] + "\n\n[Transcript truncated due to length...]"
	}

	return fmt.Sprintf(`Summarize the following YouTube video transcript.

**Length:** %s
**Style:** %s

**Important:** Respond with valid JSON in this exact format:
{
  "summary": "Your summary text here",
  "key_points": ["Point 1", "Point 2", "Point 3"]
}

**Transcript:**
%s`, length, style, truncated)
}

// parseStructuredOutput tries to extract JSON from the AI response.
// Falls back to treating the whole response as the summary text.
func parseStructuredOutput(content string) *Result {
	// Try to parse as JSON first
	var structured struct {
		Summary   string   `json:"summary"`
		KeyPoints []string `json:"key_points"`
	}

	if err := json.Unmarshal([]byte(content), &structured); err == nil && structured.Summary != "" {
		return &Result{
			Summary:   structured.Summary,
			KeyPoints: structured.KeyPoints,
		}
	}

	// Try to find JSON within the response (models sometimes wrap it in markdown)
	// Look for { ... } pattern
	start := -1
	end := -1
	braceCount := 0
	for i, c := range content {
		if c == '{' {
			if braceCount == 0 {
				start = i
			}
			braceCount++
		} else if c == '}' {
			braceCount--
			if braceCount == 0 {
				end = i + 1
				break
			}
		}
	}

	if start >= 0 && end > start {
		jsonStr := content[start:end]
		if err := json.Unmarshal([]byte(jsonStr), &structured); err == nil && structured.Summary != "" {
			return &Result{
				Summary:   structured.Summary,
				KeyPoints: structured.KeyPoints,
			}
		}
	}

	// Fall back to raw text
	return &Result{
		Summary:   content,
		KeyPoints: []string{},
	}
}
