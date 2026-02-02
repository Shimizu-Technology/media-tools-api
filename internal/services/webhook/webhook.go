// Package webhook handles sending webhook notifications for async job events (MTA-18).
package webhook

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// Service handles webhook notification delivery.
type Service struct {
	db     *database.DB
	client *http.Client
}

// New creates a new webhook service.
func New(db *database.DB) *Service {
	return &Service{
		db: db,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

// GenerateSecret creates a random HMAC secret for a webhook.
func GenerateSecret() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}

// SignPayload creates an HMAC-SHA256 signature for a payload.
func SignPayload(payload []byte, secret string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(payload)
	return hex.EncodeToString(mac.Sum(nil))
}

// NotifyEvent sends webhook notifications for a given event to all registered webhooks.
// Delivery happens asynchronously with retry logic.
func (s *Service) NotifyEvent(ctx context.Context, event string, data interface{}) {
	webhooks, err := s.db.GetActiveWebhooksForEvent(ctx, event)
	if err != nil {
		log.Printf("⚠️  Failed to get webhooks for event %s: %v", event, err)
		return
	}

	if len(webhooks) == 0 {
		return
	}

	payload := models.WebhookPayload{
		Event:     event,
		Data:      data,
		Timestamp: time.Now().UTC(),
	}

	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		log.Printf("⚠️  Failed to marshal webhook payload: %v", err)
		return
	}

	for _, wh := range webhooks {
		// Fire and forget — each delivery runs in its own goroutine
		go s.deliverWithRetry(wh, event, payloadJSON)
	}
}

// deliverWithRetry attempts to deliver a webhook with exponential backoff.
// Retries: 3 attempts with delays of 1s, 5s, 30s.
func (s *Service) deliverWithRetry(wh models.Webhook, event string, payloadJSON []byte) {
	ctx := context.Background()

	// Create delivery record
	delivery := &models.WebhookDelivery{
		WebhookID: wh.ID,
		Event:     event,
		Payload:   string(payloadJSON),
		Status:    "pending",
	}

	if err := s.db.CreateWebhookDelivery(ctx, delivery); err != nil {
		log.Printf("⚠️  Failed to create webhook delivery record: %v", err)
		return
	}

	retryDelays := []time.Duration{0, 1 * time.Second, 5 * time.Second, 30 * time.Second}

	for attempt := 0; attempt < len(retryDelays); attempt++ {
		if attempt > 0 {
			time.Sleep(retryDelays[attempt])
		}

		delivery.Attempts = attempt + 1
		statusCode, err := s.deliver(wh, payloadJSON)
		delivery.ResponseCode = statusCode

		if err == nil && statusCode >= 200 && statusCode < 300 {
			// Success
			delivery.Status = "success"
			now := time.Now()
			delivery.DeliveredAt = &now
			delivery.LastError = ""
			if updateErr := s.db.UpdateWebhookDelivery(ctx, delivery); updateErr != nil {
				log.Printf("⚠️  Failed to update delivery record: %v", updateErr)
			}
			log.Printf("✅ Webhook delivered: %s → %s (attempt %d)", event, wh.URL, attempt+1)
			return
		}

		// Record the error
		if err != nil {
			delivery.LastError = err.Error()
		} else {
			delivery.LastError = fmt.Sprintf("HTTP %d", statusCode)
		}
		delivery.Status = "pending"
		if updateErr := s.db.UpdateWebhookDelivery(ctx, delivery); updateErr != nil {
			log.Printf("⚠️  Failed to update delivery record: %v", updateErr)
		}

		log.Printf("⚠️  Webhook delivery failed (attempt %d/%d): %s → %s: %s",
			attempt+1, len(retryDelays), event, wh.URL, delivery.LastError)
	}

	// All retries exhausted
	delivery.Status = "failed"
	if updateErr := s.db.UpdateWebhookDelivery(ctx, delivery); updateErr != nil {
		log.Printf("⚠️  Failed to update delivery record: %v", updateErr)
	}
	log.Printf("❌ Webhook delivery failed permanently: %s → %s", event, wh.URL)
}

// deliver sends a single webhook HTTP request.
func (s *Service) deliver(wh models.Webhook, payloadJSON []byte) (int, error) {
	req, err := http.NewRequest("POST", wh.URL, bytes.NewReader(payloadJSON))
	if err != nil {
		return 0, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "MediaToolsAPI-Webhook/1.0")

	// Sign with HMAC-SHA256 if secret is set
	if wh.Secret != "" {
		signature := SignPayload(payloadJSON, wh.Secret)
		req.Header.Set("X-Webhook-Signature", signature)
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	return resp.StatusCode, nil
}
