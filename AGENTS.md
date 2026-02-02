# AGENTS.md — Media Tools API

## Project Overview

Media Tools API is a Go + React monorepo for YouTube transcript extraction and AI summarization. This is Leon's first Go project — the codebase is intentionally well-commented and educational.

## Tech Stack

- **Backend:** Go 1.21+ with Gin framework
- **Frontend:** React 18 + Vite + TypeScript + Tailwind CSS v4 + Framer Motion
- **Database:** PostgreSQL 16 with golang-migrate
- **AI:** OpenRouter API (multi-model LLM access)
- **Transcripts:** yt-dlp CLI tool

## Project Structure

```
cmd/server/main.go       → Entry point (DI wiring, server startup, shutdown)
internal/config/         → Environment variable loading
internal/database/       → PostgreSQL connection, queries, migrations
internal/handlers/       → HTTP request handlers (Gin)
internal/middleware/      → Auth, rate limiting, CORS
internal/models/         → Data structures + DTOs
internal/services/       → Business logic
  transcript/            → YouTube extraction via yt-dlp
  summary/               → AI summary via OpenRouter
  worker/                → Background job processing (goroutines)
internal/router/         → Route configuration
migrations/              → SQL migration files
frontend/                → React app
```

## Conventions

### Go
- Error handling: always check and propagate errors (`if err != nil`)
- Use `context.Context` for cancellation and timeouts
- Interfaces defined where consumed, not where implemented
- Comments explain "why" and Go patterns that differ from JS/Ruby

### Frontend
- NO emoji in UI — use Lucide React icons
- Brand tokens via CSS custom properties (not hardcoded colors)
- Mobile-first (44px min touch targets)
- Framer Motion for all animations
- Dark mode via `.dark` class on `<html>`

### API
- All endpoints under `/api/v1/`
- Auth via `X-API-Key` header
- Consistent error format: `{"error": "...", "message": "...", "code": N}`
- Async processing returns 202 Accepted

## Key Files to Understand First

1. `cmd/server/main.go` — How everything connects
2. `internal/models/models.go` — All data structures
3. `internal/services/worker/worker.go` — Goroutine patterns
4. `internal/middleware/auth.go` — Authentication flow

## Running Locally

```bash
# Docker (easiest)
docker compose up --build

# Manual
make run                # Go server on :8080
make frontend-dev       # React on :5173
```

## Environment

See `.env.example` for all configuration options.

## What to Read If Learning Go

The codebase comments explain Go patterns as they appear. Start with:
1. Error handling (`if err != nil`) — see any handler
2. Goroutines + channels — see `worker/worker.go`
3. Interfaces — see `transcript/extractor.go`
4. Context — see `database/database.go`
5. Middleware — see `middleware/auth.go`
