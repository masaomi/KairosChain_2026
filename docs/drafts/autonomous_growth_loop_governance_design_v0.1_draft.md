# Autonomous Growth Loop — Governance Design

**Version:** v0.1 draft
**Date:** 2026-07-03
**Author:** Masaomi Hatakeyama (with Claude Fable 5)
**Status:** DRAFT — for multi-LLM review round 1
**Layer:** SkillSet-level design (design-by-invariant applies)

---

## 1. Purpose and scope

KairosChain gains an unattended growth loop: cycles that select their own
task, execute it through an external body (an LLM agent harness), verify the
outcome, record it constitutively, and continue or stop — without a human
present at each step.

This document specifies the **governance invariants** such a loop must
satisfy. It does not specify mechanisms. Mechanism candidates are listed in
the non-normative backlog (§6) and are decided at implementation time.

In the loop taxonomy of L1 `loop_engineering_patterns` §A, this is the
**Autonomous** type (trigger: schedule/event; no human present), whose home
is the gem/SkillSet layer, bound by the Prop 10 procedural floor as a
cross-cutting constraint. The source taxonomy's "run until disabled, no
human present" is deliberately not adopted verbatim; the deltas are the
substance of this design.

Out of scope: sub-agent fan-out (harness-layer concern), scheduling
mechanics (existing harness and body facilities suffice), and the skill
lifecycle after promotion (covered by existing evolution rules).

## 2. Position in the existing structure

Three prior results constrain and motivate this design:

- The existing agent loop already exceeds naive autonomy in safety
  (checkpoints, drift detection, risk budgets) but is structurally weak in
  exactly one place: **verification**. Its reflection phase judges success
  from the acting LLM's own narrative; its termination is resource-count
  plus safety gates, with a confidence-based early exit whose input is that
  same unverified narrative; its per-cycle progress records are written but
  not read back. (L2 analyses, 2026-06-10 and 2026-06-21, converge on this
  single gap from independent external sources.)
- A working precedent exists for the recording half: a cycle wrapper proven
  on 2026-07-03 executes a task through an external body and records the
  cycle's *actual* resource consumption from the body's own ground-truth
  store, bypassing the LLM entirely. The pattern — mechanical observation
  over self-report — generalizes from cost to outcome, and this
  generalization is the core move of the present design.
- Validation criteria themselves must remain evolvable. Hard-coding "what
  counts as good" into infrastructure would break structural
  self-referentiality; the criteria belong at the same layer as other
  evolvable capabilities.

## 3. Invariants

Each invariant is stated once, followed by a single prose justification.

### INV-1 — Evidence-grounded judgment

*No cycle's success or failure is judged from the acting LLM's self-report
alone. Every verdict consumes evidence collected by mechanical observation
outside the acting LLM's narrative.*

An agent that grades its own homework from its own account of the homework
cannot close a learning loop; this is the single structural gap both
external analyses identified. The 2026-07-03 precedent shows the pattern is
implementable and cheap: ground truth read from the substrate, zero LLM
tokens. What counts as admissible evidence for a given goal is declared
before the run, not improvised by the acting session.

### INV-2 — Dual stop floor

*Every unattended run has both (a) a semantic exit: a judgment against
achievement criteria declared before the run, consuming only INV-1
evidence, and (b) hard resource ceilings declared before the run. Neither
alone is a sufficient stop condition; exhaustion of (b) is a recorded stop,
never a silent one.*

Resource-only termination wastes the loop's purpose (it stops working, not
when done); semantic-only termination is unbounded liability when the judge
errs. The ordering dependency is deliberate: a semantic exit fed by
unverified confidence risks confident-but-wrong termination, which is why
INV-1 precedes INV-2 in implementation order. A stop is a Kairos moment
(Prop 5): it is recorded with its reason, not merely reached.

### INV-3 — Progress continuity

*Each cycle's orientation input includes the recorded outcomes of prior
cycles in the same run. Progress records are write-and-read, not
write-only.*

Without read-back, an N-cycle run is N independent one-cycle runs that
happen to share a goal; nothing learned in cycle k can prevent cycle k+1
from repeating it. The write side already exists; this invariant makes the
read side a condition of the loop rather than an optimization.

### INV-4 — Goal provenance

*Every autonomously generated goal carries recorded provenance naming its
source, and is admissible only from sources declared to the run. A goal
without provenance is rejected before execution.*

