ALTER TABLE table_settings
  ADD COLUMN IF NOT EXISTS table_number INTEGER
  CHECK (table_number IS NULL OR table_number > 0);

NOTIFY pgrst, 'reload schema';
