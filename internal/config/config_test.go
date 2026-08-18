package config

import (
	"strings"
	"testing"
)

func setRequiredReleaseEnv(t *testing.T) {
	t.Helper()
	t.Setenv("GIN_MODE", "release")
	t.Setenv("JWT_SECRET", "test-secret-that-is-not-the-development-default")
	t.Setenv("ADMIN_API_KEY", "test-admin-key-that-is-at-least-32-chars")
	t.Setenv("YT_DLP_PATH", "/bin/true")
	t.Setenv("CLERK_JWKS_URL", "https://example.clerk.accounts.dev/.well-known/jwks.json")
}

func TestLoadRejectsMissingOrShortProductionSecrets(t *testing.T) {
	tests := []struct {
		name          string
		environment   string
		value         string
		wantErrorText string
	}{
		{
			name:          "empty JWT secret",
			environment:   "JWT_SECRET",
			value:         "",
			wantErrorText: "JWT_SECRET must be set to at least 32 characters",
		},
		{
			name:          "short JWT secret",
			environment:   "JWT_SECRET",
			value:         "too-short",
			wantErrorText: "JWT_SECRET must be set to at least 32 characters",
		},
		{
			name:          "empty admin key",
			environment:   "ADMIN_API_KEY",
			value:         "",
			wantErrorText: "ADMIN_API_KEY must be set to at least 32 characters",
		},
		{
			name:          "short admin key",
			environment:   "ADMIN_API_KEY",
			value:         "too-short",
			wantErrorText: "ADMIN_API_KEY must be set to at least 32 characters",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			setRequiredReleaseEnv(t)
			t.Setenv("CORS_ORIGIN", "https://media-tools-gu.netlify.app")
			t.Setenv(tt.environment, tt.value)

			_, err := Load()
			if err == nil || !strings.Contains(err.Error(), tt.wantErrorText) {
				t.Fatalf("Load error = %v, want %q", err, tt.wantErrorText)
			}
		})
	}
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
	if got := cfg.AllowedOrigins[0]; got != "https://media-tools-gu.netlify.app" {
		t.Fatalf("AllowedOrigins[0] = %q, want frontend origin without trailing slash", got)
	}
}

func TestLoadDefaultsLegacyAuthOffInRelease(t *testing.T) {
	setRequiredReleaseEnv(t)
	t.Setenv("CORS_ORIGIN", "https://media-tools-gu.netlify.app")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if cfg.LegacyAuthEnabled {
		t.Fatal("LegacyAuthEnabled = true, want false by default in release mode")
	}
}

func TestLoadAllowsLegacyAuthOverride(t *testing.T) {
	setRequiredReleaseEnv(t)
	t.Setenv("CORS_ORIGIN", "https://media-tools-gu.netlify.app")
	t.Setenv("LEGACY_AUTH_ENABLED", "true")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if !cfg.LegacyAuthEnabled {
		t.Fatal("LegacyAuthEnabled = false, want true when explicitly enabled")
	}
}

func TestLoadParsesMultipleCORSOrigins(t *testing.T) {
	t.Setenv("YT_DLP_PATH", "/bin/true")
	t.Setenv("CORS_ORIGIN", "https://app.example.com/, https://preview.example.com")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	want := []string{"https://app.example.com", "https://preview.example.com"}
	if len(cfg.AllowedOrigins) != len(want) {
		t.Fatalf("AllowedOrigins = %#v, want %#v", cfg.AllowedOrigins, want)
	}
	for i := range want {
		if cfg.AllowedOrigins[i] != want[i] {
			t.Fatalf("AllowedOrigins = %#v, want %#v", cfg.AllowedOrigins, want)
		}
	}
}

func TestLoadRequiresClerkAudienceAuthorizedPartyOrCORSOriginInRelease(t *testing.T) {
	setRequiredReleaseEnv(t)
	t.Setenv("CORS_ORIGIN", "")

	_, err := Load()
	if err == nil {
		t.Fatal("Load succeeded, want missing Clerk token-boundary config error")
	}
	if !strings.Contains(err.Error(), "CLERK_AUDIENCE, CLERK_AUTHORIZED_PARTY, or single CORS_ORIGIN") {
		t.Fatalf("Load error = %q, want Clerk token-boundary config error", err.Error())
	}
}

func TestLoadClampsWhisperConcurrencyAndAcceptsThroughputRouting(t *testing.T) {
	t.Setenv("YT_DLP_PATH", "/bin/true")
	t.Setenv("WHISPER_CHUNK_CONCURRENCY", "4")
	t.Setenv("WHISPER_GLOBAL_CONCURRENCY", "2")
	t.Setenv("OPENROUTER_PROVIDER_SORT", "throughput")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if cfg.WhisperChunkConcurrency != 4 || cfg.WhisperGlobalConcurrency != 4 {
		t.Fatalf("Whisper concurrency = %d/%d, want 4/4", cfg.WhisperChunkConcurrency, cfg.WhisperGlobalConcurrency)
	}
}

func TestLoadRejectsUnknownOpenRouterProviderSort(t *testing.T) {
	t.Setenv("YT_DLP_PATH", "/bin/true")
	t.Setenv("OPENROUTER_PROVIDER_SORT", "fastest-ish")

	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "OPENROUTER_PROVIDER_SORT") {
		t.Fatalf("Load error = %v, want provider sort validation error", err)
	}
}

func TestLoadConfiguresOpenAISummaryFallbackModel(t *testing.T) {
	t.Setenv("YT_DLP_PATH", "/bin/true")
	t.Setenv("OPENAI_SUMMARY_FALLBACK_MODEL", "gpt-4.1-mini-custom")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if cfg.OpenAISummaryFallbackModel != "gpt-4.1-mini-custom" {
		t.Fatalf("OpenAISummaryFallbackModel = %q, want configured model", cfg.OpenAISummaryFallbackModel)
	}
}

func TestLoadConfiguresSeparateBrowserReadRateLimit(t *testing.T) {
	t.Setenv("YT_DLP_PATH", "/bin/true")
	t.Setenv("DEFAULT_RATE_LIMIT", "250")
	t.Setenv("DEFAULT_BROWSER_READ_RATE_LIMIT", "7500")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if cfg.DefaultRateLimit != 250 {
		t.Fatalf("DefaultRateLimit = %d, want 250", cfg.DefaultRateLimit)
	}
	if cfg.DefaultBrowserReadRateLimit != 7500 {
		t.Fatalf("DefaultBrowserReadRateLimit = %d, want 7500", cfg.DefaultBrowserReadRateLimit)
	}
}
