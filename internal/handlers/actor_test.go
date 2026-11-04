package handlers

import (
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestReadOwnershipForUserOwnedAPIKeyOnlyIncludesKeyScope(t *testing.T) {
	userID := "user-id"
	actor := readOwnershipForAPIKey(&models.APIKey{ID: "key-id", UserID: &userID})

	if actor.UserID != nil {
		t.Fatalf("read scope leaked owning user: %#v", actor.UserID)
	}
	if actor.APIKeyID == nil || *actor.APIKeyID != "key-id" {
		t.Fatalf("expected exact API key scope, got %#v", actor.APIKeyID)
	}
}

func TestWriteOwnershipForUserOwnedAPIKeyIncludesBothScopes(t *testing.T) {
	userID := "user-id"
	actor := writeOwnershipForAPIKey(&models.APIKey{ID: "key-id", UserID: &userID})

	if actor.UserID == nil || *actor.UserID != userID {
		t.Fatalf("expected user ownership %q, got %#v", userID, actor.UserID)
	}
	if actor.APIKeyID == nil || *actor.APIKeyID != "key-id" {
		t.Fatalf("expected API key ownership, got %#v", actor.APIKeyID)
	}
}

func TestWriteOwnershipForStandaloneAPIKeyOnlyIncludesKeyScope(t *testing.T) {
	actor := writeOwnershipForAPIKey(&models.APIKey{ID: "key-id"})

	if actor.UserID != nil {
		t.Fatalf("expected no user ownership, got %#v", actor.UserID)
	}
	if actor.APIKeyID == nil || *actor.APIKeyID != "key-id" {
		t.Fatalf("expected API key ownership, got %#v", actor.APIKeyID)
	}
}

func TestReadOwnershipForScopedKeyActsAsOwningUser(t *testing.T) {
	userID := "user-id"
	actor := readOwnershipForAPIKey(&models.APIKey{ID: "key-id", UserID: &userID, Scopes: []string{models.ScopeLibraryRead}})

	if actor.UserID == nil || *actor.UserID != userID {
		t.Fatalf("scoped key must read as its owner, got %#v", actor.UserID)
	}
	if actor.APIKeyID != nil {
		t.Fatalf("scoped key read should not be limited to the exact key, got %#v", actor.APIKeyID)
	}
}

func TestReadOwnershipForScopedKeyWithoutOwnerStaysExactKey(t *testing.T) {
	actor := readOwnershipForAPIKey(&models.APIKey{ID: "key-id", Scopes: []string{models.ScopeLibraryRead}})

	if actor.UserID != nil || actor.APIKeyID == nil {
		t.Fatalf("ownerless scoped key must not gain user scope, got %#v", actor)
	}
}

func TestWriteOwnershipForScopedKeyKeepsBothScopes(t *testing.T) {
	userID := "user-id"
	actor := writeOwnershipForAPIKey(&models.APIKey{ID: "key-id", UserID: &userID, Scopes: []string{models.ScopeLibraryWrite}})

	if actor.UserID == nil || actor.APIKeyID == nil {
		t.Fatalf("expected user and key ownership, got %#v", actor)
	}
}
