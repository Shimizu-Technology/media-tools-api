package middleware

import "testing"

func TestValidateAuthorizedParty(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		expected  string
		actual    string
		wantError bool
	}{
		{
			name:     "matching browser origin",
			expected: "https://media-tools-gu.netlify.app",
			actual:   "https://media-tools-gu.netlify.app",
		},
		{
			name:     "native token omits authorized party",
			expected: "https://media-tools-gu.netlify.app",
			actual:   "",
		},
		{
			name:     "constraint disabled",
			expected: "",
			actual:   "https://another.example",
		},
		{
			name:      "conflicting browser origin",
			expected:  "https://media-tools-gu.netlify.app",
			actual:    "https://attacker.example",
			wantError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			err := validateAuthorizedParty(tt.expected, tt.actual)
			if tt.wantError && err == nil {
				t.Fatal("expected authorized-party validation to fail")
			}
			if !tt.wantError && err != nil {
				t.Fatalf("expected authorized-party validation to pass: %v", err)
			}
		})
	}
}
