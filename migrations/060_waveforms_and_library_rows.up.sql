-- Additive columns. Upgraded audio reads use explicit projections, including
-- workspace queries, so internal title flags and future columns cannot break scans.
ALTER TABLE audio_transcriptions
 ADD COLUMN waveform jsonb,
 ADD COLUMN waveform_status text NOT NULL DEFAULT '',
 ADD CONSTRAINT audio_waveform_shape CHECK (waveform IS NULL OR
   (jsonb_typeof(waveform) = 'array' AND jsonb_array_length(waveform) = 200)),
 ADD CONSTRAINT audio_waveform_status CHECK (waveform_status IN ('','pending','processing','completed','failed'));
ALTER TABLE background_jobs ADD COLUMN priority integer NOT NULL DEFAULT 0;
CREATE INDEX background_jobs_priority_ready ON background_jobs(priority, run_at, created_at)
 WHERE status IN ('queued','running');
ALTER TABLE collections ADD COLUMN color text NOT NULL DEFAULT 'coral'
 CHECK (color IN ('coral','teal','violet','amber','blue','rose'));
WITH ranked AS (
 SELECT c.id, row_number() OVER (PARTITION BY COALESCE(c.user_id, k.user_id, c.api_key_id) ORDER BY c.created_at,c.id) AS n
 FROM collections c LEFT JOIN api_keys k ON k.id=c.api_key_id
)
UPDATE collections c SET color=(ARRAY['coral','teal','violet','amber','blue','rose'])[((r.n-1)%6)::int+1]
FROM ranked r WHERE r.id=c.id;
CREATE INDEX collection_items_media_lookup ON collection_items(item_type,item_id,collection_id);

ALTER TABLE background_jobs DROP CONSTRAINT background_jobs_type_check;
ALTER TABLE background_jobs ADD CONSTRAINT background_jobs_type_check CHECK
 (job_type IN ('transcript_extraction','summary_generation','audio_transcription','audio_summary','audio_transcript_formatting','account_deletion','auth_email','audio_waveform','admin_backfill')) NOT VALID;

CREATE TABLE backfill_runs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 kind text NOT NULL CHECK(kind IN ('waveforms','enrichment')),
 user_id uuid REFERENCES users(id) ON DELETE SET NULL,
 dispatch_status text NOT NULL DEFAULT 'queued' CHECK(dispatch_status IN ('queued','running','completed','failed')),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE backfill_run_jobs (
 run_id uuid NOT NULL REFERENCES backfill_runs(id) ON DELETE CASCADE,
 job_id uuid NOT NULL REFERENCES background_jobs(id) ON DELETE CASCADE,
 PRIMARY KEY(run_id,job_id), UNIQUE(job_id)
);
