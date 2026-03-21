# Service Grant SkillSet Guide

## Overview

Service Grant provides generic access control and usage tracking for any
KairosChain-based service. It manages "what is permitted" for authenticated
agents without managing identity (identity = RSA key pair via MMP).

## Key Concepts

- **pubkey_hash**: SHA-256 hash of agent's public key. This IS the identity.
- **Grant**: An entry per (pubkey_hash, service) with plan, status, usage.
- **Plan**: Quota configuration (free, pro, etc.) defined in YAML.
- **Dual-path enforcement**: Both `/mcp` (Path A) and `/place/*` (Path B) are gated.

## Architecture

```
Path A (/mcp):  Token -> pubkey_hash -> AccessGate -> AccessChecker
Path B (/place): Bearer -> peer_id -> PlaceMiddleware -> AccessChecker
```

## Configuration

Edit `config/service_grant.yml` to define services and plans:

```yaml
services:
  my_service:
    billing_model: per_action  # per_action | metered | subscription | free
    cycle: monthly             # monthly | weekly | daily
    write_actions: [create]
    action_map:
      my_tool: "create"
    plans:
      free:
        limits:
          create: 10
          read: -1  # unlimited
```

## Tools

- `service_grant_status`: View your grants and usage (all users)
- `service_grant_manage`: Admin operations — plan changes, suspend/unsuspend (owner only)
- `service_grant_migrate`: Database migrations (owner only)

## Access Flow

1. Agent authenticates (MMP Bearer or token)
2. pubkey_hash resolved from auth context
3. Grant auto-created on first access (free plan)
4. AccessChecker validates: suspension -> cooldown -> trust -> quota
5. If allowed, tool executes normally

## Anti-Sybil Measures

- IP rate limiting on new grant creation (5/hour per IP, PG-backed with in-memory fallback)
- Delayed activation cooldown (5 min, write-only)
- Trust score requirements (Phase 2)

## Ungated Actions

The `unregister` action is intentionally ungated. Agents should always be able
to leave a Meeting Place without quota restrictions. This is consistent with
KairosChain's fluid role philosophy — participation is voluntary, not coerced.

## IP Rate Limiting

IP rate limiting uses `X-Real-IP` header (set by nginx from `$remote_addr`).
`X-Forwarded-For` is NOT trusted because it is client-spoofable.

Deployment requirement: nginx (or equivalent reverse proxy) must be in front
of the application and set `X-Real-IP` to the true client address. For direct
Puma deployments without a proxy, `REMOTE_ADDR` is used as fallback.

## Anti-Collusion Threat Model (Phase 2)

### What Phase 2 CAN prevent

- **Pure cartel**: N agents mutually attesting with no external connections.
  PageRank floor = 0.0 without external attestation, so cartel members'
  attestations carry zero weight.
- **Bootstrap inflation**: New agents with 0.01 floor cannot bootstrap each
  other above meaningful trust thresholds.

### What Phase 2 CANNOT prevent

- **Compromised trusted agent**: If a legitimate high-trust agent attests for
  cartel members, those members gain real trust. Requires revocation + monitoring.
- **Slow drip cartel**: One attestation per day, below burst detection. Requires
  time-series anomaly detection (Phase 3+).
- **Single-connection bootstrap**: One legitimate external attestation enables
  non-zero bridge score for the entire connected cartel (1-hop transitivity).

### Explicit non-goal

Perfect Sybil resistance is not achievable without economic cost (proof-of-work,
payment, or reputation deposit). Phase 2's goal is to make cartel attacks
expensive enough that exploiting the free tier is not profitable.

### Trust Identity

Canonical trust subject URI: `agent://<pubkey_hash>`. This maps between
Service Grant identity (pubkey_hash) and Synoptis attestation identity
(subject_ref/attester_id). Legacy proofs with raw pubkey_hash continue to work.
