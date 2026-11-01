-- Private metadata-only receipts on the relay host. Never persist MIME bodies, addresses or QR tokens.
CREATE TABLE IF NOT EXISTS wedding_email_relay_requests (
  id uuid PRIMARY KEY,
  sender text NOT NULL,
  payload_hash text NOT NULL,
  status text NOT NULL DEFAULT 'sending' CHECK (status IN ('sending','sent','failed','unknown')),
  reason text,
  started_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS wedding_email_relay_sender_time ON wedding_email_relay_requests(sender, started_at);
ALTER TABLE wedding_email_relay_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON wedding_email_relay_requests FROM PUBLIC, anon, authenticated;
GRANT ALL ON wedding_email_relay_requests TO service_role;

CREATE OR REPLACE FUNCTION reserve_wedding_email_relay(
  p_id uuid, p_sender text, p_hash text, p_limit integer, p_interval double precision
) RETURNS jsonb LANGUAGE plpgsql SET search_path = public AS $$
DECLARE receipt wedding_email_relay_requests; used integer; last_attempt timestamptz; wait_seconds double precision;
BEGIN
  IF p_id IS NULL OR p_sender IS NULL OR p_hash IS NULL THEN RAISE EXCEPTION 'Relay identity is required'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('wedding_email:' || p_sender));
  SELECT * INTO receipt FROM wedding_email_relay_requests WHERE id=p_id;
  IF FOUND THEN
    IF receipt.sender<>p_sender OR receipt.payload_hash<>p_hash THEN
      RETURN jsonb_build_object('state','conflict','status','unknown');
    END IF;
    -- A processing/restarted request never gains another SMTP submission opportunity.
    RETURN jsonb_build_object('state','replay','status',
      CASE WHEN receipt.status='sending' THEN 'unknown' ELSE receipt.status END,'reason',receipt.reason);
  END IF;
  SELECT count(*), max(started_at) INTO used, last_attempt FROM (
    SELECT started_at FROM wedding_email_attempts WHERE sender=p_sender AND started_at>now()-interval '24 hours'
    UNION ALL
    SELECT started_at FROM wedding_email_relay_requests WHERE sender=p_sender AND started_at>now()-interval '24 hours'
  ) attempts;
  IF used>=p_limit THEN RETURN jsonb_build_object('state','quota'); END IF;
  wait_seconds := p_interval-extract(epoch FROM now()-last_attempt);
  IF wait_seconds>0 THEN RETURN jsonb_build_object('state','wait','seconds',wait_seconds); END IF;
  -- Also handles an ID collision between different senders without granting ownership twice.
  INSERT INTO wedding_email_relay_requests(id,sender,payload_hash) VALUES(p_id,p_sender,p_hash)
    ON CONFLICT (id) DO NOTHING RETURNING * INTO receipt;
  IF NOT FOUND THEN RETURN jsonb_build_object('state','conflict','status','unknown'); END IF;
  RETURN jsonb_build_object('state','claimed');
