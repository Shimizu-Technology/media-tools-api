package middleware

import (
	"context"
	"log"
	"net/http"
	"sort"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// scopeRule says which scopes unlock one route. Holding any listed scope is
// enough.
type scopeRule struct {
	method string
	path   string
	scopes []string
}

func (r scopeRule) route() string { return r.method + " " + r.path }

func rule(method, path string, scopes ...string) scopeRule {
	return scopeRule{method: method, path: path, scopes: scopes}
}

// scopedKeyRules is the complete list of routes a scoped key may reach.
//
// This is an allow list on purpose. A route that is not here is denied to
// scoped keys, so a route added later (key management, passwords, passkeys,
// sessions, webhooks, ops, account deletion, anything new) fails closed until
// someone decides it belongs. router_scope_test.go walks the real route table
// and makes that decision explicit in review.
var scopedKeyRules = []scopeRule{
	// library:read: everything that only reads media, chat history, or exports.
	rule("GET", "/api/v1/transcripts", models.ScopeLibraryRead),
	rule("GET", "/api/v1/transcripts/:id", models.ScopeLibraryRead),
	rule("GET", "/api/v1/transcripts/:id/summaries", models.ScopeLibraryRead),
	rule("GET", "/api/v1/transcripts/:id/chat", models.ScopeLibraryRead),
	rule("GET", "/api/v1/transcripts/:id/export", models.ScopeLibraryRead),
	rule("GET", "/api/v1/batches/:id", models.ScopeLibraryRead),
	rule("GET", "/api/v1/audio/transcriptions", models.ScopeLibraryRead),
	rule("GET", "/api/v1/audio/transcriptions/search", models.ScopeLibraryRead),
	rule("GET", "/api/v1/audio/transcriptions/:id", models.ScopeLibraryRead),
	rule("GET", "/api/v1/audio/transcriptions/:id/audio", models.ScopeLibraryRead),
	rule("GET", "/api/v1/audio/transcriptions/:id/chat", models.ScopeLibraryRead),
	rule("GET", "/api/v1/audio/transcriptions/:id/export", models.ScopeLibraryRead),
	rule("GET", "/api/v1/pdf/extractions", models.ScopeLibraryRead),
	rule("GET", "/api/v1/pdf/extractions/:id", models.ScopeLibraryRead),
	rule("GET", "/api/v1/pdf/extractions/:id/chat", models.ScopeLibraryRead),
	rule("GET", "/api/v1/collections", models.ScopeLibraryRead),
	rule("GET", "/api/v1/collections/:id", models.ScopeLibraryRead),
	rule("GET", "/api/v1/collections/:id/chat", models.ScopeLibraryRead),
	rule("GET", "/api/v1/library/items", models.ScopeLibraryRead),
	rule("GET", "/api/v1/library/stats", models.ScopeLibraryRead),
	rule("GET", "/api/v1/library/items/:type/:id/preferences", models.ScopeLibraryRead),
	rule("GET", "/api/v1/library/items/:type/:id/segments", models.ScopeLibraryRead),

	// library:write: create, change, retry, summarize, and chat.
	rule("POST", "/api/v1/transcripts", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/transcripts/batch", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/transcripts/:id/chat", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/summaries", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/audio/transcribe", models.ScopeLibraryWrite),
	rule("PATCH", "/api/v1/audio/transcriptions/:id", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/audio/transcriptions/:id/cancel", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/audio/transcriptions/:id/retry", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/audio/transcriptions/:id/format", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/audio/transcriptions/:id/summarize", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/audio/transcriptions/:id/chat", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/pdf/extract", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/pdf/extractions/:id/chat", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/collections", models.ScopeLibraryWrite),
	rule("PATCH", "/api/v1/collections/:id", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/collections/:id/items", models.ScopeLibraryWrite),
	rule("DELETE", "/api/v1/collections/:id/items/:itemId", models.ScopeLibraryWrite),
	rule("POST", "/api/v1/collections/:id/chat", models.ScopeLibraryWrite),
	rule("PATCH", "/api/v1/library/items/:type/:id/preferences", models.ScopeLibraryWrite),

	// library:delete: removing media or a whole collection.
	rule("DELETE", "/api/v1/transcripts/:id", models.ScopeLibraryDelete),
	rule("DELETE", "/api/v1/audio/transcriptions/:id", models.ScopeLibraryDelete),
	rule("DELETE", "/api/v1/pdf/extractions/:id", models.ScopeLibraryDelete),
	rule("DELETE", "/api/v1/collections/:id", models.ScopeLibraryDelete),

	// capture:upload: only the two calls a share extension needs to hand a
	// recording to the server. It is deliberately not a library scope, so a
	// key kept on a phone for sharing cannot read or change anything.
	// library:write also covers them for agents that upload on someone's behalf.
	rule("POST", "/api/v1/audio/uploads/presign", models.ScopeCaptureUpload, models.ScopeLibraryWrite),
	rule("POST", "/api/v1/audio/uploads/complete", models.ScopeCaptureUpload, models.ScopeLibraryWrite),
}

// ScopedKeyAllowedRoutes returns every "METHOD path" a scoped key can ever
// reach, sorted. Tests use it to pin the surface and to detect stale rules.
func ScopedKeyAllowedRoutes() []string {
	routes := make([]string, 0, len(scopedKeyRules))
	for _, r := range scopedKeyRules {
		routes = append(routes, r.route())
	}
	sort.Strings(routes)
	return routes
}

// ScopedKeyPermits reports whether a key holding scopes may call method on the
// registered route pattern. Unknown routes are never permitted.
func ScopedKeyPermits(scopes []string, method, pattern string) bool {
	key := &models.APIKey{Scopes: scopes}
	for _, r := range scopedKeyRules {
		if r.method != method || r.path != pattern {
			continue
		}
		for _, scope := range r.scopes {
			if key.HasScope(scope) {
				return true
			}
		}
	}
	return false
}

// AgentActivityRecorder stores audit rows. *database.DB implements it.
type AgentActivityRecorder interface {
	RecordAgentActivity(ctx context.Context, activity models.AgentActivity) error
}

const activityItemContextKey = "agent_activity_item"

type activityItem struct{ itemType, itemID string }

// SetActivityItem lets a handler name the item it just created, since the
// route alone cannot (POST /collections has no :id yet). Identifiers only.
func SetActivityItem(c *gin.Context, itemType, itemID string) {
	c.Set(activityItemContextKey, activityItem{itemType: itemType, itemID: itemID})
}

// ScopedKeyAccess enforces scopes and audits scoped keys. Classic keys and
// signed-in users pass straight through untouched, so existing behavior holds.
// It must run after DualAuth.
func ScopedKeyAccess(recorder AgentActivityRecorder) gin.HandlerFunc {
	return func(c *gin.Context) {
		key := GetAPIKey(c)
		if !key.IsScoped() {
			c.Next()
			return
		}

		method, pattern := c.Request.Method, c.FullPath()
		if key.UserID == nil || !ScopedKeyPermits(key.Scopes, method, pattern) {
			c.JSON(http.StatusForbidden, models.ErrorResponse{
				Error:   "forbidden_scope",
				Message: "This API key's scopes do not allow this request",
				Code:    http.StatusForbidden,
			})
			c.Abort()
			recordAgentActivity(c, recorder, key, method, pattern, http.StatusForbidden)
			return
		}

		c.Next()
		if method != http.MethodGet && method != http.MethodHead {
			recordAgentActivity(c, recorder, key, method, pattern, c.Writer.Status())
		}
	}
}

func recordAgentActivity(c *gin.Context, recorder AgentActivityRecorder, key *models.APIKey, method, pattern string, status int) {
	if recorder == nil || key.UserID == nil {
		return
	}
	itemType, itemID := activityItemFor(c, pattern)
	// The request may already be cancelled (client hung up); the audit row
	// still matters, so detach from cancellation but keep a deadline.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(c.Request.Context()), 3*time.Second)
	defer cancel()
	err := recorder.RecordAgentActivity(ctx, models.AgentActivity{
		UserID:     *key.UserID,
		APIKeyID:   &key.ID,
		APIKeyName: key.Name,
		Method:     method,
		Route:      pattern,
		ItemType:   itemType,
		ItemID:     itemID,
		StatusCode: status,
	})
	if err != nil {
		// Never log the request: the error carries no content, only the cause.
		log.Printf("Failed to record agent activity: %v", err)
	}
}

// activityItemFor picks the item from a handler hint or the route parameters.
// Only UUIDs are kept, so a crafted path segment can never reach the log.
func activityItemFor(c *gin.Context, pattern string) (string, string) {
	if v, ok := c.Get(activityItemContextKey); ok {
		if item, ok := v.(activityItem); ok && isUUID(item.itemID) {
			return item.itemType, item.itemID
		}
	}
	id := c.Param("id")
	if !isUUID(id) {
		return "", ""
	}
	switch {
	case hasRoutePrefix(pattern, "/api/v1/transcripts"):
		return "transcript", id
	case hasRoutePrefix(pattern, "/api/v1/audio/transcriptions"):
		return "audio", id
	case hasRoutePrefix(pattern, "/api/v1/pdf/extractions"):
		return "pdf", id
	case hasRoutePrefix(pattern, "/api/v1/collections"):
		return "collection", id
	case hasRoutePrefix(pattern, "/api/v1/batches"):
		return "batch", id
	case hasRoutePrefix(pattern, "/api/v1/library/items"):
		switch c.Param("type") {
		case "audio":
			return "audio", id
		case "pdf":
			return "pdf", id
		case "transcript", "youtube":
			return "transcript", id
		}
	}
	return "", ""
}

func hasRoutePrefix(pattern, prefix string) bool {
	return len(pattern) >= len(prefix) && pattern[:len(prefix)] == prefix
}

func isUUID(value string) bool {
	_, err := uuid.Parse(value)
	return err == nil && len(value) == 36
}
