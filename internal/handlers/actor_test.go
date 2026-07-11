package handlers

import (
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestOwnershipForUserOwnedAPIKeyIncludesBothScopes(t *testing.T) {
	userID := "user-id"
	actor := ownershipForAPIKey(&models.APIKey{ID: "key-id", UserID: &userID})

	if actor.UserID == nil || *actor.UserID != userID {
		t.Fatalf("expected user ownership %q, got %#v", userID, actor.UserID)
	}
	if actor.APIKeyID == nil || *actor.APIKeyID != "key-id" {
		t.Fatalf("expected API key ownership, got %#v", actor.APIKeyID)
	}
}

func TestOwnershipForStandaloneAPIKeyOnlyIncludesKeyScope(t *testing.T) {
	actor := ownershipForAPIKey(&models.APIKey{ID: "key-id"})

	if actor.UserID != nil {
		t.Fatalf("expected no user ownership, got %#v", actor.UserID)
	}
	if actor.APIKeyID == nil || *actor.APIKeyID != "key-id" {
		t.Fatalf("expected API key ownership, got %#v", actor.APIKeyID)
	}
}
