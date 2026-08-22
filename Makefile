# ═══════════════════════════════════════════════
# Media Tools API — Makefile
# Common commands for development
# ═══════════════════════════════════════════════

GO_PACKAGES := $(shell go list ./... | grep -v '/frontend/node_modules/')

.PHONY: help build run test gate security-scan ios-release-preflight clean docker docker-up docker-down migrate lint fmt vet frontend dev

# Default target — show help
help: ## Show this help message
	@echo "Media Tools API — Available Commands"
	@echo "═════════════════════════════════════"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Build & Run ──

build: ## Build the Go binary
	go build -ldflags="-X main.Version=dev" -o bin/server ./cmd/server/

run: build ## Build and run the server locally
	@set -a; [ ! -f .env ] || . ./.env; set +a; ./bin/server

dev: ## Run with live reload (requires air: go install github.com/air-verse/air@latest)
	air

# ── Testing ──

test: ## Run all Go tests
	go test -v $(GO_PACKAGES)

gate: ## Run the complete backend, frontend, and available iOS verification gate
	./scripts/gate.sh

security-scan: ## Scan repository history and the working tree for committed credentials
	./scripts/scan-secrets.sh

ios-release-preflight: ## Verify iOS release source and optional ARCHIVE_PATH / EXPORT_PATH
	./scripts/ios-release-preflight.sh $(if $(ARCHIVE_PATH),--archive "$(ARCHIVE_PATH)",) $(if $(EXPORT_PATH),--export "$(EXPORT_PATH)",)

test-cover: ## Run tests with coverage report
	go test -coverprofile=coverage.out $(GO_PACKAGES)
	go tool cover -html=coverage.out -o coverage.html
	@echo "Coverage report: coverage.html"

# ── Code Quality ──

lint: ## Run Go linter (requires golangci-lint)
	golangci-lint run $(GO_PACKAGES)

fmt: ## Format Go code
	go fmt $(GO_PACKAGES)

vet: ## Run Go vet (catch common mistakes)
	go vet $(GO_PACKAGES)

# ── Docker ──

docker: ## Build Docker image
	docker build -t mta .

docker-up: ## Start all services with Docker Compose
	docker compose up --build -d

docker-down: ## Stop all Docker Compose services
	docker compose down

docker-logs: ## Tail Docker Compose logs
	docker compose logs -f

docker-db: ## Connect to the PostgreSQL database in Docker
	docker compose exec db psql -U postgres -d media_tools

# ── Database ──

migrate: ## Run all pending migrations
	go run -tags postgres github.com/golang-migrate/migrate/v4/cmd/migrate@v4.19.1 \
		-path migrations \
		-database "$${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/media_tools?sslmode=disable}" \
		up

migrate-up: migrate ## Alias for migrate

migrate-down: ## Rollback the last migration
	go run -tags postgres github.com/golang-migrate/migrate/v4/cmd/migrate@v4.19.1 \
		-path migrations \
		-database "$${DATABASE_URL:-postgres://postgres:postgres@localhost:5432/media_tools?sslmode=disable}" \
		down 1

migrate-create: ## Create a new migration (usage: make migrate-create NAME=add_users)
	go run -tags postgres github.com/golang-migrate/migrate/v4/cmd/migrate@v4.19.1 \
		create -ext sql -dir migrations -seq $(NAME)

# ── Frontend ──

frontend-install: ## Install frontend dependencies
	cd frontend && npm install

frontend-dev: ## Start frontend dev server
	cd frontend && npm run dev

frontend-build: ## Build frontend for production
	cd frontend && npm run build

# ── Utility ──

clean: ## Remove build artifacts
	rm -rf bin/ coverage.out coverage.html
	cd frontend && rm -rf dist node_modules/.vite

create-key: ## Create a new API key (server must be running)
	@curl -s -X POST http://localhost:8080/api/v1/keys \
		-H "Content-Type: application/json" \
		-d '{"name": "dev-key"}' | jq .

health: ## Check API health
	@curl -s http://localhost:8080/api/v1/health | jq .
