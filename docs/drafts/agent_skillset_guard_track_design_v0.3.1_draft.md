---
name: agent_skillset_guard_track_design
title: "Agent SkillSet Guard Track — structural confinement and mechanical acceptance for the in-instance cognitive loop"
version: 0.3.1
status: FROZEN (masaomi confirmed 2026-07-10; R4 = 6/6 unanimous APPROVE, persona 3/3 unanimity x2 rounds; residual findings (c)-only; genuine-(a) trajectory R1→R4 = ~14→6→3→0)
date: 2026-07-10
r3_fixes: >
  R3 (3/6 APPROVE — opus4.6/opus4.8/persona team 3/3 unanimity; codex x2 + cursor REJECT
  converged on ONE genuine (a)): the v0.3 declared-surface option for in-process live-tree
  effects allowed pre-verdict landing with undefined failing-verdict residue — re-admitting,
  scoped to the live tree, the detection semantics the design rejects for the stores. Fixed
  by removing the option: live-tree effects use one geometry on both routes (driver-declared
  scratch area, verdict-gated driver return); declaration-and-refusal remains the shape of
  store admission (AGT-5) only. §2(i) now reads "exactly as on the delegated route"
  literally. Also: AGT-5 totality clause reworded to name the single constitutive-recording
  exception (opus4.8 P2); act-individuation rule provenance pinned (fixed before the loop
  runs, human-approved like the mandate) and rule candidates added to §9 (persona P2s);
  §7/§8 synced to the improved wording that R3's submission carried but the file lacked
  (orchestrator transcription drift, now corrected); §8 "Open for R2" label fixed.
