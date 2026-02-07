// Package database handles PostgreSQL connections and queries.
//
// Go Pattern: We use the `sqlx` package which extends Go's standard `database/sql`
// with convenient features like scanning rows into structs. Unlike an ORM
// (ActiveRecord, Sequelize), you write raw SQL — which gives you full control
// and helps you learn SQL properly.
//
// Go's database/sql has built-in connection pooling — you create one *sql.DB
// (or *sqlx.DB) at startup and share it across your entire application.
// It's safe for concurrent use by multiple goroutines.
package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq" // PostgreSQL driver — the underscore import runs its init()

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// DB wraps the sqlx database connection with our application-specific methods.
// Go Pattern: Embedding (*sqlx.DB) gives us all of sqlx's methods automatically,
// plus we can add our own. This is Go's version of inheritance — composition.
type DB struct {
	*sqlx.DB
}

// New creates a new database connection with connection pooling configured.
func New(databaseURL string) (*DB, error) {
	// sqlx.Connect both opens the connection and pings the database
	db, err := sqlx.Connect("postgres", databaseURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to database: %w", err)
	}

	// Configure connection pool for serverless PostgreSQL (Neon)
	// Go Pattern: The connection pool is managed by database/sql internally.
	// These settings prevent resource exhaustion and handle Neon's aggressive
	// connection timeouts (serverless PG closes idle connections quickly).
	db.SetMaxOpenConns(10)                 // Fewer connections for serverless
	db.SetMaxIdleConns(2)                  // Keep minimal idle connections
	db.SetConnMaxLifetime(2 * time.Minute) // Recycle connections frequently
	db.SetConnMaxIdleTime(30 * time.Second) // Close idle connections before Neon does

	return &DB{db}, nil
}

// HealthCheck verifies the database connection is alive.
// Go Pattern: context.Context is passed to functions that may be slow or
// need cancellation (like database queries, HTTP requests). It's like
// AbortController in JavaScript but built into the language conventions.
func (db *DB) HealthCheck(ctx context.Context) error {
	return db.PingContext(ctx)
}

// --- Transcript Operations ---

// CreateTranscript inserts a new transcript record.
// Returns the created transcript with its generated ID and timestamps.
// Note: batch_id defaults to NULL for single transcript extractions.
func (db *DB) CreateTranscript(ctx context.Context, t *models.Transcript) error {
	query := `
		INSERT INTO transcripts (youtube_url, youtube_id, title, channel_name, duration, language, transcript_text, word_count, status, error_message, batch_id, api_key_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
		RETURNING id, created_at, updated_at`

	// QueryRowContext executes a query that returns a single row.
	// Scan() reads the returned columns into our struct fields.
	return db.QueryRowContext(ctx, query,
		t.YouTubeURL, t.YouTubeID, t.Title, t.ChannelName,
		t.Duration, t.Language, t.TranscriptText, t.WordCount,
		t.Status, t.ErrorMessage, t.BatchID, t.APIKeyID,
	).Scan(&t.ID, &t.CreatedAt, &t.UpdatedAt)
}

// GetTranscript retrieves a single transcript by ID.
func (db *DB) GetTranscript(ctx context.Context, id string) (*models.Transcript, error) {
	var t models.Transcript
	// GetContext is sqlx's convenience method — it scans directly into a struct
	// using the `db:"column_name"` tags we defined on the model.
	err := db.GetContext(ctx, &t, `SELECT * FROM transcripts WHERE id = $1`, id)
	if err != nil {
		return nil, fmt.Errorf("transcript not found: %w", err)
	}
	return &t, nil
}

