package config

import (
	"os"
	"strings"
	"testing"
)

func setRequiredReleaseEnv(t *testing.T) {
	t.Helper()
	t.Setenv("GIN_MODE", "release")
	t.Setenv("JWT_SECRET", "test-secret-that-is-not-the-development-default")
	t.Setenv("ADMIN_API_KEY", "test-admin-key-that-is-at-least-32-chars")
	t.Setenv("YT_DLP_PATH", "/bin/true")
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
			name:          "whitespace-padded short JWT secret",
			environment:   "JWT_SECRET",
			value:         "            too-short            ",
			wantErrorText: "JWT_SECRET must be set to at least 32 characters",
		},
		{
			name:          "whitespace-padded development JWT secret",
			environment:   "JWT_SECRET",
			value:         "    dev-jwt-secret-change-in-production    ",
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

func TestLoadNormalizesProductionSecretsBeforeUse(t *testing.T) {
	setRequiredReleaseEnv(t)
	t.Setenv("CORS_ORIGIN", "https://media-tools-gu.netlify.app")
	t.Setenv("JWT_SECRET", "  test-secret-that-is-not-the-development-default  ")
	t.Setenv("ADMIN_API_KEY", "  test-admin-key-that-is-at-least-32-chars  ")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if cfg.JWTSecret != "test-secret-that-is-not-the-development-default" {
		t.Fatalf("JWTSecret retained surrounding whitespace")
	}
	if cfg.AdminAPIKey != "test-admin-key-that-is-at-least-32-chars" {
		t.Fatalf("AdminAPIKey retained surrounding whitespace")
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

func TestLoadAllowsPasskeyCookieAuthWithoutProvider(t *testing.T) {
	t.Setenv("YT_DLP_PATH", "/bin/true")
	t.Setenv("FIRST_PARTY_AUTH_ENABLED", "true")
	t.Setenv("WEB_COOKIE_AUTH_ENABLED", "true")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if !cfg.WebCookieAuthEnabled || !cfg.FirstPartyAuthEnabled {
		t.Fatalf("first-party web auth was not enabled: %#v", cfg)
	}
}

func TestLoadRequiresFirstPartyAuthForPasswordAuth(t *testing.T) {
	t.Setenv("FIRST_PARTY_PASSWORD_AUTH_ENABLED", "true")
	t.Setenv("FIRST_PARTY_AUTH_ENABLED", "false")
	_, err := Load()
	if err == nil || !strings.Contains(err.Error(), "FIRST_PARTY_PASSWORD_AUTH_ENABLED requires FIRST_PARTY_AUTH_ENABLED") {
		t.Fatalf("Load error = %v", err)
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

func TestEmailSignupAndQuotaDefaults(t *testing.T) {
	t.Setenv("YT_DLP_PATH", "/usr/bin/true")
	t.Setenv("GIN_MODE", "debug")
	t.Setenv("FIRST_PARTY_PASSWORD_AUTH_ENABLED", "false")
	t.Setenv("EMAIL_DELIVERY", "")
	// An explicit invalid empty mode should be rejected; an absent setting uses
	// log. Testing the default needs Unsetenv with a restoring cleanup.
	previous, had := os.LookupEnv("EMAIL_DELIVERY")
	_ = os.Unsetenv("EMAIL_DELIVERY")
	t.Cleanup(func() {
		if had {
			_ = os.Setenv("EMAIL_DELIVERY", previous)
		} else {
			_ = os.Unsetenv("EMAIL_DELIVERY")
		}
	})
	t.Setenv("PUBLIC_SIGNUP_ENABLED", "false")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.EmailDelivery != "log" || cfg.PublicSignupEnabled || cfg.DefaultMonthlyTranscriptionMinutes != 300 || cfg.DefaultMonthlyAIRequests != 1000 {
		t.Fatal("unsafe auth defaults")
	}
	t.Setenv("EMAIL_DELIVERY", "resend")
	t.Setenv("RESEND_API_KEY", "")
	t.Setenv("RESEND_FROM_EMAIL", "")
	if _, err = Load(); err == nil {
		t.Fatal("configured Resend accepted missing settings")
	}
	t.Setenv("EMAIL_DELIVERY", "log")
	t.Setenv("PUBLIC_SIGNUP_ENABLED", "true")
	if _, err = Load(); err == nil {
		t.Fatal("signup enabled without password auth")
	}
}

func TestMalformedMonthlyCaps(t *testing.T) {
	for _, key := range []string{"DEFAULT_MONTHLY_TRANSCRIPTION_MINUTES", "DEFAULT_MONTHLY_AI_REQUESTS"} {
		t.Run(key, func(t *testing.T) {
			t.Setenv(key, "100O")
			_, err := Load()
			if err == nil || !strings.Contains(err.Error(), key) {
				t.Fatalf("expected malformed %s error, got %v", key, err)
			}
		})
	}
}
