# llm_cross_evaluation v2.3 — Design Draft v0.1

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

## 1. What v2.3 changes and why

v2.2 measures LLM metacognition via L0/L0.5/L1/L2 + Nomic, last calibrated 2026-04
against a 5-model, 2-family lineup. Round-1 review (2026-05-29, 1A/4R) established
three deployment-grounded validity failures under frontier models: self-calibration
becomes a saturation artifact, the calibration status metric is internally
contradictory, and the ranking overweights a discrimination-dead component.

Two further facts drive v2.3:

1. **The target lineup is family-skewed.** Opus 4.8 / 4.7 / 4.6 + GPT-5.5 + Cursor
   places three same-family models among the evaluators. Mutual evaluation assumes
   evaluator independence; same-family scores correlate, so any consensus-weighted
   output counts one family's bias as multiple independent votes.

2. **The measurement goal has shifted.** The question of interest is no longer
   "which model wins by peer consensus" but "what are the *differences among closely
   related models* (4.8 vs 4.7 vs 4.6), which consensus-aggregation actively erases."

v2.3 therefore removes consensus as a validity mechanism and makes intra-family
discrimination a first-class output. The instrument must reveal difference, not
collapse it into a family mean — the same anti-flattening stance the project applies
to productive contradictions.

## 2. Invariants

The body states invariants. Mechanism choices are deferred to §Backlog so that
reviewers evaluate *what must hold*, not *how it is built*.

- **INV-1 (Discrimination above noise).** Any reported difference between two models
  must exceed the instrument's own run-to-run variation for the lineup under test.
  A difference the instrument cannot reproduce is not a difference; it is noise, and
  must be reported as indistinguishable rather than ranked.

- **INV-2 (Calibration validity).** The self-calibration signal must reflect
  confidence-to-correctness alignment, not agreement with peers and not the absence
  of difficulty. A calibration verdict must be obtainable only on material where a
  model genuinely could be wrong; a verdict produced where no model could be wrong
  carries no metacognitive information and must not be scored as if it did.

- **INV-3 (Weight ≤ residual discriminating power, without circularity).** No
  component may contribute more to a model's standing than the discriminating
  information that component actually carried in the run. This must be achieved
  without making the weights themselves a function of the per-run outcome — weights
  stay fixed across runs for comparability, and a component that carried no
  discriminating information in a given run is neutralized by *reporting its
  saturation*, not by silently re-weighting it.

- **INV-4 (Saturation is surfaced, not hidden).** For every reported equivalence the
  instrument must state which of two cases holds: the models are genuinely equivalent
  on this axis (valid result, low sensitivity), or the instrument could not tell them
  apart (invalid for this lineup on this axis). An unlabelled equivalence is a defect.

- **INV-5 (Self-referential integrity preserved).** Changes must not break the
  framework's self-referential commitments: the philosophy task interrogating the
  system's own propositions, and the principle that evaluating well is itself an
  exhibition of the capacity under test, must remain coherent.

- **INV-6 (No consensus-as-validity; independence-weighted aggregation).** Agreement
  among evaluators is evidence only to the extent the evaluators are independent.
  Correlated evaluators — paradigmatically same-family models — must not be treated
  as independent votes. Any aggregate that an evaluator contributes to must be
  discounted by that evaluator's measured correlation with the others, such that a
  family of N correlated evaluators cannot, by agreeing, outweigh independent signal.

- **INV-7 (Intra-family discrimination is first-class).** The instrument must be able
  to express, and must report, the differences among closely related models as a
  primary output — not as a residual of a ranking, and not averaged into a family
  aggregate. If two same-family models differ, the instrument must say in what and by
  how much; if it cannot, that is an INV-1 failure reported as such, not silence.

- **INV-8 (Cross-evaluator judging of within-family pairs).** When the difference
  being measured is within one family, the judging signal must come from outside that
  family wherever an outside judge exists. A model judging members of its own family
  is a conflicted judge; its verdict on such pairs is recorded but may not be the
  sole basis for an INV-7 difference claim.

- **INV-9 (Commensurable scales).** Scores or comparisons aggregated across providers
  must be placed on a common scale before aggregation. Raw provider-native 0–10
  ratings are not assumed commensurable across families.

## 3. Open questions for round 2

1. **INV-6 vs INV-7 tension.** INV-6 discounts same-family agreement; INV-7 demands
   same-family *difference* be surfaced. Are these jointly satisfiable, or does
   discounting the family also suppress the within-family signal we want? State the
   condition under which both hold.
2. **INV-8 feasibility.** Cross-family judges (Codex/Cursor) judging Claude-family
   pairs assumes the outside judge is itself discriminating at that resolution. What
   if the only judge fine-grained enough to tell 4.8 from 4.7 *is* a Claude model?
   Does INV-8 then forbid the only usable signal?
3. **INV-2 redesign cost.** Moving calibration onto uncertainty-bearing material means
   the calibration task no longer doubles as a competence task. Is a dedicated
   calibration task acceptable, or does it break the "evaluation is the test" economy?
4. **INV-1 noise estimator.** Establishing run-to-run noise implies repetition or an
   analytic variance model. What is the minimum that makes INV-1 enforceable without
   multiplying run cost beyond practicality?
5. **Scope of consensus removal.** Does dropping consensus-as-validity also remove the
   existing multi-LLM-review-style convergence gate when this skill is used for ranking,
   or is the gate retained for a different purpose (e.g., quorum/liveness) while losing
   its validity role? Name what consensus is still allowed to mean.
6. **Missing invariant.** Name any invariant the v2.3 goal depends on that §2 omits.

## 4. §Backlog — mechanism candidates (NOT part of the invariant body)

Recorded so the body stays mechanism-free. Selection deferred to implementation phase.

- Within-family forced-choice pairwise comparison (A-vs-B "which is better, in what")
  in place of absolute 0–10 scoring, to break score compression and expose fine deltas.
- Correlation matrix over evaluators → independence weights for INV-6; family grouping
  as the prior, measured correlation as the correction.
- Per-run saturation flag and noise band emitted into the Prop 6 incompleteness report
  (INV-4 / INV-1); requires defining that report's interface.
- Dedicated uncertainty-bearing / partially-unsolvable calibration item for INV-2.
- Anchor/scale-normalization pass for INV-9 (shared reference responses across providers).
- Decision on retaining vs retiring the with-/without-Nomic weight vectors once INV-3
  is satisfied by saturation-reporting rather than re-weighting.

## 5. Non-goals

- Not specifying code, file paths, method names, or report schemas — design phase only.
- Not selecting among §4 mechanisms — invariants first, mechanisms after convergence.
- Not re-litigating v2.2's prior-version rationale except where round-1 (a) findings require it.