r2_fixes: >
  R2 (4/6 APPROVE — opus4.6/opus4.8/codex5.5/cursor; codex5.4 REJECT on one genuine (a);
  persona practitioner REVISE with two genuine (a)). All R1 themes verified RESOLVED by all
  reviewers; new findings were sentence-level and confined to v0.2's new elements. Fixed:
  §2 frame commitment (iii) reconciled with the constitutive-recording exemption ("through
  the driver" — by admission or as constitutive recording); AGT-5 admission now explicitly
  ranges over BOTH stores with the record store never declarable (act-route record-store
  writes refused by construction) and the exemption scoped to the driver's cycle-record
  authorship, with an exemption-boundary probe; AGT-1 gains route symmetry (in-process
  live-tree effects are scratch-confined or declared-and-refusal-gated — no route-shopping;
  AGT-6 merge step scoped to cycles that produce mergeable results); AGT-3 gains
  boundary-owned act individuation (never deciding-context-owned; Observe/Orient reads named
  outside the gated set) and a per-route statement of the evidence's structural basis;
  AGT-4 gains mandate human-approval provenance and terminology aligned to "deciding
  context"; merge-store and in-process out-of-declaration probes added. Not applied
  ((c)/false positives, recorded): parent-lineage location, human-fallback-rate design
  bound (stays an empirical §8 open), and cursor's decomposition-independence claim
  (already stated in AGT-4: "never by the deciding context").
sub_author_pass_v03: >
  claude_cli_opus4.6 integration check on v0.3 (3/4 categories clean; 1 real integration
  miss fixed): §2(i) "exactly as on the delegated route" overclaimed for the declared-surface
  option and AGT-1's merge-only sentence was falsified by that option — both scoped
  ("quarantined in a scratch area exactly as on the delegated route, or pre-declared and
  refused outside the declaration"; "On the delegated route, legitimate results...").
  "equally strict" softened to "comparably strict about pre-act gating". Over-tightening
  and terminology drift: clean.
sub_author_pass: >
  claude_cli_opus4.6 corrective pass applied (5/5 accepted): within-run scope for
  tighten-only reflection (AGT-3); "untrusted witness" reworded to preserve the model's
  constitutive-participant framing (AGT-3); driver's constitutive recording exempted from
  admission as an inherent boundary act, resolving a circularity (AGT-5); no-spec-halt
  reframed as committed-and-revisable design choice (AGT-6); native-body process prohibition
  made revisable through L0 governance only (AGT-8).
layer_target: L1 design (instance-local); implementation lands in the agent SkillSet (plugin level, not L0 core)
parent: governed_loop_orchestration_invariants v0.3 (FROZEN_planB; currently a frozen draft under docs/drafts, pending L1 registration)
related:
  - governed_loop_orchestration_invariants (boundary invariants, attended pattern)
  - loop_validation L1 (fail-closed mechanical verdict discipline)
  - autonomous_growth_loop SkillSet (external-body guard track: layer guard, admission, enactment, OS confinement)
tags: [agent-skillset, guard-track, design-by-invariant, confinement, mechanical-acceptance, ooda]
r1_fixes: >
  R1 (2/6 APPROVE; persona team REVISE; codex x2 + cursor REJECT). Fixed the convergent
  genuine (a)/(b): the in-process act route is now first-class — AGT-3 ranges over ALL acts
  of a cycle regardless of route, AGT-5 gains refusal semantics, structural attribution, and
  a no-bypass clause, and the §2 frame commitment states route-specific guarantees instead of
  overclaiming confinement for both routes; "record store" and "governance stores" are defined;
  AGT-3 gains an evidence-provenance clause (verdict consumes boundary-observed state, never
  executor self-report); AGT-1 gains work-area/store disjointness (overlap = AGT-6 halt) and
  the scratch-geometry + boundary-merge return path; AGT-4 commits to a default spec channel
  (mandate-derived, human for the unmechanizable) with context-level independence and
  boundary-owned decomposition; AGT-6 names the merge step, resolves the none_attended
  compatibility question against the referenced verdict discipline, and scopes probe cadence;
  blocked-read and spec-discrimination probes added; reflection constrained to tighten-only;
  §3 count corrected (three No rows); sections renumbered continuously; the three-channel
  enumeration moved out of the AGT-4 body. (c) advisories recorded, not applied, where they
  conflicted with design-by-invariant (enforcement hook points stay in the backlog).
---

# Agent SkillSet Guard Track — design v0.3.1

## 1. Frame and scope

The agent SkillSet runs a governed OODA loop *inside* a KairosChain instance:
the trusted orchestration side (the loop driver, its policy gates, mandate
accounting, and record-writing) lives in the instance's own runtime, and the
ACT of a cycle travels one of **two act routes**: it is either performed
**in-process**, as governed tool execution inside the trusted runtime, or
**delegated** to an external executor process. Both routes are in scope, and
they are guarded differently because they sit on different sides of the
process boundary — this asymmetry is stated precisely in §2 and carried
through every invariant.

Two terms are used throughout and defined here once. The **record store** is
the instance's constitutive, append-only record (the chain and attestation
stores — what makes recording constitutive rather than evidential). The
**governance stores** are the layer-defining artifacts (the L0/L1 material
that defines what the instance is and can do). "The stores" below means both.

The external-body guard track (hermes) established, and dogfooding validated,
a set of boundary invariants for governed loops (the parent document). Those
invariants describe a system whose executor is context-blank, confined, and
structurally unable to write the record. The agent SkillSet today satisfies
some of these properties by construction, others only by policy or by
accident of configuration, and several not at all.

This design closes that gap. It is deliberately split into two slices:

- **Slice 1 — harden the existing loop.** Keep the current executor
  substrate; add the missing structural properties (record-write confinement
  with a scratch-geometry return path; pre-pinned mechanical acceptance over
  both act routes; admission with refusal semantics) and make the
  currently-accidental properties explicit and probed.
- **Slice 2 — native body.** Introduce an executor substrate implemented in
  the instance's own language and packaged in the same structure as every
  other capability (a SkillSet), satisfying the identical invariants. Slice 2
  changes the substrate, not the boundary: no invariant is added, weakened,
  or re-interpreted by the substitution.

The confinement work of Slice 1 is the floor Slice 2 stands on; nothing in
Slice 1 is discarded by Slice 2.

**In scope:** the boundary between the agent loop's trusted side and its
executor; the acceptance judgment of an ACT on either route; admission of
store-touching writes that occur within an agent cycle; the return path by
which delegated results reach the live project tree.

**Out of scope:** the loop's existing policy gates (termination, drift,
budgets, complexity-driven review, checkpointing) — they remain as they are,
*above* this guard track; unattended operation (explicitly not claimed, as in
the parent); the L2→L1→L0 promotion path itself; multi-agent composition.

## 2. Roles (specialization of the parent)

The parent's roles map onto the agent SkillSet as follows:

