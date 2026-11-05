package worker

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/services/waveform"
)

func (p *Pool) processAudioWaveform(job Job) error {
	ctx, cancel := context.WithTimeout(p.ctx, 15*time.Minute)
	defer cancel()
	// Never load a transcript just to compute its waveform.
	var key, status, stored string
	var exists bool
	err := p.db.QueryRowContext(ctx, `SELECT audio_s3_key,status,audio_s3_status,waveform IS NOT NULL FROM audio_transcriptions WHERE id=$1`, job.ID).Scan(&key, &status, &stored, &exists)
	if err != nil {
		return fmt.Errorf("read waveform source: %w", err)
	}
	if status != "completed" || exists {
		return nil
	}
	if key == "" || stored != "uploaded" {
		return fmt.Errorf("waveform source is not stored")
	}
	if !p.audioStorage.IsConfigured() {
		return fmt.Errorf("waveform storage is not configured")
	}
	file, err := os.CreateTemp("", "mta-waveform-source-*")
	if err != nil {
		return err
	}
	path := file.Name()
	_ = file.Close()
	defer os.Remove(path)
	if _, err = p.db.ExecContext(ctx, `UPDATE audio_transcriptions SET waveform_status='processing' WHERE id=$1`, job.ID); err != nil {
		return err
	}
	// DownloadFile uses io.Copy, preserving constant memory and seekability.
	if err = p.audioStorage.DownloadFile(ctx, key, path); err != nil {
		return fmt.Errorf("download waveform source failed")
	}
	peaks, err := waveform.Compute(ctx, path)
	if err != nil {
		return err
	}
	encoded, err := json.Marshal(peaks)
	if err != nil {
		return err
	}
	_, err = p.db.ExecContext(ctx, `UPDATE audio_transcriptions SET waveform=$2::jsonb,waveform_status='completed' WHERE id=$1 AND status='completed' AND audio_s3_key=$3`, job.ID, string(encoded), key)
	return err
}
