package worker

import (
	"encoding/json"
	"fmt"
	"time"
)

type retryableJobError struct {
	err   error
	delay time.Duration
}

func (e *retryableJobError) Error() string { return e.err.Error() }
func (e *retryableJobError) Unwrap() error { return e.err }

func retryAccountDeletion(err error, delay time.Duration) error {
	if delay < 15*time.Second {
		delay = 15 * time.Second
	}
	return &retryableJobError{err: err, delay: delay}
}

func (p *Pool) processAccountDeletion(job Job) error {
	request, err := p.db.GetAccountDeletionRequest(p.ctx, job.ID)
	if err != nil {
		return fmt.Errorf("load account deletion: %w", err)
	}
	if request.Status == "completed" {
		return nil
	}
	if err := p.db.StartAccountDeletion(p.ctx, request.ID); err != nil {
		return retryAccountDeletion(fmt.Errorf("start account deletion: %w", err), 30*time.Second)
	}

	var objectKeys []string
	if err := json.Unmarshal(request.ObjectKeys, &objectKeys); err != nil {
		return fmt.Errorf("decode account storage objects: %w", err)
	}
	if len(objectKeys) > 0 {
		if p.audioStorage == nil || !p.audioStorage.IsConfigured() {
			err := fmt.Errorf("audio storage is unavailable for account cleanup")
			_ = p.db.RecordAccountDeletionError(p.ctx, request.ID, err.Error())
			return retryAccountDeletion(err, 5*time.Minute)
		}
		for _, key := range objectKeys {
			if err := p.audioStorage.DeleteObject(p.ctx, key); err != nil {
				wrapped := fmt.Errorf("delete account storage object: %w", err)
				_ = p.db.RecordAccountDeletionError(p.ctx, request.ID, wrapped.Error())
				return retryAccountDeletion(wrapped, 5*time.Minute)
			}
		}
	}

	if request.ClerkDeletedAt == nil {
		if request.ClerkUserID == nil || *request.ClerkUserID == "" {
			return fmt.Errorf("account deletion is missing its Clerk identity")
		}
		if p.identityDeleter == nil {
			err := fmt.Errorf("Clerk account deletion is unavailable")
			_ = p.db.RecordAccountDeletionError(p.ctx, request.ID, err.Error())
			return retryAccountDeletion(err, 5*time.Minute)
		}
		if err := p.identityDeleter.DeleteUser(p.ctx, *request.ClerkUserID); err != nil {
			wrapped := fmt.Errorf("delete Clerk identity: %w", err)
			_ = p.db.RecordAccountDeletionError(p.ctx, request.ID, wrapped.Error())
			return retryAccountDeletion(wrapped, 5*time.Minute)
		}
		if err := p.db.MarkAccountIdentityDeleted(p.ctx, request.ID); err != nil {
			return retryAccountDeletion(fmt.Errorf("record Clerk deletion: %w", err), 30*time.Second)
		}
	}

	// Delete the same keys once more after every issued presigned PUT URL has
	// expired. Repeated S3 DELETE requests are intentionally idempotent.
	if remaining := time.Until(request.CleanupAfter); remaining > 0 {
		return retryAccountDeletion(fmt.Errorf("waiting for issued upload URLs to expire"), remaining)
	}
	if err := p.db.CompleteAccountDeletion(p.ctx, request.ID); err != nil {
		return retryAccountDeletion(fmt.Errorf("complete account deletion: %w", err), 30*time.Second)
	}
	return nil
}
