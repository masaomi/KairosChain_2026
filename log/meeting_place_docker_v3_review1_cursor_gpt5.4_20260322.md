# Review: Meeting Place Docker v3.0.0

- **Reviewer**: Cursor GPT-5.4
- **Model**: gpt-5.4-high
- **Date**: 2026-03-22
- **Mode**: manual

## Verdict: CONDITIONAL APPROVE

## Findings

### HIGH Admin token is printed to setup script stdout
- **File**: `docker/scripts/ec2-setup.sh:81`
- **Description**: The script executes `docker exec kairos-meeting-place cat /app/.kairos/.admin_token`, which prints the live admin token directly to stdout. On a real EC2 deployment this can leak into terminal scrollback, shell recording, session logs, or remote support transcripts. Since this token is a privileged bootstrap secret, emitting it by default is too risky for production setup automation.
- **Recommendation**: Do not print the token value automatically. Instead print only the file path and an explicit retrieval command, or require an interactive confirmation step before revealing it.

### HIGH Production verification path is incompatible with the production compose network model
- **File**: `docker/scripts/ec2-setup.sh:76`
- **Description**: The verification step curls `http://localhost:8080/health`, but `docker/docker-compose.prod.yml` intentionally does not publish port 8080 on the host and only uses `expose: ["8080"]` behind Caddy. On a correctly configured production deployment, this host-level health check will fail even when the stack is healthy, making the setup script report failure incorrectly.
- **Recommendation**: Verify through the actual production ingress path instead. For pre-DNS local verification, use `sg docker -c "docker exec kairos-caddy wget -qO- http://meeting-place:8080/health"` or `docker exec kairos-meeting-place curl -sf http://localhost:8080/health`. For end-to-end validation after DNS, check `https://meeting.kairoschain.io/health`.

### MEDIUM Docker Compose plugin install is unpinned and unchecked
- **File**: `docker/scripts/ec2-setup.sh:25`
- **Description**: The script fetches the latest Compose release dynamically from GitHub and installs it without pinning a version or verifying a checksum/signature. That makes production setup non-reproducible and introduces an avoidable supply-chain risk.
- **Recommendation**: Pin a known-good Compose version and verify its checksum, or install Docker Compose from the OS package manager / official Docker repository instead of downloading `latest` at runtime.

### LOW Existing volumes will not automatically gain the new `service_grant` SkillSet
- **File**: `docker/scripts/entrypoint.sh:17`
- **Description**: Volume seeding is guarded only by the presence of `.kairos_meta.yml`. If an existing `kairos-data` volume created under v2.8.0 is reused, the new `service_grant` files from `/app/.kairos-template` will not be copied in. The deployment plan already notes this risk, but the runtime path does not detect or remediate it.
- **Recommendation**: Either document this as a mandatory migration step for upgrades, or add a targeted runtime check that backfills missing SkillSet directories when upgrading an existing volume.

## Summary

The core Docker changes are directionally sound: `service_grant` is installed, the entrypoint PG injection matches the existing `multiuser` pattern, and the production compose layout of `expose: 8080` behind Caddy is correct. The `Grant validation skipped` log is acceptable as a non-fatal initialization artifact as long as runtime startup reaches a healthy PG-backed state, but the EC2 setup script still has two production-facing issues: it leaks the admin token and it verifies the wrong endpoint for the chosen network topology.
