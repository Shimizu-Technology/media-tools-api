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
	"net"
	"net/http"
	"net/url"
	"strings"
	"syscall"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// Service handles webhook notification delivery.
type Service struct {
	db         *database.DB
	client     *http.Client
	shutdownCh chan struct{} // Signals pending deliveries to stop
}

// New creates a new webhook service.
func New(db *database.DB) *Service {
	return &Service{
		db:         db,
		client:     safeHTTPClient(),
		shutdownCh: make(chan struct{}),
	}
}

// Shutdown signals all pending webhook deliveries to stop.
// Call this during graceful server shutdown.
func (s *Service) Shutdown() {
	close(s.shutdownCh)
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
func (s *Service) NotifyEvent(ctx context.Context, event string, userID, apiKeyID *string, data interface{}) {
	webhooks, err := s.db.GetActiveWebhooksForEvent(ctx, event, userID, apiKeyID)
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
		// Pool.notifyWebhook already runs this method behind a bounded semaphore.
		// Deliver sequentially here so one event cannot create an unbounded number
		// of retry goroutines and silently defeat that concurrency limit.
		s.deliverWithRetry(wh, event, payloadJSON)
	}
}

// deliverWithRetry attempts to deliver a webhook with exponential backoff.
// Retries: 3 attempts with delays of 1s, 5s, 30s.
// Delivery respects shutdown signals for graceful termination.
func (s *Service) deliverWithRetry(wh models.Webhook, event string, payloadJSON []byte) {
	// Create a context with a generous timeout for the entire retry sequence
	// (up to ~40 seconds of retries + delivery time)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

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
			// Wait for the retry delay, but respect shutdown signals
			select {
			case <-s.shutdownCh:
				log.Printf("⚠️  Webhook delivery aborted due to shutdown: %s → %s", event, wh.URL)
				delivery.Status = "failed"
				delivery.LastError = "shutdown during delivery"
				s.db.UpdateWebhookDelivery(ctx, delivery)
				return
			case <-ctx.Done():
				log.Printf("⚠️  Webhook delivery timed out: %s → %s", event, wh.URL)
				delivery.Status = "failed"
				delivery.LastError = "delivery timeout"
				s.db.UpdateWebhookDelivery(ctx, delivery)
				return
			case <-time.After(retryDelays[attempt]):
				// Continue with next attempt
			}
		}

		delivery.Attempts = attempt + 1
		statusCode, err := s.deliver(ctx, wh, payloadJSON)
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

// deliver sends a single webhook HTTP request with context support.
func (s *Service) deliver(ctx context.Context, wh models.Webhook, payloadJSON []byte) (int, error) {
	if err := ValidateWebhookURL(ctx, wh.URL); err != nil {
		return 0, fmt.Errorf("invalid webhook URL: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", wh.URL, bytes.NewReader(payloadJSON))
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

// ValidateWebhookURL blocks unsafe destinations to reduce SSRF risk.
// Policy:
// - https scheme only
// - no localhost / loopback / private / link-local / multicast / unspecified IPs
func ValidateWebhookURL(ctx context.Context, raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("malformed URL")
	}
	if u.Scheme != "https" {
		return fmt.Errorf("only https webhook URLs are allowed")
	}
	if u.Host == "" {
		return fmt.Errorf("missing host")
	}
	hostname := strings.ToLower(u.Hostname())
	if hostname == "" || hostname == "localhost" {
		return fmt.Errorf("localhost is not allowed")
	}

	// Direct IP literal host (IPv4/IPv6) checks.
	if ip := net.ParseIP(hostname); ip != nil {
		if isBlockedIP(ip) {
			return fmt.Errorf("private or local network destinations are not allowed")
		}
		return nil
	}

	// DNS host checks.
	resolveCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	ips, err := net.DefaultResolver.LookupIPAddr(resolveCtx, hostname)
	if err != nil || len(ips) == 0 {
		return fmt.Errorf("failed to resolve host")
	}
	for _, ip := range ips {
		if isBlockedIP(ip.IP) {
			return fmt.Errorf("private or local network destinations are not allowed")
		}
	}
	return nil
}

func isBlockedIP(ip net.IP) bool {
	return ip.IsLoopback() ||
		ip.IsPrivate() ||
		ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() ||
		ip.IsUnspecified()
}

func safeHTTPClient() *http.Client {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{
		// Do not honor HTTP_PROXY/HTTPS_PROXY for webhook delivery: a proxy
		// would make DialContext validate the proxy host rather than the final
		// webhook destination, bypassing the SSRF guard.
		Proxy: nil,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(address)
			if err != nil {
				return nil, err
			}
			ips, err := net.DefaultResolver.LookupIPAddr(ctx, host)
			if err != nil || len(ips) == 0 {
				return nil, fmt.Errorf("failed to resolve host")
			}
			var lastErr error
			for _, resolved := range ips {
				if isBlockedIP(resolved.IP) {
					lastErr = fmt.Errorf("private or local network destinations are not allowed")
					continue
				}
				conn, err := dialer.DialContext(ctx, network, net.JoinHostPort(resolved.IP.String(), port))
				if err == nil {
					return conn, nil
				}
				lastErr = err
			}
			if lastErr != nil {
				return nil, lastErr
			}
			return nil, syscall.EHOSTUNREACH
		},
	}
	return &http.Client{
		Timeout:   10 * time.Second,
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if err := ValidateWebhookURL(req.Context(), req.URL.String()); err != nil {
				return err
			}
			if len(via) >= 3 {
				return fmt.Errorf("too many redirects")
			}
			return nil
		},
	}
}
