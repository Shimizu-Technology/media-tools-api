// Package config handles application configuration.
//
// Go Pattern: Configuration via environment variables with sensible defaults.
// In Go, we typically use structs to hold configuration, and a function to
// load values from environment variables. This is different from Ruby's
// Rails.application.config or JavaScript's dotenv — Go keeps it explicit.
package config

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// Config holds all application configuration.
// Go Pattern: We use exported (capitalized) fields so other packages can read them.
// Tags like `json:"port"` are metadata — useful for serialization but not required here.
type Config struct {
	// Server settings
	Port    string
	GinMode string // "debug", "release", or "test"

	// Database settings
	DatabaseURL string
	// Optional direct (non-pooled) connection string for PgBouncer compatibility
	DatabaseURLDirect string

	// External tools
	YtDlpPath          string // Path to yt-dlp binary
	YtDlpCookiesFile   string // Optional: Netscape cookie jar path for login-required sites (e.g., Vimeo private/unlisted)
	YtDlpCookiesBase64 string // Optional: Base64-encoded cookies.txt content (written to temp file at startup)
	YouTubeProxy       string // Optional: Residential proxy for YouTube (format: http://user:pass@host:port)

	// AWS S3 (raw audio persistence)
	AWSAccessKeyID                string
	AWSSecretAccessKey            string
	AWSSessionToken               string
	AWSRegion                     string
	AWSS3Bucket                   string
	AWSS3Prefix                   string
	AudioPlaybackURLExpiryMinutes int

	// OpenRouter AI settings
	OpenRouterAPIKey       string
	OpenRouterModel        string // Default model for summaries
	OpenRouterChatModel    string // Optional faster model for interactive chat
	OpenRouterProviderSort string // price, latency, or throughput

	// OpenAI settings (for Whisper/audio transcription and summary fallback)
	OpenAIAPIKey                string
	OpenAISummaryFallbackModel  string
	OpenAITranscriptionModel    string
	OpenAITranscriptionLanguage string
	OpenAITranscriptionPrompt   string

	// JWT Authentication (MTA-20)
	JWTSecret string
	// Legacy email/password auth is kept for local/dev compatibility but should
	// be disabled in production when Clerk is the browser auth source of truth.
	LegacyAuthEnabled bool

	// Clerk Authentication
	ClerkPublishableKey  string
	ClerkSecretKey       string
	ClerkJWKSURL         string
	ClerkIssuer          string
	ClerkAudience        string
	ClerkAuthorizedParty string

	// Admin API key for bootstrap operations (creating first API keys)
	// This protects the API key creation endpoint in production.
	AdminAPIKey string

	// Owner override (bypass rate limits/queue caps for personal use)
	OwnerAPIKeyID     string
	OwnerAPIKeyPrefix string

	// Worker settings
	WorkerCount              int // Number of background worker goroutines
	JobQueueSize             int // Size of the in-memory job queue buffer
	WhisperChunkConcurrency  int // Parallel chunks within one recording
	WhisperGlobalConcurrency int // Process-wide cap across recordings

	// Rate limiting
	DefaultRateLimit int // Requests per hour per API key

	// CORS
	AllowedOrigins []string
}

