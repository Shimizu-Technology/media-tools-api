DROP TRIGGER IF EXISTS enqueue_audio_summary_background_job ON audio_transcriptions;
DROP TRIGGER IF EXISTS enqueue_audio_transcription_background_job ON audio_transcriptions;
DROP TRIGGER IF EXISTS enqueue_summary_background_job ON summaries;
DROP TRIGGER IF EXISTS enqueue_transcript_background_job ON transcripts;
DROP FUNCTION IF EXISTS enqueue_media_background_job();