// GetTranscriptByYouTubeID checks if we already have a transcript for this video.
func (db *DB) GetTranscriptByYouTubeID(ctx context.Context, youtubeID string) (*models.Transcript, error) {
	var t models.Transcript
	err := db.GetContext(ctx, &t, `SELECT * FROM transcripts WHERE youtube_id = $1`, youtubeID)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// UpdateTranscript updates a transcript's fields after processing.
func (db *DB) UpdateTranscript(ctx context.Context, t *models.Transcript) error {
	query := `
		UPDATE transcripts
		SET title = $2, channel_name = $3, duration = $4, language = $5,
			transcript_text = $6, word_count = $7, status = $8, error_message = $9,
			updated_at = NOW()
		WHERE id = $1
		RETURNING updated_at`

	return db.QueryRowContext(ctx, query,
		t.ID, t.Title, t.ChannelName, t.Duration, t.Language,
		t.TranscriptText, t.WordCount, t.Status, t.ErrorMessage,
	).Scan(&t.UpdatedAt)
}

// ListTranscripts returns a paginated list of transcripts with optional filters.
func (db *DB) ListTranscripts(ctx context.Context, params models.TranscriptListParams) ([]models.Transcript, int, error) {
	// Set defaults
	if params.Page < 1 {
		params.Page = 1
	}
	if params.PerPage < 1 || params.PerPage > 100 {
		params.PerPage = 20
	}
	if params.SortBy == "" {
		params.SortBy = "created_at"
	}
	if params.SortDir == "" {
		params.SortDir = "desc"
	}

	// Build WHERE clause dynamically
	// Go Pattern: Strings.Builder is the efficient way to build strings
	// (like StringBuilder in Java). Using + for concatenation creates new
	// strings each time, which is wasteful.
	var conditions []string
	var args []interface{}
	argNum := 1

	if params.Status != "" {
		conditions = append(conditions, fmt.Sprintf("status = $%d", argNum))
		args = append(args, params.Status)
		argNum++
	}

	if params.Search != "" {
		conditions = append(conditions, fmt.Sprintf("(title ILIKE $%d OR channel_name ILIKE $%d)", argNum, argNum))
		args = append(args, "%"+params.Search+"%")
		argNum++
	}

	if params.DateFrom != "" {
		conditions = append(conditions, fmt.Sprintf("created_at >= $%d", argNum))
		args = append(args, params.DateFrom)
		argNum++
	}

	if params.DateTo != "" {
		conditions = append(conditions, fmt.Sprintf("created_at <= $%d", argNum))
		args = append(args, params.DateTo)
		argNum++
	}

	if params.APIKeyID != nil {
		conditions = append(conditions, fmt.Sprintf("api_key_id = $%d", argNum))
		args = append(args, *params.APIKeyID)
		argNum++
	}

	whereClause := ""
	if len(conditions) > 0 {
		whereClause = "WHERE " + strings.Join(conditions, " AND ")
	}

	// Validate sort column to prevent SQL injection
	validSortColumns := map[string]bool{
		"created_at": true, "title": true, "word_count": true, "duration": true,
	}
	if !validSortColumns[params.SortBy] {
		params.SortBy = "created_at"
	}
	if params.SortDir != "asc" && params.SortDir != "desc" {
		params.SortDir = "desc"
	}

	// Count total matching records
	countQuery := fmt.Sprintf("SELECT COUNT(*) FROM transcripts %s", whereClause)
	var total int
	err := db.GetContext(ctx, &total, countQuery, args...)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			total = 0
		} else {
			return nil, 0, fmt.Errorf("count query failed: %w", err)
		}
	}

	// Fetch page of results
	offset := (params.Page - 1) * params.PerPage
	selectQuery := fmt.Sprintf(
		"SELECT * FROM transcripts %s ORDER BY %s %s LIMIT $%d OFFSET $%d",
		whereClause, params.SortBy, params.SortDir, argNum, argNum+1,
	)
	args = append(args, params.PerPage, offset)

	var transcripts []models.Transcript
	err = db.SelectContext(ctx, &transcripts, selectQuery, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("list query failed: %w", err)
	}

	return transcripts, total, nil
}

