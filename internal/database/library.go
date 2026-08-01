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
			CASE
				WHEN t.status::text = 'completed'
				 AND COALESCE(latest_summary.status, '') IN ('pending', 'processing')
				THEN latest_summary.status
				ELSE t.status::text
			END AS status,
			t.word_count, t.duration::double precision AS duration,
			0::integer AS page_count,
			COALESCE(latest_summary.status, '') AS summary_status,
			COALESCE(mip.favorite, false) AS favorite,
			COALESCE(mip.archived, false) AS archived,
			COALESCE(mip.tags, '[]'::jsonb) AS tags,
			t.created_at, t.search_vector
		FROM transcripts t
		LEFT JOIN LATERAL (
			SELECT s.status::text AS status
			FROM summaries s
			WHERE s.transcript_id = t.id
			ORDER BY s.created_at DESC
			LIMIT 1
		) latest_summary ON true
		LEFT JOIN media_item_preferences mip ON mip.item_type = 'youtube' AND mip.item_id = t.id
			AND (($1::uuid IS NOT NULL AND mip.user_id = $1) OR ($2::uuid IS NOT NULL AND mip.api_key_id = $2))
		WHERE (($1::uuid IS NOT NULL AND t.user_id = $1) OR ($2::uuid IS NOT NULL AND t.api_key_id = $2))

		UNION ALL

		SELECT a.id, 'audio'::text, COALESCE(NULLIF(a.original_name, ''), 'Untitled recording')::text,
			COALESCE(NULLIF(UPPER(a.language), ''), 'Recording')::text,
			CASE
				WHEN a.status::text = 'completed' AND a.summary_status IN ('pending', 'processing')
				THEN a.summary_status
				ELSE a.status::text
			END AS status,
			a.word_count, a.duration::double precision, 0::integer,
			COALESCE(a.summary_status, '')::text,
			COALESCE(mip.favorite, false), COALESCE(mip.archived, false), COALESCE(mip.tags, '[]'::jsonb),
			a.created_at, a.search_vector
		FROM audio_transcriptions a
		LEFT JOIN media_item_preferences mip ON mip.item_type = 'audio' AND mip.item_id = a.id
			AND (($1::uuid IS NOT NULL AND mip.user_id = $1) OR ($2::uuid IS NOT NULL AND mip.api_key_id = $2))
		WHERE (($1::uuid IS NOT NULL AND a.user_id = $1) OR ($2::uuid IS NOT NULL AND a.api_key_id = $2))

		UNION ALL

		SELECT p.id, 'pdf'::text, COALESCE(NULLIF(p.original_name, ''), 'Untitled PDF')::text,
			(p.page_count::text || CASE WHEN p.page_count = 1 THEN ' page' ELSE ' pages' END)::text,
			p.status::text, p.word_count, 0::double precision, p.page_count,
			''::text,
			COALESCE(mip.favorite, false), COALESCE(mip.archived, false), COALESCE(mip.tags, '[]'::jsonb),
			p.created_at, p.search_vector
		FROM pdf_extractions p
		LEFT JOIN media_item_preferences mip ON mip.item_type = 'pdf' AND mip.item_id = p.id
			AND (($1::uuid IS NOT NULL AND mip.user_id = $1) OR ($2::uuid IS NOT NULL AND mip.api_key_id = $2))
		WHERE (($1::uuid IS NOT NULL AND p.user_id = $1) OR ($2::uuid IS NOT NULL AND p.api_key_id = $2))
	), filtered AS (
		SELECT * FROM library_items li
		WHERE ($3::text = '' OR item_type = $3)
		  AND ($4::text = '' OR status = $4)
		  AND ($5::text = ''
			OR search_vector @@ websearch_to_tsquery('simple'::regconfig, $5)
			OR to_tsvector('simple'::regconfig, tags::text) @@ websearch_to_tsquery('simple'::regconfig, $5)
			OR (item_type = 'youtube' AND EXISTS (
				SELECT 1 FROM summaries s
				WHERE s.transcript_id = li.id AND s.status = 'completed'
				  AND s.search_vector @@ websearch_to_tsquery('simple'::regconfig, $5)
			)))
		  AND ($6::text = 'all' OR ($6::text = 'only' AND archived) OR ($6::text = '' AND NOT archived))
		  AND ($7::text = '' OR ($7::text = 'true' AND favorite))
		  AND ($8::text = '' OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(tags) tag_value WHERE LOWER(tag_value) = LOWER($8)))
	)`

const libraryItemColumns = `id, item_type, title, subtitle, status, word_count, duration, page_count, summary_status, favorite, archived, tags, created_at`

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
	if params.Archive != "" && params.Archive != "all" && params.Archive != "only" {
		return nil, 0, fmt.Errorf("invalid archive filter")
	}
	if params.Favorite != "" && params.Favorite != "true" {
		return nil, 0, fmt.Errorf("invalid favorite filter")
	}
	if params.SortDir != "asc" {
		params.SortDir = "desc"
	}
	params.Search = strings.TrimSpace(params.Search)

	args := []interface{}{params.UserID, params.APIKeyID, params.ItemType, params.Status, params.Search, params.Archive, params.Favorite, strings.TrimSpace(params.Tag)}
	var total int
	if err := db.GetContext(ctx, &total, libraryItemsCTE+` SELECT COUNT(*) FROM filtered`, args...); err != nil {
		return nil, 0, fmt.Errorf("count library items: %w", err)
	}

	// UUID is a deterministic tie-breaker for rows that share a timestamp. Without
	// it, offset pagination can repeat or skip items between adjacent pages.
	query := libraryItemsCTE + ` SELECT ` + libraryItemColumns + ` FROM filtered ORDER BY created_at ` + params.SortDir + `, id ` + params.SortDir + ` LIMIT $9 OFFSET $10`
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
	// Stats describe the whole workspace, including items intentionally hidden in
	// the archive. Normal library browsing still excludes archived items by default.
	if err := db.GetContext(ctx, &stats, query, userID, apiKeyID, "", "", "", "all", "", ""); err != nil {
		return stats, fmt.Errorf("get library stats: %w", err)
	}
	return stats, nil
}
