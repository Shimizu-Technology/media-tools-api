# Media Tools API — Build Plan

## Phase 1: Core MVP

### MTA-1: Project Scaffolding ✅
- [x] Go project structure (cmd/, internal/, pkg/ convention)
- [x] React frontend (Vite + TypeScript + Tailwind + Framer Motion)
- [x] Monorepo structure
- [x] AGENTS.md, PRD.md, BUILD_PLAN.md
- [x] .cursor/rules/ files
- [x] Docker Compose for local dev
- [x] Makefile for common commands
- [x] .env.example

### MTA-2: Database Setup ✅
- [x] golang-migrate for migrations
- [x] transcripts table (full schema)
- [x] summaries table with JSONB key_points
- [x] api_keys table with hash storage
- [x] Connection pooling configuration
- [x] Health check endpoint

### MTA-3: YouTube Transcript Extraction ✅
- [x] POST /api/v1/transcripts endpoint
- [x] YouTube URL parsing (youtube.com, youtu.be, shorts, video IDs)
- [x] yt-dlp integration for transcript extraction
- [x] WebVTT subtitle parsing
- [x] Metadata extraction (title, channel, duration)
- [x] Deduplication (return existing if already extracted)
- [x] Error handling for common failures

### MTA-4: Background Job Processing ✅
- [x] Worker pool using goroutines and channels
- [x] Buffered channel as job queue
- [x] Status tracking: pending → processing → completed → failed
- [x] Graceful shutdown with WaitGroup
- [x] Non-blocking job submission

### MTA-5: API Key Auth + Rate Limiting ✅
- [x] API key generation (crypto/rand)
- [x] SHA-256 key hashing (never store raw keys)
- [x] X-API-Key header authentication middleware
- [x] Token bucket rate limiting per key
- [x] Rate limit headers (X-RateLimit-Limit, X-RateLimit-Remaining)
- [x] Key management: create, list, revoke

### MTA-6: Transcript List + Get ✅
- [x] GET /api/v1/transcripts/:id
- [x] GET /api/v1/transcripts (list with pagination)
- [x] Filter by status, date range
- [x] Search by title/channel
- [x] Sort by created_at, title, word_count

### MTA-7: AI Summary Endpoint ✅
- [x] POST /api/v1/summaries
- [x] OpenRouter API integration
- [x] Configurable model, length, style
- [x] Structured output parsing (summary + key points)
- [x] GET /api/v1/transcripts/:id/summaries

### MTA-11: Frontend Landing Page ✅
- [x] Clean landing page with hero section
- [x] YouTube URL input with submit
- [x] Loading state with polling
- [x] Transcript display with metadata
- [x] Copy to clipboard
- [x] API key setup flow
- [x] Dark mode toggle
- [x] Framer Motion animations
- [x] Mobile-first responsive design
- [x] Lucide React icons (no emoji)

## Phase 2: Enhancements (Future)

### MTA-8: Batch Processing
- Accept array of URLs
- Track batch progress
- Return all results

### MTA-9: Webhook Notifications
- Register webhook URLs per API key
- POST to webhook on job completion
- Retry with exponential backoff

### MTA-10: Export Formats
- Markdown export
- PDF generation
- SRT subtitle file
- Plain text with timestamps

### MTA-12: Frontend — Summary UI
- Summary generation UI
- Model selector
- Length/style options
- Summary display with key points

### MTA-13: Frontend — History
- List of past transcripts
- Search and filter
- Delete functionality

### MTA-14: Deployment
- Fly.io or Railway deployment
- CI/CD with GitHub Actions
- Production PostgreSQL (Neon or Supabase)

## Phase 4: Media Processing Tools

### MTA-16: Audio Transcription Endpoint (Whisper) ✅
- [x] POST /api/v1/audio/transcribe — multipart file upload (mp3, wav, m4a, ogg, flac, webm)
- [x] Max 25MB file size (Whisper API limit)
- [x] OpenAI Whisper API integration via OPENAI_API_KEY env var
- [x] Graceful handling when API key not configured
- [x] audio_transcriptions table (migration 005)
- [x] Handler: internal/handlers/audio.go
- [x] Service: internal/services/audio/transcriber.go
- [x] GET endpoints for retrieval and listing
- [x] Frontend: /audio route with drag-and-drop upload
- [x] Copy/download transcription results

### MTA-17: PDF Text Extraction Endpoint ✅
- [x] POST /api/v1/pdf/extract — multipart PDF upload (max 50MB)
- [x] Pure Go PDF text extraction (ledongthuc/pdf library)
- [x] Page count, word count, text with page break markers
- [x] pdf_extractions table (migration 006)
- [x] Handler: internal/handlers/pdf.go
- [x] Service: internal/services/pdf/extractor.go
- [x] GET endpoints for retrieval and listing
- [x] Frontend: /pdf route with drag-and-drop, page-break display
- [x] Copy all / download as .txt
