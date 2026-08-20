package transcriptformat

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func formatterResponse(content string) *http.Response {
	body := `{"model":"gpt-test","choices":[{"message":{"content":` + string(mustJSON(content)) + `}}]}`
	return &http.Response{
		StatusCode: http.StatusOK,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     make(http.Header),
	}
}

func mustJSON(value string) []byte {
	encoded, _ := json.Marshal(value)
	return encoded
}

func TestLexicallyEquivalentAllowsReadabilityChanges(t *testing.T) {
	source := "testing this and i'm still testing one two three let's see"
	formatted := "Testing this, and I’m still testing.\n\nOne, two, three—let’s see."
	if !LexicallyEquivalent(source, formatted) {
		t.Fatal("capitalization, punctuation, and paragraphs should be accepted")
	}
}

func TestLexicallyEquivalentRejectsChangedWords(t *testing.T) {
	tests := []struct {
		name      string
		formatted string
	}{
		{name: "addition", formatted: "Testing this thoroughly."},
		{name: "deletion", formatted: "Testing."},
		{name: "replacement", formatted: "Reviewing this."},
		{name: "reordering", formatted: "This testing."},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if LexicallyEquivalent("testing this", tt.formatted) {
				t.Fatalf("unsafe rewrite %q was accepted", tt.formatted)
			}
		})
	}
}

func TestLexicallyEquivalentPreservesNumbersContractionsAndNames(t *testing.T) {
	source := "i'm meeting stassi at 7 with 1,250 dollars"
	formatted := "I’m meeting Stassi at 7—with 1,250 dollars."
	if !LexicallyEquivalent(source, formatted) {
		t.Fatal("safe typography around contractions, names, and numbers should be accepted")
	}
}

func TestSplitIntoWordBoundedChunksPreservesEveryWord(t *testing.T) {
	chunks := splitIntoWordBoundedChunks("one two three four five six seven", 3)
	if len(chunks) != 3 {
		t.Fatalf("got %d chunks, want 3", len(chunks))
	}
	if got := stringsJoin(chunks); got != "one two three four five six seven" {
		t.Fatalf("joined chunks = %q", got)
	}
}

func stringsJoin(chunks []string) string {
	result := ""
	for _, chunk := range chunks {
		if result != "" {
			result += " "
		}
		result += chunk
	}
	return result
}

func TestNormalizeLayoutCollapsesExcessBlankLines(t *testing.T) {
	got := normalizeLayout(" First line. \r\n\r\n\r\n Second line. \n")
	if got != "First line.\n\nSecond line." {
		t.Fatalf("normalizeLayout() = %q", got)
	}
}

func TestFormatAcceptsSafeProviderOutput(t *testing.T) {
	formatter := New("test-key", "gpt-test")
	formatter.httpClient = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Header.Get("Authorization") != "Bearer test-key" {
			t.Fatal("missing API authorization header")
		}
		return formatterResponse(`{"text":"Testing this.\n\nI’m still testing."}`), nil
	})}

	result, err := formatter.Format(context.Background(), "testing this i'm still testing")
	if err != nil {
		t.Fatalf("Format() error = %v", err)
	}
	if result.Text != "Testing this.\n\nI’m still testing." || result.Model != "gpt-test" || result.Version != Version {
		t.Fatalf("Format() result = %#v", result)
	}
}

func TestFormatRejectsPlausibleWordCorrection(t *testing.T) {
	formatter := New("test-key", "gpt-test")
	formatter.httpClient = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return formatterResponse(`{"text":"I am going to test this."}`), nil
	})}

	_, err := formatter.Format(context.Background(), "i'm gonna test this")
	if !errors.Is(err, ErrUnsafeRewrite) {
		t.Fatalf("Format() error = %v, want ErrUnsafeRewrite", err)
	}
}
