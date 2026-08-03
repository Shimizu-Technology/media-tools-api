package config

import (
	"strings"
	"testing"
	"time"
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

func TestLoadDefaultsJobRecoveryInterval(t *testing.T) {
	t.Setenv("YT_DLP_PATH", "/bin/true")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if cfg.JobRecoveryInterval != 15*time.Minute {
		t.Fatalf("JobRecoveryInterval = %s, want 15m", cfg.JobRecoveryInterval)
	}
}

func TestLoadParsesJobRecoveryInterval(t *testing.T) {
	t.Setenv("YT_DLP_PATH", "/bin/true")
	t.Setenv("JOB_RECOVERY_INTERVAL", "45s")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if cfg.JobRecoveryInterval != 45*time.Second {
		t.Fatalf("JobRecoveryInterval = %s, want 45s", cfg.JobRecoveryInterval)
	}
}

func TestLoadRejectsInvalidJobRecoveryInterval(t *testing.T) {
	t.Setenv("YT_DLP_PATH", "/bin/true")

	for _, value := range []string{"soon", "0s", "-1m"} {
		t.Run(value, func(t *testing.T) {
			t.Setenv("JOB_RECOVERY_INTERVAL", value)
			_, err := Load()
			if err == nil || !strings.Contains(err.Error(), "JOB_RECOVERY_INTERVAL") {
				t.Fatalf("Load error = %v, want JOB_RECOVERY_INTERVAL validation error", err)
			}
		})
	}
}
