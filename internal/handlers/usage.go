package handlers

import (
	"context"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/gin-gonic/gin"
)

func usageAccount(c *gin.Context) string {
	if user := middleware.GetUser(c); user != nil {
		return user.ID
	}
	if key := middleware.GetAPIKey(c); key != nil && key.UserID != nil {
		return *key.UserID
	}
	return ""
}
func (h *Handler) ensureUsage(c *gin.Context, userID string) bool {
	if err := h.DB.EnsureUsagePolicy(c.Request.Context(), userID, h.MonthlyMinutes, h.MonthlyAIRequests, h.OwnerUserID, h.OwnerAPIKeyID); err != nil {
		log.Printf("usage policy check failed: %v", err)
		authError(c, 503, "usage_unavailable", "Could not check account usage; retry")
		c.Abort()
		return false
	}
	return true
}
func (h *Handler) GetUsage(c *gin.Context) {
	userID := usageAccount(c)
	if userID == "" {
		authError(c, 401, "unauthorized", "Sign in to see account usage")
		return
	}
	if !h.ensureUsage(c, userID) {
		return
	}
	usage, err := h.DB.AccountUsage(c.Request.Context(), userID)
	if err != nil {
		log.Printf("usage lookup failed: %v", err)
		authError(c, 503, "usage_unavailable", "Could not check account usage; retry")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, usage)
}

// UsageGuard checks before accepting work. Database admission triggers reserve
// one minute per new resource in the creation transaction, closing the race
// between simultaneous API processes. Workers replace it with actual duration
// before Whisper. Summary/chat calls reserve a request atomically here.
func (h *Handler) UsageGuard() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.Request.Method != "POST" {
			c.Next()
			return
		}
		route := c.FullPath()
		transcription := route == "/api/v1/transcripts" || route == "/api/v1/transcripts/batch" || route == "/api/v1/audio/transcribe" || route == "/api/v1/audio/uploads/presign" || route == "/api/v1/audio/uploads/complete" || strings.HasSuffix(route, "/retry")
		formatting := route == "/api/v1/audio/transcriptions/:id/format"
		ai := formatting || route == "/api/v1/summaries" || strings.HasSuffix(route, "/summarize") || strings.HasSuffix(route, "/chat") || strings.HasSuffix(route, "/messages")
		userID := usageAccount(c)
		if userID == "" || (!transcription && !ai) {
			c.Next()
			return
		}
		if !h.ensureUsage(c, userID) {
			return
		}
		usage, err := h.DB.AccountUsage(c.Request.Context(), userID)
		if err != nil {
			log.Printf("usage lookup failed: %v", err)
			authError(c, 503, "usage_unavailable", "Could not check account usage; retry")
			c.Abort()
			return
		}
		if usage.Exempt {
			c.Next()
			return
		}
		atomicAdmission := route == "/api/v1/transcripts" || route == "/api/v1/transcripts/batch" || route == "/api/v1/audio/uploads/complete"
		if transcription && !atomicAdmission && usage.TranscriptionSeconds+60 > usage.TranscriptionLimitSeconds {
			authError(c, 402, "monthly_transcription_cap", "Monthly transcription limit reached; try again next month")
			c.Abort()
			return
		}
		if formatting {
			// Formatting is charged by its durable worker, for both manual and
			// automatic jobs. Do not double-charge the HTTP enqueue operation.
			if usage.AIRequests >= usage.AIRequestLimit {
				authError(c, 402, "monthly_ai_cap", "Monthly AI limit reached; try again next month")
				c.Abort()
				return
			}
		} else if ai {
			reservedMonth, reserveErr := h.DB.ReserveAIRequest(c.Request.Context(), userID)
			err = reserveErr
			if err != nil {
				if database.IsUsageCap(err) {
					authError(c, 402, "monthly_ai_cap", "Monthly summary and chat limit reached; try again next month")
				} else {
					log.Printf("AI usage reservation failed: %v", err)
					authError(c, 503, "usage_unavailable", "Could not check account usage; retry")
				}
				c.Abort()
				return
			}
			ctx, providerCalled := summary.TrackProviderCall(c.Request.Context())
			c.Request = c.Request.WithContext(ctx)
			defer func() {
				if c.Writer.Status() >= 400 && !providerCalled.Load() {
					ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					defer cancel()
					if err := h.DB.RefundAIRequest(ctx, userID, reservedMonth); err != nil {
						log.Printf("AI usage refund failed; manual reconciliation may be needed: %v", err)
					}
				}
			}()
		}
		c.Next()
	}
}

// quotaCreationError converts the database's atomic admission rejection to the
// same public 402 contract as the early guard. Other database errors remain the
// responsibility of the existing handler.
func quotaCreationError(c *gin.Context, err error) bool {
	if !database.IsUsageCap(err) {
		return false
	}
	authError(c, 402, "monthly_transcription_cap", "Monthly transcription limit reached; try again next month")
	return true
}
