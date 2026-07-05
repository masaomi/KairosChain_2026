---
title: L2 Attestation for Constitutive Recording — Design v0.9 (unified, bank-ledger, typed entries + lineage binding)
author: Masaomi Hatakeyama
date: 2026-07-05
status: FROZEN (R4-of-v0.9 = 6/6 APPROVE unanimous; converged; ready for design → implementation planning)
layer: L1 capability (extends the existing attestation SkillSet, Synoptis)
grounding_case: UZH Entrepreneur Fellowship pitch (rejected 2026-07-01)
revises: l2_attestation_constitutive_recording_design_v0.8_unified_draft.md
baseline_decisions: >
  Unchanged four user-fixed premises (dedicated ledger not Meta Ledger; bank-ledger
  re-attest-don't-detect; tamper-proofness from external anchoring uniform across ledgers;
  never exceed the L0/L1 posture). R3-of-v0.8 reached 5/6 APPROVE; the one genuine residual
  (echoed by codex 5.4, cursor, and the orchestrator persona) was a lineage-reference
  precision gap: a supersession's approval bound only (subject, digest), not the target entry
  it supersedes, and LED-2(b)'s "prior entry it follows" (chronological) diverged from
  §Kinds/ACT-3's "entry it supersedes/withdraws" (semantic target). Closed by defining the
  lineage reference once in §Kinds (the target entry) and having ACT-3/LED-2(b)/ACT-1 bind and
  reference it consistently.
---

# L2 Attestation for Constitutive Recording — Design v0.9 (unified)

## 1. Purpose

Prop 5 (constitutive recording): to compute is to record. L2 contexts are freely editable
files; nothing today lets a later reader distinguish "this judgment as recorded at the time"
from "this judgment as quietly re-storied after the outcome was known." This design enters
selected L2 judgments into a dedicated **append-only attestation ledger** — a dated line
stating *at moment T, subject X had digest D* — and adds a propose-only activation policy so
that entries actually get made (the system proposes, the human approves).

The model is a bank ledger. Lines are only ever appended, never rewritten. If the live context
changes and the new state matters, a **new entry is appended** (a supersession of the prior
one); the old entry stands as what was true then. Revocation is likewise a new entry
referencing the entry it withdraws, never an edit of it. The sequence of entries *is* the audit
trail — no separate preservation store, no tamper-detection machinery, no consent cryptography.
Recording is constitutive by accumulation of moments (Kairos, not Chronos).

A digest binds an entry to the *fact* that specific bytes existed at T; it proves *that* the
content matched, not *what* it said. An audit that needs the original wording can opt the entry
into an embedded snapshot (§Kinds, LED-3); a digest-only entry proves change, not prior text.

Grounding case unchanged: the UZH pitch (rejected 2026-07-01); the "why did it fail" analysis
spans ~70 L2 contexts to a rejection debrief whose judgments deserve dated entries as made.

## 2. Scope and non-goals

In scope: (A) a dedicated append-only attestation ledger for selected L2 contexts; (B) a
propose-only activation policy (system proposes, human approves per attestation, human retains
independent initiative) with its own append-only operational log.

Non-goals: attesting all L2 (LED-1); recording L2 attestations on the Meta Ledger — both stores
are their own (LED-5); a new interpretive index over L2 (LED-4); read-only/frozen live L2 —
editing stays free (LED-2); mandatory content preservation — snapshot optional per entry
(§Kinds); tamper-proofing the local stores — from external anchoring uniformly with L0/L1
(LED-6, §11); consent stronger than the L0/L1 approval posture (ACT-1); autonomous attestation
(ACT-1); a universal per-context evaluation record — only declines are logged, and only for
proposed contexts (ACT-4); a fixed pre-designed selection criterion — it evolves (ACT-2).

---

## Part A — Ledger invariants (LED-1..6)

### Kinds (definitional; referenced by the invariants below)

The design maintains exactly two append-only stores holding exactly four line kinds. This
vocabulary is fixed here so the invariants quantify over named kinds rather than carving
exceptions inline.

- **Attestation ledger** (human-approved, ACT-1), two entry kinds:
  - **content-attestation entry** — commits (subject, digest, moment); may embed a content
    snapshot (per-entry optional). The *first* content-attestation about a subject stands
    alone; a *supersession* is a content-attestation that additionally commits a
    **target-entry reference** to the prior entry it supersedes (see "lineage reference" below).
    A re-attestation of an already-attested subject is therefore a supersession.
  - **revocation-withdrawal entry** — commits (subject, target-entry reference, moment); commits
    no digest and no content. It marks the referenced target entry withdrawn.
