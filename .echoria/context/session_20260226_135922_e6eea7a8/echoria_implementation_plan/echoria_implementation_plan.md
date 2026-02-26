---
title: Echoria MVP Implementation Plan
description: Original 5-phase implementation plan for Echoria (Rails 8 + Next.js + Docker)
tags: [echoria, plan, mvp, architecture]
---

# Echoria MVP Implementation Plan

## Overview

**Echoria** is a narrative-driven AI app where users guide their "Echo" (AI persona) through an interactive story world alongside Tiara (cat spirit companion). Through story choices, the Echo's personality crystallizes, becoming a unique conversational AI partner.

**Architecture**: Rails 8 API + Next.js 16 frontend on EC2, with KairosChain core as Ruby library (PostgreSQL multi-tenant backend).

## Phases

- **Phase 0**: Project Scaffolding (Rails 8, Next.js, Docker) — DONE
- **Phase 1**: Auth + Echo + KairosChain PG Backend — DONE
- **Phase 2-3**: Story Engine + Services + Crystallization — DONE
- **Phase 4**: UI/UX (Mobile-First) — DONE
- **Phase 5**: Docker Deployment + Production — DONE

## Key Design Decisions

1. KairosChain as library, not MCP Server — Direct Ruby require in Rails
2. PostgreSQL multi-tenant via echo_id — Not filesystem-based
3. Claude API direct call — Not via MCP, for latency
4. Static Next.js export — Nginx serves static files
5. Single EC2 — No service sprawl
6. Story beacons + AI scenes — Fixed quality control + AI creativity
7. JWT auth — Stateless, mobile-friendly

## 5-Axis Affinity System

- `tiara_trust` (0–100)
- `logic_empathy_balance` (-50 to +50)
- `name_memory_stability` (0–100)
- `authority_resistance` (-50 to +50)
- `fragment_count` (0+)

## Repository Structure

```
Echoria/
├── echoria-api/          # Rails 8 API
├── echoria-web/          # Next.js 16 frontend
├── docker/               # Docker Compose + Nginx
└── story/                # Story content (beacons, world data)
```
