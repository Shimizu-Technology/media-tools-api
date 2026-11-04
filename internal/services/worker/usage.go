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
	err := p.db.ReserveAutomaticAIRequest(p.ctx, item.UserID, item.APIKeyID, key+":"+operation)
	if database.IsUsageCap(err) {
		return fmt.Errorf("Monthly summary and chat limit reached. Try again next month: %w", database.ErrMonthlyUsageCap)
	}
	return err
}