- **Executor**: the process that performs a *delegated* act. Untrusted with
  respect to the record. (Slice 1: the current external CLI substrate;
  Slice 2: the native body. The role, and every invariant bound to it, is
  substrate-independent.)
- **Boundary**: the trusted side, in two parts the parent also
  distinguishes. The **orchestration part** translates decisions into
  executor tasks, curates what crosses, and sequences cycles; the **driver
  part** is the deterministic loop machinery that pins specifications,
  executes verdicts and admission, performs merges, and authors records.
  Spec-pinning and record-writing belong to the driver part, not to any
  model invocation. The human at checkpoints is part of the boundary.
- **Independent verifier**: the party that authors the acceptance
  specification for an act before the act runs. Never the executor; and
  never the deciding context (defined below).

One structural fact distinguishes this system from the external-body loop and
motivates the entire design: **the trusted side and the deciding intelligence
share a runtime and a context.** The model that decides is invoked by the
boundary itself, so decision-making cannot be made context-blank. The
consequence is a narrowed trust claim, stated as a frame commitment:

> The guard track does not attempt to make the *decision* untrusted-safe; it
> makes the *act* and the *record* untrusted-safe. Whatever the deciding
> model proposes: (i) a delegated act executes under structural process
> confinement (AGT-1/AGT-2), and an in-process act executes only through the
> governed tool surface with store-touching writes refused unless admitted
> (AGT-5), and with live-tree effects quarantined in a scratch area with
> verdict-gated return, exactly as on the delegated route (AGT-1) — route
> choice never relaxes the guard;
> (ii) on either route, the cycle's success is judged against criteria the
> deciding context did not author, pinned before the act (AGT-3/AGT-4); and
> (iii) nothing reaches the stores except through the driver — through its
> admission, or as its own constitutive recording of the cycle (AGT-5). The
> decision itself remains governed by the existing policy gates and by the
> human at checkpoints.

"**Deciding context**" below means the model conversation state from which
the cycle's decision was produced — not merely the single invocation. Two
invocations that share that mutable state share the deciding context.

## 3. Current state, stated as properties

To make the delta reviewable without dragging implementation surface into the
body, the current state is summarized as which parent invariants hold and how.

| Parent invariant | Holds today? | How it holds (or fails) |
|---|---|---|
| INV-1 record-write authority boundary-only | **No** | The executor process runs in the live project working tree with no substrate-level write restriction; the stores are reachable by ordinary file writes. The in-process route can likewise write the stores through governed tools with no cycle-scoped admission. |
| INV-2 knowledge crosses by copy/value | Partially | Context reaches the executor as values embedded in its task (curated summaries), which is the compliant channel. But the executor also has ambient read access to the live working tree, including the stores — a reference-shaped channel the parent excludes. |
| INV-3 executor holds only what the boundary gives | Partially | The executor starts context-blank as a process (scrubbed environment, restricted tool surface, resource ceilings) and receives boundary-curated context. But "only what the boundary gives" fails for the same ambient-read reason as INV-2. |
| INV-4 acceptance mechanical, pre-authored | **No** | The cycle's success judgment is a post-hoc self-assessment by a model invocation (a reflection step yielding a confidence value). No specification exists before the act; no deterministic check gates the cycle, on either route. |
| INV-5 actor never authors what judges it | **No** | The deciding invocation and the reflecting invocation are drawn from the same context and the reflection judges the act it helped produce. |
| INV-6 fail-closed | Partially | Timeouts, budget exhaustion, and executor failure halt or checkpoint the loop. But because no pinned specification exists, the "absence of a specification" branch of fail-closed is vacuous — absence is the normal case, and the loop proceeds. |

The three "No" rows — confinement, mechanical acceptance, and actor/judge
separation — are Slice 1's substance; the third falls out of the same two
moves (a pinned spec authored outside the deciding context dissolves the
self-judgment). The "partially" rows are closed by the same moves plus
explicit probing.

One consequence is a deliberate behavior change on both routes: today the
executor edits live project files directly, and in-process tool effects land
in the live tree immediately. Under this design, neither happens: both routes
work through a driver-declared scratch area with verdict-gated return
(AGT-1). The loop's observable outcomes are unchanged, but the write path
moves.

## 4. Invariants (AGT series)

