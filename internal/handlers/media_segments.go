package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// GetMediaSegments returns source evidence only after the same ownership check
// used by the corresponding item endpoint.
func (h *Handler) GetMediaSegments(c *gin.Context) {
	itemType := c.Param("type")
	itemID := c.Param("id")
	actor := getActorOwnership(c)

	var err error
	switch itemType {
	case "transcript":
		_, err = h.DB.GetTranscriptForActor(c.Request.Context(), itemID, actor.UserID, actor.APIKeyID)
	case "audio":
		_, err = h.DB.GetAudioTranscriptionForActor(c.Request.Context(), itemID, actor.UserID, actor.APIKeyID)
	case "pdf":
		_, err = h.DB.GetPDFExtractionForActor(c.Request.Context(), itemID, actor.UserID, actor.APIKeyID)
	default:
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_item_type", Message: "Unsupported item type", Code: http.StatusBadRequest,
		})
		return
	}
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "Media item not found", Code: http.StatusNotFound,
		})
		return
	}

	segments, err := h.DB.ListMediaSegments(c.Request.Context(), itemType, itemID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "database_error", Message: "Failed to load source evidence", Code: http.StatusInternalServerError,
		})
		return
	}
	c.JSON(http.StatusOK, segments)
}
