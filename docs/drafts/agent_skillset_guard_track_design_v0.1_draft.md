---
name: agent_skillset_guard_track_design
title: "Agent SkillSet Guard Track — structural confinement and mechanical acceptance for the in-instance cognitive loop"
version: 0.1
status: DRAFT (pre-review)
date: 2026-07-10
layer_target: L1 design (instance-local); implementation lands in the agent SkillSet (plugin level, not L0 core)
parent: governed_loop_orchestration_invariants v0.3 (FROZEN_planB)
related:
  - governed_loop_orchestration_invariants (boundary invariants, attended pattern)
  - loop_validation L1 (fail-closed mechanical verdict discipline)
  - autonomous_growth_loop SkillSet (external-body guard track: layer guard, admission, enactment, OS confinement)
tags: [agent-skillset, guard-track, design-by-invariant, confinement, mechanical-acceptance, ooda]
---

# Agent SkillSet Guard Track — design v0.1

## 1. Frame and scope

The agent SkillSet runs a governed OODA loop *inside* a KairosChain instance:
the trusted orchestration side (the loop driver, its policy gates, mandate
accounting, and record-writing) lives in the instance's own runtime, and the
ACT of a cycle is either performed in-process through governed tool execution
or delegated to an external executor process.

The external-body guard track (hermes) established, and dogfooding validated,
a set of boundary invariants for governed loops (the parent document). Those
invariants describe a system whose executor is context-blank, confined, and
structurally unable to write the record. The agent SkillSet today satisfies
some of these properties by construction, others only by policy or by
accident of configuration, and two not at all.

This design closes that gap. It is deliberately split into two slices:

- **Slice 1 — harden the existing executor path.** Keep the current external
  executor substrate; add the two missing structural properties (record-write
  confinement; pre-pinned mechanical acceptance) and make the
  currently-accidental properties explicit and probed.
- **Slice 2 — native body.** Introduce an executor substrate implemented in
  the instance's own language and packaged in the same structure as every
  other capability (a SkillSet), satisfying the identical invariants. Slice 2
  changes the substrate, not the boundary: no invariant is added, weakened,
  or re-interpreted by the substitution.

The confinement work of Slice 1 is the floor Slice 2 stands on; nothing in
Slice 1 is discarded by Slice 2.

**In scope:** the boundary between the agent loop's trusted side and its
executor; the acceptance judgment of an ACT; admission of layer-touching
writes that originate from an agent decision.

**Out of scope:** the loop's existing policy gates (termination, drift,
budgets, complexity-driven review, checkpointing) — they remain as they are,
*above* this guard track; unattended operation (explicitly not claimed, as in
the parent); the L2→L1→L0 promotion path itself; multi-agent composition.

## 2. Roles (specialization of the parent)

The parent's roles map onto the agent SkillSet as follows:

- **Executor**: the process that performs the ACT of a cycle when the act is
  delegated outside the trusted runtime. Untrusted with respect to the
  record. (Slice 1: the current external CLI substrate; Slice 2: the native
  body. The role, and every invariant bound to it, is substrate-independent.)
- **Boundary**: the loop driver inside the instance runtime (which
  translates the decision into an executor task, curates what crosses,
  sequences cycles, and writes records), together with the human at
  checkpoints.
- **Independent verifier**: the party that authors the acceptance
  specification for an ACT before the act runs. Never the executor; and for
  the judgment that gates the cycle, never the same model invocation that
  produced the decision under judgment.

One structural fact distinguishes this system from the external-body loop and
motivates the entire design: **the trusted side and the deciding intelligence
share a runtime and a context.** The model that decides is invoked by the
boundary itself, so decision-making cannot be made context-blank. The
consequence is a narrowed trust claim, stated as a frame commitment:

> The guard track does not attempt to make the *decision* untrusted-safe; it
> makes the *act* and the *record* untrusted-safe. Whatever the deciding
> model proposes, (i) the act executes under structural confinement, (ii) its
> acceptance is judged against criteria the actor did not author, pinned
> before the act, and (iii) nothing reaches the record or governance layers
> except through the boundary's admission. The decision remains governed by
> the existing policy gates and by the human at checkpoints.

