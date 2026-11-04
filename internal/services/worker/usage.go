package worker

import (
	"fmt"
	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func (p *Pool) reserveAutomaticAI(job Job, item *models.AudioTranscription, operation string) error {
	key := job.QueueID
	if key == "" {
		key = job.ID
	}
	err := p.db.ReserveAutomaticAIRequest(p.ctx, item.UserID, item.APIKeyID, key+":"+operation, p.usageDefaults)
	if database.IsUsageCap(err) {
		return fmt.Errorf("Monthly summary and chat limit reached. Try again next month: %w", database.ErrMonthlyUsageCap)
	}
	return err
}

const aiCapSkipMessage = "Skipped: monthly AI limit reached; try again next month. The original transcript is available."

func (p *Pool) skipCappedEnrichment(itemID, operation string, err error) error {
	if !database.IsUsageCap(err) {
		return err
	}
	query := `UPDATE audio_transcriptions SET summary_status='skipped',summary_error_message=$2 WHERE id=$1`
	if operation == "format" {
		query = `UPDATE audio_transcriptions SET formatting_status='skipped',formatting_error_message=$2 WHERE id=$1`
	}
	_, saveErr := p.db.ExecContext(p.ctx, query, itemID, aiCapSkipMessage)
	return saveErr
}

// ConfigureUsage must be called before Start, just like other pool configuration.
func (p *Pool) ConfigureUsage(defaults database.UsageDefaults) { p.usageDefaults = defaults }
