package middleware

import "github.com/Shimizu-Technology/media-tools-api/internal/models"

// IsOwnerAPIKey checks if the given API key should bypass limits.
// It matches either the key ID or the key prefix if configured.
func IsOwnerAPIKey(apiKey *models.APIKey, ownerKeyID, ownerKeyPrefix string) bool {
	if apiKey == nil {
		return false
	}
	if ownerKeyID != "" && apiKey.ID == ownerKeyID {
		return true
	}
	if ownerKeyPrefix != "" && apiKey.KeyPrefix == ownerKeyPrefix {
		return true
	}
	return false
}
