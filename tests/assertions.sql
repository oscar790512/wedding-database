DO $$
BEGIN
  IF to_regclass('public.wedding_email_batches') IS NULL
     OR to_regclass('public.wedding_email_deliveries') IS NULL
     OR to_regclass('public.wedding_email_attempts') IS NULL THEN
    RAISE EXCEPTION 'Email delivery tables were not created';
  END IF;
  IF to_regprocedure('public.enqueue_wedding_email(uuid,text,text,text,jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.claim_wedding_email(uuid,text,integer,double precision)') IS NULL THEN
    RAISE EXCEPTION 'Email queue functions were not created';
  END IF;
  IF EXISTS (SELECT FROM pg_class WHERE oid IN ('public.wedding_email_batches'::regclass, 'public.wedding_email_deliveries'::regclass, 'public.wedding_email_attempts'::regclass) AND NOT relrowsecurity) THEN
    RAISE EXCEPTION 'Email tables must enforce RLS';
  END IF;
  IF has_table_privilege('anon', 'wedding_email_deliveries', 'SELECT')
     OR has_table_privilege('authenticated', 'wedding_email_deliveries', 'SELECT')
     OR has_function_privilege('authenticated', 'claim_wedding_email(uuid,text,integer,double precision)', 'EXECUTE')
     OR has_function_privilege('anon', 'enqueue_wedding_email(uuid,text,text,text,jsonb,jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Browser roles must not access private delivery data or queue functions';
  END IF;
  IF NOT has_table_privilege('service_role', 'wedding_email_deliveries', 'SELECT')
     OR NOT has_function_privilege('service_role', 'claim_wedding_email(uuid,text,integer,double precision)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Backend service role cannot manage deliveries';
  END IF;
  IF NOT EXISTS (SELECT FROM wedding_email_deliveries WHERE id='20000000-0000-4000-8000-000000000001'
      AND status='sent' AND checkin_token='test-only-qr' AND sent_at='2026-10-26T00:00:00Z')
     OR (SELECT count(*) FROM wedding_email_deliveries) <> 1
     OR (SELECT count(*) FROM wedding_email_attempts) <> 1
     OR (SELECT content->>'subject' FROM wedding_email_batches WHERE id='10000000-0000-4000-8000-000000000001') <> 'Original reviewed subject' THEN
    RAISE EXCEPTION 'Migration must preserve existing sent emails, QR tokens, template snapshots and attempts';
  END IF;
  IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_schema='public' AND table_name='table_settings' AND column_name='table_number') THEN
    RAISE EXCEPTION 'Existing table-number migration was lost';
  END IF;
END $$;
