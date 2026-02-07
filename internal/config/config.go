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
	"strconv"
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

	// External tools
	YtDlpPath    string // Path to yt-dlp binary
	YouTubeProxy string // Optional: Residential proxy for YouTube (format: http://user:pass@host:port)

	// OpenRouter AI settings
	OpenRouterAPIKey string
	OpenRouterModel  string // Default model for summaries

	// OpenAI settings (for Whisper audio transcription)
	OpenAIAPIKey string

	// JWT Authentication (MTA-20)
	JWTSecret string

	// Admin API key for bootstrap operations (creating first API keys)
	// This protects the API key creation endpoint in production.
	AdminAPIKey string

	// Owner override (bypass rate limits/queue caps for personal use)
	OwnerAPIKeyID     string
	OwnerAPIKeyPrefix string

	// Worker settings
	WorkerCount    int // Number of background worker goroutines
	JobQueueSize   int // Size of the in-memory job queue buffer

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
	cfg := &Config{
		// Server defaults
		Port:    getEnv("PORT", "8080"),
		GinMode: getEnv("GIN_MODE", "debug"),

		// Database — required in production, has a default for local dev
		DatabaseURL: getEnv("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/media_tools?sslmode=disable"),

		// yt-dlp — try common locations
		YtDlpPath:    getEnv("YT_DLP_PATH", findYtDlp()),
		YouTubeProxy: getEnv("YOUTUBE_PROXY", ""), // Optional: residential proxy for YouTube

		// OpenRouter AI
		OpenRouterAPIKey: getEnv("OPENROUTER_API_KEY", ""),
		OpenRouterModel:  getEnv("OPENROUTER_MODEL", "anthropic/claude-4.5-sonnet-20250929"),

		// OpenAI (Whisper API for audio transcription)
		OpenAIAPIKey: getEnv("OPENAI_API_KEY", ""),

		// JWT Authentication
		JWTSecret: getEnv("JWT_SECRET", "dev-jwt-secret-change-in-production"),

		// Admin API key for bootstrap — optional in dev, required in production
		AdminAPIKey: getEnv("ADMIN_API_KEY", ""),

		// Owner override (optional)
		OwnerAPIKeyID:     getEnv("OWNER_API_KEY_ID", ""),
		OwnerAPIKeyPrefix: getEnv("OWNER_API_KEY_PREFIX", ""),

		// Worker defaults
		WorkerCount:  getEnvInt("WORKER_COUNT", 3),
		JobQueueSize: getEnvInt("JOB_QUEUE_SIZE", 100),

		// Rate limiting
		DefaultRateLimit: getEnvInt("DEFAULT_RATE_LIMIT", 100),

		// CORS — in production, set this to your frontend URL
		AllowedOrigins: []string{
			getEnv("CORS_ORIGIN", "http://localhost:5173"), // Vite dev server default
		},
	}

	// Validate required configuration
	if cfg.YtDlpPath == "" {
		return nil, fmt.Errorf("yt-dlp not found; set YT_DLP_PATH environment variable")
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

// getEnvInt reads an integer environment variable with a fallback.
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