## 3. Current state, stated as properties

To make the delta reviewable without dragging implementation surface into the
body, the current state is summarized as which parent invariants hold and how.

| Parent invariant | Holds today? | How it holds (or fails) |
|---|---|---|
| INV-1 record-write authority boundary-only | **No** | The executor process runs in the project working tree with no substrate-level write restriction; the record store is reachable by ordinary file writes. Nothing but the task's own content prevents a write. |
| INV-2 knowledge crosses by copy/value | Partially | Context reaches the executor as values embedded in its task (curated summaries), which is the compliant channel. But the executor also has ambient read access to the live working tree, including the record store — a reference-shaped channel the parent excludes. |
| INV-3 executor holds only what the boundary gives | Partially | The executor starts context-blank as a process (scrubbed environment, restricted tool surface, resource ceilings) and receives boundary-curated context. But "only what the boundary gives" fails for the same ambient-read reason as INV-2. |
| INV-4 acceptance mechanical, pre-authored | **No** | The cycle's success judgment is a post-hoc self-assessment by a model invocation (a reflection step yielding a confidence value). No specification exists before the act; no deterministic check gates the cycle. |
| INV-5 actor never authors what judges it | **No** | The deciding invocation and the reflecting invocation are drawn from the same context and the reflection judges the act it helped produce. |
| INV-6 fail-closed | Partially | Timeouts, budget exhaustion, and executor failure halt or checkpoint the loop. But because no pinned specification exists, the "absence of a specification" branch of fail-closed is vacuous — absence is the normal case, and the loop proceeds. |

The two "No / No / No" rows — confinement and mechanical acceptance — are
Slice 1's substance. The "partially" rows are closed by the same two moves
plus explicit probing.

## 4. Invariants (AGT series)

These bind both slices. They specialize the parent; where a parent invariant
is restated it is because the agent-loop context sharpens it, not to fork it.

**AGT-1 — Executor writes are confined to a declared work area; the record is structurally unwritable.**
The executor process can write only within a work area declared per act by
the boundary. Writes outside it — in particular to the record and governance
stores — fail at the substrate level, not by convention or prompt. The
confinement is *probed*: the guard track includes a standing check that a
record-write attempt from executor position actually fails, so that the
property is observed, not assumed.
*Why:* this is the parent's INV-1 made local. In this loop the executor runs
in the same working tree as the instance, so "the executor doesn't write the
record" is currently a fact about model behavior, not about the system.
Moving it into the substrate converts the record's integrity from a policy
into a structural fact, which is the entire point of a guard track. The probe
exists because confinement that is configured but never exercised decays
silently.

**AGT-2 — What the executor can read is curated, and the record store is not readable from executor position.**
Knowledge reaches the executor as boundary-curated values in the task or
copies in its work area. The live record and governance stores are outside
its readable surface.
*Why:* parent INV-2/INV-3. Ambient read of the live store is a reference in
disguise: it lets an untrusted process observe (and, combined with any write
gap, race) governance state, and it silently widens what the executor "holds"
beyond what the boundary chose to give. Closing the read side is what makes
the curation channel meaningful rather than decorative.

**AGT-3 — Every delegated act carries an acceptance specification pinned before the act, and the cycle's success is decided by a deterministic, model-free check against it.**
The specification is authored before the act runs, is fixed (content-
addressed) at pin time, and the verdict that gates the cycle is computed by a
deterministic checker with no model in the judgment path. The existing
model-based reflection may continue to produce advisory signal (confidence,
narrative), but it cannot pass a cycle whose mechanical verdict is absent or
failing.
*Why:* parent INV-4, and the discipline already frozen in the instance's
loop-validation knowledge: fail-closed, spec-pinned, deterministic verdicts
are what let an autonomous loop accumulate *trustworthy* records. Today the
loop's only success signal is self-assessment, which the parent identifies as
vacuously satisfiable. Keeping reflection as advisory preserves its value
(steering, early exit) without letting it hold the gate.

