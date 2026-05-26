---
name: multi_llm_reviewer_evaluation
description: "Multi-LLM reviewer performance evaluation — strengths, weaknesses, value-system biases, and recommended workflows. Based on 185+ reviews (Phase 1, 2026-02 to 03) + Phase 2 Case A 4-round Codex bias study (2026-05-04)."
version: "1.4"
tags:
  - multi-llm
  - review
  - evaluation
  - methodology
  - llm-comparison
---

# Multi-LLM Reviewer Performance Evaluation

Based on 185+ review files across KairosChain development (2026-02-24 to 2026-03-28).

## Basic Statistics

| Reviewer | Reviews | Period | FAIL/REJECT Rate | Role |
|----------|---------|--------|-----------------|------|
| Claude Opus 4.6 (Primary) | 15 | 3/18-3/28 | 0% | Designer + reviewer |
| Claude Team Opus 4.6 | 53 | 3/18-3/28 | 0% | Persona assembly review |
| Codex GPT-5.4 | 49 | 3/19-3/28 | 27% | Auto review |
| Codex GPT-5.5 | 4 (Phase 2 Case A) | 2026-05-04 | 100% | Auto review |
| Cursor Composer-2.5 | 27 | 3/20-3/28 | 0% | Auto review |
| Cursor GPT-5.4 | 16 | 3/21-3/25 | 12% | Manual review (Codex fallback) |
| Cursor Premium | 26 | 3/19-3/21 | 12% | Manual review |
| Claude CLI Opus 4.7 | 2 | 4/19- | 0% | Auto review (CLI) |
| Antigravity Gemini 3.1 | ~18 | 2/24-3/08 | 0% | Design review + philosophy |

## Strength Matrix

| Category | Best | 2nd | 3rd |
|----------|------|-----|-----|
| Security design | Claude Opus 4.6 | Cursor Premium | Codex GPT-5.4 |
| Implementation bugs | Codex GPT-5.4 | Cursor Premium | Claude Opus 4.6 |
| State transition/config | Codex GPT-5.4 | Cursor GPT-5.4 | — |
| Overall design coherence | Composer-2.5 | Claude Team | Gemini 3.1 |
| Philosophical alignment | Gemini 3.1 | Claude Team | — |
| Future extensibility | Gemini 3.1 | Composer-2.5 | — |
| Deployment/ops | Composer-2.5 | Cursor GPT-5.4 | — |
| Test adequacy | Codex GPT-5.4 | Cursor GPT-5.4 | Cursor Premium |
| Design-implementation seam | Codex GPT-5.4 | Claude Opus 4.6 | Composer-2.5 |
| Fail-open/fail-closed detection | Codex GPT-5.4 | Claude Opus 4.6 | — |

> Claude CLI Opus 4.7: not yet ranked. Pending evaluation data (added 2026-04-19).

## Per-Reviewer Profiles

### Claude Opus 4.6 (Primary Designer)

- **Strength**: Security-level threat modeling, novel architectural alternatives (e.g., discovering `register_gate` as zero-L0 solution)
- **Weakness**: Implementation-level code bugs (method name typos, race windows in pool logic)
- **Pattern**: Catches architectural bypasses at design stage; proposes creative alternatives others miss
- **Verdict bias**: Trusts implementation if design is sound
- **Unique findings**: Attestation `issued_at` timing attack, nonce NULL bypass, Synoptis replay attack gap, register_gate passive observer pattern

### Claude Team Opus 4.6 (Agent Assembly)

- **Strength**: Consensus-building; catches issues spanning multiple perspectives
- **Weakness**: Slower; sometimes defaults to CONDITIONAL when answer is unclear
- **Pattern**: Excels at multi-angle philosophy review and design-implementation mismatches
- **Verdict bias**: Prefers consensus over individual conviction
- **Unique findings**: L2 API method name mismatch (Autonomos)
- **Persona Assembly**: Most effective as final merge gate (Kairos + Guardian + Pragmatist + Skeptic)

