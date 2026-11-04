package models

import "time"

// Scoped key permissions. The list is fixed: the database enforces it with a
// CHECK constraint and CreateUserAPIKey validates against it, so a typo can
// never mint a key with a scope nothing recognises.
const (
	ScopeLibraryRead   = "library:read"
	ScopeLibraryWrite  = "library:write"
	ScopeLibraryDelete = "library:delete"
	ScopeCaptureUpload = "capture:upload"
)

// ScopedKeyRateLimit is the hourly budget for scoped keys. Classic keys keep
// the public default of 100; an agent filing a library needs room to list and
// read many items per run.
const ScopedKeyRateLimit = 2000

// AllAPIKeyScopes lists every valid scope in display order.
func AllAPIKeyScopes() []string {
	return []string{ScopeLibraryRead, ScopeLibraryWrite, ScopeLibraryDelete, ScopeCaptureUpload}
}

// NormalizeAPIKeyScopes validates a requested scope list. It returns the
// scopes de-duplicated in canonical order, or the first unknown value.
func NormalizeAPIKeyScopes(requested []string) (scopes []string, unknown string) {
	wanted := make(map[string]bool, len(requested))
	for _, scope := range requested {
		valid := false
		for _, known := range AllAPIKeyScopes() {
			if scope == known {
				valid = true
				break
			}
		}
		if !valid {
			return nil, scope
		}
		wanted[scope] = true
	}
	for _, known := range AllAPIKeyScopes() {
		if wanted[known] {
			scopes = append(scopes, known)
		}
	}
	return scopes, ""
}

// IsScoped reports whether the key is a scoped agent key. Classic keys carry
// no scopes and keep their original exact-key behavior.
func (k *APIKey) IsScoped() bool {
	return k != nil && len(k.Scopes) > 0
}

// HasScope reports whether the key was granted scope.
func (k *APIKey) HasScope(scope string) bool {
	if k == nil {
		return false
	}
	for _, granted := range k.Scopes {
		if granted == scope {
			return true
		}
	}
	return false
}

// AgentActivity is one audited scoped-key request. It deliberately has no
// field that could hold transcript text, titles, or search terms.
type AgentActivity struct {
	ID         string    `json:"id" db:"id"`
	UserID     string    `json:"-" db:"user_id"`
	APIKeyID   *string   `json:"api_key_id,omitempty" db:"api_key_id"`
	APIKeyName string    `json:"api_key_name" db:"api_key_name"`
	Method     string    `json:"method" db:"method"`
	Route      string    `json:"route" db:"route"`
	ItemType   string    `json:"item_type,omitempty" db:"item_type"`
	ItemID     string    `json:"item_id,omitempty" db:"item_id"`
	StatusCode int       `json:"status_code" db:"status_code"`
	CreatedAt  time.Time `json:"created_at" db:"created_at"`
}
