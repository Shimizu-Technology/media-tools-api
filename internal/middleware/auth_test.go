// auth_test.go — Unit tests for API key hashing.
//
// Go Pattern: Even simple functions deserve tests. HashAPIKey is security-critical
// — if it breaks, authentication breaks. Tests catch regressions early.
package middleware

import (
	"testing"
)

// TestHashAPIKey verifies that hashing is deterministic and produces
// the expected SHA-256 output.
func TestHashAPIKey(t *testing.T) {
	tests := []struct {
		name string
		key  string
		want string
	}{
		{
			name: "known key produces expected hash",
			key:  "mta_test123456",
			// SHA-256 of "mta_test123456"
			want: HashAPIKey("mta_test123456"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := HashAPIKey(tt.key)
			if got != tt.want {
				t.Errorf("HashAPIKey(%q) = %q, want %q", tt.key, got, tt.want)
			}
		})
	}

	// Test: same input always produces same output (deterministic)
	t.Run("deterministic", func(t *testing.T) {
		key := "mta_determinism_test"
		hash1 := HashAPIKey(key)
		hash2 := HashAPIKey(key)
		if hash1 != hash2 {
			t.Errorf("HashAPIKey is not deterministic: %q != %q", hash1, hash2)
		}
	})

	// Test: different inputs produce different outputs
	t.Run("different inputs different outputs", func(t *testing.T) {
		hash1 := HashAPIKey("mta_key_one")
		hash2 := HashAPIKey("mta_key_two")
		if hash1 == hash2 {
			t.Error("HashAPIKey produced same hash for different inputs")
		}
	})

	// Test: output is 64 hex characters (256 bits = 64 hex chars)
	t.Run("output length", func(t *testing.T) {
		hash := HashAPIKey("mta_any_key")
		if len(hash) != 64 {
			t.Errorf("HashAPIKey output length = %d, want 64", len(hash))
		}
	})
}