### Codex GPT-5.4

- **Strength**: State transition logic, edge case configuration validation, integration test gaps, fail-open/fail-closed detection
- **Weakness**: Sometimes rejects incremental progress when phase-gating is intentional
- **Pattern**: Finds bugs in unused code paths, missing call sites, type mismatches between API boundaries
- **Verdict bias**: Strictest; expects comprehensive test coverage. REJECT is the default until convinced
- **Unique findings**: Session Path B authorization re-binding, dead circuit breaker code, plan removal fallback, fail-open content_hash attestation, build_place_client return type mismatch, record_file_usage missing call site
- **Convergence signal**: Codex APPROVE = high confidence that all issues are genuinely resolved (see Convergence Behavior)

### Codex GPT-5.5

- **Strength**: Same axis as GPT-5.4 (state transition, fail-open detection) plus tighter schema-internal-consistency checks. Round 3 of Phase 2 Case A caught a §5 schema internal contradiction that no Anthropic family or Cursor reviewer caught
- **Weakness**: Shares all 3 value-system biases with GPT-5.4 (see § Reviewer Value-System Divergence below). Even more resistant to philosophy-briefing internalization than 5.4 in Phase 2 Case A round 4
- **Pattern**: Treat as "stricter sibling" of GPT-5.4. Same evaluative axis, narrower tolerance
- **Verdict bias**: REJECT-default; convergence behavior similar to GPT-5.4 but slower
- **Provisional**: Profile based on Phase 2 Case A 4-round data only. Will refine after additional sessions

### Cursor Composer-2.5

- **Strength**: High-level design coherence, protocol correctness, practical deployability, balanced architecture + pragmatics
- **Weakness**: Less detail on cryptographic edge cases and thread safety
- **Pattern**: Fast, pragmatic assessment; comfortable with CONDITIONAL states
- **Verdict bias**: Approves if core algorithm correct, doesn't penalize incomplete testing
- **Unique findings**: Docker health check port mismatch, L2-first design vs actual API drift, post-hook API absence (register_gate is pre-call only)

### Cursor GPT-5.4

- **Strength**: Configuration validation, explicit security requirements, fail-closed semantics
- **Weakness**: Binary (approve/reject); less granular on which concerns block vs. defer
- **Pattern**: Finds validation gaps and environmental setup issues
- **Verdict bias**: Uncompromising; bimodal approve-or-reject
- **Unique findings**: Docker Compose plugin version pinning, existing volume migration gap

### Cursor Premium

- **Strength**: Deep code-level concurrency issues, resource exhaustion scenarios, API contract mismatches
- **Weakness**: Less engagement with abstract design philosophy
- **Pattern**: Catches subtle bugs in complex interactions (pool + circuit breaker + rate limiter)
- **Verdict bias**: Thorough but pragmatic; uses NOTES to distinguish severity
- **Unique findings**: `@user_context` undefined reference, connection pool checkout leak, PgCB serialization bottleneck

### Claude CLI Opus 4.7 (External CLI)

- **Strength**: Operability and execution-layer issues — auth preconditions, stderr handling, prompt-vs-artifact drift, flag inconsistencies. Finds practical "will this actually run?" problems that internal reviewers miss
- **Weakness**: May miss table/section completeness gaps that systematic reviewers (Opus 4.6) catch. Did not catch residual "1/3" wording in R2
- **Pattern**: Deeply examines CLI execution constraints and cross-references project memory (MEMORY.md) against artifact claims. Produces structured verification tables
- **Verdict bias**: Thorough; APPROVE WITH CHANGES is default. Provides blocking/non-blocking classification
- **Unique findings**: `2>&1` stderr pollution (R1), `--bare` ANTHROPIC_API_KEY auth precondition (R2), Reviews=0 staleness on merge (R2)
- **Note**: Uses `claude -p --model claude-opus-4-7` as external CLI process. `--bare` requires ANTHROPIC_API_KEY; omit in OAuth-only environments. Not an Agent Assembly — runs as single-shot independent reviewer
- **Complementarity with Opus 4.6**: Highly complementary. Opus 4.6 = "is it complete?", Opus 4.7 = "will it work?". Different bug classes with minimal overlap

