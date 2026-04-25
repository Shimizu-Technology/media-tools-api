// collections.go handles collection CRUD operations.
// collections.go handles collection CRUD and item management.
package database

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// CreateCollection inserts a new collection.
func (db *DB) CreateCollection(ctx context.Context, c *models.Collection) error {
	query := `
		INSERT INTO collections (name, description, user_id, api_key_id)
		VALUES ($1, $2, $3, $4)
		RETURNING id, created_at, updated_at`

	return db.QueryRowContext(ctx, query,
		c.Name, c.Description, c.UserID, c.APIKeyID,
	).Scan(&c.ID, &c.CreatedAt, &c.UpdatedAt)
}

// ListCollections returns all collections for a user or API key.
func (db *DB) ListCollections(ctx context.Context, userID, apiKeyID *string) ([]models.Collection, error) {
	query := `
		SELECT c.id, c.name, c.description, c.user_id, c.api_key_id,
		       c.created_at, c.updated_at,
		       COALESCE(ci.cnt, 0) AS item_count
		FROM collections c
		LEFT JOIN (
			SELECT collection_id, COUNT(*) AS cnt
			FROM collection_items
			GROUP BY collection_id
		) ci ON ci.collection_id = c.id
		WHERE ($1::uuid IS NOT NULL AND c.user_id = $1)
		   OR ($2::uuid IS NOT NULL AND c.api_key_id = $2)
		ORDER BY c.updated_at DESC`

	var collections []models.Collection
	err := db.SelectContext(ctx, &collections, query, userID, apiKeyID)
	if err != nil {
		return nil, fmt.Errorf("list collections: %w", err)
	}
	if collections == nil {
		collections = []models.Collection{}
	}
	return collections, nil
}

// GetCollection returns a single collection by ID with ownership check.
func (db *DB) GetCollection(ctx context.Context, id string, userID, apiKeyID *string) (*models.Collection, error) {
	query := `
		SELECT c.id, c.name, c.description, c.user_id, c.api_key_id,
		       c.created_at, c.updated_at,
		       COALESCE(ci.cnt, 0) AS item_count
		FROM collections c
		LEFT JOIN (
			SELECT collection_id, COUNT(*) AS cnt
			FROM collection_items
			GROUP BY collection_id
		) ci ON ci.collection_id = c.id
		WHERE c.id = $1
		  AND (($2::uuid IS NOT NULL AND c.user_id = $2)
		    OR ($3::uuid IS NOT NULL AND c.api_key_id = $3))`

	var c models.Collection
	err := db.GetContext(ctx, &c, query, id, userID, apiKeyID)
	if err != nil {
		return nil, fmt.Errorf("collection not found: %w", err)
	}
	return &c, nil
}

// UpdateCollection updates a collection's name and/or description.
func (db *DB) UpdateCollection(ctx context.Context, id string, userID, apiKeyID *string, name, description *string) (*models.Collection, error) {
	query := `
		UPDATE collections
		SET name = COALESCE($4, name),
		    description = COALESCE($5, description),
		    updated_at = NOW()
		WHERE id = $1
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))
		RETURNING id, name, description, user_id, api_key_id, created_at, updated_at`

	var c models.Collection
	err := db.QueryRowContext(ctx, query, id, userID, apiKeyID, name, description).Scan(
		&c.ID, &c.Name, &c.Description, &c.UserID, &c.APIKeyID, &c.CreatedAt, &c.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("update collection: %w", err)
	}
	return &c, nil
}

