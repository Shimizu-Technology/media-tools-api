package handlers

import (
	"log"
	"strings"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/gin-gonic/gin"
)

// Current iOS/web/CLI clients default to the server model (empty override).
// Keep the documented GPT-4o choices and the configured production defaults.
// Arbitrary CLI --model overrides are intentionally restricted for capped users.
var publicAIModels = map[string]bool{
	"openai/gpt-4o":                        true,
	"openai/gpt-4o-mini":                   true,
	"google/gemini-2.5-flash":              true,
	"google/gemini-2.5-flash-lite":         true,
	"anthropic/claude-4.5-sonnet-20250929": true,
}

func (h *Handler) allowAIModel(c *gin.Context, model string) bool {
	if strings.TrimSpace(model) == "" || publicAIModels[strings.TrimSpace(model)] {
		return true
	}
	account := usageAccount(c)
	// Derive exemption from exact owner configuration, not the legacy prefix helper.
	if account != "" {
		if !h.ensureUsage(c, account) {
			return false
		}
		usage, err := h.DB.AccountUsage(c.Request.Context(), account)
		if err != nil {
			log.Printf("usage lookup failed: %v", err)
			authError(c, 503, "usage_unavailable", "Could not check account usage; retry")
			return false
		}
		if usage.Exempt {
			return true
		}
	} else if keyID := h.OwnerAPIKeyID; keyID != "" {
		// Unowned legacy keys may use only the exact configured key id.
		if key := middleware.GetAPIKey(c); key != nil && key.ID == keyID {
			return true
		}
	}
	authError(c, 400, "invalid_model", "Choose an allowed AI model or omit model to use the default")
	return false
}
