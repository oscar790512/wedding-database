-- Wedding RSVP & Admin System
-- PostgreSQL schema for Supabase

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ---------------------------------------------------------------------------
-- guests: 賓客 RSVP 與現場管理
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guests (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT NOT NULL,
  phone           TEXT NOT NULL,
  email           TEXT,
  status          TEXT NOT NULL DEFAULT 'undecided'
                    CHECK (status IN ('attend', 'decline', 'undecided')),
  total_adults    INTEGER NOT NULL DEFAULT 0 CHECK (total_adults >= 0),
  total_children  INTEGER NOT NULL DEFAULT 0 CHECK (total_children >= 0),
  actual_adults   INTEGER CHECK (actual_adults IS NULL OR actual_adults >= 0),
  actual_children INTEGER CHECK (actual_children IS NULL OR actual_children >= 0),
  vegetarian_count INTEGER NOT NULL DEFAULT 0 CHECK (vegetarian_count >= 0),
  vegetarian_adults INTEGER NOT NULL DEFAULT 0 CHECK (vegetarian_adults >= 0),
  vegetarian_children INTEGER NOT NULL DEFAULT 0 CHECK (vegetarian_children >= 0),
  allergy_notes   TEXT,
  child_seats     INTEGER NOT NULL DEFAULT 0 CHECK (child_seats >= 0),
  diet_notes      TEXT,
  need_invitation BOOLEAN NOT NULL DEFAULT FALSE,
  invitation_address TEXT,
  decline_response TEXT CHECK (
    decline_response IS NULL
    OR decline_response IN ('blessing_only', 'request_cake')
  ),
  blessing_message TEXT,
  guest_category  TEXT,
  invitation_status TEXT NOT NULL DEFAULT 'not_required'
                    CHECK (invitation_status IN ('not_required', 'pending_address', 'pending_send', 'sent', 'received')),
  cake_status     TEXT NOT NULL DEFAULT 'not_required'
                    CHECK (cake_status IN ('not_required', 'pending_pickup', 'pending_address', 'pending_send', 'sent', 'pickup')),
  shipping_recipient TEXT,
  shipping_phone  TEXT,
  shipping_address TEXT,
  shipping_date   DATE,
  tracking_no     TEXT,
  is_arrived      BOOLEAN NOT NULL DEFAULT FALSE,
  arrived_at      TIMESTAMPTZ,
  checkin_updated_at TIMESTAMPTZ,
  checkin_note    TEXT,
  checkin_token   TEXT UNIQUE,
  checkin_token_rotated_at TIMESTAMPTZ,
  gift_amount     NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (gift_amount >= 0),
  allocated_table TEXT,
  admin_notes     TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_guests_phone ON guests (phone);
CREATE INDEX IF NOT EXISTS idx_guests_name ON guests (name);
CREATE INDEX IF NOT EXISTS idx_guests_status ON guests (status);

-- ---------------------------------------------------------------------------
-- admin_users: 管理端登入帳號
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS admin_users (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username       TEXT NOT NULL UNIQUE,
  password_hash  TEXT NOT NULL,
  role           TEXT NOT NULL DEFAULT 'staff'
                   CHECK (role IN ('admin', 'staff'))
);

CREATE INDEX IF NOT EXISTS idx_admin_users_username ON admin_users (username);

-- ---------------------------------------------------------------------------
-- table_settings: 桌次容量設定
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS table_settings (
  table_name TEXT PRIMARY KEY,
  capacity   INTEGER NOT NULL DEFAULT 12 CHECK (capacity > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- api_counters: 後台排程 / 外部整合計數器
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS api_counters (
  counter_key TEXT PRIMARY KEY,
  count       INTEGER NOT NULL DEFAULT 0 CHECK (count >= 0),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION increment_api_counter(
  counter_name TEXT,
  increment_by INTEGER DEFAULT 1
)
RETURNS TABLE (
  counter_key TEXT,
  count INTEGER,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF counter_name IS NULL OR btrim(counter_name) = '' THEN
    RAISE EXCEPTION 'counter_name is required';
  END IF;

  IF increment_by <= 0 THEN
    RAISE EXCEPTION 'increment_by must be positive';
  END IF;

  RETURN QUERY
  INSERT INTO api_counters AS counters (counter_key, count, created_at, updated_at)
  VALUES (btrim(counter_name), increment_by, NOW(), NOW())
  ON CONFLICT (counter_key) DO UPDATE
    SET count = counters.count + EXCLUDED.count,
        updated_at = NOW()
  RETURNING counters.counter_key, counters.count, counters.created_at, counters.updated_at;
END;
$$;

ALTER TABLE table_settings
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

UPDATE table_settings
SET created_at = COALESCE(created_at, updated_at, NOW())
WHERE created_at IS NULL;

-- ---------------------------------------------------------------------------
-- Row Level Security (RLS)
-- FastAPI 後端使用 service_role key 存取，會 bypass RLS。
-- 啟用 RLS 可阻擋 anon / authenticated 透過 PostgREST 直接讀寫資料表。
-- ---------------------------------------------------------------------------
ALTER TABLE guests ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE table_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_counters ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Migration: need_cake -> need_invitation + invitation_address
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'guests'
      AND column_name = 'need_cake'
  ) THEN
    ALTER TABLE guests RENAME COLUMN need_cake TO need_invitation;
  END IF;
END $$;

ALTER TABLE guests ADD COLUMN IF NOT EXISTS invitation_address TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS email TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS child_seats INTEGER NOT NULL DEFAULT 0 CHECK (child_seats >= 0);
ALTER TABLE guests ADD COLUMN IF NOT EXISTS actual_adults INTEGER CHECK (actual_adults IS NULL OR actual_adults >= 0);
ALTER TABLE guests ADD COLUMN IF NOT EXISTS actual_children INTEGER CHECK (actual_children IS NULL OR actual_children >= 0);
ALTER TABLE guests ADD COLUMN IF NOT EXISTS vegetarian_count INTEGER NOT NULL DEFAULT 0 CHECK (vegetarian_count >= 0);
ALTER TABLE guests ADD COLUMN IF NOT EXISTS vegetarian_adults INTEGER NOT NULL DEFAULT 0 CHECK (vegetarian_adults >= 0);
ALTER TABLE guests ADD COLUMN IF NOT EXISTS vegetarian_children INTEGER NOT NULL DEFAULT 0 CHECK (vegetarian_children >= 0);
ALTER TABLE guests ADD COLUMN IF NOT EXISTS allergy_notes TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS decline_response TEXT CHECK (
  decline_response IS NULL
  OR decline_response IN ('blessing_only', 'request_cake')
);
ALTER TABLE guests ADD COLUMN IF NOT EXISTS blessing_message TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS guest_category TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS invitation_status TEXT NOT NULL DEFAULT 'not_required' CHECK (
  invitation_status IN ('not_required', 'pending_address', 'pending_send', 'sent', 'received')
);
ALTER TABLE guests ADD COLUMN IF NOT EXISTS cake_status TEXT NOT NULL DEFAULT 'not_required';
ALTER TABLE guests DROP CONSTRAINT IF EXISTS guests_cake_status_check;
ALTER TABLE guests ADD CONSTRAINT guests_cake_status_check CHECK (
  cake_status IN ('not_required', 'pending_pickup', 'pending_address', 'pending_send', 'sent', 'pickup')
);
ALTER TABLE guests ADD COLUMN IF NOT EXISTS shipping_recipient TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS shipping_phone TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS shipping_address TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS shipping_date DATE;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS tracking_no TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS is_arrived BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS arrived_at TIMESTAMPTZ;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS checkin_updated_at TIMESTAMPTZ;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS checkin_note TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS checkin_token TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS checkin_token_rotated_at TIMESTAMPTZ;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS gift_amount NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (gift_amount >= 0);
ALTER TABLE guests ADD COLUMN IF NOT EXISTS allocated_table TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS admin_notes TEXT;
ALTER TABLE guests ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE guests ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

UPDATE guests
SET shipping_address = invitation_address
WHERE status = 'decline'
  AND decline_response = 'request_cake'
  AND shipping_address IS NULL
  AND invitation_address IS NOT NULL;

UPDATE guests
SET cake_status = CASE
  WHEN shipping_address IS NULL THEN 'pending_address'
  ELSE 'pending_send'
END
WHERE status = 'decline'
  AND decline_response = 'request_cake'
  AND cake_status = 'not_required';

UPDATE guests
SET cake_status = 'pending_pickup'
WHERE status = 'attend'
  AND cake_status = 'not_required';

UPDATE guests
SET vegetarian_count = vegetarian_adults + vegetarian_children
WHERE vegetarian_count = 0
  AND (vegetarian_adults > 0 OR vegetarian_children > 0);

CREATE INDEX IF NOT EXISTS idx_guests_guest_category ON guests (guest_category);
CREATE INDEX IF NOT EXISTS idx_guests_email ON guests (email);
CREATE INDEX IF NOT EXISTS idx_guests_allocated_table ON guests (allocated_table);
CREATE INDEX IF NOT EXISTS idx_guests_invitation_status ON guests (invitation_status);
CREATE INDEX IF NOT EXISTS idx_guests_cake_status ON guests (cake_status);
CREATE INDEX IF NOT EXISTS idx_guests_deleted_at ON guests (deleted_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_guests_checkin_token ON guests (checkin_token) WHERE checkin_token IS NOT NULL;
