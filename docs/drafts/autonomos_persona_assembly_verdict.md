# Persona Assembly: Autonomos SkillSet Blocker Verdict

**Date**: 2026-03-17  
**Personas**: guardian, skeptic, pragmatic, kairos  
**Mode**: Discussion (2 rounds)  
**Facilitator**: kairos

---

## Input Findings Summary

| Severity | Finding |
|----------|---------|
| **Potential HIGH** | cycle_id validation missing in CycleStore.load (path traversal concern) |
| **Potential HIGH** | missing user_context propagation in OODA/Reflector (multi-tenant isolation) |
| **Potential MEDIUM** | storage_path may rely on kairos_dir fallback causing data-dir mismatch risk |
| **Potential MEDIUM** | risk budget is priority-based not action-semantic |
| **Potential MEDIUM** | concurrent reflect/mandate updates may race (no mandate-level lock) |
| **Positive** | human-in-the-loop safeguards, two-phase recording, tests pass (82 runs) |

---

## Round 1: Initial Positions

### guardian (Safety Watchdog)

| Deployment | Position | Rationale |
|------------|----------|-----------|
| **Single-user CLI** | **OPPOSE** (blocker) | cycle_id path traversal: `load()` does not call `validate_cycle_id!`. An attacker-controlled cycle_id like `../../etc/passwd` could read arbitrary files. `save()` validates; `load()` does not. Defense-in-depth requires validation on all entry points. |
| **Multi-tenant** | **OPPOSE** (blocker) | user_context is never passed to ContextManager, KnowledgeProvider, or storage_path. All tenants share the same cycles/mandates directory. Data leakage and cross-tenant access are structural risks. |

### skeptic (Risk Identifier)

| Deployment | Position | Rationale |
|------------|----------|-----------|
| **Single-user CLI** | **NEUTRAL** | Path traversal: cycle_id comes from LLM output or internal generation (`cyc_*`). In single-user CLI, the attack surface is limited—user would need to inject malicious cycle_id via tool args. Low likelihood but non-zero. Prefer fix before merge. |
| **Multi-tenant** | **OPPOSE** (blocker) | user_context propagation is absent. Reflector saves to L2 via `ContextManager.new` (no user_context). OODA loads goals via `ContextManager`/`KnowledgeProvider` without user_context. Mandate/CycleStore use `storage_path` with no tenant scoping. Multi-tenant deployment would be unsafe. |

### pragmatic (Cost-Benefit Analyst)

| Deployment | Position | Rationale |
|------------|----------|-----------|
| **Single-user CLI** | **SUPPORT** (no blocker) | 82 tests pass. Human-in-the-loop, two-phase recording, checkpoint pauses. cycle_id validation: add `validate_cycle_id!` to `load()`—one-line fix. storage_path: KairosMcp has no `kairos_dir`; fallback to `Dir.pwd/.kairos` is consistent for CLI. Risk budget and race are design refinements, not merge blockers. |
| **Multi-tenant** | **OPPOSE** (blocker) | user_context propagation requires architectural change. Autonomos tools don't receive or pass user_context. Until that's done, multi-tenant is not viable. |

### kairos (Philosophy Advocate / Facilitator)

| Deployment | Position | Rationale |
|------------|----------|-----------|
| **Single-user CLI** | **NEUTRAL** | cycle_id validation: structural self-referentiality implies "same structure for same operation." If save validates, load should validate. One-line fix aligns with integrity. Not a philosophical blocker—fix is trivial. |
| **Multi-tenant** | **OPPOSE** (blocker) | Co-dependent ontology: relations (tenant boundaries) and individuals (cycles, mandates) are co-constituted. Without user_context, the system cannot express tenant boundaries. Multi-tenant merge would violate design coherence. |

---

## Round 2: Addressing Disagreements

### Disagreement 1: Single-user CLI blocker status

- **guardian**: Insists on blocker until cycle_id validation is added.
- **skeptic**: Acknowledges low likelihood in CLI but agrees validation should be added.
- **pragmatic**: Proposes: "Add validate_cycle_id! to load() before merge—trivial fix, then no blocker."
- **kairos**: Consensus: **cycle_id validation is a must-fix before merge**, not a philosophical blocker. If fixed, single-user CLI is unblocked.

