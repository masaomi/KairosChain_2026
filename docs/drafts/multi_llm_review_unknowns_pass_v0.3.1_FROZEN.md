# Unknowns Pass — Pre-Draft Unknown Discovery for Design Reviews

**Version:** v0.3.1 draft
**Target artifact:** L1 `multi_llm_review_workflow` v3.5 → v3.6 (new Step 0.25)
**Author:** Fable 5 (orchestrator) with Masaomi Hatakeyama
**Date:** 2026-07-05
**Status:** FREEZE CANDIDATE — R3 reached 4/6 APPROVE; v0.3.1 dissolves the residual (b)-class editorial findings surgically (no invariant substance changed). Changelog in §12.

---

## 1. Problem

The multi-LLM review workflow begins at "artifact exists." Unknowns that the
author has never considered (blind spots) enter the draft undetected and are
excavated by reviewers round by round. This inflates round counts and feeds
the perpetual-new-P0 pattern: each round, reviewers surface unresolved design
questions as fresh blocking findings.

Step 0.5 (Design Direction Block) already requires declared scope, rejected
alternatives, and tradeoffs — and states that an artifact whose scope cannot
be cleanly declared is not review-ready. What the workflow lacks is the step
that *produces* that readiness: a deliberate pass that surfaces unknowns
before drafting, resolves the decision-shaped ones with the human, and
declares the rest.

This design moves unknown discovery from the expensive channel (review
rounds) to the cheap channel (pre-draft dialogue), and makes the residue
explicit rather than latent.

## 2. Scope

**Applies to:** artifacts that the workflow's existing decision heuristic
routes to full multi-LLM review, in the design-phase and
knowledge/documentation review types (in the target L1's own vocabulary:
design review, knowledge/documentation-update review, and document review).
Throughout this design, "qualifying review" means exactly this set. Artifacts below that threshold (single-LLM
review, self-review, skip) are exempt — the pass inherits the workflow's
tier heuristic rather than introducing a second gate.

**Solves:**
- A pre-draft discipline (Step 0.25) that surfaces the author-orchestrator's
  unknowns before the first draft of a qualifying artifact.
- Classification of reviewer findings that merely restate an already-declared
  unknown.
- Compatibility with unattended execution contexts (autonomous loops), where
  no human is available to answer.

**Does NOT solve (out of scope):**
- Implementation-phase reviews. The pass applies to qualifying reviews only,
  mirroring Step 0.5's scope rule.
- Tooling or automation of the interview. This is workflow discipline; a
  mechanism may be extracted later only if the discipline survives use
  (selective survival). → §11
- A standalone L1 for unknown-discovery patterns in general. → §11
- Elimination of unknowns. Per Prop 6, incompleteness is a driving force,
  not a defect; the pass reduces and declares, it does not zero out.

## 3. Structure of the pass

Step 0.25 runs after the decision to produce a qualifying artifact and
before its first draft. It has two moves and one triage:

1. **Blindspot enumeration.** The orchestrator, holding full project context,
   enumerates the questions most likely to change the design if answered
   differently — *without answering them itself*. This is a bounded search
   discipline, not a completeness guarantee: the pass is judged by whether it
   reliably surfaces the highest-impact questions available to the
   orchestrator's current context, not by whether nothing was missed
   (nothing-missed is unachievable per Prop 6).
2. **Interview.** The orchestrator puts the enumerated questions to the human,
   one question at a time, ordered by decision impact. The interview ends when
   both parties judge that remaining questions will only be answerable once a
   draft exists. Ending the interview does not discharge the triage below:
   every enumerated unknown — including those the interview never reached —
   still exits through it.

**Triage.** Every surfaced unknown exits the pass in exactly one of two
**terminal** states, possibly via one **transient** state:

- **Resolved** (terminal) — answered by the human; the answer feeds the Design
  Direction Block (an unknown known has become a known known).
