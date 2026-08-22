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
	SearchVector   string           `json:"-" db:"search_vector"`
}

// Batch represents a group of transcript extraction requests.
type Batch struct {
	ID             string           `json:"id" db:"id"`
	Status         TranscriptStatus `json:"status" db:"status"`
	TotalCount     int              `json:"total_count" db:"total_count"`
	CompletedCount int              `json:"completed_count" db:"completed_count"`
	FailedCount    int              `json:"failed_count" db:"failed_count"`
	UserID         *string          `json:"user_id,omitempty" db:"user_id"`
	APIKeyID       *string          `json:"api_key_id,omitempty" db:"api_key_id"`
	CreatedAt      time.Time        `json:"created_at" db:"created_at"`
	UpdatedAt      time.Time        `json:"updated_at" db:"updated_at"`
}

// Summary represents an AI-generated summary of a transcript.
type Summary struct {
	ID           string           `json:"id" db:"id"`
	TranscriptID string           `json:"transcript_id" db:"transcript_id"`
	ModelUsed    string           `json:"model_used" db:"model_used"`
	PromptUsed   string           `json:"prompt_used" db:"prompt_used"`
	SummaryText  string           `json:"summary_text" db:"summary_text"`
	KeyPoints    json.RawMessage  `json:"key_points" db:"key_points"`
	Evidence     json.RawMessage  `json:"evidence" db:"evidence"`
	Length       string           `json:"length" db:"length"`
	Style        string           `json:"style" db:"style"`
	ContentType  string           `json:"content_type,omitempty" db:"content_type"`
	Status       TranscriptStatus `json:"status" db:"status"`
	ErrorMessage string           `json:"error_message,omitempty" db:"error_message"`
	CreatedAt    time.Time        `json:"created_at" db:"created_at"`
	UpdatedAt    time.Time        `json:"updated_at" db:"updated_at"`
	SearchVector string           `json:"-" db:"search_vector"`
}

// Transcript chat models for AI Q&A (MTA-27)
type TranscriptChatSession struct {
	ID           string    `json:"id" db:"id"`
	TranscriptID *string   `json:"transcript_id,omitempty" db:"transcript_id"`
	ItemType     string    `json:"item_type" db:"item_type"` // transcript, audio, pdf
	ItemID       string    `json:"item_id" db:"item_id"`
	UserID       *string   `json:"user_id,omitempty" db:"user_id"`
	APIKeyID     *string   `json:"api_key_id,omitempty" db:"api_key_id"`
	CreatedAt    time.Time `json:"created_at" db:"created_at"`
	UpdatedAt    time.Time `json:"updated_at" db:"updated_at"`
}

type TranscriptChatMessage struct {
	ID        string          `json:"id" db:"id"`
	SessionID string          `json:"session_id" db:"session_id"`
	Role      string          `json:"role" db:"role"` // "user" or "assistant"
	Content   string          `json:"content" db:"content"`
	ModelUsed string          `json:"model_used,omitempty" db:"model_used"`
	Citations json.RawMessage `json:"citations" db:"citations"`
	CreatedAt time.Time       `json:"created_at" db:"created_at"`
}

// MediaSegment is a source-backed passage from a video, recording, or PDF.
// Time values use milliseconds so clients can seek without floating-point
// drift; PDF evidence uses PageNumber instead.
type MediaSegment struct {
	ID         string    `json:"id" db:"id"`
	ItemType   string    `json:"item_type" db:"item_type"`
	ItemID     string    `json:"item_id" db:"item_id"`
	Ordinal    int       `json:"ordinal" db:"ordinal"`
	StartMS    *int64    `json:"start_ms,omitempty" db:"start_ms"`
	EndMS      *int64    `json:"end_ms,omitempty" db:"end_ms"`
	PageNumber *int      `json:"page_number,omitempty" db:"page_number"`
	Text       string    `json:"text" db:"text"`
	CreatedAt  time.Time `json:"created_at" db:"created_at"`
}

// Citation is the validated, reader-facing pointer attached to a summary
// claim or assistant answer.
type Citation struct {
	SegmentID  string `json:"segment_id"`
	ItemType   string `json:"item_type"`
	ItemID     string `json:"item_id"`
	ItemTitle  string `json:"item_title,omitempty"`
	StartMS    *int64 `json:"start_ms,omitempty"`
	EndMS      *int64 `json:"end_ms,omitempty"`
	PageNumber *int   `json:"page_number,omitempty"`
}

