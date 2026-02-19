// collections.go handles collection CRUD endpoints and collection-level AI chat.
// Collections allow users to group transcripts, audio transcriptions,
// and PDF extractions together for organization and cross-item AI analysis.
package handlers

import (
	"fmt"
	"log"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
)

// getOwnership extracts user ID and API key ID from the request context.
// Collections can be owned by either a Clerk user or an API key.
func getOwnership(c *gin.Context) (userID, apiKeyID *string) {
	if user := middleware.GetUser(c); user != nil {
		return &user.ID, nil
	}
	if apiKey := middleware.GetAPIKey(c); apiKey != nil {
		return nil, &apiKey.ID
	}
	return nil, nil
}

// ListCollections returns all collections for the authenticated user/key.
// GET /api/v1/collections
func (h *Handler) ListCollections(c *gin.Context) {
	userID, apiKeyID := getOwnership(c)
	if userID == nil && apiKeyID == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error: "unauthorized", Message: "Authentication required", Code: http.StatusUnauthorized,
		})
		return
	}

	collections, err := h.DB.ListCollections(c.Request.Context(), userID, apiKeyID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "internal_error", Message: "Failed to list collections", Code: http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusOK, collections)
}

// CreateCollection creates a new collection.
// POST /api/v1/collections
func (h *Handler) CreateCollection(c *gin.Context) {
	var req models.CreateCollectionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: "Name is required (max 255 chars)", Code: http.StatusBadRequest,
		})
		return
	}

	userID, apiKeyID := getOwnership(c)
	if userID == nil && apiKeyID == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error: "unauthorized", Message: "Authentication required", Code: http.StatusUnauthorized,
		})
		return
	}

	col := &models.Collection{
		Name:        req.Name,
		Description: req.Description,
		UserID:      userID,
		APIKeyID:    apiKeyID,
	}

	if err := h.DB.CreateCollection(c.Request.Context(), col); err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "internal_error", Message: "Failed to create collection", Code: http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusCreated, col)
}

// GetCollection returns a single collection with its items.
// GET /api/v1/collections/:id
func (h *Handler) GetCollection(c *gin.Context) {
	id := c.Param("id")
	userID, apiKeyID := getOwnership(c)

	col, err := h.DB.GetCollection(c.Request.Context(), id, userID, apiKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "Collection not found", Code: http.StatusNotFound,
		})
		return
	}

	items, err := h.DB.GetCollectionItems(c.Request.Context(), id)
	if err != nil {
		items = []models.CollectionItem{}
	}

	c.JSON(http.StatusOK, models.CollectionWithItems{
		Collection: *col,
		Items:      items,
	})
}

// UpdateCollection updates a collection's name and/or description.
// PATCH /api/v1/collections/:id
func (h *Handler) UpdateCollection(c *gin.Context) {
	id := c.Param("id")
	var req models.UpdateCollectionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: "Invalid request body", Code: http.StatusBadRequest,
		})
		return
	}

	userID, apiKeyID := getOwnership(c)

	col, err := h.DB.UpdateCollection(c.Request.Context(), id, userID, apiKeyID, req.Name, req.Description)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "Collection not found or not owned by you", Code: http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, col)
}

// DeleteCollection removes a collection (items are NOT deleted, just ungrouped).
// DELETE /api/v1/collections/:id
func (h *Handler) DeleteCollection(c *gin.Context) {
	id := c.Param("id")
	userID, apiKeyID := getOwnership(c)

	if err := h.DB.DeleteCollection(c.Request.Context(), id, userID, apiKeyID); err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "Collection not found or not owned by you", Code: http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Collection deleted"})
}

// AddCollectionItems adds one or more items to a collection.
// POST /api/v1/collections/:id/items
func (h *Handler) AddCollectionItems(c *gin.Context) {
	id := c.Param("id")
	userID, apiKeyID := getOwnership(c)

	// Verify ownership first
	_, err := h.DB.GetCollection(c.Request.Context(), id, userID, apiKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "Collection not found", Code: http.StatusNotFound,
		})
		return
	}

	var req models.AddCollectionItemsRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: "Provide items array with item_type and item_id", Code: http.StatusBadRequest,
		})
		return
	}

	added, err := h.DB.AddCollectionItems(c.Request.Context(), id, req.Items)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "internal_error", Message: "Failed to add items", Code: http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"added": added})
}

// RemoveCollectionItem removes a single item from a collection.
// DELETE /api/v1/collections/:id/items/:itemId
func (h *Handler) RemoveCollectionItem(c *gin.Context) {
	collectionID := c.Param("id")
	itemID := c.Param("itemId")
	userID, apiKeyID := getOwnership(c)

	// Verify ownership
	_, err := h.DB.GetCollection(c.Request.Context(), collectionID, userID, apiKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "Collection not found", Code: http.StatusNotFound,
		})
		return
	}

	if err := h.DB.RemoveCollectionItem(c.Request.Context(), collectionID, itemID); err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "Item not found in collection", Code: http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Item removed from collection"})
}