// DeleteCollection removes a collection and its item associations.
func (db *DB) DeleteCollection(ctx context.Context, id string, userID, apiKeyID *string) error {
	query := `
		DELETE FROM collections
		WHERE id = $1
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`

	result, err := db.ExecContext(ctx, query, id, userID, apiKeyID)
	if err != nil {
		return fmt.Errorf("delete collection: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("collection not found or not owned by you")
	}
	return nil
}

// GetCollectionItems returns all items in a collection that the actor can still access.
func (db *DB) GetCollectionItems(ctx context.Context, collectionID string, userID, apiKeyID *string) ([]models.CollectionItem, error) {
	var baseItems []models.CollectionItem
	err := db.SelectContext(ctx, &baseItems, `
		SELECT id, collection_id, item_type, item_id, position, added_at
		FROM collection_items
		WHERE collection_id = $1
		ORDER BY position ASC, added_at ASC`,
		collectionID,
	)
	if err != nil {
		return nil, fmt.Errorf("get collection items: %w", err)
	}

	items := make([]models.CollectionItem, 0, len(baseItems))
	for _, item := range baseItems {
		title, status, err := db.getOwnedCollectionItemMetadata(ctx, item.ItemType, item.ItemID, userID, apiKeyID)
		if err != nil {
			if err == sql.ErrNoRows {
				continue
			}
			return nil, fmt.Errorf("get collection item metadata: %w", err)
		}
		item.ItemTitle = title
		item.ItemStatus = status
		items = append(items, item)
	}
	return items, nil
}

// AddCollectionItems adds items to a collection, skipping duplicates.
func (db *DB) AddCollectionItems(ctx context.Context, collectionID string, items []models.CollectionItemInput) (int, error) {
	// Get current max position
	var maxPos int
	_ = db.QueryRowContext(ctx,
		`SELECT COALESCE(MAX(position), -1) FROM collection_items WHERE collection_id = $1`,
		collectionID,
	).Scan(&maxPos)

	added := 0
	for _, item := range items {
		maxPos++
		result, err := db.ExecContext(ctx, `
				INSERT INTO collection_items (collection_id, item_type, item_id, position)
				VALUES ($1, $2, $3, $4)
				ON CONFLICT (collection_id, item_type, item_id) DO NOTHING`,
			collectionID, item.ItemType, item.ItemID, maxPos,
		)
		if err != nil {
			return added, fmt.Errorf("add item %s/%s: %w", item.ItemType, item.ItemID, err)
		}
		if rows, _ := result.RowsAffected(); rows > 0 {
			added++
		}
	}

	// Touch updated_at on the collection
	_, _ = db.ExecContext(ctx,
		`UPDATE collections SET updated_at = NOW() WHERE id = $1`, collectionID)

	return added, nil
}

// RemoveCollectionItem removes a single item from a collection.
func (db *DB) RemoveCollectionItem(ctx context.Context, collectionID, itemID string) error {
	result, err := db.ExecContext(ctx,
		`DELETE FROM collection_items WHERE collection_id = $1 AND id = $2`,
		collectionID, itemID,
	)
	if err != nil {
		return fmt.Errorf("remove collection item: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("item not found in collection")
	}

	// Touch updated_at
	_, _ = db.ExecContext(ctx,
		`UPDATE collections SET updated_at = NOW() WHERE id = $1`, collectionID)

	return nil
}

// CollectionItemContent holds the text content of a single collection item.
type CollectionItemContent struct {
	ItemType string
	Title    string
	Text     string
}

// GetCollectionItemContents fetches the text content of all completed items in a collection.
// Used for collection-level AI chat — aggregates transcripts, audio, and PDF text.
func (db *DB) GetCollectionItemContents(ctx context.Context, collectionID string, userID, apiKeyID *string) ([]CollectionItemContent, error) {
	items, err := db.GetCollectionItems(ctx, collectionID, userID, apiKeyID)
	if err != nil {
		return nil, err
	}

	var contents []CollectionItemContent
	for _, item := range items {
		switch item.ItemType {
		case "transcript":
			var title, text string
			err := db.QueryRowContext(ctx,
				`SELECT COALESCE(title, ''), COALESCE(transcript_text, '')
				 FROM transcripts
				 WHERE id = $1
				   AND status = 'completed'
				   AND (($2::uuid IS NOT NULL AND user_id = $2)
				     OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
				item.ItemID, userID, apiKeyID).Scan(&title, &text)
			if err == nil && text != "" {
				contents = append(contents, CollectionItemContent{ItemType: "transcript", Title: title, Text: text})
			}
		case "audio":
			var title, text string
			err := db.QueryRowContext(ctx,
				`SELECT COALESCE(original_name, ''), COALESCE(transcript_text, '')
				 FROM audio_transcriptions
				 WHERE id = $1
				   AND status = 'completed'
				   AND (($2::uuid IS NOT NULL AND user_id = $2)
				     OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
				item.ItemID, userID, apiKeyID).Scan(&title, &text)
			if err == nil && text != "" {
				contents = append(contents, CollectionItemContent{ItemType: "audio", Title: title, Text: text})
			}
		case "pdf":
			var title, text string
			err := db.QueryRowContext(ctx,
				`SELECT COALESCE(filename, ''), COALESCE(text_content, '')
				 FROM pdf_extractions
				 WHERE id = $1
				   AND status = 'completed'
				   AND (($2::uuid IS NOT NULL AND user_id = $2)
				     OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
				item.ItemID, userID, apiKeyID).Scan(&title, &text)
			if err == nil && text != "" {
				contents = append(contents, CollectionItemContent{ItemType: "pdf", Title: title, Text: text})
			}
		}
	}
	return contents, nil
}

// ActorOwnsCollectionItem returns true when the authenticated actor owns the referenced item.
func (db *DB) ActorOwnsCollectionItem(ctx context.Context, itemType, itemID string, userID, apiKeyID *string) (bool, error) {
	if userID == nil && apiKeyID == nil {
		return false, fmt.Errorf("actor is required")
	}

	var exists bool
	switch itemType {
	case "transcript":
		err := db.GetContext(ctx, &exists, `
			SELECT EXISTS(
				SELECT 1 FROM transcripts
				WHERE id = $1
				  AND (($2::uuid IS NOT NULL AND user_id = $2)
				    OR ($3::uuid IS NOT NULL AND api_key_id = $3))
			)`, itemID, userID, apiKeyID)
		return exists, err
	case "audio":
		err := db.GetContext(ctx, &exists, `
			SELECT EXISTS(
				SELECT 1 FROM audio_transcriptions
				WHERE id = $1
				  AND (($2::uuid IS NOT NULL AND user_id = $2)
				    OR ($3::uuid IS NOT NULL AND api_key_id = $3))
			)`, itemID, userID, apiKeyID)
		return exists, err
	case "pdf":
		err := db.GetContext(ctx, &exists, `
			SELECT EXISTS(
				SELECT 1 FROM pdf_extractions
				WHERE id = $1
				  AND (($2::uuid IS NOT NULL AND user_id = $2)
				    OR ($3::uuid IS NOT NULL AND api_key_id = $3))
			)`, itemID, userID, apiKeyID)
		return exists, err
	default:
		return false, fmt.Errorf("unsupported item type: %s", itemType)
	}
}

func (db *DB) getOwnedCollectionItemMetadata(ctx context.Context, itemType, itemID string, userID, apiKeyID *string) (string, string, error) {
	var title, status string
	switch itemType {
	case "transcript":
		err := db.QueryRowContext(ctx, `
			SELECT COALESCE(title, ''), COALESCE(status, '')
			FROM transcripts
			WHERE id = $1
			  AND (($2::uuid IS NOT NULL AND user_id = $2)
			    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
			itemID, userID, apiKeyID).Scan(&title, &status)
		return title, status, err
	case "audio":
		err := db.QueryRowContext(ctx, `
			SELECT COALESCE(original_name, ''), COALESCE(status, '')
			FROM audio_transcriptions
			WHERE id = $1
			  AND (($2::uuid IS NOT NULL AND user_id = $2)
			    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
			itemID, userID, apiKeyID).Scan(&title, &status)
		return title, status, err
	case "pdf":
		err := db.QueryRowContext(ctx, `
			SELECT COALESCE(filename, ''), COALESCE(status, '')
			FROM pdf_extractions
			WHERE id = $1
			  AND (($2::uuid IS NOT NULL AND user_id = $2)
			    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
			itemID, userID, apiKeyID).Scan(&title, &status)
		return title, status, err
	default:
		return "", "", fmt.Errorf("unsupported item type: %s", itemType)
	}
}
