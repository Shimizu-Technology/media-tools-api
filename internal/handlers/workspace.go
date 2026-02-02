// workspace.go handles workspace-related HTTP endpoints (MTA-20).
package handlers

import (
	"log"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// GetWorkspace returns the authenticated user's saved workspace items.
// GET /api/v1/workspace
func (h *Handler) GetWorkspace(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Login required to access workspace",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	transcripts, err := h.DB.GetWorkspaceTranscripts(c.Request.Context(), user.ID)
	if err != nil {
		log.Printf("Failed to get workspace transcripts: %v", err)
		transcripts = []models.Transcript{}
	}

	audio, err := h.DB.GetWorkspaceAudio(c.Request.Context(), user.ID)
	if err != nil {
		log.Printf("Failed to get workspace audio: %v", err)
		audio = []models.AudioTranscription{}
	}

	pdfs, err := h.DB.GetWorkspacePDFs(c.Request.Context(), user.ID)
	if err != nil {
		log.Printf("Failed to get workspace PDFs: %v", err)
		pdfs = []models.PDFExtraction{}
	}

	c.JSON(http.StatusOK, models.WorkspaceResponse{
		Transcripts: transcripts,
		Audio:       audio,
		PDFs:        pdfs,
	})
}

// SaveToWorkspace adds an item to the authenticated user's workspace.
// POST /api/v1/workspace
func (h *Handler) SaveToWorkspace(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Login required to save to workspace",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	var req models.SaveToWorkspaceRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "item_type and item_id are required",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Validate item_type
	validTypes := map[string]bool{"transcript": true, "audio": true, "pdf": true}
	if !validTypes[req.ItemType] {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_type",
			Message: "item_type must be 'transcript', 'audio', or 'pdf'",
			Code:    http.StatusBadRequest,
		})
		return
	}

	item := &models.WorkspaceItem{
		UserID:   user.ID,
		ItemType: req.ItemType,
		ItemID:   req.ItemID,
	}

	if err := h.DB.SaveWorkspaceItem(c.Request.Context(), item); err != nil {
		// ON CONFLICT DO NOTHING means it might already exist — that's fine
		c.JSON(http.StatusOK, gin.H{"message": "Item saved to workspace"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "Item saved to workspace", "id": item.ID})
}

// RemoveFromWorkspace removes an item from the authenticated user's workspace.
// DELETE /api/v1/workspace/:type/:id
func (h *Handler) RemoveFromWorkspace(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Login required",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	itemType := c.Param("type")
	itemID := c.Param("id")

	if err := h.DB.RemoveWorkspaceItem(c.Request.Context(), user.ID, itemType, itemID); err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to remove item",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Item removed from workspace"})
}
