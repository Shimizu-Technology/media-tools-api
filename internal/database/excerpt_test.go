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

func TestExcerptReviewRegressions(t *testing.T) {
	cases := []struct{ source, want string }{
		{strings.Repeat("語", 220), strings.Repeat("語", 200)},
		{"snake_case and second_snake_case", "snake_case and second_snake_case"},
		{"a < b > c", "a < b > c"}, {"2024. A year worth keeping", "2024. A year worth keeping"},
		{"---\nActual text", "Actual text"},
		{"| Name | Value |\n| --- | --- |\n| Call | Today |", "Name Value Call Today"},
		{"```python\nprint(1)\n```", "print(1)"},
		{"**Bold** _emphasis_ and `snake_case`", "Bold emphasis and snake_case"},
		{"<p>Human <strong>text</strong></p>", "Human text"},
	}
	for _, tc := range cases {
		if got := plainExcerpt(tc.source); got != tc.want {
			t.Errorf("excerpt %q got %q want %q", tc.source, got, tc.want)
		}
	}
	for _, tail := range []string{`\`, `\u`, `\u2`, `\u20`, `\u202`, `\uD83D\uDE`} {
		source := `{"summary":"Summary prefix stays ` + tail
		if got := plainExcerpt(source); !strings.HasPrefix(got, "Summary prefix stays") {
			t.Errorf("lost summary on truncated escape %q: %q", tail, got)
		}
	}
}