// GetCollectionChat returns the chat session for a collection.
// GET /api/v1/collections/:id/chat
func (h *Handler) GetCollectionChat(c *gin.Context) {
	id := c.Param("id")
	userID, apiKeyID := getOwnership(c)

	_, err := h.DB.GetCollection(c.Request.Context(), id, userID, apiKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "Collection not found", Code: http.StatusNotFound,
		})
		return
	}

	session, err := h.DB.GetOrCreateChatSession(c.Request.Context(), "collection", id, apiKeyID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "database_error", Message: "Failed to load chat session", Code: http.StatusInternalServerError,
		})
		return
	}

	messages, err := h.DB.ListChatMessages(c.Request.Context(), session.ID, 100)
	if err != nil {
		messages = []models.TranscriptChatMessage{}
	}

	c.JSON(http.StatusOK, models.ChatResponse{Session: *session, Messages: messages})
}

// PostCollectionChat sends a message about all items in a collection.
// POST /api/v1/collections/:id/chat
func (h *Handler) PostCollectionChat(c *gin.Context) {
	if h.Summarizer == nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error: "service_unavailable", Message: "AI chat not configured. Set OPENROUTER_API_KEY.", Code: http.StatusServiceUnavailable,
		})
		return
	}

	id := c.Param("id")
	userID, apiKeyID := getOwnership(c)

	col, err := h.DB.GetCollection(c.Request.Context(), id, userID, apiKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error: "not_found", Message: "Collection not found", Code: http.StatusNotFound,
		})
		return
	}

	var req models.CreateChatMessageRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: "message is required", Code: http.StatusBadRequest,
		})
		return
	}
	req.Message = strings.TrimSpace(req.Message)
	if req.Message == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_request", Message: "message cannot be empty", Code: http.StatusBadRequest,
		})
		return
	}

	// Load all item texts from collection
	contents, err := h.DB.GetCollectionItemContents(c.Request.Context(), id)
	if err != nil {
		log.Printf("Failed to load collection contents for %s: %v", id, err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "database_error", Message: "Failed to load collection contents", Code: http.StatusInternalServerError,
		})
		return
	}
	if len(contents) == 0 {
		c.JSON(http.StatusConflict, models.ErrorResponse{
			Error: "no_content", Message: "Collection has no completed items to chat about", Code: http.StatusConflict,
		})
		return
	}

	// Build combined context: label each item's content
	var combined strings.Builder
	for i, item := range contents {
		label := fmt.Sprintf("[%s] %s", item.ItemType, item.Title)
		if item.Title == "" {
			label = fmt.Sprintf("[%s #%d]", item.ItemType, i+1)
		}
		combined.WriteString(fmt.Sprintf("=== %s ===\n%s\n\n", label, item.Text))
	}

	contextLabel := fmt.Sprintf("collection '%s' containing %d items", col.Name, len(contents))

	// Chat session
	session, err := h.DB.GetOrCreateChatSession(c.Request.Context(), "collection", id, apiKeyID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "database_error", Message: "Failed to load chat session", Code: http.StatusInternalServerError,
		})
		return
	}

	history, _ := h.DB.ListChatMessages(c.Request.Context(), session.ID, 40)

	// Save user message
	userMsg := &models.TranscriptChatMessage{SessionID: session.ID, Role: "user", Content: req.Message}
	if err := h.DB.CreateChatMessage(c.Request.Context(), userMsg); err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "database_error", Message: "Failed to save message", Code: http.StatusInternalServerError,
		})
		return
	}

	// Build history for AI
	chatHistory := make([]summary.ChatMessage, 0, len(history)+1)
	for _, m := range history {
		if m.Content == "" || (m.Role != "user" && m.Role != "assistant") {
			continue
		}
		chatHistory = append(chatHistory, summary.ChatMessage{Role: m.Role, Content: m.Content})
	}
	chatHistory = append(chatHistory, summary.ChatMessage{Role: "user", Content: req.Message})

	answer, modelUsed, err := h.Summarizer.ChatTranscript(
		c.Request.Context(),
		contextLabel,
		combined.String(),
		chatHistory,
		req.Model,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "ai_error", Message: "Failed to generate response: " + err.Error(), Code: http.StatusInternalServerError,
		})
		return
	}

	assistantMsg := &models.TranscriptChatMessage{
		SessionID: session.ID, Role: "assistant",
		Content: strings.TrimSpace(answer), ModelUsed: modelUsed,
	}
	_ = h.DB.CreateChatMessage(c.Request.Context(), assistantMsg)

	c.JSON(http.StatusOK, models.ChatResponse{
		Session:  *session,
		Messages: []models.TranscriptChatMessage{*userMsg, *assistantMsg},
	})
}
