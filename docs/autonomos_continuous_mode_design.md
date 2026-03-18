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
  goal_name: "project_goals",           # L2 context first, L1 fallback (create_mandate)
  max_cycles: 5,                         # 1-10, required for create_mandate
  checkpoint_every: 1,                   # 1-3, mandatory human pause interval
  risk_budget: "low",                    # "low" | "medium" — max auto-approved risk
  mandate_id: "...",                     # for start / cycle_complete / interrupt
  execution_result: "...",               # for cycle_complete (from autoexec)
  feedback: "..."                        # for cycle_complete (human feedback)
)
```

### Command: create_mandate

1. Load and validate goal (L2 context first, L1 knowledge fallback)
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
4. Verify goal_hash matches mandate — if drift detected, pause with `paused_goal_drift`
5. If no gaps: terminate("goal_achieved")
6. Apply risk budget gate to proposal
7. Return proposal summary + next_steps (LLM executes act)

### Command: cycle_complete

1. Verify mandate_id exists and is "active", "paused_at_checkpoint", or "paused_risk_exceeded"
2. If resuming from pause, set status to "active" and skip checkpoint re-evaluation for this cycle
3. Run reflect phase on execution_result (skipped if no prior cycle)
4. Increment cycles_completed
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

The risk budget is **priority-based**, not action-semantic. Gap priority maps
to step risk: high-priority gaps produce high-risk steps.

| Budget | Auto-approved | Pause required |
|--------|--------------|----------------|
| low    | low-priority gaps only | medium and high priority |
| medium | low and medium priority | high priority |

This is a practical simplification: full action-semantic risk classification
(read/write/delete) is deferred to v0.2. When a proposal exceeds budget,
mandate status becomes "paused_risk_exceeded" and the tool returns asking for
human decision.

## Loop Detection

3-step lookback with two patterns:

```ruby
def loop_detected?(current_proposal, recent_gap_descriptions)
  normalize = ->(s) { s.to_s.gsub(/\d+/, 'N') }
  current_norm = normalize.call(current_desc)
  recent_norm = recent.map { |d| normalize.call(d) }
  # 1. Consecutive same-gap (A→A)
  return true if recent_norm.last == current_norm
  # 2. Oscillation (A→B→A pattern)
  if recent_norm.size >= 2
    window = recent_norm.last(2) + [current_norm]
    return true if window[0] == window[2] && window[0] != window[1]
  end
end
```

Note: Number-normalized string comparison (digits replaced with `N` to prevent
interpolated counts from defeating detection). LLM synonym rewording can still
bypass detection. This is acceptable for v0.1 given the other termination safety
nets (max_cycles, error_threshold, checkpoints).

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
7. **Loop detection**: 3-step lookback (A→A, A→B→A) halts loop
8. **Goal hash verification**: each cycle verifies goal hasn't drifted since mandate creation
9. **No L0 modification**: inherited from v1
10. **Mandate recorded on chain**: approval is constitutive and auditable
11. **interrupt command**: human can stop at any time

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
