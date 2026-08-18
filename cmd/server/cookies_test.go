package main

import (
	"encoding/base64"
	"os"
	"testing"
)

func TestMaterializeCookieFileIsPrivateAndCleanedUp(t *testing.T) {
	content := []byte("# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t0\tsession\tsecret\n")
	path, cleanup, err := materializeCookieFile(base64.StdEncoding.EncodeToString(content))
	if err != nil {
		t.Fatalf("materialize cookies: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat cookie file: %v", err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("cookie permissions = %o, want 600", got)
	}
	stored, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read cookie file: %v", err)
	}
	if string(stored) != string(content) {
		t.Fatalf("cookie content = %q, want %q", stored, content)
	}

	cleanup()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("cookie file still exists after cleanup: %v", err)
	}
}

func TestMaterializeCookieFileRejectsInvalidBase64(t *testing.T) {
	if _, _, err := materializeCookieFile("not-base64!!!"); err == nil {
		t.Fatal("materialize cookies succeeded with invalid base64")
	}
}
