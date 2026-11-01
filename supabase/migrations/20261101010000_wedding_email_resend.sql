-- Retain completed delivery rows; only the latest delivery participates in duplicate prevention.
ALTER TABLE wedding_email_deliveries ADD COLUMN IF NOT EXISTS superseded_at timestamptz;
ALTER TABLE wedding_email_deliveries DROP CONSTRAINT IF EXISTS wedding_email_deliveries_campaign_guest_id_key;
CREATE UNIQUE INDEX IF NOT EXISTS wedding_email_current_guest ON wedding_email_deliveries(campaign,guest_id)
  WHERE superseded_at IS NULL;

CREATE OR REPLACE FUNCTION enqueue_wedding_email(p_id uuid, p_campaign text, p_sender text, p_actor text, p_content jsonb, p_guests jsonb)
RETURNS uuid LANGUAGE plpgsql SET search_path = public AS $$
DECLARE new_id uuid;
BEGIN
  INSERT INTO wedding_email_batches(id, campaign, sender, created_by, content)
    VALUES (p_id, p_campaign, p_sender, p_actor, p_content) ON CONFLICT (id) DO NOTHING RETURNING id INTO new_id;
  IF new_id IS NULL THEN RETURN p_id; END IF;
  -- Only the first confirmation creates deliveries. Replaying the request is safe.
  INSERT INTO wedding_email_deliveries(batch_id, campaign, guest_id, name, email, checkin_token)
    SELECT p_id, p_campaign, (g->>'id')::uuid, g->>'name', g->>'email', g->>'checkin_token'
    FROM jsonb_array_elements(p_guests) g ON CONFLICT (campaign, guest_id) WHERE superseded_at IS NULL DO UPDATE
      SET batch_id=EXCLUDED.batch_id, name=EXCLUDED.name, email=EXCLUDED.email,
          checkin_token=EXCLUDED.checkin_token, status='pending', error=NULL
      WHERE wedding_email_deliveries.status='failed';
  RETURN p_id;
END $$;


CREATE OR REPLACE FUNCTION enqueue_wedding_email_resend(
  p_id uuid, p_campaign text, p_sender text, p_actor text, p_content jsonb, p_guest jsonb, p_previous jsonb
) RETURNS uuid LANGUAGE plpgsql SET search_path = public AS $$
DECLARE previous wedding_email_deliveries; existing wedding_email_batches;
BEGIN
  -- Serialize confirmation replay before locking the original delivery.
  PERFORM pg_advisory_xact_lock(hashtext('wedding_email_enqueue:' || p_id::text));
  SELECT * INTO existing FROM wedding_email_batches WHERE id=p_id;
  IF FOUND THEN
    IF existing.campaign=p_campaign AND existing.sender=p_sender AND existing.created_by=p_actor
       AND existing.content=p_content AND existing.content->'resend_of'=p_previous THEN RETURN p_id; END IF;
    RAISE EXCEPTION 'Resend confirmation changed';
  END IF;
  SELECT * INTO previous FROM wedding_email_deliveries
    WHERE id=(p_previous->>'id')::uuid AND campaign=p_campaign FOR UPDATE;
  IF NOT FOUND OR previous.status<>'sent' OR previous.superseded_at IS NOT NULL
     OR previous.guest_id IS DISTINCT FROM (p_guest->>'id')::uuid
     OR previous.batch_id IS DISTINCT FROM (p_previous->>'batch_id')::uuid
     OR previous.email IS DISTINCT FROM p_previous->>'email'
     OR previous.attempted_at IS DISTINCT FROM (p_previous->>'attempted_at')::timestamptz
     OR previous.sent_at IS DISTINCT FROM (p_previous->>'sent_at')::timestamptz
     OR p_content->'resend_of' IS DISTINCT FROM p_previous THEN
    RAISE EXCEPTION 'Delivery changed; preview again';
  END IF;
  INSERT INTO wedding_email_batches(id,campaign,sender,created_by,content)
    VALUES(p_id,p_campaign,p_sender,p_actor,p_content);
  UPDATE wedding_email_deliveries SET superseded_at=now() WHERE id=previous.id;
  INSERT INTO wedding_email_deliveries(batch_id,campaign,guest_id,name,email,checkin_token)
    VALUES(p_id,p_campaign,(p_guest->>'id')::uuid,p_guest->>'name',p_guest->>'email',p_guest->>'checkin_token');
  RETURN p_id;
END $$;
REVOKE ALL ON FUNCTION enqueue_wedding_email_resend(uuid,text,text,text,jsonb,jsonb,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION enqueue_wedding_email_resend(uuid,text,text,text,jsonb,jsonb,jsonb) TO service_role;
NOTIFY pgrst, 'reload schema';
