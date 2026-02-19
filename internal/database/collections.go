// collections.go handles collection CRUD operations.
package database

import (
	"context"
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

// GetCollectionItems returns all items in a collection with title/status from their source tables.
func (db *DB) GetCollectionItems(ctx context.Context, collectionID string) ([]models.CollectionItem, error) {
	query := `
		SELECT ci.id, ci.collection_id, ci.item_type, ci.item_id, ci.position, ci.added_at,
		       COALESCE(
		           t.title,
		           at.original_name,
		           pe.filename,
		           ''
		       ) AS item_title,
		       COALESCE(
		           t.status,
		           at.status,
		           pe.status,
		           ''
		       ) AS item_status
		FROM collection_items ci
		LEFT JOIN transcripts t ON ci.item_type = 'transcript' AND ci.item_id = t.id
		LEFT JOIN audio_transcriptions at ON ci.item_type = 'audio' AND ci.item_id = at.id
		LEFT JOIN pdf_extractions pe ON ci.item_type = 'pdf' AND ci.item_id = pe.id
		WHERE ci.collection_id = $1
		ORDER BY ci.position ASC, ci.added_at ASC`

	var items []models.CollectionItem
	err := db.SelectContext(ctx, &items, query, collectionID)
	if err != nil {
		return nil, fmt.Errorf("get collection items: %w", err)
	}
	if items == nil {
		items = []models.CollectionItem{}
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
		_, err := db.ExecContext(ctx, `
			INSERT INTO collection_items (collection_id, item_type, item_id, position)
			VALUES ($1, $2, $3, $4)
			ON CONFLICT (collection_id, item_type, item_id) DO NOTHING`,
			collectionID, item.ItemType, item.ItemID, maxPos,
		)
		if err != nil {
			return added, fmt.Errorf("add item %s/%s: %w", item.ItemType, item.ItemID, err)
		}
		added++
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
