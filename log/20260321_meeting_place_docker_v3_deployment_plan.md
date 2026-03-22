# Meeting Place Docker v3.0.0 Deployment Plan

**Date**: 2026-03-21
**Branch**: `feature/meeting-place-deployment`
**Base**: Docker v2.8.0 (plan2.2, 12 fixes, E2E passed 2026-03-08)
**Target**: v3.0.0 (Service Grant SkillSet added)

---

## Context

Docker構成は v2.8.0 で3チーム×2ラウンドのレビュー済み（Fix 1-12）。
今回は増分変更のみ。Multi-LLM reviewは不要と判断。

## Scope

1. v3.0.0 対応（service_grant skillset 追加）
2. ローカル Docker build & test
3. EC2 デプロイ（TLS + reverse proxy）

---

## Phase 1: v3.0.0 Docker対応（ローカル）

### 1.1 Dockerfile変更

**変更点**: service_grant skillset のインストール追加

```dockerfile
# 現状（L47-51）
RUN kairos-chain init /app/.kairos-template && \
    kairos-chain skillset install /app/skillset-sources/mmp      --data-dir /app/.kairos-template && \
    kairos-chain skillset install /app/skillset-sources/hestia    --data-dir /app/.kairos-template && \
    kairos-chain skillset install /app/skillset-sources/synoptis  --data-dir /app/.kairos-template && \
    kairos-chain skillset install /app/skillset-sources/multiuser --data-dir /app/.kairos-template && \
    rm -rf /app/skillset-sources

# 追加
    kairos-chain skillset install /app/skillset-sources/service_grant --data-dir /app/.kairos-template && \
```

**注意**: `service_grant` は `requires_pg: true` で `depends_on: ["hestia", "synoptis"]`。
multiuser と同じ PG 接続を共有する。entrypoint.sh で PG 設定を注入する必要あり。

### 1.2 entrypoint.sh変更

service_grant の config にも PostgreSQL 接続情報を注入:

```bash
# 新規追加（Section 2 の後）
apply_config "/app/config-override/service_grant.yml" \
  "$KAIROS_DATA_DIR/skillsets/service_grant/config/service_grant.yml"
```

PG接続注入（multiuser と同様のパターン）:

```bash
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
echo "[entrypoint] Service Grant PostgreSQL connection configured."
```

### 1.3 docker/config/service_grant.yml 作成

Docker環境用のデフォルト設定（最小限のoverride）:

```yaml
default_service: meeting_place
pg_unavailable_policy: deny_all
```

PG接続はentrypoint.shが環境変数から注入するので、configには書かない。

### 1.4 ローカル Build & Test

```bash
cd docker/
docker compose down -v
docker compose build --no-cache
docker compose up -d
```

**検証項目**:

| # | テスト | コマンド | 期待値 |
|---|--------|---------|--------|
| 1 | Health | `curl localhost:8080/health` | `status: ok`, `version: 3.0.0`, `place_started: true` |
| 2 | SkillSet一覧 | MCP `tools/list` | service_grant関連4ツール含む |
| 3 | Admin token | `docker exec kairos-meeting-place cat /app/.kairos/.admin_token` | トークン取得可能 |
| 4 | Service Grant status | MCP `service_grant_status` | enabled, PG connected |
| 5 | Logs | `docker compose logs` | エラー/警告なし |

---

## Phase 2: EC2 デプロイ

### 2.1 前提・決定事項（要確認）

| 項目 | 未決/決定済み | 備考 |
|------|:----------:|------|
| EC2 instance type | 未決 | t3.small推奨（2 vCPU, 2GB RAM） |
| Domain | 未決 | e.g., meeting.kairoschain.io |
| TLS 終端 | 未決 | Caddy推奨（auto HTTPS, Let's Encrypt） |
| OS/AMI | 未決 | Amazon Linux 2023 or Ubuntu 24.04 |
| Docker install | 未決 | docker compose v2 (plugin) |
| SSH key | 未決 | 既存 or 新規 |

### 2.2 docker-compose.prod.yml

本番用compose（Caddy reverse proxy追加）:

```yaml
services:
  caddy:
    image: caddy:2-alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - caddy-data:/data
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    depends_on:
      meeting-place:
        condition: service_healthy
    restart: unless-stopped

  meeting-place:
    # port 8080 is internal only (no host mapping)
    ...

  postgres:
    ...

volumes:
  caddy-data:
  kairos-data:
  pg-data:
```

### 2.3 Caddyfile

```
meeting.kairoschain.io {
    reverse_proxy meeting-place:8080
}
```

### 2.4 EC2 セットアップスクリプト

```bash
# 1. Docker install
# 2. git clone (or scp docker/ directory)
# 3. .env 作成（強いPG password）
# 4. docker compose -f docker-compose.prod.yml up -d
# 5. DNS A record → EC2 public IP
```

### 2.5 本番検証

| # | テスト | 期待値 |
|---|--------|--------|
| 1 | `curl https://meeting.kairoschain.io/health` | TLS + health OK |
| 2 | Place API info | `/place/v1/info` 応答 |
| 3 | Agent registration | E2E (register → agents list) |
| 4 | Container restart | `docker compose restart` → 自動復帰 |

---

## 実行順序

1. **Phase 1.1-1.3**: Dockerfile + entrypoint.sh + config 変更
2. **Phase 1.4**: ローカルbuild & test
3. **Phase 2 前提確認**: EC2/ドメイン等の決定
4. **Phase 2.2-2.4**: prod compose + EC2 デプロイ
5. **Phase 2.5**: 本番検証

## リスク

- **service_grant の PG migration**: `service_grant` は初回起動時にテーブル作成が必要。
  multiuser と同じ DB を共有するので、entrypoint で特別な migration step が必要か確認要。
- **既存 volume との互換**: v2.8.0 で作った volume がある場合、service_grant skillset が
  追加されていない。volume seeding は `.kairos_meta.yml` の存在チェックなので、
  既存 volume には service_grant が入らない → `docker compose down -v` で初期化が安全。
