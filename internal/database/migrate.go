// migrate.go handles database migration using golang-migrate.
//
// Migrations are SQL files in the migrations/ directory. Each migration
// has an "up" (apply) and "down" (rollback) file. The migrate library
// tracks which migrations have been applied in a schema_migrations table.
package database

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/golang-migrate/migrate/v4"
	"github.com/golang-migrate/migrate/v4/database/postgres"
	_ "github.com/golang-migrate/migrate/v4/source/file" // File source driver
)

// Render briefly overlaps old and new instances during a zero-downtime deploy.
// Both instances run migrations at startup, so the library's 15-second default
// can expire while the other instance still owns PostgreSQL's advisory lock.
// Waiting longer is safe because the lock serializes migration work; once the
// other instance finishes, this instance rechecks the schema and normally gets
// migrate.ErrNoChange.
const migrationLockTimeout = 60 * time.Second

const migrationPreflightTimeout = 5 * time.Second

// RunMigrations applies all pending database migrations.
// This is called at application startup to ensure the schema is up to date.
func (db *DB) RunMigrations(migrationsPath string) error {
	// golang-migrate's PostgreSQL driver takes an advisory lock while it is
	// being constructed, before Migrate.LockTimeout can be applied. On Render,
	// a stopped deployment can briefly leave that lock behind and block the new
	// process before it opens its HTTP port. Most deployments have no schema
	// work to do, so avoid constructing the locking driver when the database is
	// already clean and at the exact version bundled with this binary.
	latestVersion, err := latestMigrationVersion(migrationsPath)
	if err != nil {
		return fmt.Errorf("inspect bundled migrations: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), migrationPreflightTimeout)
	defer cancel()

	currentVersion, dirty, tableExists, err := db.currentMigrationState(ctx)
	if err != nil {
		return fmt.Errorf("inspect database migration state: %w", err)
	}
	if tableExists && !dirty && currentVersion == latestVersion {
		log.Printf("📦 Database: no new migrations to apply (version %d)", currentVersion)
		return nil
	}
	if tableExists && !dirty && currentVersion > latestVersion {
		return fmt.Errorf(
			"database migration version %d is newer than bundled version %d",
			currentVersion,
			latestVersion,
		)
	}

	// Create a postgres driver instance for golang-migrate
	driver, err := postgres.WithInstance(db.DB.DB, &postgres.Config{})
	if err != nil {
		return fmt.Errorf("failed to create migration driver: %w", err)
	}

	// Create the migrate instance pointing to our SQL files
	m, err := migrate.NewWithDatabaseInstance(
		"file://"+migrationsPath,
		"postgres",
		driver,
	)
	if err != nil {
		return fmt.Errorf("failed to create migrator: %w", err)
	}
	m.LockTimeout = migrationLockTimeout

	// Run all pending migrations
	err = m.Up()
	if err != nil && err != migrate.ErrNoChange {
		return fmt.Errorf("migration failed: %w", err)
	}

	if err == migrate.ErrNoChange {
		log.Println("📦 Database: no new migrations to apply")
	} else {
		version, dirty, _ := m.Version()
		log.Printf("📦 Database: migrated to version %d (dirty: %v)", version, dirty)
	}

	return nil
}

// currentMigrationState reads the single row maintained by golang-migrate.
// tableExists is separate because a brand-new database has no version table
// yet and must still go through the normal migration driver initialization.
func (db *DB) currentMigrationState(ctx context.Context) (version int64, dirty, tableExists bool, err error) {
	err = db.QueryRowContext(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM information_schema.tables
			WHERE table_schema = current_schema()
			  AND table_name = 'schema_migrations'
		)`).Scan(&tableExists)
	if err != nil || !tableExists {
		return 0, false, tableExists, err
	}

	err = db.QueryRowContext(ctx, `SELECT version, dirty FROM schema_migrations LIMIT 1`).Scan(&version, &dirty)
	if err == sql.ErrNoRows {
		return 0, false, true, nil
	}
	return version, dirty, true, err
}

// latestMigrationVersion derives the expected schema version from the up
// migration filenames (for example, 039_persist_audio_summary_length.up.sql).
func latestMigrationVersion(migrationsPath string) (int64, error) {
	entries, err := os.ReadDir(migrationsPath)
	if err != nil {
		return 0, err
	}

	var latest int64
	found := false
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".up.sql") {
			continue
		}

		prefix, _, ok := strings.Cut(entry.Name(), "_")
		if !ok {
			return 0, fmt.Errorf("invalid migration filename %q", filepath.Join(migrationsPath, entry.Name()))
		}
		version, err := strconv.ParseInt(prefix, 10, 64)
		if err != nil || version <= 0 {
			return 0, fmt.Errorf("invalid migration version in %q", filepath.Join(migrationsPath, entry.Name()))
		}
		if !found || version > latest {
			latest = version
			found = true
		}
	}

	if !found {
		return 0, fmt.Errorf("no up migrations found in %q", migrationsPath)
	}
	return latest, nil
}
