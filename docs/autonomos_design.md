# Autonomos SkillSet — Design Document (Revised after 4-persona review)

## Decision: SkillSet (not Core)

All requirements achievable via SkillSet APIs (BaseTool, KnowledgeProvider, ContextManager, Chain).

## Overview

Autonomos implements an OODA-style autonomous agent loop as a KairosChain SkillSet.
Each cycle: Observe → Orient → Decide (returned to human) → Act (via autoexec) → Reflect.
Default is single-cycle mode: one cycle, one human review, maximum agency with maximum safety.

## Review History

Initial design reviewed by 4 personas (kairos, pragmatic, skeptic, architect).
All recommended REVISE. Key changes from v1:
- Removed `phase` parameter (over-engineering, phantom modules)
- Removed `autonomos_goal` tool (redundant with knowledge_update)
- Removed continuous mode from initial v1 (self-approval gap); re-introduced as mandate-based loop in v0.1 experimental (see `autonomos_continuous_mode_design.md`)
- Collapsed 5 lib modules to 2 (observer/orienter were data formatters)
- Added two-phase chain recording (intent + outcome)
- Added PID-based cycle lock (concurrency safety)
- Defined state machine transitions explicitly
- Specified git access method (Open3, no shell interpolation)

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                  Autonomos SkillSet                   │
│                                                       │
│  Tools:                                               │
│    autonomos_cycle   — observe+orient+decide in one   │
│    autonomos_reflect — post-execution reflection      │
│    autonomos_status  — cycle history & state           │
│                                                       │
│  Lib:                                                 │
│    autonomos/cycle_store.rb  — L2+chain state adapter │
│    autonomos/reflector.rb    — reflect logic           │
│                                                       │
│  Knowledge:                                           │
│    autonomos_guide  — usage guide + goal convention    │
│                                                       │
│  Depends on: autoexec (required, hard dependency)     │
└──────────────────────────────────────────────────────┘
```

## Tool Design

### autonomos_cycle

Runs one complete observe → orient → decide pass. Returns a proposal for human review.

**Parameters:**
- `goal_name`: string (L2 context name with L1 fallback, default: "project_goals")
- `feedback`: string (optional, human feedback/new perspective from previous cycle)
- `cycle_id`: string (optional, resume an interrupted cycle)

**Output:** Structured JSON containing:
- `cycle_id`: unique cycle identifier
- `observation`: current project state snapshot
- `orientation`: gap analysis against goals
- `proposal`: autoexec-compatible task JSON + design intent
- `suggested_next`: what to do after this cycle
- `goal_hash`: SHA-256 of goal content at read time (structural immutability check)

**Flow:**
```
1. Acquire cycle lock (PID-based, same pattern as autoexec)
2. Observe: git state (Open3), L2 context, chain history, previous cycle
3. Orient: load L1 goal, compare, identify gaps, prioritize
4. Record INTENT on chain (two-phase commit, phase 1)
5. Decide: select top gap, generate autoexec task JSON with design intent
6. Save cycle state to CycleStore (phase: "decided")
7. Release lock
8. Return proposal to human
```

### autonomos_reflect

Post-execution reflection. Called after autoexec completes (or after human decides to skip act).

**Parameters:**
- `cycle_id`: string (required, links to the cycle from autonomos_cycle)
- `execution_result`: string (optional, summary of what autoexec did)
- `feedback`: string (optional, human feedback on execution results)
- `skip_reason`: string (optional, if act was skipped — why)

**Output:** Structured JSON containing:
- `evaluation`: success | partial | failed | skipped
- `learnings`: what was learned this cycle
- `l2_saved`: context name where learnings were saved
- `l1_promotion_candidate`: if a pattern merits L1 promotion (optional)
- `suggested_next`: recommended next cycle direction
- `chain_ref`: outcome block hash (two-phase commit, phase 2)

**Flow:**
```
1. Load cycle state from CycleStore
2. Verify cycle_id exists and is in "decided" state
3. Evaluate: compare execution_result against decide intent
4. Save learnings to L2 context (context_save)
5. If pattern confirmed across ≥3 cycles, propose L1 promotion
6. Record OUTCOME on chain (two-phase commit, phase 2)
7. Update cycle state to "reflected"
8. Return evaluation + learnings + suggested_next
```

### autonomos_status

View cycle history and current state.

**Parameters:**
- `command`: `"current"` | `"history"` | `"summary"`
- `cycle_id`: string (optional, for specific cycle details)
- `limit`: integer (optional, for history, default 10)

## State Machine

```
             ┌──────────┐
             │  idle     │
             └─────┬────┘
                   │ autonomos_cycle()
                   ▼
             ┌──────────┐
             │ observing │
             └─────┬────┘
                   │
                   ▼
             ┌──────────┐
             │ orienting │
             └─────┬────┘
                   │
              ┌────┴────┐
              │         │
              ▼         ▼
        ┌──────────┐ ┌──────────┐
        │ decided  │ │ no_action │ (no gaps found → cycle complete)
        └─────┬────┘ └──────────┘
              │
              │ Human reviews proposal
              │
         ┌────┴──────────┐
         │               │
         ▼               ▼
   ┌──────────┐    ┌──────────┐
   │ approved │    │ rejected │ (human rejects → cycle ends)
   └─────┬────┘    └──────────┘
         │
         │ Human calls autoexec_plan + autoexec_run
         │
         ▼
   ┌──────────┐
   │ executed  │ (autoexec completed)
   └─────┬────┘
         │
         │ autonomos_reflect()
         │
    ┌────┴────────┐
    │             │
    ▼             ▼
