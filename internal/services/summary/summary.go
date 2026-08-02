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
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const (
	shortSummaryMaxTokens    = 1_500
	mediumSummaryMaxTokens   = 3_000
	detailedSummaryMaxTokens = 5_000
	chatMaxTokens            = 1_200
)

// Service handles AI summary generation.
type Service struct {
	apiKey       string
	model        string
	chatModel    string
	providerSort string
	httpClient   *http.Client
}

// New creates a new summary service.
func New(apiKey, defaultModel string) *Service {
	return NewWithModels(apiKey, defaultModel, defaultModel, "")
}

// NewWithModels allows interactive chat to use a faster model independently
// from the model chosen for durable summaries.
func NewWithModels(apiKey, summaryModel, chatModel, providerSort string) *Service {
	if strings.TrimSpace(chatModel) == "" {
		chatModel = summaryModel
	}
	return &Service{
		apiKey:       apiKey,
		model:        summaryModel,
		chatModel:    chatModel,
		providerSort: strings.TrimSpace(providerSort),
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
	Summary     string                 `json:"summary"`
	KeyPoints   []string               `json:"key_points"`
	ActionItems []string               `json:"action_items"`
	Decisions   []string               `json:"decisions"`
	Model       string                 `json:"model"`
	Evidence    models.SummaryEvidence `json:"evidence"`
}

// Result holds the generated summary.
type Result struct {
	Summary     string                 `json:"summary"`
	KeyPoints   []string               `json:"key_points"`
	ActionItems []string               `json:"action_items,omitempty"`
	Topics      []string               `json:"topics,omitempty"`
	Model       string                 `json:"model"`
	Prompt      string                 `json:"prompt"`
	Evidence    models.SummaryEvidence `json:"evidence"`
}

// --- OpenRouter API types ---
// These match the OpenAI chat completions format used by OpenRouter.

type chatRequest struct {
	Model          string               `json:"model"`
	Messages       []chatMessage        `json:"messages"`
	MaxTokens      int                  `json:"max_tokens"`
	ResponseFormat *responseFormat      `json:"response_format,omitempty"`
	Provider       *providerPreferences `json:"provider,omitempty"`
}

type responseFormat struct {
	Type string `json:"type"`
}

type providerPreferences struct {
	Sort string `json:"sort,omitempty"`
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

// ProviderError keeps provider failures typed without exposing raw upstream
// response bodies through persisted job errors or API responses.
type ProviderError struct {
	StatusCode int
	ErrorType  string
}

func (e *ProviderError) Error() string {
	return "AI provider request failed"
}

// PublicErrorMessage translates internal and provider errors into copy that is
// safe to persist and display. The original error remains available to server
// logs, while provider payloads, account links, and identifiers stay private.
func PublicErrorMessage(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "The AI service took too long to respond. Please try again."
	}
	if errors.Is(err, context.Canceled) {
		return "Summary generation was interrupted. Please try again."
	}

	var providerErr *ProviderError
	if errors.As(err, &providerErr) {
		switch providerErr.StatusCode {
		case http.StatusPaymentRequired:
			return "The AI service could not reserve enough capacity for this summary. Please try again. If it keeps happening, the workspace's AI credits may need attention."
		case http.StatusUnauthorized, http.StatusForbidden:
			return "AI summaries are temporarily unavailable because the service configuration needs attention."
		case http.StatusRequestTimeout:
			return "The AI service took too long to respond. Please try again."
		case http.StatusTooManyRequests:
			return "The AI service is busy right now. Please wait a moment and try again."
		case http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
			return "The AI service is temporarily unavailable. Please try again in a moment."
		default:
			return "We couldn't generate the AI summary. Please try again."
		}
	}

	return "We couldn't generate the AI summary. Please try again."
}

// PublicChatErrorMessage is the chat-specific version of the public error
// boundary. Chat endpoints are synchronous, so their handler responses must be
// safe even when a caller accidentally renders the returned message verbatim.
func PublicChatErrorMessage(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "The AI service took too long to answer. Please try again."
	}
	if errors.Is(err, context.Canceled) {
		return "The AI response was interrupted. Please try again."
	}

	var providerErr *ProviderError
	if errors.As(err, &providerErr) {
		switch providerErr.StatusCode {
		case http.StatusPaymentRequired:
			return "The AI service couldn't answer because the workspace's AI credits may need attention. Please try again."
		case http.StatusUnauthorized, http.StatusForbidden:
			return "AI chat is temporarily unavailable because the service configuration needs attention."
		case http.StatusRequestTimeout:
			return "The AI service took too long to answer. Please try again."
		case http.StatusTooManyRequests:
			return "The AI service is busy right now. Please wait a moment and try again."
		case http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
			return "The AI service is temporarily unavailable. Please try again in a moment."
		}
	}

	return "We couldn't generate an answer. Please try again."
}

