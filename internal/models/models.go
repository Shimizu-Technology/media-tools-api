// Package models defines the data structures used throughout the application.
package models

import (
	"encoding/json"
	"time"
)

// TranscriptStatus represents the processing state of a transcript.
type TranscriptStatus string

const (
	StatusPending    TranscriptStatus = "pending"
	StatusProcessing TranscriptStatus = "processing"
	StatusCompleted  TranscriptStatus = "completed"
	StatusFailed     TranscriptStatus = "failed"
)

// Transcript represents a YouTube video transcript stored in the database.
type Transcript struct {
	ID             string           `json:"id" db:"id"`
	YouTubeURL     string           `json:"youtube_url" db:"youtube_url"`
	YouTubeID      string           `json:"youtube_id" db:"youtube_id"`
	Title          string           `json:"title" db:"title"`
	ChannelName    string           `json:"channel_name" db:"channel_name"`
	Duration       int              `json:"duration" db:"duration"`
	Language       string           `json:"language" db:"language"`
	TranscriptText string           `json:"transcript_text" db:"transcript_text"`
	WordCount      int              `json:"word_count" db:"word_count"`
	Status         TranscriptStatus `json:"status" db:"status"`
	ErrorMessage   string           `json:"error_message,omitempty" db:"error_message"`
	BatchID        *string          `json:"batch_id,omitempty" db:"batch_id"`
	UserID         *string          `json:"user_id,omitempty" db:"user_id"`
	APIKeyID       *string          `json:"api_key_id,omitempty" db:"api_key_id"`
	CreatedAt      time.Time        `json:"created_at" db:"created_at"`
	UpdatedAt      time.Time        `json:"updated_at" db:"updated_at"`
}

// Batch represents a group of transcript extraction requests.
type Batch struct {
	ID             string           `json:"id" db:"id"`
	Status         TranscriptStatus `json:"status" db:"status"`
	TotalCount     int              `json:"total_count" db:"total_count"`
	CompletedCount int              `json:"completed_count" db:"completed_count"`
	FailedCount    int              `json:"failed_count" db:"failed_count"`
	CreatedAt      time.Time        `json:"created_at" db:"created_at"`
	UpdatedAt      time.Time        `json:"updated_at" db:"updated_at"`
}

// Summary represents an AI-generated summary of a transcript.
type Summary struct {
	ID           string          `json:"id" db:"id"`
	TranscriptID string          `json:"transcript_id" db:"transcript_id"`
	ModelUsed    string          `json:"model_used" db:"model_used"`
	PromptUsed   string          `json:"prompt_used" db:"prompt_used"`
	SummaryText  string          `json:"summary_text" db:"summary_text"`
	KeyPoints    json.RawMessage `json:"key_points" db:"key_points"`
	Length       string          `json:"length" db:"length"`
	Style        string          `json:"style" db:"style"`
	CreatedAt    time.Time       `json:"created_at" db:"created_at"`
}

// Transcript chat models for AI Q&A (MTA-27)
type TranscriptChatSession struct {
	ID           string    `json:"id" db:"id"`
	TranscriptID *string   `json:"transcript_id,omitempty" db:"transcript_id"`
	ItemType     string    `json:"item_type" db:"item_type"` // transcript, audio, pdf
	ItemID       string    `json:"item_id" db:"item_id"`
	APIKeyID     *string   `json:"api_key_id,omitempty" db:"api_key_id"`
	CreatedAt    time.Time `json:"created_at" db:"created_at"`
	UpdatedAt    time.Time `json:"updated_at" db:"updated_at"`
}

type TranscriptChatMessage struct {
	ID        string    `json:"id" db:"id"`
	SessionID string    `json:"session_id" db:"session_id"`
	Role      string    `json:"role" db:"role"` // "user" or "assistant"
	Content   string    `json:"content" db:"content"`
	ModelUsed string    `json:"model_used,omitempty" db:"model_used"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

// APIKey represents an API key for authentication.
type APIKey struct {
	ID         string     `json:"id" db:"id"`
	KeyHash    string     `json:"-" db:"key_hash"`
	KeyPrefix  string     `json:"key_prefix" db:"key_prefix"`
	Name       string     `json:"name" db:"name"`
	Active     bool       `json:"active" db:"active"`
	RateLimit  int        `json:"rate_limit" db:"rate_limit"`
	UserID     *string    `json:"user_id,omitempty" db:"user_id"`
	CreatedAt  time.Time  `json:"created_at" db:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty" db:"last_used_at"`
}

// --- Request/Response DTOs ---

