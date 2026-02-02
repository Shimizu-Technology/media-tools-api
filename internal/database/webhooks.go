// webhooks.go handles webhook-related database operations (MTA-18).
package database

import (
	"context"
	"fmt"

	"github.com/lib/pq"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// CreateWebhook inserts a new webhook record.
func (db *DB) CreateWebhook(ctx context.Context, w *models.Webhook) error {
	query := `
		INSERT INTO webhooks (api_key_id, url, events, secret, active)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, created_at`

	return db.QueryRowContext(ctx, query,
		w.APIKeyID, w.URL, pq.Array(w.Events), w.Secret, w.Active,
	).Scan(&w.ID, &w.CreatedAt)
}

// GetWebhook retrieves a single webhook by ID.
func (db *DB) GetWebhook(ctx context.Context, id string) (*models.Webhook, error) {
	var w models.Webhook
	query := `SELECT id, api_key_id, url, events, secret, active, created_at FROM webhooks WHERE id = $1`
	row := db.QueryRowContext(ctx, query, id)
	err := row.Scan(&w.ID, &w.APIKeyID, &w.URL, pq.Array(&w.Events), &w.Secret, &w.Active, &w.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("webhook not found: %w", err)
	}
	return &w, nil
}

// ListWebhooksByAPIKey returns all webhooks for a given API key.
func (db *DB) ListWebhooksByAPIKey(ctx context.Context, apiKeyID string) ([]models.Webhook, error) {
	query := `SELECT id, api_key_id, url, events, secret, active, created_at FROM webhooks WHERE api_key_id = $1 ORDER BY created_at DESC`
	rows, err := db.QueryContext(ctx, query, apiKeyID)
	if err != nil {
		return nil, fmt.Errorf("failed to list webhooks: %w", err)
	}
	defer rows.Close()

	var webhooks []models.Webhook
	for rows.Next() {
		var w models.Webhook
		if err := rows.Scan(&w.ID, &w.APIKeyID, &w.URL, pq.Array(&w.Events), &w.Secret, &w.Active, &w.CreatedAt); err != nil {
			return nil, fmt.Errorf("failed to scan webhook: %w", err)
		}
		webhooks = append(webhooks, w)
	}
	return webhooks, nil
}

// UpdateWebhookActive toggles a webhook's active state.
func (db *DB) UpdateWebhookActive(ctx context.Context, id string, active bool) error {
	result, err := db.ExecContext(ctx, `UPDATE webhooks SET active = $2 WHERE id = $1`, id, active)
	if err != nil {
		return fmt.Errorf("failed to update webhook: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("webhook not found")
	}
	return nil
}

// DeleteWebhook removes a webhook by ID.
func (db *DB) DeleteWebhook(ctx context.Context, id string) error {
	result, err := db.ExecContext(ctx, `DELETE FROM webhooks WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("failed to delete webhook: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("webhook not found")
	}
	return nil
}

// GetActiveWebhooksForEvent returns all active webhooks that subscribe to a given event.
func (db *DB) GetActiveWebhooksForEvent(ctx context.Context, event string) ([]models.Webhook, error) {
	query := `SELECT id, api_key_id, url, events, secret, active, created_at FROM webhooks WHERE active = true AND $1 = ANY(events)`
	rows, err := db.QueryContext(ctx, query, event)
	if err != nil {
		return nil, fmt.Errorf("failed to get webhooks for event: %w", err)
	}
	defer rows.Close()

	var webhooks []models.Webhook
	for rows.Next() {
		var w models.Webhook
		if err := rows.Scan(&w.ID, &w.APIKeyID, &w.URL, pq.Array(&w.Events), &w.Secret, &w.Active, &w.CreatedAt); err != nil {
			return nil, fmt.Errorf("failed to scan webhook: %w", err)
		}
		webhooks = append(webhooks, w)
	}
	return webhooks, nil
}

// CreateWebhookDelivery inserts a new webhook delivery record.
func (db *DB) CreateWebhookDelivery(ctx context.Context, d *models.WebhookDelivery) error {
	query := `
		INSERT INTO webhook_deliveries (webhook_id, event, payload, status, attempts, last_error, response_code)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id, created_at`

	return db.QueryRowContext(ctx, query,
		d.WebhookID, d.Event, d.Payload, d.Status, d.Attempts, d.LastError, d.ResponseCode,
	).Scan(&d.ID, &d.CreatedAt)
}

// UpdateWebhookDelivery updates a delivery record after an attempt.
func (db *DB) UpdateWebhookDelivery(ctx context.Context, d *models.WebhookDelivery) error {
	query := `
		UPDATE webhook_deliveries
		SET status = $2, attempts = $3, last_error = $4, response_code = $5, delivered_at = $6
		WHERE id = $1`

	_, err := db.ExecContext(ctx, query,
		d.ID, d.Status, d.Attempts, d.LastError, d.ResponseCode, d.DeliveredAt,
	)
	return err
}

// ListWebhookDeliveries returns recent deliveries for a webhook.
func (db *DB) ListWebhookDeliveries(ctx context.Context, webhookID string, limit int) ([]models.WebhookDelivery, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	var deliveries []models.WebhookDelivery
	err := db.SelectContext(ctx, &deliveries,
		`SELECT * FROM webhook_deliveries WHERE webhook_id = $1 ORDER BY created_at DESC LIMIT $2`,
		webhookID, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to list webhook deliveries: %w", err)
	}
	return deliveries, nil
}

// ListAllDeliveriesByAPIKey returns recent deliveries for all webhooks of an API key.
func (db *DB) ListAllDeliveriesByAPIKey(ctx context.Context, apiKeyID string, limit int) ([]models.WebhookDelivery, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	var deliveries []models.WebhookDelivery
	err := db.SelectContext(ctx, &deliveries,
		`SELECT wd.* FROM webhook_deliveries wd
		 JOIN webhooks w ON w.id = wd.webhook_id
		 WHERE w.api_key_id = $1
		 ORDER BY wd.created_at DESC LIMIT $2`,
		apiKeyID, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to list deliveries: %w", err)
	}
	return deliveries, nil
}