- **Activation-policy operational log** (not human-approved; policy telemetry), two record kinds:
  - **decision record** — commits (subject-id, "declined", moment); content-free. Only declines
    are recorded here (ACT-4).
  - **trigger record** — commits (moment, surfaced-count); subject-free and content-free (ACT-5).

**Lineage reference.** Where an entry carries a lineage reference (a supersession, a
revocation-withdrawal), the reference denotes the specific **target entry** the new entry acts
on — the one it supersedes or withdraws. The target is normally the subject's latest prior
entry, but the binding is to the target itself, not to "whatever is chronologically previous,"
so the reference is unambiguous even if entries are read out of order.

"Entry" denotes an attestation-ledger line; "record" denotes an operational-log line; "line"
denotes either. Where an invariant says "entry" it governs the attestation ledger only.

**LED-1 — Selective; the artifact's freedom is preserved.**
Attestation is never an obligation over all L2. Neither store may change the free modification
or natural selection of any L2 *artifact*, attested or not: both stores record claims and
decisions *about* contexts, and never constrain, preserve, or resurrect the live context files
themselves.
*Justification.* Total coverage would collapse L2's selective-survival character and partial
autopoiesis (closure at governance, not execution). "Records about artifacts, not bindings on
artifacts" is what lets a declined or attested subject still be freely edited or allowed to die:
a content-free decline or a dated digest is a note in a book, not a lock on the file. Durability,
where it exists, attaches to a line, never to the artifact.

**LED-2 — Both stores are append-only; attestation-ledger entries additionally carry lineage.**
(a) Every line of both stores is append-only: once written it is never edited, deleted, or
unbound; the live L2 context stays freely editable and neither store constrains it. (b) Within
the attestation ledger, every entry that acts on an existing entry — a supersession or a
revocation-withdrawal — carries a lineage reference to the target entry it acts on (§Kinds); the
first content-attestation about a subject carries none. Operational-log records carry no lineage
(a trigger record has no subject; a decision record stands alone).
*Justification.* Clause (a) is the bank-ledger integrity model: silent hindsight rewriting *by
the agent, through the stores' own operations* is excluded structurally — there is no edit
operation. (Operator-level wholesale rewriting is a separate threat, out of scope locally,
addressed only by anchoring, LED-6.) Clause (b) is what makes an attested subject's trajectory
reconstructable; binding the reference to the *target* entry (not merely "the previous line")
keeps the lineage unambiguous and is a property of judgment-bearing entries, not telemetry, so
it is scoped to the ledger. Revocation is itself an append (a revocation-withdrawal entry), so
"what was claimed, and that it was later withdrawn" survives its own withdrawal. No detection or
preservation machinery: if live content diverges from the last entry, that is not an incident —
either irrelevant (the context evolved past its attested moment) or the occasion for the next
entry.

**LED-3 — An attestation entry commits one judgment.**
Each attestation-ledger entry corresponds to exactly one interpretable judgment as of a moment
(a line fusing unrelated judgments or splitting below the judgment boundary cannot anchor an
audit) and binds a subject identifier stable across rename/relocation. A content-attestation
entry additionally binds a digest of the subject's actual persisted content (and may embed a
snapshot); a supersession additionally binds a target-entry reference; a revocation-withdrawal
binds a target-entry reference and no digest (§Kinds).
*Justification.* One-judgment correspondence and a stable subject id are what let successive
entries be shown to concern the same judgment across time and rename. Binding the digest to
actual persisted content prevents attesting content that was never the subject; a digest proves
*that* content matched, not *what* it was, so audits needing original text embed the snapshot,
which LED-2(a) then preserves. The three entry forms are defined once in §Kinds, so this
invariant states the shared property (one judgment, stable subject) and defers the per-form
bindings (digest, target-entry reference) to §Kinds without asserting a field a form does not
carry. (Digest algorithm, canonical form, subject-id scheme, judgment-unit realization,
snapshot format, reference format → §11.)

