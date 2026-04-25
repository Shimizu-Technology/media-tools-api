// users.go handles user-related database operations (MTA-20).
package database

import (
	"context"
	"fmt"
	"log"

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

// GetUserByClerkID retrieves a user by their Clerk user ID.
func (db *DB) GetUserByClerkID(ctx context.Context, clerkID string) (*models.User, error) {
	var u models.User
	err := db.GetContext(ctx, &u, `SELECT * FROM users WHERE clerk_id = $1`, clerkID)
	if err != nil {
		return nil, fmt.Errorf("user not found: %w", err)
	}
	return &u, nil
}

// CreateUserFromClerk creates a new user from Clerk authentication (no password).
func (db *DB) CreateUserFromClerk(ctx context.Context, u *models.User) error {
	if u.ClerkID == nil || *u.ClerkID == "" {
		return fmt.Errorf("clerk_id is required for CreateUserFromClerk")
	}

	query := `
		INSERT INTO users (email, name, clerk_id)
		VALUES ($1, $2, $3)
		RETURNING id, created_at`

	return db.QueryRowContext(ctx, query,
		u.Email, u.Name, u.ClerkID,
	).Scan(&u.ID, &u.CreatedAt)
}

// LinkClerkIDToUser updates an existing user's clerk_id (email migration path).
// Used when a legacy email/password user signs in via Clerk for the first time.
func (db *DB) LinkClerkIDToUser(ctx context.Context, userID, clerkID string) error {
	_, err := db.ExecContext(ctx,
		`UPDATE users SET clerk_id = $1 WHERE id = $2`,
		clerkID, userID)
	return err
}

// FindOrCreateClerkUser handles the invite-only / migration flow:
// 1. Find by clerk_id (returning Clerk user) → return
// 2. Find by email (legacy user migrating to Clerk) → link clerk_id, return
// 3. Not found → create new user
func (db *DB) FindOrCreateClerkUser(ctx context.Context, clerkID, email, name string) (*models.User, error) {
	// 1. Already linked to Clerk
	user, err := db.GetUserByClerkID(ctx, clerkID)
	if err == nil {
		return user, nil
	}

	// 2. Existing user with same email (migration path)
	if email != "" {
		existing, err := db.GetUserByEmail(ctx, email)
		if err == nil {
			// Link Clerk ID to existing account
			if linkErr := db.LinkClerkIDToUser(ctx, existing.ID, clerkID); linkErr != nil {
				return nil, fmt.Errorf("failed to link clerk_id to existing user: %w", linkErr)
			}
			existing.ClerkID = &clerkID
			// Update name if provided
			if name != "" {
				if _, execErr := db.ExecContext(ctx, `UPDATE users SET name = $1 WHERE id = $2`, name, existing.ID); execErr != nil {
					log.Printf("⚠️ Failed to update name for user %s: %v", existing.ID, execErr)
				} else {
					existing.Name = name
				}
			}
			return existing, nil
		}
	}

	// 3. Brand new user
	u := &models.User{
		Email:   email,
		Name:    name,
		ClerkID: &clerkID,
	}
	if err := db.CreateUserFromClerk(ctx, u); err != nil {
		// Race condition: another request may have just created this user.
		// Retry the clerk_id lookup before giving up.
		if retryUser, retryErr := db.GetUserByClerkID(ctx, clerkID); retryErr == nil {
			return retryUser, nil
		}
		return nil, fmt.Errorf("failed to create user: %w", err)
	}
	return u, nil
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

// UserOwnsWorkspaceItem returns true when the given user owns the referenced item.
func (db *DB) UserOwnsWorkspaceItem(ctx context.Context, userID, itemType, itemID string) (bool, error) {
	var exists bool
	switch itemType {
	case "transcript":
		err := db.GetContext(ctx, &exists, `
			SELECT EXISTS(
				SELECT 1 FROM transcripts WHERE id = $1 AND user_id = $2
			)`, itemID, userID)
		return exists, err
	case "audio":
		err := db.GetContext(ctx, &exists, `
			SELECT EXISTS(
				SELECT 1 FROM audio_transcriptions WHERE id = $1 AND user_id = $2
			)`, itemID, userID)
		return exists, err
	case "pdf":
		err := db.GetContext(ctx, &exists, `
			SELECT EXISTS(
				SELECT 1 FROM pdf_extractions WHERE id = $1 AND user_id = $2
			)`, itemID, userID)
		return exists, err
	default:
		return false, fmt.Errorf("unsupported workspace item type: %s", itemType)
	}
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
		 WHERE wi.user_id = $1 AND t.user_id = wi.user_id
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
		 WHERE wi.user_id = $1 AND a.user_id = wi.user_id
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
		 WHERE wi.user_id = $1 AND p.user_id = wi.user_id
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