These bind both slices. They specialize the parent; where a parent invariant
is restated it is because the agent-loop context sharpens it, not to fork it.

**AGT-1 — Executor writes are confined to a scratch work area disjoint from the stores; results return only through the driver, and only after the verdict.**
The executor process can write only within a scratch work area declared per
act by the driver. The declared area is structurally disjoint from the stores
and from the live project tree; a declaration that overlaps either is itself
a guard failure and halts under AGT-6 — disjointness is required, not
presumed, because the declaration is downstream of a model decision and must
not be steerable into the protected surface. Writes outside the area fail at
the substrate level, not by convention or prompt. On the delegated route, legitimate results reach
the live tree only through a merge performed by the driver, and only for a
cycle whose mechanical verdict (AGT-3) has passed; the merge itself never
targets the stores. The confinement is *probed*: the guard track includes
standing checks that a store-write attempt from executor position fails and
that an overlapping declaration is refused, so the property is observed, not
assumed. The same geometry binds the in-process route: an in-process act
whose effects would reach the live tree performs them in a driver-declared
scratch area with the same verdict-gated return — one geometry, both routes.
Declaration-and-refusal remains the shape of store admission (AGT-5); it is
not an alternative for live-tree effects, because a write landing inside a
declared surface before the verdict would re-admit, for the live tree, the
detection semantics this design rejects for the stores. The deciding context
influences which route an act takes, so the routes must be identically
strict about pre-verdict effects — otherwise steering an act in-process
would escape the quarantine the delegated route enforces (route-shopping),
and the confinement would be only as strong as the weaker route.
*Why:* this is the parent's INV-1 made local, with the return path included
because confinement without it is incomplete: if results flowed back by any
path other than a verdict-gated driver merge, the boundary would be writing
untrusted content into the live tree ungoverned, and the confinement would
merely relocate the hazard. Moving both the write restriction and the return
into the substrate and the driver converts the record's integrity from a
policy into a structural fact, which is the entire point of a guard track.
The probes exist because confinement that is configured but never exercised
decays silently.

**AGT-2 — What the executor can read is curated, and the stores are not readable from executor position.**
Knowledge reaches the executor as boundary-curated values in the task or
copies in its work area. The live stores are outside its readable surface,
and this too is probed: a standing check that a store-read attempt from
executor position fails, for the same decay reason as AGT-1's write probe.
*Why:* parent INV-2/INV-3. Ambient read of the live store is a reference in
disguise: it lets an untrusted process observe (and, combined with any write
gap, race) governance state, and it silently widens what the executor "holds"
beyond what the boundary chose to give. Closing the read side — and observing
the closure — is what makes the curation channel meaningful rather than
decorative.

**AGT-3 — Every act of a cycle, on either route, carries an acceptance specification pinned before the act; the cycle's success is decided by a deterministic, model-free check against boundary-observed state.**
The specification is authored before the act runs and fixed
(content-addressed) at pin time. The verdict that gates the cycle is computed
by a deterministic checker with no model in the judgment path, and its
evidence is state observed by the driver from boundary position — for a
delegated act, the driver inspects the scratch area's actual content; for an
in-process act, the driver executed the governed tool call itself and
observes its effects first-hand — never the executor's or the model's report
of that state, which would let the act's own participant supply the evidence
for its own judgment — the same self-assessment the mechanical verdict
displaces. This ranges over *all* acts the loop performs, in-process acts
included: an act route changes how the act is confined, not whether it is
judged. What counts as an act — and where one act ends and the next begins —
is individuated by the boundary (the driver by pre-declared rule, or the
human at a checkpoint), never by the deciding context, which could otherwise
classify a gated act as mere observation and carry it past the gate; the
individuation rule itself is fixed before the loop runs and enters force
through the same human approval as the mandate, so the deciding context
cannot propose its own rule at loop start. The
reads of the observe and orient phases are not acts and sit outside the
gated set — they can mutate nothing, since AGT-1 and AGT-5 bound every write
path — so gating them would add cost without adding protection. Model-based reflection may continue as advisory signal,
and advisory means one-directional: it may tighten the outcome (trigger an
earlier halt or checkpoint) but can never loosen it — it cannot pass a cycle
whose mechanical verdict is absent or failing, and it is excluded from the
recorded success status. This tighten-only constraint governs advisory
influence *within a run*; between runs, the mandate and its acceptance
material are revisable through the normal governance path, which is where
threshold adjustment lives.
*Why:* parent INV-4, and the discipline already frozen in the instance's
loop-validation knowledge: fail-closed, spec-pinned, deterministic verdicts
are what let an autonomous loop accumulate *trustworthy* records. R1 exposed
two ways this invariant could be hollowed out — scoping it to delegated acts
only (leaving the in-process route self-assessed), and leaving evidence
provenance unstated (letting self-report satisfy the spec) — so both closures
are part of the invariant, not mechanism. Keeping reflection as
tighten-only advisory preserves its metacognitive value without letting it
become a soft override channel.

