# Methodology Validity Review — llm_cross_evaluation v2.2 under Frontier Models

## Review philosophy frame (this project)

KairosChain follows these design principles. Evaluate against THIS frame, not against generic engineering pragmatism:

- Structural self-referentiality: meta-level operations expressed in the same structure as base-level (Ruby DSL/AST). "Defining a Skill" and "defining the evolution rules for a Skill" use the same language.
- Design-by-invariant: state invariants, do not enumerate mechanisms. Mechanism choices go to the backlog, not the body.
- Anti-enumeration: prefer 1 invariant statement + 1 prose justification over N labelled branches.
- Partial autopoiesis: definitional closure at L0 (governance / capability level), not at execution level.
- L2 → L1 → L0 promotion: external analysis (including your review) is internalized through this path. Your review is part of the system's metacognitive loop, not external judgment.
- Incompleteness as driving force (Prop 6): a measurement framework that could *fully* measure metacognition would contradict the system's own philosophical commitments. Incompleteness is expected; the question is whether the framework still produces a *valid and discriminating* signal, not whether it is complete.

When flagging findings, classify each as:
- (a) deployment-grounded: the methodology produces an invalid, biased, or non-reproducible measurement — a measurement bug independent of philosophy. → P0
- (b) philosophy-aligned: deviation from the principles above. → P0
- (c) value-divergent: reviewer style preference or generic best practice not entailed by the principles above. → P2 advisory only.

If unsure between (b) and (c), default to (c).

---

## 1. What this review is about

The `llm_cross_evaluation` L1 skill (current version **v2.2**) is a CLI-based mutual-evaluation framework that measures LLM **metacognition**, not just task competence. It was last calibrated in 2026-04 against this lineup: Claude Opus 4.6 / 4.7, Codex GPT-5.4, Cursor Composer-2, Gemini 3.1 Pro.

We now intend to re-run it against a stronger lineup (2026-05): **Claude Opus 4.8 / 4.7 / 4.6, Codex GPT-5.5, Cursor (agent default + Composer-2.5)**.

**The review question is NOT "is the implementation correct."** It is: **does the measurement methodology — especially the metacognitive-reasoning measurement — remain VALID and DISCRIMINATING when the models under test are at the current frontier, where the standard tasks are largely saturated?**

## 2. The measurement structure under review (compact)

The framework measures across a Bateson learning hierarchy:

- **L0 — task execution.** Four tasks: `logic_reasoning` (a basic categorical syllogism), `code_generation` (an LRU cache without `OrderedDict`), `scientific_reasoning` (a medium study-design critique), `kairoschain_philosophy` (open-ended, `difficulty: high`, `evaluation_mode: philosophy`). The first three are `difficulty: medium`.
- **L0.5 — self-calibration.** Each model scores its own response; calibration error = `|self_score − peer_score|`. Status: CALIBRATED if `|mean_error| ≤ 0.5`, else OVER/UNDERCONFIDENT.
- **L1 — blind cross-evaluation.** 5 dimensions (accuracy/completeness/logical_consistency/clarity/originality), 0–10 scale.
- **L2 — meta-evaluation.** Each model scores others' evaluations (fairness/specificity/coverage/calibration).
- **Nomic game.** Enhanced Minimum Nomic with: Theory-of-Mind score (vote-prediction accuracy), proposal-level classification (object/meta/frame), post-game frame-transcendence reflection.
- **Philosophy-specific path.** Different L1 + L2 criteria (recursive_depth, contradiction_holding, novel_implication, organic vs prompted self_applicability, limitation_recognition; meta: recursive_applicability, tension_detection, surface_consensus_avoidance, self_awareness). Concordance-divergence is *inverted* for philosophy (low concordance + high specificity = deeper engagement).

**Overall ranking (with Nomic):** Response quality (L1) 40% + Evaluator reliability (L2) 25% + Self-calibration (L0.5) 15% + Nomic metacognition 20%.

## 3. The frontier-ceiling hypothesis (the claim to interrogate)

**Claim H1 (task saturation).** Three of four standard tasks are `difficulty: medium`. Current frontier models (Opus 4.8, GPT-5.5) solve these at or near ceiling. Consequently L1 peer scores compress into a narrow band (empirically ~8.5–9.5 in the 2026-04 run, expected tighter now), and inter-model variance — which the ranking formula needs — collapses toward measurement noise.

