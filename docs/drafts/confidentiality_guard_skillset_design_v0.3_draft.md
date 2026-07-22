---
name: confidentiality_guard_skillset_design
title: "Confidentiality Guard SkillSet — fail-closed data-confidentiality regime for enterprise environments"
version: 0.3
status: DRAFT (post-R2 revision)
date: 2026-07-22
revises: v0.2 (R2 4/6 APPROVE but (a)-class P0s remained — resolved here: permitted restricted-storage reads now recorded (CG-4); profile designations span every guarded crossing class incl. persistent-layer admission (§4); enrollment completeness moved from backlog to release-gated design constraint (CG-2); cessation recorded so guard-active intervals reconstructible (CG-1); verdict basis versioned incl. detection machinery (CG-3/CG-4); strictest-wins order defined deny>transform>pass (CG-5); transform output re-judged (CG-6); salt residual stated honestly (CG-4)
layer_target: SkillSet (plugin level, not L0 core); policy content is user-editable data
parent: agent_skillset_guard_track_design v0.3.1 (FROZEN) — regime pattern (selectable-off, fail-closed-as-a-whole)
related:
  - loop_validation L1 (fail-closed mechanical verdict discipline, LLM-free judgment)
  - synoptis sdp-1 (salted field-commitment pattern reused for CG-4 record binding)
  - kairos_hook_projector (host-side coverage extension path, Stage 0)
  - multi-host projection track (define-once, project-per-host philosophy)
tags: [guard, confidentiality, design-by-invariant, fail-closed, enterprise, audit]
---

# Confidentiality Guard SkillSet — design v0.3

## 1. Frame and scope

Enterprises that adopt KairosChain-mediated agent work face a data-protection
question that is distinct from agent-behavior safety: not "will the loop act
outside its mandate" but "will confidential content cross a boundary it must
not cross" — outward to an external model or a shared board, or inward into
the instance's own persistent memory layers where it would outlive the
session that touched it.

The existing guard track (the parent document) established a regime pattern
for the agent SkillSet: shipped off by default, and when enabled, activating
a fail-closed discipline as a whole rather than as a menu of toggles. This
design reuses that pattern for a different protected good. The protected good
here is **confidentiality of designated content**, and the protecting party
is the instance itself, at its own tool surface.

**In scope:** every crossing of the instance's tool surface where content
either (a) leaves the instance's trust boundary, (b) enters a persistent
layer (L2/L1), or (c) is read from storage the policy designates as
restricted; the recording of guard decisions; the policy that drives them.

**Out of scope:** host-native tool traffic that does not pass through the
instance's tools (see CG-5 for the honest-boundary commitment and the
projection path); the deciding model's own context — content lawfully read
into the conversation is thereby visible to the host model and its provider,
a disclosure governed by the decision to operate the instance at all, not by
per-call verdicts; network-level egress control, sandboxing, and contractual
data-handling terms — the guard is one layer of a defense-in-depth stack and
does not claim to replace the others; the agent loop's behavioral gates
(they remain orthogonal and compose).

## 2. Threat model and roles

Three failure classes motivate the design, and the guard addresses them
asymmetrically:

- **Operator slip** — a human or model, acting in good faith, routes
  confidential content through a tool call that persists or transmits it.
  Fully in scope: this is the primary case the guard prevents.
- **Misled model** — the deciding intelligence is induced (e.g., by
  adversarial content) to attempt an exfiltrating tool call. In scope at the
  tool surface, on two grounds: the verdict does not depend on the model's
  judgment (CG-3), and the policy the verdict runs on is pinned outside the
  model's reach for the duration of the regime (CG-1) — so a misled model
  can neither argue past the verdict nor rewrite the rules it is judged by.
  What remains open to it is re-encoding content so that detection misses;
  that residual is part of CG-5's coverage statement, not a hidden promise.
- **Malicious insider** — an actor who can edit the policy or the guard
  itself. Out of scope for prevention; in scope for evidence: policy changes
  and guard decisions are constitutively recorded (CG-4), so tampering is
  visible even where it is not preventable. The evidence claim assumes the
  chain store itself has integrity against this actor; where it does not,
  the anchoring tracks (external head anchoring) supply the independent
  witness, and this design inherits rather than restates that machinery.

Roles: the **policy author** (human, enterprise-side) owns the policy as
user-editable data; the **guard** computes verdicts mechanically; the
**deciding model** is untrusted with respect to confidentiality verdicts —
it never participates in the judgment of its own tool call.