**LED-4 — No new interpretive index over L2 content.**
Neither store introduces a new causal or temporal index for interpreting "why" over L2 content:
causal ancestry stays with the existing L2 relation graph, chronological order with existing
session timestamps. The attestation ledger's entry-to-entry lineage (LED-2b) is store
bookkeeping over attestation events, not an index over L2 content.
*Justification.* Both structures already exist and are load-bearing; the ledger's sole
interpretive contribution is dated evidence on nodes already in those structures.

**LED-5 — Two dedicated stores, neither the Meta Ledger.**
The attestation ledger and the operational log (§Kinds) are both separate from the Meta Ledger
(L0/L1 change history): no line of either is written to the Meta Ledger, and no Meta Ledger
semantics are imported. The two stores are also separate from each other.
*Justification.* The Meta Ledger records capability/governance evolution; these stores record,
respectively, dated judgments about contexts and the policy's own operation. Separating the two
stores is what let §Kinds give judgment-bearing entries and content-free telemetry distinct
shapes and rules (the recurring R1/R2 defect was one store forcing one line definition to cover
both). Keeping both off the Meta Ledger preserves the layer architecture ("L2: blockchain
none") and lets each store choose its own volume, retention, and anchoring granularity.
(Whether the attestation ledger reuses/extends Synoptis's proof store, and where the operational
log lives → §11.)

**LED-6 — Integrity posture is inherited from anchoring, uniformly with L0/L1.**
Each store's resistance to operator-level rewriting is whatever the deployment's anchoring
provides, and never claims more. Local-only operation is honest-operator grade — exactly the
posture today's L0/L1 Meta Ledger has. Anchoring a store to an external public/consortium chain
upgrades every line made before the anchor point to undeniably-detectable (effectively
tamper-proof for audit purposes). Anchoring is a deployment choice applied uniformly to the
system's ledgers (Meta Ledger, attestation ledger, operational log alike), not an L2-special
mechanism. This uniform *integrity* posture is independent of the *approval* asymmetry between
the stores (attestation entries are approved, operational records are not — LED-5, ACT-1).
*Justification.* A private store can always be rewritten wholesale by its operator; pretending
otherwise (preservation stores, consent cryptography, forge-resistant tokens) is machinery that
guards a door in a wall with a hole in it. Against the agent and against casual edits,
append-only structure suffices; against the operator, only an external anchor helps — the same
statement L0/L1 already live with. Security of L2 attestation therefore never exceeds the L0/L1
posture by design. (Anchor target, granularity, cadence → §11.)

---

## Part B — Activation & selection invariants (ACT-1..5, propose-only)

**ACT-1 — Appending any attestation-ledger entry requires human approval, at the L0/L1 approval posture; the human retains independent initiative.**
Appending any attestation-ledger entry — a content-attestation (whether the first about a
subject or a supersession) or a revocation-withdrawal — requires human approval on every path
(proactive proposal or direct/manual call), regardless of how the selection criterion evolves.
The approval is of the same kind as the existing L0/L1 approval workflow: a human-in-the-loop
confirmation, not a cryptographic or harness-anchored consent signal — L2 attestation does not
exceed the L0/L1 security posture (LED-6). Enforcement is therefore workflow-level: a
mis-instructed agent that bypasses the workflow can append a bogus entry, which — being permanent
(LED-2a) — is answered by an appended revocation-withdrawal, not prevented; this residual is
accepted at exactly the level L0/L1 accept it, and retired for all stores at once by anchoring,
not by per-layer hardening. Operational-log records (decisions, triggers) are not
attestation-ledger entries and are governed by ACT-4/ACT-5, not by this gate. Independently of
the proposal channel, the human may initiate an attestation of any L2 context the criterion did
not propose.
*Justification.* Attestation entries are permanent judgment commitments (LED-2a), so what enters
the ledger must be human-authored: the approval requirement keeps authorship, and independent
initiative keeps *agenda-authorship* — the human on the boundary (Prop 9). Phrasing the invariant
as a *requirement* (approval must precede a valid append) rather than an absolute guarantee (no
entry can ever exist without approval) is deliberate and matches the posture: the
constitution-level layer itself uses workflow approval without cryptographic signatures, so a
working-layer convenience must not claim a stronger guarantee than L0 delivers. (Approval
surface, and how the Synoptis `automated` issuance path is routed through workflow approval → §11.)

**ACT-2 — Proposal is a recommendation, not a commitment; the criterion is revisable.**
The selection criterion produces *proposals only*: a proposal creates no attestation and no
obligation until approved. The criterion is revisable and its revisions are recorded with the
criterion itself (its own versioned L2 context, §11) — not in the attestation ledger or the
operational log; its evolution never alters ACT-1.
*Justification.* This separates "what to propose" (evolvable, fallible, LLM-judged) from "what is
attested" (human-gated). Convergence toward the user's judgment is welcomed (Prop 6; experience
as capital) precisely because errors surface at the human gate rather than in the ledger.
Recording criterion revisions with the criterion keeps the two stores' kinds closed (§Kinds).
(Criterion realization, versioning, approve/decline feedback → §11.)