// Load reads configuration from environment variables with sensible defaults.
//
// Go Pattern: Functions that can fail return (value, error). This is Go's
// alternative to exceptions — the caller MUST handle the error. You'll see
// this pattern everywhere in Go: `result, err := doSomething()`.
func Load() (*Config, error) {
	ginMode := getEnv("GIN_MODE", "debug")
	cfg := &Config{
		// Server defaults
		Port:    getEnv("PORT", "8080"),
		GinMode: ginMode,

		// Database — required in production, has a default for local dev
		DatabaseURL:       getEnv("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/media_tools?sslmode=disable"),
		DatabaseURLDirect: getEnv("DATABASE_URL_DIRECT", ""),

		// yt-dlp — try common locations
		YtDlpPath:          getEnv("YT_DLP_PATH", findYtDlp()),
		YtDlpCookiesFile:   getEnv("YT_DLP_COOKIES_FILE", ""),
		YtDlpCookiesBase64: getEnv("YT_DLP_COOKIES_B64", ""),
		YouTubeProxy:       getEnv("YOUTUBE_PROXY", ""), // Optional: residential proxy for YouTube

		// AWS S3 (raw audio persistence)
		AWSAccessKeyID:                getEnv("AWS_ACCESS_KEY_ID", ""),
		AWSSecretAccessKey:            getEnv("AWS_SECRET_ACCESS_KEY", ""),
		AWSSessionToken:               getEnv("AWS_SESSION_TOKEN", ""),
		AWSRegion:                     getEnv("AWS_REGION", ""),
		AWSS3Bucket:                   getEnv("AWS_S3_BUCKET", ""),
		AWSS3Prefix:                   getEnv("AWS_S3_PREFIX", "audio"),
		AudioPlaybackURLExpiryMinutes: getEnvInt("AUDIO_PLAYBACK_URL_EXPIRY_MINUTES", 60),

		// OpenRouter AI
		OpenRouterAPIKey: getEnv("OPENROUTER_API_KEY", ""),
		OpenRouterModel:  getEnv("OPENROUTER_MODEL", "anthropic/claude-4.5-sonnet-20250929"),
		// Interactive Q&A favors a fast workhorse model; durable summaries keep
		// the separately configured quality-oriented model above.
		OpenRouterChatModel:    getEnv("OPENROUTER_CHAT_MODEL", "google/gemini-2.5-flash"),
		OpenRouterProviderSort: getEnv("OPENROUTER_PROVIDER_SORT", "throughput"),

		// OpenAI (Whisper/API for audio transcription and a direct summary
		// fallback when OpenRouter cannot accept a request).
		OpenAIAPIKey:                getEnv("OPENAI_API_KEY", ""),
		OpenAISummaryFallbackModel:  getEnv("OPENAI_SUMMARY_FALLBACK_MODEL", "gpt-4.1-mini"),
		OpenAITranscriptionModel:    getEnv("OPENAI_TRANSCRIPTION_MODEL", "whisper-1"),
		OpenAITranscriptionLanguage: getEnv("OPENAI_TRANSCRIPTION_LANGUAGE", "en"),
		OpenAITranscriptionPrompt:   getEnv("OPENAI_TRANSCRIPTION_PROMPT", ""),

		// JWT Authentication
		JWTSecret:         getEnv("JWT_SECRET", "dev-jwt-secret-change-in-production"),
		LegacyAuthEnabled: getEnvBool("LEGACY_AUTH_ENABLED", ginMode != "release"),

		// Clerk Authentication
		ClerkPublishableKey:  getEnv("CLERK_PUBLISHABLE_KEY", ""),
		ClerkSecretKey:       getEnv("CLERK_SECRET_KEY", ""),
		ClerkJWKSURL:         getEnv("CLERK_JWKS_URL", ""),
		ClerkIssuer:          getEnv("CLERK_ISSUER", ""),
		ClerkAudience:        getEnv("CLERK_AUDIENCE", ""),
		ClerkAuthorizedParty: getEnv("CLERK_AUTHORIZED_PARTY", ""),

		// Admin API key for bootstrap — optional in dev, required in production
		AdminAPIKey: getEnv("ADMIN_API_KEY", ""),

		// Owner override (optional)
		OwnerAPIKeyID:     getEnv("OWNER_API_KEY_ID", ""),
		OwnerAPIKeyPrefix: getEnv("OWNER_API_KEY_PREFIX", ""),

		// Worker defaults
		WorkerCount:              getEnvInt("WORKER_COUNT", 3),
		JobQueueSize:             getEnvInt("JOB_QUEUE_SIZE", 100),
		WhisperChunkConcurrency:  getEnvInt("WHISPER_CHUNK_CONCURRENCY", 3),
		WhisperGlobalConcurrency: getEnvInt("WHISPER_GLOBAL_CONCURRENCY", 6),

		// Rate limiting
		DefaultRateLimit: getEnvInt("DEFAULT_RATE_LIMIT", 100),

		// CORS — in production, set this to your frontend URL. Multiple origins can
		// be comma-separated for preview deployments.
		AllowedOrigins: parseAllowedOrigins(getEnv("CORS_ORIGIN", "http://localhost:5173")),
	}

	if cfg.GinMode == "release" && cfg.ClerkJWKSURL != "" && cfg.ClerkAudience == "" && cfg.ClerkAuthorizedParty == "" {
		if origin, ok := os.LookupEnv("CORS_ORIGIN"); ok && strings.TrimSpace(origin) != "" && !strings.Contains(origin, ",") {
			cfg.ClerkAuthorizedParty = normalizeOrigin(origin)
		} else {
			return nil, fmt.Errorf("CLERK_AUDIENCE, CLERK_AUTHORIZED_PARTY, or single CORS_ORIGIN must be set in production when Clerk auth is enabled")
		}
	}

	// Validate required configuration
	if cfg.YtDlpPath == "" {
		return nil, fmt.Errorf("yt-dlp not found; set YT_DLP_PATH environment variable")
	}
	if cfg.YtDlpCookiesFile != "" {
		info, err := os.Stat(cfg.YtDlpCookiesFile)
		if err != nil {
			return nil, fmt.Errorf("YT_DLP_COOKIES_FILE not readable (%s): %w", cfg.YtDlpCookiesFile, err)
		}
		if info.IsDir() {
			return nil, fmt.Errorf("YT_DLP_COOKIES_FILE must be a file, got directory: %s", cfg.YtDlpCookiesFile)
		}
	}

	// Security: JWT secret MUST be set in production mode
	// In release mode, we refuse to start with the default secret.
	if cfg.GinMode == "release" && cfg.JWTSecret == "dev-jwt-secret-change-in-production" {
		return nil, fmt.Errorf("JWT_SECRET must be set in production; refusing to start with default secret")
	}

	// Security: Admin API key MUST be set in production mode
	// This protects the API key creation endpoint from unauthorized access.
	if cfg.GinMode == "release" && cfg.AdminAPIKey == "" {
		return nil, fmt.Errorf("ADMIN_API_KEY must be set in production; this protects API key creation")
	}
	if cfg.WhisperChunkConcurrency < 1 {
		cfg.WhisperChunkConcurrency = 1
	}
	if cfg.WhisperGlobalConcurrency < cfg.WhisperChunkConcurrency {
		cfg.WhisperGlobalConcurrency = cfg.WhisperChunkConcurrency
	}
	switch cfg.OpenRouterProviderSort {
	case "", "price", "latency", "throughput":
	default:
		return nil, fmt.Errorf("OPENROUTER_PROVIDER_SORT must be price, latency, throughput, or empty")
	}
	return cfg, nil
}

