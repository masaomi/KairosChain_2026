# llm_cross_evaluation v2.3 — Design Draft v0.3

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

## 0. What v0.3 resolves from round 3 (verification map)

Round 3 reached 4 APPROVE / 1 REJECT (the lone REJECT being the documented Codex legalistic-waterfall pattern, both its P0s rated P1/P2 by the other four reviewers). v0.3 closes the one genuine residual and the real polish items:

- **INV-8(ii) control-pair bootstrapping** (cited P1 by three reviewers — the one true residual) → resolved in body by the coarse-to-fine control principle: a judge's fine-grained resolution is verified against pairs whose difference is established *independently of the instrument's own fine judgment*, paradigmatically a known generational gap. Cold-start is no longer blocked; circularity is bounded by INV-1.
- **INV-6 logical bug** (shared prompt/rubric disqualifies *all* agreement, since every evaluator shares them by construction) → fixed: the disqualifier is a shared *cause of judgment tendency* (training lineage), not the shared task material.
- **INV-7 amplification had no ceiling** → bounded: a within-family difference is treated as higher-information only above INV-1's noise floor; below it, it is noise. Weighting-operation language removed.
- **INV-3 aggregate standing could be misread as a ranking** → guarded: standing carrying saturated components may not be consumed as a difference/ranking claim and must be labelled accordingly.
- **"Component" undefined / lineup not pinned / Prop 6 report only in backlog** → added Definitions, INV-4 now mandates a per-run limits report, INV-10 pins and records lineup identity.
- §3 no longer invites ad-hoc invariant discovery; it lists only residuals deliberately deferred to implementation.

This summary is meta; the Definitions and invariants below are the artifact.

## 1. What v2.3 changes and why

v2.2 measures LLM metacognition via L0/L0.5/L1/L2 + Nomic. Round-1 review established three deployment-grounded validity failures under frontier models: self-calibration became a saturation artifact, the calibration status metric was internally contradictory, and the ranking overweighted a discrimination-dead component.

Two facts drive v2.3:

1. **The target lineup is family-skewed.** Opus 4.8 / 4.7 / 4.6 + Codex GPT-5.5 + Cursor places three same-family models among the evaluators. Mutual evaluation assumes evaluator independence; same-family judgments share a common cause, so any consensus-weighted output counts one family's bias as several independent votes.

2. **The measurement goal has shifted.** The question is no longer "which model wins by peer consensus" but "what are the *differences among closely related models* (4.8 vs 4.7 vs 4.6), which consensus-aggregation erases."

The central design move: **near-kinship is reframed from a liability into an instrument.** When two same-family models differ, the shared training substrate is held constant, so the difference isolates the version delta. v2.3 discounts family *agreement* (it may be shared bias) while treating family *difference* as version-isolated signal. Consensus is removed as a validity mechanism; intra-family difference becomes a first-class output.

## 2. Definitions

These fix the referents the invariants quantify over; they are not themselves invariants.

- **Component** — a distinct measured channel whose saturation and discrimination are assessed on its own: a (task × criterion) axis, a judge, or a measurement layer.
- **Lineup** — the pinned set under test: model identities and versions, the judge roster, and the protocol revision. Recorded per run (INV-10).
- **Family / near-kin** — models sharing training lineage (the common cause INV-6 is concerned with).
- **Noise floor** — the instrument's established run-to-run variation for a pinned lineup, below which no difference is claimable (INV-1).

## 3. Invariants

The body states invariants; all mechanism choices are in §Backlog.

- **INV-1 (Discrimination above noise).** No difference between two models may be claimed unless it exceeds the established noise floor for the pinned lineup. Where no noise floor has been established, the output is "indistinguishable," never a ranking.

- **INV-2 (Calibration validity).** Self-calibration must reflect confidence-to-correctness alignment, not agreement with peers and not the absence of difficulty. A calibration verdict is informative only on material where a model genuinely could be wrong; a verdict obtained where no model could be wrong carries no metacognitive information and must not be scored as if it did.

- **INV-3 (Standing and difference claims are distinct; saturation gates difference claims without re-weighting standing, and standing is never read as a ranking).** A model's aggregate standing and a claim that one model differs from another must not be conflated. Standing uses weights fixed across runs for comparability. A difference or ranking claim may rest only on components that carried discriminating information in that run; a saturated component still enters the fixed aggregate but may not ground any difference claim, and that exclusion must be stated. Because standing may carry saturated components, standing may not itself be consumed as a difference or ranking claim; where it is surfaced it must be labelled as not-a-ranking.

- **INV-4 (Saturation and limits are surfaced, not hidden).** For every reported equivalence the instrument must state which case holds: genuine equivalence (valid, low sensitivity) or non-discrimination (invalid for this lineup on this axis). Each run must emit a limits report naming every saturated component and every claim left unresolved. An unlabelled equivalence, or a run with no limits report, is a defect.

