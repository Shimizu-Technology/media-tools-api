// Package models defines the data structures used throughout the application.
//
// Go Pattern: Models are plain structs with JSON tags for serialization.
// Unlike Ruby's ActiveRecord or JavaScript's Mongoose, Go models are just
// data containers — no ORM magic. The database package handles persistence.
//
// JSON tags (e.g., `json:"id"`) control how struct fields are serialized
// to/from JSON. The `db` tags work with sqlx for database column mapping.
package models

import (
	"encoding/json"
	"time"
)

// TranscriptStatus represents the processing state of a transcript.
// Go Pattern: We use string constants instead of enums (Go doesn't have enums).
// This is a common pattern — define a type alias and named constants.
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
	Duration       int              `json:"duration" db:"duration"`          // Duration in seconds
	Language       string           `json:"language" db:"language"`
	TranscriptText string           `json:"transcript_text" db:"transcript_text"`
	WordCount      int              `json:"word_count" db:"word_count"`
	Status         TranscriptStatus `json:"status" db:"status"`
	ErrorMessage   string           `json:"error_message,omitempty" db:"error_message"` // omitempty = skip if empty
	BatchID        *string          `json:"batch_id,omitempty" db:"batch_id"`           // Pointer = nullable; links to batches table
	CreatedAt      time.Time        `json:"created_at" db:"created_at"`
	UpdatedAt      time.Time        `json:"updated_at" db:"updated_at"`
}

// Batch represents a group of transcript extraction requests (MTA-8).
// Go Pattern: Using a separate table for batches lets us track aggregate
// progress without querying every transcript. The counts are denormalized
// for performance — updated as each transcript completes or fails.
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
	KeyPoints    json.RawMessage `json:"key_points" db:"key_points"` // JSONB — stored as raw JSON
	Length       string          `json:"length" db:"length"`         // "short", "medium", "detailed"
	Style        string          `json:"style" db:"style"`           // "bullet", "narrative", "academic"
	CreatedAt    time.Time       `json:"created_at" db:"created_at"`
}

// APIKey represents an API key for authentication.
// Note: We store the HASH of the key, never the raw key itself.
type APIKey struct {
	ID         string    `json:"id" db:"id"`
	KeyHash    string    `json:"-" db:"key_hash"`           // "-" means never serialize to JSON
	KeyPrefix  string    `json:"key_prefix" db:"key_prefix"` // First 8 chars for identification
	Name       string    `json:"name" db:"name"`
	Active     bool      `json:"active" db:"active"`
	RateLimit  int       `json:"rate_limit" db:"rate_limit"` // Requests per hour
	CreatedAt  time.Time `json:"created_at" db:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty" db:"last_used_at"` // Pointer = nullable
}

// --- Request/Response DTOs (Data Transfer Objects) ---
// Go Pattern: Separate structs for API input/output vs database models.
// This keeps your API contract clean and independent of your database schema.

// CreateTranscriptRequest is the JSON body for POST /api/v1/transcripts.
type CreateTranscriptRequest struct {
	// Accept either a full YouTube URL or just the video ID
	URL     string `json:"url" binding:"required_without=VideoID"`
	VideoID string `json:"video_id" binding:"required_without=URL"`
}

// CreateSummaryRequest is the JSON body for POST /api/v1/summaries.
type CreateSummaryRequest struct {
	TranscriptID string `json:"transcript_id" binding:"required"`
	Model        string `json:"model,omitempty"`  // Optional: override default model
	Length       string `json:"length,omitempty"` // "short", "medium", "detailed"
	Style        string `json:"style,omitempty"`  // "bullet", "narrative", "academic"
}

// CreateAPIKeyRequest is the JSON body for POST /api/v1/keys.
type CreateAPIKeyRequest struct {
	Name      string `json:"name" binding:"required"`
	RateLimit int    `json:"rate_limit,omitempty"` // 0 = use default
}

// CreateAPIKeyResponse includes the raw key — shown only once at creation time.
type CreateAPIKeyResponse struct {
	APIKey
	RawKey string `json:"raw_key"` // The actual API key — save it! Only shown once.
}

// --- Batch DTOs (MTA-8) ---

// CreateBatchRequest is the JSON body for POST /api/v1/transcripts/batch.
// Go Pattern: The `binding:"required"` tag means Gin will reject requests
// where this field is missing. The `max=10` validator enforces our limit.
type CreateBatchRequest struct {
	URLs []string `json:"urls" binding:"required,min=1,max=10"`
}

// BatchResponse is the API response for a batch operation.
// It includes the batch metadata plus the individual transcript records.
type BatchResponse struct {
	Batch       Batch        `json:"batch"`
	Transcripts []Transcript `json:"transcripts"`
}

// BatchStatusResponse shows aggregate progress for a batch.
type BatchStatusResponse struct {
	Batch       Batch        `json:"batch"`
	Transcripts []Transcript `json:"transcripts"`
}

// TranscriptListParams holds query parameters for listing transcripts.
type TranscriptListParams struct {
	Page     int              `form:"page"`     // Page number (1-indexed)
	PerPage  int              `form:"per_page"` // Items per page
	Status   TranscriptStatus `form:"status"`   // Filter by status
	Search   string           `form:"search"`   // Search in title/channel
	SortBy   string           `form:"sort_by"`  // "created_at", "title", "word_count"
	SortDir  string           `form:"sort_dir"` // "asc" or "desc"
	DateFrom string           `form:"date_from"` // ISO date string
	DateTo   string           `form:"date_to"`   // ISO date string
}

// PaginatedResponse wraps a list response with pagination metadata.
// Go Pattern: Generics (added in Go 1.18) let us create type-safe
// containers. `any` is an alias for `interface{}` — it means "any type".
type PaginatedResponse[T any] struct {
	Data       []T `json:"data"`
	Page       int `json:"page"`
	PerPage    int `json:"per_page"`
	TotalItems int `json:"total_items"`
	TotalPages int `json:"total_pages"`
}

// ErrorResponse is a standard error format for all API errors.
type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
	Code    int    `json:"code"`
}

// HealthResponse is returned by the health check endpoint.
type HealthResponse struct {
	Status   string `json:"status"`
	Version  string `json:"version"`
	Database string `json:"database"`
	Workers  int    `json:"workers"`
}
