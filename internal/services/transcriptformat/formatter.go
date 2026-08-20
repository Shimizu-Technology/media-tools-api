// Package transcriptformat improves transcript readability without changing
// what the speaker said. The source Whisper text remains authoritative; every
// model response must pass a strict lexical-equivalence check before storage.
package transcriptformat

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode"
)

const (
	Version              = "readability-v1"
	defaultModel         = "gpt-4.1-mini"
	defaultEndpoint      = "https://api.openai.com/v1/chat/completions"
	maxChunkWords        = 2_000
	maxResponseBodyBytes = 2 << 20
)

var (
	ErrNotConfigured   = errors.New("transcript formatting is not configured")
	ErrUnsafeRewrite   = errors.New("formatted transcript changed the spoken words")
	ErrInvalidResponse = errors.New("transcript formatter returned an invalid response")
)

type Result struct {
	Text    string
	Model   string
	Version string
}

type Formatter struct {
	apiKey     string
	model      string
	endpoint   string
	httpClient *http.Client
}

func New(apiKey, model string) *Formatter {
	model = strings.TrimSpace(model)
	if model == "" {
		model = defaultModel
	}
	return &Formatter{
		apiKey:   strings.TrimSpace(apiKey),
		model:    model,
		endpoint: defaultEndpoint,
		httpClient: &http.Client{
			Timeout: 90 * time.Second,
		},
	}
}

func (f *Formatter) IsConfigured() bool {
	return f != nil && f.apiKey != "" && f.model != ""
}

func (f *Formatter) Format(ctx context.Context, source string) (*Result, error) {
	if !f.IsConfigured() {
		return nil, ErrNotConfigured
	}
	source = strings.TrimSpace(source)
	if source == "" {
		return nil, fmt.Errorf("%w: source transcript is empty", ErrInvalidResponse)
	}

	chunks := splitIntoWordBoundedChunks(source, maxChunkWords)
	formatted := make([]string, 0, len(chunks))
	modelUsed := f.model
	for _, chunk := range chunks {
		text, model, err := f.formatChunk(ctx, chunk)
		if err != nil {
			return nil, err
		}
		if !LexicallyEquivalent(chunk, text) {
			return nil, ErrUnsafeRewrite
		}
		formatted = append(formatted, normalizeLayout(text))
		if strings.TrimSpace(model) != "" {
			modelUsed = model
		}
	}

	resultText := normalizeLayout(strings.Join(formatted, "\n\n"))
	if !LexicallyEquivalent(source, resultText) {
		return nil, ErrUnsafeRewrite
	}
	return &Result{Text: resultText, Model: modelUsed, Version: Version}, nil
}

func (f *Formatter) formatChunk(ctx context.Context, source string) (string, string, error) {
	requestBody := struct {
		Model    string `json:"model"`
		Messages []struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"messages"`
		Temperature    float64 `json:"temperature"`
		MaxTokens      int     `json:"max_tokens"`
		ResponseFormat struct {
			Type string `json:"type"`
		} `json:"response_format"`
	}{
		Model:       f.model,
		Temperature: 0,
		MaxTokens:   8_192,
	}
	requestBody.ResponseFormat.Type = "json_object"
	requestBody.Messages = append(requestBody.Messages,
		struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		}{
			Role:    "system",
			Content: "Format speech-to-text for comfortable reading. Only change capitalization, punctuation, and paragraph breaks. Do not add, remove, replace, reorder, summarize, or correct any spoken word. Preserve repetitions, filler words, names, numbers, and contractions exactly. Do not use headings, bullets, labels, or Markdown. Return JSON with exactly one string field named text.",
		},
		struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		}{Role: "user", Content: source},
	)

	payload, err := json.Marshal(requestBody)
	if err != nil {
		return "", "", fmt.Errorf("marshal formatting request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, f.endpoint, bytes.NewReader(payload))
	if err != nil {
		return "", "", fmt.Errorf("create formatting request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+f.apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := f.httpClient.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("transcript formatting request failed: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBodyBytes))
	if err != nil {
		return "", "", fmt.Errorf("read formatting response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", "", fmt.Errorf("transcript formatting provider returned status %d", resp.StatusCode)
	}

	var providerResponse struct {
		Model   string `json:"model"`
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &providerResponse); err != nil || len(providerResponse.Choices) == 0 {
		return "", "", ErrInvalidResponse
	}
	var formatted struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal([]byte(providerResponse.Choices[0].Message.Content), &formatted); err != nil {
		return "", "", ErrInvalidResponse
	}
	formatted.Text = normalizeLayout(formatted.Text)
	if formatted.Text == "" {
		return "", "", ErrInvalidResponse
	}
	return formatted.Text, providerResponse.Model, nil
}

// LexicallyEquivalent ignores case and punctuation while requiring the exact
// same ordered sequence of letter/number tokens. This allows typography such
// as straight-to-curly apostrophes, but rejects even a plausible word rewrite.
func LexicallyEquivalent(source, formatted string) bool {
	left := lexicalTokens(source)
	right := lexicalTokens(formatted)
	if len(left) == 0 || len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

func lexicalTokens(value string) []string {
	var tokens []string
	var token []rune
	flush := func() {
		if len(token) == 0 {
			return
		}
		tokens = append(tokens, strings.ToLower(string(token)))
		token = token[:0]
	}
	for _, r := range value {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			token = append(token, r)
		} else {
			flush()
		}
	}
	flush()
	return tokens
}

func splitIntoWordBoundedChunks(value string, limit int) []string {
	words := strings.Fields(value)
	if len(words) <= limit || limit < 1 {
		return []string{strings.Join(words, " ")}
	}
	chunks := make([]string, 0, (len(words)+limit-1)/limit)
	for start := 0; start < len(words); start += limit {
		end := start + limit
		if end > len(words) {
			end = len(words)
		}
		chunks = append(chunks, strings.Join(words[start:end], " "))
	}
	return chunks
}

func normalizeLayout(value string) string {
	value = strings.ReplaceAll(value, "\r\n", "\n")
	value = strings.ReplaceAll(value, "\r", "\n")
	lines := strings.Split(value, "\n")
	cleaned := make([]string, 0, len(lines))
	blank := false
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			if !blank && len(cleaned) > 0 {
				cleaned = append(cleaned, "")
			}
			blank = true
			continue
		}
		cleaned = append(cleaned, line)
		blank = false
	}
	return strings.TrimSpace(strings.Join(cleaned, "\n"))
}
