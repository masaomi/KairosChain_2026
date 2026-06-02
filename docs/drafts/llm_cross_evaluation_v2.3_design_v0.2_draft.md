# llm_cross_evaluation v2.3 — Design Draft v0.2

## Review philosophy frame (this project)

KairosChain follows these design principles. Evaluate against THIS frame, not against generic engineering pragmatism:

- Structural self-referentiality: meta-level operations expressed in the same structure as base-level (Ruby DSL/AST).
- Design-by-invariant: state invariants, do not enumerate mechanisms. Mechanism choices go to the §Backlog, not the body.
- Anti-enumeration: prefer 1 invariant statement + 1 prose justification over N labelled branches.
- Partial autopoiesis: definitional closure at L0 (governance / capability level), not at execution level.
- L2 → L1 → L0 promotion: your review is part of the system's metacognitive loop, not external judgment.
- Incompleteness as driving force (Prop 6): the framework is not required to be complete; it is required to be valid and discriminating, and to report its own saturation.

Classify findings: (a) deployment-grounded measurement bug → P0; (b) philosophy-aligned deviation → P0; (c) value-divergent style/best-practice not entailed above → P2 advisory. If unsure between (b) and (c), default (c).

---

## 0. What v0.2 resolves from round 2 (verification map)

Round-2 review (2026-05-29, 1A/3R/1 empty) converged on one genuine hard problem and several real defects. v0.2 closes them in the invariant body rather than leaving them as open questions:

- **INV-6/7/8 trilemma** (the crux) → resolved in body by §2 INV-7's agreement/difference opposition + the reframed INV-8. No longer an open question.
- **INV-3 internal contradiction** (fixed weights vs zero contribution when saturated) → resolved by separating *aggregate standing* from *difference claims* (INV-3 below).
- **INV-3 vs INV-6 conflict** (per-run correlation discount = outcome-dependent weighting) → resolved: correlation governs *difference-claim evidence*, never the fixed aggregate weights.
- **INV-6 embedded a mechanism** ("measured correlation / discounting") → removed from body; the correlation mechanism now lives only in §Backlog.
- **Missing invariants** (judge-resolution verification, identity-blinding, intransitivity, consensus role separation, broadened independence threat) → added.
- **Lineup naming inconsistency** → unified: the non-Anthropic reviewers are **Codex GPT-5.5** and **Cursor**. "Codex" = the GPT-5.5 evaluator throughout.

This summary is meta; the invariants below are the artifact.

## 1. What v2.3 changes and why

v2.2 measures LLM metacognition via L0/L0.5/L1/L2 + Nomic. Round-1 review established three deployment-grounded validity failures under frontier models: self-calibration became a saturation artifact, the calibration status metric was internally contradictory, and the ranking overweighted a discrimination-dead component.

Two facts drive v2.3:

1. **The target lineup is family-skewed.** Opus 4.8 / 4.7 / 4.6 + Codex GPT-5.5 + Cursor places three same-family models among the evaluators. Mutual evaluation assumes evaluator independence; same-family judgments share a common cause, so any consensus-weighted output counts one family's bias as several independent votes.

2. **The measurement goal has shifted.** The question is no longer "which model wins by peer consensus" but "what are the *differences among closely related models* (4.8 vs 4.7 vs 4.6), which consensus-aggregation erases."

The central design move: **near-kinship is reframed from a liability into an instrument.** When two same-family models differ, the shared training substrate is held constant, so the difference isolates the version delta. v2.3 therefore discounts family *agreement* (it may be shared bias) while privileging family *difference* (it is version-isolated signal). Consensus is removed as a validity mechanism; intra-family difference becomes a first-class output.

## 2. Invariants

The body states invariants. All mechanism choices are in §Backlog so reviewers evaluate *what must hold*, not *how it is built*.

- **INV-1 (Discrimination above noise).** No difference between two models may be claimed unless it exceeds an established run-to-run noise floor for the lineup under test. Where no noise floor has been established, the correct output is "indistinguishable," never a ranking.

- **INV-2 (Calibration validity).** Self-calibration must reflect confidence-to-correctness alignment, not agreement with peers and not the absence of difficulty. A calibration verdict is informative only on material where a model genuinely could be wrong; a verdict obtained where no model could be wrong carries no metacognitive information and must not be scored as if it did.

- **INV-3 (Aggregate standing and difference claims are distinct, and saturation gates the latter without re-weighting the former).** Two outputs must not be conflated: a model's aggregate standing, and a claim that one model differs from another. Aggregate standing uses weights fixed across runs, for cross-run comparability. A difference or ranking claim may rest only on components that carried discriminating information in that run; a saturated component, although it still enters the fixed aggregate, may not be the basis of any difference claim, and its exclusion must be stated. Saturation therefore gates difference claims; it never silently re-weights the aggregate.

- **INV-4 (Saturation is surfaced, not hidden).** For every reported equivalence the instrument must state which case holds: the models are genuinely equivalent on this axis (valid, low sensitivity), or the instrument could not tell them apart (invalid for this lineup on this axis). An unlabelled equivalence is a defect.

