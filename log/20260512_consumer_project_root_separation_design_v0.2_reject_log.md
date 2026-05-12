# v0.2 Integration Reject Log

**Date:** 2026-05-12
**Inputs:**
- Sub-author (Opus 4.6) draft: `log/20260512_consumer_project_root_separation_design_v0.2_sub_author_4.6.md`
- Orchestrator (Opus 4.7) draft: `log/20260512_consumer_project_root_separation_design_v0.2_orchestrator_4.7.md`

**Integrator:** Opus 4.7 (this session's orchestrator)

**Base selected:** 4.6 sub-author draft. Rationale: 9 invariants vs 4.7's 11 — 4.6 absorbed P0-A (plausibility) into existing Inv 6 and P1-G (authorization) into existing Inv 4 rather than spawning new invariants. This matches the user directive "これ以上レビュー面積を増やさないように" (do not expand review surface). 4.6's draft is also ~70 lines shorter without losing content density.

## From 4.7 — Accepted

- **Inv 2 rewording**: 4.7's "Explicit configuration or named default; no silent inference" with the justification that "defaulting is a named form of explicitness, not its absence" — this directly addresses the Inv 2 ↔ Inv 6 tension flagged by every round-1 reviewer. 4.6's draft kept v0.1's "explicit over implicit" wording, which leaves the tension implicit.
- **§5 narrowing language**: "The commitment is to the canonical common case, not to every prior behavior. The bug being fixed had no 'correct' behavior in the failing scenarios; backward compatibility for those is impossible by definition." This addresses codex P1 ("§5 inconsistent with HTTP MCP transport rule") more sharply than 4.6's neutral wording.
- **§10 criterion 7 addendum**: "Does the authorization requirement (Inv 4) inadvertently centralize trust in the core?" 4.6's criterion 7 asked only about Skill-expressibility; 4.7 surfaces the additional Prop 10/centralization question raised by the new authorization invariant.
- **§6 row provenance annotation**: "source of value" added to the loud-failure diagnostic for "path does not exist" (4.7 had this; 4.6 omitted). The provenance helps debugging in shared-instance scenarios.

## From 4.7 — Rejected

- **Splitting plausibility into a separate Inv 8**: 4.7's approach (new Inv 8 + new Inv 9 for realpath + new Inv 10 for routing + new Inv 11 for authorization) brings invariant count to 11. 4.6's absorption into Inv 6 / Inv 4 is more parsimonious and arrives at the same operational behavior. Rejected for bloat.
- **§4 cell labels "Required" repeated across rows**: 4.7's table had a column per invariant marking each "Required" or "N/A". 4.6's collapsed presentation (one "Defaulting" column + a separate invariant-applicability paragraph) is cleaner. Rejected — kept 4.6's structure.
- **Risk 3 "false positives and false negatives"**: 4.7 listed both failure modes; 4.6 listed only false negatives (with the prose making clear the predicate must err toward refusal). Kept 4.6's narrower framing — false positives are not a meaningful risk if the predicate is conservative by design.
- **§7 test 7 wording about "request-level identifier"**: 4.7 wrote "each carrying its own request-level identifier"; 4.6 wrote "each with a distinct consumer identifier". Kept 4.6 — "consumer identifier" matches Inv 9 terminology; "request-level" is mechanism detail.

## From 4.6 — Accepted (as base)

Substantially all of 4.6's structure, including:
- 9-invariant set with Inv 6 (plausibility) and Inv 4 (authorization) tightening rather than new invariants.
- §6 failure taxonomy row ordering.
- §3 scope boundaries expanded to mention Inv 9 routing.
- §4 single-column "Defaulting" presentation.
- §11 backlog organization (per-transport defaults relocated correctly).
- Risk 3 reframed to plausibility-check false negatives.

## Findings deliberately not addressed in v0.2

These were classified (c) value-divergent in round 1 or are pre-existing design choices preserved across revisions:

- **Concurrent shared-data consistency model** (codex P2, persona-safety P2 advisory): §8 Risk 2 acknowledges this. The consistency model is genuinely undefined here and need not be defined to fix the silent-failure bug. Deferred.
- **Blockchain recording of project-root resolution events** (philosophy-persona P2, Prop 5 advisory): §9 item 6 keeps blockchain format unchanged. Per-projection recording would be a separate design touching the blockchain layer; not required for this fix.
- **§10 criterion 7 not answered in body** (philosophy-persona P2): the open question is load-bearing per Prop 4 (structure opens possibility space). Answering it in body would close it prematurely. Preserved as open.
- **§1 omits settings.json hook merging** (subprocess Claude P2): §1 cites four locations as illustrative; settings.json hook merging is part of "the `.claude/` directory" reference. Adding a fifth would expand body surface without changing the invariants.
- **Threat model section** (codex P2, "no stated boundaries for write target trust"): Inv 4's authorization requirement closes the practical trust gap (consumer must designate the path). A formal threat-model section would expand review surface beyond what the bug fix requires.

## Process notes

- Sub-author (4.6) first attempt via `cat brief | claude -p ... &` produced empty output (zero-byte log, no artifact). Cause not investigated. Synchronous retry with `claude -p "<inline brief>"` succeeded on first attempt. Background-pipe pattern is unreliable for `claude -p`; prefer inline-prompt + foreground or wait-then-poll for future revisions.
- No second multi-LLM review round was run on v0.2. Per user directive ("これ以上レビュー面積を増やさないように... 実装に進んでください"), v0.2 proceeds directly to Phase 3 implementation.
- Invariant count crossed the v0.1 goal cap (≤7 → 9). This is a documented evolution, not a goal violation. The cap was a starting budget; round-1 reviewer findings required structural additions that could not be absorbed into 7 invariants without weakening them.