**AGT-4 — The deciding context does not author what judges it; the default author is the mandate, and the fallback is the human.**
The acceptance specification for an act is authored independently of the
executor and independently of the deciding context (§2) — independence at the
level of the shared conversation state that defines the deciding context, not
merely of invocation. The committed default channel: specifications are
derived by the driver from acceptance material declared in the mandate before
the loop ran; the mandate itself enters force only through human approval at
its creation, so the anchor material does not share a trajectory with the
loop it will judge. Intent whose acceptance
cannot be derived that way is not delegated as a gated act: it is decomposed
at the boundary — by the orchestration part or the human, never by the
deciding context — or it goes to the existing review-and-human tier. The
human at a checkpoint may author or amend a specification; a model invocation
sharing the deciding context may not.
*Why:* parent INV-5. R1 established that invocation-level independence is
nominal here: a fresh authoring invocation drawn from the same session is
steered by the same trajectory that produced the decision, and a deciding
context that owns decomposition can shape acts toward specs it predicts —
actor-authors-judge through the back door. Deriving specs from the mandate
anchors judgment in material fixed before any cycle ran (where the mandate's
authority already lives), at the acknowledged cost that mandate authors must
state acceptance in checkable terms; the human fallback covers what the
mandate cannot foresee. This is a committed default, not a menu: alternates
live in the backlog and would need their own review to displace it.

**AGT-5 — Store-touching writes within a cycle pass admission, admission refuses rather than detects, and no bypass path exists.**
Any write that would land in the stores and is performed within an agent
cycle — by either act route, attributed structurally by *when and where* it
executes (inside the loop's machinery during a cycle), not by inferred
intent — is admitted against a declaration, made in the mandate before the
loop ran, of which layers that mandate may touch. Admission ranges over
*both* stores; the declaration can name only governance-store surfaces,
because the record store is never declarable — so an act-route write to the
record store is outside every possible declaration and is refused by
construction, not by favorable interpretation. Exactly one path reaches the
record store: the driver's own constitutive recording — writing the cycle's
record to the chain and attestation stores — which is an inherent act of the
boundary, not an admitted act: it is what makes the cycle exist as a recorded
event, and it cannot be subject to mandate-level permission without
circularity. The exemption is scoped to that authorship alone, and its
boundary is probed: a non-record write attempted through the recording path
is refused. Admission is refusal, not detection: a write outside the declared surface does not land, and the cycle
halts at a checkpoint with the refusal recorded. And admission is total for
the trusted runtime's loop machinery: apart from that single
constitutive-recording path, no store-write path exists inside the loop that
does not pass through admission — the absence of a bypass is itself part
of the invariant, probed from the in-process route, not an implementation
hope.
*Why:* this is the agent-loop analogue of the external track's layer
guard/admission, and it is the invariant that covers the *in-process* act
route, which AGT-1's process confinement cannot reach (the in-process route
runs as the boundary itself). R1 exposed three ways it could be hollowed out:
detection semantics (the layer is already mutated when the loop halts —
unacceptable where recording is constitutive and appends are irreversible),
intent-based attribution (a layer write reclassified as "boundary
housekeeping" escapes admission), and an un-intercepted write path (admission
as decoration). All three closures are invariant content. Admission
re-anchors store writes to a human-visible pre-declaration, which is where
the mandate's authority actually comes from.