// DeleteTranscript removes a transcript by ID.
func (db *DB) DeleteTranscript(ctx context.Context, id string) error {
	result, err := db.ExecContext(ctx, `DELETE FROM transcripts WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("failed to delete transcript: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("transcript not found")
	}
	return nil
}

// --- Summary Operations ---

// CreateSummary inserts a new summary record.
func (db *DB) CreateSummary(ctx context.Context, s *models.Summary) error {
	query := `
		INSERT INTO summaries (transcript_id, model_used, prompt_used, summary_text, key_points, length, style)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id, created_at`

	return db.QueryRowContext(ctx, query,
		s.TranscriptID, s.ModelUsed, s.PromptUsed,
		s.SummaryText, s.KeyPoints, s.Length, s.Style,
	).Scan(&s.ID, &s.CreatedAt)
}

// GetSummary retrieves a single summary by ID.
func (db *DB) GetSummary(ctx context.Context, id string) (*models.Summary, error) {
	var s models.Summary
	err := db.GetContext(ctx, &s, `SELECT * FROM summaries WHERE id = $1`, id)
	if err != nil {
		return nil, fmt.Errorf("summary not found: %w", err)
	}
	return &s, nil
}

// GetSummariesByTranscript returns all summaries for a given transcript.
func (db *DB) GetSummariesByTranscript(ctx context.Context, transcriptID string) ([]models.Summary, error) {
	var summaries []models.Summary
	err := db.SelectContext(ctx, &summaries,
		`SELECT * FROM summaries WHERE transcript_id = $1 ORDER BY created_at DESC`, transcriptID)
	if err != nil {
		return nil, fmt.Errorf("failed to list summaries: %w", err)
	}
	return summaries, nil
}

// --- Chat Operations (MTA-27) ---

// GetOrCreateChatSession finds or creates a chat session for an item.
func (db *DB) GetOrCreateChatSession(ctx context.Context, itemType, itemID string, apiKeyID *string) (*models.TranscriptChatSession, error) {
	var session models.TranscriptChatSession
	var err error

	if apiKeyID != nil {
		err = db.GetContext(ctx, &session,
			`SELECT * FROM transcript_chat_sessions WHERE item_type = $1 AND item_id = $2 AND api_key_id = $3`,
			itemType, itemID, *apiKeyID)
	} else {
		err = db.GetContext(ctx, &session,
			`SELECT * FROM transcript_chat_sessions WHERE item_type = $1 AND item_id = $2 AND api_key_id IS NULL`,
			itemType, itemID)
	}

	if err == nil {
		return &session, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("failed to fetch chat session: %w", err)
	}

	// Create a new session
	var transcriptID *string
	if itemType == "transcript" {
		transcriptID = &itemID
	}

	query := `
		INSERT INTO transcript_chat_sessions (item_type, item_id, transcript_id, api_key_id)
		VALUES ($1, $2, $3, $4)
		RETURNING id, created_at, updated_at`
	if apiKeyID != nil {
		err = db.QueryRowContext(ctx, query, itemType, itemID, transcriptID, *apiKeyID).
			Scan(&session.ID, &session.CreatedAt, &session.UpdatedAt)
		session.APIKeyID = apiKeyID
	} else {
		err = db.QueryRowContext(ctx, query, itemType, itemID, transcriptID, nil).
			Scan(&session.ID, &session.CreatedAt, &session.UpdatedAt)
	}
	if err != nil {
		return nil, fmt.Errorf("failed to create chat session: %w", err)
	}
	session.ItemType = itemType
	session.ItemID = itemID
	if itemType == "transcript" {
		session.TranscriptID = &itemID
	}

	return &session, nil
}

// ListChatMessages returns chat messages for a session.
func (db *DB) ListChatMessages(ctx context.Context, sessionID string, limit int) ([]models.TranscriptChatMessage, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var messages []models.TranscriptChatMessage
	err := db.SelectContext(ctx, &messages,
		`SELECT * FROM transcript_chat_messages WHERE session_id = $1 ORDER BY created_at ASC LIMIT $2`,
		sessionID, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to list chat messages: %w", err)
	}
	return messages, nil
}

// CreateChatMessage inserts a chat message.
func (db *DB) CreateChatMessage(ctx context.Context, msg *models.TranscriptChatMessage) error {
	query := `
		INSERT INTO transcript_chat_messages (session_id, role, content, model_used)
		VALUES ($1, $2, $3, $4)
		RETURNING id, created_at`
	if err := db.QueryRowContext(ctx, query,
		msg.SessionID, msg.Role, msg.Content, msg.ModelUsed,
	).Scan(&msg.ID, &msg.CreatedAt); err != nil {
		return fmt.Errorf("failed to create chat message: %w", err)
	}

	_, _ = db.ExecContext(ctx,
		`UPDATE transcript_chat_sessions SET updated_at = NOW() WHERE id = $1`,
		msg.SessionID)
	return nil
}

// --- API Key Operations ---

// CreateAPIKey inserts a new API key record.
func (db *DB) CreateAPIKey(ctx context.Context, key *models.APIKey) error {
	query := `
		INSERT INTO api_keys (key_hash, key_prefix, name, active, rate_limit)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, created_at`

	return db.QueryRowContext(ctx, query,
		key.KeyHash, key.KeyPrefix, key.Name, key.Active, key.RateLimit,
	).Scan(&key.ID, &key.CreatedAt)
}

// GetAPIKeyByHash retrieves an API key by its hash (used during authentication).
func (db *DB) GetAPIKeyByHash(ctx context.Context, hash string) (*models.APIKey, error) {
	var key models.APIKey
	err := db.GetContext(ctx, &key,
		`SELECT * FROM api_keys WHERE key_hash = $1 AND active = true`, hash)
	if err != nil {
		return nil, fmt.Errorf("invalid API key: %w", err)
	}
	return &key, nil
}

// UpdateAPIKeyLastUsed bumps the last_used_at timestamp.
func (db *DB) UpdateAPIKeyLastUsed(ctx context.Context, id string) error {
	_, err := db.ExecContext(ctx, `UPDATE api_keys SET last_used_at = NOW() WHERE id = $1`, id)
	return err
}

// ListAPIKeys returns all API keys (active and inactive).
func (db *DB) ListAPIKeys(ctx context.Context) ([]models.APIKey, error) {
	var keys []models.APIKey
	err := db.SelectContext(ctx, &keys, `SELECT * FROM api_keys ORDER BY created_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("failed to list API keys: %w", err)
	}
	return keys, nil
}