type CreateTranscriptRequest struct {
	URL     string `json:"url" binding:"required_without=VideoID"`
	VideoID string `json:"video_id" binding:"required_without=URL"`
}

type CreateSummaryRequest struct {
	TranscriptID string `json:"transcript_id" binding:"required"`
	Model        string `json:"model,omitempty"`
	Length       string `json:"length,omitempty"`
	Style        string `json:"style,omitempty"`
}

type CreateChatMessageRequest struct {
	Message string `json:"message" binding:"required"`
	Model   string `json:"model,omitempty"`
}

type ChatResponse struct {
	Session  TranscriptChatSession  `json:"session"`
	Messages []TranscriptChatMessage `json:"messages"`
}

type CreateAPIKeyRequest struct {
	Name      string `json:"name" binding:"required"`
	RateLimit int    `json:"rate_limit,omitempty"`
}

type CreateAPIKeyResponse struct {
	APIKey
	RawKey string `json:"raw_key"`
}

// --- Batch DTOs ---

type CreateBatchRequest struct {
	URLs []string `json:"urls" binding:"required,min=1,max=10"`
}

type BatchResponse struct {
	Batch       Batch        `json:"batch"`
	Transcripts []Transcript `json:"transcripts"`
}

type BatchStatusResponse struct {
	Batch       Batch        `json:"batch"`
	Transcripts []Transcript `json:"transcripts"`
}

type TranscriptListParams struct {
	Page     int              `form:"page"`
	PerPage  int              `form:"per_page"`
	Status   TranscriptStatus `form:"status"`
	Search   string           `form:"search"`
	SortBy   string           `form:"sort_by"`
	SortDir  string           `form:"sort_dir"`
	DateFrom string           `form:"date_from"`
	DateTo   string           `form:"date_to"`
	APIKeyID *string          // Filter by owning API key (set internally, not from form)
}

type PaginatedResponse[T any] struct {
	Data       []T `json:"data"`
	Page       int `json:"page"`
	PerPage    int `json:"per_page"`
	TotalItems int `json:"total_items"`
	TotalPages int `json:"total_pages"`
}

// --- Audio Transcription Models (MTA-16, MTA-22/24/25/26) ---

// AudioContentType defines the type of audio content for tailored summarization.
type AudioContentType string

const (
	ContentGeneral      AudioContentType = "general"
	ContentPhoneCall    AudioContentType = "phone_call"
	ContentMeeting      AudioContentType = "meeting"
	ContentVoiceMemo    AudioContentType = "voice_memo"
	ContentInterview    AudioContentType = "interview"
	ContentLecture      AudioContentType = "lecture"
)

// ValidContentTypes for validation.
var ValidContentTypes = map[AudioContentType]bool{
	ContentGeneral:   true,
	ContentPhoneCall: true,
	ContentMeeting:   true,
	ContentVoiceMemo: true,
	ContentInterview: true,
	ContentLecture:   true,
}

type AudioTranscription struct {
	ID             string           `json:"id" db:"id"`
	Filename       string           `json:"filename" db:"filename"`
	OriginalName   string           `json:"original_name" db:"original_name"`
	Duration       float64          `json:"duration" db:"duration"`
	Language       string           `json:"language" db:"language"`
	TranscriptText string           `json:"transcript_text" db:"transcript_text"`
	WordCount      int              `json:"word_count" db:"word_count"`
	Status         string           `json:"status" db:"status"`
	ErrorMessage   string           `json:"error_message,omitempty" db:"error_message"`
	ContentType    AudioContentType `json:"content_type" db:"content_type"`
	SummaryText    string           `json:"summary_text,omitempty" db:"summary_text"`
	KeyPoints      json.RawMessage  `json:"key_points" db:"key_points"`
	ActionItems    json.RawMessage  `json:"action_items" db:"action_items"`
	Decisions      json.RawMessage  `json:"decisions" db:"decisions"`
	SummaryModel   string           `json:"summary_model,omitempty" db:"summary_model"`
	SummaryStatus  string           `json:"summary_status" db:"summary_status"`
	UserID         *string          `json:"user_id,omitempty" db:"user_id"`
	APIKeyID       *string          `json:"api_key_id,omitempty" db:"api_key_id"`
	CreatedAt      time.Time        `json:"created_at" db:"created_at"`
}

// SummarizeAudioRequest is the request body for POST /api/v1/audio/transcriptions/:id/summarize
type SummarizeAudioRequest struct {
	ContentType string `json:"content_type,omitempty"` // phone_call, meeting, voice_memo, etc.
	Model       string `json:"model,omitempty"`        // Override AI model
	Length      string `json:"length,omitempty"`       // short, medium, detailed
}

