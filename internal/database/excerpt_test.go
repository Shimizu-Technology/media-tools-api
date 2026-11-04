package database

import (
	"strings"
	"testing"
)

func TestPlainExcerpt(t *testing.T) {
	for _, tc := range []struct{ input, want string }{
		{"## **Meeting**\n- Call tomorrow [1] [^note] 【source】", "Meeting Call tomorrow"},
		{`{"summary":"An **actual** summary [2]","key_points":["noise"]}`, "An actual summary"},
		{`{"summary":{"text":"Nested text","citations":["opaque"]}}`, "Nested text"},
		{"", ""},
		{"[A linked opening](https://example.test) with text.", "A linked opening with text."},
		{"[1] Source begins after a citation.", "Source begins after a citation."},
		{"An inline citation [1](#evidence) ends here.", "An inline citation ends here."},
		{strings.Repeat("word ", 100), strings.TrimSpace(strings.Repeat("word ", 40))},
		{`{"summary":"` + strings.Repeat("word ", 1000), strings.TrimSpace(strings.Repeat("word ", 40))},
	} {
		if got := plainExcerpt(tc.input); got != tc.want {
			t.Fatalf("got %q want %q", got, tc.want)
		}
	}
}