**ACT-3 — A committed entry commits exactly what was approved, including what it acts on.**
Approval binds exactly the fields the entry commits (§Kinds), and the appended entry commits
exactly what was approved: for a content-attestation, the (subject, digest) pair — and, when it
is a supersession, additionally the target-entry reference it supersedes; for a
revocation-withdrawal, the (subject, target-entry reference) it withdraws. If a content
digest was approved and the live content changed before append so the digest no longer matches,
the append does not proceed silently; the change surfaces and the human re-approves (which,
under LED-2, is simply approving a fresh entry for the new state).
*Justification.* Consent attaches to the specific judgment being committed, not to a bare "yes":
for content it attaches to specific bytes (the digest), and for a supersession or revocation it
attaches to *which prior entry* is being acted on (the target reference) — otherwise a human who
approved superseding entry A could have entry B silently superseded instead. Binding approval to
exactly the §Kinds fields of each form closes the gap R3 found (a supersession whose target was
un-approved) without asserting a digest for the form that has none. (Bind-and-append realization
→ §11.)

**ACT-4 — Only declines are logged, content-free, in the operational log.**
The activation policy writes a decision record *only when it proposed a context and the human
declined*, keyed by subject identifier, content-free (§Kinds). An approval writes no decision
record — it is evidenced by the content-attestation entry it produced (ACT-1, LED-3), not
duplicated. No verdict is logged for contexts the policy evaluated but did not propose, and no
decision record binds an L2 context's content or is organized into an interpretive index over
L2 (LED-4).
*Justification.* A proposed-and-declined context is the only outcome that produces no
attestation entry yet carries a human decision worth keeping contestable (Prop 10) — and the
decline is a signal the criterion consumes (ACT-2). Logging approvals separately would duplicate
the attestation entry and reintroduce an ambiguous second record of the same act (the R2
finding). Because the decline record is content-free and binds no artifact (LED-1), it does not
deny an un-attested context its silent death — the file may still be edited or die; only the
fact "a human declined a proposal about this subject at T" persists. An evaluated-but-not-
proposed context is logged nowhere (recording every one would rebuild the index LED-4 forbids).
A decline is not permanent in effect: an evolved criterion may re-propose, and that is a fresh
decision, not a reversal. (Decision record format, declined-re-proposal handling → §11.)

**ACT-5 — Proposals fire and are surfaced, observably; firing is logged.**
At each defined trigger point — at least one must be defined — the criterion is evaluated and any
resulting proposals are surfaced to the human; the policy may not silently decline to propose,
nor evaluate without surfacing. Each firing appends a trigger record to the operational log that
distinguishes "fired and surfaced nothing" from "never ran" (§Kinds: it carries the moment and
the surfaced count, no subject and no content). These records are not attestation-ledger entries
and require no approval.
*Justification.* Propose-only removed the only force that would have guaranteed recording occurs;
without a liveness obligation the policy decays into never-proposing and the capability returns
to "implemented but never runs" — the failure this design exists to prevent. Because ACT-4 logs
only declines, firing needs its own trace to be checkable at all; the trigger record is
subject-free, so it neither indexes L2 (LED-4) nor records a per-context verdict (ACT-4), and
being policy telemetry rather than a judgment it needs no approval (ACT-1). A criterion that
fires but chronically proposes nothing is thereby visible — addressing it is criterion evolution
(ACT-2) and human initiative (ACT-1), not liveness. (Trigger point — session-end default,
save-time/scheduled optional — and record format → §11.)

## 4. Register and layer note