## 3. Invariants

**CG-1 (regime activation, pinned policy, fail-closed coverage).** The guard
ships selectable-off. Activation is an environment-level or
configuration-level act, made before the session's work runs, never
negotiated per-call by the deciding model. The policy the regime enforces is
pinned at activation: an edit to the policy data — by anyone, through any
surface — is inert until a subsequent activation-level act, of the same
environment-level kind and occurring at an activation boundary rather than
mid-session, adopts it; the edit is recorded either way (CG-4). When
enabled, the regime is fail-closed as a whole, and fail-closed extends to
coverage: a call that crosses a guarded surface and yields no affirmative
verdict is denied, absence of a rule is a denial, and a crossing belonging
to a guarded surface class whose enforcement is not present in the running
instance is denied, not passed. The regime's own state — enabled or not, and
the pinned policy version — is readable at any time, and both activation and
cessation are recorded, so the guard-active intervals of an instance are
reconstructible from the chain alone.

*Why:* the enterprise case is precisely the one where "the model decided the
data was fine" is not an acceptable failure report. Pinning closes the gap
the misled-model class would otherwise walk through: a policy editable
mid-session by the guarded party is not a policy but a suggestion. Extending
fail-closed to coverage keeps the regime honest across its own staging — a
surface the shipped slice does not yet judge is a surface the regime
refuses, so activation never silently promises more than it enforces. And
recording cessation alongside activation is what makes the trail answer the
prior question every audit asks first: was the guard on when it mattered?

**CG-2 (guarded surfaces, verdict before effect).** Under the active regime,
no content crosses the instance's tool surface outward (external model
invocation, deposit to a shared board, export), inward to a persistent layer
(L2/L1 writes), or from policy-restricted storage, without a guard verdict
preceding the effect. The verdict's inputs are the pinned policy, the
crossing descriptor (direction and the designated source or destination),
and the content presented; the effect a verdict precedes is content becoming
available beyond the guard's examination — persisted, transmitted, or, for
restricted reads, entering the conversational context. The guard's own
reading of content in order to judge it is not an effect. The surface is
defined by the crossing property, not by tool names, and the enrollment
obligation this creates is release-gated: a slice's definition of done
includes a verified check that every instance tool bearing the crossing
property is enrolled, enforced by the same design-constraint tests that gate
the slice — not an emergent hope, and not a backlog item.

*Why:* the three crossing directions share one property — content outlives
or escapes the conversational context — and that property, not the tool's
name, is what defines the surface. Persistence into L2/L1 is treated as a
crossing because the memory layers are read by future sessions whose
operating environment the current session cannot see. Naming the descriptor
as a verdict input removes the pretense that content alone decides: the same
content lawfully stored locally may be denied egress. And making enrollment
a release gate is the only honest footing for CG-1's coverage clause — the
clause can deny what it can classify, so the claim that nothing bearing the
property escapes classification must be verified, not assumed.

**CG-3 (mechanical, conjunctive verdict).** The verdict is deterministic and
LLM-free: computed from the pinned verdict basis — the policy and the
detection machinery it invokes, both versioned — plus the crossing
descriptor and the call's content, and nothing else; any machinery chosen in
§8 must preserve that determinism, for a machinery that cannot be re-run to
the same verdict is out of bounds. The affirmative form is conjunctive: the
crossing must be affirmatively designated by the policy (absence of
designation is denial — CG-1), and the presented content must clear the
policy's content classes, a detection yielding denial or, under CG-6 opt-in,
transformation. Detection that fires nothing on a designated crossing is a
pass: the regime is fail-closed over designations and detection-bounded over
content, and the false-negative residual this leaves is part of CG-5's
coverage statement. The deciding model neither computes nor overrides the
verdict.

*Why:* this is the loop_validation discipline applied to confidentiality. A
verdict the model can argue with is a verdict prompt injection can argue
with. Stating the conjunction resolves what "fail-closed" can and cannot
mean for a content guard: rules and destinations are closed-world, content
detection is not and cannot be, and an invariant that pretended otherwise
would be the overstated-coverage failure CG-5 warns against. Versioning the
whole verdict basis, not the policy alone, is what keeps re-derivation
meaningful when the detection machinery itself evolves.