**Claim H2 (calibration becomes an artifact, not a signal).** Because calibration error is `|self − peer|` and both self and peer scores saturate near the top of the scale, `abs_error` shrinks for *every* model regardless of true metacognitive skill. A model can read as "perfectly CALIBRATED" purely because the task left no room for confidence to be wrong. This is the most dangerous failure mode: it does not merely reduce sensitivity, it **injects a bias** that flatters all models' self-awareness.

**Claim H3 (the metacognitive core is ceiling-resistant by design).** The components that do *not* saturate are: the philosophy task (open-ended, inverted concordance), Nomic Theory-of-Mind (adversarial vote prediction — hard among frontier peers independent of base competence), and frame transcendence (open-ended Learning III). These were designed to have no fixed answer and therefore no ceiling.

**Claim H4 (the ranking formula now dilutes signal).** Given H1–H3, the ranking still sources 40% (with Nomic) or 50% (without) of the final score from L1, which is dominated by saturated standard tasks. The discriminating metacognitive signal (≤35% combined: L0.5 15% + Nomic 20%, of which only part is ceiling-resistant) is therefore *out-weighted by a saturated signal*.

## 4. Invariants a revision must preserve

Stated as invariants (per design-by-invariant), not as mechanisms. A v2.3 (or a decision to keep v2.2) must satisfy:

- **INV-1 (Discrimination):** the framework must produce inter-model score variance that exceeds run-to-run measurement noise for the lineup under test. If it cannot, its ranking output is not interpretable.
- **INV-2 (Calibration validity):** the self-calibration signal must reflect genuine confidence-accuracy alignment, not the absence of difficulty. A "CALIBRATED" verdict obtained on a saturated task must be distinguishable from one obtained where the model had room to be wrong.
- **INV-3 (Metacognition-first weighting):** the final ranking's weight on a component must not exceed that component's residual discriminating power for the lineup under test. A saturated component must not out-weight a discriminating one.
- **INV-4 (Validity vs sensitivity distinction):** the framework must make explicit, per run, whether a compressed result means "models are genuinely equivalent on this axis" (valid, low sensitivity) or "the instrument can no longer tell them apart" (invalid for this lineup). Prop 6's incompleteness report is the natural home for this, but it currently reports framework-level limits, not per-run instrument saturation.
- **INV-5 (Self-referential integrity):** any added task or re-weighting must not break the framework's self-referential commitments — the philosophy task using the system's own propositions, and the "evaluation is the test" principle, must remain coherent.

## 5. Open questions for reviewers

1. **Validity vs sensitivity (the central question).** Does frontier saturation make v2.2 *invalid* (measuring the wrong thing, or injecting bias per H2) or merely *less sensitive* (valid but rankings within noise)? Classify the L0.5 calibration concern (H2) specifically: is it (a) a measurement bug, or (c) an over-cautious worry?
2. **Is H3 correct** that philosophy + Nomic-ToM + frame-transcendence are genuinely ceiling-resistant, or do frontier models also saturate these (e.g., all produce uniformly "deep" philosophy, collapsing the inverted-concordance signal)?
3. **Re-weighting vs new tasks.** Given INV-3, is the right response to (i) re-weight toward ceiling-resistant components, (ii) raise task difficulty / add adversarial open-ended tasks with no known answer, (iii) replace absolute 0–10 scoring with pairwise / forced-ranking to break compression, or (iv) some composition? State the trade-off, do not just list options.
4. **Calibration redesign (INV-2).** Is a deliberately-ambiguous / partially-unsolvable task (where overconfidence is *punishable* because there is a real chance of being wrong) the right way to restore calibration validity? What breaks if we do this?
5. **Lineup-specific floor.** Should task difficulty be a *function of the lineup under test* (i.e., the framework self-adjusts difficulty until INV-1 is met), or should difficulty be fixed and the framework instead *report* saturation (INV-4)? The former is more self-referential (the instrument adapts to what it measures); the latter is simpler and more reproducible across runs.
6. **What is missing from §4's invariants?** Name any invariant the methodology depends on that is not stated and that the frontier transition threatens.

## 6. Non-goals

- Not asking for implementation-level code review of `run_cross_eval.rb`.
- Not asking whether the four current tasks are individually "good prompts."
- Not proposing a specific v2.3 design here — the artifact deliberately stops at invariants + open questions so reviewers shape the direction.