// SummaryEvidence keeps citations aligned by output position while preserving
// the existing string-array API for key points, actions, and decisions.
type SummaryEvidence struct {
	Summary     []Citation   `json:"summary"`
	KeyPoints   [][]Citation `json:"key_points"`
	ActionItems [][]Citation `json:"action_items,omitempty"`
	Decisions   [][]Citation `json:"decisions,omitempty"`
	Topics      [][]Citation `json:"topics,omitempty"`
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
	ContentType  string `json:"content_type,omitempty"` // tutorial, lecture, podcast, conference, review, news, entertainment
}

type CreateChatMessageRequest struct {
	Message string `json:"message" binding:"required"`
	Model   string `json:"model,omitempty"`
}

type ChatResponse struct {
	Session  TranscriptChatSession   `json:"session"`
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
	UserID   *string          // Filter by owning user (set internally, not from form)
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
	ContentGeneral   AudioContentType = "general"
	ContentPhoneCall AudioContentType = "phone_call"
	ContentMeeting   AudioContentType = "meeting"
	ContentVoiceMemo AudioContentType = "voice_memo"
	ContentInterview AudioContentType = "interview"
	ContentLecture   AudioContentType = "lecture"
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
	ID                  string           `json:"id" db:"id"`
	Filename            string           `json:"filename" db:"filename"`
	OriginalName        string           `json:"original_name" db:"original_name"`
	AudioS3Key          string           `json:"audio_s3_key,omitempty" db:"audio_s3_key"`
	AudioS3Status       string           `json:"audio_s3_status,omitempty" db:"audio_s3_status"`
	AudioS3Size         int64            `json:"audio_s3_size,omitempty" db:"audio_s3_size"`
	ProcessingStage     string           `json:"processing_stage,omitempty" db:"processing_stage"`
	ProcessingProgress  int              `json:"processing_progress,omitempty" db:"processing_progress"`
	RetryCount          int              `json:"retry_count,omitempty" db:"retry_count"`
	Duration            float64          `json:"duration" db:"duration"`
	Language            string           `json:"language" db:"language"`
	TranscriptText      string           `json:"transcript_text" db:"transcript_text"`
	FormattedTranscript string           `json:"formatted_transcript_text" db:"formatted_transcript_text"`
	FormattingStatus    string           `json:"formatting_status" db:"formatting_status"`
	FormattingModel     string           `json:"formatting_model,omitempty" db:"formatting_model"`
	FormattingVersion   string           `json:"formatting_version,omitempty" db:"formatting_version"`
	FormattingError     string           `json:"formatting_error_message,omitempty" db:"formatting_error_message"`
	WordCount           int              `json:"word_count" db:"word_count"`
	Status              string           `json:"status" db:"status"`
	ErrorMessage        string           `json:"error_message,omitempty" db:"error_message"`
	QualityWarning      string           `json:"quality_warning,omitempty" db:"quality_warning"`
	OmittedRanges       json.RawMessage  `json:"omitted_ranges" db:"omitted_ranges"`
	ContentType         AudioContentType `json:"content_type" db:"content_type"`
	SummaryText         string           `json:"summary_text,omitempty" db:"summary_text"`
	KeyPoints           json.RawMessage  `json:"key_points" db:"key_points"`
	ActionItems         json.RawMessage  `json:"action_items" db:"action_items"`
	Decisions           json.RawMessage  `json:"decisions" db:"decisions"`
	SummaryModel        string           `json:"summary_model,omitempty" db:"summary_model"`
	SummaryLength       string           `json:"summary_length" db:"summary_length"`
	SummaryStatus       string           `json:"summary_status" db:"summary_status"`
	SummaryEvidence     json.RawMessage  `json:"summary_evidence" db:"summary_evidence"`
	SummaryErrorMessage string           `json:"summary_error_message,omitempty" db:"summary_error_message"`
	UserID              *string          `json:"user_id,omitempty" db:"user_id"`
	APIKeyID            *string          `json:"api_key_id,omitempty" db:"api_key_id"`
	CreatedAt           time.Time        `json:"created_at" db:"created_at"`
	SearchVector        string           `json:"-" db:"search_vector"`
}

