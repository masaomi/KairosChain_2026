# Review Round 2: Meeting Place Docker v3.0.0

- **Reviewer**: Claude Agent Team
- **Model**: claude-opus-4-6 (1M context)
- **Date**: 2026-03-22
- **Mode**: auto

## Verdict: CONDITIONAL APPROVE

Condition: Fix the Caddy healthcheck exec-form bug (N1 below). All other items pass.

## Fix Verification

| Fix | Status | Notes |
|-----|--------|-------|
| F1 | PASS | `ec2-setup.sh:81` now uses `docker exec kairos-meeting-place curl -sf http://localhost:8080/health` -- correctly checks inside the container, bypassing the host network limitation. |
| F2 | PASS | `ec2-setup.sh:87-88` prints only the retrieval command (`docker exec ... cat ...`), not the token value itself. Token is never written to stdout. |
| F3 | PASS | `ec2-setup.sh:23-32` tries `dnf install docker-compose-plugin` first (OS package manager, reproducible), falls back to pinned `v2.32.4` from GitHub. Both paths work on Amazon Linux 2023. |
| F4 | PASS | `Caddyfile:4-9` adds HSTS (`max-age=31536000; includeSubDomains`), `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and `Referrer-Policy: strict-origin-when-cross-origin`. All four headers from the original finding are present. |
| F5 | PASS | `ec2-setup.sh:44-45` has a comment block with the `GH_TOKEN` alternative clone URL. Clear and sufficient. |
| F6 | PASS | `entrypoint.sh:23-29` iterates over all five skillsets (`mmp hestia synoptis multiuser service_grant`) and copies any missing ones from the build-time template. Logic is correct: checks both that the volume dir is missing AND the template dir exists before copying. |
| F7 | PASS | `ec2-setup.sh:57` uses `openssl rand -hex 32`, producing a fixed 64-character hex string. No more variable-length output from base64 stripping. |
| F8 | PASS | `docker-compose.prod.yml:74-76` defines `frontend` and `backend` networks. Caddy is on `frontend` only (line 13), meeting-place is on both `frontend` and `backend` (lines 43-44), postgres is on `backend` only (line 66). Caddy can reach meeting-place via `frontend`, meeting-place can reach postgres via `backend`, Caddy cannot reach postgres. Correct isolation. |
| F9 | PARTIAL | Caddy healthcheck is present (`docker-compose.prod.yml:18`) using the admin API on `localhost:2019`. However, the exec form has a bug -- see N1 below. |

## New Findings

### [MEDIUM] N1: Caddy healthcheck uses CMD exec form with shell operators as arguments

- **File**: `docker/docker-compose.prod.yml:18`
- **Description**: The healthcheck is defined as:
  ```yaml
  test: ["CMD", "wget", "-qO-", "http://localhost:2019/config/", "||", "true"]
  ```
  With the `CMD` (exec) form, Docker runs the command directly without a shell. The `"||"` and `"true"` strings are passed as extra arguments to `wget`, not interpreted as shell operators. This means: (a) `wget` receives unexpected arguments which may cause it to behave unpredictably (busybox wget may ignore them or error), and (b) the `|| true` fallback -- which would make the check always pass -- never activates.

  In practice, Caddy's admin API on `localhost:2019` is enabled by default, so the `wget` to `/config/` should succeed when Caddy is healthy and the extra args may be silently ignored by busybox wget. But this is fragile and semantically wrong.
- **Recommendation**: Either switch to `CMD-SHELL` for shell interpretation, or remove the `|| true` since a healthcheck should genuinely fail when the service is unhealthy:
  ```yaml
  # Option A: Clean exec form (preferred -- healthcheck should reflect real status)
  test: ["CMD", "wget", "-qO-", "http://localhost:2019/config/"]

  # Option B: Shell form if || true is truly desired
  test: ["CMD-SHELL", "wget -qO- http://localhost:2019/config/ || true"]
  ```
  Option A is recommended. A healthcheck that always passes via `|| true` defeats its purpose.

### [LOW] N2: Caddy admin API exposure within frontend network

- **File**: `docker/docker-compose.prod.yml:18`
- **Description**: Caddy's admin API (`localhost:2019`) is enabled by default and used for the healthcheck. While it only listens on `localhost` inside the container (not exposed to the host or other containers), it is worth noting that the admin API allows runtime configuration changes. If the Caddy container were compromised, the admin API could be used to modify routing rules.
- **Recommendation**: No action needed for current threat model. If hardening is desired later, the admin API can be made read-only or disabled (with a different healthcheck approach).

## Summary

All nine Round 1 fixes are correctly implemented. The network isolation (F8) is properly designed with meeting-place bridging both networks. The volume upgrade backfill loop (F6) correctly handles all five skillsets. The `dnf install` primary path (F3) is appropriate for Amazon Linux 2023. One new MEDIUM finding: the Caddy healthcheck mixes exec-form `CMD` with shell operators (`|| true`), which are passed as literal arguments to `wget` rather than being interpreted by a shell. This should be fixed by removing the `|| true` or switching to `CMD-SHELL`. The fix is a one-line change and does not block deployment, but should be addressed before production to ensure accurate health reporting.