The capability extends the existing attestation SkillSet (Synoptis), not core. It sits under
Prop 5 (constitutive recording) and Prop 10's procedural floor (contestability: attestation
entries are surfaceable, appendable-against, and revocable-by-appending — LED-2 is the local
expression of that floor). Part B is where Prop 10 (consent) and Prop 9 (human on the boundary)
become operational, by the plainest means: the human approves each attestation, and the human
keeps the agenda.

The security register is deliberately flat: nothing here exceeds the L0/L1 posture. Two threat
levels are named and separated. The agent-level threat — an agent silently rewriting history
through the system — is excluded by LED-2(a)'s append-only structure (no edit operation), with
the one residual (a mis-instructed agent appending a bogus entry) accepted at the same level
L0/L1 accept it and answered by revocation, not prevented by hardening. The operator-level
threat — wholesale rewriting of a local store's file — is out of scope locally and retired by
external anchoring, uniformly for all stores (LED-6, §11). The v0.5.x lineage's consent-signal
hardening (harness-anchored human-only tokens, forge-resistance, two-anchor separation) is
**withdrawn as over-engineering**: it defended L2 records above the level at which L0 itself is
defended, inverting the layer architecture's own importance ordering.

Active proposal reads L2 content (the LLM-semantic criterion inspects content to judge), but
appends only ledger/log lines and never constrains the live context's editing (Prop 2).
(§§5–10 intentionally omitted; design-by-invariant body.)

## 11. Backlog (mechanism — deferred)

- Store realization: formats of the attestation ledger and the operational log; the four line
  schemas fixed in §Kinds (content-attestation, revocation-withdrawal, decision, trigger),
  including the target-entry reference format; who may revoke.
- Whether the attestation ledger reuses/extends Synoptis's proof store, and where the operational
  log lives (Synoptis, a policy-local store, or L2 context) — resolve against LED-5's separation
  and LED-4's no-index.
- Digest algorithm and canonical form. (The attested moment is fixed by LED-3/§Kinds as the
  append moment; the digest reflects the content approved under ACT-3.)
- Subject-reference scheme stable across rename/relocation; judgment-unit realization.
- Anchoring (LED-6): anchor target (public vs consortium chain), granularity, cadence, whether
  the stores share one anchoring pipeline. Uniform L0/L1/L2 deployment matter.
- Approval surface (ACT-1): how proposals are shown with subject, content state, and (for a
  supersession/revocation) the target entry; how approval/decline is captured; how the Synoptis
  `automated` issuance path routes through workflow approval; graceful approve-append
  digest-mismatch handling (ACT-3).
- Selection criterion (ACT-2): LLM-semantic realization, versioning, approve/decline feedback
  loop, where the criterion's own revision record lives, optional inspectability.
- Declined-re-proposal handling; surfaced-but-undecided proposals (pending state or recoverable
  as surfaced-count minus decline records) — advisory.
- Soft proposal-volume bound per session as a UX guard against approval fatigue — advisory.
- Synoptis integration: reconcile its duplicate-claim hard-reject with LED-2 re-attestation (a
  new entry for an already-attested subject must append as a supersession, not hard-reject);
  reconcile its revocation store with the revocation-withdrawal entry kind; retire its default
  proof TTL (an attestation entry does not expire; only anchoring depth varies).
- Target-chain fold semantics: the "current" view of a subject is a computed fold over its
  entries' target-entry references; the ordering policy for chained acts (whether an
  already-superseded or already-withdrawn entry may itself be the target of a further
  supersession/revocation, and how the fold resolves such a chain) is a mechanism detail. It is
  §11, not an invariant: the append-only ledger already records every act, and re-attestation
  is a supersession (§Kinds), so the fold is well-defined once its ordering rule is fixed here.
- Graph-driven selection (attest a target plus the closure of its causal-ancestor edges).

## Open tensions (Aufhebung-pending)

**(i) Two-speed L2.** Attested subjects acquire a permanent trace while un-attested contexts
stay mortal. The bank-ledger model softens the earlier form — the *live context* is never
frozen, only ledger lines accumulate — but the ledger itself still grows monotonically,
human-paced. Whether human-paced monotonic accumulation diverges meaningfully from an automatic
one over long timescales is an empirical question held open.

**(ii) Annotation vs index.** Discovering "all attested contexts" requires scanning the ledger,
not querying an interpretive index over L2 (LED-4 holds annotate-only). Whether this stays
acceptable as the ledger grows is not yet observed; observation may redraw the boundary.

