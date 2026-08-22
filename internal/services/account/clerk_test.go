package account

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestClerkClientDeleteUser(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodDelete {
			t.Fatalf("method = %s, want DELETE", r.Method)
		}
		if r.URL.Path != "/users/user_123" {
			t.Fatalf("path = %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer secret" {
			t.Fatal("missing Clerk authorization")
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client := NewClerkClient("secret")
	client.baseURL = server.URL
	client.client = server.Client()
	if err := client.DeleteUser(context.Background(), "user_123"); err != nil {
		t.Fatalf("DeleteUser() error = %v", err)
	}
}

func TestClerkClientDeleteUserTreatsNotFoundAsIdempotentSuccess(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()

	client := NewClerkClient("secret")
	client.baseURL = server.URL
	client.client = server.Client()
	if err := client.DeleteUser(context.Background(), "already_deleted"); err != nil {
		t.Fatalf("DeleteUser() error = %v", err)
	}
}

func TestClerkClientDeleteUserRejectsProviderFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "temporarily unavailable", http.StatusServiceUnavailable)
	}))
	defer server.Close()

	client := NewClerkClient("secret")
	client.baseURL = server.URL
	client.client = server.Client()
	if err := client.DeleteUser(context.Background(), "user_123"); err == nil {
		t.Fatal("DeleteUser() error = nil, want provider failure")
	}
}