END $$;
REVOKE ALL ON FUNCTION reserve_wedding_email_relay(uuid,text,text,integer,double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION reserve_wedding_email_relay(uuid,text,text,integer,double precision) TO service_role;

-- Native staging batches and relayed production messages share one sender quota and interval.
CREATE OR REPLACE FUNCTION claim_wedding_email_v2(
  p_batch uuid, p_sender text, p_limit integer, p_interval double precision, p_request_id uuid
) RETURNS jsonb LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  delivery wedding_email_deliveries;
  previous_attempt wedding_email_attempts;
  used integer;
  last_attempt timestamptz;
  wait_seconds double precision;
BEGIN
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A claim request ID is required'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('wedding_email:' || p_sender));
  SELECT * INTO previous_attempt FROM wedding_email_attempts WHERE id=p_request_id;
  IF FOUND THEN
    SELECT * INTO delivery FROM wedding_email_deliveries
      WHERE id=previous_attempt.delivery_id AND batch_id=p_batch
        AND previous_attempt.sender=p_sender AND status='sending'
        AND attempted_at=previous_attempt.started_at;
    IF FOUND THEN
      RETURN jsonb_build_object('state','claimed','delivery',to_jsonb(delivery));
    END IF;
    RETURN jsonb_build_object('state','empty');
  END IF;
  UPDATE wedding_email_deliveries SET status='unknown', error='寄送中斷，請先至 Gmail 寄件備份確認，勿直接重寄。'
    WHERE batch_id=p_batch AND status='sending' AND attempted_at < now()-interval '5 minutes';
  SELECT * INTO delivery FROM wedding_email_deliveries WHERE batch_id=p_batch AND status='pending'
    ORDER BY created_at, id FOR UPDATE SKIP LOCKED LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('state','empty'); END IF;
  SELECT count(*), max(started_at) INTO used, last_attempt FROM (
    SELECT started_at FROM wedding_email_attempts WHERE sender=p_sender AND started_at>now()-interval '24 hours'
    UNION ALL
    SELECT started_at FROM wedding_email_relay_requests WHERE sender=p_sender AND started_at>now()-interval '24 hours'
  ) attempts;
  IF used >= p_limit THEN RETURN jsonb_build_object('state','quota'); END IF;
  wait_seconds := p_interval-extract(epoch FROM now()-last_attempt);
  IF wait_seconds > 0 THEN RETURN jsonb_build_object('state','wait','seconds',wait_seconds); END IF;
  UPDATE wedding_email_deliveries SET status='sending', error=NULL, attempted_at=now()
    WHERE id=delivery.id RETURNING * INTO delivery;
  INSERT INTO wedding_email_attempts(id,delivery_id,sender) VALUES(p_request_id,delivery.id,p_sender);
  RETURN jsonb_build_object('state','claimed','delivery',to_jsonb(delivery));
END $$;
REVOKE ALL ON FUNCTION claim_wedding_email_v2(uuid,text,integer,double precision,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION claim_wedding_email_v2(uuid,text,integer,double precision,uuid) TO service_role;
CREATE OR REPLACE FUNCTION claim_wedding_email(p_batch uuid, p_sender text, p_limit integer, p_interval double precision)
RETURNS jsonb LANGUAGE plpgsql SET search_path = public AS $$
DECLARE delivery wedding_email_deliveries; used integer; last_attempt timestamptz; wait_seconds double precision;
BEGIN
  -- Shared across all workers/batches sending from this account.
  PERFORM pg_advisory_xact_lock(hashtext('wedding_email:' || p_sender));
  UPDATE wedding_email_deliveries SET status='unknown', error='寄送中斷，請先至 Gmail 寄件備份確認，勿直接重寄。'
    WHERE status='sending' AND attempted_at < now() - interval '5 minutes';
  SELECT * INTO delivery FROM wedding_email_deliveries WHERE batch_id=p_batch AND status='pending'
    ORDER BY created_at, id FOR UPDATE SKIP LOCKED LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('state','empty'); END IF;
  SELECT count(*), max(started_at) INTO used, last_attempt FROM (
    SELECT started_at FROM wedding_email_attempts WHERE sender=p_sender AND started_at>now()-interval '24 hours'
    UNION ALL
    SELECT started_at FROM wedding_email_relay_requests WHERE sender=p_sender AND started_at>now()-interval '24 hours'
  ) attempts;
  IF used >= p_limit THEN RETURN jsonb_build_object('state','quota'); END IF;
  wait_seconds := p_interval - extract(epoch FROM now()-last_attempt);
  IF wait_seconds > 0 THEN RETURN jsonb_build_object('state','wait','seconds',wait_seconds); END IF;
  UPDATE wedding_email_deliveries SET status='sending', error=NULL, attempted_at=now() WHERE id=delivery.id RETURNING * INTO delivery;
  INSERT INTO wedding_email_attempts(delivery_id,sender) VALUES(delivery.id,p_sender);
  RETURN jsonb_build_object('state','claimed','delivery',to_jsonb(delivery));
END $$;
REVOKE ALL ON FUNCTION claim_wedding_email(uuid,text,integer,double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION claim_wedding_email(uuid,text,integer,double precision) TO service_role;
NOTIFY pgrst, 'reload schema';
