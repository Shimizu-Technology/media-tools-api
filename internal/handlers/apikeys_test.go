package handlers

import "testing"

func TestAdminKeyMatches(t *testing.T) {
	valid := "admin-key-that-is-long-enough-for-production"
	if !adminKeyMatches(valid, valid) {
		t.Fatal("adminKeyMatches rejected the configured key")
	}
	if adminKeyMatches("different-key", valid) {
		t.Fatal("adminKeyMatches accepted a different key")
	}
	if adminKeyMatches("", valid) || adminKeyMatches(valid, "") {
		t.Fatal("adminKeyMatches accepted an empty key")
	}
}
