# Autonomos SkillSet — Multi-LLM Review Synthesis

**Date**: 2026-03-17
**Sources**: Claude Opus 4.6 (4-persona), Codex/GPT-5.4 (persona assembly), Cursor Premium (persona assembly)
**Branch**: feature/autonomos-skillset
**Method**: Cross-source triangulation — issues ranked by inter-reviewer agreement and severity

---

## Source Summary

| Source | Verdict | Method | Key Strength |
|--------|---------|--------|--------------|
| Claude Opus 4.6 | REVISE | 4-persona (Kairos/Pragmatic/Skeptic/Architect) | Deepest philosophical analysis, most rescue cataloging |
| Codex/GPT-5.4 | REVISE | Persona assembly (kairos/pragmatic/skeptic) | Novel findings (prose goal, resume semantics), precise code references |
| Cursor Premium | REVISE | Persona assembly (kairos/guardian/skeptic/pragmatic) | Strongest on multiuser/tenant isolation, concise fix recommendations |

**Unanimous verdict**: REVISE (not REWORK). Architecture is sound; specific fixes needed.

---

## Triangulated Findings

### Tier 1 — All 3 Sources Agree (Must Fix)

| # | Issue | Claude | Codex | Cursor | Priority |
|---|-------|--------|-------|--------|----------|
| 1 | **goal_hash saved but never verified at runtime** | Skeptic+Architect HIGH | HIGH (#1) | implicit (design↔impl gap) | **P0** |
| 2 | **Session/tenant isolation missing (user_context)** | Skeptic CONCERN | HIGH (#3) | FAIL all personas (#1) | **P0** |
| 3 | **Design docs stale** (L2-first, A-B-A detection, state machine divergences) | Architect CONCERN | implicit | LOW (#4) | **P2** |

### Tier 2 — 2 of 3 Sources Agree (Should Fix)

| # | Issue | Sources | Priority |
|---|-------|---------|----------|
| 4 | **Skip path doesn't use Reflector** — cycle stays `decided`, no chain outcome | Codex HIGH (#2), Claude Pragmatic (nil cycle_id) | **P1** |
| 5 | **Silent `rescue StandardError` in load_goal** — masks provider bugs | Claude Pragmatic+Skeptic, Cursor implied | **P1** |
| 6 | **Unreachable CycleStore states** — dead code, misleading docs | Claude Skeptic+Architect | **P1** |
| 7 | **Risk budget is priority filter, not risk assessment** | Claude Pragmatic ISSUE, Cursor MEDIUM (#2) | **P2** (document) |
| 8 | **Goal-source messaging inconsistency** (L1 hints remain in L2-first code) | Codex implied, Cursor MEDIUM (#3) | **P1** |

### Tier 3 — Single Source (Could Fix / Future)

| # | Issue | Source | Priority |
|---|-------|--------|----------|
| 9 | **Prose goals wrongly judged as achieved** — empty gaps = `goal_achieved` | Codex MEDIUM (#4) | **P1** |
| 10 | **Resume is re-execution not continuation** — state not checked | Codex MEDIUM (#5) | **P2** |
| 11 | **many_gaps threshold too sensitive** (>3) | Claude Pragmatic | **P2** |
| 12 | **No mandate file locking** | Claude Skeptic | **Future** |
| 13 | **State transition validation missing** | Claude Skeptic | **Future** |
| 14 | **Loop detection string equality fragile** | Claude Skeptic | **Future** (acknowledged limitation) |

---

## Final Fix Plan

### Phase 1 — Blocking (before merge)

**Fix 1: goal_hash verification at runtime**
- File: `tools/autonomos_loop.rb` — `run_cycle` method
- Action: After orient, compare `orientation[:goal_hash]` with `mandate[:goal_hash]`. If mismatch, pause mandate with `goal_drift_detected` status.
- Rationale: All 3 reviewers flag this. The documented safety feature must be enforced.

**Fix 2: Skip path uses Reflector**
- File: `tools/autonomos_loop.rb` — `handle_cycle_complete`
- Action: When `execution_result` is nil, call `Reflector.new(cycle_id, skip_reason: "skipped_by_user")` instead of inline evaluation. This closes cycle state, records chain outcome, saves L2 learnings.
- Rationale: Codex identified that skip is the most safety-sensitive path yet has the weakest closure.

**Fix 3: Narrow rescue in load_goal + add warn**
- File: `lib/autonomos/ooda.rb` — `load_goal` method
- Action: Catch `StandardError` but add `warn` with error message for both L2 and L1 rescue blocks.
- Rationale: Silent rescue masks real ContextManager/KnowledgeProvider bugs.

**Fix 4: Remove unreachable CycleStore states**
- File: `lib/autonomos/cycle_store.rb` — VALID_STATES
- Action: Remove `observing`, `orienting`, `approved`, `rejected`, `executed`, `cycle_complete` — only keep states actually used: `decided`, `no_action`, `reflected`.
- Rationale: 6 of 9 states are unreachable. Dead states mislead documentation.

**Fix 5: Prose goals return clarification gap, not "achieved"**
- File: `lib/autonomos/ooda.rb` — `identify_gaps`
- Action: When goal is found but has no checklist items AND no gaps from git, add a `clarification` gap asking user to convert prose goal to checklist format.
- Rationale: Codex identified that prose goals silently result in `goal_achieved` — dangerous UX.

**Fix 6: Goal-source messaging normalization**
- Files: `tools/autonomos_loop.rb`, `lib/autonomos/ooda.rb`, `knowledge/autonomos_guide/autonomos_guide.md`
- Action: Change all L1-oriented hints to L2-first messaging: `context_save` for goals, `knowledge_update` for templates.
- Rationale: Implementation is L2-first but messages still say L1.

**Fix 7: Nil cycle_id guard in skipped cycles**
- File: `tools/autonomos_loop.rb` — `handle_cycle_complete`
- Action: Guard `mandate[:last_cycle_id]` being nil. If nil, generate synthetic cycle_id or skip reflect entirely with proper logging.

### Phase 2 — Non-blocking (near-term)

**Fix 8: Update design document**
- File: `docs/autonomos_continuous_mode_design.md`
- Action: Sync with L2-first goal loading, A-B-A oscillation detection, actual state machine, goal_hash verification, complexity hints. Mark v1-only sections as historical.

**Fix 9: Risk budget documentation**
- File: `knowledge/autonomos_guide/autonomos_guide.md`
- Action: Document that risk budget is a priority-based filter (known design choice), not full action-semantic risk assessment.

**Fix 10: many_gaps threshold**
- File: `lib/autonomos/ooda.rb` — `assess_complexity`
- Action: Raise threshold from `> 3` to `> 5`.

### Deferred (requires coordination)

**Fix 11: user_context propagation** — All 3 reviewers flag this (Cursor FAIL). Requires `@safety&.current_user` threading through Ooda, Reflector, and all ContextManager/KnowledgeProvider calls. Deferred because it depends on multiuser SkillSet API stabilization. Track as first-priority for next iteration.

**Fix 12: Resume state validation** — Codex finding. Track for next iteration.

---

## Cross-Reference: Philosophical Alignment

All sources confirm philosophical alignment with KairosChain Nine Propositions:
- **0 violations** across all reviewers
- Mandate model correctly implements Proposition 9 (human-system boundary)
- Two-phase chain recording implements Proposition 5 (constitutive recording)
- Tool↔LLM round-trip constraint transformed into philosophical strength (Proposition 3)
- Minor tension: chain recording failure existential status (Kairos persona, Claude review)

---

## Verification

- Tests: `76 runs, 160 assertions, 0 failures, 0 errors, 0 skips` (all 3 sources confirmed)
- After fixes: re-run tests to confirm no regression
