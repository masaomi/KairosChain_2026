---
name: agent
description: >
  Governed autonomous OODA loop for cognitive agents. Use when starting, stepping,
  monitoring, or stopping agent sessions with human checkpoints and safety gates.
---

# Agent — Cognitive OODA Loop

Manage autonomous agent sessions with observe-orient-decide-act-reflect cycles.

## Recommended Workflow

### Standard (Human-in-the-Loop)
1. `agent_start goal="..."` — create mandate, run OBSERVE
2. Review observation, then `agent_step` — run ORIENT → DECIDE → ACT
3. Review result, repeat `agent_step` or `agent_stop`

### Autonomous Mode
1. `agent_start goal="..." autonomous=true` — start with auto-cycling
2. Agent runs OODA cycles with 8 safety gates (mandate term, goal drift, budget, risk, etc.)
3. `agent_status` — check progress at any time
4. `agent_stop` — terminate when done or if paused

## Sub-Agents

### `/kairos-chain:agent-monitor`
Post-session review agent. Invokes `agent_status`, `autonomos_status`, and `chain_history`
to summarize session progress and flag anomalies. Read-only — cannot modify state.

## Available Tools

<!-- AUTO_TOOLS -->
