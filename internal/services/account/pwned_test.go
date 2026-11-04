package account

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

type pwnedTransport func(*http.Request) (*http.Response, error)

func (f pwnedTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestPwnedKAnonymityPaddingAndFailOpen(t *testing.T) {
	password := "a synthetic password for HIBP tests"
	sum := sha1.Sum([]byte(password))
	hash := strings.ToUpper(hex.EncodeToString(sum[:]))
	checker := NewPwnedChecker()
	checker.Client = &http.Client{Transport: pwnedTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/range/"+hash[:5] || r.Header.Get("Add-Padding") != "true" || r.Body != nil {
			t.Fatal("password or full hash sent")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(hash[5:] + ":12\n"))}, nil
	})}
	if !checker.Compromised(context.Background(), password) {
		t.Fatal("known breach accepted")
	}
	checker.Client.Transport = pwnedTransport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(hash[5:] + ":0\n"))}, nil
	})
	if checker.Compromised(context.Background(), password) {
		t.Fatal("padding treated as breach")
	}
	checker.Client.Transport = pwnedTransport(func(*http.Request) (*http.Response, error) { return nil, errors.New("outage") })
	if checker.Compromised(context.Background(), password) {
		t.Fatal("outage failed closed")
	}
}
