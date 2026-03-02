package handlers

import (
	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
)

// actorOwnership captures who owns/requests a resource.
// Exactly one of UserID or APIKeyID should be set for authenticated routes.
type actorOwnership struct {
	UserID   *string
	APIKeyID *string
}

func getActorOwnership(c *gin.Context) actorOwnership {
	if user := middleware.GetUser(c); user != nil {
		return actorOwnership{UserID: &user.ID}
	}
	if apiKey := middleware.GetAPIKey(c); apiKey != nil {
		return actorOwnership{APIKeyID: &apiKey.ID}
	}
	return actorOwnership{}
}

func (a actorOwnership) IsAuthenticated() bool {
	return a.UserID != nil || a.APIKeyID != nil
}