func summaryMaxTokens(length string) int {
	switch strings.ToLower(strings.TrimSpace(length)) {
	case "short":
		return shortSummaryMaxTokens
	case "detailed":
		return detailedSummaryMaxTokens
	default:
		return mediumSummaryMaxTokens
	}
}

func newProviderError(status int, body []byte) error {
	var response struct {
		Error struct {
			Metadata struct {
				ErrorType string `json:"error_type"`
			} `json:"metadata"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &response)
	return &ProviderError{StatusCode: status, ErrorType: response.Error.Metadata.ErrorType}
}

func providerErrorStatus(responseStatus, errorCode int) int {
	if errorCode >= 400 {
		return errorCode
	}
	if responseStatus >= 400 {
		return responseStatus
	}
	return http.StatusBadGateway
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
	systemPrompt := getVideoSystemPrompt(opts.ContentType)

	log.Printf("🤖 Generating %s %s summary (type: %s) using %s", opts.Length, opts.Style, opts.ContentType, model)

	// Make the API request
	reqBody := chatRequest{
		Model:     model,
		MaxTokens: summaryMaxTokens(opts.Length),
		Provider:  s.providerPreferences(),
		Messages: []chatMessage{
			{
				Role:    "system",
				Content: systemPrompt,
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
		return nil, newProviderError(resp.StatusCode, body)
	}

	// Parse the response
	var chatResp chatResponse
	if err := json.Unmarshal(body, &chatResp); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	if chatResp.Error != nil {
		return nil, newProviderError(providerErrorStatus(resp.StatusCode, chatResp.Error.Code), body)
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

	model := s.chatModel
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
		Model:     model,
		Messages:  reqMessages,
		MaxTokens: chatMaxTokens,
		Provider:  s.providerPreferences(),
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
		return "", "", newProviderError(resp.StatusCode, body)
	}

	var chatResp chatResponse
	if err := json.Unmarshal(body, &chatResp); err != nil {
		return "", "", fmt.Errorf("failed to parse response: %w", err)
	}
	if chatResp.Error != nil {
		return "", "", newProviderError(providerErrorStatus(resp.StatusCode, chatResp.Error.Code), body)
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
		Model:     model,
		MaxTokens: summaryMaxTokens(opts.Length),
		Provider:  s.providerPreferences(),
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
		return nil, newProviderError(resp.StatusCode, body)
	}

	var chatResp chatResponse
	if err := json.Unmarshal(body, &chatResp); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	if chatResp.Error != nil {
		return nil, newProviderError(providerErrorStatus(resp.StatusCode, chatResp.Error.Code), body)
	}

	if len(chatResp.Choices) == 0 {
		return nil, fmt.Errorf("no response from model")
	}

	content := chatResp.Choices[0].Message.Content
	result := parseAudioOutput(content)
	result.Model = model

	return result, nil
}

func (s *Service) providerPreferences() *providerPreferences {
	if s.providerSort == "" {
		return nil
	}
	return &providerPreferences{Sort: s.providerSort}
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
// getVideoSystemPrompt returns a system prompt for video summarization.
// Uses the content_type option if provided, otherwise defaults to general.
func getVideoSystemPrompt(contentType string) string {
	prompts := map[string]string{
		"tutorial":      "You are an expert at summarizing programming tutorials and technical walkthroughs. Extract the technologies used, step-by-step instructions, gotchas/tips, and what the viewer should be able to do after watching.",
		"lecture":       "You are an expert at summarizing educational lectures. Extract key concepts, definitions, frameworks, examples, and study-worthy takeaways. Structure for easy review.",
		"podcast":       "You are an expert at summarizing podcast conversations. Identify the main topics discussed, interesting opinions, notable quotes, disagreements, and key recommendations.",
		"news":          "You are an expert at summarizing news content. Extract the key facts (who, what, when, where, why), context, implications, and any calls to action.",
		"conference":    "You are an expert at summarizing conference talks. Extract the speaker's thesis, key arguments, demos shown, tools/resources mentioned, and actionable takeaways.",
		"entertainment": "You are an expert at summarizing entertainment content. Identify the main narrative or theme, standout moments, and overall tone.",
		"review":        "You are an expert at summarizing product/tech reviews. Extract the product, pros, cons, key specs, comparisons, and the reviewer's verdict.",
	}

	if p, ok := prompts[contentType]; ok {
		return p
	}
	return "You are an expert content summarizer. You extract the most important information and present it clearly. You identify key points, actionable takeaways, and important details."
}

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

	// Increase truncation limit — modern models handle 100K+ tokens
	maxLen := 50000
	truncated := transcript
	if len(transcript) > maxLen {
		truncated = transcript[:maxLen] + "\n\n[Transcript truncated due to length...]"
	}

	return fmt.Sprintf(`Summarize the following video transcript.

**Length:** %s
**Style:** %s

**Important:** Respond with valid JSON in this exact format:
{
  "summary": "Clear executive summary of the content",
  "key_points": ["Most important point 1", "Point 2", "Point 3"],
  "action_items": ["Actionable takeaway 1", "Takeaway 2"],
  "topics": ["Topic/technology/concept 1", "Topic 2"]
}

Rules:
- "summary" should be a clear, informative executive summary (%s)
- "key_points" should capture the most important information (5-10 items for detailed, 3-5 for short)
- "action_items" should list actionable takeaways, things to try, or follow-ups (empty array if none)
- "topics" should list the main subjects, technologies, or concepts covered
- Be specific — include names, numbers, tools, and concrete details
- %s

**Transcript:**
%s`, length, style, length, style, truncated)
}

func buildTranscriptContext(transcript string) string {
	maxLen := 50000
	truncated := transcript
	if len(transcript) > maxLen {
		truncated = transcript[:maxLen] + "\n\n[Transcript truncated due to length...]"
	}
	return fmt.Sprintf("Transcript context:\n%s", truncated)
}

// parseStructuredOutput tries to extract JSON from the AI response.
// Falls back to treating the whole response as the summary text.
func parseStructuredOutput(content string) *Result {
	var structured struct {
		Summary     string   `json:"summary"`
		KeyPoints   []string `json:"key_points"`
		ActionItems []string `json:"action_items"`
		Topics      []string `json:"topics"`
	}

	// Try direct JSON parse
	if err := json.Unmarshal([]byte(content), &structured); err == nil && structured.Summary != "" {
		return &Result{
			Summary:     structured.Summary,
			KeyPoints:   structured.KeyPoints,
			ActionItems: structured.ActionItems,
			Topics:      structured.Topics,
		}
	}

	// Try to find JSON within the response (models sometimes wrap in markdown)
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
				Summary:     structured.Summary,
				KeyPoints:   structured.KeyPoints,
				ActionItems: structured.ActionItems,
				Topics:      structured.Topics,
			}
		}
	}

	// Fall back to raw text
	return &Result{
		Summary:   content,
		KeyPoints: []string{},
	}
}
