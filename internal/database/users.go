// users.go handles user-related database operations (MTA-20).
package database

import (
	"context"
	"fmt"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// CreateUser inserts a new user record.
func (db *DB) CreateUser(ctx context.Context, u *models.User) error {
	query := `
		INSERT INTO users (email, password_hash, name)
		VALUES ($1, $2, $3)
		RETURNING id, created_at`

	return db.QueryRowContext(ctx, query,
		u.Email, u.PasswordHash, u.Name,
	).Scan(&u.ID, &u.CreatedAt)
}

// GetUserByEmail retrieves a user by email address.
func (db *DB) GetUserByEmail(ctx context.Context, email string) (*models.User, error) {
	var u models.User
	err := db.GetContext(ctx, &u, `SELECT * FROM users WHERE email = $1`, email)
	if err != nil {
		return nil, fmt.Errorf("user not found: %w", err)
	}
	return &u, nil
}

// GetUserByID retrieves a user by ID.
func (db *DB) GetUserByID(ctx context.Context, id string) (*models.User, error) {
	var u models.User
	err := db.GetContext(ctx, &u, `SELECT * FROM users WHERE id = $1`, id)
	if err != nil {
		return nil, fmt.Errorf("user not found: %w", err)
	}
	return &u, nil
}

// --- Workspace Operations ---

// SaveWorkspaceItem adds an item to a user's workspace.
func (db *DB) SaveWorkspaceItem(ctx context.Context, item *models.WorkspaceItem) error {
	query := `
		INSERT INTO workspace_items (user_id, item_type, item_id)
		VALUES ($1, $2, $3)
		ON CONFLICT (user_id, item_type, item_id) DO NOTHING
		RETURNING id, created_at`

	return db.QueryRowContext(ctx, query,
		item.UserID, item.ItemType, item.ItemID,
	).Scan(&item.ID, &item.CreatedAt)
}

// RemoveWorkspaceItem removes an item from a user's workspace.
func (db *DB) RemoveWorkspaceItem(ctx context.Context, userID, itemType, itemID string) error {
	_, err := db.ExecContext(ctx,
		`DELETE FROM workspace_items WHERE user_id = $1 AND item_type = $2 AND item_id = $3`,
		userID, itemType, itemID)
	return err
}

// GetWorkspaceItems returns all workspace items for a user.
func (db *DB) GetWorkspaceItems(ctx context.Context, userID string) ([]models.WorkspaceItem, error) {
	var items []models.WorkspaceItem
	err := db.SelectContext(ctx, &items,
		`SELECT * FROM workspace_items WHERE user_id = $1 ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, fmt.Errorf("failed to get workspace items: %w", err)
	}
	return items, nil
}

// GetWorkspaceTranscripts returns transcripts saved to a user's workspace.
func (db *DB) GetWorkspaceTranscripts(ctx context.Context, userID string) ([]models.Transcript, error) {
	var transcripts []models.Transcript
	err := db.SelectContext(ctx, &transcripts,
		`SELECT t.* FROM transcripts t
		 JOIN workspace_items wi ON wi.item_id = t.id AND wi.item_type = 'transcript'
		 WHERE wi.user_id = $1
		 ORDER BY wi.created_at DESC LIMIT 50`, userID)
	if err != nil {
		return nil, fmt.Errorf("failed to get workspace transcripts: %w", err)
	}
	return transcripts, nil
}

// GetWorkspaceAudio returns audio transcriptions saved to a user's workspace.
func (db *DB) GetWorkspaceAudio(ctx context.Context, userID string) ([]models.AudioTranscription, error) {
	var audio []models.AudioTranscription
	err := db.SelectContext(ctx, &audio,
		`SELECT a.* FROM audio_transcriptions a
		 JOIN workspace_items wi ON wi.item_id = a.id AND wi.item_type = 'audio'
		 WHERE wi.user_id = $1
		 ORDER BY wi.created_at DESC LIMIT 50`, userID)
	if err != nil {
		return nil, fmt.Errorf("failed to get workspace audio: %w", err)
	}
	return audio, nil
}

// GetWorkspacePDFs returns PDF extractions saved to a user's workspace.
func (db *DB) GetWorkspacePDFs(ctx context.Context, userID string) ([]models.PDFExtraction, error) {
	var pdfs []models.PDFExtraction
	err := db.SelectContext(ctx, &pdfs,
		`SELECT p.* FROM pdf_extractions p
		 JOIN workspace_items wi ON wi.item_id = p.id AND wi.item_type = 'pdf'
		 WHERE wi.user_id = $1
		 ORDER BY wi.created_at DESC LIMIT 50`, userID)
	if err != nil {
		return nil, fmt.Errorf("failed to get workspace PDFs: %w", err)
	}
	return pdfs, nil
}

// LinkAPIKeyToUser associates an API key with a user.
func (db *DB) LinkAPIKeyToUser(ctx context.Context, apiKeyID, userID string) error {
	_, err := db.ExecContext(ctx, `UPDATE api_keys SET user_id = $2 WHERE id = $1`, apiKeyID, userID)
	return err
}
