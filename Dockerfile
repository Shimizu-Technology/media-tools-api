# ── Stage 1: Build the Go binary ──
# Multi-stage builds keep the final image small (no compiler, no source code).
FROM golang:1.23-alpine AS builder

WORKDIR /app

# Copy dependency files first (cache layer — only re-downloads if go.mod changes)
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build the binary
# CGO_ENABLED=0 creates a statically linked binary (no C library dependencies)
# -ldflags strips debug info and sets the version
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.Version=1.0.0" \
    -o /app/server \
    ./cmd/server/

# ── Stage 2: Minimal runtime image ──
# Alpine is ~5MB vs ~1GB for the full Go image
FROM alpine:3.19

# Install ca-certificates (needed for HTTPS calls to OpenRouter)
# and yt-dlp dependencies
RUN apk add --no-cache ca-certificates python3 py3-pip ffmpeg curl && \
    pip3 install --break-system-packages yt-dlp

WORKDIR /app

# Copy the binary from the builder stage
COPY --from=builder /app/server .
COPY --from=builder /app/migrations ./migrations

# Create a non-root user for security
RUN adduser -D -u 1000 appuser
USER appuser

# Expose the API port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/api/v1/health || exit 1

# Run the server
CMD ["./server"]
