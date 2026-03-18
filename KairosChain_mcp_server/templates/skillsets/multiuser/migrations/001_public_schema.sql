-- Multiuser SkillSet: Public schema (shared across all tenants)

CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username VARCHAR(255) UNIQUE NOT NULL,
  display_name VARCHAR(255),
  tenant_schema VARCHAR(63) NOT NULL,
  role VARCHAR(20) NOT NULL DEFAULT 'member',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash VARCHAR(64) NOT NULL UNIQUE,
  user_id UUID REFERENCES users(id) ON DELETE CASCADE,
  role VARCHAR(20) NOT NULL,
  status VARCHAR(20) DEFAULT 'active',
  issued_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  issued_by VARCHAR(255),
  revoked_at TIMESTAMPTZ,
  revoked_by VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS system_migrations (
  id SERIAL PRIMARY KEY,
  version VARCHAR(255) NOT NULL UNIQUE,
  applied_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tenant_migrations (
  id SERIAL PRIMARY KEY,
  tenant_schema VARCHAR(63) NOT NULL,
  version VARCHAR(255) NOT NULL,
  applied_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(tenant_schema, version)
);

-- System-level audit log (P5 constitutive recording)
CREATE TABLE IF NOT EXISTS system_audit_log (
  id SERIAL PRIMARY KEY,
  timestamp TIMESTAMPTZ DEFAULT NOW(),
  action VARCHAR(50) NOT NULL,
  actor VARCHAR(255),
  target VARCHAR(255),
  details JSONB,
  block_hash VARCHAR(64)
);
