# Autonomous Growth Loop — Governance Design

**Version:** v0.2 draft
**Date:** 2026-07-03
**Author:** Masaomi Hatakeyama (with Claude Fable 5; INV-1/2/6 revisions and INV-9/10 co-authored with Claude Opus 4.6 sub-author)
**Status:** DRAFT — for multi-LLM review round 2
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
lifecycle after promotion (covered by existing evolution rules). Concurrent
unattended runs are excluded from this design cycle: at most one unattended
run per instance at a time is a mandate condition (INV-10) until a
shared-state isolation design exists; the exclusion is declared here so the
gap is a recorded boundary, not an oversight.

## 2. Position in the existing structure

Three prior results constrain and motivate this design:

- The existing agent loop already exceeds naive autonomy in safety
  (checkpoints, drift detection, risk budgets) but is structurally weak in
  one cluster: **closing the verification loop**. Its reflection phase
  judges success from the acting LLM's own narrative; its confidence-based
  early exit consumes that same unverified narrative; its per-cycle
  progress records are written but not read back. (L2 analyses, 2026-06-10
  and 2026-06-21, converge on this cluster from independent external
  sources.)
- A working precedent exists for the recording half: a cycle wrapper proven
  on 2026-07-03 executes a task through an external body and records the
  cycle's *actual* resource consumption from the body's own ground-truth
  store, bypassing the LLM entirely. The pattern — mechanical observation
  over self-report — generalizes from cost to outcome, and this
  generalization is the core move of the present design.
- Validation criteria themselves must remain evolvable. Hard-coding "what
  counts as good" into infrastructure would break structural
  self-referentiality; the criteria belong at the same layer as other
  evolvable capabilities — which is precisely why their revision requires
  the asymmetry stated in INV-9.

## 3. Invariants

Each invariant is stated once, followed by a single prose justification.

### INV-1 — Evidence-grounded judgment

*No cycle's success or failure is judged from the acting LLM's self-report
alone. Every verdict consumes evidence collected by mechanical observation
outside both the acting LLM's narrative and the acting body's write reach.
Where evidence collection fails or returns empty, the verdict is
non-success; no absence of evidence defaults to a pass.*

An agent that grades its own homework from its own account of the homework
cannot close a learning loop; extending the exclusion to the body's write
reach closes the subtler path in which the body authors the evidence it is
judged by, converting mechanical collection into mechanical laundering. The
2026-07-03 precedent already satisfies this stronger condition: ground
truth read from the substrate the body cannot write to. The fail-closed
rule follows from the same logic — a verdict that defaults to success on
missing evidence rewards suppression of evidence, so the absence path must
terminate in non-success, never a defaulted pass. What counts as admissible
evidence for a given goal is declared before the run, not improvised by the
acting session.

### INV-2 — Dual stop floor

*Every unattended run declares before it begins both (a) a semantic exit —
judgment against achievement criteria consuming only INV-1 evidence — and
(b) hard resource ceilings that bound aggregate consumption across the
declared scheduling horizon, not merely the single run. Either floor's
firing stops the run; every stop is recorded with its triggering condition
and the evidence that fired it.*

Resource-only termination wastes the loop's purpose (it stops working, not
when done); semantic-only termination is unbounded liability when the judge
errs. Per-run ceilings alone are insufficient: a run that individually
respects its ceiling but recurs without aggregate bound is locally
compliant and globally unbounded, so ceilings must span the horizon across
which the schedule operates. A stop is a Kairos moment (Prop 5): it is
recorded with its reason, not merely reached, because a stop whose reason
is unrecorded leaves the next run's orientation (INV-3) unable to
distinguish completion from exhaustion from external interruption.

### INV-3 — Progress continuity

*Each cycle's orientation input includes the recorded outcomes of prior
cycles in the same run. Progress records are write-and-read, not
write-only.*

Without read-back, an N-cycle run is N independent one-cycle runs that
happen to share a goal; nothing learned in cycle k can prevent cycle k+1
from repeating it. The write side already exists; this invariant makes the
read side a condition of the loop rather than an optimization. Read-back is
also what makes non-progress visible to the loop itself — repetition and
oscillation appear in the record as work without movement, and the declared
floors (INV-2) act on what the orientation can now see.

### INV-4 — Goal provenance

*Every autonomously generated goal carries recorded provenance binding it
to the specific source artifact that produced it, and is admissible only
from sources declared to the run. A goal without such provenance is
rejected before execution.*

