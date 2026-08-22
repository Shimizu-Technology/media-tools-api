-- AI output reports let signed-in users flag generated chat responses and
-- summaries without leaving the app. The snapshot contains only the selected
-- AI output; source recordings, transcripts, and documents are not copied.

CREATE TABLE ai_content_reports (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_type      VARCHAR(32) NOT NULL,
    target_id        UUID NOT NULL,
    subject_type     VARCHAR(20) NOT NULL,
    subject_id       UUID NOT NULL,
    user_id          UUID REFERENCES users(id) ON DELETE CASCADE,
    api_key_id       UUID REFERENCES api_keys(id) ON DELETE CASCADE,
    category         VARCHAR(32) NOT NULL,
    details          VARCHAR(1000) NOT NULL DEFAULT '',
    content_snapshot JSONB NOT NULL,
    status           VARCHAR(20) NOT NULL DEFAULT 'open',
    admin_note       VARCHAR(1000) NOT NULL DEFAULT '',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ai_content_reports_owner_check CHECK (
        (user_id IS NOT NULL AND api_key_id IS NULL)
        OR
        (user_id IS NULL AND api_key_id IS NOT NULL)
    ),
    CONSTRAINT ai_content_reports_target_type_check CHECK (
        target_type IN ('chat_message', 'transcript_summary', 'audio_summary')
    ),
    CONSTRAINT ai_content_reports_subject_type_check CHECK (
        subject_type IN ('transcript', 'audio', 'pdf', 'collection')
    ),
    CONSTRAINT ai_content_reports_category_check CHECK (
        category IN ('dangerous', 'hate_or_harassment', 'sexual', 'privacy', 'deceptive', 'other')
    ),
    CONSTRAINT ai_content_reports_status_check CHECK (
        status IN ('open', 'reviewing', 'resolved', 'dismissed')
    ),
    CONSTRAINT ai_content_reports_snapshot_check CHECK (
        jsonb_typeof(content_snapshot) = 'object'
    )
);

CREATE UNIQUE INDEX idx_ai_content_reports_user_target
    ON ai_content_reports(target_type, target_id, user_id)
    WHERE user_id IS NOT NULL;

CREATE UNIQUE INDEX idx_ai_content_reports_api_key_target
    ON ai_content_reports(target_type, target_id, api_key_id)
    WHERE api_key_id IS NOT NULL;

CREATE INDEX idx_ai_content_reports_review_queue
    ON ai_content_reports(status, created_at DESC);

DROP TRIGGER IF EXISTS update_ai_content_reports_updated_at
    ON ai_content_reports;
CREATE TRIGGER update_ai_content_reports_updated_at
    BEFORE UPDATE ON ai_content_reports
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
