package database

import (
	"context"
	"fmt"
	"strings"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const libraryItemsCTE = `
	WITH library_items AS (
		SELECT t.id, 'youtube'::text AS item_type,
			COALESCE(NULLIF(t.title, ''), 'Untitled video')::text AS title,
			COALESCE(NULLIF(t.channel_name, ''), 'Unknown channel')::text AS subtitle,
			t.status::text, t.word_count, t.duration::double precision AS duration,
			0::integer AS page_count,
			COALESCE((SELECT s.status::text FROM summaries s WHERE s.transcript_id = t.id ORDER BY s.created_at DESC LIMIT 1), '') AS summary_status,
			t.created_at
		FROM transcripts t
		WHERE (($1::uuid IS NOT NULL AND t.user_id = $1) OR ($2::uuid IS NOT NULL AND t.api_key_id = $2))

		UNION ALL

		SELECT a.id, 'audio'::text, COALESCE(NULLIF(a.original_name, ''), 'Untitled recording')::text,
			COALESCE(NULLIF(UPPER(a.language), ''), 'Recording')::text,
			a.status::text, a.word_count, a.duration::double precision, 0::integer,
			COALESCE(a.summary_status, '')::text, a.created_at
		FROM audio_transcriptions a
		WHERE (($1::uuid IS NOT NULL AND a.user_id = $1) OR ($2::uuid IS NOT NULL AND a.api_key_id = $2))

		UNION ALL

		SELECT p.id, 'pdf'::text, COALESCE(NULLIF(p.original_name, ''), 'Untitled PDF')::text,
			(p.page_count::text || CASE WHEN p.page_count = 1 THEN ' page' ELSE ' pages' END)::text,
			p.status::text, p.word_count, 0::double precision, p.page_count,
			''::text, p.created_at
		FROM pdf_extractions p
		WHERE (($1::uuid IS NOT NULL AND p.user_id = $1) OR ($2::uuid IS NOT NULL AND p.api_key_id = $2))
	), filtered AS (
		SELECT * FROM library_items
		WHERE ($3::text = '' OR item_type = $3)
		  AND ($4::text = '' OR status = $4)
		  AND ($5::text = '' OR title ILIKE '%' || $5 || '%' OR subtitle ILIKE '%' || $5 || '%')
	)`

// ListLibraryItems provides one correctly paginated/searchable view over every
// media table. Keeping the union server-side avoids partial totals and client-
// side filtering that only sees the first page of each content type.
func (db *DB) ListLibraryItems(ctx context.Context, params models.LibraryListParams) ([]models.LibraryItem, int, error) {
	if params.UserID == nil && params.APIKeyID == nil {
		return []models.LibraryItem{}, 0, nil
	}
	if params.Page < 1 {
		params.Page = 1
	}
	if params.PerPage < 1 || params.PerPage > 100 {
		params.PerPage = 20
	}
	if params.ItemType != "" && params.ItemType != "youtube" && params.ItemType != "audio" && params.ItemType != "pdf" {
		return nil, 0, fmt.Errorf("invalid library item type")
	}
	if params.SortDir != "asc" {
		params.SortDir = "desc"
	}
	params.Search = strings.TrimSpace(params.Search)

	args := []interface{}{params.UserID, params.APIKeyID, params.ItemType, params.Status, params.Search}
	var total int
	if err := db.GetContext(ctx, &total, libraryItemsCTE+` SELECT COUNT(*) FROM filtered`, args...); err != nil {
		return nil, 0, fmt.Errorf("count library items: %w", err)
	}

	query := libraryItemsCTE + ` SELECT * FROM filtered ORDER BY created_at ` + params.SortDir + ` LIMIT $6 OFFSET $7`
	args = append(args, params.PerPage, (params.Page-1)*params.PerPage)
	var items []models.LibraryItem
	if err := db.SelectContext(ctx, &items, query, args...); err != nil {
		return nil, 0, fmt.Errorf("list library items: %w", err)
	}
	if items == nil {
		items = []models.LibraryItem{}
	}
	return items, total, nil
}

// GetLibraryStats returns exact workspace-wide counts, independent of paging.
func (db *DB) GetLibraryStats(ctx context.Context, userID, apiKeyID *string) (models.LibraryStats, error) {
	var stats models.LibraryStats
	query := libraryItemsCTE + `
		SELECT COUNT(*) AS total,
			COUNT(*) FILTER (WHERE status = 'pending') AS pending,
			COUNT(*) FILTER (WHERE status = 'processing') AS processing,
			COUNT(*) FILTER (WHERE status = 'completed') AS completed,
			COUNT(*) FILTER (WHERE status = 'failed') AS failed,
			COUNT(*) FILTER (WHERE item_type = 'youtube') AS videos,
			COUNT(*) FILTER (WHERE item_type = 'audio') AS audio,
			COUNT(*) FILTER (WHERE item_type = 'pdf') AS pdfs
		FROM filtered`
	if err := db.GetContext(ctx, &stats, query, userID, apiKeyID, "", "", ""); err != nil {
		return stats, fmt.Errorf("get library stats: %w", err)
	}
	return stats, nil
}
