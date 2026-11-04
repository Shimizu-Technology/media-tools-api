CREATE TABLE account_usage_policies (
 user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 transcription_limit_seconds BIGINT NOT NULL CHECK(transcription_limit_seconds>0),
 ai_request_limit BIGINT NOT NULL CHECK(ai_request_limit>0),
 exempt BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE account_monthly_usage (
 user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 month DATE NOT NULL,
 transcription_seconds BIGINT NOT NULL DEFAULT 0 CHECK(transcription_seconds>=0),
 ai_requests BIGINT NOT NULL DEFAULT 0 CHECK(ai_requests>=0),
 PRIMARY KEY(user_id,month)
);
CREATE TABLE account_transcription_usage (
 user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 resource_id UUID NOT NULL,
 month DATE NOT NULL,
 seconds BIGINT NOT NULL CHECK(seconds>=0),
 provisional BOOLEAN NOT NULL DEFAULT TRUE,
 PRIMARY KEY(user_id,resource_id,month)
);

-- UTC calendar months, serialised by policy row. The resource ledger makes
-- retries and worker restarts idempotent. Actual duration is reserved before
-- Whisper; the initial minute prevents unbounded concurrent queued uploads.
CREATE FUNCTION reserve_transcription_usage(account UUID, resource UUID, amount BIGINT, provisional_value BOOLEAN) RETURNS VOID AS $$
DECLARE
 period DATE := date_trunc('month',NOW() AT TIME ZONE 'UTC')::date;
 policy account_usage_policies%ROWTYPE;
 previous BIGINT := 0;
 used BIGINT;
BEGIN
 SELECT * INTO policy FROM account_usage_policies WHERE user_id=account FOR UPDATE;
 IF NOT FOUND OR policy.exempt THEN RETURN; END IF;
 INSERT INTO account_monthly_usage(user_id,month) VALUES(account,period) ON CONFLICT DO NOTHING;
 SELECT seconds INTO previous FROM account_transcription_usage WHERE user_id=account AND resource_id=resource AND month=period;
 previous:=COALESCE(previous,0);
 SELECT transcription_seconds INTO used FROM account_monthly_usage WHERE user_id=account AND month=period FOR UPDATE;
 IF used-previous+amount>policy.transcription_limit_seconds THEN
  RAISE EXCEPTION USING ERRCODE='P0402',MESSAGE='monthly_transcription_cap';
 END IF;
 UPDATE account_monthly_usage SET transcription_seconds=used-previous+amount WHERE user_id=account AND month=period;
 INSERT INTO account_transcription_usage(user_id,resource_id,month,seconds,provisional) VALUES(account,resource,period,amount,provisional_value)
 ON CONFLICT(user_id,resource_id,month) DO UPDATE SET seconds=EXCLUDED.seconds,provisional=EXCLUDED.provisional;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION reserve_media_admission() RETURNS TRIGGER AS $$
DECLARE account UUID; reserved BIGINT;
BEGIN
 account:=NEW.user_id;
 IF account IS NULL AND NEW.api_key_id IS NOT NULL THEN SELECT user_id INTO account FROM api_keys WHERE id=NEW.api_key_id; END IF;
 IF account IS NULL THEN RETURN NEW; END IF;
 IF TG_OP='INSERT' AND NEW.status IN ('pending','processing') THEN
  PERFORM reserve_transcription_usage(account,NEW.id,60,TRUE);
 ELSIF TG_OP='UPDATE' AND NEW.status='failed' AND OLD.status<>NEW.status THEN
  SELECT seconds INTO reserved FROM account_transcription_usage
  WHERE user_id=account AND resource_id=NEW.id AND month=date_trunc('month',NOW() AT TIME ZONE 'UTC')::date AND provisional;
  IF FOUND THEN PERFORM reserve_transcription_usage(account,NEW.id,0,TRUE); END IF;
 END IF;
 RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER reserve_audio_admission BEFORE INSERT OR UPDATE OF status ON audio_transcriptions FOR EACH ROW EXECUTE FUNCTION reserve_media_admission();
CREATE TRIGGER reserve_video_admission BEFORE INSERT OR UPDATE OF status ON transcripts FOR EACH ROW EXECUTE FUNCTION reserve_media_admission();

-- Automatic enrichment has no HTTP admission request. A durable job/operation
-- key reserves its summary/title budget once, including after worker restart.
CREATE TABLE account_ai_request_reservations (
 user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 reservation_key TEXT NOT NULL,
 month DATE NOT NULL,
 PRIMARY KEY(user_id,reservation_key,month)
);
