-- Create the durable queue row in the same transaction as the resource state
-- change. The HTTP handler still calls Submit after commit so local workers wake
-- immediately and so a richer upload payload can include a temporary file path.
-- That call is idempotent and updates a queued trigger-created payload.

CREATE OR REPLACE FUNCTION enqueue_media_background_job()
RETURNS TRIGGER AS $$
DECLARE
    row_data JSONB := to_jsonb(NEW);
    queued_type TEXT;
    queued_payload JSONB := '{}'::jsonb;
BEGIN
    IF TG_TABLE_NAME = 'transcripts' THEN
        queued_type := 'transcript_extraction';
    ELSIF TG_TABLE_NAME = 'summaries' THEN
        queued_type := 'summary_generation';
        queued_payload := jsonb_build_object(
            'transcript_id', row_data->>'transcript_id',
            'summary_id', row_data->>'id',
            'model', COALESCE(row_data->>'model_used', ''),
            'length', COALESCE(row_data->>'length', 'medium'),
            'style', COALESCE(row_data->>'style', 'bullet'),
            'content_type', COALESCE(row_data->>'content_type', '')
        );
    ELSIF TG_TABLE_NAME = 'audio_transcriptions'
          AND TG_ARGV[0] = 'summary' THEN
        queued_type := 'audio_summary';
        queued_payload := jsonb_build_object(
            'audio_id', row_data->>'id',
            'model', '',
            'length', 'medium',
            'content_type', COALESCE(row_data->>'content_type', 'general')
        );
    ELSIF TG_TABLE_NAME = 'audio_transcriptions' THEN
        queued_type := 'audio_transcription';
        queued_payload := jsonb_build_object(
            'audio_id', row_data->>'id',
            'audio_s3_key', COALESCE(row_data->>'audio_s3_key', ''),
            'original_name', COALESCE(row_data->>'original_name', '')
        );
    ELSE
        RETURN NEW;
    END IF;

    INSERT INTO background_jobs (job_type, resource_id, payload)
    VALUES (queued_type, (row_data->>'id')::uuid, queued_payload)
    ON CONFLICT (job_type, resource_id)
        WHERE status IN ('queued', 'running')
    DO UPDATE SET
        payload = EXCLUDED.payload,
        updated_at = NOW()
    WHERE background_jobs.status = 'queued';

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enqueue_transcript_background_job
    AFTER INSERT ON transcripts
    FOR EACH ROW
    WHEN (NEW.status::text = 'pending')
    EXECUTE FUNCTION enqueue_media_background_job();

CREATE TRIGGER enqueue_summary_background_job
    AFTER INSERT ON summaries
    FOR EACH ROW
    WHEN (NEW.status = 'pending')
    EXECUTE FUNCTION enqueue_media_background_job();

CREATE TRIGGER enqueue_audio_transcription_background_job
    AFTER INSERT OR UPDATE OF status ON audio_transcriptions
    FOR EACH ROW
    WHEN (NEW.status = 'pending')
    EXECUTE FUNCTION enqueue_media_background_job('transcription');

CREATE TRIGGER enqueue_audio_summary_background_job
    AFTER UPDATE OF summary_status ON audio_transcriptions
    FOR EACH ROW
    WHEN (NEW.summary_status = 'pending')
    EXECUTE FUNCTION enqueue_media_background_job('summary');