// AudioSearchParams for searching audio transcriptions (MTA-25).
type AudioSearchParams struct {
	Query       string `form:"q"`
	ContentType string `form:"content_type"`
	Page        int    `form:"page"`
	PerPage     int    `form:"per_page"`
}

// --- PDF Extraction Models (MTA-17) ---

type PDFExtraction struct {
	ID           string    `json:"id" db:"id"`
	Filename     string    `json:"filename" db:"filename"`
	OriginalName string    `json:"original_name" db:"original_name"`
	PageCount    int       `json:"page_count" db:"page_count"`
	TextContent  string    `json:"text_content" db:"text_content"`
	WordCount    int       `json:"word_count" db:"word_count"`
	Status       string    `json:"status" db:"status"`
	ErrorMessage string    `json:"error_message,omitempty" db:"error_message"`
	UserID       *string   `json:"user_id,omitempty" db:"user_id"`
	APIKeyID     *string   `json:"api_key_id,omitempty" db:"api_key_id"`
	CreatedAt    time.Time `json:"created_at" db:"created_at"`
}

// --- Webhook Models (MTA-18) ---

type Webhook struct {
	ID        string    `json:"id" db:"id"`
	APIKeyID  string    `json:"api_key_id" db:"api_key_id"`
	URL       string    `json:"url" db:"url"`
	Events    []string  `json:"events" db:"events"`
	Secret    string    `json:"-" db:"secret"`
	Active    bool      `json:"active" db:"active"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

type WebhookDelivery struct {
	ID           string     `json:"id" db:"id"`
	WebhookID    string     `json:"webhook_id" db:"webhook_id"`
	Event        string     `json:"event" db:"event"`
	Payload      string     `json:"payload" db:"payload"`
	Status       string     `json:"status" db:"status"`
	Attempts     int        `json:"attempts" db:"attempts"`
	LastError    string     `json:"last_error,omitempty" db:"last_error"`
	ResponseCode int        `json:"response_code" db:"response_code"`
	CreatedAt    time.Time  `json:"created_at" db:"created_at"`
	DeliveredAt  *time.Time `json:"delivered_at,omitempty" db:"delivered_at"`
}

type WebhookPayload struct {
	Event     string      `json:"event"`
	Data      interface{} `json:"data"`
	Timestamp time.Time   `json:"timestamp"`
}

var ValidWebhookEvents = map[string]bool{
	"transcript.completed": true,
	"transcript.failed":    true,
	"audio.completed":      true,
	"audio.failed":         true,
	"pdf.completed":        true,
	"pdf.failed":           true,
	"batch.completed":      true,
}

type CreateWebhookRequest struct {
	URL    string   `json:"url" binding:"required"`
	Events []string `json:"events" binding:"required,min=1"`
}

type UpdateWebhookRequest struct {
	Active *bool `json:"active"`
}

// --- User Auth Models (MTA-20) ---

type User struct {
	ID           string    `json:"id" db:"id"`
	Email        string    `json:"email" db:"email"`
	PasswordHash string    `json:"-" db:"password_hash"`
	Name         string    `json:"name" db:"name"`
	CreatedAt    time.Time `json:"created_at" db:"created_at"`
}

type RegisterRequest struct {
	Email    string `json:"email" binding:"required,email"`
	Password string `json:"password" binding:"required,min=8"`
	Name     string `json:"name" binding:"required"`
}

type LoginRequest struct {
	Email    string `json:"email" binding:"required,email"`
	Password string `json:"password" binding:"required"`
}

type AuthResponse struct {
	Token string `json:"token"`
	User  User   `json:"user"`
}

// --- Workspace Models (MTA-20) ---

type WorkspaceItem struct {
	ID        string    `json:"id" db:"id"`
	UserID    string    `json:"user_id" db:"user_id"`
	ItemType  string    `json:"item_type" db:"item_type"`
	ItemID    string    `json:"item_id" db:"item_id"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

type SaveToWorkspaceRequest struct {
	ItemType string `json:"item_type" binding:"required"`
	ItemID   string `json:"item_id" binding:"required"`
}

type WorkspaceResponse struct {
	Transcripts []Transcript         `json:"transcripts"`
	Audio       []AudioTranscription `json:"audio"`
	PDFs        []PDFExtraction      `json:"pdfs"`
}

// --- Common Response Types ---

type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
	Code    int    `json:"code"`
}

type HealthResponse struct {
	Status   string `json:"status"`
	Version  string `json:"version"`
	Database string `json:"database"`
	Workers  int    `json:"workers"`
}