**CG-4 (constitutive audit, commitment-bound records).** Recorded on the
chain: every verdict on an outward crossing — permitted, denied, or
transformed — every read from policy-restricted storage, permitted or not,
every denial and transformation on any surface, and every change to the
policy data. Permitted inward writes need not be recorded, and the asymmetry
is principled: what a permitted write admits is itself persisted in L2/L1
and remains inspectable there, which is exactly what a permitted restricted
read does not leave behind — so reads are recorded and writes may speak for
themselves. Each record identifies the verdict — the versioned verdict
basis, the designation or rule that grounded it, the crossing descriptor —
and binds the content by a salted commitment rather than containing it.
Re-derivability means exactly this: given the record and a re-presentation
of the content, the verdict recomputes and the commitment checks; the record
alone never reconstructs the content, and verification of a denial record
accordingly requires an independent holder of the content — the commitment
is a binding check, not a recovery path. What salting cannot prevent — a
holder of the record confirming a guessed low-entropy content — is a stated
residual; bounding it (salt custody, scheme parameters) is a §8 choice
aligned with sdp-1. The audit write itself is constitutive of the guard's
operation, not a guarded crossing; it is constrained instead by this
invariant's no-content clause.

*Why:* recording is the second half of the protection, and the record scope
follows the audit's questions: "what was sent where, when" is answered by
the outward records, "who touched the restricted store, when" by the read
records — the two questions about content the trail cannot recover from
anywhere else. For the operator-slip class the denial records convert
near-misses into learnable events; for the malicious-insider class the trail
is the only defense offered. The commitment construction is the
reconciliation of two demands that are jointly unsatisfiable in their naive
forms — re-derive the verdict, never store the content — and it reuses the
salted field-commitment pattern the anchoring track (sdp-1) has already
carried through review. A guard whose audit trail republishes the secret has
negative value.

**CG-5 (honest boundary, with a projection path).** The guard claims
coverage of the instance's own tool surface and nothing more, and the claim
is per-crossing and syntactic: the guard judges the content presented at a
crossing, not the semantic lineage of what the deciding model has derived
in-context, so paraphrase between crossings and detection false negatives
are residual risks owned by the surrounding stack, and stated as such.
Host-native tools reach storage and network without crossing the surface,
and the design states this rather than obscuring it. The same policy,
unchanged in content, may be projected into host-side enforcement points
(the hook projector track); the projection act is recorded under CG-4's
policy-change discipline and carries the policy version it was made from, so
version skew between enforcement points is visible from the instance's own
records — without any claim that host-side decisions are themselves
recorded, which remains outside the boundary. Projection extends coverage
but never relaxes the instance-side regime, and where both a projected point
and the instance guard intercept the same crossing, the outcome is the
strictest of the two under the order deny over transform over pass —
outcomes not comparable under that order resolve to denial — independent of
evaluation order.

*Why:* a guard that overstates its coverage is worse than no guard, because
it displaces the layers (sandbox, egress control) that actually cover the
rest — and "coverage" here has two dimensions, surface and semantics, both
of which the claim must bound honestly. Define-once/project-per-host keeps
a single policy authoritative instead of forking enterprise rules per tool,
and defining strictness as an order rather than a negotiation is what makes
the composition claim checkable.

**CG-6 (deny over transform, diagnosable denial).** The default consequence
of a detection is denial. Transform-and-pass (redaction) is a per-policy
opt-in; a transformation's output is itself presented to the verdict before
it passes, so a redaction whose residue still detects is denied, not passed;
and a transformed pass is recorded as a transformation, never as a clean
pass. Every denial yields an operator-visible report that names the
designation or rule and the crossing without republishing the content, so
blocked legitimate work is diagnosable without disabling the regime.

*Why:* fail-closed extends to the consequence: redaction is a judgment about
what remains sensitive after removal, and that judgment can be wrong — which
is exactly why the judgment is not trusted: the transformed output re-enters
the same mechanical verdict as any content, and only a clean result passes.
Recording transforms distinctly keeps the audit trail truthful, and the
denial report keeps fail-closed livable — a regime whose only failure mode
is silent refusal trains its operators to switch it off.

## 4. Policy and profiles (property level)

