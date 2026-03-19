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

- IP rate limiting on new grant creation (5/hour per IP)
- Delayed activation cooldown (5 min, write-only)
- Trust score requirements (Phase 2)
