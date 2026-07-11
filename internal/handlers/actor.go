package handlers

import (
	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// actorOwnership captures the current authentication principal. API-key reads
// remain scoped to the exact key, even when that key belongs to a user.
type actorOwnership struct {
	UserID   *string
	APIKeyID *string
}

func getActorOwnership(c *gin.Context) actorOwnership {
	if user := middleware.GetUser(c); user != nil {
		return actorOwnership{UserID: &user.ID}
	}
	if apiKey := middleware.GetAPIKey(c); apiKey != nil {
		return readOwnershipForAPIKey(apiKey)
	}
	return actorOwnership{}
}

func readOwnershipForAPIKey(apiKey *models.APIKey) actorOwnership {
	if apiKey == nil {
		return actorOwnership{}
	}
	return actorOwnership{APIKeyID: &apiKey.ID}
}

// getActorWriteOwnership adds the owning user only while creating content.
// The dual ownership makes key-created media visible in the signed-in user
// workspace without granting that key the user's broader read scope.
func getActorWriteOwnership(c *gin.Context) actorOwnership {
	if user := middleware.GetUser(c); user != nil {
		return actorOwnership{UserID: &user.ID}
	}
	return writeOwnershipForAPIKey(middleware.GetAPIKey(c))
}

func writeOwnershipForAPIKey(apiKey *models.APIKey) actorOwnership {
	if apiKey == nil {
		return actorOwnership{}
	}
	return actorOwnership{UserID: apiKey.UserID, APIKeyID: &apiKey.ID}
}

func (a actorOwnership) IsAuthenticated() bool {
	return a.UserID != nil || a.APIKeyID != nil
}
