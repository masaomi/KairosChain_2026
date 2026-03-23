---
tags: [docker, meeting-place, ec2, deployment, security, production]
status: deployed
date: 2026-03-23
related_sessions: [session_20260322_192528_ebe072e0, session_20260322_193208_1deb4496, session_20260323_053444_ed2063ab]
---

# Meeting Place Server — Deployment Complete (2026-03-23)

## Deployed Server

- **URL**: https://meeting.genomicschain.io
- **Version**: v3.1.1 (gem v3.1.1 inside Docker, but image built from v3.1.0 code — needs rebuild for v3.1.1 version string)
- **EC2**: t3.medium, Ubuntu 24.04 LTS, Elastic IP 63.178.216.211
- **DNS**: meeting.genomicschain.io → 63.178.216.211 (Infomaniak)
- **TLS**: Caddy auto-managed Let's Encrypt certificate
- **Health**: https://meeting.genomicschain.io/health → OK
- **Place**: https://meeting.genomicschain.io/place/v1/info → OK

## Infrastructure

- Docker Compose (prod): Caddy + meeting-place + postgres
- Networks: frontend (Caddy + app), backend (app + PG)
- Volumes: caddy-data, caddy-config, kairos-data, pg-data
- Admin token: `docker exec kairos-meeting-place cat /app/.kairos/.admin_token`

## Post-Deploy Fixes Applied

1. **Port 80 conflict**: Killed old screen session `SCREEN -S kairos` (PID 3976961)
   - Cleanup done: `screen -X -S kairos quit`
2. **Caddy DNS**: Added dns: [8.8.8.8, 1.1.1.1] to Caddy container (Ubuntu systemd-resolved incompatible)
3. **HTTPS support**: All MMP tools lacked `http.use_ssl` — fixed in v3.1.1

## Security TODO (pending)

### HIGH Priority
1. **Restore cooldown**: `grant_creation_cooldown` is currently 0 (test mode). Set to 60-300s.
   - File: `docker/config/service_grant.yml` → `grant_creation_cooldown: 60`
2. **Restore trust_requirements**: `deposit_skill` trust is 0.0 (test mode). Set back to 0.1.
   - File: `docker/config/service_grant.yml` → services.meeting_place.plans.free.trust_requirements.deposit_skill: 0.1
3. **Caddy rate limiting**: No rate limit currently. Add `rate_limit` directive to Caddyfile.

### MEDIUM Priority
4. **Backup strategy**: Set up cron for `pg_dump` (PG data) and volume snapshot
5. **Admin UI access**: `/admin` is publicly accessible (requires admin token but still exposed)
6. **Deposit content sanitization**: Malicious skill content (XSS etc.) could be deposited

### LOW Priority
7. **Docker log sanitization**: Agent IDs and partial tokens visible in logs
8. **Caddy admin API**: Disable or make read-only (currently localhost:2019 inside container)

## How to Update Server

```bash
ssh ubuntu@63.178.216.211
cd ~/KairosChain_2026/docker
git pull
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml up -d
```

## How to Check Status

```bash
# Health
curl https://meeting.genomicschain.io/health

# Place info
curl https://meeting.genomicschain.io/place/v1/info

# Logs
docker compose -f docker-compose.prod.yml logs -f meeting-place

# Admin token
docker exec kairos-meeting-place cat /app/.kairos/.admin_token
```

## E2E Verified Flows

1. Local Agent A → connect (HTTPS) → deposit skill → success
2. Local Agent B → connect → browse → acquire → success
3. MCP tools via admin token → meeting_place_status, service_grant_status → success

## Related Design Ideas (from L2)

- **Auto-recommend on connect**: session_20260322_193208_1deb4496
- **Trust-based cooldown**: cooldown = base * (1.0 - trust_score)
- **generate_instance_id fix**: derive from pubkey_hash instead of config hash

## Version History This Session

- v3.1.0: Docker deployment + Service Grant bugfixes (4 bugs)
- v3.1.1: HTTPS support for MMP tools + Caddy DNS fix
