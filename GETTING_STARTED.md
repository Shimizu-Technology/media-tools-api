# Getting Started — Go for Rails Developers

Welcome! If you're coming from Ruby on Rails (or any web framework), this guide will get you productive in this Go project fast. No Go experience required.

---

## Go vs Rails — The Mental Model

Rails is **convention over configuration** — it makes hundreds of decisions for you.
Go is **explicit over implicit** — you make every decision, but there's no magic.

Think of it this way:
- **Rails** is like a fully furnished apartment. Move in and start living.
- **Go** is like a well-organized workshop. Every tool is labeled, nothing is hidden, you build exactly what you want.

Neither is better — they're different tools for different jobs.

### Why Go for This Project?

- **Fast** — Compiles to a single binary, runs without an interpreter
- **Simple** — 25 keywords (Ruby has 41). Small language, quick to learn
- **Concurrent** — Goroutines make background workers trivial (our worker pool is ~100 lines)
- **Great for APIs** — First-class HTTP support, low memory usage, fast cold starts
- **Learning** — It's a valuable skill, especially for systems and API work

---

## Project Structure

```
media-tools-api/              ← Root IS the backend (Go convention)
├── cmd/
│   └── server/
│       └── main.go           ← Entry point (like bin/rails)
├── internal/                 ← All backend application code
│   ├── config/               ← Configuration loading (.env → struct)
│   ├── handlers/             ← HTTP handlers (like controllers)
│   ├── models/               ← Data structures (like models, but no ORM)
│   ├── database/             ← SQL queries (replaces ActiveRecord)
│   ├── services/             ← Business logic
│   │   ├── audio/            ← Whisper transcription
│   │   ├── summary/          ← AI summarization via OpenRouter
│   │   ├── transcript/       ← YouTube transcript extraction
│   │   ├── webhook/          ← Webhook notifications
│   │   └── worker/           ← Background job processing
│   ├── router/               ← Route definitions (like routes.rb)
│   └── middleware/            ← Auth, CORS, rate limiting
├── migrations/               ← SQL migration files (like db/migrate/)
├── frontend/                 ← React app (Vite + TypeScript + Tailwind)
│   ├── src/
│   │   ├── pages/            ← Page components (Home, Audio, History, etc.)
│   │   ├── components/       ← Shared components
│   │   ├── lib/api.ts        ← API client (all fetch calls)
│   │   └── stores/           ← Small storage helpers
│   ├── package.json
│   └── vite.config.ts        ← Proxies /api → localhost:8080
├── go.mod                    ← Go dependencies (like Gemfile)
├── go.sum                    ← Dependency checksums (like Gemfile.lock)
├── Makefile                  ← All dev commands
├── .env.example              ← Environment variable template
├── Dockerfile                ← Production container
├── docker-compose.yml        ← Local dev with Docker
├── README.md                 ← Full API documentation
├── PRD.md                    ← Product requirements
├── BUILD_PLAN.md             ← Architecture and ticket breakdown
└── AGENTS.md                 ← AI agent conventions
```

### Rails to Go File Mapping

| What | Rails | This Project (Go) |
|------|-------|--------------------|
| Entry point | `bin/rails server` | `cmd/server/main.go` |
| Routes | `config/routes.rb` | `internal/router/router.go` |
| Controllers | `app/controllers/` | `internal/handlers/` |
| Models | `app/models/` | `internal/models/models.go` |
| Database queries | ActiveRecord | `internal/database/database.go` (raw SQL) |
| Business logic | `app/services/` | `internal/services/` |
| Migrations | `db/migrate/` | `migrations/` |
| Background jobs | Sidekiq / Active Job | `internal/services/worker/` (goroutine pool) |
| Middleware | Rack middleware | `internal/middleware/` |
| Dependencies | `Gemfile` | `go.mod` |
| Lock file | `Gemfile.lock` | `go.sum` |
| Config | `config/database.yml`, etc. | `.env` file |
| Dev commands | `rails s`, `rails db:migrate` | `make run`, `make migrate` |

### Why Is the Backend at the Root?

In Go, the convention is that the repository root IS the Go module. The `frontend/` folder is a nested sub-project. This is different from the `/frontend` + `/backend` sibling pattern common in Rails monorepos — but it's the Go standard.

---

## Setup (Step by Step)

### Prerequisites

- **Go 1.25+** — Check: `go version`
- **PostgreSQL** — Check: `psql --version`
- **Node.js 22+** — Check: `node --version`
- **yt-dlp** (optional, for YouTube transcripts) — `brew install yt-dlp`