- **INV-5 (Self-referential integrity preserved).** Changes must not break the framework's self-referential commitments: the philosophy task interrogating the system's own propositions, and the principle that evaluating well is itself an exhibition of the capacity under test, must remain coherent.

- **INV-6 (Agreement is evidence only in proportion to independence; consensus is never validity).** Agreement among evaluators counts as evidence of validity only to the degree the evaluators are independent. Independence is broken by a shared *cause of judgment tendency* — paradigmatically shared training lineage — not by the task material every evaluator necessarily shares; using the same prompt and rubric is the experiment, not a confound. Evaluators with a shared cause do not provide independent agreement, and their concurring judgments must not be counted as multiplied evidence. Consensus, by itself, is never a validity signal.

- **INV-7 (Intra-family difference is first-class, above the noise floor).** The instrument must express and report differences among near-kin as a primary output — not as a residual of a ranking, not averaged into a family aggregate. Within-family agreement is discounted (INV-6); a within-family difference *that exceeds the noise floor* (INV-1) carries more information than an equally sized difference between unrelated models, because the held-constant shared substrate isolates the version delta, and the instrument must neither discard nor average it away. A within-family difference at or below the noise floor is noise, not signal, and receives no such treatment. If two same-family models differ above the floor, the instrument must state in what and by how much; if it cannot, that is an INV-1 outcome reported as such, not silence.

- **INV-8 (Difference-claim admissibility).** A claim that one model differs from another is admissible only if all of the following hold; otherwise the difference is reported unresolved (INV-4), never asserted on insufficient evidence:
  - (i) *Blinded.* Judging is blind to which model authored which output; identity leakage that lets a judge attribute outputs invalidates the claim.
  - (ii) *Resolution-verified, bootstrapped coarse-to-fine.* A judge may ground a fine difference claim only if its discrimination at that grain is verified against control pairs whose difference is established independently of the instrument's own fine judgment — paradigmatically pairs separated by a known generational gap, which serve as coarse controls. A judge that cannot resolve a known-coarse difference may not adjudicate a finer one. The control's difference must never depend on the same fine judgment under test (no circularity).
  - (iii) *Conflict-controlled.* A model judging members of its own family is conflicted; beyond (i) and (ii) its within-family verdict may not be the sole basis of a claim. Where no unconflicted, sufficiently resolved judge exists, the claim rests on an out-of-family judge or is reported unresolved — the absence of a fine-enough judge is itself a reportable outcome, not a licence.
  - (iv) *Consistent.* Pairwise difference claims over three or more models must be globally consistent; an intransitive set (A≻B≻C≻A) is reported indeterminate, not resolved by aggregation.
  - (v) *Commensurable.* Comparisons aggregated across providers must share at least an ordinal scale; provider-native cardinal ratings are not assumed comparable across families, so aggregation uses rank/preference information where only ordinal comparability holds.

- **INV-9 (Consensus may keep a process role, never a validity role).** Consensus may be retained for process purposes (quorum, liveness, scheduling) but carries no evidential weight toward correctness, and any such use must be labelled process-only.

- **INV-10 (Lineup is pinned and recorded).** Every run records its lineup — model identities and versions, judge roster, protocol revision. A noise floor (INV-1) and a saturation report (INV-4) are meaningful only relative to a pinned lineup; results from different lineups are not comparable unless the lineup record establishes the comparison is valid.

## 4. Residual items deferred to implementation (not design-blocking)

- Cost floor of blinded, resolution-verified, repeated judging at 4.8-vs-4.7 grain — a tuning question, bounded by INV-1/INV-8, settled empirically in implementation.
- For the named lineup, fine within-family claims will lean on the out-of-family judges (Codex GPT-5.5, Cursor) being resolution-verified at that grain per INV-8(ii); whether they are is an empirical control-pair result, not a design gap.

## 5. §Backlog — mechanism candidates (NOT part of the invariant body)

- Within-family forced-choice pairwise comparison in place of absolute 0–10 scoring (serves INV-7, INV-8(v)).
- Evaluator correlation matrix → independence weighting for INV-6, family membership as prior, measured correlation as correction — applied to difference-claim evidence only, never to INV-3 standing weights.
- Identity-blinding and coarse-to-fine control-pair resolution checks for INV-8(i)/(ii); generational-gap pairs as coarse controls.
- Cycle detection over pairwise claims for INV-8(iv).
- Per-run noise-floor estimator (repeat trials or analytic variance) for INV-1; limits report emitted per INV-4.
- Dedicated uncertainty-bearing / partially-unsolvable calibration item for INV-2.
- Decision on retaining vs retiring the with-/without-Nomic weight vectors once INV-3 is satisfied by gating rather than re-weighting.

## 6. Non-goals

- Not specifying code, file paths, method names, or report schemas — design phase only.
- Not selecting among §5 mechanisms — invariants first, mechanisms after convergence.
- Not re-litigating v2.2's prior-version rationale except where round-1/2/3 (a) findings require it.
