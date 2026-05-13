CREATE TABLE IF NOT EXISTS jobs (
  id          TEXT PRIMARY KEY,
  file_name   TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'pending',
  speed       DOUBLE PRECISION NOT NULL DEFAULT 0.75,
  reverb_wet  DOUBLE PRECISION NOT NULL DEFAULT 0.5,
  reverb_decay DOUBLE PRECISION NOT NULL DEFAULT 2.0,
  format      TEXT NOT NULL DEFAULT 'wav',
  output_path TEXT,
  error       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
