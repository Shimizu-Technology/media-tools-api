package handlers

import (
	"math"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// ListLibraryItems returns a unified, paginated view of videos, audio, and PDFs.
func (h *Handler) ListLibraryItems(c *gin.Context) {
	params := models.LibraryListParams{}
	if err := c.ShouldBindQuery(&params); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_query", Message: "Invalid library filters", Code: http.StatusBadRequest})
		return
	}
	actor := getActorOwnership(c)
	params.UserID = actor.UserID
	params.APIKeyID = actor.APIKeyID
	if params.Page < 1 {
		params.Page = 1
	}
	if params.PerPage < 1 || params.PerPage > 100 {
		params.PerPage = 20
	}
	if params.ItemType != "" && params.ItemType != "youtube" && params.ItemType != "audio" && params.ItemType != "pdf" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_query", Message: "type must be youtube, audio, or pdf", Code: http.StatusBadRequest})
		return
	}

	items, total, err := h.DB.ListLibraryItems(c.Request.Context(), params)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: "database_error", Message: "Failed to load library items", Code: http.StatusInternalServerError})
		return
	}
	c.JSON(http.StatusOK, models.PaginatedResponse[models.LibraryItem]{
		Data: items, Page: params.Page, PerPage: params.PerPage, TotalItems: total,
		TotalPages: int(math.Ceil(float64(total) / float64(params.PerPage))),
	})
}

// GetLibraryStats returns exact processing and content-type totals.
func (h *Handler) GetLibraryStats(c *gin.Context) {
	actor := getActorOwnership(c)
	stats, err := h.DB.GetLibraryStats(c.Request.Context(), actor.UserID, actor.APIKeyID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: "database_error", Message: "Failed to load library stats", Code: http.StatusInternalServerError})
		return
	}
	c.JSON(http.StatusOK, stats)
}
