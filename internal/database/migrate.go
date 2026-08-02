// migrate.go handles database migration using golang-migrate.
//
// Migrations are SQL files in the migrations/ directory. Each migration
// has an "up" (apply) and "down" (rollback) file. The migrate library
// tracks which migrations have been applied in a schema_migrations table.
package database

import (
	"fmt"
	"log"
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

// RunMigrations applies all pending database migrations.
// This is called at application startup to ensure the schema is up to date.
func (db *DB) RunMigrations(migrationsPath string) error {
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
