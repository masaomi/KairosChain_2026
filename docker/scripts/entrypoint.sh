#!/bin/bash
set -e

KAIROS_DATA_DIR="${KAIROS_DATA_DIR:-/app/.kairos}"

# -------------------------------------------------------------------------
# 0. Validate required environment
# -------------------------------------------------------------------------
if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "[entrypoint] FATAL: POSTGRES_PASSWORD is not set or empty."
  exit 1
fi

# -------------------------------------------------------------------------
# 0.5 Volume seeding: copy build-time template if volume is empty
# -------------------------------------------------------------------------
if [ ! -f "$KAIROS_DATA_DIR/.kairos_meta.yml" ]; then
  echo "[entrypoint] First start: seeding volume from build-time template..."
  cp -a /app/.kairos-template/. "$KAIROS_DATA_DIR/"
  echo "[entrypoint] Volume seeded."
else
  echo "[entrypoint] Volume already initialized."
  # Sync skillsets from template (handles both missing and upgraded skillsets)
  for ss in mmp hestia synoptis multiuser service_grant; do
    if [ ! -d "/app/.kairos-template/skillsets/$ss" ]; then
      continue
    fi
    if [ ! -d "$KAIROS_DATA_DIR/skillsets/$ss" ]; then
      echo "[entrypoint] SkillSet '$ss' missing from volume. Copying from template..."
      cp -a "/app/.kairos-template/skillsets/$ss" "$KAIROS_DATA_DIR/skillsets/$ss"
    else
      # Compare tool counts and skillset.json to detect upgrades
      tmpl_hash=$(md5sum "/app/.kairos-template/skillsets/$ss/skillset.json" 2>/dev/null | cut -d' ' -f1)
      vol_hash=$(md5sum "$KAIROS_DATA_DIR/skillsets/$ss/skillset.json" 2>/dev/null | cut -d' ' -f1)
      if [ "$tmpl_hash" != "$vol_hash" ]; then
        echo "[entrypoint] SkillSet '$ss' updated in image. Syncing from template (preserving config)..."
        # Backup config before sync
        if [ -d "$KAIROS_DATA_DIR/skillsets/$ss/config" ]; then
          cp -a "$KAIROS_DATA_DIR/skillsets/$ss/config" "/tmp/${ss}_config_backup"
        fi
        cp -a "/app/.kairos-template/skillsets/$ss/." "$KAIROS_DATA_DIR/skillsets/$ss/"
        # Restore config (volume config takes precedence)
        if [ -d "/tmp/${ss}_config_backup" ]; then
          cp -a "/tmp/${ss}_config_backup/." "$KAIROS_DATA_DIR/skillsets/$ss/config/"
          rm -rf "/tmp/${ss}_config_backup"
        fi
      fi
    fi
  done
fi

# -------------------------------------------------------------------------
# 1. Apply config overrides (recursive YAML deep merge via Ruby)
# -------------------------------------------------------------------------
apply_config() {
  local src="$1" dest="$2"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    MERGE_SRC="$src" MERGE_DEST="$dest" ruby -ryaml -e '
      def deep_merge(base, override)
        base.merge(override) do |_key, old_val, new_val|
          if old_val.is_a?(Hash) && new_val.is_a?(Hash)
            deep_merge(old_val, new_val)
          else
            new_val
          end
        end
      end

      src  = ENV["MERGE_SRC"]
      dest = ENV["MERGE_DEST"]
      base = File.exist?(dest) ? (YAML.safe_load(File.read(dest)) || {}) : {}
      override = YAML.safe_load(File.read(src)) || {}
      File.write(dest, YAML.dump(deep_merge(base, override)))
    '
    echo "[entrypoint] Applied config: $(basename "$src")"
  fi
}

apply_config "/app/config-override/config.yml" \
  "$KAIROS_DATA_DIR/skills/config.yml"

apply_config "/app/config-override/multiuser.yml" \
  "$KAIROS_DATA_DIR/skillsets/multiuser/config/multiuser.yml"

apply_config "/app/config-override/hestia.yml" \
  "$KAIROS_DATA_DIR/skillsets/hestia/config/hestia.yml"

apply_config "/app/config-override/meeting.yml" \
  "$KAIROS_DATA_DIR/skillsets/mmp/config/meeting.yml"

apply_config "/app/config-override/synoptis.yml" \
  "$KAIROS_DATA_DIR/skillsets/synoptis/config/synoptis.yml"

apply_config "/app/config-override/service_grant.yml" \
  "$KAIROS_DATA_DIR/skillsets/service_grant/config/service_grant.yml"

