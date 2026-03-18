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

> **Scope (v0.1)**: Single-terminal, single-user experimental mode.
> Goal loading, cycle history, and session lookup operate on global state —
> not yet scoped to terminal or user session. Multi-terminal and multi-user
> isolation is planned for v0.2. Running concurrent Autonomos sessions from
> different terminals against the same `.kairos/` directory is not supported.

## Quick Start

### 1. Set a Project Goal

Goals are stored as **L2 context** (created via `context_save`) or **L1 knowledge**
(created via `knowledge_update`). Autonomos scans L2 sessions first (most recent first),
then falls back to L1:

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
naturally discarded when the work is done.

Autonomos scans all L2 sessions (most recent first) for the named context.
If not found, it falls back to L1 knowledge.

**L1 for reusable goals**: Use L1 for goal templates shared across sessions:

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
- **Multi-terminal (v0.2)**: planned — each terminal will have its own goal scope. Currently global.
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

## Continuous Mode (Mandate-Based Loop)

For multi-step tasks, use `autonomos_loop` to run multiple cycles with pre-authorized scope.

### 1. Create a Mandate

```
autonomos_loop(
  command: "create_mandate",
  goal_name: "project_goals",
  max_cycles: 5,
  checkpoint_every: 2,
  risk_budget: "low"
)
```

The mandate is the human's pre-authorization — it scopes what the loop can do.

### 2. Start the Loop

```
autonomos_loop(command: "start", mandate_id: "mnd_...")
```

### 3. Execute and Continue

After each proposal, execute via autoexec, then:

```
autonomos_loop(
  command: "cycle_complete",
  mandate_id: "mnd_...",
  execution_result: "Tests pass, 3 files changed"
)
```

The loop continues until: goal achieved, max_cycles reached, checkpoint due,
error threshold (2 consecutive), or loop detected (A→A / A→B→A pattern).

### 4. Checkpoints and Interrupts

At checkpoints, review progress and continue or stop:

```
autonomos_loop(command: "cycle_complete", mandate_id: "mnd_...", feedback: "Looks good")
autonomos_loop(command: "interrupt", mandate_id: "mnd_...")
```

### Safety Gates

- **Risk budget**: `low` or `medium` — proposals exceeding budget pause the loop
- **Goal hash**: verified each cycle — drift pauses with `paused_goal_drift`
- **Checkpoints**: mandatory human review every 1-3 cycles
- **Max cycles**: hard cap (1-10)

See `docs/autonomos_continuous_mode_design.md` for full design details.

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

## Known Limitations (v0.1)

- **Mandate concurrency**: Mandate state (JSON file) is not protected by locks.
  Concurrent tool calls on the same mandate can corrupt state (e.g., `cycles_completed`
  counter). Single-terminal usage prevents this in practice. v0.2 will add mandate locking.
- **Loop detection**: Uses number-normalized string comparison on gap descriptions
  (digits replaced with `N` to prevent interpolated counts from defeating detection).
  LLM synonym rewording can still bypass detection. Compensated by max_cycles,
  error_threshold, and checkpoints.
- **Reflector evaluation**: Regex-based heuristic (`/fail|error/` → failed). May
  misclassify ambiguous results. Human feedback in the next cycle corrects this.

## Related L1 Knowledge

The following L1 knowledge resources are available and complement Autonomos workflows.
Use `knowledge_get(name: "...")` to load them when relevant.

| Name | When to consider |
|------|-----------------|
| `review_discipline` | Before reviewing implementation results. Contains checklists for LLM-common cognitive biases (caller-side bias, fix-what-was-flagged bias, mock fidelity bias). Especially valuable during `autonomos_reflect` and multi-cycle reviews. |
| `multi_agent_design_workflow` | When `complexity_hint` is `high` or the proposal involves architectural decisions. Provides structured multi-agent deliberation workflow for design and review. |
| `persona_definitions` | When running `sc_review` with persona assembly. Defines default personas (kairos, pragmatic, skeptic, architect) and assembly protocol. Referenced by `complexity_hint` recommendations above. |

### Continuous Mode Reminder

For multi-step tasks, use `autonomos_loop` instead of repeating single `autonomos_cycle` calls.
The loop provides mandate-based pre-authorization, automatic checkpoint/risk gates, and loop detection.
See the "Continuous Mode" section above for details.
