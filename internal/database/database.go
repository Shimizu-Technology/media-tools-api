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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/jmoiron/sqlx"

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
	return NewWithSimpleProtocol(databaseURL, true)
}

// NewWithSimpleProtocol creates a database connection and optionally disables
// prepared statements for PgBouncer-compatible pooled connections.
func NewWithSimpleProtocol(databaseURL string, useSimpleProtocol bool) (*DB, error) {
	cfg, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("failed to parse database URL: %w", err)
	}
	if useSimpleProtocol {
		// Neon pooled connections sit behind PgBouncer. Prepared statements can
		// intermittently fail there with "bind message supplies N parameters"
		// when a pooled server connection has stale statement state, so use pgx's
		// simple protocol for maximum pooler compatibility.
		cfg.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	}

	sqlDB := stdlib.OpenDB(*cfg)
	db := sqlx.NewDb(sqlDB, "pgx")
	if err := db.Ping(); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("failed to connect to database: %w", err)
	}

	// Configure connection pool for serverless PostgreSQL (Neon)
	// Go Pattern: The connection pool is managed by database/sql internally.
	// These settings prevent resource exhaustion and handle Neon's aggressive
	// connection timeouts (serverless PG closes idle connections quickly).
	db.SetMaxOpenConns(10)                  // Fewer connections for serverless
	db.SetMaxIdleConns(2)                   // Keep minimal idle connections
	db.SetConnMaxLifetime(2 * time.Minute)  // Recycle connections frequently
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
		INSERT INTO transcripts (youtube_url, youtube_id, title, channel_name, duration, language, transcript_text, word_count, status, error_message, batch_id, user_id, api_key_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
		RETURNING id, created_at, updated_at`

	// QueryRowContext executes a query that returns a single row.
	// Scan() reads the returned columns into our struct fields.
	return db.QueryRowContext(ctx, query,
		t.YouTubeURL, t.YouTubeID, t.Title, t.ChannelName,
		t.Duration, t.Language, t.TranscriptText, t.WordCount,
		t.Status, t.ErrorMessage, t.BatchID, t.UserID, t.APIKeyID,
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

// ListRecoverableTranscripts returns pending/processing transcripts that can be requeued after restart.
func (db *DB) ListRecoverableTranscripts(ctx context.Context, limit int) ([]models.Transcript, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}

	var rows []models.Transcript
	err := db.SelectContext(ctx, &rows, `
		SELECT * FROM transcripts
		WHERE status IN ('pending', 'processing')
		ORDER BY created_at ASC
		LIMIT $1
	`, limit)
	if err != nil {
		return nil, err
	}
	return rows, nil
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
	if params.UserID == nil && params.APIKeyID == nil {
		return []models.Transcript{}, 0, nil
	}

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

	if params.UserID != nil && params.APIKeyID != nil {
		conditions = append(conditions, fmt.Sprintf("(user_id = $%d OR api_key_id = $%d)", argNum, argNum+1))
		args = append(args, *params.UserID, *params.APIKeyID)
		argNum += 2
	} else if params.UserID != nil {
		conditions = append(conditions, fmt.Sprintf("user_id = $%d", argNum))
		args = append(args, *params.UserID)
		argNum++
	} else if params.APIKeyID != nil {
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
	if len(s.Evidence) == 0 {
		s.Evidence = []byte(`{}`)
	}
	query := `
		INSERT INTO summaries (
			id, transcript_id, model_used, prompt_used, summary_text, key_points,
			evidence, length, style, content_type, status, error_message
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
		RETURNING created_at, updated_at`

	return db.QueryRowContext(ctx, query,
		s.ID, s.TranscriptID, s.ModelUsed, s.PromptUsed,
		s.SummaryText, s.KeyPoints, s.Evidence, s.Length, s.Style,
		s.ContentType, s.Status, s.ErrorMessage,
	).Scan(&s.CreatedAt, &s.UpdatedAt)
}

// UpdateSummary persists the latest lifecycle state and generated content.
func (db *DB) UpdateSummary(ctx context.Context, s *models.Summary) error {
	if len(s.Evidence) == 0 {
		s.Evidence = []byte(`{}`)
	}
	result, err := db.ExecContext(ctx, `
		UPDATE summaries
		SET model_used = $2, prompt_used = $3, summary_text = $4,
			key_points = $5, evidence = $6, length = $7, style = $8, content_type = $9,
			status = $10, error_message = $11
		WHERE id = $1`,
		s.ID, s.ModelUsed, s.PromptUsed, s.SummaryText, s.KeyPoints, s.Evidence,
		s.Length, s.Style, s.ContentType, s.Status, s.ErrorMessage,
	)
	if err != nil {
		return fmt.Errorf("failed to update summary: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("summary not found")
	}
	return nil
}

// ListRecoverableSummaries returns jobs that were queued or interrupted.
func (db *DB) ListRecoverableSummaries(ctx context.Context, limit int) ([]models.Summary, error) {
	if limit <= 0 || limit > 1000 {
		limit = 200
	}
	var summaries []models.Summary
	if err := db.SelectContext(ctx, &summaries, `
		SELECT * FROM summaries
		WHERE status IN ('pending', 'processing')
		ORDER BY created_at ASC
		LIMIT $1`, limit); err != nil {
		return nil, fmt.Errorf("failed to list recoverable summaries: %w", err)
	}
	return summaries, nil
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
func (db *DB) GetOrCreateChatSession(ctx context.Context, itemType, itemID string, userID, apiKeyID *string) (*models.TranscriptChatSession, error) {
	var session models.TranscriptChatSession
	var ownerClause string
	var ownerArg interface{}
	// Prefer the API-key principal when both scopes are present. The content may
	// be visible to the owning user too, but API integrations keep an independent
	// chat history from the browser workspace.
	if apiKeyID != nil {
		ownerClause = "api_key_id = $3 AND user_id IS NULL"
		ownerArg = *apiKeyID
	} else if userID != nil {
		ownerClause = "user_id = $3 AND api_key_id IS NULL"
		ownerArg = *userID
	} else {
		return nil, fmt.Errorf("chat session owner is required")
	}
	selectQuery := fmt.Sprintf(`SELECT * FROM transcript_chat_sessions WHERE item_type = $1 AND item_id = $2 AND %s`, ownerClause)
	err := db.GetContext(ctx, &session, selectQuery, itemType, itemID, ownerArg)

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

	insertQuery := `
		INSERT INTO transcript_chat_sessions (item_type, item_id, transcript_id, user_id, api_key_id)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, created_at, updated_at`
	chatUserID, chatAPIKeyID := userID, apiKeyID
	if apiKeyID != nil {
		chatUserID = nil
	}
	err = db.QueryRowContext(ctx, insertQuery, itemType, itemID, transcriptID, chatUserID, chatAPIKeyID).
		Scan(&session.ID, &session.CreatedAt, &session.UpdatedAt)
	if apiKeyID != nil {
		session.APIKeyID = apiKeyID
	} else if userID != nil {
		session.UserID = userID
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

// DeleteChatSessionForActor removes a chat session for an owned item.
// Messages are deleted by the transcript_chat_messages ON DELETE CASCADE FK.
func (db *DB) DeleteChatSessionForActor(ctx context.Context, itemType, itemID string, userID, apiKeyID *string) error {
	var err error
	switch {
	case apiKeyID != nil:
		_, err = db.ExecContext(ctx, `
			DELETE FROM transcript_chat_sessions
			WHERE item_type = $1
			  AND item_id = $2
			  AND api_key_id = $3
			  AND user_id IS NULL`,
			itemType, itemID, *apiKeyID,
		)
	case userID != nil:
		_, err = db.ExecContext(ctx, `
			DELETE FROM transcript_chat_sessions
			WHERE item_type = $1
			  AND item_id = $2
			  AND user_id = $3
			  AND api_key_id IS NULL`,
			itemType, itemID, *userID,
		)
	default:
		return fmt.Errorf("chat session owner is required")
	}
	if err != nil {
		return fmt.Errorf("failed to delete chat session: %w", err)
	}
	return nil
}

// ListChatMessages returns chat messages for a session.
func (db *DB) ListChatMessages(ctx context.Context, sessionID string, limit int) ([]models.TranscriptChatMessage, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var messages []models.TranscriptChatMessage
	err := db.SelectContext(ctx, &messages,
		`SELECT * FROM (
			SELECT * FROM transcript_chat_messages
			WHERE session_id = $1
			ORDER BY created_at DESC
			LIMIT $2
		) recent
		ORDER BY created_at ASC`,
		sessionID, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to list chat messages: %w", err)
	}
	return messages, nil
}

// CreateChatMessage inserts a chat message.
func (db *DB) CreateChatMessage(ctx context.Context, msg *models.TranscriptChatMessage) error {
	if len(msg.Citations) == 0 {
		msg.Citations = []byte(`[]`)
	}
	query := `
		INSERT INTO transcript_chat_messages (session_id, role, content, model_used, citations)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, created_at`
	if err := db.QueryRowContext(ctx, query,
		msg.SessionID, msg.Role, msg.Content, msg.ModelUsed, msg.Citations,
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
		INSERT INTO api_keys (key_hash, key_prefix, name, active, rate_limit, user_id)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING id, created_at`

	return db.QueryRowContext(ctx, query,
		key.KeyHash, key.KeyPrefix, key.Name, key.Active, key.RateLimit, key.UserID,
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

// ListAPIKeysForActor returns only the API keys visible to the authenticated actor.
func (db *DB) ListAPIKeysForActor(ctx context.Context, userID, apiKeyID *string) ([]models.APIKey, error) {
	var keys []models.APIKey
	switch {
	case apiKeyID != nil:
		err := db.SelectContext(ctx, &keys,
			`SELECT * FROM api_keys WHERE id = $1 ORDER BY created_at DESC`, *apiKeyID)
		if err != nil {
			return nil, fmt.Errorf("failed to list API keys: %w", err)
		}
	case userID != nil:
		err := db.SelectContext(ctx, &keys,
			`SELECT * FROM api_keys WHERE user_id = $1 ORDER BY created_at DESC`, *userID)
		if err != nil {
			return nil, fmt.Errorf("failed to list API keys: %w", err)
		}
	default:
		return []models.APIKey{}, nil
	}

	if keys == nil {
		keys = []models.APIKey{}
	}
	return keys, nil
}

// RevokeAPIKeyForActor deactivates an API key only when it belongs to the authenticated actor.
func (db *DB) RevokeAPIKeyForActor(ctx context.Context, id string, userID, apiKeyID *string) error {
	var (
		result sql.Result
		err    error
	)

	switch {
	case apiKeyID != nil:
		// API-key-authenticated callers may only revoke the exact key they are
		// currently using. Keep the query simple and enforce the self-revoke rule
		// explicitly instead of relying on a tautological SQL predicate.
		if id != *apiKeyID {
			return fmt.Errorf("API key not found")
		}
		result, err = db.ExecContext(ctx,
			`UPDATE api_keys SET active = false WHERE id = $1`, id)
	case userID != nil:
		result, err = db.ExecContext(ctx,
			`UPDATE api_keys SET active = false WHERE id = $1 AND user_id = $2`, id, *userID)
	default:
		return fmt.Errorf("actor is required")
	}
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

const audioTranscriptionSelectColumns = `
	id,
	filename,
	original_name,
	COALESCE(audio_s3_key, '') AS audio_s3_key,
	COALESCE(audio_s3_status, 'pending') AS audio_s3_status,
	COALESCE(audio_s3_size, 0) AS audio_s3_size,
	COALESCE(processing_stage, 'queued') AS processing_stage,
	COALESCE(processing_progress, 0) AS processing_progress,
	COALESCE(retry_count, 0) AS retry_count,
	duration,
	language,
	transcript_text,
	word_count,
	status,
	error_message,
	COALESCE(quality_warning, '') AS quality_warning,
	COALESCE(omitted_ranges, '[]'::jsonb) AS omitted_ranges,
	content_type,
	summary_text,
	key_points,
	action_items,
	decisions,
	summary_model,
	COALESCE(summary_length, 'medium') AS summary_length,
	summary_status,
	COALESCE(summary_evidence, '{}'::jsonb) AS summary_evidence,
	COALESCE(summary_error_message, '') AS summary_error_message,
	user_id,
	api_key_id,
	created_at
`

// CreateAudioTranscription inserts a new audio transcription record.
func (db *DB) CreateAudioTranscription(ctx context.Context, at *models.AudioTranscription) error {
	query := `
		INSERT INTO audio_transcriptions (
			filename, original_name, audio_s3_key, audio_s3_status, audio_s3_size,
			processing_stage, processing_progress, retry_count,
			duration, language, transcript_text, word_count, status, error_message, content_type, user_id, api_key_id
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17)
		RETURNING id, created_at`

	if at.ContentType == "" {
		at.ContentType = models.ContentGeneral
	}
	if at.ProcessingStage == "" {
		at.ProcessingStage = "queued"
	}

	return db.QueryRowContext(ctx, query,
		at.Filename, at.OriginalName, at.AudioS3Key, at.AudioS3Status, at.AudioS3Size,
		at.ProcessingStage, at.ProcessingProgress, at.RetryCount,
		at.Duration, at.Language, at.TranscriptText, at.WordCount, at.Status, at.ErrorMessage,
		at.ContentType, at.UserID, at.APIKeyID,
	).Scan(&at.ID, &at.CreatedAt)
}

// CreateAudioTranscriptionWithJob stores a local upload and its exact worker
// payload in one transaction. Migration 038 creates the queue row from the
// INSERT trigger; the second statement fills in the process-local temporary
// path before any worker can observe or claim the committed job.
func (db *DB) CreateAudioTranscriptionWithJob(ctx context.Context, at *models.AudioTranscription, tempFilePath string) error {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin audio transcription transaction: %w", err)
	}
	defer tx.Rollback()

	query := `
		INSERT INTO audio_transcriptions (
			filename, original_name, audio_s3_key, audio_s3_status, audio_s3_size,
			processing_stage, processing_progress, retry_count,
			duration, language, transcript_text, word_count, status, error_message, content_type, user_id, api_key_id
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17)
		RETURNING id, created_at`

	if at.ContentType == "" {
		at.ContentType = models.ContentGeneral
	}
	if at.ProcessingStage == "" {
		at.ProcessingStage = "queued"
	}

	if err := tx.QueryRowContext(ctx, query,
		at.Filename, at.OriginalName, at.AudioS3Key, at.AudioS3Status, at.AudioS3Size,
		at.ProcessingStage, at.ProcessingProgress, at.RetryCount,
		at.Duration, at.Language, at.TranscriptText, at.WordCount, at.Status, at.ErrorMessage,
		at.ContentType, at.UserID, at.APIKeyID,
	).Scan(&at.ID, &at.CreatedAt); err != nil {
		return fmt.Errorf("create audio transcription: %w", err)
	}

	result, err := tx.ExecContext(ctx, `
		UPDATE background_jobs
		SET payload = jsonb_build_object(
				'audio_id', $1::text,
				'temp_file_path', $2::text,
				'audio_s3_key', $3::text,
				'original_name', $4::text
			),
			updated_at = NOW()
		WHERE job_type = 'audio_transcription'
		  AND resource_id = $1
		  AND status = 'queued'`,
		at.ID, tempFilePath, at.AudioS3Key, at.OriginalName,
	)
	if err != nil {
		return fmt.Errorf("prepare audio transcription job: %w", err)
	}
	if rows, _ := result.RowsAffected(); rows != 1 {
		return fmt.Errorf("prepare audio transcription job: queue trigger did not create a queued job")
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit audio transcription transaction: %w", err)
	}
	return nil
}

// GetAudioTranscription retrieves a single audio transcription by ID.
func (db *DB) GetAudioTranscription(ctx context.Context, id string) (*models.AudioTranscription, error) {
	var at models.AudioTranscription
	query := fmt.Sprintf(`SELECT %s FROM audio_transcriptions WHERE id = $1`, audioTranscriptionSelectColumns)
	err := db.GetContext(ctx, &at, query, id)
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
			status = $6, error_message = $7,
			processing_stage = $8, processing_progress = $9, retry_count = $10,
			quality_warning = $11, omitted_ranges = $12
		WHERE id = $1`

	_, err := db.ExecContext(ctx, query,
		at.ID, at.Duration, at.Language, at.TranscriptText,
		at.WordCount, at.Status, at.ErrorMessage, at.ProcessingStage, at.ProcessingProgress, at.RetryCount,
		at.QualityWarning, at.OmittedRanges,
	)
	return err
}

// UpdateAudioTranscriptionWithSummary atomically updates transcription and summary fields.
// Use this when re-transcription needs to clear or restore both payloads as one row mutation.
func (db *DB) UpdateAudioTranscriptionWithSummary(ctx context.Context, at *models.AudioTranscription) error {
	if len(at.SummaryEvidence) == 0 {
		at.SummaryEvidence = []byte(`{}`)
	}
	query := `
		UPDATE audio_transcriptions
		SET duration = $2, language = $3, transcript_text = $4, word_count = $5,
			status = $6, error_message = $7,
			processing_stage = $8, processing_progress = $9, retry_count = $10,
			content_type = $11, summary_text = $12, key_points = $13,
			action_items = $14, decisions = $15, summary_model = $16,
			summary_length = $17, summary_status = $18, summary_evidence = $19,
			summary_error_message = $20, quality_warning = $21, omitted_ranges = $22
		WHERE id = $1`

	result, err := db.ExecContext(ctx, query,
		at.ID, at.Duration, at.Language, at.TranscriptText,
		at.WordCount, at.Status, at.ErrorMessage, at.ProcessingStage, at.ProcessingProgress, at.RetryCount,
		at.ContentType, at.SummaryText, at.KeyPoints, at.ActionItems, at.Decisions, at.SummaryModel, at.SummaryLength,
		at.SummaryStatus, at.SummaryEvidence, at.SummaryErrorMessage, at.QualityWarning, at.OmittedRanges,
	)
	if err != nil {
		return err
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("audio transcription not found")
	}
	return nil
}

// PrepareAudioRetranscriptionForActor atomically swaps a completed/failed audio
// row to the provided pending state and returns the prior row for rollback.
// The status predicate is part of the UPDATE transaction so simultaneous
// re-transcribe clicks cannot enqueue multiple jobs for the same recording.
func (db *DB) PrepareAudioRetranscriptionForActor(ctx context.Context, at *models.AudioTranscription, userID, apiKeyID *string) (*models.AudioTranscription, bool, error) {
	if at == nil {
		return nil, false, fmt.Errorf("audio transcription is required")
	}
	if len(at.SummaryEvidence) == 0 {
		at.SummaryEvidence = []byte(`{}`)
	}

	const updateSQL = `
		updated AS (
			UPDATE audio_transcriptions AS a
			SET duration = $3, language = $4, transcript_text = $5, word_count = $6,
				status = $7, error_message = $8,
				processing_stage = $9, processing_progress = $10, retry_count = $11,
				content_type = $12, summary_text = $13, key_points = $14,
				action_items = $15, decisions = $16, summary_model = $17,
				summary_length = $18, summary_status = $19, summary_evidence = $20,
				summary_error_message = $21, quality_warning = $22, omitted_ranges = $23
			FROM previous AS p
			WHERE a.id = p.id
			RETURNING a.id
		)
		SELECT p.* FROM previous AS p INNER JOIN updated AS u ON p.id = u.id`

	var query string
	var ownerArg string
	switch {
	case apiKeyID != nil:
		query = `
			WITH previous AS (
				SELECT ` + audioTranscriptionSelectColumns + ` FROM audio_transcriptions
				WHERE id = $1
				  AND api_key_id = $2
				  AND status IN ('completed', 'failed')
				FOR UPDATE
			),
			` + updateSQL
		ownerArg = *apiKeyID
	case userID != nil:
		query = `
			WITH previous AS (
				SELECT ` + audioTranscriptionSelectColumns + ` FROM audio_transcriptions
				WHERE id = $1
				  AND user_id = $2
				  AND status IN ('completed', 'failed')
				FOR UPDATE
			),
			` + updateSQL
		ownerArg = *userID
	default:
		return nil, false, fmt.Errorf("actor is required")
	}

	var previous models.AudioTranscription
	err := db.GetContext(ctx, &previous, query,
		at.ID, ownerArg, at.Duration, at.Language, at.TranscriptText,
		at.WordCount, at.Status, at.ErrorMessage, at.ProcessingStage, at.ProcessingProgress, at.RetryCount,
		at.ContentType, at.SummaryText, at.KeyPoints, at.ActionItems, at.Decisions, at.SummaryModel, at.SummaryLength,
		at.SummaryStatus, at.SummaryEvidence, at.SummaryErrorMessage, at.QualityWarning, at.OmittedRanges,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return &previous, true, nil
}

// UpdateAudioTranscriptionIfActive saves terminal worker results only while a job is still active.
func (db *DB) UpdateAudioTranscriptionIfActive(ctx context.Context, at *models.AudioTranscription) (bool, error) {
	query := `
		UPDATE audio_transcriptions
		SET duration = $2, language = $3, transcript_text = $4, word_count = $5,
			status = $6, error_message = $7,
			processing_stage = $8, processing_progress = $9, retry_count = $10,
			quality_warning = $11, omitted_ranges = $12
		WHERE id = $1
		  AND status IN ('pending', 'processing')`

	result, err := db.ExecContext(ctx, query,
		at.ID, at.Duration, at.Language, at.TranscriptText,
		at.WordCount, at.Status, at.ErrorMessage, at.ProcessingStage, at.ProcessingProgress, at.RetryCount,
		at.QualityWarning, at.OmittedRanges,
	)
	if err != nil {
		return false, err
	}
	rows, _ := result.RowsAffected()
	return rows > 0, nil
}

// UpdateAudioProcessing updates processing stage/progress without changing transcript payload.
func (db *DB) UpdateAudioProcessing(ctx context.Context, id, stage string, progress int) error {
	if progress < 0 {
		progress = 0
	}
	if progress > 100 {
		progress = 100
	}
	_, err := db.ExecContext(ctx,
		`UPDATE audio_transcriptions SET processing_stage = $2, processing_progress = $3 WHERE id = $1`,
		id, stage, progress,
	)
	return err
}

// IncrementAudioRetryCount increments retry_count and returns the new value.
func (db *DB) IncrementAudioRetryCount(ctx context.Context, id string) (int, error) {
	var retryCount int
	err := db.QueryRowContext(ctx,
		`UPDATE audio_transcriptions SET retry_count = retry_count + 1 WHERE id = $1 RETURNING retry_count`,
		id,
	).Scan(&retryCount)
	if err != nil {
		return 0, err
	}
	return retryCount, nil
}

// ListRecoverableAudioTranscriptions returns pending/processing jobs that can be requeued after restart.
func (db *DB) ListRecoverableAudioTranscriptions(ctx context.Context, limit int) ([]models.AudioTranscription, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	var rows []models.AudioTranscription
	err := db.SelectContext(ctx, &rows, `
		SELECT `+audioTranscriptionSelectColumns+` FROM audio_transcriptions
		WHERE status IN ('pending', 'processing')
		ORDER BY created_at ASC
		LIMIT $1
	`, limit)
	if err != nil {
		return nil, err
	}
	return rows, nil
}

// UpdateAudioSummary updates the summary fields of an audio transcription (MTA-22).
func (db *DB) UpdateAudioSummary(ctx context.Context, at *models.AudioTranscription) error {
	if len(at.SummaryEvidence) == 0 {
		at.SummaryEvidence = []byte(`{}`)
	}
	query := `
		UPDATE audio_transcriptions
		SET content_type = $2, summary_text = $3, key_points = $4, action_items = $5,
			decisions = $6, summary_model = $7, summary_length = $8,
			summary_status = $9, summary_evidence = $10, summary_error_message = $11
		WHERE id = $1`

	_, err := db.ExecContext(ctx, query,
		at.ID, at.ContentType, at.SummaryText, at.KeyPoints,
		at.ActionItems, at.Decisions, at.SummaryModel, at.SummaryLength,
		at.SummaryStatus, at.SummaryEvidence, at.SummaryErrorMessage,
	)
	return err
}

// ListRecoverableAudioSummaries returns summary jobs interrupted by a restart.
func (db *DB) ListRecoverableAudioSummaries(ctx context.Context, limit int) ([]models.AudioTranscription, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	var rows []models.AudioTranscription
	err := db.SelectContext(ctx, &rows, `
		SELECT `+audioTranscriptionSelectColumns+`
		FROM audio_transcriptions
		WHERE summary_status IN ('pending', 'processing')
		  AND status = 'completed'
		ORDER BY created_at ASC
		LIMIT $1`,
		limit,
	)
	if err != nil {
		return nil, fmt.Errorf("list recoverable audio summaries: %w", err)
	}
	return rows, nil
}

// ListAudioTranscriptions returns recent audio transcriptions.
func (db *DB) ListAudioTranscriptions(ctx context.Context, limit int, userID, apiKeyID *string) ([]models.AudioTranscription, error) {
	return db.listAudioTranscriptions(ctx, limit, userID, apiKeyID, "")
}

// ListAudioTranscriptionsByStatus keeps polling payloads focused on the small
// active subset instead of repeatedly returning completed transcript bodies.
func (db *DB) ListAudioTranscriptionsByStatus(ctx context.Context, limit int, userID, apiKeyID *string, status string) ([]models.AudioTranscription, error) {
	return db.listAudioTranscriptions(ctx, limit, userID, apiKeyID, status)
}

func (db *DB) listAudioTranscriptions(ctx context.Context, limit int, userID, apiKeyID *string, status string) ([]models.AudioTranscription, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	var transcriptions []models.AudioTranscription
	var whereClause string
	var args []interface{}
	if userID != nil && apiKeyID != nil {
		whereClause = "WHERE (user_id = $1 OR api_key_id = $2)"
		args = append(args, *userID, *apiKeyID)
	} else if userID != nil {
		whereClause = "WHERE user_id = $1"
		args = append(args, *userID)
	} else if apiKeyID != nil {
		whereClause = "WHERE api_key_id = $1"
		args = append(args, *apiKeyID)
	} else {
		return []models.AudioTranscription{}, nil
	}
	if status == "active" {
		whereClause += " AND status IN ('pending', 'processing')"
	} else if status != "" {
		whereClause += fmt.Sprintf(" AND status = $%d", len(args)+1)
		args = append(args, status)
	}
	query := fmt.Sprintf(`SELECT %s FROM audio_transcriptions %s ORDER BY created_at DESC LIMIT $%d`,
		audioTranscriptionSelectColumns, whereClause, len(args)+1,
	)
	args = append(args, limit)
	err := db.SelectContext(ctx, &transcriptions, query, args...)

	if err != nil {
		return nil, fmt.Errorf("failed to list audio transcriptions: %w", err)
	}
	return transcriptions, nil
}

// SearchAudioTranscriptions performs full-text search across transcripts and summaries (MTA-25).
func (db *DB) SearchAudioTranscriptions(ctx context.Context, params models.AudioSearchParams, userID, apiKeyID *string) ([]models.AudioTranscription, int, error) {
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
	if userID != nil && apiKeyID != nil {
		conditions = append(conditions, fmt.Sprintf("(user_id = $%d OR api_key_id = $%d)", argNum, argNum+1))
		args = append(args, *userID, *apiKeyID)
		argNum += 2
	} else if userID != nil {
		conditions = append(conditions, fmt.Sprintf("user_id = $%d", argNum))
		args = append(args, *userID)
		argNum++
	} else if apiKeyID != nil {
		conditions = append(conditions, fmt.Sprintf("api_key_id = $%d", argNum))
		args = append(args, *apiKeyID)
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
		"SELECT %s FROM audio_transcriptions %s ORDER BY created_at DESC LIMIT $%d OFFSET $%d",
		audioTranscriptionSelectColumns, whereClause, argNum, argNum+1)
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
		INSERT INTO pdf_extractions (filename, original_name, page_count, text_content, word_count, status, error_message, user_id, api_key_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		RETURNING id, created_at`

	return db.QueryRowContext(ctx, query,
		pe.Filename, pe.OriginalName, pe.PageCount, pe.TextContent,
		pe.WordCount, pe.Status, pe.ErrorMessage, pe.UserID, pe.APIKeyID,
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
func (db *DB) ListPDFExtractions(ctx context.Context, limit int, userID, apiKeyID *string) ([]models.PDFExtraction, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	var extractions []models.PDFExtraction
	var whereClause string
	var args []interface{}
	if userID != nil && apiKeyID != nil {
		whereClause = "WHERE user_id = $1 OR api_key_id = $2"
		args = append(args, *userID, *apiKeyID)
	} else if userID != nil {
		whereClause = "WHERE user_id = $1"
		args = append(args, *userID)
	} else if apiKeyID != nil {
		whereClause = "WHERE api_key_id = $1"
		args = append(args, *apiKeyID)
	} else {
		return []models.PDFExtraction{}, nil
	}
	query := fmt.Sprintf(`SELECT * FROM pdf_extractions %s ORDER BY created_at DESC LIMIT $%d`,
		whereClause, len(args)+1,
	)
	args = append(args, limit)
	err := db.SelectContext(ctx, &extractions, query, args...)

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
