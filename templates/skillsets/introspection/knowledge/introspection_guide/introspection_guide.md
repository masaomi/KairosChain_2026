---
title: Introspection Guide
description: Usage guide for the introspection SkillSet — self-inspection, health scoring, and safety visibility
version: "0.1.0"
tags:
  - introspection
  - health
  - safety
  - blockchain
  - maintenance
---

# Introspection Guide

## Overview

The introspection SkillSet provides self-inspection capabilities for KairosChain.
It examines knowledge health, blockchain integrity, and safety mechanisms to produce
actionable reports and recommendations.

## Tools

### introspection_check

Full self-inspection combining all domains. Returns a consolidated report with
recommendations.

```
introspection_check()                           # All domains, markdown format
introspection_check(format: "json")             # JSON output
introspection_check(domains: ["health"])        # Health only
introspection_check(domains: ["blockchain"])    # Blockchain only
```

### introspection_health

Focused L1 knowledge health scoring.

```
introspection_health()                          # All entries
introspection_health(name: "my_knowledge")      # Single entry
introspection_health(below_threshold: 0.5)      # Only unhealthy entries
introspection_health(sort_by: "name")           # Sort alphabetically
```

### introspection_safety

Safety mechanism visibility across all layers.

```
introspection_safety()    # Returns 4-layer safety report
```

## Health Scoring

Health scores range from 0.0 (unhealthy) to 1.0 (healthy).

When Synoptis TrustScorer is available:
- **Trust score** (70% weight): Based on attestation count and quality
- **Staleness score** (30% weight): Based on file modification time

When TrustScorer is not available:
- **Staleness score only** (100%): Linear decay over configurable threshold

### Staleness Threshold

Default: 180 days. Configure in `config/introspection.yml`:

```yaml
introspection:
  health:
    staleness_days: 90  # More aggressive freshness requirement
```

## Safety Layers

The safety report covers four layers:

1. **L0 Approval Workflow**: Whether Kairos DSL approval_workflow skill is loaded
2. **Runtime RBAC**: Registered Safety policies (can_modify_l0, etc.)
3. **Agent Safety Gates**: Autonomous mode limits from agent.yml
4. **Blockchain Recording**: Chain integrity and block count

## Recommendations

The full check generates prioritized recommendations:

- **CRITICAL**: Blockchain integrity failure
- **HIGH**: Missing L0 approval workflow
- **MEDIUM**: Low health scores on individual knowledge entries