┌──────────┐ ┌────────────┐
│ reflected│ │ reflect_   │ (reflect with partial/failed)
│ (success)│ │ (partial)  │
└─────┬────┘ └─────┬──────┘
      │            │
      ▼            ▼
┌──────────────────────┐
│ cycle_complete       │
│ suggested_next shown │
│ → human decides to   │
│   start next cycle   │
│   or stop            │
└──────────────────────┘
```

### Transition conditions:
| From | To | Condition |
|------|----|-----------|
| idle | observing | autonomos_cycle() called |
| observing | orienting | observation complete |
| orienting | decided | gaps found, proposal generated |
| orienting | no_action | no gaps found (goal achieved or no actionable gaps) |
| decided | approved | human approves (external) |
| decided | rejected | human rejects (external) |
| approved | executed | autoexec completes (external) |
| executed | reflected | autonomos_reflect() called |
| reflected | cycle_complete | always |

## Observe Phase (inside autonomos_cycle)

Gathers current state:
1. **Git state**: branch, status, recent commits via `Open3.capture2("git", "status", "--short")` — no shell interpolation, explicit args only. If git unavailable, returns `git_available: false` and proceeds with chain-only observation.
2. **L2 context**: load latest session context and previous cycle's reflect output via ContextManager
3. **Chain history**: recent 10 chain events via Chain API
4. **Previous cycle**: CycleStore.load_latest — observation/orientation/decision from last cycle

Output: structured hash merged into cycle state.

## Orient Phase (inside autonomos_cycle)

Compares observation against goals:
1. Load goal from L2 context (newest session first), falling back to L1: `KnowledgeProvider.get(goal_name)` — record `goal_hash = SHA256(content)`
2. Gap identification — returned as structured list for LLM to reason over:
   - `task_gaps`: concrete tasks needed (→ autoexec)
   - `capability_gaps`: system capability missing (→ potential skills_evolve, flagged only)
3. Blockers: what prevents progress
4. Priority ranking hint based on goal structure

The tool provides **structured data**; the LLM provides **reasoning**. Orient does not pretend to be a reasoning engine.

## Decide Phase (inside autonomos_cycle)

The tool:
1. Packages observation + orientation into a structured prompt context
2. Generates an autoexec-compatible task JSON **template** (task_id, meta, steps skeleton)
3. States design intent extracted from goal + gap analysis

The LLM is expected to refine the template. The tool provides structure, not intelligence.

## Goal Convention (replaces autonomos_goal tool)

Goals are stored as standard L1 knowledge with naming convention:

```
knowledge_update(name: "autonomos_goal_<project>", content: <<~MD)
---
type: autonomos_goal
priority: high
status: active
---
# Project Goal: <title>

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Current Sprint
- Task A
- Task B
MD
```

`autonomos_cycle` reads goals via `knowledge_get(goal_name)`.
No dedicated tool needed — `knowledge_update` / `knowledge_get` are sufficient.

## Chain Recording (Two-Phase Commit)

### Phase 1: Intent (at end of autonomos_cycle)
```json
{
  "_type": "autonomos_intent",
  "cycle_id": "cyc_20260316_001",
  "goal_name": "project_goals",
  "goal_hash": "abc123...",
  "gaps_identified": 3,
  "proposed_task_id": "fix_tests",
  "design_intent": "...",
  "timestamp": "2026-03-16T..."
}
```

### Phase 2: Outcome (at end of autonomos_reflect)
```json
{
  "_type": "autonomos_outcome",
  "cycle_id": "cyc_20260316_001",
  "intent_ref": "<intent_block_hash>",
  "evaluation": "success",
  "learnings_saved": "autonomos_session_20260316",
  "l1_promotion_proposed": false,
  "suggested_next": "implement feature X",
  "timestamp": "2026-03-16T..."
}
```

## Safety Model

1. **Single cycle default**: always stops after decide for human review. Continuous mode available via `autonomos_loop` with mandate-based pre-authorization (see `autonomos_continuous_mode_design.md`)
2. **PID-based cycle lock**: prevents concurrent cycles (same pattern as autoexec PlanStore)
3. **Inherited autoexec safety**: risk classification, L0 deny-list, hash-locked plans
4. **No L0 modification**: Autonomos tools cannot call skills_evolve (capability_gaps are flagged, not acted on)
5. **Goal hash verification**: goal content hashed at observe time; if goal changes mid-cycle, detectable
6. **Git access safety**: Open3.capture2 with explicit args array, no shell interpretation
7. **autoexec required**: startup check `defined?(::Autoexec)`, raise error if missing
8. **Escape hatch**: any cycle can be abandoned; CycleStore preserves last good state

## Concurrency

- `CycleStore.acquire_lock(cycle_id)` — atomic file creation (File::CREAT | File::EXCL)
- Lock file contains PID + timestamp
- Stale lock detection: if PID no longer running, lock is reclaimed
- Only one active cycle at a time (global lock, not per-cycle)
- autoexec has its own lock — no conflict because Act phase is human-initiated (separate tool calls)

## Dependencies

- `autoexec` SkillSet (required): hard dependency, checked at load time
- KairosChain core: KnowledgeProvider, ContextManager, Chain (standard APIs)

## Philosophy Alignment

- **Proposition 5** (Constitutive Recording): Two-phase chain commit (intent + outcome) makes each cycle constitutive, not evidential. Mirrors autoexec's proven pattern.
- **Proposition 6** (Incompleteness as Driving Force): Orient phase explicitly identifies task_gaps and capability_gaps. Gaps drive the next cycle. capability_gaps connect to the L2→L1→L0 promotion path.
- **Proposition 7** (Design-Implementation Closure): Autonomos uses KairosChain (L1/L2/chain) to manage its own project execution — the system manages projects through the system.
- **Proposition 9** (Human-System Composite): Human is on the boundary at 3 points: (1) goal-setting via knowledge_update, (2) proposal review after decide, (3) feedback injection via reflect. Not excluded, not bypassed. Reflect phase explicitly invites human perspective as input.

## File Structure (Revised)

```
skillsets/autonomos/
  skillset.json
  config/autonomos.yml
  lib/
    autonomos.rb                 # entry point, dependency check
    autonomos/cycle_store.rb     # thin L2+chain adapter, lock management
    autonomos/reflector.rb       # reflect logic (L2 save, L1 promotion, chain record)
  tools/
    autonomos_cycle.rb           # observe+orient+decide in one tool
    autonomos_reflect.rb         # post-execution reflection
    autonomos_status.rb          # cycle history viewer
  knowledge/
    autonomos_guide/autonomos_guide.md
  test/
    test_autonomos.rb
```

## Future (v0.2+ candidates)

- **Continuous mode enhancements**: semantic loop detection, action-semantic risk classification, multi-terminal mandate isolation
- **Cross-SkillSet Act**: drive mmp/hestia tasks, not just code tasks
- **multiuser RBAC**: goal-setting permission tied to user roles, `user_context` end-to-end propagation
- **Multi-LLM review SkillSet**: integrate review triangulation workflow via MCP meeting
