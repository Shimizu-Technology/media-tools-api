# AGENTS.md — Media Tools API

## Project Overview

Media Tools API is a Go + React monorepo for YouTube transcripts, audio transcription (Whisper), PDF extraction, and AI summarization. This is Leon's first Go project — the codebase is intentionally well-commented and educational.

**Live:** [media-tools-gu.netlify.app](https://media-tools-gu.netlify.app)

## Tech Stack

- **Backend:** Go 1.25.6 with Gin framework
- **Frontend:** React 19 + Vite + TypeScript + Tailwind CSS v4 + Framer Motion
- **Native:** SwiftUI for iOS 18.5+
- **Database:** PostgreSQL 16 with golang-migrate (hosted on Neon)
- **AI Summaries:** OpenRouter API (multi-model LLM access)
- **Audio Transcription:** OpenAI Whisper API
- **YouTube Transcripts:** yt-dlp CLI tool
- **Hosting:** Render (backend), Netlify (frontend), Neon (database)

## Project Structure

```
cmd/server/main.go       → Entry point (DI wiring, server startup, shutdown)
internal/config/         → Environment variable loading
internal/database/       → PostgreSQL connection, queries, migrations
internal/handlers/       → HTTP request handlers (Gin)
internal/middleware/     → Auth, rate limiting, CORS
internal/models/         → Data structures + DTOs
internal/services/       → Business logic
  transcript/            → YouTube extraction via yt-dlp
  audio/                 → Audio transcription via Whisper API
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

## Validation

- Complete gate: `make gate` or `./scripts/gate.sh`.
- The gate covers credential scanning, Go formatting/vet/race tests, frontend lint/build/audit, and available iOS tests.
- If a task or gate boots an iOS simulator, record its exact UDID and shut down only that simulator when the task finishes. A simulator already booted at session start is borrowed.

## Local Development Lifecycle

- Manual API: `make run` on port `8080`; override with `PORT` when running concurrent sessions.
- Manual frontend: `make frontend-dev` on port `5173`; use an explicit alternate Vite port for concurrent sessions.
- Docker stack: `make docker-up`; exact stop command: `make docker-down`. The default Compose project is derived from this repository directory and is not a shared home-server stack.
- Claim servers, browser tabs, simulator UDIDs, and containers started by the task through the `local-dev-lifecycle` skill. Clean only the exact owned resources.
- Existing listeners, tabs, simulators, and containers are borrowed. Never use broad process, simulator, browser, or Docker cleanup.
- Media Tools API has no intentionally persistent local development service. A deliberate resource handoff must name the owner, reason, and expected lifetime.

## Parallel Sessions and Handoffs

- Give every independently writable session a separate Git worktree and branch. Do not run two writing sessions in this worktree.
- Split concurrent work into non-overlapping vertical slices with explicit blockers and acceptance criteria.
- Use the `handoff` skill before unfinished work changes session, agent, worktree, or device.
- Same-machine handoffs live under `.codex/handoffs/` and are local by default. A receiving session verifies the repository, branch, commit, tests, and runtime state before continuing.

## Environment

See `.env.example` for all configuration options.

## What to Read If Learning Go

The codebase comments explain Go patterns as they appear. Start with:
1. Error handling (`if err != nil`) — see any handler
2. Goroutines + channels — see `worker/worker.go`
3. Interfaces — see `transcript/extractor.go`
4. Context — see `database/database.go`
5. Middleware — see `middleware/auth.go`
