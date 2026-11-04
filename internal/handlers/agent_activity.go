package handlers

import (
	"log"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// ListAgentActivity returns recent scoped-key writes for the signed-in user.
// GET /api/v1/user/agent-activity?limit=50
//
// Only a real user session may read the log. A key of any kind is refused so an
// agent cannot inspect or tamper with its own audit trail.
func (h *Handler) ListAgentActivity(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.JSON(http.StatusForbidden, models.ErrorResponse{
			Error:   "forbidden",
			Message: "Sign in with a user account to view agent activity",
			Code:    http.StatusForbidden,
		})
		return
	}
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	activity, err := h.DB.ListAgentActivity(c.Request.Context(), user.ID, limit)
	if err != nil {
		log.Printf("Failed to list agent activity: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to load agent activity",
			Code:    http.StatusInternalServerError,
		})
		return
	}
	c.JSON(http.StatusOK, activity)
}
