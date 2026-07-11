// Package main is the entry point for the Media Tools API server.
package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/config"
	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/router"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/storage"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcript"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/webhook"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// Version is set at build time via -ldflags.
var Version = "dev"

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Printf("🚀 Media Tools API %s starting...", Version)

	// Step 1: Load Configuration
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("❌ Failed to load config: %v", err)
	}

	log.Printf("📋 Config loaded: port=%s, workers=%d, gin_mode=%s", cfg.Port, cfg.WorkerCount, cfg.GinMode)
	log.Printf("🔧 yt-dlp path: %s", cfg.YtDlpPath)

	os.Setenv("GIN_MODE", cfg.GinMode)

	// Step 2: Connect to Database
	dbURL := cfg.DatabaseURL
	useSimpleProtocol := true
	if cfg.DatabaseURLDirect != "" {
		dbURL = cfg.DatabaseURLDirect
		useSimpleProtocol = false
		log.Println("✅ Using direct database connection (no pooler)")
	}
	db, err := database.NewWithSimpleProtocol(dbURL, useSimpleProtocol)
	if err != nil {
		log.Fatalf("❌ Failed to connect to database: %v", err)
	}
	defer db.Close()
	log.Println("✅ Database connected")

	// Run migrations
	if err := db.RunMigrations("migrations"); err != nil {
		log.Fatalf("❌ Migration failed: %v", err)
	}

	// Step 3: Create Services
	extractor := transcript.NewExtractor(cfg.YtDlpPath)
	summarizer := summary.New(cfg.OpenRouterAPIKey, cfg.OpenRouterModel)

	// Configure YouTube proxy if provided (residential proxy to bypass IP blocks)
	if cfg.YouTubeProxy != "" {
		extractor.SetProxy(cfg.YouTubeProxy)
		log.Println("✅ YouTube proxy configured (residential proxy for yt-dlp)")
	} else {
		log.Println("⚠️  No YouTube proxy configured (set YOUTUBE_PROXY for reliable YouTube access)")
	}
	cookiesPath := cfg.YtDlpCookiesFile
	if cookiesPath == "" && cfg.YtDlpCookiesBase64 != "" {
		decoded, err := base64.StdEncoding.DecodeString(cfg.YtDlpCookiesBase64)
		if err != nil {
			log.Fatalf("❌ Failed to decode YT_DLP_COOKIES_B64: %v", err)
		}
		cookiesPath = filepath.Join(os.TempDir(), "mta-yt-dlp-cookies.txt")
		if err := os.WriteFile(cookiesPath, decoded, 0600); err != nil {
			log.Fatalf("❌ Failed to write yt-dlp cookies file: %v", err)
		}
	}
	if cookiesPath != "" {
		extractor.SetCookiesFile(cookiesPath)
		log.Printf("✅ yt-dlp cookies configured (%s)", cookiesPath)
	}
	ytDlpCookiesConfigured := cookiesPath != ""

	audioTranscriber := audio.NewTranscriberWithOptions(cfg.OpenAIAPIKey, audio.TranscriberOptions{
		Model:    cfg.OpenAITranscriptionModel,
		Language: cfg.OpenAITranscriptionLanguage,
		Prompt:   cfg.OpenAITranscriptionPrompt,
	})
	if audioTranscriber.IsConfigured() {
		modelHint := strings.TrimSpace(cfg.OpenAITranscriptionModel)
		if modelHint == "" {
			modelHint = "whisper-1"
		}
		languageHint := strings.TrimSpace(cfg.OpenAITranscriptionLanguage)
		switch {
		case languageHint == "":
			languageHint = "en"
		case strings.EqualFold(languageHint, "auto") || strings.EqualFold(languageHint, "detect"):
			languageHint = "auto-detect"
		}
		log.Printf("✅ Audio transcription enabled (model=%s, language=%s)", modelHint, languageHint)
		// Enable Whisper as fallback for YouTube transcripts when subtitles fail
		whisperAdapter := audio.NewWhisperAdapter(audioTranscriber)
		extractor.SetWhisperFallback(whisperAdapter)
		log.Println("✅ YouTube Whisper fallback enabled (will transcribe audio if subtitles unavailable)")
	} else {
		log.Println("⚠️  Audio transcription disabled (set OPENAI_API_KEY to enable)")
	}

	// Webhook notification service (MTA-18)
	webhookService := webhook.New(db)
	log.Println("✅ Webhook notification service initialized")

	// Raw audio storage service (S3)
	audioStorage := storage.NewS3(
		cfg.AWSAccessKeyID,
		cfg.AWSSecretAccessKey,
		cfg.AWSSessionToken,
		cfg.AWSRegion,
		cfg.AWSS3Bucket,
		cfg.AWSS3Prefix,
		cfg.AudioPlaybackURLExpiryMinutes,
	)
	if audioStorage.IsConfigured() {
		log.Printf("✅ Audio S3 storage enabled (bucket=%s, prefix=%s)", cfg.AWSS3Bucket, cfg.AWSS3Prefix)
	} else {
		log.Println("⚠️  Audio S3 storage not configured (raw recordings will not be durable across retries)")
	}

	// Step 4: Create and Start Worker Pool
	wp := worker.NewPool(cfg.WorkerCount, cfg.JobQueueSize, db, extractor, summarizer)
	wp.SetWebhookService(webhookService)     // MTA-18: wire webhooks into worker for job notifications
	wp.SetAudioTranscriber(audioTranscriber) // Wire audio transcriber for async Whisper jobs
	wp.SetAudioStorage(audioStorage)
	wp.Start()
	defer wp.Stop()

	recoveredTranscripts, err := wp.RecoverTranscriptJobs(context.Background(), 200)
	if err != nil {
		log.Printf("⚠️  Transcript job recovery failed: %v", err)
	} else if recoveredTranscripts > 0 {
		log.Printf("♻️  Requeued %d recoverable transcript job(s) on startup", recoveredTranscripts)
	}

	go func() {
		// Summary generation can take minutes. Recover in the background so a
		// large backlog never delays health checks or server startup.
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel()
		recoveredSummaries, recoveryErr := wp.RecoverSummaryJobs(ctx, 200)
		if recoveryErr != nil {
			log.Printf("⚠️  Summary job recovery failed: %v", recoveryErr)
		} else if recoveredSummaries > 0 {
			log.Printf("♻️  Requeued %d recoverable summary job(s) on startup", recoveredSummaries)
		}
	}()

	requeued, err := wp.RecoverAudioJobs(context.Background(), 200)
	if err != nil {
		log.Printf("⚠️  Audio job recovery failed: %v", err)
	} else if requeued > 0 {
		log.Printf("♻️  Requeued %d recoverable audio job(s) on startup", requeued)
	}

	if cfg.LegacyAuthEnabled {
		log.Println("⚠️  Legacy email/password auth routes are enabled")
	} else {
		log.Println("✅ Legacy email/password auth routes disabled (Clerk-first browser auth)")
	}

	// Log admin API key status
	if cfg.AdminAPIKey != "" {
		log.Println("✅ Admin API key configured (API key creation protected)")
	} else {
		log.Println("⚠️  No admin API key set (API key creation is open — set ADMIN_API_KEY in production)")
	}

	// Step 5: Setup HTTP Router
	r := router.Setup(router.RouterConfig{
		DB:                     db,
		WorkerPool:             wp,
		AudioTranscriber:       audioTranscriber,
		AudioStorage:           audioStorage,
		Webhooks:               webhookService,
		Summarizer:             summarizer,
		JWTSecret:              cfg.JWTSecret,
		LegacyAuthEnabled:      cfg.LegacyAuthEnabled,
		AdminAPIKey:            cfg.AdminAPIKey,
		OwnerKeyID:             cfg.OwnerAPIKeyID,
		OwnerKeyPrefix:         cfg.OwnerAPIKeyPrefix,
		ClerkJWKSURL:           cfg.ClerkJWKSURL,
		ClerkSecretKey:         cfg.ClerkSecretKey,
		ClerkIssuer:            cfg.ClerkIssuer,
		ClerkAudience:          cfg.ClerkAudience,
		ClerkAuthorizedParty:   cfg.ClerkAuthorizedParty,
		AllowedOrigins:         cfg.AllowedOrigins,
		DefaultRateLimit:       cfg.DefaultRateLimit,
		YtDlpCookiesConfigured: ytDlpCookiesConfigured,
	})

	// Step 6: Start the HTTP Server
	srv := &http.Server{
		Addr:              fmt.Sprintf(":%s", cfg.Port),
		Handler:           r,
		ReadHeaderTimeout: 15 * time.Second,
		// Do not set ReadTimeout: large recording uploads may legitimately take
		// longer than 15s on mobile networks. MaxBytesReader and auth still bound
		// upload risk, while direct-to-S3 remains the preferred large-file path.
		WriteTimeout: 120 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Printf("🌐 Server listening on http://localhost:%s", cfg.Port)
		log.Printf("📖 Health check: http://localhost:%s/api/v1/health", cfg.Port)

		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("❌ Server failed: %v", err)
		}
	}()

	// Step 7: Graceful Shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	sig := <-quit
	log.Printf("🛑 Received signal %v, shutting down gracefully...", sig)

	// Signal webhook service to stop pending deliveries
	webhookService.Shutdown()
	log.Println("⏳ Webhook deliveries signaled to stop")

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("⚠️  Server forced to shutdown: %v", err)
	}

	log.Println("👋 Server stopped. Goodbye!")
}
