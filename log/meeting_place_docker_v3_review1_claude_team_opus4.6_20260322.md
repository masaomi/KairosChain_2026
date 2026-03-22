# Review: Meeting Place Docker v3.0.0

- **Reviewer**: Claude Agent Team
- **Model**: claude-opus-4-6
- **Date**: 2026-03-22
- **Mode**: auto

## Verdict: CONDITIONAL APPROVE

Condition: Fix the HIGH finding (ec2-setup.sh health check port mismatch). All other findings are MEDIUM/LOW and can be addressed in a follow-up.

## Findings

### [HIGH] EC2 setup health check targets wrong port

- **File**: `/Users/masa/forback/github/KairosChain_2026/docker/scripts/ec2-setup.sh:76`
- **Description**: The verification step runs `curl -sf http://localhost:8080/health`, but in the production compose (`docker-compose.prod.yml`), port 8080 is only `expose`d internally (not mapped to host). Caddy maps 80/443 to host. This health check will always fail on EC2 when using the prod compose, making the setup script report failure even when everything is working correctly.
- **Recommendation**: Change to `curl -sf http://localhost:80/health` or `curl -sf https://localhost:443/health --insecure` (Caddy may not have a cert yet if DNS is not pointed). Safest option:
  ```bash
  # Check via docker network directly
  sg docker -c "docker exec kairos-meeting-place curl -sf http://localhost:8080/health"
  ```

### [MEDIUM] Existing volume upgrade path lacks service_grant skillset

- **File**: `/Users/masa/forback/github/KairosChain_2026/docker/scripts/entrypoint.sh:17`
- **Description**: The volume seeding check (`if [ ! -f "$KAIROS_DATA_DIR/.kairos_meta.yml" ]`) only seeds on first start. If upgrading from v2.8.0 with an existing volume, the `service_grant` skillset directory will not exist in the volume. The `apply_config` and PG injection for service_grant will write to a nonexistent directory path, and the skillset won't be registered. The deployment plan acknowledges this risk and suggests `docker compose down -v`, but there is no warning in entrypoint.sh itself.
- **Recommendation**: Add a check in entrypoint.sh after the volume seeding block:
  ```bash
  # Check for missing skillsets (upgrade scenario)
  if [ -f "$KAIROS_DATA_DIR/.kairos_meta.yml" ] && [ ! -d "$KAIROS_DATA_DIR/skillsets/service_grant" ]; then
    echo "[entrypoint] WARNING: service_grant skillset missing from existing volume."
    echo "[entrypoint] Run: docker compose down -v && docker compose up -d (destroys data)"
  fi
  ```
  Or better: install missing skillsets from the template into the live volume.

### [MEDIUM] Admin token printed to stdout in ec2-setup.sh

- **File**: `/Users/masa/forback/github/KairosChain_2026/docker/scripts/ec2-setup.sh:81`
- **Description**: The admin token is printed to the terminal via `docker exec ... cat .admin_token`. If the SSH session is logged (e.g., `script`, cloud audit logs, or terminal scrollback), the token is exposed. Additionally, the `echo ""` after the cat command will succeed even if the cat fails, making it look like the token was displayed.
- **Recommendation**: Consider writing the token to a local file with `chmod 600` instead of printing to stdout, or at minimum add a clear security warning. Also gate the echo on cat's exit code:
  ```bash
  if sg docker -c "docker exec kairos-meeting-place cat /app/.kairos/.admin_token"; then
    echo ""
    echo "Admin token shown above. Store it securely and clear terminal history."
  else
    echo "WARNING: Could not retrieve admin token."
  fi
  ```

### [MEDIUM] Caddy volumes missing caddy-config in production compose

- **File**: `/Users/masa/forback/github/KairosChain_2026/docker/docker-compose.prod.yml:10`
- **Description**: The `caddy-config` volume is mounted and declared, which is correct. However, the Caddyfile is minimal and does not configure any security headers, rate limiting, or request size limits. For a production MCP server, this leaves the endpoint open to abuse.
- **Recommendation**: Add basic hardening to the Caddyfile:
  ```
  meeting.kairoschain.io {
      reverse_proxy meeting-place:8080

      header {
          Strict-Transport-Security "max-age=31536000; includeSubDomains"
          X-Content-Type-Options "nosniff"
          X-Frame-Options "DENY"
      }
  }
  ```

