package account

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const defaultClerkAPIURL = "https://api.clerk.com/v1"

// ClerkClient performs the final identity-provider deletion after application
// data has been purged. Keeping it small makes the exact destructive request
// easy to test and audit.
type ClerkClient struct {
	secretKey string
	baseURL   string
	client    *http.Client
}

func NewClerkClient(secretKey string) *ClerkClient {
	return &ClerkClient{
		secretKey: strings.TrimSpace(secretKey),
		baseURL:   defaultClerkAPIURL,
		client:    &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *ClerkClient) IsConfigured() bool {
	return c != nil && c.secretKey != ""
}

func (c *ClerkClient) DeleteUser(ctx context.Context, clerkUserID string) error {
	if !c.IsConfigured() {
		return fmt.Errorf("CLERK_SECRET_KEY is not configured")
	}
	if strings.TrimSpace(clerkUserID) == "" {
		return fmt.Errorf("Clerk user ID is required")
	}

	requestURL := strings.TrimRight(c.baseURL, "/") + "/users/" + url.PathEscape(clerkUserID)
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, requestURL, nil)
	if err != nil {
		return fmt.Errorf("create Clerk deletion request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.secretKey)
	req.Header.Set("Accept", "application/json")

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("delete Clerk user: %w", err)
	}
	defer resp.Body.Close()
	if (resp.StatusCode >= 200 && resp.StatusCode < 300) || resp.StatusCode == http.StatusNotFound {
		return nil
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
	return fmt.Errorf("Clerk deletion returned status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
}
