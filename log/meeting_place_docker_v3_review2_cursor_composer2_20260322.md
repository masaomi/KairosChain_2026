# Review Round 2: Meeting Place Docker v3.0.0

- **Reviewer**: Cursor Composer
- **Model**: Composer (Cursor agent)
- **Date**: 2026-03-22
- **Mode**: manual

## Verdict: CONDITIONAL APPROVE

## Fix Verification

| Fix | Status | Notes |
|-----|--------|-------|
| F1 | PASS | `ec2-setup.sh` L81: `docker exec kairos-meeting-place curl -sf http://localhost:8080/health` — reaches the app inside the container; correct for prod compose without host `:8080` publish. |
| F2 | PASS | L87–88: prints only the retrieval command, not the token value. |
| F3 | PASS | L22–32: `dnf install docker-compose-plugin` first; fallback installs pinned `v2.32.4` to `DOCKER_CLI_PLUGINS` with arch from `uname -m` (matches Compose release asset naming for x86_64/aarch64). |
| F4 | PASS | `docker/Caddyfile` L4–9: HSTS, `nosniff`, `DENY` frame, `Referrer-Policy` present. |
| F5 | PASS | `ec2-setup.sh` L44–46: comment documents `GH_TOKEN` / private clone pattern. |
| F6 | PASS | `entrypoint.sh` L23–29: upgrade path loops `mmp hestia synoptis multiuser service_grant` and copies from template when missing; aligns with Dockerfile skillset installs. Edge case: if entire `skillsets/` parent is absent, `cp` may fail — see New Findings. |
| F7 | PASS | L57: `openssl rand -hex 32` → 64 hex characters (256-bit entropy), fixed width. |
| F8 | PASS | `docker-compose.prod.yml`: `caddy` → `frontend` only; `postgres` → `backend` only; `meeting-place` → `frontend` + `backend`. Caddy cannot route to Postgres by network isolation; `meeting-place` resolves `postgres` on `backend` and is reachable from Caddy on `frontend` as `meeting-place:8080`. |
| F9 | FAIL | Healthcheck **intent** (admin API) is present, but the `test` array is not valid for shell semantics — see New Findings. |

## New Findings (if any)

### [MEDIUM] Caddy healthcheck uses invalid CMD form (shell `||` not applied)
- **File**: `docker/docker-compose.prod.yml:17-21`
- **Description**: `test` is `["CMD", "wget", "-qO-", "http://localhost:2019/config/", "||", "true"]`. In Docker healthchecks, `CMD` runs **without** a shell; `||` and `true` are passed as extra arguments to `wget`, not interpreted as shell OR. Behavior is undefined (likely `wget` error / wrong exit code). The trailing `|| true` was presumably meant to make the check always succeed, but it does not work as written. If the goal is a real check, use e.g. `["CMD-SHELL", "wget -qO- http://localhost:2019/config/ >/dev/null 2>&1"]` or `curl` if available; if admin API is disabled in a future Caddy build, document or use an HTTP probe via loopback to `:80` with `Host` header.
- **Recommendation**: Replace with `CMD-SHELL` and a single coherent command, or drop `|| true` and rely on wget exit code against `http://localhost:2019/config/` (verify Caddy admin defaults to `:2019` in this image). Optionally confirm `wget` exists in `caddy:2-alpine` in CI or a one-off `docker run`.

### [LOW] SkillSet backfill may fail if `skillsets/` parent directory is missing
- **File**: `docker/scripts/entrypoint.sh:24-28`
- **Description**: If an old volume has `.kairos_meta.yml` but `skillsets/` was removed or never created, `cp -a ... "$KAIROS_DATA_DIR/skillsets/$ss"` can fail because the parent directory does not exist.
- **Recommendation**: Before the loop, `mkdir -p "$KAIROS_DATA_DIR/skillsets"` (or skip copy if layout is intentionally invalid and log FATAL).

### [LOW] `ec2-setup.sh` still runs `git clone` of HTTPS URL without auth
- **File**: `docker/scripts/ec2-setup.sh:44-47`
- **Description**: F5 adds a comment only; private-repo deploy still fails until the operator follows the comment. Acceptable if documented as manual step; not a regression.
- **Recommendation**: None required for Round 2 verification; optional: fail fast with a clear message when clone fails with “Repository not found” / 401.

## Summary

Round 1 の HIGH 項目（ホスト向け `localhost:8080` ヘルスチェック、EC2 スクリプトでの admin トークン表示）は意図どおり修正されている。セキュリティヘッダ、PG パスワード長、ネットワーク分離、Compose の pin 付きフォールバック、スキルセットのテンプレートバックフィルも整合している。

一方、**F9 の Caddy ヘルスチェックは Compose の `CMD` セマンティクスと矛盾**しており、健全性表示が信頼できないか常に失敗しうる。デプロイをブロックするほどではないが、運用上の誤解を招くため **CONDITIONAL APPROVE** とし、`CMD-SHELL` への修正または実効性のあるプローブへの差し替えをデプロイ前または直後に推奨する。
