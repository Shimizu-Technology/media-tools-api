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
	current := models.LibraryPreferences{Tags: json.RawMessage(`[]`)}
	if userID == nil && apiKeyID == nil {
		return current, fmt.Errorf("actor is required")
	}

	var tagsJSON interface{}
	if req.Tags != nil {
		encoded, err := json.Marshal(req.Tags)
		if err != nil {
			return current, fmt.Errorf("encode library preference tags: %w", err)
		}
		// Pass JSON as text. lib/pq treats []byte as bytea, whose encoded form is
		// not valid input for the explicit jsonb cast used by the atomic UPSERT.
		tagsJSON = string(encoded)
	}

	// Each nullable request value is merged inside the UPSERT itself. This keeps
	// partial updates atomic across tabs, devices, and API clients instead of
	// performing a read-then-write that can lose a concurrent field change.
	var query string
	var ownerID *string
	if userID != nil {
		ownerID = userID
		query = `INSERT INTO media_item_preferences (user_id, item_type, item_id, favorite, archived, tags)
			VALUES ($1, $2, $3, COALESCE($4::boolean, false), COALESCE($5::boolean, false), COALESCE($6::jsonb, '[]'::jsonb))
			ON CONFLICT (user_id, item_type, item_id) WHERE user_id IS NOT NULL
			DO UPDATE SET
				favorite = COALESCE($4::boolean, media_item_preferences.favorite),
				archived = COALESCE($5::boolean, media_item_preferences.archived),
				tags = COALESCE($6::jsonb, media_item_preferences.tags),
				updated_at = NOW()
			RETURNING favorite, archived, tags`
	} else {
		ownerID = apiKeyID
		query = `INSERT INTO media_item_preferences (api_key_id, item_type, item_id, favorite, archived, tags)
			VALUES ($1, $2, $3, COALESCE($4::boolean, false), COALESCE($5::boolean, false), COALESCE($6::jsonb, '[]'::jsonb))
			ON CONFLICT (api_key_id, item_type, item_id) WHERE api_key_id IS NOT NULL
			DO UPDATE SET
				favorite = COALESCE($4::boolean, media_item_preferences.favorite),
				archived = COALESCE($5::boolean, media_item_preferences.archived),
				tags = COALESCE($6::jsonb, media_item_preferences.tags),
				updated_at = NOW()
			RETURNING favorite, archived, tags`
	}

	if err := db.GetContext(ctx, &current, query, ownerID, itemType, itemID, req.Favorite, req.Archived, tagsJSON); err != nil {
		return current, fmt.Errorf("update library preferences: %w", err)
	}
	return current, nil
}