- **Declared** (terminal) — recorded in the artifact as an *Open Unknown* and
  registered in the artifact's §11 backlog (an unknown unknown has become a
  known unknown). A human's explicit decision *not* to answer a question is
  itself a human judgment and routes the unknown here — a legitimate attended
  outcome that does not violate INV-U2, because the human, not the
  orchestrator, made the call.
- **Draft-deferred** (transient, non-terminal) — marked for mandatory
  re-triage after drafting. Re-triage collapses each draft-deferred unknown
  into Resolved or Declared **before review dispatch**; this re-triage is a
  precondition of dispatch under INV-U1, not an optional follow-up. INV-U2
  applies at re-triage exactly as at the interview: collapsing to Resolved
  requires the human's answer, so unattended re-triage can only collapse to
  Declared.

## 4. Invariants

**INV-U1 (front-load gate).** Round 1 of a qualifying review (design-phase
or knowledge/documentation type, per §2) is not dispatched for an artifact
that has not passed through the Unknowns Pass. At dispatch time, every
unknown the pass surfaced is in a terminal state: resolved by the human, or
declared in the artifact. A draft-deferred unknown still in its transient
state blocks dispatch until re-triaged (§3).

**INV-U2 (human gate).** The answerer in the interview is the human. The
orchestrator posing a question and answering it itself does not constitute
resolution. (Same conceptual line as ACT-1 in L2 attestation — analogical,
not a shared implementation: judgment-shaped decisions belong to the human.)

