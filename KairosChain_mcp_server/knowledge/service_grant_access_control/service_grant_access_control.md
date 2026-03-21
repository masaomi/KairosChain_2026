---
description: Service Grant SkillSet — generic access control, usage tracking, and billing for KairosChain services
tags: [documentation, readme, service-grant, access-control, billing, payment, subscription]
readme_order: 4.9
readme_lang: en
---

# Service Grant SkillSet

Service Grant provides **generic, service-independent access control and billing** for any KairosChain-based service. It manages "what is permitted" for authenticated agents without managing identity (identity = RSA key pair via MMP).

## Key Concepts

- **pubkey_hash**: SHA-256 hash of agent's public key — this IS the identity
- **Grant**: Per-(pubkey_hash, service) entry with plan, status, and usage
- **Plan**: Quota/billing configuration (free, pro, etc.) defined in YAML
- **Dual-path enforcement**: Both `/mcp` (AccessGate) and `/place/*` (PlaceMiddleware) are gated

## Architecture

```
Path A (/mcp):   Token -> pubkey_hash -> AccessGate -> AccessChecker
Path B (/place): Bearer -> peer_id -> PlaceMiddleware -> AccessChecker

AccessChecker pipeline:
  suspension -> cooldown -> expiry -> trust -> quota
```

### Components

| Component | Responsibility |
|-----------|---------------|
| **GrantManager** | Grant lifecycle (create, upgrade, suspend, downgrade) |
| **AccessChecker** | Unified access decision pipeline |
| **UsageTracker** | Atomic quota consumption with cycle management |
| **PlanRegistry** | YAML config loader with validation |
| **PaymentVerifier** | Cryptographic payment attestation verification |
| **PgConnectionPool** | Thread-safe PostgreSQL with circuit breaker |
| **TrustScorerAdapter** | Synoptis trust score integration with caching |

## Billing Models

```yaml
billing_model: free          # No charges
billing_model: per_action    # Pay per API call
billing_model: metered       # Usage-based with cycle tracking
billing_model: subscription  # Time-based with auto-expiry
```

## Payment Flow (Proof-Centric)

```
Payment Agent (external) creates attestation proof
  -> PaymentVerifier verifies: signature, issuer, freshness, amount, nonce
  -> Atomic transaction: ensure_grant + upgrade_plan + record_payment
  -> Subscription expiry auto-managed (lazy downgrade on access check)
```

Payment verification uses Synoptis ProofEnvelope — the same cryptographic attestation infrastructure used for trust scoring.

## Anti-Sybil Measures

- IP rate limiting (5 new grants/hour per IP, PostgreSQL-backed)
- Delayed activation cooldown (5 min for write operations)
- Synoptis trust score requirements (configurable per action)
- Anti-collusion PageRank with external attestation weighting

## MCP Tools

| Tool | Access | Description |
|------|--------|-------------|
| `service_grant_status` | All users | View grants and usage |
| `service_grant_manage` | Owner only | Plan changes, suspend/unsuspend |
| `service_grant_migrate` | Owner only | Database schema migrations |
| `service_grant_pay` | All users | Submit payment attestation proofs |

## Configuration Example

```yaml
services:
  meeting_place:
    billing_model: per_action
    currency: USD
    cycle: monthly
    write_actions: [deposit_skill]
    action_map:
      meeting_deposit: deposit_skill
      meeting_browse: browse
    plans:
      free:
        limits:
          deposit_skill: 5
          browse: -1  # unlimited
        trust_requirements:
          deposit_skill: 0.1
      pro:
        subscription_price: "9.99"
        subscription_duration: 30  # days
        limits:
          deposit_skill: -1
          browse: -1
```

## Dependencies

- **Hard**: PostgreSQL (grants, usage, payments)
- **Hard**: Synoptis SkillSet (attestation verification, trust scoring)
- **Soft**: Hestia SkillSet (Meeting Place middleware integration)
