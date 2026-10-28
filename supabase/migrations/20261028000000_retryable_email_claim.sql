-- Safe response-loss recovery: a request UUID reserves at most one delivery/attempt.
-- V1 remains available for currently deployed workers during rollout.
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
  SELECT count(*), max(started_at) INTO used, last_attempt FROM wedding_email_attempts
    WHERE sender=p_sender AND started_at > now()-interval '24 hours';
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
NOTIFY pgrst, 'reload schema';