### [MEDIUM] PG password entropy reduced by character stripping

- **File**: `/Users/masa/forback/github/KairosChain_2026/docker/scripts/ec2-setup.sh:52`
- **Description**: `openssl rand -base64 32 | tr -d '/+='` generates 32 bytes of randomness (256 bits) but then strips base64 special characters, reducing the output length unpredictably (typically ~38 chars down to ~33). The entropy is still adequate, but the variable length is surprising.
- **Recommendation**: Use `openssl rand -hex 32` instead for a fixed 64-character hex string with no special characters, or use `tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48` for a fixed-length alphanumeric password.

### [LOW] Postgres container has no network isolation from Caddy

- **File**: `/Users/masa/forback/github/KairosChain_2026/docker/docker-compose.prod.yml`
- **Description**: All three services (caddy, meeting-place, postgres) share the default network. Caddy can reach postgres directly on port 5432. In a defense-in-depth model, the database should only be reachable from the application container.
- **Recommendation**: Define two networks (`frontend` for caddy + meeting-place, `backend` for meeting-place + postgres) so that Caddy cannot reach Postgres:
  ```yaml
  networks:
    frontend:
    backend:
  ```

### [LOW] "Grant validation skipped (non-fatal)" log message assessment

- **File**: Not in the reviewed files (runtime behavior)
- **Description**: Per the review focus question: this log message is acceptable during startup when PG tables have not yet been created or when the service_grant skillset is initializing. However, if it persists after steady-state operation, it indicates a configuration problem. The `pg_unavailable_policy: deny_all` in `service_grant.yml` is the correct production setting -- it means grant checks will deny when PG is down, rather than silently skipping.
- **Recommendation**: No code change needed. The message is acceptable as a startup transient. Consider adding a startup-complete log line like `[service_grant] PG connection established, grant validation active` to clearly mark the transition.

### [LOW] Caddyfile domain is hardcoded

- **File**: `/Users/masa/forback/github/KairosChain_2026/docker/Caddyfile:1`
- **Description**: The domain `meeting.kairoschain.io` is hardcoded in the Caddyfile. If the domain changes or if someone wants to test with a different domain, they must edit this file.
- **Recommendation**: For now this is fine since it is a single-deployment setup. If multi-environment support is needed later, consider using Caddy's environment variable substitution or generating the Caddyfile from a template.

### [LOW] Docker Compose plugin install lacks checksum verification

- **File**: `/Users/masa/forback/github/KairosChain_2026/docker/scripts/ec2-setup.sh:27`
- **Description**: The Docker Compose binary is downloaded from GitHub and made executable without verifying its SHA256 checksum. A MITM or compromised CDN could inject a malicious binary.
- **Recommendation**: Add checksum verification after download, or install via the system package manager if available (`sudo dnf install docker-compose-plugin`).

### [LOW] ec2-setup.sh git clone uses HTTPS without auth

- **File**: `/Users/masa/forback/github/KairosChain_2026/docker/scripts/ec2-setup.sh:41`
- **Description**: The script clones from `https://github.com/masaomi/KairosChain_2026.git`. The CLAUDE.md states this is a private repo that will become public post grant submission. If still private at deployment time, this clone will fail without credentials.
- **Recommendation**: Add a note or check:
  ```bash
  # NOTE: If repo is private, use SSH or set GH_TOKEN:
  #   git clone https://${GH_TOKEN}@github.com/masaomi/KairosChain_2026.git
  ```

## Summary

The v2.8.0 to v3.0.0 incremental changes are well-structured. The service_grant PG injection in entrypoint.sh correctly follows the established multiuser pattern, and the password-from-ENV-only approach is sound. The production compose correctly uses `expose` instead of `ports` for the application container. One HIGH finding: the EC2 setup script's health check targets port 8080 which is not host-mapped in the prod compose, guaranteeing a false failure report. Five MEDIUM findings cover the volume upgrade path, admin token exposure, Caddyfile hardening, and password generation. The remaining LOW findings are defense-in-depth improvements. Overall, this is a solid incremental deployment configuration that needs one fix before production use.
