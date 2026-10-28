DO $$
BEGIN
  IF (SELECT count(*) FROM supabase_migrations.schema_migrations) <> 4
     OR NOT EXISTS (SELECT FROM supabase_migrations.schema_migrations WHERE version='20260620000000')
     OR NOT EXISTS (SELECT FROM supabase_migrations.schema_migrations WHERE version='20261004000000')
     OR NOT EXISTS (SELECT FROM supabase_migrations.schema_migrations WHERE version='20261026000000')
     OR NOT EXISTS (SELECT FROM supabase_migrations.schema_migrations WHERE version='20261028000000') THEN
    RAISE EXCEPTION 'Supabase must track each migration exactly once';
  END IF;
END $$;
