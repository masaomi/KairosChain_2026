-- Service Grant SkillSet schema v1.4
-- No users table. pubkey_hash is the identity key.

CREATE TABLE IF NOT EXISTS service_grants (
  id              SERIAL PRIMARY KEY,
  pubkey_hash     TEXT NOT NULL
                    CHECK (pubkey_hash ~ '^[0-9a-f]{64}$'),
  service         TEXT NOT NULL
                    CHECK (length(service) > 0),
  plan            TEXT NOT NULL DEFAULT 'free'
                    CHECK (length(plan) > 0),
  plan_version    TEXT,
  billing_model   TEXT NOT NULL DEFAULT 'free'
                    CHECK (billing_model IN ('per_action', 'metered', 'subscription', 'free')),
  trust_score     REAL DEFAULT 0.0
                    CHECK (trust_score >= 0.0 AND trust_score <= 1.0),
  suspended       BOOLEAN NOT NULL DEFAULT false,
  suspended_reason TEXT,
  first_seen_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_active_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata        JSONB DEFAULT '{}',
  UNIQUE (pubkey_hash, service)
);

CREATE TABLE IF NOT EXISTS usage_counts (
  id              SERIAL PRIMARY KEY,
  pubkey_hash     TEXT NOT NULL,
  service         TEXT NOT NULL,
  action          TEXT NOT NULL,
  count           INTEGER NOT NULL DEFAULT 0
                    CHECK (count >= 0),
  cycle_start     TIMESTAMPTZ NOT NULL,
  cycle_end       TIMESTAMPTZ NOT NULL,
  CHECK (cycle_start < cycle_end),
  UNIQUE (pubkey_hash, service, action, cycle_start)
);

CREATE TABLE IF NOT EXISTS usage_log (
  id              SERIAL PRIMARY KEY,
  pubkey_hash     TEXT NOT NULL,
  service         TEXT NOT NULL,
  action          TEXT NOT NULL,
  tool_name       TEXT,
  recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata        JSONB DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS metered_usage (
  id              SERIAL PRIMARY KEY,
  pubkey_hash     TEXT NOT NULL,
  service         TEXT NOT NULL,
  metric          TEXT NOT NULL,
  cumulative      NUMERIC(12,4) NOT NULL DEFAULT 0.0
                    CHECK (cumulative >= 0.0),
  cycle_start     TIMESTAMPTZ NOT NULL,
  cycle_end       TIMESTAMPTZ NOT NULL,
  CHECK (cycle_start < cycle_end),
  UNIQUE (pubkey_hash, service, metric, cycle_start)
);

CREATE INDEX idx_usage_log_pubkey_service ON usage_log (pubkey_hash, service, recorded_at);
CREATE INDEX idx_grants_suspended ON service_grants (suspended) WHERE suspended = true;

CREATE TABLE IF NOT EXISTS payment_records (
  id                  SERIAL PRIMARY KEY,
  pubkey_hash         TEXT NOT NULL,
  service             TEXT NOT NULL,
  payment_intent_id   TEXT NOT NULL,
  attestation_hash    TEXT NOT NULL,
  payment_type        TEXT NOT NULL,
  amount              NUMERIC(12,4),
  currency            TEXT NOT NULL DEFAULT 'USD',
  amount_display      TEXT,
  old_plan            TEXT NOT NULL,
  new_plan            TEXT NOT NULL,
  nonce               TEXT,
  verified_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (payment_intent_id)
);

-- Permanent nonce uniqueness per payer (stronger than time-windowed)
CREATE UNIQUE INDEX idx_payment_nonce_unique
  ON payment_records (pubkey_hash, nonce)
  WHERE nonce IS NOT NULL;

CREATE INDEX idx_payment_records_pubkey ON payment_records (pubkey_hash);

CREATE TABLE IF NOT EXISTS system_migrations (
  version     TEXT PRIMARY KEY,
  checksum    TEXT,
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
