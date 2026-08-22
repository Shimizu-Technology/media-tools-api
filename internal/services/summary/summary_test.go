package summary

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
)

func TestProviderPreferencesRequireZeroRetentionAndDenyCollection(t *testing.T) {
	service := NewWithModels("key", "model", "chat-model", "throughput")
	body, err := json.Marshal(chatRequest{Provider: service.providerPreferences()})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	encoded := string(body)
	for _, required := range []string{`"sort":"throughput"`, `"data_collection":"deny"`, `"zdr":true`} {
		if !strings.Contains(encoded, required) {
			t.Fatalf("provider preferences %s missing %s", encoded, required)
		}
	}
}

func TestProviderPreferencesRemainPresentWithoutCustomSort(t *testing.T) {
	prefs := New("key", "model").providerPreferences()
	if prefs == nil || prefs.Sort != "" || prefs.DataCollection != "deny" || !prefs.ZDR {
		t.Fatalf("provider preferences = %#v, want privacy controls without a sort override", prefs)
	}
}

func TestSummaryMaxTokensUsesBoundedBudgets(t *testing.T) {
	tests := []struct {
		length string
		want   int
	}{
		{length: "short", want: shortSummaryMaxTokens},
		{length: "medium", want: mediumSummaryMaxTokens},
		{length: "detailed", want: detailedSummaryMaxTokens},
		{length: "", want: mediumSummaryMaxTokens},
		{length: "unexpected", want: mediumSummaryMaxTokens},
	}

	for _, test := range tests {
		t.Run(test.length, func(t *testing.T) {
			if got := summaryMaxTokens(test.length); got != test.want {
				t.Fatalf("summaryMaxTokens(%q) = %d, want %d", test.length, got, test.want)
			}
		})
	}
}

func TestProviderErrorDoesNotExposeUpstreamPayload(t *testing.T) {
	body := []byte(`{"error":{"message":"Add credits at https://openrouter.ai/settings/credits","metadata":{"error_type":"payment_required","user_id":"private-user"}}}`)
	err := newProviderError("OpenRouter", http.StatusPaymentRequired, body)

	for _, sensitive := range []string{"settings/credits", "private-user", "Add credits", "OpenRouter", "payment_required"} {
		if strings.Contains(err.Error(), sensitive) {
			t.Fatalf("error %q exposed sensitive upstream payload %q", err, sensitive)
		}
	}
	var providerErr *ProviderError
	if !errors.As(err, &providerErr) || providerErr.StatusCode != http.StatusPaymentRequired || providerErr.ErrorType != "payment_required" {
		t.Fatalf("typed provider error = %#v, want status and error type retained for classification", providerErr)
	}
}

func TestPublicErrorMessageClassifiesProviderFailures(t *testing.T) {
	tests := []struct {
		status int
		want   string
	}{
		{status: http.StatusPaymentRequired, want: "credits may need attention"},
		{status: http.StatusTooManyRequests, want: "busy right now"},
		{status: http.StatusServiceUnavailable, want: "temporarily unavailable"},
		{status: http.StatusUnauthorized, want: "configuration needs attention"},
	}

	for _, test := range tests {
		message := PublicErrorMessage(&ProviderError{StatusCode: test.status})
		if !strings.Contains(message, test.want) {
			t.Fatalf("PublicErrorMessage(%d) = %q, want text containing %q", test.status, message, test.want)
		}
	}
}

func TestShouldFallbackToOpenAIForInternalServerErrorButNotCancellation(t *testing.T) {
	if !shouldFallbackToOpenAI(&ProviderError{StatusCode: http.StatusInternalServerError}) {
		t.Fatal("shouldFallbackToOpenAI(500) = false, want transient provider failure fallback")
	}
	if shouldFallbackToOpenAI(context.Canceled) {
		t.Fatal("shouldFallbackToOpenAI(context.Canceled) = true, want cancellation preserved")
	}
}

func TestPublicErrorMessageHidesUnknownInternalErrors(t *testing.T) {
	message := PublicErrorMessage(errors.New("database DSN and internal identifier"))
	if strings.Contains(message, "DSN") || strings.Contains(message, "identifier") {
		t.Fatalf("PublicErrorMessage() exposed internal details: %q", message)
	}
}

func TestPublicChatErrorMessageHidesProviderDetails(t *testing.T) {
	err := &ProviderError{StatusCode: http.StatusPaymentRequired, ErrorType: "payment_required"}
	message := PublicChatErrorMessage(err)
	for _, sensitive := range []string{"OpenRouter", "payment_required", "402"} {
		if strings.Contains(message, sensitive) {
			t.Fatalf("PublicChatErrorMessage() exposed provider detail %q in %q", sensitive, message)
		}
	}
	if !strings.Contains(message, "credits may need attention") {
		t.Fatalf("PublicChatErrorMessage() = %q, want actionable credit guidance", message)
	}
}