**INV-U3 (constitutive recording).** The products of the pass — enumerated
questions, human answers, declared Open Unknowns — are recorded to L2. A
discovered unknown is an asset, not a consumable. (This is the addition
KairosChain makes beyond the source article, which ends at "the discovery
feeds the next prompt.") Two corollaries: the record is instance-local, and
outbound sharing of it is governed by whatever outbound-sharing discipline
the instance already operates (in this instance, the active instruction
mode's Meeting Place rules) — this invariant itself authorizes no new
disclosure surface; and the *absence* of this record is observable evidence
that the pass was not run, so a skipped pass is distinguishable from a pass
that surfaced nothing. To make that distinction real, the record is written
unconditionally: a pass that surfaces no unknowns writes an explicit
zero-result record.

**INV-U4 (declared unknowns are non-blocking — bounded).** A reviewer finding
that merely restates a declared Open Unknown is classified (c) advisory by
default, **subject to two bounds**:

- *Provenance bound*: the demotion applies only to unknowns whose specific
  declaration a human has seen — i.e., declared through an attended pass, or
  ratified by a human at a subsequent attended session. Declarations made by
  an orchestrator alone — including declarations made unattended under a
  mandate's category-level pre-classification, where the human authorized
  the *category* but never saw the *specific* unknown — carry no demotion
  power until so ratified.
- *Inverted default*: when the orchestrator is uncertain whether a finding
  merely restates a declared unknown or shows that the declared deferral is
  itself unsafe, the finding is treated as blocking. This deliberately
  inverts the workflow's usual "unsure between (b) and (c) → (c)" rule,
  because here the doubt concerns whether a gate is being laundered, and
  gates fail closed.

Findings about the *integrity* of the design — internal contradiction,
unrealizable invariant, an Open Unknown whose declared deferral is itself
unsafe — remain (a)/(b) and block as before.

INV-U4 is the convergence lever: Step 0.5 already demotes out-of-scope
expectations to (c); INV-U4 closes the remaining channel through which
undeclared open questions re-enter each round as fresh P0s — without opening
a reverse channel in which declaring everything demotes every reviewer.

**INV-U5 (classification authority).** The judgment-shaped /
non-judgment-shaped classification of an unknown (§5) is a human
prerogative. Attended, the human exercises it through the interview itself
(answering, declining, or judging a question draft-answerable). Unattended,
every surfaced unknown is judgment-shaped by default; only a human-authored
mandate may pre-classify named categories of unknowns as non-judgment-shaped
for a given run. An orchestrator's self-classification has no force.
(Fail-closed: unclassified ⇒ judgment-shaped ⇒ stop.)

## 5. Compatibility clause — unattended execution

The pass has two terminal exits for an unknown ("resolved" and "declared";
draft-deferred is transient per §3). In an unattended context (e.g., an
autonomous growth loop invoking a qualifying review from inside a run), the
"resolved" exit is unavailable because no human can answer. INV-U2 is
preserved unmodified — the system does not self-answer — and INV-U5 governs
who may classify:

| Nature of unknown | Attended | Unattended |
|---|---|---|
| **Judgment-shaped** (unattended default for ALL unknowns per INV-U5) | Interview, one question at a time; exits Resolved or (on human decline) Declared | **Fail-closed stop**; the question is recorded and queued for the next attended session (keep-fire: minimal heartbeat, not extinction) |
| **Non-judgment-shaped** (attended: so judged by the human during the interview; unattended: only via mandate per INV-U5) | Exits via §3 triage — Declared, or draft-deferred with mandatory re-triage before dispatch | Declared as Open Unknown; run proceeds, but per INV-U4's provenance bound the declaration carries no demotion power until human-ratified — reviewer restatements remain blocking |

Consequence: an unattended run without a mandate cannot proceed past any
surfaced unknown — it stops on the first one. This is intended: it makes
"unattended design review without human pre-delegation" structurally inert
rather than quietly self-certifying. And even with a mandate, unattended
declarations do not weaken reviewers (INV-U4 provenance bound), so an
unattended loop gains no convergence advantage from declaring liberally —
the honest cost is that unattended reviews converge only as far as their
findings genuinely allow.

Stop semantics, as an invariant: repeated unattended encounters with the
same pending question produce no new side effects and no forward motion —
re-stopping is idempotent. Forward motion requires a human answer; the
absence of forward motion until then is the designed outcome, not a
livelock to be engineered away. (The queue/persistence mechanism that
realizes this invariant is deliberately unspecified here → §11, guard
track.)

Two known limits, deferred cleanly: the mandate's expressive power (which
categories may be pre-classified, whether a mandate may declare "no human
available — treat every unknown as stop") is a mandate-side design question
owned by the Autonomous Growth Loop guard track; and enumeration
completeness in the unattended path has no counterparty check — the pass
surfaces what the orchestrator's context affords (§3), and the residual risk
that an unattended orchestrator under-enumerates is part of why unattended
operation remains design-gated off in that track. → §11

## 6. Rejected alternatives

- **Host the pass in `design_to_implementation_workflow`.** Rejected: the
  review-readiness gate (Step 0.5) lives in `multi_llm_review_workflow`;
  the discipline that produces readiness belongs beside its enforcement
  point. The lifecycle L1 gets a one-line cross-reference only.
- **Implement the interview as an MCP tool / Skill.** Rejected for now:
  discipline first, mechanism only after survival is observed (same
  treatment as PASS+S).
- **Delegate blindspot enumeration to external reviewers.** Rejected: before
  drafting there is no artifact to ship to a subprocess reviewer, and the
  orchestrator is the only party holding full project context at that moment.
- **Permit orchestrator self-classification with audit (instead of INV-U5's
  human-only rule).** Rejected: audit detects laundering after the fact;
  INV-U5 prevents it. The cost — unattended runs stop on every unknown
  absent a mandate — is acceptable because unattended design review is
  currently design-gated off anyway.
- **Grant mandate-authorized declarations demotion power (instead of the
  ratification requirement).** Rejected: a mandate authorizes categories,
  not specific unknowns; demotion power without a human having seen the
  specific declaration reopens the laundering channel INV-U4 exists to
  close.

## 7. Tradeoffs adopted

- **Discipline over mechanism**: enforcement is procedural (workflow text),
  not automated gating, until the pass proves itself.
- **Front-loading over exhaustiveness**: the pass spends a bounded, cheap
  dialogue to remove what it can and declare what it cannot; it does not
  attempt completeness (Prop 6).
- **Consistency over novelty**: the unattended clause reuses the existing
  judgment-shaped criterion (analogically) and fail-closed posture rather
  than inventing a new taxonomy.
- **Fail-closed over throughput (unattended)**: INV-U5's human-only
  classification and INV-U4's ratification requirement make unattended
  passes stop early and converge slowly. Chosen deliberately over
  audit-based and mandate-demotion alternatives (§6).

## 8. Provenance

Source: Thariq Shihipar (Anthropic), "A Field Guide to Fable: Finding Your
Unknowns," X article, 2026-07-03
(https://x.com/trq212/article/2073100352921215386). The article body is
paywalled from this environment; details were corroborated via summary
coverage (one-question-at-a-time interviewing; volatile decisions first in
implementation plans). Techniques adopted here: blindspot pass (①) and
interview (③). If the full text becomes available, it should be preserved
under the L1's `references/` with this note upgraded from summary-level to
full-text provenance.

## 9. Acceptance criteria

Measurement is forward-only: past loops (Context Graph, L2 attestation,
INV-10) were not finding-tagged and serve as qualitative reference only, not
as a numeric baseline. Criteria apply to qualifying loops (design-phase and
knowledge/documentation, per §2).

- **Tagging rule**: from adoption onward, during synthesis the orchestrator
  tags each blocking finding — and each finding demoted under INV-U4 — as
  kind `open-question` (the finding is an unresolved design decision) or
  kind `defect` (the finding is a flaw in a made decision). The tag is
  recorded in the round's L2 review record. (Demoted findings are tagged so
  that criterion 2 is evaluable.)
- **Criterion 1**: across the first 2–3 qualifying loops run with the pass,
  the per-loop count of round-1 `open-question` blocking findings trends
  toward zero. (Directional, not thresholded: the selective-survival
  judgment is the human's, made on recorded counts.)
- **Criterion 2**: no finding demoted to (c) under INV-U4 is later re-tagged
  as kind `defect` within the observation window — the remainder of the
  qualifying loop in which it was demoted plus the artifact's next revision
  cycle.
- **Criterion 3**: interview cost stays bounded: if passes routinely exceed
  ~5 questions or stall, the cut-off rule needs redesign, not more
  questions. (Premature cut-off is monitored through criterion 1: unknowns
  missed by an under-run interview reappear as round-1 `open-question`
  findings.)

## 10. Changes upon freeze

- `multi_llm_review_workflow` v3.5 → v3.6:
  - add Step 0.25 as a new section carrying this design's **§3, §4, and §5
    in full** — the pass structure, all five invariants INV-U1–U5, and the
    unattended compatibility clause. Note on numbering vs timing: Steps 0
    and 0.5 execute at review time (immediately before dispatch); Step 0.25
    executes **pre-draft**, earlier in wall-clock time than both, and the
    section text states this explicitly so the numeric order is read as
    document order, not execution order;
  - update the **Workflow Pattern diagram** to make the lifecycle explicit
    for qualifying artifacts: [0.25] Unknowns Pass (pre-draft) → [1] primary
    LLM creates artifact + review prompt (unchanged, and re-triage of
    draft-deferred unknowns completes here per §3) → [2] dispatch,
    **conditioned on INV-U1**: dispatch proceeds only when the pass's L2
    record exists and every surfaced unknown is terminal → [3] unchanged →
    [4] extended as below;
  - extend **Step 0.5** (Design Direction Block) with one field: declared
    Open Unknowns carried in from the pass;
  - extend **workflow step [4]** (finding classification) with INV-U4's
    demotion rule and its two bounds, **and** with §9's tagging rule
    (`open-question` / `defect` kinds recorded per round);
  - extend the **L2 Save Points** section with two entries: after the
    Unknowns Pass (unconditionally, including zero-result passes, per
    INV-U3) and the per-round finding-tagging requirement;
  - three-location sync (instance `.kairos/knowledge/`, gem `knowledge/`,
    gem `templates/knowledge/`); blockchain record.
- One-line cross-reference from `design_to_implementation_workflow`.
- This change is itself an L1 design change → self-referentially subject to
  this workflow's own multi-LLM review (precedent: v3.0, v3.5).

## 11. Backlog (not in this design's body)

- Standalone L1 `unknown_discovery_patterns` (sister to
  `skill_authoring_patterns` / `loop_engineering_patterns`) if the pattern
  proves useful outside review preparation.
- Mechanization of the pass (tool-enforced gate) after survival is observed.
- INV-10 run-mandate extension: mandate-side expressive power for
  pre-classifying unknown categories (per INV-U5), for declaring all-stop
  runs, and a ratification protocol by which a human retroactively grants
  demotion power to unattended declarations (per INV-U4's provenance
  bound). Owned by the Autonomous Growth Loop guard track.
- Pending-question queue: the persistence and deduplication mechanism
  realizing §5's idempotent-stop invariant (storage, identity of "the same
  question", resumption surfacing). Owned by the same track; until built,
  the invariant binds the orchestrator procedurally like every other
  discipline in this design.
- Unattended enumeration-completeness counterparty (e.g., independent
  enumerator): only relevant if unattended design review is ever un-gated;
  owned by the same track.
- Techniques ② (best-of-N brainstorm) and ⑤ (volatile-decisions-first plan
  ordering) from the source article — deliberately not adopted in this
  design; re-evaluate after ①/③ observation.
- Full-text provenance upgrade for the source article.

## 12. Changelog

- **v0.3.1 (2026-07-05)** — freeze-candidate revision after R3 (4/6 APPROVE
  threshold reached; residual REJECTs carried two (b)-class editorial slips
  and mechanism-class items). Surgical fixes, no invariant substance
  changed: §10 change list now carries §4 (all five invariants) explicitly
  and conditions dispatch step [2] on INV-U1; INV-U3 requires an
  unconditional (including zero-result) pass record, making the
  skipped-vs-empty distinction real; L2 Save Points gains the pass-record
  entry; §5 stop semantics restated as invariant with the queue mechanism
  moved to §11 (new pending-question-queue backlog item); §3 re-triage
  states INV-U2 applies (unattended re-triage collapses only to Declared);
  §9 tagging extended to demoted findings so criterion 2 is evaluable; §2
  qualifying-review vocabulary aligned with the target L1's review-type
  names; lifecycle wording "[3]/[4] unchanged" corrected.
- **v0.3 (2026-07-05)** — revision after R2 (REVISE, 2/6; six blocking
  clusters, all seams of the v0.2 fixes). (1) Attended non-judgment-shaped
  path now has defined exits: §5 table cells name the §3 triage states;
  §3 interview move states that ending the interview does not discharge
  triage. (2) INV-U1 (and §5, §9) now gate "qualifying review" = design +
  knowledge/documentation per §2, removing the scope mismatch. (3) §10
  numbering-vs-timing contradiction resolved: explicit note that Step 0.25
  is document-ordered, not execution-ordered; Workflow Pattern lifecycle
  spelled out with first-draft creation and re-triage placed at step [1].
  (4) INV-U4 provenance bound tightened: mandate category-level
  authorization does not confer demotion power; specific declarations must
  be human-seen or human-ratified (new rejected alternative records the
  why; §11 gains the ratification-protocol item). (5) INV-U3 no longer
  cites a nonexistent named policy; refers to the instance's operating
  outbound-sharing discipline. (6) §10 wires §9's tagging rule into step
  [4] and L2 Save Points. Cleanups: decline-to-answer moved to the Declared
  bullet (§3); §9 criterion 2 uses the `defect` tag vocabulary; INV-U5
  states how attended classification is exercised (through the interview).
- **v0.2 (2026-07-05)** — revision after R1 (REVISE, 2/6; clusters 1–7):
  triage state model reconciled (draft-deferred transient); INV-U5 added
  (human-only classification, fail-closed); INV-U4 bounded (provenance +
  inverted default); §10 placement extended; §9 forward-only measurement;
  §2 tier inheritance; §3 blindspot reworded. Human decisions Q1/Q2
  approved by masaomi.
- **v0.1 (2026-07-05)** — initial draft.