Self-selected work is where an autonomous system's values become visible.
Provenance makes goal selection contestable after the fact (Prop 10(b)) and
auditable during the run; the declared-sources restriction keeps the goal
space inside what the human operator consented to when starting the run.

### INV-5 — Layer-scoped autonomy

*Unattended cycles may modify L2 freely and L1 under its existing
lightweight constraint. No unattended cycle applies an L0 change: anything
L0-touching is emitted as a proposal into a human-approval queue and the
cycle proceeds without it.*

This is the existing layer constraint table applied to a new actor, not a
new rule. The approval workflow already provides the queue's semantics;
autonomy changes who *proposes*, never who *approves*. The loop thereby
inherits the Prop 10 safety minima instead of re-implementing them.

### INV-6 — Constitutive cycle recording

*Before a run continues past any cycle, that cycle's actual resource
consumption and its INV-1 verdict are irreversibly recorded, both drawn
from mechanical sources.*

Recording is constitutive, not evidential (Prop 5): the recorded cycle is
what the next cycle's orientation consumes (INV-3), so an unrecorded cycle
did not happen, as far as the loop's own becoming is concerned. The cost
half of this invariant is already operational; the verdict half is new.

### INV-7 — Governance/body separation

*All invariants above are enforced at the governance layer and hold
regardless of which body executes the cycle. Body-specific mechanics are
adapters; no invariant's enforcement may live only inside a particular
body's configuration.*

Partial autopoiesis (Prop 2) closes the loop at the
governance/capability-definition level while executing on external
substrates. Bodies will change — the current one is one of several
candidates — and a governance property that dies when the body is swapped
was never a governance property.

### INV-8 — Revisable norms

*The loop's normative surface — achievement criteria, evidence
admissibility, evaluation rubrics, thresholds, goal-source declarations —
is expressed in revisable, recorded form at the same layer as other
evolvable capabilities, never hard-coded into infrastructure.*

A norm that cannot be contested from within is incompatible with the system
(Prop 10). Concretely this also serves evolution: the external analysis
that motivated this design observed that designing and monitoring
evaluation criteria is the enduring human role — that role needs a surface
to act on, and that surface must itself be under version control and
recording, or revising a norm becomes an unrecorded meta-change.

## 4. Relation to the Prop 10 floor

INV-4, INV-5, and INV-8 instantiate the floor's two clauses for this loop:
safety minima via layer scoping and consented goal sources; contestability
via provenance and revisable norms. INV-6 supplies the audit substrate both
clauses presuppose. The design adds no new floor semantics; it routes an
unattended actor through the floor that already binds attended ones.

## 5. Implementation phasing (non-normative)

One invariant cluster at a time, each independently shippable, in
dependency order: INV-1 first (evidence-grounded judgment), then INV-2
(semantic exit consuming INV-1 evidence), then INV-3 (read-back). INV-4/5
(goal admission and layer scoping) follow as the run graduates from
human-given goals to self-selected ones. INV-6's verdict half lands with
INV-1; INV-7/8 are enforced from the first slice by placement choices
rather than by new code.

## 6. Backlog (non-normative mechanism candidates)

Recorded so the body of this design stays mechanism-free:

- Evidence collectors: test execution results, working-tree diffs, the
  existing introspection and drift-detection tools, substrate ground-truth
  stores.
- Semantic exit: wiring the existing declared-but-unwired confidence
  threshold; goal records gaining an achievement-criteria field; a
  single-judge comparison as a lighter sibling of multi-LLM review.
- Goal sources: audit-gap reports, drift detection, the dream-proposal
  path, the PDCA review skill's Act output.
- Norm surface: an evaluation-rubric skill evolvable via the standard
  skill-evolution path (keystone analysis candidate B).
- Body adapters: the proven cycle wrapper for the current body; the paused
  tmux-based adapter design as a second body; harness-level scheduling for
  the time trigger.
- L0 proposal queue: reuse of the existing approval workflow's pending
  state.

## 7. Review guidance

Findings are classified per the project's (a)/(b)/(c) taxonomy. The
question this design puts to reviewers: do the eight invariants close the
governance surface of an unattended growth loop, or is there a class of
unattended failure they do not cover? Mechanism-level objections belong to
§6, not the body.