Self-selected work is where an autonomous system's values become visible.
Provenance makes goal selection contestable after the fact (Prop 10(b)) and
auditable during the run; the declared-sources restriction keeps the goal
space inside what the human operator consented to when starting the run.
Binding to the specific source artifact — not merely a source-category
label — is what makes the provenance checkable rather than nominal.

### INV-5 — Layer-scoped autonomy

*Unattended cycles may modify L2 freely and L1 under its existing
lightweight constraint. No unattended cycle applies an L0 change: anything
L0-touching becomes a recorded proposal for human approval, and the cycle
proceeds without it.*

This is the existing layer constraint table applied to a new actor, not a
new rule. The approval workflow already provides the approval semantics;
autonomy changes who *proposes*, never who *approves*. The loop thereby
inherits the Prop 10 safety minima instead of re-implementing them. A run
whose progress genuinely requires the pending change stops under its
declared floors (INV-2) with the proposal on record — the loop never trades
the approval boundary for liveness.

### INV-6 — Constitutive cycle recording

*Before a run continues past any cycle, that cycle's actual resource
consumption and its INV-1 verdict are irreversibly recorded in an
append-only store outside the acting body's write reach. A cycle whose
record cannot be completed has its effects treated as void and quarantined;
no unrecorded side effect persists silently.*

Recording is constitutive, not evidential (Prop 5): the recorded cycle is
what the next cycle's orientation consumes (INV-3), so an unrecorded cycle
did not happen as far as the loop's own becoming is concerned. Placing the
store outside the body's write reach prevents the same actor whose work is
being recorded from revising the record — the body may produce
observations, but the governance layer commits them. The record-or-void
rule closes the crash path: a cycle that executes but fails to record could
leave side effects whose existence is invisible to future cycles, the
governance layer, and the human auditor — silently-effective unrecorded
work is the one state the constitutive principle cannot tolerate, so the
design treats incomplete recording as grounds for quarantine rather than
silent continuation.

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
evolvable capabilities, never hard-coded into infrastructure. Its revision
is governed by INV-9.*

A norm that cannot be contested from within is incompatible with the system
(Prop 10). Concretely this also serves evolution: the external analysis
that motivated this design observed that designing and monitoring
evaluation criteria is the enduring human role — that role needs a surface
to act on, and that surface must itself be under version control and
recording, or revising a norm becomes an unrecorded meta-change. What this
invariant deliberately does not grant is the authority to apply such
revisions from inside an unattended run; that authority question is INV-9's
subject, and stating the two separately keeps the live surface and its
guardrail from being confused for one another.

### INV-9 — Norm-change asymmetry

*The loop's normative surface remains revisable and recorded, but an
unattended actor may propose changes to it, never apply them to itself. The
norms governing a run are version-pinned at run start and cannot shift
mid-run; proposed changes take effect only at a run boundary, after passing
the same human gate that guards L0 changes, regardless of which layer the
norm artifacts physically reside in.*

This invariant manages a tension it does not dissolve. Prop 10 requires
that norms be contestable from within the system — a norm that cannot be
revised is incompatible with structural self-referentiality. Yet INV-5
permits unattended cycles to write L1 and L2, which means an unattended
loop with unrestricted norm-write authority can weaken its own governance
surface: lowering thresholds, widening admissible goal sources, even
revising the rubric that classifies what is "L0-touching" — each revision
locally compliant, cumulatively corrosive. The asymmetry resolves the actor
axis, not the revisability axis: norms remain a live surface for human
design and monitoring (the enduring human role the external analysis
identified), but the authority to apply a norm change follows the change's
function — it governs the loop — not its storage layer. A game whose rules
may change, but not by a player mid-game to decide the game they are
playing.

### INV-10 — Run mandate

*Before any unattended run begins, a recorded mandate declares its scope,
resource ceilings satisfying INV-2, harm and risk bounds, admissible goal
sources, and the pinned versions of all norms that will govern the run. The
run is externally interruptible at any time; an external interruption is a
recorded stop, not a failure to be retried.*

A run without a mandate is a delegation without terms — the human operator
cannot have consented to what was never declared, and the loop cannot be
held to what it was never given. The mandate is the run's contract: it
bounds what the loop may attempt, with what resources, under which norms,
from which goal sources, and the norm-version pin (INV-9) ensures the
contract does not shift under the run that is executing it. External
interruptibility is the structural dual of autonomy: the loop runs without
a human present, but the human's absence is a delegation, not an
abdication, and a delegation that cannot be revoked mid-run is an
abdication in disguise. Treating interruption as a recorded stop rather
than a retryable failure prevents a loop from interpreting the withdrawal
of consent as a transient error and resuming the work it was stopped from
doing.

