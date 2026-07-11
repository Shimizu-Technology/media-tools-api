package handlers

import (
	"log"
	"math"
	"net/http"
	"strings"
	"unicode/utf8"

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
	if params.Archive != "" && params.Archive != "all" && params.Archive != "only" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_query", Message: "archive must be all or only", Code: http.StatusBadRequest})
		return
	}
	if params.Favorite != "" && params.Favorite != "true" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_query", Message: "favorite must be true", Code: http.StatusBadRequest})
		return
	}

	items, total, err := h.DB.ListLibraryItems(c.Request.Context(), params)
	if err != nil {
		log.Printf("Failed to load library items: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: "database_error", Message: "Failed to load library items", Code: http.StatusInternalServerError})
		return
	}
	c.JSON(http.StatusOK, models.PaginatedResponse[models.LibraryItem]{
		Data: items, Page: params.Page, PerPage: params.PerPage, TotalItems: total,
		TotalPages: int(math.Ceil(float64(total) / float64(params.PerPage))),
	})
}

func (h *Handler) GetLibraryPreferences(c *gin.Context) {
	itemType, ownershipType, ok := libraryPreferenceTypes(c.Param("type"))
	if !ok {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_item_type", Message: "type must be transcript, audio, or pdf", Code: http.StatusBadRequest})
		return
	}
	actor := getActorOwnership(c)
	owned, err := h.DB.ActorOwnsCollectionItem(c.Request.Context(), ownershipType, c.Param("id"), actor.UserID, actor.APIKeyID)
	if err != nil {
		log.Printf("Failed to verify library item ownership: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: "database_error", Message: "Failed to verify library item ownership", Code: http.StatusInternalServerError})
		return
	}
	if !owned {
		c.JSON(http.StatusNotFound, models.ErrorResponse{Error: "not_found", Message: "Library item not found", Code: http.StatusNotFound})
		return
	}
	preferences, err := h.DB.GetLibraryPreferences(c.Request.Context(), itemType, c.Param("id"), actor.UserID, actor.APIKeyID)
	if err != nil {
		log.Printf("Failed to load library preferences: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: "database_error", Message: "Failed to load library preferences", Code: http.StatusInternalServerError})
		return
	}
	c.JSON(http.StatusOK, preferences)
}

func (h *Handler) UpdateLibraryPreferences(c *gin.Context) {
	itemType, ownershipType, ok := libraryPreferenceTypes(c.Param("type"))
	if !ok {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_item_type", Message: "type must be transcript, audio, or pdf", Code: http.StatusBadRequest})
		return
	}
	var req models.UpdateLibraryPreferencesRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "Invalid preference update", Code: http.StatusBadRequest})
		return
	}
	if req.Tags != nil {
		seen := make(map[string]bool)
		tags := make([]string, 0, len(req.Tags))
		for _, value := range req.Tags {
			value = strings.TrimSpace(value)
			key := strings.ToLower(value)
			if value == "" || seen[key] {
				continue
			}
			if utf8.RuneCountInString(value) > 40 || len(tags) >= 20 {
				c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_tags", Message: "Use at most 20 tags with 40 characters each", Code: http.StatusBadRequest})
				return
			}
			seen[key] = true
			tags = append(tags, value)
		}
		req.Tags = tags
	}
	actor := getActorOwnership(c)
	owned, err := h.DB.ActorOwnsCollectionItem(c.Request.Context(), ownershipType, c.Param("id"), actor.UserID, actor.APIKeyID)
	if err != nil {
		log.Printf("Failed to verify library item ownership: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: "database_error", Message: "Failed to verify library item ownership", Code: http.StatusInternalServerError})
		return
	}
	if !owned {
		c.JSON(http.StatusNotFound, models.ErrorResponse{Error: "not_found", Message: "Library item not found", Code: http.StatusNotFound})
		return
	}
	preferences, err := h.DB.UpdateLibraryPreferences(c.Request.Context(), itemType, c.Param("id"), actor.UserID, actor.APIKeyID, req)
	if err != nil {
		log.Printf("Failed to update library preferences: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: "database_error", Message: "Failed to update library preferences", Code: http.StatusInternalServerError})
		return
	}
	c.JSON(http.StatusOK, preferences)
}

func libraryPreferenceTypes(value string) (storageType, ownershipType string, ok bool) {
	switch value {
	case "transcript", "youtube":
		return "youtube", "transcript", true
	case "audio":
		return "audio", "audio", true
	case "pdf":
		return "pdf", "pdf", true
	default:
		return "", "", false
	}
}

// GetLibraryStats returns exact processing and content-type totals.
func (h *Handler) GetLibraryStats(c *gin.Context) {
	actor := getActorOwnership(c)
	stats, err := h.DB.GetLibraryStats(c.Request.Context(), actor.UserID, actor.APIKeyID)
	if err != nil {
		log.Printf("Failed to load library stats: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: "database_error", Message: "Failed to load library stats", Code: http.StatusInternalServerError})
		return
	}
	c.JSON(http.StatusOK, stats)
}