// BackgroundJob is the durable queue record claimed by worker processes.
type BackgroundJob struct {
	ID             string          `json:"id" db:"id"`
	JobType        string          `json:"job_type" db:"job_type"`
	ResourceID     string          `json:"resource_id" db:"resource_id"`
	Payload        json.RawMessage `json:"payload" db:"payload"`
	Status         string          `json:"status" db:"status"`
	Attempts       int             `json:"attempts" db:"attempts"`
	MaxAttempts    int             `json:"max_attempts" db:"max_attempts"`
	RunAt          time.Time       `json:"run_at" db:"run_at"`
	LockedBy       *string         `json:"locked_by,omitempty" db:"locked_by"`
	LockedAt       *time.Time      `json:"locked_at,omitempty" db:"locked_at"`
	LeaseExpiresAt *time.Time      `json:"lease_expires_at,omitempty" db:"lease_expires_at"`
	StartedAt      *time.Time      `json:"started_at,omitempty" db:"started_at"`
	CompletedAt    *time.Time      `json:"completed_at,omitempty" db:"completed_at"`
	LastError      string          `json:"last_error" db:"last_error"`
	CreatedAt      time.Time       `json:"created_at" db:"created_at"`
	UpdatedAt      time.Time       `json:"updated_at" db:"updated_at"`
}

type AudioUploadSession struct {
	ID           string     `json:"id" db:"id"`
	ObjectKey    string     `json:"object_key" db:"object_key"`
	OriginalName string     `json:"original_name" db:"original_name"`
	ContentType  string     `json:"content_type" db:"content_type"`
	SizeBytes    int64      `json:"size_bytes" db:"size_bytes"`
	UserID       *string    `json:"user_id,omitempty" db:"user_id"`
	APIKeyID     *string    `json:"api_key_id,omitempty" db:"api_key_id"`
	Status       string     `json:"status" db:"status"`
	ExpiresAt    time.Time  `json:"expires_at" db:"expires_at"`
	CreatedAt    time.Time  `json:"created_at" db:"created_at"`
	CompletedAt  *time.Time `json:"completed_at,omitempty" db:"completed_at"`
}

// SummarizeAudioRequest is the request body for POST /api/v1/audio/transcriptions/:id/summarize
type SummarizeAudioRequest struct {
	ContentType string `json:"content_type,omitempty"` // phone_call, meeting, voice_memo, etc.
	Model       string `json:"model,omitempty"`        // Override AI model
	Length      string `json:"length,omitempty"`       // short, medium, detailed
}

type RenameAudioTranscriptionRequest struct {
	Name string `json:"name" binding:"required"`
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
	SearchVector string    `json:"-" db:"search_vector"`
}

// --- Webhook Models (MTA-18) ---

type Webhook struct {
	ID        string    `json:"id" db:"id"`
	UserID    *string   `json:"user_id,omitempty" db:"user_id"`
	APIKeyID  *string   `json:"api_key_id,omitempty" db:"api_key_id"`
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
	"summary.completed":    true,
	"summary.failed":       true,
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
	ClerkID      *string   `json:"clerk_id,omitempty" db:"clerk_id"`
	CreatedAt    time.Time `json:"created_at" db:"created_at"`
}

// AccountDeletionRequest is the durable coordination record for deleting an
// account across PostgreSQL, object storage, and Clerk.
type AccountDeletionRequest struct {
	ID             string          `json:"id" db:"id"`
	AppUserID      string          `json:"-" db:"app_user_id"`
	ClerkUserID    *string         `json:"-" db:"clerk_user_id"`
	ClerkUserHash  string          `json:"-" db:"clerk_user_hash"`
	ObjectKeys     json.RawMessage `json:"-" db:"object_keys"`
	Status         string          `json:"status" db:"status"`
	CleanupAfter   time.Time       `json:"cleanup_after" db:"cleanup_after"`
	ClerkDeletedAt *time.Time      `json:"-" db:"clerk_deleted_at"`
	CompletedAt    *time.Time      `json:"completed_at,omitempty" db:"completed_at"`
	LastError      string          `json:"-" db:"last_error"`
	RequestedAt    time.Time       `json:"requested_at" db:"requested_at"`
	UpdatedAt      time.Time       `json:"updated_at" db:"updated_at"`
}

type DeleteAccountRequest struct {
	Confirmation string `json:"confirmation" binding:"required"`
}