// RevokeAPIKey deactivates an API key.
func (db *DB) RevokeAPIKey(ctx context.Context, id string) error {
	result, err := db.ExecContext(ctx, `UPDATE api_keys SET active = false WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("failed to revoke key: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("API key not found")
	}
	return nil
}

// --- Audio Transcription Operations (MTA-16) ---

// CreateAudioTranscription inserts a new audio transcription record.
func (db *DB) CreateAudioTranscription(ctx context.Context, at *models.AudioTranscription) error {
	query := `
		INSERT INTO audio_transcriptions (filename, original_name, duration, language, transcript_text, word_count, status, error_message, content_type, api_key_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		RETURNING id, created_at`

	if at.ContentType == "" {
		at.ContentType = models.ContentGeneral
	}

	return db.QueryRowContext(ctx, query,
		at.Filename, at.OriginalName, at.Duration, at.Language,
		at.TranscriptText, at.WordCount, at.Status, at.ErrorMessage,
		at.ContentType, at.APIKeyID,
	).Scan(&at.ID, &at.CreatedAt)
}

// GetAudioTranscription retrieves a single audio transcription by ID.
func (db *DB) GetAudioTranscription(ctx context.Context, id string) (*models.AudioTranscription, error) {
	var at models.AudioTranscription
	err := db.GetContext(ctx, &at, `SELECT * FROM audio_transcriptions WHERE id = $1`, id)
	if err != nil {
		return nil, fmt.Errorf("audio transcription not found: %w", err)
	}
	return &at, nil
}

// UpdateAudioTranscription updates an audio transcription record after processing.
func (db *DB) UpdateAudioTranscription(ctx context.Context, at *models.AudioTranscription) error {
	query := `
		UPDATE audio_transcriptions
		SET duration = $2, language = $3, transcript_text = $4, word_count = $5,
			status = $6, error_message = $7
		WHERE id = $1`

	_, err := db.ExecContext(ctx, query,
		at.ID, at.Duration, at.Language, at.TranscriptText,
		at.WordCount, at.Status, at.ErrorMessage,
	)
	return err
}

// UpdateAudioSummary updates the summary fields of an audio transcription (MTA-22).
func (db *DB) UpdateAudioSummary(ctx context.Context, at *models.AudioTranscription) error {
	query := `
		UPDATE audio_transcriptions
		SET content_type = $2, summary_text = $3, key_points = $4, action_items = $5,
			decisions = $6, summary_model = $7, summary_status = $8
		WHERE id = $1`

	_, err := db.ExecContext(ctx, query,
		at.ID, at.ContentType, at.SummaryText, at.KeyPoints,
		at.ActionItems, at.Decisions, at.SummaryModel, at.SummaryStatus,
	)
	return err
}

// ListAudioTranscriptions returns recent audio transcriptions.
func (db *DB) ListAudioTranscriptions(ctx context.Context, limit int, apiKeyID *string) ([]models.AudioTranscription, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	var transcriptions []models.AudioTranscription
	var err error
	var apiKeyValue interface{} = nil
	if apiKeyID != nil {
		apiKeyValue = *apiKeyID
	}
	err = db.SelectContext(ctx, &transcriptions,
		`SELECT * FROM audio_transcriptions
		 WHERE ($1::uuid IS NULL OR api_key_id = $1)
		 ORDER BY created_at DESC
		 LIMIT $2`,
		apiKeyValue, limit)

	if err != nil {
		return nil, fmt.Errorf("failed to list audio transcriptions: %w", err)
	}
	return transcriptions, nil
}

// SearchAudioTranscriptions performs full-text search across transcripts and summaries (MTA-25).
func (db *DB) SearchAudioTranscriptions(ctx context.Context, params models.AudioSearchParams) ([]models.AudioTranscription, int, error) {
	if params.Page < 1 {
		params.Page = 1
	}
	if params.PerPage < 1 || params.PerPage > 100 {
		params.PerPage = 20
	}

	var conditions []string
	var args []interface{}
	argNum := 1

	if params.Query != "" {
		conditions = append(conditions, fmt.Sprintf(
			"to_tsvector('english', transcript_text || ' ' || summary_text) @@ plainto_tsquery('english', $%d)", argNum))
		args = append(args, params.Query)
		argNum++
	}

	if params.ContentType != "" {
		conditions = append(conditions, fmt.Sprintf("content_type = $%d", argNum))
		args = append(args, params.ContentType)
		argNum++
	}

	whereClause := ""
	if len(conditions) > 0 {
		whereClause = "WHERE " + strings.Join(conditions, " AND ")
	}

	// Count total
	var total int
	countQuery := fmt.Sprintf("SELECT COUNT(*) FROM audio_transcriptions %s", whereClause)
	if err := db.GetContext(ctx, &total, countQuery, args...); err != nil {
		return nil, 0, fmt.Errorf("count query failed: %w", err)
	}

	// Fetch page
	offset := (params.Page - 1) * params.PerPage
	selectQuery := fmt.Sprintf(
		"SELECT * FROM audio_transcriptions %s ORDER BY created_at DESC LIMIT $%d OFFSET $%d",
		whereClause, argNum, argNum+1)
	args = append(args, params.PerPage, offset)

	var results []models.AudioTranscription
	if err := db.SelectContext(ctx, &results, selectQuery, args...); err != nil {
		return nil, 0, fmt.Errorf("search query failed: %w", err)
	}

	return results, total, nil
}

// DeleteAudioTranscription removes an audio transcription by ID.
func (db *DB) DeleteAudioTranscription(ctx context.Context, id string) error {
	result, err := db.ExecContext(ctx, `DELETE FROM audio_transcriptions WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("failed to delete audio transcription: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("audio transcription not found")
	}
	return nil
}

// --- PDF Extraction Operations (MTA-17) ---

// CreatePDFExtraction inserts a new PDF extraction record.
func (db *DB) CreatePDFExtraction(ctx context.Context, pe *models.PDFExtraction) error {
	query := `
		INSERT INTO pdf_extractions (filename, original_name, page_count, text_content, word_count, status, error_message, api_key_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		RETURNING id, created_at`

	return db.QueryRowContext(ctx, query,
		pe.Filename, pe.OriginalName, pe.PageCount, pe.TextContent,
		pe.WordCount, pe.Status, pe.ErrorMessage, pe.APIKeyID,
	).Scan(&pe.ID, &pe.CreatedAt)
}

// GetPDFExtraction retrieves a single PDF extraction by ID.
func (db *DB) GetPDFExtraction(ctx context.Context, id string) (*models.PDFExtraction, error) {
	var pe models.PDFExtraction
	err := db.GetContext(ctx, &pe, `SELECT * FROM pdf_extractions WHERE id = $1`, id)
	if err != nil {
		return nil, fmt.Errorf("pdf extraction not found: %w", err)
	}
	return &pe, nil
}

// ListPDFExtractions returns recent PDF extractions.
func (db *DB) ListPDFExtractions(ctx context.Context, limit int, apiKeyID *string) ([]models.PDFExtraction, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	var extractions []models.PDFExtraction
	var err error
	var apiKeyValue interface{} = nil
	if apiKeyID != nil {
		apiKeyValue = *apiKeyID
	}
	err = db.SelectContext(ctx, &extractions,
		`SELECT * FROM pdf_extractions
		 WHERE ($1::uuid IS NULL OR api_key_id = $1)
		 ORDER BY created_at DESC
		 LIMIT $2`,
		apiKeyValue, limit)

	if err != nil {
		return nil, fmt.Errorf("failed to list pdf extractions: %w", err)
	}
	return extractions, nil
}

// DeletePDFExtraction removes a PDF extraction by ID.
func (db *DB) DeletePDFExtraction(ctx context.Context, id string) error {
	result, err := db.ExecContext(ctx, `DELETE FROM pdf_extractions WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("failed to delete PDF extraction: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("PDF extraction not found")
	}
	return nil
}
