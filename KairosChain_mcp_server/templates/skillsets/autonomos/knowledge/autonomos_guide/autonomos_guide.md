---
name: autonomos_guide
description: >
  Usage guide for the Autonomos SkillSet — autonomous project execution via OODA cycles.
  Covers tool usage, goal convention, cycle flow, and integration with autoexec.
version: "0.1"
layer: L1
tags: [autonomos, agent, autonomous, ooda, guide, workflow]
---

# Autonomos SkillSet Guide

## Overview

Autonomos enables autonomous project execution through OODA cycles:
**Observe** project state, **Orient** against goals, **Decide** next task,
**Act** via autoexec, **Reflect** on results.

Default mode is single-cycle: one cycle, one human review, maximum agency with maximum safety.

## Quick Start

### 1. Set a Project Goal

Goals are stored as **L2 context** (session-scoped, per-terminal):

```
context_save(name: "project_goals", content: <<~MD)
---
type: autonomos_goal
status: active
---
# Project Goal: Feature X

## Acceptance Criteria
- [ ] Implement core logic
- [ ] Write tests
- [ ] Update documentation

## Current Sprint
- Build the data model
- Add API endpoints
MD
```

L2 goals are ephemeral — they belong to your current work session and are
naturally discarded when the work is done. Multiple terminals can have
different goals without conflict.

**L1 fallback**: If no L2 goal is found, Autonomos falls back to L1 knowledge.
Use L1 for reusable goal templates shared across sessions:

```
knowledge_update(name: "goal_template_release", content: "...")
```

### 2. Run a Cycle

```
autonomos_cycle()
```

Returns: observation (git, L2, chain state) + orientation (gap analysis) + proposal (autoexec task JSON).

### 3. Review and Execute

Review the proposal. If approved:

```
autoexec_plan(task_json: '<proposal from cycle>')
autoexec_run(task_id: "...", mode: "dry_run", approved_hash: "...")
autoexec_run(task_id: "...", mode: "execute", approved_hash: "...")
```

### 4. Reflect

After execution completes:

```
autonomos_reflect(cycle_id: "cyc_...", execution_result: "Tests pass, feature works")
```

Or with feedback:

```
autonomos_reflect(
  cycle_id: "cyc_...",
  execution_result: "Partial — tests pass but edge case missing",
  feedback: "Also consider the multi-user scenario"
)
```

### 5. Next Cycle

Start the next cycle with context from reflection:

```
autonomos_cycle(feedback: "Focus on edge cases next")
```

## Goal Convention

Goals are L2 contexts by default (L1 fallback for templates).

- **Name**: `project_goals` (default) or any name passed to `goal_name` parameter
- **Create**: `context_save(name: "my_goal", content: "...")` for session-scoped goals
- **Frontmatter**: include `type: autonomos_goal` for discoverability
- **Checklist**: use `- [ ]` items — Autonomos reads these as task gaps. Prose-only goals will receive a clarification gap asking you to add checklist items.
- **Update**: use `context_save` to modify goals between cycles
- **Multi-terminal**: each terminal can have its own goal name (e.g. `goals_auth`, `goals_api`)
- **L1 templates**: use `knowledge_update` for reusable goal patterns shared across sessions

## Cycle States

| State | Meaning | Next Action |
|-------|---------|-------------|
| decided | Proposal ready | Human reviews → autoexec |
| no_action | No gaps found | Refine goals or celebrate |
| reflected | Reflection done | Start next cycle or stop |

Note: Approval, rejection, and execution happen outside cycle state (in the LLM/human loop).
Autonomos tracks the cognitive phases only: decide → reflect.

## Chain Recording

Each cycle records two chain events (two-phase commit):
1. **Intent** (`autonomos_intent`): recorded at decide — what we plan to do
2. **Outcome** (`autonomos_outcome`): recorded at reflect — what happened

This makes each cycle a Kairotic moment (constitutive, not evidential).

## Safety

- Single-cycle default: human reviews every proposal
- PID-based lock: prevents concurrent cycles
- Inherited autoexec safety: risk classification, L0 deny-list, hash-locked plans
- Goal hash: verified each cycle — if goal changes after mandate creation, loop pauses with `paused_goal_drift`
- No L0 modification: capability gaps are flagged, not acted on
- Risk budget: maps gap priority to step risk (high priority = high risk). This is a priority-based filter, not full action-semantic risk assessment. High-priority gaps always pause in low/medium budgets.

## Integration with autoexec

Autonomos generates proposals. autoexec validates, plans, and executes.

```
Autonomos (what to do) → autoexec (how to do it) → Human (approval) → Execution
```

Autonomos never calls autoexec internally — the human mediates.

## Human-in-the-Loop

The human participates at three points:
1. **Goal-setting**: define what success looks like (context_save for session goals, knowledge_update for templates)
2. **Proposal review**: approve/modify/reject the cycle's decision
3. **Feedback injection**: provide perspective during reflect or next cycle

This follows Proposition 9: the human is on the boundary, not excluded.

## Complexity-Driven Deliberation

Each proposal includes a `complexity_hint` with a level (`low`, `medium`, `high`)
and signals explaining why.

| Level | Signals | Recommended Action |
|-------|---------|-------------------|
| low | (none) | Execute directly via autoexec |
| medium | 1 signal (e.g. `high_risk` or `design_scope`) | Use your judgment — consider a quick review |
| high | 2+ signals (e.g. `high_risk` + `many_gaps`) | Run `sc_review(persona_assembly)` on the proposal before executing |

Complexity signals:
- `high_risk` — the gap produces high-risk steps
- `many_gaps` — more than 5 gaps remain (direction matters)
- `design_scope` — gap description involves architecture, design, refactoring, migration, integration, or security

This is guidance, not enforcement. The LLM decides whether to escalate.
When in doubt, a 30-second persona assembly review is cheaper than a bad decision.
