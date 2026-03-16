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

Goals are stored as L1 knowledge with a naming convention:

```
knowledge_update(name: "project_goals", content: <<~MD)
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

Goals use standard L1 knowledge. No special tool needed.

- **Name**: `project_goals` (default) or any name passed to `goal_name` parameter
- **Frontmatter**: include `type: autonomos_goal` for discoverability
- **Checklist**: use `- [ ]` items — Autonomos reads these as task gaps
- **Update**: use `knowledge_update` directly to modify goals between cycles

## Cycle States

| State | Meaning | Next Action |
|-------|---------|-------------|
| decided | Proposal ready | Human reviews → autoexec |
| no_action | No gaps found | Refine goals or celebrate |
| approved | Human approved | Run autoexec |
| rejected | Human rejected | Start new cycle |
| executed | Autoexec completed | Call autonomos_reflect |
| reflected | Reflection done | Start next cycle or stop |

## Chain Recording

Each cycle records two chain events (two-phase commit):
1. **Intent** (`autonomos_intent`): recorded at decide — what we plan to do
2. **Outcome** (`autonomos_outcome`): recorded at reflect — what happened

This makes each cycle a Kairotic moment (constitutive, not evidential).

## Safety

- Single-cycle default: human reviews every proposal
- PID-based lock: prevents concurrent cycles
- Inherited autoexec safety: risk classification, L0 deny-list, hash-locked plans
- Goal hash: immutability check during cycle
- No L0 modification: capability gaps are flagged, not acted on

## Integration with autoexec

Autonomos generates proposals. autoexec validates, plans, and executes.

```
Autonomos (what to do) → autoexec (how to do it) → Human (approval) → Execution
```

Autonomos never calls autoexec internally — the human mediates.

## Human-in-the-Loop

The human participates at three points:
1. **Goal-setting**: define what success looks like (knowledge_update)
2. **Proposal review**: approve/modify/reject the cycle's decision
3. **Feedback injection**: provide perspective during reflect or next cycle

This follows Proposition 9: the human is on the boundary, not excluded.