### 1. Clone and Configure

```bash
git clone https://github.com/Shimizu-Technology/media-tools-api.git
cd media-tools-api
cp .env.example .env
```

Edit `.env`:

```bash
PORT=8080
GIN_MODE=debug

# Database — points to YOUR local PostgreSQL
# In Rails, config/database.yml handles this automatically.
# In Go (and Node, Python, etc.), you set it explicitly.
DATABASE_URL=postgres://YOUR_MAC_USERNAME@localhost:5432/media_tools?sslmode=disable

# AI Services (both optional for basic use)
OPENAI_API_KEY=sk-your-key          # For Whisper audio transcription
OPENROUTER_API_KEY=sk-or-your-key   # For AI summaries
OPENROUTER_MODEL=google/gemini-2.5-flash  # Default summary model

# Auth
JWT_SECRET=any-random-string-for-local-dev

# Frontend URL (for CORS)
CORS_ORIGIN=http://localhost:5173
```

**Why DATABASE_URL?** In Rails, `config/database.yml` has smart defaults (localhost, your username, no password). Rails is the exception — every other framework uses a connection URL. Same info, different format.

### 2. Create the Database

```bash
createdb media_tools
```

That's it. Migrations run automatically when the server starts (no `rails db:migrate` needed).

### 3. Start the API Server

```bash
make run
```

You should see:
```
🚀 Media Tools API dev starting...
📋 Config loaded: port=8080, workers=3, gin_mode=debug
✅ Database connected
✅ Migrations applied
🌐 Server listening on http://localhost:8080
```

### 4. Start the Frontend

In a **new terminal tab**:

```bash
cd media-tools-api
make frontend-install   # First time only — installs node_modules
make frontend-dev       # Starts Vite dev server
```

Frontend runs at **http://localhost:5173** and proxies API calls to `:8080`.

### 5. Verify Everything Works

```bash
# In a third terminal (or use the browser)
make health
# Should return: {"status":"ok","version":"dev","database":"healthy","workers":3}
```

Open **http://localhost:5173** — you're in!

### 6. (Optional) Enable Clerk Authentication

Without Clerk keys, the app runs in **API-key-only development mode**. The `/app/*` workspace prompts for a local API key, while public docs remain available.

To enable **user sign-in via Clerk** (Google/email login, user accounts):

#### a. Create a Clerk Application

