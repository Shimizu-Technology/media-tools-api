package config

import (
	"strings"
	"testing"
)

func setRequiredReleaseEnv(t *testing.T) {
	t.Helper()
	t.Setenv("GIN_MODE", "release")
	t.Setenv("JWT_SECRET", "test-secret-that-is-not-the-development-default")
	t.Setenv("ADMIN_API_KEY", "test-admin-key")
	t.Setenv("YT_DLP_PATH", "/bin/true")
	t.Setenv("CLERK_JWKS_URL", "https://example.clerk.accounts.dev/.well-known/jwks.json")
}

func TestLoadInfersClerkAuthorizedPartyFromCORSOrigin(t *testing.T) {
	setRequiredReleaseEnv(t)
	t.Setenv("CORS_ORIGIN", "https://media-tools-gu.netlify.app/")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}

	if cfg.ClerkAuthorizedParty != "https://media-tools-gu.netlify.app" {
		t.Fatalf("ClerkAuthorizedParty = %q, want frontend origin without trailing slash", cfg.ClerkAuthorizedParty)
	}
}

func TestLoadRequiresClerkAudienceAuthorizedPartyOrCORSOriginInRelease(t *testing.T) {
	setRequiredReleaseEnv(t)
	t.Setenv("CORS_ORIGIN", "")

	_, err := Load()
	if err == nil {
		t.Fatal("Load succeeded, want missing Clerk token-boundary config error")
	}
	if !strings.Contains(err.Error(), "CLERK_AUDIENCE, CLERK_AUTHORIZED_PARTY, or CORS_ORIGIN") {
		t.Fatalf("Load error = %q, want Clerk token-boundary config error", err.Error())
	}
}
