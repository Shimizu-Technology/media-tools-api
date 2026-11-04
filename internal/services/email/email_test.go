package email

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
	"testing"
	"time"
)

type transport func(*http.Request) (*http.Response, error)

func (f transport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestEncryptedEmailResendContractAndSanitizedFailure(t *testing.T) {
	s, err := New("resend", "fake-unit-key", "Media Tools <test@example.invalid>", "unit-test-secret")
	if err != nil {
		t.Fatal(err)
	}
	message := CodeMessage("person@example.invalid", "123456", "verification")
	sealed, err := s.Seal(message)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(sealed, message.To) || strings.Contains(sealed, "123456") {
		t.Fatal("plaintext in envelope")
	}
	opened, err := s.Open(sealed)
	if err != nil || opened != message {
		t.Fatal("envelope did not round trip")
	}
	wrong, _ := New("log", "", "", "different")
	if _, err := wrong.Open(sealed); err == nil {
		t.Fatal("different key opened envelope")
	}
	calls := 0
	s.Client = &http.Client{Transport: transport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != "POST" || r.URL.String() != "https://api.resend.com/emails" || r.Header.Get("Authorization") != "Bearer fake-unit-key" || r.Header.Get("Idempotency-Key") != "auth-email/unit-id" {
			t.Fatal("wrong Resend request contract")
		}
		var body struct {
			From    string
			To      []string
			Subject string
			Text    string
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if len(body.To) != 1 || body.To[0] != message.To || body.Text != message.Text || body.From != s.From {
			t.Fatal("wrong Resend payload")
		}
		return &http.Response{StatusCode: 429, Header: http.Header{"Retry-After": []string{"73"}}, Body: io.NopCloser(strings.NewReader("provider echoed 123456 and person@example.invalid"))}, nil
	})}
	for i := 0; i < 2; i++ {
		err := s.Deliver(context.Background(), "unit-id", sealed)
		var provider *DeliveryError
		if !errors.As(err, &provider) || !provider.Retryable() || provider.RetryAfter != 73*time.Second {
			t.Fatal("retry contract")
		}
		if strings.Contains(err.Error(), "123456") || strings.Contains(err.Error(), message.To) {
			t.Fatal("provider leaked content")
		}
	}
	if calls != 2 {
		t.Fatal("fake transport not called")
	}
	s.Client.Transport = transport(func(*http.Request) (*http.Response, error) { return nil, errors.New("transport leaked fake-unit-key") })
	if err := s.Deliver(context.Background(), "unit-id", sealed); strings.Contains(err.Error(), "fake-unit-key") {
		t.Fatal("transport error leaked")
	}
}
func TestLogDeliveryNeverContainsCodesOrAddresses(t *testing.T) {
	s, _ := New("log", "", "", "test")
	sealed, _ := s.Seal(CodeMessage("private@example.invalid", "654321", "reset"))
	var output bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&output)
	defer log.SetOutput(previous)
	if err := s.Deliver(context.Background(), "unit", sealed); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), "654321") || strings.Contains(output.String(), "private@") {
		t.Fatal("log contains private content")
	}
	if s.CodeHash("a", "123456") == s.CodeHash("b", "123456") {
		t.Fatal("hash not bound to challenge")
	}
	for i := 0; i < 20; i++ {
		code, err := NewCode()
		if err != nil || len(code) != 6 || strings.Trim(code, "0123456789") != "" {
			t.Fatal("code shape")
		}
	}
}
