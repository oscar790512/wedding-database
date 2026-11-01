DO $$
BEGIN
  IF to_regclass('public.wedding_email_batches') IS NULL
     OR to_regclass('public.wedding_email_deliveries') IS NULL
     OR to_regclass('public.wedding_email_attempts') IS NULL THEN
    RAISE EXCEPTION 'Email delivery tables were not created';
  END IF;
  IF to_regprocedure('public.enqueue_wedding_email(uuid,text,text,text,jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.claim_wedding_email(uuid,text,integer,double precision)') IS NULL
     OR to_regprocedure('public.claim_wedding_email_v2(uuid,text,integer,double precision,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Email queue functions were not created';
  END IF;
  IF EXISTS (SELECT FROM pg_class WHERE oid IN ('public.wedding_email_batches'::regclass, 'public.wedding_email_deliveries'::regclass, 'public.wedding_email_attempts'::regclass) AND NOT relrowsecurity) THEN
    RAISE EXCEPTION 'Email tables must enforce RLS';
  END IF;
  IF has_table_privilege('anon', 'wedding_email_deliveries', 'SELECT')
     OR has_table_privilege('authenticated', 'wedding_email_deliveries', 'SELECT')
     OR has_function_privilege('authenticated', 'claim_wedding_email(uuid,text,integer,double precision)', 'EXECUTE')
     OR has_function_privilege('anon', 'enqueue_wedding_email(uuid,text,text,text,jsonb,jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'claim_wedding_email_v2(uuid,text,integer,double precision,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'claim_wedding_email_v2(uuid,text,integer,double precision,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Browser roles must not access private delivery data or queue functions';
  END IF;
  IF NOT has_table_privilege('service_role', 'wedding_email_deliveries', 'SELECT')
     OR NOT has_function_privilege('service_role', 'claim_wedding_email(uuid,text,integer,double precision)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'claim_wedding_email_v2(uuid,text,integer,double precision,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Backend service role cannot manage deliveries';
  END IF;
  IF NOT EXISTS (SELECT FROM wedding_email_deliveries WHERE id='20000000-0000-4000-8000-000000000001'
      AND status='sent' AND checkin_token='test-only-qr' AND sent_at='2026-10-26T00:00:00Z')
     OR (SELECT count(*) FROM wedding_email_deliveries) <> 1
     OR (SELECT count(*) FROM wedding_email_attempts) <> 1
     OR (SELECT content->>'subject' FROM wedding_email_batches WHERE id='10000000-0000-4000-8000-000000000001') <> 'Original reviewed subject' THEN
    RAISE EXCEPTION 'Migration must preserve existing sent emails, QR tokens, template snapshots and attempts';
  END IF;
  IF to_regclass('public.wedding_email_relay_requests') IS NULL
     OR to_regprocedure('public.reserve_wedding_email_relay(uuid,text,text,integer,double precision)') IS NULL
     OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.wedding_email_relay_requests'::regclass)
     OR has_table_privilege('anon','wedding_email_relay_requests','SELECT')
     OR has_table_privilege('authenticated','wedding_email_relay_requests','SELECT')
     OR has_function_privilege('anon','reserve_wedding_email_relay(uuid,text,text,integer,double precision)','EXECUTE')
     OR has_function_privilege('authenticated','reserve_wedding_email_relay(uuid,text,text,integer,double precision)','EXECUTE')
     OR NOT has_function_privilege('service_role','reserve_wedding_email_relay(uuid,text,text,integer,double precision)','EXECUTE') THEN
    RAISE EXCEPTION 'Relay receipts and reservation must be private and usable by service role';
  END IF;
  IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_schema='public' AND table_name='wedding_email_deliveries' AND column_name='superseded_at')
     OR to_regclass('public.wedding_email_current_guest') IS NULL
     OR to_regprocedure('public.enqueue_wedding_email_resend(uuid,text,text,text,jsonb,jsonb,jsonb)') IS NULL
     OR has_function_privilege('anon','enqueue_wedding_email_resend(uuid,text,text,text,jsonb,jsonb,jsonb)','EXECUTE')
     OR has_function_privilege('authenticated','enqueue_wedding_email_resend(uuid,text,text,text,jsonb,jsonb,jsonb)','EXECUTE')
     OR NOT has_function_privilege('service_role','enqueue_wedding_email_resend(uuid,text,text,text,jsonb,jsonb,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'Explicit resend schema must retain history and restrict enqueue to backend';
  END IF;
  IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_schema='public' AND table_name='table_settings' AND column_name='table_number') THEN
    RAISE EXCEPTION 'Existing table-number migration was lost';
  END IF;
END $$;
