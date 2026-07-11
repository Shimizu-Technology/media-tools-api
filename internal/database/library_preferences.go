package database

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func (db *DB) GetLibraryPreferences(ctx context.Context, itemType, itemID string, userID, apiKeyID *string) (models.LibraryPreferences, error) {
	preferences := models.LibraryPreferences{Tags: json.RawMessage(`[]`)}
	if userID == nil && apiKeyID == nil {
		return preferences, fmt.Errorf("actor is required")
	}
	err := db.GetContext(ctx, &preferences, `
		SELECT favorite, archived, tags
		FROM media_item_preferences
		WHERE item_type = $1 AND item_id = $2
		  AND (($3::uuid IS NOT NULL AND user_id = $3)
		    OR ($4::uuid IS NOT NULL AND api_key_id = $4))`, itemType, itemID, userID, apiKeyID)
	if errors.Is(err, sql.ErrNoRows) {
		// Preferences are optional. An item without a row uses the zero-value state.
		return models.LibraryPreferences{Tags: json.RawMessage(`[]`)}, nil
	}
	if err != nil {
		return preferences, fmt.Errorf("get library preferences: %w", err)
	}
	return preferences, nil
}

func (db *DB) UpdateLibraryPreferences(ctx context.Context, itemType, itemID string, userID, apiKeyID *string, req models.UpdateLibraryPreferencesRequest) (models.LibraryPreferences, error) {
	current, err := db.GetLibraryPreferences(ctx, itemType, itemID, userID, apiKeyID)
	if err != nil {
		return current, err
	}
	if req.Favorite != nil {
		current.Favorite = *req.Favorite
	}
	if req.Archived != nil {
		current.Archived = *req.Archived
	}
	if req.Tags != nil {
		current.Tags, _ = json.Marshal(req.Tags)
	}
	if len(current.Tags) == 0 {
		current.Tags = json.RawMessage(`[]`)
	}

	var query string
	var ownerID *string
	if userID != nil {
		ownerID = userID
		query = `INSERT INTO media_item_preferences (user_id, item_type, item_id, favorite, archived, tags)
			VALUES ($1, $2, $3, $4, $5, $6)
			ON CONFLICT (user_id, item_type, item_id) WHERE user_id IS NOT NULL
			DO UPDATE SET favorite = EXCLUDED.favorite, archived = EXCLUDED.archived, tags = EXCLUDED.tags, updated_at = NOW()
			RETURNING favorite, archived, tags`
	} else {
		ownerID = apiKeyID
		query = `INSERT INTO media_item_preferences (api_key_id, item_type, item_id, favorite, archived, tags)
			VALUES ($1, $2, $3, $4, $5, $6)
			ON CONFLICT (api_key_id, item_type, item_id) WHERE api_key_id IS NOT NULL
			DO UPDATE SET favorite = EXCLUDED.favorite, archived = EXCLUDED.archived, tags = EXCLUDED.tags, updated_at = NOW()
			RETURNING favorite, archived, tags`
	}

	if err := db.GetContext(ctx, &current, query, ownerID, itemType, itemID, current.Favorite, current.Archived, current.Tags); err != nil {
		return current, fmt.Errorf("update library preferences: %w", err)
	}
	return current, nil
}
