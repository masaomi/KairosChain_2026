# llm_cross_evaluation v2.3 — Design FREEZE v1.0

Status: **FROZEN for implementation** (2026-05-29). Anthropic persona unanimity gate
satisfied across rounds 3–4 (claude_team_opus4.7 + claude_cli_opus4.6 both APPROVE);
zero P0 findings at round 4. The two round-4 REJECTs were both Codex (legalistic-waterfall
non-convergence pattern; codex_gpt5.5 regressed APPROVE→REJECT), classified advisory.
This freeze folds the four genuine round-4 P1 precision fixes; no structural change.

## Review philosophy frame (this project)

Evaluate against THIS frame, not generic engineering pragmatism: structural
self-referentiality; design-by-invariant (invariants in body, mechanisms in §Backlog);
anti-enumeration; partial autopoiesis (closure at L0); L2→L1→L0 promotion; incompleteness
as driving force (valid + discriminating + self-reporting saturation, not complete).
Findings: (a) deployment-grounded → P0; (b) philosophy-aligned → P0; (c) value-divergent → P2.

---

## 0. Provenance (rounds 1–4)

- **R1** (1A/4R): established three (a) validity failures under frontier models — L0.5 self-calibration is a saturation artifact, calibration status metric self-contradictory, ranking overweights discrimination-dead L1.
- **R2** (1A/3R): surfaced the INV-6/7/8 trilemma and INV-3 contradiction.
- **R3** (4A/1R): trilemma resolved via the near-kin-as-control reframing; one genuine residual (control-pair bootstrapping).
- **R4** (3A/2R, zero P0): bootstrapping resolved; persona gate satisfied. Round-4 P1 fixes folded here:
  - INV-8(ii): coarse controls are a *screen* (necessary, not sufficient for fine resolution); generational gap established by release provenance, external to the instrument's own judgments.
  - INV-7: the within-vs-cross comparison uses INV-8(v) ordinal commensurability; preservation-property phrasing replaces weighting verbs.
  - Definitions/Component: precedence under multi-level saturation; intra-family difference is itself a component channel.
  - Definitions/Family + INV-10: family membership is per-lineup by declared lineage; opaque-lineage judges (e.g., Cursor) are "unknown-family"; lineup record includes the Definitions/invariant-set version.

## 1. What v2.3 changes and why

v2.2 measures LLM metacognition via L0/L0.5/L1/L2 + Nomic. Two facts drive v2.3:

1. **The target lineup is family-skewed.** Opus 4.8 / 4.7 / 4.6 + Codex GPT-5.5 + Cursor places three same-family models among the evaluators. Mutual evaluation assumes evaluator independence; same-family judgments share a common cause, so consensus counts one family's bias as several votes.
2. **The measurement goal has shifted** from "which model wins by peer consensus" to "what are the *differences among closely related models* (4.8 vs 4.7 vs 4.6), which consensus-aggregation erases."

Central move: **near-kinship is reframed from liability to instrument.** When two same-family models differ, the shared substrate is held constant, so the difference isolates the version delta. v2.3 discounts family *agreement* (possible shared bias) and treats family *difference* as version-isolated signal. Consensus is removed as a validity mechanism; intra-family difference becomes first-class.

## 2. Definitions

- **Component** — a distinct measured channel assessed for saturation/discrimination on its own: a (task × criterion) axis, a judge, a measurement layer, or an intra-family difference channel. When multiple levels saturate in one run, gating and the limits report apply at the finest applicable channel and name each saturated level.
- **Lineup** — the pinned set under test: model identities and versions, judge roster, protocol revision, and the Definitions/invariant-set version. Recorded per run (INV-10).
- **Family / near-kin** — models sharing declared training lineage; determined per lineup. A judge whose lineage is undeclared or opaque (e.g., a product that routes to an undisclosed backing model) is "unknown-family": it is neither counted as independent corroboration nor as same-family conflict, and its status is named in the limits report.
- **Noise floor** — the instrument's established run-to-run variation for a pinned lineup, below which no difference is claimable (INV-1).

## 3. Invariants

- **INV-1 (Discrimination above noise).** No difference between two models may be claimed unless it exceeds the established noise floor for the pinned lineup. Absent an established floor, the output is "indistinguishable," never a ranking.

- **INV-2 (Calibration validity).** Self-calibration must reflect confidence-to-correctness alignment, not agreement with peers and not the absence of difficulty. A calibration verdict is informative only on material where a model genuinely could be wrong; one obtained where no model could be wrong carries no metacognitive information and must not be scored as if it did.

- **INV-3 (Standing vs difference claims; saturation gates difference claims without re-weighting standing; standing is never a ranking).** Aggregate standing and a difference claim must not be conflated. Standing uses weights fixed across runs for comparability. A difference/ranking claim may rest only on components that carried discriminating information that run; a saturated component still enters the fixed aggregate but may not ground a difference claim, and that exclusion must be recorded in the INV-4 limits report. Because standing may carry saturated components, standing may not itself be consumed as a difference/ranking claim and, where surfaced, must be labelled not-a-ranking.

