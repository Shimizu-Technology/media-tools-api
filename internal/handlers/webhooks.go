// webhooks.go handles webhook management HTTP endpoints (MTA-18).
package handlers

import (
	"log"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	webhookservice "github.com/Shimizu-Technology/media-tools-api/internal/services/webhook"
)

// CreateWebhook registers a new webhook endpoint.
// POST /api/v1/webhooks
func (h *Handler) CreateWebhook(c *gin.Context) {
	apiKey := middleware.GetAPIKey(c)
	if apiKey == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Webhook management requires API key authentication",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	var req models.CreateWebhookRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "URL and at least one event are required",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Validate events
	for _, event := range req.Events {
		if !models.ValidWebhookEvents[event] {
			c.JSON(http.StatusBadRequest, models.ErrorResponse{
				Error:   "invalid_event",
				Message: "Invalid event type: " + event,
				Code:    http.StatusBadRequest,
			})
			return
		}
	}

	// Generate HMAC secret
	secret, err := webhookservice.GenerateSecret()
	if err != nil {
		log.Printf("❌ Failed to generate webhook secret: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "generation_error",
			Message: "Failed to generate webhook secret",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	wh := &models.Webhook{
		APIKeyID: apiKey.ID,
		URL:      req.URL,
		Events:   req.Events,
		Secret:   secret,
		Active:   true,
	}

	if err := h.DB.CreateWebhook(c.Request.Context(), wh); err != nil {
		log.Printf("❌ Failed to create webhook: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to create webhook",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Return webhook with secret (only shown once, like API keys)
	c.JSON(http.StatusCreated, gin.H{
		"id":         wh.ID,
		"url":        wh.URL,
		"events":     wh.Events,
		"secret":     secret, // Shown once for verification setup
		"active":     wh.Active,
		"created_at": wh.CreatedAt,
	})
}

// ListWebhooks returns all webhooks for the authenticated API key.
// GET /api/v1/webhooks
func (h *Handler) ListWebhooks(c *gin.Context) {
	apiKey := middleware.GetAPIKey(c)
	if apiKey == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Webhook management requires API key authentication",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	webhooks, err := h.DB.ListWebhooksByAPIKey(c.Request.Context(), apiKey.ID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to list webhooks",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	if webhooks == nil {
		webhooks = []models.Webhook{}
	}

	c.JSON(http.StatusOK, webhooks)
}

// UpdateWebhook toggles a webhook's active state.
// PATCH /api/v1/webhooks/:id
func (h *Handler) UpdateWebhook(c *gin.Context) {
	id := c.Param("id")

	var req models.UpdateWebhookRequest
	if err := c.ShouldBindJSON(&req); err != nil || req.Active == nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "active field is required (true/false)",
			Code:    http.StatusBadRequest,
		})
		return
	}

	if err := h.DB.UpdateWebhookActive(c.Request.Context(), id, *req.Active); err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Webhook not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Webhook updated", "active": *req.Active})
}

// DeleteWebhook removes a webhook.
// DELETE /api/v1/webhooks/:id
func (h *Handler) DeleteWebhook(c *gin.Context) {
	id := c.Param("id")

	if err := h.DB.DeleteWebhook(c.Request.Context(), id); err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Webhook not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Webhook deleted"})
}

// ListWebhookDeliveries returns recent delivery attempts for the authenticated API key.
// GET /api/v1/webhooks/deliveries
func (h *Handler) ListWebhookDeliveries(c *gin.Context) {
	apiKey := middleware.GetAPIKey(c)
	if apiKey == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Webhook management requires API key authentication",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	deliveries, err := h.DB.ListAllDeliveriesByAPIKey(c.Request.Context(), apiKey.ID, 50)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to list deliveries",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	if deliveries == nil {
		deliveries = []models.WebhookDelivery{}
	}

	c.JSON(http.StatusOK, deliveries)
}
