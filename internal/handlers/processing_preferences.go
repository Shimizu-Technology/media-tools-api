package handlers

import (
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/gin-gonic/gin"
	"net/http"
)

// ProcessingPreferences exposes account-wide automatic enrichment settings.
func (h *Handler) ProcessingPreferences(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.AbortWithStatusJSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "Authentication required", Code: http.StatusUnauthorized})
		return
	}
	enabled := true
	if c.Request.Method == http.MethodPatch {
		var request struct {
			AutomaticSummaries *bool `json:"automatic_summaries"`
		}
		if c.ShouldBindJSON(&request) != nil || request.AutomaticSummaries == nil {
			c.AbortWithStatusJSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "automatic_summaries must be a boolean", Code: http.StatusBadRequest})
			return
		}
		enabled = *request.AutomaticSummaries
		if _, err := h.DB.ExecContext(c.Request.Context(), `INSERT INTO processing_preferences(user_id,automatic_summaries) VALUES($1,$2) ON CONFLICT(user_id) DO UPDATE SET automatic_summaries=EXCLUDED.automatic_summaries`, user.ID, enabled); err != nil {
			c.AbortWithStatusJSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "database_unavailable", Message: "Please try again shortly", Code: http.StatusServiceUnavailable})
			return
		}
	} else {
		if err := h.DB.QueryRowContext(c.Request.Context(), `SELECT COALESCE((SELECT automatic_summaries FROM processing_preferences WHERE user_id=$1),true)`, user.ID).Scan(&enabled); err != nil {
			c.AbortWithStatusJSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "database_unavailable", Message: "Please try again shortly", Code: http.StatusServiceUnavailable})
			return
		}
	}
	c.JSON(http.StatusOK, gin.H{"automatic_summaries": enabled})
}
