package handlers

import (
	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// actorOwnership captures every scope through which the caller may access a
// resource. A developer key owned by a user carries both IDs so content created
// through the key also appears in the owner's signed-in workspace.
type actorOwnership struct {
	UserID   *string
	APIKeyID *string
}

func getActorOwnership(c *gin.Context) actorOwnership {
	if user := middleware.GetUser(c); user != nil {
		return actorOwnership{UserID: &user.ID}
	}
	if apiKey := middleware.GetAPIKey(c); apiKey != nil {
		return ownershipForAPIKey(apiKey)
	}
	return actorOwnership{}
}

func ownershipForAPIKey(apiKey *models.APIKey) actorOwnership {
	if apiKey == nil {
		return actorOwnership{}
	}
	return actorOwnership{UserID: apiKey.UserID, APIKeyID: &apiKey.ID}
}

func (a actorOwnership) IsAuthenticated() bool {
	return a.UserID != nil || a.APIKeyID != nil
}