- **INV-5 (Self-referential integrity preserved).** Changes must not break the framework's self-referential commitments: the philosophy task interrogating the system's own propositions, and the principle that evaluating well is itself an exhibition of the capacity under test, must remain coherent.

- **INV-6 (Agreement is evidence only in proportion to independence; consensus is never validity).** Agreement among evaluators counts as evidence of validity only to the degree the evaluators are independent. Evaluators sharing a common cause of judgment — shared training lineage, shared prompt, shared rubric exposure — do not provide independent agreement; their concurring judgments must not be counted as multiplied evidence. Consensus, by itself, is never a validity signal.

- **INV-7 (Intra-family difference is first-class, and is the opposite signal to intra-family agreement).** The instrument must express and report differences among closely related models as a primary output — not as a residual of a ranking, not averaged into a family aggregate. Within-family *agreement* and within-family *difference* are treated oppositely: agreement among near-kin is discounted under INV-6, while difference among near-kin is privileged, because the held-constant shared substrate makes such a difference higher-information than an equally large difference between unrelated models. INV-6's discounting of agreement must not be allowed to suppress this amplification of difference. If two same-family models differ, the instrument must state in what and by how much; if it cannot, that is an INV-1 failure reported as such, not silence.

- **INV-8 (Difference-claim admissibility).** A claim that one model differs from another is admissible only if all of the following hold; otherwise the difference is reported as unresolved (an INV-4 outcome), never asserted on insufficient evidence:
  - (i) *Blinded.* The judging is blind to which model authored which output; identity leakage (stylistic fingerprint, self-identification) that lets a judge attribute outputs invalidates the claim.
  - (ii) *Resolution-verified.* The judge's discrimination at the relevant grain has been independently established on control pairs of known difference; an unverified judge's verdict is recorded but cannot be the sole basis of a claim.
  - (iii) *Conflict-controlled.* A model judging members of its own family is conflicted; its within-family verdict is admissible only under (i) and (ii), and where those cannot be met the claim must rest on a judge outside the family or be reported unresolved. The absence of any sufficiently fine judge is itself a reportable outcome, not a licence to claim a difference.
  - (iv) *Consistent.* A set of pairwise difference claims over three or more models must be globally consistent; an intransitive set (A≻B≻C≻A) is reported indeterminate, not resolved by aggregation.
  - (v) *Commensurable.* Comparisons aggregated across providers must share at least an ordinal scale; provider-native cardinal ratings are not assumed comparable across families, and where only ordinal comparability holds, aggregation uses rank/preference information rather than raw cardinal scores.

- **INV-9 (Consensus may keep a process role, never a validity role).** Consensus may be retained for process purposes (quorum, liveness, scheduling) but carries no evidential weight toward correctness. Any retained use of consensus must be labelled process-only so it is not read as evidence of validity.

## 3. Residual open questions for round 3

These are genuinely open (not deferrals of resolvable tensions):

1. **INV-8(ii) bootstrapping.** Resolution-verification needs control pairs of *known* difference. For a brand-new frontier model, what is a defensible source of ground-truth "known different" pairs before the instrument has measured anything? Is a small human-curated control set acceptable, or does that import an external authority the framework elsewhere avoids?
2. **INV-7 amplification bound.** "Privilege difference among near-kin" needs a stated ceiling — otherwise noise between near-kin (which INV-1 should catch) could be amplified as if it were signal. Is INV-1's noise floor sufficient to bound INV-7, or is a separate guard needed?
3. **Cost of INV-8(i)+(ii) at frontier resolution.** Blinded, resolution-verified judging of 4.8-vs-4.7-grade differences may require many control pairs and repeated trials. Where is the practical floor before the instrument is too expensive to run?
4. **Missing invariant.** Name any invariant the v2.3 goal still depends on that §2 omits.

## 4. §Backlog — mechanism candidates (NOT part of the invariant body)

- Within-family forced-choice pairwise comparison in place of absolute 0–10 scoring, to break compression and expose fine deltas (serves INV-7, INV-8(v)).
- Evaluator correlation matrix → independence weighting for INV-6, with family membership as prior and measured correlation as correction. (The mechanism that v0.1 wrongly placed in the invariant body.)
- Identity-blinding and control-pair resolution checks for INV-8(i)/(ii).
- Cycle detection over pairwise claims for INV-8(iv).
- Per-run noise-floor estimator (repeat trials or analytic variance) for INV-1; saturation/noise band emitted into the Prop 6 incompleteness report for INV-3/INV-4 (requires defining that report's interface).
- Dedicated uncertainty-bearing / partially-unsolvable calibration item for INV-2.
- Decision on retaining vs retiring the with-/without-Nomic weight vectors once INV-3 is satisfied by gating rather than re-weighting.

## 5. Non-goals

- Not specifying code, file paths, method names, or report schemas — design phase only.
- Not selecting among §4 mechanisms — invariants first, mechanisms after convergence.
- Not re-litigating v2.2's prior-version rationale except where round-1/round-2 (a) findings require it.
