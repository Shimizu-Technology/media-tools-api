package summary

import (
	"errors"
	"net/http"
	"strings"
	"testing"
)

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
	err := newProviderError(http.StatusPaymentRequired, body)

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