# -------------------------------------------------------------------------
# 2. Inject PostgreSQL connection (password stays in ENV only)
# -------------------------------------------------------------------------
MERGE_DEST="$KAIROS_DATA_DIR/skillsets/multiuser/config/multiuser.yml" \
  ruby -ryaml -e '
    dest = ENV["MERGE_DEST"]
    cfg = File.exist?(dest) ? (YAML.safe_load(File.read(dest)) || {}) : {}
    pg = cfg["postgresql"] || {}
    pg["host"]   = ENV["POSTGRES_HOST"]   || pg["host"]   || "postgres"
    pg["port"]   = (ENV["POSTGRES_PORT"]  || pg["port"]   || 5432).to_i
    pg["dbname"] = ENV["POSTGRES_DB"]     || pg["dbname"] || "kairoschain"
    pg["user"]   = ENV["POSTGRES_USER"]   || pg["user"]   || "kairoschain"
    pg.delete("password")
    cfg["postgresql"] = pg
    File.write(dest, YAML.dump(cfg))
  '
echo "[entrypoint] Multiuser PostgreSQL connection configured."

MERGE_DEST="$KAIROS_DATA_DIR/skillsets/service_grant/config/service_grant.yml" \
  ruby -ryaml -e '
    dest = ENV["MERGE_DEST"]
    cfg = File.exist?(dest) ? (YAML.safe_load(File.read(dest)) || {}) : {}
    pg = cfg["postgresql"] || {}
    pg["host"]   = ENV["POSTGRES_HOST"]   || pg["host"]   || "postgres"
    pg["port"]   = (ENV["POSTGRES_PORT"]  || pg["port"]   || 5432).to_i
    pg["dbname"] = ENV["POSTGRES_DB"]     || pg["dbname"] || "kairoschain"
    pg["user"]   = ENV["POSTGRES_USER"]   || pg["user"]   || "kairoschain"
    pg.delete("password")
    cfg["postgresql"] = pg
    File.write(dest, YAML.dump(cfg))
  '
echo "[entrypoint] Service Grant PostgreSQL connection configured (password via ENV only)."

# -------------------------------------------------------------------------
# 3. Wait for PostgreSQL (fatal on timeout)
# -------------------------------------------------------------------------
if [ -n "$POSTGRES_HOST" ]; then
  echo "[entrypoint] Waiting for PostgreSQL at $POSTGRES_HOST:${POSTGRES_PORT:-5432}..."
  for i in $(seq 1 30); do
    if pg_isready -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -q 2>/dev/null; then
      echo "[entrypoint] PostgreSQL is ready."
      break
    fi
    if [ "$i" = "30" ]; then
      echo "[entrypoint] FATAL: PostgreSQL not ready after 30s."
      exit 1
    fi
    sleep 1
  done
fi

# -------------------------------------------------------------------------
# 3.5 Run Service Grant database migrations
# -------------------------------------------------------------------------
if [ -d "$KAIROS_DATA_DIR/skillsets/service_grant/migrations" ]; then
  echo "[entrypoint] Running Service Grant database migrations..."
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" \
    -U "${POSTGRES_USER:-kairoschain}" -d "${POSTGRES_DB:-kairoschain}" -q \
    -f "$KAIROS_DATA_DIR/skillsets/service_grant/migrations/001_service_grant_schema.sql" 2>&1
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" \
    -U "${POSTGRES_USER:-kairoschain}" -d "${POSTGRES_DB:-kairoschain}" -q \
    -f "$KAIROS_DATA_DIR/skillsets/service_grant/migrations/002_grant_ip_events.sql" 2>&1
  echo "[entrypoint] Service Grant migrations applied."
fi

# -------------------------------------------------------------------------
# 4. Bootstrap admin token
#    Uses the token output file as idempotency guard.
#    If .admin_token exists in the volume, bootstrap was already done.
# -------------------------------------------------------------------------
ADMIN_TOKEN_FILE="$KAIROS_DATA_DIR/.admin_token"

if [ ! -f "$ADMIN_TOKEN_FILE" ]; then
  echo "[entrypoint] No admin token file found. Bootstrapping admin token..."
  kairos-chain --init-admin --quiet \
    --token-output-file "$ADMIN_TOKEN_FILE" \
    --data-dir "$KAIROS_DATA_DIR" 2>&1
  if [ -f "$ADMIN_TOKEN_FILE" ]; then
    echo "[entrypoint] Admin token created and saved."
    echo "[entrypoint] Retrieve: docker exec kairos-meeting-place cat /app/.kairos/.admin_token"
  else
    echo "[entrypoint] WARNING: Admin token bootstrap may have failed."
  fi
else
  echo "[entrypoint] Admin token file exists. Skipping bootstrap."
fi

# -------------------------------------------------------------------------
# 5. Start
# -------------------------------------------------------------------------
echo "[entrypoint] Starting KairosChain Meeting Place Server..."
exec "$@"
