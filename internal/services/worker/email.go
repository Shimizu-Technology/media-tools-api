package worker

import (
	"errors"
	emailservice "github.com/Shimizu-Technology/media-tools-api/internal/services/email"
	"time"
)

func (p *Pool) SetEmailService(service *emailservice.Service) { p.email = service }
func (p *Pool) processAuthEmail(job Job) error {
	sealed, err := p.db.EmailForDelivery(p.ctx, job.ID)
	if err != nil {
		return &retryableJobError{err: errors.New("load auth email failed"), delay: 30 * time.Second}
	}
	if sealed == "" {
		return nil
	}
	if p.email == nil {
		return &retryableJobError{err: errors.New("email delivery unavailable"), delay: time.Minute}
	}
	if err := p.email.Deliver(p.ctx, job.ID, sealed); err != nil {
		var provider *emailservice.DeliveryError
		if errors.As(err, &provider) && provider.Retryable() {
			return &retryableJobError{err: provider, delay: max(provider.RetryAfter, 30*time.Second)}
		}
		return errors.New("auth email delivery failed")
	}
	if err := p.db.MarkEmailSent(p.ctx, job.ID); err != nil {
		return &retryableJobError{err: errors.New("record auth email delivery failed"), delay: 30 * time.Second}
	}
	return nil
}