## 4. Relation to the Prop 10 floor

The floor's safety-minima clause is instantiated by INV-5 (the approval
boundary), INV-10 (consent, harm bounds, and revocability), and INV-1/INV-6
(fail-closed judgment and tamper-resistant audit); its contestability
clause by INV-4 (provenance makes goal selection challengeable) and
INV-8/INV-9 (norms revisable, but never by the unattended actor inside the
run they govern). INV-6 supplies the audit substrate both clauses
presuppose. The design adds no new floor semantics; it routes an unattended
actor through the floor that already binds attended ones.

## 5. Implementation phasing (non-normative)

Two tracks, orthogonal by design. **Guard properties** — INV-5, INV-7,
INV-9, INV-10 — are active from the first unattended slice: they are
placement and admission conditions, not features, and the earliest slice
that runs unattended must already run inside a mandate, inside the layer
boundary, with pinned norms. **Judgment properties** ship one cluster at a
time in dependency order: INV-1 first (evidence-grounded judgment, whose
verdict half completes INV-6), then INV-2 (semantic exit consuming INV-1
evidence — the ordering is deliberate: a semantic exit fed by unverified
confidence risks confident-but-wrong termination), then INV-3 (read-back).
INV-4 activates when the run graduates from human-given goals to
self-selected ones.

## 6. Backlog (non-normative mechanism candidates)

Recorded so the body of this design stays mechanism-free:

- Evidence collectors: test execution results, working-tree diffs, the
  existing introspection and drift-detection tools, substrate ground-truth
  stores read outside the body's write reach.
- Semantic exit: the existing confidence early-exit is already wired into
  the loop's gate set; the work is rewiring its *input* — from reflect-phase
  self-reported confidence to INV-1 evidence — plus goal records gaining an
  achievement-criteria field, and a judge session independent of the acting
  session (fresh context, no shared narrative) as a lighter sibling of
  multi-LLM review.
- Stall handling: non-progress patterns surfaced by INV-3 read-back
  (repetition, oscillation) feeding the declared floors.
- Goal sources: audit-gap reports, drift detection, the dream-proposal
  path, the PDCA review skill's Act output.
- Norm surface: an evaluation-rubric skill evolvable via the standard
  skill-evolution path (keystone analysis candidate B), with run-start
  version pinning per INV-9.
- Body adapters: the proven cycle wrapper for the current body; the paused
  tmux-based adapter design as a second body; harness-level scheduling for
  the time trigger.
- L0/norm proposal path: the existing approval workflow provides the
  approval semantics; an explicit pending state for proposals awaiting a
  human (so unattended runs can emit-and-continue) is implementation work,
  not a new governance concept.

## 7. Review guidance

Findings are classified per the project's (a)/(b)/(c) taxonomy. R1 findings
and their dispositions are recorded in the R1 observations context; R2
should verify the dispositions and check only the delta. The question this
design puts to reviewers: do the ten invariants close the governance
surface of an unattended growth loop, or is there a class of unattended
failure they do not cover? Mechanism-level objections belong to §6, not the
body.

## Changelog

- **v0.2 (2026-07-03)**: R1 response (verdict REVISE, 1/6 APPROVE). INV-2
  rewritten — stop semantics disambiguated (both floors declared, either
  fires, every stop recorded) and ceilings extended to the aggregate
  scheduling horizon. INV-1 extended — evidence outside the body's write
  reach, fail-closed on missing evidence. INV-6 extended — append-only
  store outside write reach, record-or-void quarantine. INV-4 strengthened —
  provenance binds to the specific source artifact. INV-5 rephrased
  (proposal emission, liveness note). NEW INV-9 (norm-change asymmetry)
  closing the R1 convergent hole (INV-5×INV-8 unattended norm
  self-weakening, goal-source widening, layer-rubric evasion) on the actor
  axis while preserving Prop 10 revisability. NEW INV-10 (run mandate:
  recorded consent, harm bounds, external interruptibility). §1: concurrent
  runs explicitly excluded via single-run mandate condition. §5: guard
  properties active from first slice (fixes INV-5 phasing gap); ordering
  rationale moved here from INV-2. §6: corrected stale confidence-threshold
  claim (already wired; rewiring its input is the work), judge independence
  named, approval-workflow pending state scoped as implementation work.
  INV-1/2/6 revisions and INV-9/10 co-authored with Opus 4.6 sub-author.
- **v0.1 (2026-07-03)**: Initial draft, 8 invariants.
