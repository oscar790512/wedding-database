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
  status          TEXT NOT NULL DEFAULT 'undecided'
                    CHECK (status IN ('attend', 'decline', 'undecided')),
  total_adults    INTEGER NOT NULL DEFAULT 0 CHECK (total_adults >= 0),
  total_children  INTEGER NOT NULL DEFAULT 0 CHECK (total_children >= 0),
  child_seats     INTEGER NOT NULL DEFAULT 0 CHECK (child_seats >= 0),
  diet_notes      TEXT,
  need_invitation BOOLEAN NOT NULL DEFAULT FALSE,
  invitation_address TEXT,
  blessing_message TEXT,
  is_arrived      BOOLEAN NOT NULL DEFAULT FALSE,
  gift_amount     NUMERIC(12, 2) NOT NULL DEFAULT 0 CHECK (gift_amount >= 0),
  allocated_table TEXT,
  admin_notes     TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
-- Row Level Security (RLS)
-- FastAPI 後端使用 service_role key 存取，會 bypass RLS。
-- 啟用 RLS 可阻擋 anon / authenticated 透過 PostgREST 直接讀寫資料表。
-- ---------------------------------------------------------------------------
ALTER TABLE guests ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;

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
ALTER TABLE guests ADD COLUMN IF NOT EXISTS child_seats INTEGER NOT NULL DEFAULT 0 CHECK (child_seats >= 0);