**AGT-4 — The actor does not author what judges it.**
The acceptance specification for an act is authored independently of the
executor, and independently of the model invocation whose decision produced
the act. Intent whose acceptance cannot be authored as a self-contained
mechanical specification is not delegated as a gated act: it is decomposed at
the boundary, or it goes to the existing review-and-human tier.
*Why:* parent INV-5. The agent loop's sharpening is the second independence
clause: because decision and judgment would otherwise be produced by the same
context, the specification must be separated from the deciding invocation —
by deriving it from the mandate/goal declared before the loop ran, by an
independent authoring step, or by the human at a checkpoint. Which of these
supplies the spec is a mechanism choice (backlog); *that* the deciding
invocation cannot be the author is the invariant.

**AGT-5 — Layer-touching writes originating from an agent decision pass admission.**
Any write that lands in a governance layer and originates from an agent
cycle's decision — regardless of which act route performed it — is admitted
against a declaration, made before the loop ran, of which layers that mandate
may touch. A write outside the declared surface halts the cycle at a
checkpoint.
*Why:* this is the agent-loop analogue of the external track's layer
guard/admission, and it is the invariant that covers the *in-process* act
route, which AGT-1's process confinement cannot reach (the in-process route
runs as the boundary itself). Without it, the guard track would protect
against the untrusted executor while leaving the trusted runtime free to
write any layer at a model's suggestion. Admission re-anchors layer writes to
a human-visible pre-declaration, which is where the mandate's authority
actually comes from.

**AGT-6 — Fail-closed over the guard set.**
For the guard-relevant steps — declaring the work area, pinning the
specification, executing the mechanical verdict, performing admission, and
running the confinement probe — absence, inability to execute, an
unmeasurable result, or detected tamper halts the cycle at a checkpoint.
None of these defaults to success, and a missing specification is a halt,
not a permission to fall back to self-assessment.
*Why:* parent INV-6, with the vacuity fixed: once AGT-3 exists, "no spec"
changes meaning from "normal case" to "halt". The explicit list here is the
guard set, not an enumeration of mechanisms; anything later added to the
guard track inherits the same fail-closed obligation.

**AGT-7 — Attended, sandboxed, human-gated; the guard track does not relax this.**
The loop remains attended; irreversible externalization (commits, pushes,
publication) remains behind the human; unattended operation is not claimed
and is not made easier by this design.
*Why:* the guard track is a floor under the attended pattern, not a license
to remove the human. The external track's history shows the temptation:
better mechanical guarantees invite unattended use. Stating the
non-relaxation as an invariant keeps that a deliberate future decision (with
its own design and review) rather than a drift.

**AGT-8 — Substrate substitution preserves the boundary (Slice 2).**
A native-body executor is a substrate substitution beneath AGT-1..7:
it must satisfy every invariant above, verified by the same probes and the
same acceptance discipline, before it may carry acts. The native body is
packaged and evolved in the same structure as other capabilities (a
SkillSet), so that the definition of the body and the rules for its evolution
live in the same language and governance as everything else. Its process
boundary remains real: same-language does not mean same-process, and no
in-process execution path may be introduced under the name of the native
body.
*Why:* this is where the design touches the project's generative principle —
the body joining the language of the system is what makes its definition and
evolution self-referential rather than external. But the philosophical gain
must not purchase a confinement loss: the isolation that makes an executor
safe is the process boundary and the substrate-level confinement, which are
language-independent. AGT-8 makes "rewrite the body in our language" safe by
construction: the invariants, probes, and admission are already in place and
indifferent to what the executor is written in.

## 5. Slice plan

**Slice 1 — confinement and mechanical acceptance (existing substrate).**
Delivers AGT-1, AGT-2, AGT-3, AGT-4, AGT-5, AGT-6 on the current executor
path, plus the probes that observe them. AGT-7 is already the operating
regime and is carried forward unchanged. Slice 1's acceptance: each AGT
invariant has at least one executed probe or test demonstrating the
guarded-failure branch (a blocked write, a halted no-spec cycle, a refused
out-of-declaration layer write), not only the happy path.

**Slice 2 — native body (substrate substitution).**
Delivers AGT-8. Preconditions: Slice 1 frozen and its probes green in real
attended runs. Slice 2 explicitly reuses Slice 1's confinement and acceptance
unchanged; its own design document covers only the executor substrate (task
intake, tool loop, resource ceilings) and the demonstration that the Slice 1
probes pass identically under the new substrate. Model access for the native
body goes through the instance's existing model-adapter capability rather
than a new channel, so that provider policy and configuration remain in one
place.

