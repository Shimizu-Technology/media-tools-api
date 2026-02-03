# Media Tools API

A media processing API for YouTube transcripts, audio transcription, PDF extraction, and AI-powered summaries. Built with Go and React.

**Live Demo:** [media-tools-gu.netlify.app](https://media-tools-gu.netlify.app)

## Features

- **YouTube Transcripts** — Paste a URL, get the full transcript with metadata
- **Audio Transcription** — Upload audio files (MP3, M4A, WAV, etc.) for Whisper transcription
- **PDF Text Extraction** — Extract text from PDF documents
- **AI Summaries** — Generate summaries with key points, action items, and decisions
- **Background Processing** — Long-running jobs processed asynchronously
- **API Key Auth** — Secure access with per-key rate limiting
- **Ownership** — Each transcript is linked to the API key that created it

## Architecture

```
┌─────────────┐     ┌──────────────────────┐     ┌─────────────┐
│   React UI  │────>│    Go API (Gin)       │────>│ PostgreSQL  │
│  Vite + TS  │<────│  /api/v1/*            │<────│   Database  │
└─────────────┘     └──────────┬───────────┘     └─────────────┘
                               │
                    ┌──────────┴───────────┐
                    │   Worker Pool        │
                    │   (goroutines)       │
                    │                      │
                    │  ┌───────────────┐   │     ┌──────────────┐
                    │  │   yt-dlp      │   │────>│  OpenRouter   │
                    │  │  (transcripts)│   │     │  (AI models)  │
                    │  └───────────────┘   │     └──────────────┘
                    │                      │
                    │  ┌───────────────┐   │     ┌──────────────┐
                    │  │   Whisper     │   │────>│  OpenAI API   │
                    │  │  (audio)      │   │     │  (Whisper)    │
                    │  └───────────────┘   │     └──────────────┘
                    └──────────────────────┘
```

**Tech Stack:**
- **Backend:** Go 1.21+ with Gin framework
- **Frontend:** React 18 + Vite + TypeScript + Tailwind CSS v4 + Framer Motion
- **Database:** PostgreSQL 16
- **AI Summaries:** OpenRouter API (GPT-4o, Claude, Gemini, etc.)
- **Audio Transcription:** OpenAI Whisper API
- **YouTube Transcripts:** yt-dlp CLI tool

## Quick Start (Docker)

```bash
# Clone and setup
git clone https://github.com/Shimizu-Technology/media-tools-api.git
cd media-tools-api
cp .env.example .env

# Add your API keys to .env:
# - OPENROUTER_API_KEY (for AI summaries)
# - OPENAI_API_KEY (for audio transcription)

# Start everything
docker compose up --build -d

# API running at http://localhost:8080
# Frontend at http://localhost:5173
```

## Quick Start (Manual)

```bash
# Prerequisites: Go 1.21+, PostgreSQL, Node.js 18+, yt-dlp

# 1. Clone and setup
git clone https://github.com/Shimizu-Technology/media-tools-api.git
cd media-tools-api
cp .env.example .env

# 2. Configure .env with your DATABASE_URL and API keys

# 3. Run the API server
make run
# Server at http://localhost:8080

# 4. Start the frontend (in another terminal)
make frontend-install
make frontend-dev
# Frontend at http://localhost:5173
```

## API Documentation

### Authentication

All endpoints require an API key via the `X-API-Key` header:

```bash
curl -H "X-API-Key: mta_your_key_here" http://localhost:8080/api/v1/transcripts
```

### Create an API Key

In production, API key creation requires an admin key:

```bash
curl -X POST http://localhost:8080/api/v1/keys \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: your_admin_key" \
  -d '{"name": "my-app", "rate_limit": 1000}'
```

Response includes `raw_key` — **save it! Only shown once.**

### YouTube Transcripts

```bash
# Extract transcript (returns immediately, processes in background)
POST /api/v1/transcripts
curl -X POST http://localhost:8080/api/v1/transcripts \
  -H "Content-Type: application/json" \
  -H "X-API-Key: mta_your_key" \
  -d '{"url": "https://www.youtube.com/watch?v=VIDEO_ID"}'

# Get transcript (poll until status is "completed")
GET /api/v1/transcripts/:id

# List your transcripts
GET /api/v1/transcripts?page=1&per_page=20&status=completed
```

### Audio Transcription

```bash
# Upload audio file (returns immediately, processes in background)
POST /api/v1/audio/transcribe
curl -X POST http://localhost:8080/api/v1/audio/transcribe \
  -H "X-API-Key: mta_your_key" \
  -F "file=@recording.m4a"

# Get transcription (poll until status is "completed")
GET /api/v1/audio/transcriptions/:id

# Generate AI summary for audio
POST /api/v1/audio/transcriptions/:id/summarize
curl -X POST http://localhost:8080/api/v1/audio/transcriptions/:id/summarize \
  -H "Content-Type: application/json" \
  -H "X-API-Key: mta_your_key" \
  -d '{"content_type": "phone_call"}'

# Content types: general, phone_call, meeting, voice_memo, interview, lecture
```

Supported formats: MP3, WAV, M4A, OGG, FLAC, WebM (max 25MB)

### PDF Extraction

```bash
# Extract text from PDF
POST /api/v1/pdf/extract
curl -X POST http://localhost:8080/api/v1/pdf/extract \
  -H "X-API-Key: mta_your_key" \
  -F "file=@document.pdf"

# List your PDF extractions
GET /api/v1/pdf/extractions
```

### AI Summaries

```bash
# Generate summary for a YouTube transcript
POST /api/v1/summaries
curl -X POST http://localhost:8080/api/v1/summaries \
  -H "Content-Type: application/json" \
  -H "X-API-Key: mta_your_key" \
  -d '{
    "transcript_id": "UUID",
    "length": "medium",
    "style": "bullet",
    "model": "google/gemini-2.5-flash"
  }'
```

Options:
- `length`: short, medium, detailed
- `style`: bullet, narrative, academic
- `model`: Any OpenRouter model

## Production Deployment

### Recommended Stack

- **Backend:** Render (Docker support, auto-deploy from GitHub)
- **Frontend:** Netlify (CDN, auto-deploy, SPA redirects)
- **Database:** Neon (serverless PostgreSQL)

### Environment Variables (Production)

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | Yes | PostgreSQL connection string |
| `JWT_SECRET` | Yes | 32+ char random string |
| `ADMIN_API_KEY` | Yes | Secret key for creating API keys |
| `OPENROUTER_API_KEY` | For summaries | OpenRouter API key |
| `OPENAI_API_KEY` | For audio | OpenAI API key (Whisper) |
| `CORS_ORIGIN` | Yes | Frontend URL (e.g., https://your-app.netlify.app) |
| `GIN_MODE` | Recommended | Set to `release` |

### Generate Secrets

```bash
# JWT_SECRET
openssl rand -base64 32

# ADMIN_API_KEY
openssl rand -hex 32
```

## Project Structure

```
media-tools-api/
├── cmd/server/main.go          # Entry point
├── internal/
│   ├── config/                 # Environment configuration
│   ├── database/               # PostgreSQL queries
│   ├── handlers/               # HTTP handlers
│   ├── middleware/             # Auth, rate limiting, CORS
│   ├── models/                 # Data structures
│   └── services/
│       ├── transcript/         # yt-dlp integration
│       ├── audio/              # Whisper integration
│       ├── summary/            # OpenRouter integration
│       └── worker/             # Background job processing
├── migrations/                 # SQL migrations
├── frontend/                   # React app
├── Dockerfile                  # Production container
└── docker-compose.yml          # Local development
```

## Key Go Patterns

This codebase demonstrates:

1. **Explicit error handling** — `result, err := fn()` pattern
2. **Goroutines + channels** — Worker pool for async jobs
3. **Context propagation** — Timeouts and cancellation
4. **Dependency injection** — Handler struct with dependencies
5. **Middleware chain** — Auth → Rate Limit → Handler
6. **Graceful shutdown** — Signal handling for clean termination

## Makefile Commands

```bash
make run               # Run the server
make docker-up         # Start Docker stack
make frontend-dev      # Start frontend dev server
make test              # Run tests
make health            # Check API health
```

## License

MIT — Shimizu Technology
