-- Multiuser SkillSet: Tenant schema template (SqliteBackend aligned)
-- Applied to each tenant_XXXX schema on creation

CREATE TABLE IF NOT EXISTS blocks (
  id SERIAL PRIMARY KEY,
  block_index INTEGER NOT NULL UNIQUE,
  timestamp TIMESTAMPTZ NOT NULL,
  data JSONB NOT NULL,
  previous_hash VARCHAR(64) NOT NULL,
  merkle_root VARCHAR(64) NOT NULL,
  hash VARCHAR(64) NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS action_logs (
  id SERIAL PRIMARY KEY,
  timestamp TIMESTAMPTZ NOT NULL,
  action VARCHAR(50) NOT NULL,
  skill_id VARCHAR(255),
  layer VARCHAR(10),
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS knowledge_meta (
  id SERIAL PRIMARY KEY,
  name VARCHAR(255) NOT NULL UNIQUE,
  content_hash VARCHAR(64) NOT NULL,
  version VARCHAR(50),
  description TEXT,
  tags JSONB,
  is_archived BOOLEAN DEFAULT FALSE,
  archived_at TIMESTAMPTZ,
  archived_reason TEXT,
  superseded_by VARCHAR(255),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_blocks_hash ON blocks(hash);
CREATE INDEX IF NOT EXISTS idx_blocks_index ON blocks(block_index);
CREATE INDEX IF NOT EXISTS idx_action_logs_timestamp ON action_logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_action_logs_skill ON action_logs(skill_id);
CREATE INDEX IF NOT EXISTS idx_knowledge_meta_archived ON knowledge_meta(is_archived);
CREATE INDEX IF NOT EXISTS idx_knowledge_meta_hash ON knowledge_meta(content_hash);
