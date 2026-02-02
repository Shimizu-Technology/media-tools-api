# Media Tools API

A media processing API for YouTube transcript extraction and AI-powered summaries. Built with Go and React.

## What It Does

1. **Extract Transcripts** — Paste a YouTube URL, get the full transcript with metadata (title, channel, duration, word count)
2. **AI Summaries** — Generate summaries using any LLM via OpenRouter (GPT-4o, Claude, Gemini, etc.)
3. **Background Processing** — Jobs are processed asynchronously using a Go worker pool with goroutines
4. **API Key Auth** — Secure access with API keys and per-key rate limiting

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
                    │  ┌───────────────┐   │
                    │  │   yt-dlp      │   │     ┌──────────────┐
                    │  │  (transcripts)│   │────>│  OpenRouter   │
                    │  └───────────────┘   │     │  (AI models)  │
                    └──────────────────────┘     └──────────────┘
```

**Tech Stack:**
- **Backend:** Go 1.21+ with Gin framework
- **Frontend:** React 18 + Vite + TypeScript + Tailwind CSS + Framer Motion
- **Database:** PostgreSQL 16
- **AI:** OpenRouter API (unified access to multiple LLM providers)
- **Transcripts:** yt-dlp (command-line YouTube downloader)

## Quick Start (Docker Compose)

The fastest way to run everything locally:

```bash
# Clone the repo
git clone https://github.com/Shimizu-Technology/media-tools-api.git
cd media-tools-api

# Copy environment file
cp .env.example .env
# Edit .env and add your OPENROUTER_API_KEY (optional — needed for summaries only)

# Start PostgreSQL + API server
docker compose up --build -d

# The API is now running at http://localhost:8080
# Check health:
curl http://localhost:8080/api/v1/health | jq
```

## Quick Start (Manual)

```bash
# Prerequisites: Go 1.21+, PostgreSQL, Node.js 18+, yt-dlp

# 1. Clone and setup
git clone https://github.com/Shimizu-Technology/media-tools-api.git
cd media-tools-api
cp .env.example .env

# 2. Start PostgreSQL (if not running)
# Make sure DATABASE_URL in .env points to your PostgreSQL instance

# 3. Run the API server
make run
# Server starts at http://localhost:8080

# 4. Start the frontend (in another terminal)
make frontend-install
make frontend-dev
# Frontend starts at http://localhost:5173
```

## API Documentation

### Health Check
```bash
GET /api/v1/health
curl http://localhost:8080/api/v1/health
```

### Create an API Key
```bash
POST /api/v1/keys
curl -X POST http://localhost:8080/api/v1/keys \
  -H "Content-Type: application/json" \
  -d '{"name": "my-app", "rate_limit": 200}'
```
Response includes `raw_key` — **save it! Only shown once.**

### Extract a Transcript
```bash
POST /api/v1/transcripts
curl -X POST http://localhost:8080/api/v1/transcripts \
  -H "Content-Type: application/json" \
  -H "X-API-Key: mta_your_key_here" \
  -d '{"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}'
```
Returns 202 Accepted with a transcript record (status: "pending").
Poll `GET /api/v1/transcripts/:id` to check when it's ready.

### Get a Transcript
```bash
GET /api/v1/transcripts/:id
curl http://localhost:8080/api/v1/transcripts/UUID_HERE \
  -H "X-API-Key: mta_your_key_here"
```

### List Transcripts
```bash
GET /api/v1/transcripts?page=1&per_page=20&status=completed&search=golang
curl "http://localhost:8080/api/v1/transcripts?page=1&status=completed" \
  -H "X-API-Key: mta_your_key_here"
```

### Generate AI Summary
```bash
POST /api/v1/summaries
curl -X POST http://localhost:8080/api/v1/summaries \
  -H "Content-Type: application/json" \
  -H "X-API-Key: mta_your_key_here" \
  -d '{
    "transcript_id": "UUID_HERE",
    "length": "medium",
    "style": "bullet",
    "model": "openai/gpt-4o-mini"
  }'
```
Options:
- `length`: "short", "medium", "detailed"
- `style`: "bullet", "narrative", "academic"
- `model`: Any OpenRouter model (default: openai/gpt-4o-mini)

### Get Summaries for a Transcript
```bash
GET /api/v1/transcripts/:id/summaries
curl http://localhost:8080/api/v1/transcripts/UUID_HERE/summaries \
  -H "X-API-Key: mta_your_key_here"
```

### List / Revoke API Keys
```bash
GET /api/v1/keys
DELETE /api/v1/keys/:id
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | API server port |
| `GIN_MODE` | `debug` | Gin mode (debug/release/test) |
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/media_tools?sslmode=disable` | PostgreSQL connection string |
| `YT_DLP_PATH` | Auto-detected | Path to yt-dlp binary |
| `OPENROUTER_API_KEY` | (none) | OpenRouter API key for AI summaries |
| `OPENROUTER_MODEL` | `openai/gpt-4o-mini` | Default AI model |
| `WORKER_COUNT` | `3` | Background worker goroutines |
| `JOB_QUEUE_SIZE` | `100` | Max pending jobs in queue |
| `DEFAULT_RATE_LIMIT` | `100` | Requests per hour per API key |
| `CORS_ORIGIN` | `http://localhost:5173` | Allowed CORS origin |

## Project Structure

```
media-tools-api/
├── cmd/server/main.go          # Entry point — wires everything together
├── internal/
│   ├── config/                 # Environment variable configuration
│   ├── database/               # PostgreSQL connection + queries
│   ├── handlers/               # HTTP request handlers
│   ├── middleware/              # Auth, rate limiting, CORS
│   ├── models/                 # Data structures (Transcript, Summary, APIKey)
│   ├── services/
│   │   ├── transcript/         # YouTube transcript extraction via yt-dlp
│   │   ├── summary/            # AI summary generation via OpenRouter
│   │   └── worker/             # Background job processing (goroutines)
│   └── router/                 # Route configuration
├── migrations/                 # PostgreSQL migration SQL files
├── frontend/                   # React app (Vite + TypeScript + Tailwind)
├── docker-compose.yml          # Local development setup
├── Dockerfile                  # Production container
└── Makefile                    # Common dev commands
```

## Key Go Patterns Used

This project demonstrates several important Go patterns:

1. **Explicit error handling** — `result, err := fn()` instead of try/catch
2. **Interfaces for composition** — `Extractor` interface in the transcript package
3. **Goroutines + channels** — Worker pool for background processing
4. **Context propagation** — `context.Context` for timeouts and cancellation
5. **Dependency injection** — Handler struct with DB and Worker dependencies
6. **Middleware chain** — Auth → Rate Limit → Handler
7. **Graceful shutdown** — Signal handling for clean process termination

## Makefile Commands

```bash
make help              # Show all available commands
make run               # Build and run the server
make build             # Build the binary only
make docker-up         # Start Docker Compose stack
make docker-down       # Stop Docker Compose
make test              # Run all tests
make create-key        # Create a dev API key (server must be running)
make health            # Check API health
make frontend-dev      # Start frontend dev server
make frontend-build    # Build frontend for production
```

## License

MIT — Shimizu Technology
