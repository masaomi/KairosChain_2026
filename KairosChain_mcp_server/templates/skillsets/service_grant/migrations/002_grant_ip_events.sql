-- Phase 2A: IP rate limiting persistence (D-8)
-- Stores grant creation IP events for Sybil rate limiting.
-- IpRateTracker uses this for PG-backed mode with in-memory fallback.

CREATE TABLE IF NOT EXISTS grant_ip_events (
  id          SERIAL PRIMARY KEY,
  ip          TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_grant_ip_events_lookup ON grant_ip_events (ip, created_at);