**AGT-6 — Fail-closed over the guard set.**
For the guard-relevant steps — declaring the work area, pinning the
specification, executing the mechanical verdict, performing admission,
merging results (for cycles that produced mergeable results), and running
the confinement probes at their declared cadence — absence, inability to execute, an unmeasurable result, a
disjointness violation, or detected tamper halts the cycle at a checkpoint.
None of these defaults to success. A missing specification is a halt, not a
permission to fall back to self-assessment; in particular, the referenced
verdict discipline's attended allowance for spec-less runs (recording an
attended no-spec outcome rather than halting) is *not admissible inside the
guard track* — within this design, no spec means no gated act. This is a
committed design choice matching AGT-4's mandate-derived default, not a
logical entailment of guard tracks in general; relaxing it would be its own
reviewed revision. This list names
the current guard set as an obligation carrier, not an enumeration of
mechanisms; anything later added to the guard track inherits the same
fail-closed obligation. The expected cost is accepted: early operation will
halt often, and resume-from-checkpoint under the existing attended machinery
is the intended recovery loop, not a failure of the design.
*Why:* parent INV-6, with the vacuity fixed: once AGT-3 exists, "no spec"
changes meaning from "normal case" to "halt". The explicit incompatibility
note exists because the guard track deliberately reuses an existing verdict
discipline that is more permissive when attended; reusing its engine must not
import its exemption. Probe cadence is a mechanism choice (backlog), but
"probes run at their declared cadence or the loop halts" is not.

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
A native-body executor is a substrate substitution beneath AGT-1..7: it must
satisfy every invariant above, verified by the same probes and the same
acceptance discipline, before it may carry acts. The native body is packaged
and evolved in the same structure as other capabilities (a SkillSet), so that
the definition of the body and the rules for its evolution live in the same
language and governance as everything else — while the body itself runs, like
every executor, as a separate confined process. Being defined *in* the
instance's structure and running *outside* the instance's process are
compatible, and the design requires both: no in-process execution path may be
introduced under the name of the native body. This is a structural commitment
of the current guard track, revisable only through L0 governance with its own
design and review — not through mechanism choice or implementation
convenience.
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
Delivers AGT-1..6 on the current loop, both act routes, plus the probes that
observe them. AGT-7 is already the operating regime and is carried forward
unchanged. Slice 1's acceptance: each AGT invariant has at least one executed
probe or test demonstrating the guarded-failure branch — a blocked store
write and a blocked store read from executor position, a refused overlapping
work-area declaration, a halted no-spec cycle, a refused out-of-declaration
store write from the in-process route, a blocked pre-verdict live-tree write
from an in-process act, a refused merge set containing a store path, a
refused non-record write through the recording path, a tamper halt — and additionally a
*discrimination* check for AGT-3: a deliberately non-conforming act judged
against its pinned specification must yield a failing verdict, demonstrating
the gate distinguishes, not merely that it exists. Mandate acceptance
material and the layer declaration (AGT-4/AGT-5) are part of Slice 1's
surface, not deferred.

**Slice 2 — native body (substrate substitution).**
Delivers AGT-8. Preconditions: Slice 1 frozen and its probes green in real
attended runs. Slice 2 explicitly reuses Slice 1's confinement and acceptance
unchanged; its own design document covers only the executor substrate (task
intake, tool loop, resource ceilings) and the demonstration that the Slice 1
probe suite passes identically under the new substrate. Model access for the
native body goes through the instance's existing model-adapter capability
rather than a new channel, so that provider policy and configuration remain
in one place.

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
| INV-1 record-write boundary-only | AGT-1 | Localized: substrate-level write confinement, required disjointness, verdict-gated driver merge, single scratch geometry on both routes, standing probes |
| INV-2 copy/value crossing | AGT-2 | Sharpened: ambient read of live store named as reference-in-disguise, excluded, and probed |
| INV-3 executor holds what boundary gives | AGT-2 (+ existing curation) | Read-side closure completes an already-compliant supply channel |
| INV-4 mechanical, pre-authored acceptance | AGT-3 | Extended over both act routes; evidence provenance bound to boundary observation per route; boundary-owned act individuation with pinned rule; reflection demoted to tighten-only advisory |
| INV-5 actor ≠ author of its judge | AGT-4 | Sharpened to deciding-context independence; default channel committed (mandate-derived under human approval, human fallback); decomposition ownership assigned |
| (external track: layer guard / admission) | AGT-5 | Imported with refusal semantics, structural attribution, both-stores range, scoped constitutive-recording exemption, and a no-bypass clause |
| INV-6 fail-closed | AGT-6 | Vacuity fixed; guard set as obligation carrier; permissive attended mode of the reused verdict discipline explicitly not imported |
| (parent frame: attended only) | AGT-7 | Restated as non-relaxation invariant |
| (parent frame: executor-implementation independence) | AGT-8 | Made testable: substitution gated on identical probes |