The policy is data, not code: user-editable, profile-shaped (one active
profile per environment), and versioned through the same recording
discipline as any layer-touching change. What a profile expresses is bounded
by one property: its designations span every guarded crossing class — which
outward destinations exist at all, which storage is restricted and what
reads of it are permitted, which persistent-layer admissions are allowed,
and which content classes are denied or transformed on any of them. A class
the profile leaves undesignated is wholly denied (CG-1); in the degenerate
case of activation with no profile present, the regime is total denial,
which is fail-closed behaving as stated rather than an error. The vocabulary
a profile uses to express its designations is a mechanism choice (§8). Where
projection (CG-5) spans hosts whose destination sets differ, the profile's
designations remain the single authority and a host simply has no crossing
for a designation it cannot reach.

The activation signal (the "guard_option=1" of the motivating request) is an
environment-level fact read at instance start. Which concrete signal — an
environment variable, a configuration key, or both with a defined precedence
— is a mechanism choice (§8); the invariant content is only CG-1's: chosen
before work runs, outside the deciding model's reach, and pinning the policy
version it adopts.

## 5. Relation to existing tracks

- **Agent guard track (parent):** same regime pattern, different protected
  good. The two guards compose without coordination: one constrains what an
  agent may *do*, this one constrains what content may *cross*. Neither
  reads the other's state; a call subject to both proceeds only if both
  affirm, so their evaluation order is immaterial.
- **loop_validation:** supplies the verdict discipline (CG-3) — pre-pinned
  spec, mechanical judgment, no LLM in the loop.
- **synoptis / sdp-1:** supplies the salted-commitment pattern CG-4 binds
  records with; this design reuses the reviewed construction rather than
  inventing a second one.
- **kairos_hook_projector:** supplies the coverage-extension path for CG-5.
  This design adds a consumer for that track but no new obligations to it.
- **L0 core:** untouched. The guard is a SkillSet; if a future need arises
  to make a guarded surface un-bypassable from within the instance, that is
  a separate design with its own review, not a silent promotion.

## 6. Slices

- **Slice 1 — inward and storage surfaces.** The regime skeleton
  (activation, pinning, fail-closed default, chain recording of decisions
  and policy changes) plus the storage-read and persistent-layer-write
  surfaces. Under CG-1's coverage clause, a slice-1 instance with the regime
  active denies outward crossings wholesale: an inward-only posture,
  restrictive but honest, suited to pilot workloads that exercise memory and
  storage discipline before any external destination is trusted. Chosen
  first because it is self-contained and can be validated entirely
  in-instance.
- **Slice 2 — outward surfaces.** External model invocation, deposits,
  exports — earning outward work back from the slice-1 denial posture;
  opt-in transform (CG-6) lands here, because transformation only earns its
  complexity where denial would otherwise block legitimate outward work.
- **Slice 3 — projection.** Policy projection into host-side enforcement
  via the hook projector track. Explicitly last: CG-5 keeps the instance
  honest without it, and the projector track has its own staging.

Each slice ships selectable-off and flips on only under the single regime
switch; there is no per-slice activation surface (CG-1).

## 7. Non-goals

Not a sandbox, not a network policy, not a contractual control, and not a
claim that the instance is safe for confidential work by itself. The guard
is the instance-side layer of a stack whose other layers exist outside the
instance, plus the audit substrate that the other layers lack. Record fields
are identifiers, versions, descriptors, and salted commitments — never
content; whether a designation identifier is itself personal data under a
data-protection regime is a policy-authoring concern, and erasure
obligations beyond the no-content clause are owned by the surrounding
governance stack, not by this design. Separation of duties among policy
author, activation actor, and audit consumer is likewise a governance-stack
concern: the design records who did what, and leaves who may be whom to the
enterprise.

## 8. Open questions and mechanism backlog

Open design questions (to resolve in review, not silently):

- **Q1 — policy home.** Profile as SkillSet-local user-editable data versus
  L1 knowledge entry. Leaning: SkillSet-local config for the enforced
  policy, with L1 free to document enterprise rationale; L1 is prose for
  minds, config is data for verdicts, and CG-3 wants the verdict input to
  be the pinned data, not a prose rendering.

(v0.1's Q2 — transform-record semantics — is resolved by CG-4's commitment
construction: the record establishes *that* and *where* without *what*.)

Mechanism backlog (explicitly not body content): activation signal name and
precedence; profile file format and vocabulary; commitment and salt scheme
parameters and salt custody (aligned with sdp-1); verdict-basis versioning
scheme for detection machinery; content-class detection machinery (pattern
classes, dictionaries, entropy heuristics) and its false positive/negative
handling; redaction algorithms; denial-report wording; per-tool wiring
order; re-projection cadence after policy adoption; test/probe naming.