### Antigravity Gemini 3.1

- **Strength**: KairosChain philosophy (9 propositions) alignment evaluation. Only reviewer that structurally maps review findings to each proposition. Future extensibility proposals (PageRank, Store-and-Forward, Merkle domain separation)
- **Weakness**: Code-level specific bugs (line-number errors, race conditions) rarely found. Focuses on architecture/philosophy layer
- **Pattern**: Approve with improvement proposals. Never issues FAIL or REJECT
- **Verdict bias**: Approval-leaning. "Approve then suggest improvements" is the default
- **Language**: Japanese-primary (matches project philosophy discussions)
- **Unique findings**: MerkleTree second preimage attack, Transport Store-and-Forward, challenge expiry penalty automation, `optional` dependency `parsed_depends_on` incompatibility

## Reviewer Value-System Divergence (Phase 2 Case A, 2026-05-04)

This section documents *why* reviewers reject, not *what* they catch. Phase 1 profiles
(above) record finding categories; Phase 2 Case A revealed that some REJECTs reflect
the reviewer's own evaluative frame rather than a defect in the artifact. Treating
those as blocking signals causes review loops to fail to converge (observed: Context
Graph v1.0-f-high → v1.1 → v1.2, Codex 24/24 REJECT, new P0 every round).

### Codex (GPT-5.4 / 5.5) — 3 structural biases

Both Codex models share these biases against KairosChain's design-by-invariant +
relational-ontology style. The biases are not bugs in the reviewer; they are a
different value system that must be classified explicitly.

1. **"Declared behavior must be enforceable."** Industrial-spec-audit frame.
   Any invariant declared without a verify mechanism is read as documentation drift.
   Conflicts with KairosChain's relational ontology (no verify, writer responsibility,
   graceful degradation by design).
2. **Honest articulation of limits ≡ unresolved spec gap.** §11 backlog entries
   and ceiling articulations are read as self-reported bugs. The more honest the
   document, the more Codex rejects — an inversion of the intended discipline.
3. **"Trust X" + "X is undetectable" = contract contradiction.** A §A "trust X"
   clause combined with a §B "X cannot be verified" clause is read as a defective
   contract. Conflicts with the "uncontracted trust = writer responsibility" model.

### Cursor vs Codex briefing reaction (Phase 2 Case A, 4 rounds)

| Round | Briefing | Cursor | Codex 5.4/5.5 |
|-------|----------|--------|---------------|
| 1 | none (baseline) | REJECT | REJECT |
| 2 | philosophy briefing | REJECT | REJECT |
| 3 | philosophy briefing | REJECT | REJECT |
| 4 | briefing + design-direction context | **APPROVE** | REJECT (unchanged) |

**Insight**: Cursor internalizes the philosophy briefing once design direction is added;
Codex is structurally resistant. Briefing-internalization compliance differs by reviewer
family — track separately when evaluating briefing efficacy.

### (a)/(b)/(c) finding classification

When a reviewer issues a P0, classify the *cause* — not just the severity:

| Class | Definition | Treatment |
|-------|-----------|-----------|
| (a) deployment-grounded | Spec violation, runtime bug, data corruption, concurrency hazard. Independent of philosophy. | **Blocking P0** |
| (b) philosophy-aligned | Deviation from declared design principles (e.g., enumeration where invariant suffices). | **Blocking P0** |
| (c) value-divergent | Reviewer's own style preference or generic best practice not entailed by project principles. | **Advisory only** (non-blocking) |

When uncertain between (b) and (c), default to (c). Convergence rule applies to (a)+(b);
(c) findings are recorded but do not block.

