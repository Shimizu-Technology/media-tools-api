package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

type stubReadinessChecker struct {
	err    error
	called int
}

func (s *stubReadinessChecker) HealthCheck(ctx context.Context) error {
	s.called++
	if _, ok := ctx.Deadline(); !ok {
		return errors.New("readiness context has no deadline")
	}
	return s.err
}

func runHealthHandler(t *testing.T, handler gin.HandlerFunc) (int, models.HealthResponse) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/probe", handler)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/probe", nil)
	router.ServeHTTP(recorder, request)

	var response models.HealthResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode health response: %v", err)
	}
	return recorder.Code, response
}

func TestHealthCheckDoesNotQueryDatabase(t *testing.T) {
	checker := &stubReadinessChecker{}
	handler := &Handler{readinessChecker: checker}

	status, response := runHealthHandler(t, handler.HealthCheck)

	if status != http.StatusOK {
		t.Fatalf("status = %d, want %d", status, http.StatusOK)
	}
	if response.Status != "ok" || response.Database != "unchecked" {
		t.Fatalf("response = %#v, want live process with unchecked database", response)
	}
	if checker.called != 0 {
		t.Fatalf("database health checker called %d times, want 0", checker.called)
	}
}

func TestReadinessCheckQueriesDatabase(t *testing.T) {
	tests := []struct {
		name           string
		err            error
		wantHTTPStatus int
		wantStatus     string
		wantDatabase   string
	}{
		{name: "ready", wantHTTPStatus: http.StatusOK, wantStatus: "ok", wantDatabase: "healthy"},
		{name: "database unavailable", err: errors.New("database unavailable"), wantHTTPStatus: http.StatusServiceUnavailable, wantStatus: "unhealthy", wantDatabase: "unhealthy"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			checker := &stubReadinessChecker{err: tt.err}
			handler := &Handler{readinessChecker: checker}

			status, response := runHealthHandler(t, handler.ReadinessCheck)

			if status != tt.wantHTTPStatus || response.Status != tt.wantStatus || response.Database != tt.wantDatabase {
				t.Fatalf("status/response = %d/%#v, want %d with %s/%s", status, response, tt.wantHTTPStatus, tt.wantStatus, tt.wantDatabase)
			}
			if checker.called != 1 {
				t.Fatalf("database health checker called %d times, want 1", checker.called)
			}
		})
	}
}

func TestReadinessCheckFailsWhenDatabaseIsNotConfigured(t *testing.T) {
	handler := &Handler{}

	status, response := runHealthHandler(t, handler.ReadinessCheck)

	if status != http.StatusServiceUnavailable || response.Status != "unhealthy" || response.Database != "unhealthy" {
		t.Fatalf("status/response = %d/%#v, want unavailable", status, response)
	}
}
