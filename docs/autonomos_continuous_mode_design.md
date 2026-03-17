# Autonomos Continuous Mode — Design Document (Revised)

## Problem Statement

v1 Autonomos runs single cycles only. The user's original requirement was
"loop until goal achieved, with human feedback at each cycle by default."
The v1 review identified a "self-approval gap": autoexec's hash-lock model
assumes human approval, but continuous mode needs automated progression.

## Key Architectural Constraint

autoexec_run returns "delegated" status — the LLM performs actual execution,
not Ruby code within the tool. Therefore, the loop cannot complete the Act phase
within a single tool call. The loop runs via tool-LLM round-trips:

```
autonomos_loop(start) → LLM executes act → autonomos_loop(cycle_complete) → ... → checkpoint/termination
```

## Solution: Mandate Model (Two-Step)

Instead of bypassing autoexec's safety, we introduce a **mandate** — an
explicit pre-flight approval that scopes what the loop is allowed to do.

```
1. autonomos_loop(create_mandate) → creates mandate, returns mandate_id
2. autonomos_loop(start) → runs first cycle (observe/orient/decide), returns proposal
3. LLM executes via autoexec (Act phase — outside this tool)
4. autonomos_loop(cycle_complete) → reflect + start next cycle OR pause
5. Repeat 3-4 until goal achieved / checkpoint / max_cycles / error
```

The mandate is the human's **pre-authorization**, recorded on chain.

## New Tool: autonomos_loop

### Parameters

```
autonomos_loop(
  command: "create_mandate" | "start" | "cycle_complete" | "interrupt",
  goal_name: "project_goals",           # L1 knowledge name (create_mandate)
  max_cycles: 5,                         # 1-10, required for create_mandate
  checkpoint_every: 1,                   # 1-3, mandatory human pause interval
  risk_budget: "low",                    # "low" | "medium" — max auto-approved risk
  mandate_id: "...",                     # for start / cycle_complete / interrupt
  execution_result: "...",               # for cycle_complete (from autoexec)
  feedback: "..."                        # for cycle_complete (human feedback)
)
```

### Command: create_mandate

1. Load and validate goal from L1
2. Compute goal_hash for immutability tracking
3. Create mandate:
   ```json
   {
     "mandate_id": "mnd_20260317_001",
     "goal_name": "project_goals",
     "goal_hash": "abc123...",
     "max_cycles": 5,
     "checkpoint_every": 2,
     "risk_budget": "low",
     "status": "created",
     "cycles_completed": 0,
     "cycle_history": [],
     "created_at": "2026-03-17T..."
   }
   ```
4. Record mandate on chain (constitutive: this IS the approval)
5. Return mandate_id for human to confirm before starting

### Command: start

1. Verify mandate_id exists and is in "created" state
2. Set mandate status to "active"
3. Run first cycle: observe → orient → decide
4. If no gaps: terminate("goal_achieved")
5. Apply risk budget gate to proposal
6. Return proposal summary + next_steps (LLM executes act)

### Command: cycle_complete

1. Verify mandate_id exists and is "active"
2. Run reflect phase on execution_result
3. Increment cycles_completed
4. Check termination conditions:
   - goal_achieved? → terminate
   - cycles_completed >= max_cycles → terminate("max_cycles_reached")
   - consecutive_errors >= 2 → terminate("error_threshold")
   - loop_detected? → terminate("loop_detected")
   - checkpoint_due? → pause("checkpoint")
5. If continuing: run next cycle (observe → orient → decide)
6. Apply risk budget gate
7. Return proposal summary (LLM executes next act)

### Command: interrupt

1. Set mandate status to "interrupted"
2. Record interruption on chain
3. Return current state summary

## Risk Budget Gate

| Budget | Auto-approved (return proposal) | Pause required |
|--------|-------------------------------|----------------|
| low    | read, search, analyze, list   | edit, create, test, delete |
| medium | read, search, analyze, edit, create, test | delete, push, deploy |