**Codex ↔ classes**: Codex finds genuine (a) bugs (e.g., the §5 schema contradiction).
Codex also produces many (c) findings driven by the 3 biases above. The skill of using
Codex effectively is **not** silencing it but classifying its output.

> Cross-reference: project CLAUDE.md § "Multi-LLM Review Philosophy Briefing"
> describes the experimental briefing-prepend protocol that operationalizes this
> classification. KairosChain_2026 only, experimental.

## Convergence Behavior (New: 2026-03-28)

### Codex as Convergence Indicator

Across the Attestation Nudge session (4 rounds, 12 reviews), Codex demonstrated a distinctive convergence pattern:

```
Design R1:       Codex REJECT  | Composer-2.5 APPROVE+ | Claude APPROVE+
Design R2:       Codex REJECT  | Composer-2.5 APPROVE+ | Claude APPROVE+
Impl Review:     Codex REJECT  | Composer-2.5 APPROVE+ | Claude APPROVE+
Final Review:    Codex APPROVE | Composer-2.5 APPROVE+ | Claude APPROVE+
```

**Key observations**:
- Codex is the **last to approve** — consistently REJECTs when others APPROVE WITH CHANGES
- Codex REJECT reasons are always **substantive** (not stylistic): storage model contradictions, missing call sites, fail-open security
- When Codex finally APPROVEs, all prior FAIL/HIGH issues have been genuinely resolved
- **Codex APPROVE = strongest merge-readiness signal** in the 3-LLM configuration

> **Note**: The above convergence data is from the 3-reviewer configuration in
> the Attestation Nudge session. With the 4-reviewer default (Opus 4.7 added
> 2026-04-19), the convergence pattern may shift. Update this section after
> accumulating 4-reviewer data.
>
> **Caveat (Phase 2 Case A, 2026-05-04)**: "Codex APPROVE = strongest signal" is
> session- and config-dependent. In Phase 2 Case A, Codex never reached APPROVE
> across 4 rounds even with philosophy briefing + design direction. Treat
> "waiting for Codex APPROVE" as not always achievable; rely on (a)/(b)/(c)
> classification (above) rather than verdict-level convergence when value-system
> divergence dominates.

### Convergence Rule (Updated)

The convergence rule applies **after** orchestrator classifies findings as (a)/(b)/(c)
per § Reviewer Value-System Divergence. A REJECT whose findings are entirely (c)
value-divergent is recorded but treated as non-blocking; only (a)+(b) findings count
toward the rule below.

- 3/4 APPROVE (no (a)/(b) REJECT) = proceed to next step (4-reviewer default)
- Any (a) or (b) REJECT or FAIL = revise and re-review
- **4/4 APPROVE (including Codex) = highest confidence, merge-ready**
- Legacy 3-reviewer mode: 2/3 APPROVE = proceed
- Codex-only REJECT with (a)/(b) findings + others APPROVE = likely real issue, investigate before overriding
- Codex REJECT with only (c) findings = expected per Codex value-system divergence; non-blocking

### Bug Category Differentiation Across Rounds

| Review Phase | Typical Bug Category | Example |
|-------------|---------------------|---------|
| Design review R1 | Structural gaps | "knowledge_get can't resolve flat files" |
| Design review R2 | Fix correctness | "version-bound claim contradicts key design" |
| Implementation review | Missing wiring | "record_file_usage has no call site" |
| Final review | Refinement only | "basename matching could false-positive" |

**Insight**: Design reviews and implementation reviews find **categorically different bugs**. Design reviews catch "this can't work" (structural). Implementation reviews catch "this doesn't work" (wiring/integration). Both phases are necessary.

## Cost-Benefit (Phase 1 baseline, 5 reviewers, 2026-02 to 03)

> Baseline only. Opus 4.7 and Codex GPT-5.5 entered the roster post-Phase 1 and are
> not yet rated here. Refresh after sufficient data accumulates.