**(iii) Convergence and the hollowing of approval.** As the criterion converges (Prop 6),
per-attestation approval risks becoming reflexive; the *right* to dissent stays structurally
intact (Prop 9) while the *disposition* to dissent may atrophy. The design's hoped-for success
could hollow the judgment propose-only exists to protect. Held open.

**(iv) Constitutive recording vs consent (Prop 5 ↔ Prop 10).** Consent scopes "computing =
recording" from all of L2 to the proposed-and-approved subset. Deliberate trade: recording the
human did not author would constitute a *different* being than the one the human is composing
with. The operational log's trigger records keep a thin form of "the system ran and recorded
that it ran" alive even where no attestation was authored, but the *judgment* stays un-attested;
the residue — judgments that would merit an entry but are never proposed and never occur to the
human — is the named price of human authorship. Both poles stay load-bearing; Prop 5 rescoped,
not defeated.

Neither tension is classified by severity; challenges are recorded and classified at promotion
time via the L2 → L1 → L0 path.

## Revision provenance (v0.8 → v0.9)

R3-of-v0.8 (5/6 APPROVE — convergence threshold 4/6 met; R1/R2 findings all confirmed closed;
taxonomy structurally closed by §Kinds; posture ceiling held for the third consecutive round,
**zero consent-hardening P0s**) left one genuine residual, echoed by codex 5.4 (REJECT), cursor,
and the orchestrator persona — a lineage-reference precision gap. Closed here without new
invariants (still LED-1..6 + ACT-1..5 = 11; §Kinds remains definitional):

- **Lineage reference bound and unified** (codex 5.4 P1×2, cursor P2, fable5/persona P3): (i)
  §Kinds now defines the **lineage reference** once — it denotes the *target entry* a supersession
  supersedes or a revocation-withdrawal withdraws, not merely "the chronological previous line";
  (ii) **ACT-3** now binds a supersession's approval to (subject, digest, target-entry reference)
  and a revocation's to (subject, target-entry reference), closing the gap where a supersession's
  target was un-approved (a human could approve superseding A and have B superseded); (iii)
  **LED-2(b)** references the *target* entry consistently, removing the "follows" vs
  "supersedes/withdraws" divergence; (iv) **ACT-1** and §Kinds state that a re-attestation of an
  already-attested subject *is* a supersession, so the approval-gated entry forms match §Kinds'
  two kinds (no informal third "re-attestation" kind).
- **Hygiene (c)**: §Kinds' decision-record line trimmed toward definitional minimum (the "not
  duplicated" rationale lives in ACT-4, not restated in §Kinds).

Method note: the same "define the distinction once, reference it everywhere" move that closed the
R1/R2 kind recurrence (§Kinds) is applied to the lineage reference here. No new invariant; the
fix is field-binding precision, not a design change.

## Convergence (R4-of-v0.9) — FROZEN

R4-of-v0.9 (2026-07-05) reached **6/6 APPROVE — unanimous**, the first fully unanimous round
across the whole R1→R4 arc (roster: claude_team_fable5, claude_cli_opus4.6, codex_gpt5.4,
codex_gpt5.5, cursor_composer2.5, claude_team_opus4.8). Zero blocking (a)/(b) findings. The only
observation was a (c) advisory — target-chain fold semantics — folded into §11 above (a mechanism
detail, not an invariant gap). The posture ceiling held for the fourth consecutive round with zero
consent-hardening P0s.

Arc summary: R1-of-v0.6 (1/6, entry overload → two stores) → R2-of-v0.7 (3/6, sub-kind
quantification → §Kinds four kinds) → R3-of-v0.8 (5/6, lineage-reference precision) → R4-of-v0.9
(6/6, closed). The recurring lesson — a taxonomy defect kept re-appearing one level down while
carve-outs were scattered across invariants; defining each distinction *once* (§Kinds for kinds,
the lineage reference for targets) and referencing it everywhere is what stopped the recurrence
and is the anti-enumeration-compliant fix.

**FROZEN 2026-07-05.** Ready for design → implementation planning. The eleven invariants
(LED-1..6 + ACT-1..5) and the definitional §Kinds vocabulary are the contract; all mechanism is
in §11. Distribution: extends the Synoptis SkillSet (L1), not core; adopted via the L2 → L1 → L0
promotion path.