Maps to autoexec's RiskClassifier categories. When a proposal exceeds budget,
mandate status becomes "paused_risk_exceeded" and the tool returns asking for
human decision.

## Loop Detection

Simple consecutive-same-gap detection only (no complex heuristics):

```ruby
def loop_detected?(current_proposal, previous_proposal)
  return false unless previous_proposal
  current_desc = current_proposal.dig(:selected_gap, :description)
  prev_desc = previous_proposal.dig(:selected_gap, :description)
  current_desc == prev_desc
end
```

## Checkpoint System

At checkpoint, the tool returns:

```json
{
  "mandate_id": "mnd_...",
  "status": "paused_at_checkpoint",
  "cycles_completed": 2,
  "cycles_remaining": 3,
  "last_evaluation": "success",
  "cumulative_evaluations": ["success", "partial"],
  "gaps_remaining": 2,
  "checkpoint_prompt": "Review progress. Continue with cycle_complete, or interrupt."
}
```

Human resumes with:
```
autonomos_loop(command: "cycle_complete", mandate_id: "mnd_...", feedback: "Looks good")
```

Or stops with:
```
autonomos_loop(command: "interrupt", mandate_id: "mnd_...")
```

## State Machine

```
  create_mandate          start
       │                    │
       ▼                    ▼
  ┌─────────┐         ┌─────────┐
  │ created  │────────→│ active  │
  └─────────┘         └────┬────┘
                           │
              ┌────────────┤
              │     cycle: observe → orient → decide
              │            │
              │     risk > budget? ──→ paused_risk_exceeded
              │            │
              │     return proposal to LLM
              │            │
              │     LLM executes (outside tool)
              │            │
              │     cycle_complete
              │            │
              │     reflect + check termination
              │            │
              ├── goal done / max / error / loop → terminated
              │            │
              ├── checkpoint due → paused_at_checkpoint
              │            │                │
              │            │     cycle_complete (resume)
              │            │                │
              └────────────┴────────────────┘
```

## Chain Recording

### Mandate (at create_mandate)
```json
{
  "_type": "autonomos_mandate",
  "mandate_id": "mnd_...",
  "goal_name": "project_goals",
  "goal_hash": "...",
  "max_cycles": 5,
  "checkpoint_every": 2,
  "risk_budget": "low",
  "timestamp": "..."
}
```

### Loop Summary (at termination)
```json
{
  "_type": "autonomos_loop_summary",
  "mandate_id": "mnd_...",
  "cycles_completed": 4,
  "termination_reason": "goal_achieved",
  "evaluations": ["success", "partial", "success", "success"],
  "timestamp": "..."
}
```

Individual cycle intent/outcome records continue as in v1.

## Safety Model

1. **Mandate = bounded delegation**: human explicitly approves scope BEFORE loop
2. **Two-step start**: create_mandate returns for review, start begins execution
3. **risk_budget gate**: proposals exceeding budget pause the loop
4. **checkpoint_every 1-3**: human MUST review at least every 3 cycles
5. **max_cycles 1-10**: hard cap on autonomous execution
6. **Error threshold**: 2 consecutive failures terminate loop
7. **Loop detection**: same-gap consecutive detection halts loop
8. **No L0 modification**: inherited from v1
9. **Mandate recorded on chain**: approval is constitutive and auditable
10. **interrupt command**: human can stop at any time

## Implementation Scope

### New files
- `tools/autonomos_loop.rb` — new tool (all loop logic here)
- `lib/autonomos/mandate.rb` — mandate CRUD + validation + persistence

### Modified files
- `skillset.json` — add tool_class
- `lib/autonomos.rb` — require mandate module
- `lib/autonomos/cycle_store.rb` — add loop-related states
- `tools/autonomos_status.rb` — show active mandate/loop state
- `test/test_autonomos.rb` — add loop + mandate tests
