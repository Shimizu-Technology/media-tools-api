// Package main is the entry point for the Media Tools API server.
//
// Go Pattern: The main package is special — it's the only package that
// produces an executable binary. The main() function is where your
// program starts, like `if __name__ == "__main__"` in Python.
//
// This file wires together all the components (dependency injection):
// Config → Database → Services → Worker Pool → HTTP Router → Server
//
// Think of it as the "orchestrator" — it creates all the pieces and
// connects them together, then starts the server.
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/config"
	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/router"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcript"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// Version is set at build time via -ldflags.
// Go Pattern: Build-time variables let you embed version info without
// config files. The Makefile passes: -ldflags="-X main.Version=1.0.0"
var Version = "dev"

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Printf("🚀 Media Tools API %s starting...", Version)

	// ────────────────────────────────────────────
	// Step 1: Load Configuration
	// ────────────────────────────────────────────
	// Go Pattern: Configuration is loaded once at startup and passed
	// explicitly to components that need it. No global config object.
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("❌ Failed to load config: %v", err)
	}

	log.Printf("📋 Config loaded: port=%s, workers=%d, gin_mode=%s", cfg.Port, cfg.WorkerCount, cfg.GinMode)
	log.Printf("🔧 yt-dlp path: %s", cfg.YtDlpPath)

	// Set Gin mode from config
	// Go Pattern: os.Setenv is used here because Gin reads this env var
	// internally. This is one of the few cases where env vars are set
	// programmatically — usually we just read them.
	os.Setenv("GIN_MODE", cfg.GinMode)

	// ────────────────────────────────────────────
	// Step 2: Connect to Database
	// ────────────────────────────────────────────
	// Go Pattern: database/sql (which sqlx wraps) manages a connection
	// pool internally. You create ONE *sql.DB at startup and share it
	// across all goroutines — it's safe for concurrent use.
	db, err := database.New(cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("❌ Failed to connect to database: %v", err)
	}
	defer db.Close() // Go Pattern: defer ensures cleanup happens when main() exits
	log.Println("✅ Database connected")

	// Run migrations to ensure schema is up to date
	if err := db.RunMigrations("migrations"); err != nil {
		log.Fatalf("❌ Migration failed: %v", err)
	}

	// ────────────────────────────────────────────
	// Step 3: Create Services
	// ────────────────────────────────────────────
	// Go Pattern: Dependency injection — we create each service with
	// its dependencies, then pass them to things that need them.
	// No service locator, no DI framework — just function arguments.

	// Transcript extractor (uses yt-dlp CLI tool)
	extractor := transcript.NewExtractor(cfg.YtDlpPath)

	// AI summary service (uses OpenRouter API)
	summarizer := summary.New(cfg.OpenRouterAPIKey, cfg.OpenRouterModel)

	// Audio transcription service (uses OpenAI Whisper API) — MTA-16
	audioTranscriber := audio.NewTranscriber(cfg.OpenAIAPIKey)
	if audioTranscriber.IsConfigured() {
		log.Println("✅ Audio transcription enabled (Whisper API)")
	} else {
		log.Println("⚠️  Audio transcription disabled (set OPENAI_API_KEY to enable)")
	}

	// ────────────────────────────────────────────
	// Step 4: Create and Start Worker Pool
	// ────────────────────────────────────────────
	// The worker pool runs N goroutines that process jobs from a channel.
	// Jobs are submitted by HTTP handlers and executed in the background.
	wp := worker.NewPool(cfg.WorkerCount, cfg.JobQueueSize, db, extractor, summarizer)
	wp.Start()
	defer wp.Stop() // Graceful shutdown: drain remaining jobs before exit

	// ────────────────────────────────────────────
	// Step 5: Setup HTTP Router
	// ────────────────────────────────────────────
	r := router.Setup(db, wp, audioTranscriber, cfg.AllowedOrigins)

	// ────────────────────────────────────────────
	// Step 6: Start the HTTP Server
	// ────────────────────────────────────────────
	// Go Pattern: We use http.Server directly instead of gin.Run()
	// because it gives us control over graceful shutdown. gin.Run()
	// is convenient but can't be stopped cleanly.
	srv := &http.Server{
		Addr:         fmt.Sprintf(":%s", cfg.Port),
		Handler:      r,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 60 * time.Second, // Long timeout for transcript extraction
		IdleTimeout:  60 * time.Second,
	}

	// Start server in a goroutine so it doesn't block
	// Go Pattern: The `go` keyword starts a concurrent goroutine.
	// We start the server in the background so main() can continue
	// to set up signal handling for graceful shutdown.
	go func() {
		log.Printf("🌐 Server listening on http://localhost:%s", cfg.Port)
		log.Printf("📖 Health check: http://localhost:%s/api/v1/health", cfg.Port)

		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("❌ Server failed: %v", err)
		}
	}()

	// ────────────────────────────────────────────
	// Step 7: Graceful Shutdown
	// ────────────────────────────────────────────
	// Go Pattern: Signal handling for clean shutdown.
	// When you press Ctrl+C or the process receives SIGTERM (e.g., from
	// Docker or a process manager), we want to:
	// 1. Stop accepting new requests
	// 2. Finish processing in-flight requests
	// 3. Stop background workers (drain the job queue)
	// 4. Close the database connection
	//
	// Without this, killing the process could leave jobs half-done
	// or database connections hanging.

	// Create a channel that receives OS signals
	quit := make(chan os.Signal, 1)
	// SIGINT = Ctrl+C, SIGTERM = kill command / Docker stop
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	// Block here until we receive a signal
	sig := <-quit
	log.Printf("🛑 Received signal %v, shutting down gracefully...", sig)

	// Give in-flight requests 30 seconds to finish
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("⚠️  Server forced to shutdown: %v", err)
	}

	// Worker pool and database are cleaned up by their defer statements above
	log.Println("👋 Server stopped. Goodbye!")
}