| Reviewer | Speed | Security | Impl Quality | Philosophy | Overall ROI |
|----------|-------|----------|-------------|-----------|-------------|
| Claude Opus 4.6 | 45min | 5/5 | 4/5 | 3/5 | Excellent |
| Cursor Premium | 55min | 4/5 | 5/5 | 2/5 | Excellent |
| Codex GPT-5.4 | 60min | 3/5 | 5/5 | 1/5 | Excellent |
| Gemini 3.1 | 50min | 3/5 | 2/5 | 5/5 | Good |
| Composer-2.5 | 40min | 2/5 | 3/5 | 2/5 | Good |
| Claude Team | 90min | 3/5 | 3/5 | 4/5 | Fair |
| Cursor GPT-5.4 | 35min | 2/5 | 3/5 | 1/5 | Fair |

## Recommended Workflow

> Note: Workflows updated for 4-reviewer default (Opus 4.7 added 2026-04-19). Opus 4.7 profile is provisional pending evaluation data.

```
Design phase:       Claude Opus 4.6 + Claude CLI Opus 4.7 + Codex GPT-5.4 + Composer-2.5
Implementation:     Codex GPT-5.4 + Composer-2.5 + Claude Opus 4.6 + Claude CLI Opus 4.7
Final merge gate:   Codex GPT-5.4 + Composer-2.5 + Claude Opus 4.6 Assembly + Claude CLI Opus 4.7
Philosophy/Grant:   Gemini 3.1 + Claude Team
Deployment:         Composer-2.5 or Cursor GPT-5.4
```

## One-Line Summaries

| Reviewer | Summary |
|----------|---------|
| Claude Opus 4.6 | Guardian of design. Finds security threats and novel architectural alternatives |
| Codex GPT-5.4 | Strictest judge. Classify findings (a)/(b)/(c) before treating REJECT as blocking; APPROVE is a strong signal **when reachable**, not a mandatory gate (see Phase 2 Case A caveat) |
| Codex GPT-5.5 | Stricter sibling of 5.4. Same value-system divergence (3 biases); apply the same classification discipline |
| Cursor Premium | Implementation craftsman. Bug hunter for concurrency and resource management |
| Composer-2.5 | Fastest pragmatist. First to determine if something is deployable |
| Cursor GPT-5.4 | Binary sword. Clear approve-or-reject, strictest on test coverage |
| Claude Team | Consensus philosopher. Best at integrating multiple viewpoints |
| Claude CLI Opus 4.7 | Operability guardian. Finds auth, stderr, and execution-layer issues internal reviewers miss |
| Gemini 3.1 | Visionary architect. Evaluates design in philosophical context |

## Key Insights

1. The "design-implementation seam" layer is the most valuable and most likely
   to be missed by a single LLM reviewing its own design.
2. Single-LLM findings (1/4 or 1/N) are NOT minority opinions to discard — they often
   represent the most novel and critical discoveries.
3. Codex APPROVE after multiple REJECTs is the strongest quality signal available
   in the multi-LLM configuration.
4. Design reviews and implementation reviews find categorically different bugs —
   both phases are necessary for Tier 2+ features.
5. Some REJECTs reflect the reviewer's value system, not the artifact. The (a)/(b)/(c)
   classification (see § Reviewer Value-System Divergence) is required to separate
   blocking signal from advisory noise. Codex models in particular require this lens.

## Refinement Source

Profiles in this knowledge are refined from accumulated L2 contexts named with prefix
`reviewer_evaluation_observation_<reviewer>_<date>`, recorded after each multi-LLM
review round per `multi_llm_review_workflow` § L2 Save Points. When updating this
file, sample those records to revise per-reviewer profiles, Strength Matrix entries,
Cost-Benefit ratings, and the value-system divergence section. This closes the
L2 → L1 promotion loop for reviewer profiles themselves.
