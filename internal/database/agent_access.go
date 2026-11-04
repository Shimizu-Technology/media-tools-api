package database

import (
	"context"
	"fmt"
	"strings"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// apiKeySelect loads a key together with its scopes in one round trip, since
// every authenticated API-key request needs to know whether the key is scoped.
const apiKeySelect = `SELECT k.*, COALESCE((
		SELECT string_agg(s.scope, ',' ORDER BY s.scope)
		FROM api_key_scopes s WHERE s.api_key_id = k.id
	), '') AS scope_list FROM api_keys k`

func hydrateAPIKeyScopes(key *models.APIKey) {
	key.Scopes = []string{}
	if key.ScopeList != "" {
		key.Scopes = strings.Split(key.ScopeList, ",")
	}
}

// CreateScopedAPIKey inserts a key and its scopes atomically. A key never
// exists half-scoped: that would silently turn it into a classic key.
func (db *DB) CreateScopedAPIKey(ctx context.Context, key *models.APIKey, scopes []string) error {
	if len(scopes) == 0 {
		return fmt.Errorf("scoped key requires at least one scope")
	}
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin scoped key: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	if err := tx.QueryRowContext(ctx, `
		INSERT INTO api_keys (key_hash, key_prefix, name, active, rate_limit, user_id)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING id, created_at`,
		key.KeyHash, key.KeyPrefix, key.Name, key.Active, key.RateLimit, key.UserID,
	).Scan(&key.ID, &key.CreatedAt); err != nil {
		return fmt.Errorf("insert scoped key: %w", err)
	}
	for _, scope := range scopes {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO api_key_scopes (api_key_id, scope) VALUES ($1, $2)`, key.ID, scope); err != nil {
			return fmt.Errorf("insert key scope: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit scoped key: %w", err)
	}
	key.Scopes = append([]string{}, scopes...)
	return nil
}

// RecordAgentActivity appends one audit row. Callers pass identifiers only.
func (db *DB) RecordAgentActivity(ctx context.Context, activity models.AgentActivity) error {
	_, err := db.ExecContext(ctx, `
		INSERT INTO agent_activity
			(user_id, api_key_id, api_key_name, method, route, item_type, item_id, status_code)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		activity.UserID, activity.APIKeyID, activity.APIKeyName, activity.Method,
		activity.Route, activity.ItemType, activity.ItemID, activity.StatusCode)
	if err != nil {
		return fmt.Errorf("record agent activity: %w", err)
	}
	return nil
}

// ListAgentActivity returns the newest activity for one account.
func (db *DB) ListAgentActivity(ctx context.Context, userID string, limit int) ([]models.AgentActivity, error) {
	if limit < 1 || limit > 200 {
		limit = 50
	}
	var rows []models.AgentActivity
	if err := db.SelectContext(ctx, &rows, `
		SELECT id, user_id, api_key_id, api_key_name, method, route, item_type, item_id, status_code, created_at
		FROM agent_activity WHERE user_id = $1
		ORDER BY created_at DESC, id DESC LIMIT $2`, userID, limit); err != nil {
		return nil, fmt.Errorf("list agent activity: %w", err)
	}
	if rows == nil {
		rows = []models.AgentActivity{}
	}
	return rows, nil
}
