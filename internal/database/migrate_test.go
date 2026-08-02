package database

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLatestMigrationVersion(t *testing.T) {
	dir := t.TempDir()
	files := []string{
		"001_create_users.up.sql",
		"001_create_users.down.sql",
		"039_latest_change.up.sql",
		"notes.txt",
	}
	for _, name := range files {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatalf("write fixture %q: %v", name, err)
		}
	}

	got, err := latestMigrationVersion(dir)
	if err != nil {
		t.Fatalf("latestMigrationVersion() error = %v", err)
	}
	if got != 39 {
		t.Fatalf("latestMigrationVersion() = %d, want 39", got)
	}
}

func TestLatestMigrationVersionRejectsInvalidUpMigrationName(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "not-versioned.up.sql"), nil, 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	if _, err := latestMigrationVersion(dir); err == nil {
		t.Fatal("latestMigrationVersion() error = nil, want invalid filename error")
	}
}

func TestLatestMigrationVersionRequiresUpMigration(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "001_create_users.down.sql"), nil, 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	if _, err := latestMigrationVersion(dir); err == nil {
		t.Fatal("latestMigrationVersion() error = nil, want no migrations error")
	}
}
