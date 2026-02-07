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
	Model       string // Override the default model
	Length      string // "short", "medium", "detailed"
	Style       string // "bullet", "narrative", "academic"
	ContentType string // "general", "phone_call", "meeting", "voice_memo", "interview", "lecture" (MTA-24)
}

// AudioResult holds the structured output from an audio transcription summary (MTA-22).
type AudioResult struct {
	Summary     string   `json:"summary"`
	KeyPoints   []string `json:"key_points"`
	ActionItems []string `json:"action_items"`
	Decisions   []string `json:"decisions"`
	Model       string   `json:"model"`
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

// ChatMessage represents a chat message used for transcript Q&A.
type ChatMessage struct {
	Role    string
	Content string
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

// ChatTranscript answers a user question using transcript context.
func (s *Service) ChatTranscript(ctx context.Context, contextLabel, transcriptText string, messages []ChatMessage, modelOverride string) (string, string, error) {
	if s.apiKey == "" {
		return "", "", fmt.Errorf("OpenRouter API key not configured; set OPENROUTER_API_KEY")
	}

	model := s.model
	if modelOverride != "" {
		model = modelOverride
	}

	systemPrompt := "You are a helpful assistant that answers questions about a " + contextLabel + ". " +
		"Only use information from the content. If the answer is not in the content, say you don't know."
	transcriptContext := buildTranscriptContext(transcriptText)

	reqMessages := []chatMessage{
		{Role: "system", Content: systemPrompt},
		{Role: "system", Content: transcriptContext},
	}
	for _, msg := range messages {
		if msg.Content == "" {
			continue
		}
		if msg.Role != "user" && msg.Role != "assistant" {
			continue
		}
		reqMessages = append(reqMessages, chatMessage{Role: msg.Role, Content: msg.Content})
	}

	reqBody := chatRequest{
		Model:    model,
		Messages: reqMessages,
	}

	jsonBody, err := json.Marshal(reqBody)
	if err != nil {
		return "", "", fmt.Errorf("failed to marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST",
		"https://openrouter.ai/api/v1/chat/completions",
		bytes.NewReader(jsonBody),
	)
	if err != nil {
		return "", "", fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+s.apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("HTTP-Referer", "https://github.com/Shimizu-Technology/media-tools-api")
	req.Header.Set("X-Title", "Media Tools API")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("OpenRouter request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", "", fmt.Errorf("failed to read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("OpenRouter returned %d: %s", resp.StatusCode, string(body))
	}

	var chatResp chatResponse
	if err := json.Unmarshal(body, &chatResp); err != nil {
		return "", "", fmt.Errorf("failed to parse response: %w", err)
	}
	if chatResp.Error != nil {
		return "", "", fmt.Errorf("OpenRouter error: %s", chatResp.Error.Message)
	}
	if len(chatResp.Choices) == 0 {
		return "", "", fmt.Errorf("no response from model")
	}

	content := chatResp.Choices[0].Message.Content
	return content, model, nil
}

// SummarizeAudio generates a structured summary of audio transcription text (MTA-22).
// Returns structured output with summary, key points, action items, and decisions.
func (s *Service) SummarizeAudio(ctx context.Context, transcriptText string, opts Options) (*AudioResult, error) {
	if s.apiKey == "" {
		return nil, fmt.Errorf("OpenRouter API key not configured; set OPENROUTER_API_KEY")
	}

	model := s.model
	if opts.Model != "" {
		model = opts.Model
	}
	if opts.Length == "" {
		opts.Length = "medium"
	}
	if opts.ContentType == "" {
		opts.ContentType = "general"
	}

	prompt := buildAudioPrompt(transcriptText, opts)
	systemPrompt := getAudioSystemPrompt(opts.ContentType)

	log.Printf("🤖 Generating %s audio summary (%s) using %s", opts.Length, opts.ContentType, model)

	reqBody := chatRequest{
		Model: model,
		Messages: []chatMessage{
			{Role: "system", Content: systemPrompt},
			{Role: "user", Content: prompt},
		},
	}

	jsonBody, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

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

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("OpenRouter request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("OpenRouter returned %d: %s", resp.StatusCode, string(body))
	}

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
	result := parseAudioOutput(content)
	result.Model = model

	return result, nil
}

// getAudioSystemPrompt returns a system prompt tailored to the content type (MTA-24).
func getAudioSystemPrompt(contentType string) string {
	prompts := map[string]string{
		"phone_call": `You are an expert at summarizing phone conversations. You identify the key topics discussed, any commitments or promises made, action items, and important decisions. You note who said what when possible, and flag anything that needs follow-up.`,
		"meeting":    `You are an expert meeting summarizer. You structure your output around agenda items, decisions made, action items with owners, and next steps. You capture the essence of discussions without unnecessary detail.`,
		"voice_memo": `You are an expert at processing voice memos and quick thoughts. You extract the key ideas, tasks to capture, reminders, and any creative insights. You organize scattered thoughts into clear, actionable items.`,
		"interview":  `You are an expert at summarizing interviews. You identify the key questions asked, notable answers, important insights from the interviewee, and overall impressions. You highlight standout moments.`,
		"lecture":    `You are an expert at summarizing educational content. You extract key concepts, definitions, examples, and takeaways. You structure the information for easy review and study.`,
		"general":    `You are an expert content summarizer. You extract the most important information from audio transcriptions and present it clearly and concisely. You identify key points, action items, and any decisions made.`,
	}

	if p, ok := prompts[contentType]; ok {
		return p
	}
	return prompts["general"]
}

// buildAudioPrompt constructs the prompt for audio summarization (MTA-22, MTA-24).
func buildAudioPrompt(transcript string, opts Options) string {
	lengthGuide := map[string]string{
		"short":    "2-3 sentences",
		"medium":   "1-2 paragraphs",
		"detailed": "3-5 paragraphs",
	}

	length := lengthGuide[opts.Length]
	if length == "" {
		length = lengthGuide["medium"]
	}

	contentLabel := map[string]string{
		"phone_call": "phone call",
		"meeting":    "meeting",
		"voice_memo": "voice memo",
		"interview":  "interview",
		"lecture":    "lecture/presentation",
		"general":    "audio recording",
	}

	label := contentLabel[opts.ContentType]
	if label == "" {
		label = "audio recording"
	}

	maxLen := 15000
	truncated := transcript
	if len(transcript) > maxLen {
		truncated = transcript[:maxLen] + "\n\n[Transcript truncated due to length...]"
	}

	return fmt.Sprintf(`Summarize the following %s transcription.

**Summary Length:** %s

**Important:** Respond with valid JSON in this exact format:
{
  "summary": "Executive summary of the content",
  "key_points": ["Key point 1", "Key point 2", "Key point 3"],
  "action_items": ["Action item 1", "Action item 2"],
  "decisions": ["Decision 1", "Decision 2"]
}

Rules:
- "summary" should be a clear executive summary (%s)
- "key_points" should list the most important topics/information discussed
- "action_items" should list any tasks, to-dos, or follow-ups mentioned (empty array if none)
- "decisions" should list any decisions or agreements made (empty array if none)
- Be specific and include names/details when mentioned
- If no action items or decisions exist, use empty arrays

**Transcript:**
%s`, label, length, length, truncated)
}

// parseAudioOutput extracts structured JSON from the AI response for audio summaries.
func parseAudioOutput(content string) *AudioResult {
	var structured struct {
		Summary     string   `json:"summary"`
		KeyPoints   []string `json:"key_points"`
		ActionItems []string `json:"action_items"`
		Decisions   []string `json:"decisions"`
	}

	// Try direct JSON parse
	if err := json.Unmarshal([]byte(content), &structured); err == nil && structured.Summary != "" {
		return &AudioResult{
			Summary:     structured.Summary,
			KeyPoints:   structured.KeyPoints,
			ActionItems: structured.ActionItems,
			Decisions:   structured.Decisions,
		}
	}

	// Try to find JSON within markdown code blocks or text
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
			return &AudioResult{
				Summary:     structured.Summary,
				KeyPoints:   structured.KeyPoints,
				ActionItems: structured.ActionItems,
				Decisions:   structured.Decisions,
			}
		}
	}

	// Fall back to raw text
	return &AudioResult{
		Summary:     content,
		KeyPoints:   []string{},
		ActionItems: []string{},
		Decisions:   []string{},
	}
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

func buildTranscriptContext(transcript string) string {
	maxLen := 15000
	truncated := transcript
	if len(transcript) > maxLen {
		truncated = transcript[:maxLen] + "\n\n[Transcript truncated due to length...]"
	}
	return fmt.Sprintf("Transcript context:\n%s", truncated)
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