- **INV-4 (Saturation and limits surfaced).** For every reported equivalence the instrument must state which case holds: genuine equivalence (valid, low sensitivity) or non-discrimination (invalid for this lineup on this axis). Each run must emit a limits report naming every saturated component and every unresolved claim. An unlabelled equivalence, or a run with no limits report, is a defect.

- **INV-5 (Self-referential integrity preserved).** The philosophy task interrogating the system's own propositions, and the principle that evaluating well is itself an exhibition of the capacity under test, must remain coherent.

- **INV-6 (Agreement is evidence only in proportion to independence; consensus is never validity).** Agreement counts as evidence of validity only to the degree evaluators are independent. Independence is broken by a shared *cause of judgment tendency* — paradigmatically shared training lineage — not by the task material every evaluator necessarily shares (the common prompt and rubric are the experiment, not a confound). Evaluators with a shared cause do not provide independent agreement; their concurring judgments must not be counted as multiplied evidence. Consensus, by itself, is never a validity signal.

- **INV-7 (Intra-family difference is first-class, above the noise floor).** The instrument must express and report differences among near-kin as a primary output — not a ranking residual, not averaged into a family aggregate. A within-family difference exceeding the noise floor (INV-1) must be preserved (neither discarded nor averaged away), because the held-constant shared substrate isolates the version delta; comparison of a within-family difference to a cross-family one uses the ordinal commensurability of INV-8(v). A within-family difference at or below the floor is noise. If two same-family models differ above the floor, the instrument states in what and by how much; if it cannot, that is an INV-1/INV-4 outcome reported as such, not silence.

- **INV-8 (Difference-claim admissibility).** A difference claim is admissible only if all hold; else it is reported unresolved (INV-4):
  - (i) *Blinded.* Judging is blind to which model authored which output; identity leakage that enables attribution invalidates the claim.
  - (ii) *Resolution screen, coarse-to-fine.* Control pairs whose difference is fixed by external provenance (paradigmatically a known generational gap), independent of the instrument's own judgments, screen a judge's discrimination: a judge that cannot resolve a known-coarse difference may not adjudicate a finer one. Passing the coarse screen is necessary, not sufficient — it licenses a fine claim only together with the noise-floor and consistency conditions, and never via a control whose difference depends on the same fine judgment under test.
  - (iii) *Conflict-controlled.* A model judging its own family is conflicted; beyond (i)–(ii) its within-family verdict may not be the sole basis of a claim. Where no unconflicted, sufficiently resolved judge exists, the claim rests on an out-of-family judge or is reported unresolved; the absence of a fine-enough judge is itself reportable, not a licence.
  - (iv) *Consistent.* Pairwise claims over three or more models must be globally consistent; an intransitive set (A≻B≻C≻A) is reported indeterminate, not aggregated away.
  - (v) *Commensurable.* Cross-provider comparisons must share at least an ordinal scale; provider-native cardinal ratings are not assumed comparable across families, so aggregation uses rank/preference information where only ordinal comparability holds.

- **INV-9 (Consensus may keep a process role, never a validity role).** Consensus may serve process (quorum, liveness, scheduling) but carries no evidential weight toward correctness, and any such use must be labelled process-only.

- **INV-10 (Lineup pinned and recorded).** Every run records its lineup — model identities and versions, judge roster, protocol revision, and Definitions/invariant-set version. A noise floor (INV-1) and saturation report (INV-4) are meaningful only relative to a pinned lineup; results from different lineups (including different Definitions versions) are not comparable unless the record establishes the comparison is valid.

## 4. Accepted residuals (implementation-phase, not design-blocking)

- Cost floor of blinded, screened, repeated judging at 4.8-vs-4.7 grain — empirical tuning, bounded by INV-1/INV-8.
- Whether the out-of-family judges (Codex GPT-5.5, Cursor) actually pass the INV-8(ii) screen at 4.8/4.7 grain is an empirical control-pair result, not a design gap. If none do, INV-8(iii)/INV-4 require reporting the within-family delta as unresolved rather than asserting it.
- "Sufficient non-sole basis" cardinality under INV-8(iii) (one unconflicted resolved judge vs more) is an implementation threshold.

## 5. §Backlog — mechanism candidates (NOT invariants)

- Within-family forced-choice pairwise comparison replacing absolute 0–10 scoring (INV-7, INV-8(v)).
- Evaluator correlation matrix → independence weighting for INV-6 (family as prior, measured correlation as correction), applied to difference-claim evidence only, never to INV-3 standing weights.
- Identity-blinding + coarse-to-fine control-pair screens for INV-8(i)/(ii); generational-gap pairs as coarse controls.
- Cycle detection for INV-8(iv).
- Per-run noise-floor estimator for INV-1; limits report per INV-4.
- Dedicated uncertainty-bearing calibration item for INV-2.
- Retain-vs-retire decision on with-/without-Nomic weight vectors once INV-3 is satisfied by gating.

## 6. Non-goals

- No code, paths, method names, or report schemas — design phase only.
- No mechanism selection — invariants first.
- No re-litigation of v2.2's prior rationale except where round-1/2/3/4 (a) findings require it.