type DeleteAccountResponse struct {
	Status       string    `json:"status"`
	RequestedAt  time.Time `json:"requested_at"`
	CleanupAfter time.Time `json:"cleanup_after"`
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

// LibraryItem is the common metadata shape used by the unified library. The
// full transcript/text remains available from the item-specific detail route.
type LibraryItem struct {
	ID            string          `json:"id" db:"id"`
	ItemType      string          `json:"item_type" db:"item_type"`
	Title         string          `json:"title" db:"title"`
	Subtitle      string          `json:"subtitle" db:"subtitle"`
	Status        string          `json:"status" db:"status"`
	WordCount     int             `json:"word_count" db:"word_count"`
	Duration      float64         `json:"duration" db:"duration"`
	PageCount     int             `json:"page_count" db:"page_count"`
	SummaryStatus string          `json:"summary_status" db:"summary_status"`
	Favorite      bool            `json:"favorite" db:"favorite"`
	Archived      bool            `json:"archived" db:"archived"`
	Tags          json.RawMessage `json:"tags" db:"tags"`
	CreatedAt     time.Time       `json:"created_at" db:"created_at"`
}

type LibraryListParams struct {
	Page     int    `form:"page"`
	PerPage  int    `form:"per_page"`
	ItemType string `form:"type"`
	Status   string `form:"status"`
	Search   string `form:"search"`
	SortDir  string `form:"sort_dir"`
	Favorite string `form:"favorite"`
	Archive  string `form:"archive"`
	Tag      string `form:"tag"`
	UserID   *string
	APIKeyID *string
}

type LibraryPreferences struct {
	Favorite bool            `json:"favorite" db:"favorite"`
	Archived bool            `json:"archived" db:"archived"`
	Tags     json.RawMessage `json:"tags" db:"tags"`
}

type UpdateLibraryPreferencesRequest struct {
	Favorite *bool    `json:"favorite"`
	Archived *bool    `json:"archived"`
	Tags     []string `json:"tags"`
}

type LibraryStats struct {
	Total      int `json:"total" db:"total"`
	Pending    int `json:"pending" db:"pending"`
	Processing int `json:"processing" db:"processing"`
	Completed  int `json:"completed" db:"completed"`
	Failed     int `json:"failed" db:"failed"`
	Videos     int `json:"videos" db:"videos"`
	Audio      int `json:"audio" db:"audio"`
	PDFs       int `json:"pdfs" db:"pdfs"`
}

// --- Common Response Types ---

// --- Collections (grouping transcripts, audio, PDFs) ---

// Collection represents a user-created group for organizing media items.
type Collection struct {
	ID          string    `json:"id" db:"id"`
	Name        string    `json:"name" db:"name"`
	Description string    `json:"description" db:"description"`
	UserID      *string   `json:"user_id,omitempty" db:"user_id"`
	APIKeyID    *string   `json:"api_key_id,omitempty" db:"api_key_id"`
	ItemCount   int       `json:"item_count" db:"item_count"` // computed, not stored
	CreatedAt   time.Time `json:"created_at" db:"created_at"`
	UpdatedAt   time.Time `json:"updated_at" db:"updated_at"`
}

// CollectionItem represents a single item within a collection.
type CollectionItem struct {
	ID           string    `json:"id" db:"id"`
	CollectionID string    `json:"collection_id" db:"collection_id"`
	ItemType     string    `json:"item_type" db:"item_type"` // transcript, audio, pdf
	ItemID       string    `json:"item_id" db:"item_id"`
	Position     int       `json:"position" db:"position"`
	AddedAt      time.Time `json:"added_at" db:"added_at"`
	// Populated by JOIN queries — not always present
	ItemTitle  string `json:"item_title,omitempty" db:"item_title"`
	ItemStatus string `json:"item_status,omitempty" db:"item_status"`
}

// CollectionWithItems is a collection plus its items (for detail view).
type CollectionWithItems struct {
	Collection
	Items []CollectionItem `json:"items"`
}

type CreateCollectionRequest struct {
	Name        string `json:"name" binding:"required,max=255"`
	Description string `json:"description"`
}

type UpdateCollectionRequest struct {
	Name        *string `json:"name" binding:"omitempty,max=255"`
	Description *string `json:"description"`
}

type AddCollectionItemsRequest struct {
	Items []CollectionItemInput `json:"items" binding:"required,min=1,max=50"`
}

type CollectionItemInput struct {
	ItemType string `json:"item_type" binding:"required,oneof=transcript audio pdf"`
	ItemID   string `json:"item_id" binding:"required"`
}

type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
	Code    int    `json:"code"`
}

type HealthResponse struct {
	Status                 string `json:"status"`
	Version                string `json:"version"`
	Database               string `json:"database"`
	Workers                int    `json:"workers"`
	YtDlpCookiesConfigured bool   `json:"yt_dlp_cookies_configured"`
}
