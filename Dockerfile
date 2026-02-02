# ── Stage 1: Build the frontend ──
FROM node:22-alpine AS frontend-builder
WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ .
RUN npm run build

# ── Stage 2: Build the Go binary ──
FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=frontend-builder /app/frontend/dist ./frontend/dist
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.Version=1.0.0" \
    -o /app/server \
    ./cmd/server/

# ── Stage 3: Minimal runtime image ──
FROM alpine:3.19
RUN apk add --no-cache ca-certificates python3 py3-pip ffmpeg curl && \
    pip3 install --break-system-packages yt-dlp
WORKDIR /app
COPY --from=builder /app/server .
COPY --from=builder /app/migrations ./migrations
COPY --from=frontend-builder /app/frontend/dist ./frontend/dist
RUN adduser -D -u 1000 appuser
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/api/v1/health || exit 1
CMD ["./server"]
