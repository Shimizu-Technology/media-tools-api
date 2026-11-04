DROP TRIGGER reserve_audio_admission ON audio_transcriptions;
DROP TRIGGER reserve_video_admission ON transcripts;
DROP FUNCTION reserve_media_admission();
DROP FUNCTION reserve_transcription_usage(UUID,UUID,BIGINT,BOOLEAN);
DROP TABLE account_transcription_usage,account_monthly_usage,account_usage_policies;