1. Go to [dashboard.clerk.com](https://dashboard.clerk.com) and create a new application
2. Enable the sign-in methods you want (Email, Google, etc.)
3. Copy your **Publishable Key** and **Secret Key**

#### b. Set Backend Environment Variables

Add to your `.env`:

```bash
# Clerk Authentication
CLERK_PUBLISHABLE_KEY=pk_test_...
CLERK_SECRET_KEY=sk_test_...
CLERK_JWKS_URL=https://your-app.clerk.accounts.dev/.well-known/jwks.json
```

The JWKS URL is found in **Clerk Dashboard → API Keys → Advanced → JWKS URL**.

#### c. Set Frontend Environment Variables

Create `frontend/.env` (or copy from `frontend/.env.example`):

```bash
VITE_CLERK_PUBLISHABLE_KEY=pk_test_...
```

#### d. Restart Both Servers

```bash
# Terminal 1: restart backend
make run

# Terminal 2: restart frontend
make frontend-dev
```

You should now see a signed-out landing page and a protected `/app/*` workspace. When a user signs in via Clerk, the app automatically:
- Creates or updates a local user record linked to their Clerk ID
- Sends fresh Clerk bearer tokens just-in-time on API requests
- Shows their account controls inside the app shell

#### How Auth Works (Dual Mode)

The app supports **two auth modes simultaneously**:

| Mode | How It Works | Best For |
|------|-------------|----------|
| **API Key** | `X-API-Key` header | Scripts, automation, CI/CD |
| **Clerk JWT** | `Authorization: Bearer <token>` header | Browser users, the React UI |

Most media endpoints accept both modes. Developer-only webhook/ops flows still use API keys because webhooks fire for API-key-owned jobs.

**Without Clerk keys configured**, the frontend hides sign-in UI and protects `/app/*` with the local API-key prompt. No code changes needed — it's automatic.

---

## Key Concepts for Rails Developers

### No ORM — Raw SQL with sqlx

Rails has ActiveRecord, which writes SQL for you. Go uses raw SQL:

```go
// Rails (ActiveRecord)
user = User.find_by(email: "leon@example.com")

// Go (sqlx)
var user models.User
err := db.GetContext(ctx, &user, `SELECT * FROM users WHERE email = $1`, "leon@example.com")
```

**Why?** Go philosophy: be explicit. You always know exactly what SQL is running. No N+1 surprises.

Our SQL lives in `internal/database/database.go`. The `db:"column_name"` tags on structs tell sqlx how to map columns to fields.

### No Implicit Returns — Error Handling

Ruby returns the last expression. Go returns explicit values, and **errors are values** (not exceptions):

```ruby
# Rails
def find_user(id)
  User.find(id)  # raises ActiveRecord::RecordNotFound
rescue => e
  nil
end
```

```go
// Go
func (db *DB) GetUser(ctx context.Context, id string) (*models.User, error) {
    var user models.User
    err := db.GetContext(ctx, &user, `SELECT * FROM users WHERE id = $1`, id)
    if err != nil {
        return nil, fmt.Errorf("user not found: %w", err)
    }
    return &user, nil
}
```

You'll see `if err != nil` everywhere. That's Go's version of error handling — no try/catch, no exceptions. It's verbose but explicit.

### No Class Inheritance — Structs and Interfaces

Ruby uses classes and inheritance. Go uses **structs** (data) and **interfaces** (behavior):

```ruby
# Rails
class AudioTranscription < ApplicationRecord
  belongs_to :user
  validates :status, inclusion: { in: %w[pending processing completed failed] }
end
```

```go
// Go — just a struct with tags
type AudioTranscription struct {
    ID             string    `json:"id" db:"id"`
    OriginalName   string    `json:"original_name" db:"original_name"`
    Status         string    `json:"status" db:"status"`
    TranscriptText string    `json:"transcript_text" db:"transcript_text"`
    CreatedAt      time.Time `json:"created_at" db:"created_at"`
}
```

Tags (`json:"..."`, `db:"..."`) tell Go how to serialize/deserialize the struct. `json` tags control JSON output, `db` tags control database mapping.

### Background Jobs — Goroutines, Not Sidekiq

Rails uses Sidekiq/Redis for background jobs. Go has **goroutines** — lightweight threads built into the language:

```ruby
# Rails + Sidekiq
TranscriptExtractJob.perform_async(transcript_id)
```

```go
// Go — goroutines are built-in, no external service needed
go func() {
    result := extractTranscript(url)
    saveResult(result)
}()
```

Our worker pool (`internal/services/worker/`) manages a fixed number of goroutines processing jobs from a channel (Go's built-in message queue). No Redis, no Sidekiq, no external dependencies.

### Middleware — Same Concept, Different Syntax

```ruby
# Rails
class AuthenticateRequest
  def call(env)
    token = env['HTTP_AUTHORIZATION']
    # validate...
    @app.call(env)
  end
end
```

```go
// Go (Gin framework)
func AuthMiddleware() gin.HandlerFunc {
    return func(c *gin.Context) {
        token := c.GetHeader("Authorization")
        // validate...
        c.Next() // continue to the handler
    }
}
```

Same pattern: intercept request → do something → pass along (or reject).

---

## Common Commands

### Manual (like running `rails s`)

```bash
make run              # Build and start the API server (foreground, see all logs)
make frontend-dev     # Start React dev server (separate terminal)
make frontend-build   # Build frontend for production
make test             # Run all Go tests
make health           # Quick health check (server must be running)
make create-key       # Generate an API key
make migrate          # Run pending migrations (also runs on server start)
make migrate-down     # Rollback last migration
make fmt              # Format Go code
make vet              # Catch common mistakes
make help             # Show all available commands
make clean            # Remove build artifacts
```

### Docker (self-contained — no local Go/Postgres needed)

```bash
# First time (builds images + starts everything):
docker compose up --build -d

# After that:
docker compose up -d          # Start everything (background)
docker compose down           # Stop everything
docker compose ps             # What's running?
docker compose restart api    # Restart just the API
```

### Docker vs Manual — What's the Difference?

| | Manual (`make run`) | Docker (`docker compose up`) |
|---|---|---|
| **Requires** | Go, PostgreSQL, Node.js installed | Only Docker |
| **Database** | Your local PostgreSQL | Its own PostgreSQL container |
| **Frontend** | Separate terminal (`make frontend-dev`) | Built into the container |
| **Logs** | Right in your terminal (foreground) | Background — use `docker compose logs` |
| **Best for** | Editing Go code, fast iteration | Quick testing, demos, deployment |
| **URL** | API `:8080`, Frontend `:5173` | Everything on `:8080` |

**Rule of thumb:** Use Docker when you want to test or demo. Use Manual when you're actively writing Go code (faster rebuild cycle).

---

## Where Are My Logs? (Docker)

If you're coming from Rails, you're used to seeing every request scroll by in your terminal. Docker runs in the background by default (the `-d` flag = "detached"), so you won't see logs unless you ask for them.

```bash
# Watch server logs in real time (like rails s)
docker compose logs -f api

# Watch database logs
docker compose logs -f db

# Watch everything
docker compose logs -f

# See last 50 lines
docker compose logs --tail 50 api

# Without -f (just dump recent logs, don't follow)
docker compose logs api
```

**Tip:** If you prefer seeing logs in real time (like `rails s`), run without `-d`:
```bash
docker compose up        # Foreground — logs stream in your terminal
                         # Ctrl+C to stop everything
```

The `-d` flag just means "don't take over my terminal." Without it, Docker behaves exactly like `rails s` — logs scroll by and Ctrl+C stops the server.

---

## Testing the Audio Feature

This is the fastest way to test the new Audio Intelligence features:

1. Start the server: `make run`
2. Start the frontend: `make frontend-dev`
3. Open **http://localhost:5173/app/audio**
4. **Upload tab**: Drag an `.m4a` audio file or `.mp4` Zoom recording onto the page
5. Select content type (e.g., "Phone Call")
6. Hit **Transcribe**
7. Once transcribed, hit **Generate AI Summary**
8. View structured output: summary, key points, action items, decisions
9. **Export** as .txt, .md, or .json

Or use the **Record tab** to record directly in the browser.

### Testing via curl

```bash
# Health check
curl http://localhost:8080/api/v1/health | jq

# Create an API key
curl -X POST http://localhost:8080/api/v1/keys \
  -H "Content-Type: application/json" \
  -d '{"name": "dev-key"}' | jq
# Save the raw_key from the response!

# Transcribe an audio file or meeting recording
curl -X POST http://localhost:8080/api/v1/audio/transcribe \
  -H "X-API-Key: YOUR_KEY_HERE" \
  -F "file=@/path/to/zoom-meeting.mp4"

# Summarize a transcription
curl -X POST http://localhost:8080/api/v1/audio/transcriptions/TRANSCRIPTION_ID/summarize \
  -H "X-API-Key: YOUR_KEY_HERE" \
  -H "Content-Type: application/json" \
  -d '{"content_type": "phone_call"}'

# Export as markdown
curl http://localhost:8080/api/v1/audio/transcriptions/TRANSCRIPTION_ID/export?format=md \
  -H "X-API-Key: YOUR_KEY_HERE"
```

---

## Available AI Models (via OpenRouter)

OpenRouter gives you one API key for all models. Set the default in `.env` or override per-request:

| Model | Best For | Cost |
|-------|----------|------|
| `google/gemini-2.5-flash` | Fast, smart, cheap — good default | ~$0.15/M input |
| `deepseek/deepseek-chat` | Excellent quality, very cheap | ~$0.14/M input |
| `anthropic/claude-sonnet-4-20250514` | Best structured output | ~$3/M input |
| `openai/gpt-4o` | Solid all-rounder | ~$2.50/M input |
| `openai/gpt-4o-mini` | Cheapest, good for testing | ~$0.15/M input |

Browse all models: [openrouter.ai/models](https://openrouter.ai/models)

---

## Troubleshooting

**"connection refused" on make run**
→ PostgreSQL isn't running. Start it: `brew services start postgresql@16`

**"database media_tools does not exist"**
→ Create it: `createdb media_tools`

**"role 'postgres' does not exist"**
→ On Mac, the default PostgreSQL user is your Mac username, not `postgres`. Check your DATABASE_URL uses the right username.

**Frontend shows "Network Error"**
→ The API server isn't running, or CORS_ORIGIN doesn't match. Make sure both `make run` and `make frontend-dev` are running.

**Audio transcription returns "service_unavailable"**
→ Set `OPENAI_API_KEY` in your `.env` file. Whisper requires an OpenAI key.

**Summary returns "service_unavailable"**
→ Set `OPENROUTER_API_KEY` in your `.env` file.

---

## Next Steps

- **Read `README.md`** for full API endpoint documentation
- **Read `BUILD_PLAN.md`** for the architecture breakdown
- **Explore `internal/`** — start with `router/router.go` (all routes) and `handlers/` (all endpoints)
- **Try the Swagger docs** — run the server and visit `http://localhost:8080/api/docs`

Questions? The codebase is heavily commented — Go files include explanations of Go patterns and how they compare to what you'd do in Rails/JavaScript.