## 8. Decisions resolved, and what remains open

Resolved (committed):

1. **Spec authorship channel** — mandate-derived by the driver under human
   approval at mandate creation; human at checkpoint for what the mandate
   cannot express; deciding context excluded (AGT-4).
2. **Advisory reflection** — retained, tighten-only within a run, excluded
   from recorded success status; between-run adjustment goes through mandate
   revision (AGT-3).
3. **Work-area geometry** — one geometry on both routes: driver-declared
   scratch area with verdict-gated driver return (AGT-1), accepting the
   behavior change from today's direct live-tree editing. The R3-era
   declared-surface alternative for in-process live-tree effects was removed
   because it re-admitted pre-verdict landing (detection semantics) on the
   route the deciding context can select.
4. **Constitutive-recording exemption** — the driver's cycle-record
   authorship is the single path to the record store, outside admission by
   anti-circularity, probed at its boundary (AGT-5).
5. **Act individuation** — boundary-owned (driver rule or human), never
   deciding-context-owned; the rule pinned before the loop under the
   mandate's human approval; observe/orient reads outside the gated set
   (AGT-3).

Open (empirical, measured by Slice 1 attended runs):

1. **Admission granularity (AGT-5).** Slice 1 commits to per-mandate layer
   declaration. Whether per-cycle narrowing is worth its per-cycle
   declaration cost is left to operational evidence.
2. **Mandate acceptance-material expressiveness (AGT-4).** How much real
   loop intent can be covered by mandate-derived specifications before the
   human-fallback rate makes loops impractical is an empirical question.

## 9. Mechanism backlog (non-normative)

Candidate mechanisms, deliberately kept out of the body. Choices here do not
alter the invariants.

- AGT-1 confinement: per-act scratch work area realized via OS-level sandbox
  profile vs. reuse of the external track's confinement wrapper; merge as
  driver-side file promotion with content listing recorded per cycle.
- AGT-2 read closure: work-area-relative execution vs. explicit deny of the
  data directory; interaction with the tool-surface restriction already
  present on the executor.
- AGT-3 verdict engine: reuse of the frozen loop-validation verdict
  discipline (content-addressed spec, constant-key verdict, always-exit-0
  wrapper) with its attended no-spec mode disabled, vs. a Ruby-native
  re-implementation of the same contract; verdict evidence recorded via
  attestation, per the loop-validation freeze.
- AGT-3 act individuation rule: candidate default — one dispatched ACT-phase
  task payload = one act; finer per-tool-call individuation for in-process
  acts as an alternative; rule carried in the mandate alongside acceptance
  material.
- AGT-4 spec channel: mandate schema extension carrying acceptance material;
  derivation templates; pinning via content hash. Displaced alternates
  (per-act independent authoring invocation with enforced context
  separation; human-authored per-act specs as the default) retained here for
  the record.
- AGT-5 admission: mandate schema extension (declared layer surface) +
  driver-side write interception at the governed tool-execution layer;
  reuse of the external track's admission/norm surface vs. a
  mandate-schema-native check; relation to the existing safety/permission
  layer.
- AGT-6 probe cadence: per-cycle preflight vs. per-session standing test;
  cadence declared in the mandate or in guard configuration.
- AGT-8 native body: task intake contract mirroring the current executor
  tool's schema; tool loop over the existing model-adapter chain; resource
  ceilings equivalent to current defaults; identical probe suite as
  acceptance.
- Probes: blocked-write probe, blocked-read probe, overlap-declaration
  probe, no-spec-halt probe, out-of-declaration store-write probe
  (in-process route), blocked pre-verdict live-tree write probe (in-process
  act), merge-store refusal probe (merge set containing a store path is
  refused), exemption-boundary probe (non-record write through the recording
  path is refused), tamper probe (spec hash mismatch), discrimination probe
  (non-conforming act must fail).
