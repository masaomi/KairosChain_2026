-- Phase 3b: Subscription expiry and provider transaction ID
--
-- NOTE: Existing service_grants with paid plans will have
-- subscription_expires_at = NULL after this migration.
-- NULL means "no expiry enforced" (grandfathered).
-- New payments via PaymentVerifier always set this column.

ALTER TABLE service_grants
  ADD COLUMN IF NOT EXISTS subscription_expires_at TIMESTAMPTZ;

ALTER TABLE payment_records
  ADD COLUMN IF NOT EXISTS provider_tx_id TEXT;

CREATE INDEX IF NOT EXISTS idx_payment_provider_tx
  ON payment_records (provider_tx_id)
  WHERE provider_tx_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_grants_expiring
  ON service_grants (subscription_expires_at)
  WHERE subscription_expires_at IS NOT NULL;