The slices are separately reviewable and separately shippable; Slice 2 not
happening leaves Slice 1 fully valuable.

## 6. Non-goals

- No unattended operation, and no scheduling/automation of loop starts.
- No change to the existing policy-gate ladder or its thresholds.
- No claim that the deciding model is confined — see the frame commitment in
  §2. Decision governance remains policy gates + human.
- No generalization to other loops in this design; the parent document is
  the generalization layer. If Slice 1 teaches something general, it goes
  back to the parent (or to L1 knowledge) as its own revision, not as scope
  growth here.

## 7. Relationship to the parent invariants

| Parent (governed loop) | This design | Delta |
|---|---|---|
| INV-1 record-write boundary-only | AGT-1 | Localized: substrate-level write confinement + standing probe |
| INV-2 copy/value crossing | AGT-2 | Sharpened: ambient read of live store named as reference-in-disguise and excluded |
| INV-3 executor holds what boundary gives | AGT-2 (+ existing curation) | Read-side closure completes an already-compliant supply channel |
| INV-4 mechanical, pre-authored acceptance | AGT-3 | New for this loop; reflection demoted to advisory |
| INV-5 actor ≠ author of its judge | AGT-4 | Sharpened with decision/judgment context separation |
| (external track: layer guard / admission) | AGT-5 | Imported and extended to cover the in-process act route |
| INV-6 fail-closed | AGT-6 | Vacuity fixed; guard set enumerated as obligation carrier |
| (parent frame: attended only) | AGT-7 | Restated as non-relaxation invariant |
| (parent frame: executor-implementation independence) | AGT-8 | Made testable: substitution gated on identical probes |

## 8. Open questions (for review)

1. **Spec authorship channel (AGT-4).** Three candidate authors exist for
   the per-act specification: derivation from the pre-declared mandate, an
   independent authoring step, or the human at checkpoint. The invariant
   only excludes the deciding invocation. Should v0.2 commit to a default
   channel, or is per-mandate choice acceptable?
2. **Admission granularity (AGT-5).** Is a per-mandate layer declaration
   sufficient, or does admission need per-cycle narrowing (each cycle
   declares a subset)? Per-mandate is simpler and matches how mandates are
   already scoped; per-cycle is tighter but adds a declaration step to every
   cycle.
3. **Advisory reflection retention (AGT-3).** Keeping model reflection as
   advisory preserves steering value but retains a channel that could be
   mistaken for the gate. Is the demotion (advisory, cannot pass a failing
   verdict) sufficient, or should reflection be removed from the success
   path entirely?

## 11. Mechanism backlog (non-normative)

Candidate mechanisms, deliberately kept out of the body. Choices here do not
alter the invariants.

- AGT-1 confinement: per-act scratch work area vs. OS-level sandbox profile
  vs. reuse of the external track's confinement wrapper; probe as a standing
  test vs. per-run preflight.
- AGT-2 read closure: work-area-relative execution vs. explicit deny of the
  data directory; interaction with tool-surface restriction already present.
- AGT-3 verdict engine: reuse of the frozen loop-validation verdict discipline
  (content-addressed spec, constant-key verdict, always-exit-0 wrapper) vs. a
  Ruby-native re-implementation of the same contract; where verdict evidence
  is recorded (attestation, per the loop-validation freeze).
- AGT-4 spec channel: mandate-derived template vs. independent authoring
  invocation vs. human-at-checkpoint authoring; pinning via content hash.
- AGT-5 admission: mandate schema extension (declared layer surface) +
  boundary-side write interception; relation to existing safety/permission
  layer.
- AGT-8 native body: task intake contract mirroring the current executor
  tool's schema; tool loop over the existing model-adapter chain; resource
  ceilings equivalent to current defaults; identical probe suite as
  acceptance.
- Probes: blocked-write probe, no-spec-halt probe, out-of-declaration write
  probe, tamper probe (spec hash mismatch).