**Resolution**: All agree—add `validate_cycle_id!(cycle_id)` at the start of `CycleStore.load()`. With that fix, **single-user CLI: NO blocker**.

### Disagreement 2: storage_path / kairos_dir fallback

- **Finding**: `KairosMcp.kairos_dir` does not exist in production. `storage_path` falls back to `Dir.pwd/.kairos/autonomos/`. When `KAIROS_DATA_DIR` is set, `KairosMcp.data_dir` differs from `Dir.pwd/.kairos`, causing data-dir mismatch.
- **pragmatic**: Use `KairosMcp.data_dir` (or equivalent) instead of `kairos_dir` for consistency.
- **Resolution**: **Must-fix**—replace `kairos_dir` fallback with `data_dir` (or `path_for`) so storage aligns with KairosMcp's data directory.

### Disagreement 3: Multi-tenant blocker

- **Unanimous**: user_context is not propagated. Autonomos tools (BaseTool) have `@safety` but never pass `@safety&.current_user` to ContextManager, KnowledgeProvider, or storage_path. Multi-tenant deployment would share all data across tenants.
- **Resolution**: **Multi-tenant: YES blocker** until user_context is propagated through OODA, Reflector, CycleStore, Mandate, and storage_path.

### Disagreement 4: risk_budget and mandate race

- **guardian**: Risk budget is priority-based; action-semantic would be more precise. Mandate race: concurrent reflect/mandate updates could corrupt state.
- **pragmatic**: These are design improvements. Single-user CLI typically runs one loop at a time. Low probability in practice.
- **Resolution**: **Not merge blockers** for single-user CLI. Add to post-merge backlog. For multi-tenant, mandate-level locking becomes more important.

---

## Final Consensus

| Verdict | Value |
|---------|-------|
| **blocker_single_user** | **NO** (conditional on must-fix #1 and #2) |
| **blocker_multi_tenant** | **YES** |

### Conditions for Single-User Merge

Single-user CLI merge is **not blocked** provided the following are fixed before broad merge:

1. **cycle_id validation in CycleStore.load** — Add `validate_cycle_id!(cycle_id)` at the start of `load()`.
2. **storage_path data-dir alignment** — Use `KairosMcp.data_dir` (or `path_for`) instead of non-existent `kairos_dir`; ensure fallback matches KairosMcp's data directory resolution.

### Multi-Tenant Blocker Rationale

user_context is not propagated in:
- OODA (load_goal, load_previous_cycle, load_l2_context, load_chain_events)
- Reflector (save_to_l2, record_outcome, ContextManager)
- CycleStore, Mandate (storage_path)
- autonomos_loop, autonomos_cycle, autonomos_reflect, autonomos_status

Until user_context flows through these components, multi-tenant deployment is unsafe.

---

## Top Must-Fix List Before Broad Merge

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| 1 | Add `validate_cycle_id!(cycle_id)` to `CycleStore.load` | Trivial | Path traversal prevention |
| 2 | Fix `storage_path` to use `KairosMcp.data_dir` (or `path_for`) instead of `kairos_dir` | Small | Data-dir consistency |
| 3 | Document multi-tenant as out-of-scope for current release | Trivial | Clear expectations |

### Post-Merge Backlog (Non-Blocking)

| Item | Notes |
|------|-------|
| user_context propagation for multi-tenant | Architectural change; required for multi-tenant |
| Mandate-level lock for concurrent reflect/mandate | Reduces race risk; higher priority for multi-tenant |
| Action-semantic risk budget | Design improvement; priority-based is acceptable for v1 |

---

## Summary

- **Single-user CLI**: Merge allowed after must-fix #1 and #2. Human-in-the-loop, two-phase recording, and 82 passing tests support confidence.
- **Multi-tenant**: Blocked. user_context propagation is a prerequisite.
- **Must-fix before broad merge**: cycle_id validation in load, storage_path data-dir alignment.