// getEnv reads an environment variable with a fallback default.
// Go Pattern: Small helper functions are idiomatic. Go favors simple,
// composable functions over complex frameworks.
func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}

func normalizeOrigin(origin string) string {
	return strings.TrimRight(strings.TrimSpace(origin), "/")
}

func parseAllowedOrigins(raw string) []string {
	parts := strings.Split(raw, ",")
	origins := make([]string, 0, len(parts))
	for _, part := range parts {
		origin := normalizeOrigin(part)
		if origin != "" {
			origins = append(origins, origin)
		}
	}
	if len(origins) == 0 {
		return []string{"http://localhost:5173"}
	}
	return origins
}

// getEnvInt reads an integer environment variable with a fallback.
func getEnvBool(key string, fallback bool) bool {
	str := strings.ToLower(strings.TrimSpace(getEnv(key, "")))
	if str == "" {
		return fallback
	}
	switch str {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}

func getEnvInt(key string, fallback int) int {
	str := getEnv(key, "")
	if str == "" {
		return fallback
	}
	// strconv.Atoi converts a string to an int — like parseInt() in JavaScript
	val, err := strconv.Atoi(str)
	if err != nil {
		return fallback
	}
	return val
}

// findYtDlp checks common locations for the yt-dlp binary.
func findYtDlp() string {
	if path, err := exec.LookPath("yt-dlp"); err == nil {
		return path
	}
	paths := []string{
		"/home/clawdbot/.local/bin/yt-dlp",
		"/usr/local/bin/yt-dlp",
		"/usr/bin/yt-dlp",
		"/home/linuxbrew/.linuxbrew/bin/yt-dlp",
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}
