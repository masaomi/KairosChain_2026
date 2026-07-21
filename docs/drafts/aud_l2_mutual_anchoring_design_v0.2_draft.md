---
title: "Auditability: Symmetric Mutual Anchoring across Instances — Design v0.2 (AUD-L2)"
author: Masaomi Hatakeyama
date: 2026-07-21
version: 0.2
status: DRAFT for multi-LLM review (round 2)
supersedes: docs/drafts/aud_l2_mutual_anchoring_design_v0.1_draft.md
dispositions:
  - docs/drafts/.aud_l2_mutual_anchoring_r1_disposition.md
inherits:
  - docs/drafts/auditability_head_anchor_design_v0.3_draft.md (MPR-1..9, FROZEN)
  - docs/drafts/hestia_anchor_attestation_design_v0.5_draft.md (ANC-1..9, one-way rule §5, human-gate non-goal)
  - docs/drafts/attestation_home_migration_design_v0.3_draft.md (AHM-1..9, esp. AHM-4)
  - docs/drafts/unified_deposit_board_design_v0.3_draft.md (BRD-1..4)
seeds:
  - L2 handoff_aud_l2_mutual_anchoring_dee_design_20260721
  - L2 dee_attestation_network_design_draft_20260721 (material only, not a reviewed design)
method: design-by-invariant / anti-enumeration. Mechanism choices live only in §11. §6-10 intentionally absent.
scope: design phase only; implementation is a separate phase. Realizes the L2 level of the frozen design's §5 growth path. AUD-L1.5 (content bridge), AUD-L3 (reproduces), AUD-L4 (ZK) are out of scope and appear only as connection points.
---

# AUD-L2 Mutual Anchoring Design v0.2

## §1 Purpose

AUD-L1 established head-anchoring discipline for a single chain: the MPR invariants let a third party verify membership, integrity at anchor time, and order against anchored cumulative commitments, and they disclose exactly where the resulting claims stop being operator-independent — the auditor's view of the anchor log, and the credibility of a same-party anchor, remain residuals deferred to this level. AUD-L2 addresses those residuals for the case that arises naturally from federation between instances: two operators inscribe each other's chain heads. The central design decision is that the partner acts as an ordinary foreign depositor under the inherited relational frame (ANC-8): no new mechanism kind is introduced. What is new is the relational structure — each party's committed head comes to rest in a log outside its own control — and this document states what that structure verifiably delivers, under which conditions the stronger audit readings hold, and which limits it inherits rather than escapes. The register is the one the frozen lineage established: every claim carries its trust base and its limits inside the invariant that makes it.

## §2 Scope and Non-Goals

**Scope.** The properties of mutual head inscription between instances, the properties of self-authenticating chain identity and its succession, the outcome-independence discipline whose enforceable home the frozen design deferred to this level, and the type separation of attestation vocabulary.

**Non-goals.**

- AUD-L1.5 content bridge. Connecting the operator's canonical works and their digests to the chain's committed record is a separate slice; this design neither defines nor constrains that bridge beyond providing the anchor-log side it will reference.
- Exclusive assets. Double-transfer prevention — guaranteeing that an exclusive right was not also conveyed elsewhere — cannot be closed by attestation alone; it requires an ordering consensus this design deliberately does not contain. Provenance and reputation are evidenced here; exclusive ownership must live on an external system built for it. In the MPR-5/6 disclosure register: an attestation of provenance is evidence that a party claimed provenance at a bounded moment, never proof that no competing claim exists.
- Trust composition and Sybil resistance. How much a mutual-anchor relationship is worth — weighting by history, independence judgment across operators, thresholds — is deferred until real mutual-anchoring data exists (§11); designing it beforehand would encode assumptions the first real relationships would overturn. Until then, partner independence is an assumption the auditor supplies, not a property this design establishes.
- Anchoring cadence, coordination, and reciprocation mechanics; the depth of any mapping to external credential standards; AUD-L3 re-execution (pursued on the GenomicsChain side, connected here only through the vocabulary); AUD-L4 zero-knowledge disclosure.

**Inherited invariant families.** ANC-1 through ANC-9 (including the §2 non-goal that anchoring the operator's own canonical works stays a human act), AHM-1 through AHM-9, BRD-1 through BRD-4, and MPR-1 through MPR-9 remain in force without modification. References to inherited invariants by ID are for traceability only — no inherited invariant is restated, narrowed, or extended here. In particular, where this design speaks to the ANC-4/6 residuals, it supplies material toward them; it does not amend them.

## §3 Kinds

This section establishes vocabulary only; every constraint appears in §4.

### (a) Mutual anchor

A mutual anchor is a pair of anchor entries, one in each of two instances' anchor logs, each carrying the other chain's AUD-L1 head binding under the foreign relation. The two entries are independent appends: neither depends on the other, no coupling exists between the logs, and no completion obligation attaches — an entry whose counterpart never appears is an ordinary unilateral foreign-deposit anchor, a disclosed and legitimate state, not a defect. The mutual relationship is a property of the pair, read by whoever holds authentic views of both logs.

### (b) Chain identity credential

A chain identity credential is a self-authenticating identifier: verifying that an attestation was issued by the chain it names requires nothing beyond the credential, the attestation, and material derivable from them — no external registry and no certificate authority. Two properties compose it: a content-derived component tying it to the chain's committed history (the committed chain identity MPR-9 quantifies over), and a signature capability letting the chain issue attestations a stranger can verify against the credential alone. Derivation and encoding are mechanism (§11).

### (c) Succession

Succession is the designation of one chain identity as the continuation of another. It governs who may henceforth speak for and extend a history; it never governs the arithmetic validity of past attestations, which are verifiable against the old credential regardless of whether the old chain still operates or any successor exists.

### (d) Attestation type

An attestation type is a declared category on an attestation entry naming its evidential role — what kind of claim the entry makes. Types are characterized by two axes that vary independently in principle, though any particular type fixes a position on each: whether the claim is outcome-blind or outcome-aware, and whether issuing it is automated or judgment-gated. The vocabulary is finite at any moment and extensible over time; extension does not modify the anchoring mechanism, because the type is a property of the attestation entry, not of anchoring.

### (e) Anchoring discipline

Anchoring discipline is the outcome-independence property MPR-5 named and deferred: the occurrence and content of an operator's audit head anchors do not vary with any result — no review verdict, validation outcome, or judgment selects which heads get anchored. It is distinct from endorsement, which records that a judgment was rendered and is therefore outcome-aware by nature; endorsement lives in the type vocabulary (§4 MAP-4), not in the anchoring mechanism.

## §4 Invariants: MAP (Mutual Anchoring Properties)

**MAP-1. Symmetric inscription with a disclosed evidentiary reach.** Each instance inscribes the partner's AUD-L1 head binding as an ordinary anchor entry on its own log — foreign relation per ANC-8, additive in the AHM-4 sense, no new mechanism kind — and the two inscriptions are independent appends with no coupling and no completion obligation. What a verified pair establishes is exactly this: each party's committed head, at a committed position, in a log that party does not control. Every stronger reading is conditional and the conditions travel with the claim: the temporal weight of an inscription reaches only as far as the inscribing log is itself anchored under its own AUD-L1 discipline (wall-clock remains informational per MPR-8); equivocation detection requires that someone actually obtains and cross-compares both logs, and that the partners are independent — a colluding or common-operator pair can fabricate, omit, or rewrite the entire relationship, and this design does not establish independence (§2). The inscription therefore supplies split-view detection *material* toward the ANC-4/6 residuals; it does not close them, and no reader of this document may take a mutual anchor as more than that without the stated conditions in hand.

*Justification.* The relational structure genuinely adds what a single-party anchor cannot: a commitment resting where the committed party cannot reach it, which is simultaneously a time bound from outside (as strong as the outside log's own anchoring, no stronger), contradiction material against a later different head (operative only between anchored moments and only for a consulter of both logs — per MPR-9, absence of contradiction proves nothing), and a step out of the who-anchors-the-anchor regress — a step, not an exit, because the regress terminates in a relationship whose worth is exactly the partners' independence, which remains an auditor-supplied premise until trust composition exists. Stating the reach and its conditions inside the invariant is the frozen lineage's own register (MPR-4 carries its trust base, MPR-9 its non-production rule); the alternative — a flat "the surface is closed" — would sell the appearance of external verification, which is precisely what ANC-8 exists to prevent, and would extend a frozen family this document promised to leave untouched.

**MAP-2. Self-authenticating identity with succession by prior designation.** A chain identity credential is self-authenticating as defined in §3(b), and it extends — never replaces — the committed chain identity MPR-9 quantifies over: the current content-derived form remains valid under its original verification procedure, and any changeover between identity forms is anchor-log-visible and terminates extension claims under the prior form, exactly as MPR-9 provides. Succession is established only by a designation record committed on the old chain while its authority was in force; where no such record exists, the history is orphaned — still arithmetically verifiable against the old credential, but with no party entitled to speak for or extend it — and this design prefers a disclosed orphan to any external re-attribution. Two limits are part of the invariant: succession authority coincides with the credential's own authority, so whoever holds the signing capability — including an attacker who compromised it — holds the power to designate, and no artifact distinguishes the two; and competing designations on divergent forks are decidable only up to the consistency limits MPR-9 and MAP-1 already state, never beyond them.

*Justification.* Self-authentication is forced by the P2P-natural principle (an external registry that could say who a chain is could also say it falsely, becoming the single authority the architecture refuses), and the extension relation to MPR-9 is forced by the inheritance rule — a fresh identity scheme that invalidated existing committed identities would rewrite a frozen family. The succession rule answers "who speaks for a dead chain?" with the only answer that requires no new trust: the chain itself, in advance, on its own record. That answer honestly fails in two ways and the invariant says so rather than papering over them: an unanticipated loss leaves no designation (the orphan outcome — strictly better than letting anyone else claim the history, because verifiability of the past never depended on the chain's liveness; that separation of arithmetic from entitlement is the point of §3(c)); and a compromised key designates convincingly (disclosed because a succession that claimed to survive key compromise would be claiming to verify intent, which no signature can). Fork-bounded decidability keeps succession inside the evidentiary reach the rest of the design establishes instead of quietly assuming a consensus that does not exist.

**MAP-3. Outcome-independence, legislated at home and disclosed abroad.** For the operator's own audit chain-head anchors, this design legislates the discipline MPR-5 deferred: occurrence and content of head anchors do not vary with any outcome, and a conforming operator's anchoring practice is structured so that no result — of review, validation, or judgment — can select which states get anchored. For a foreign partner, the same property is a conformance condition, not an enforceable obligation: nothing in one operator's design can bind another operator's practice, and no artifact verifies an epistemic state — what an operator "knew" when anchoring is not auditable; what accumulates instead is consistency of practice across a growing anchor history, read under the ANC-8 relational frame. This discipline applies to audit chain-head anchors only. Anchoring of the operator's own canonical works remains a human act under the inherited ANC non-goal, and outcome-aware endorsement belongs to the type vocabulary (MAP-4) — the boundary between "this state existed" and "this work is endorsed" is a boundary between kinds, and neither side may perform the other's office.

*Justification.* The discipline must live somewhere for MPR-5's conditional audit reading ("all computations are represented") ever to activate, and this level is its designated home; but legislating it beyond the local operator would repeat, one level up, the overclaim the lineage keeps refusing — promising verification of what artifacts cannot show. The honest split is enforce-at-home, disclose-abroad: locally the property is a design obligation; remotely it is a claim whose credibility is earned the same way all same-party claims are earned in this lineage, by accumulated consistency under a relational label that never hides who is speaking. The kind-boundary clause carries the hard-won AUD-L1 lesson forward in its exact shape: automating the audit head is this level's business; automating the human gate on canonical works is nobody's business, and an anchor entry must never be readable as an endorsement nor an endorsement issue as a reflex.

**MAP-4. Typed attestation vocabulary with declared, non-self-certifying types.** Every attestation entry presented as conforming to this design declares its type from the vocabulary of §3(d), and the declaration is the issuer's claim about the entry's evidential role — it is not self-certifying, and misdeclaration is detectable only through whatever verification path the declared type itself carries, a limit this design states rather than repairs. The vocabulary names one type normatively, because the MAP-3 boundary requires it to exist: quality-endorsement, the outcome-aware, judgment-gated type in which "this work is endorsed" lives, and through which AUD-L3 re-execution will connect. Retraction is itself an appended, typed entry — nothing is ever unsaid by deletion, in keeping with the append-only substrate. The initial concrete vocabulary beyond these commitments, and any mapping to external credential standards, are mechanism and deferral (§11).

*Justification.* Without declared types, every attestation reads alike and the consumer cannot scale scrutiny to the kind of claim being made — a deterministic integrity digest and a judgment of quality would carry the same face, which is precisely the conflation MAP-3 forbids at the mechanism level, reappearing at the vocabulary level. Naming only quality-endorsement in the invariant keeps the body at property level (the boundary needs that type to exist; it does not need a taxonomy), while the two-axis characterization in §3(d) constrains all future types without enumerating them. The non-self-certifying clause is the disclosure that keeps the typed vocabulary honest: a type is a claim of role, not a proof of role, and pretending otherwise would let a mislabeled endorsement borrow the credibility of an integrity check. Retraction-as-appended-entry extends constitutive recording to the act of taking back — the record of having claimed, like every record in this lineage, does not un-happen.

## §5 Growth Path

The MAP properties are a fixed relational foundation; later levels strengthen the conditions under which the same artifacts are believed. The AUD-L1.5 content bridge — connecting canonical works and their digests to the committed record — is a separate slice that will reference the anchor-log side defined here without modifying it. AUD-L3 adds the correctness dimension MPR-6 excludes: an independent party re-executes recorded computations and endorses reproducibility by foreign attestation, entering the vocabulary through the quality-endorsement type MAP-4 names; it is pursued on the GenomicsChain side. AUD-L4 applies zero-knowledge techniques so that membership or type claims can be shown without revealing which record or what content, over the same entries and credentials defined here. Trust composition — how much a web of mutual anchors is worth, weighted by history and independence — is deliberately not a numbered level: it is deferred to §11 until real mutual-anchoring data exists, and until then every multi-party reading of MAP artifacts carries the auditor-supplied independence premise MAP-1 disclosed.

## §6–§10

Intentionally absent.

## §11 Backlog

Mechanism choices deferred from the body, recorded as the known decision surface:

- Credential construction: key scheme; the derivation binding the signature capability to the content-derived committed identity (current implemented form: `block1-sha256:<hash>` under the khab-1 convention, chosen over genesis because genesis is identical across instances); encoding; versioning of the credential format.
- Succession record construction: contents of the designation record; how competing designations are surfaced to consumers; whether standing (rotating) pre-designation is recommended practice to shrink the unanticipated-loss window.
- Reciprocation mechanics: how one instance solicits the counterpart inscription; how a persistently unreciprocated relationship is surfaced (MAP-1 imposes no completion obligation, so this is presentation, not enforcement); relation to the deposit-board write path.
- Cadence policy for head inscription (event-triggered vs periodic; per-relationship variation), and how staleness is surfaced — a partner records the head it is shown, and a stale head is bounded only by MPR-9 consistency between anchored states.
- Freshness/monotonicity presentation: whether consumers are warned when successive mutual anchors of the same identity do not advance.
- Verification tooling: what an auditor needs to check a mutual-anchor pair offline; replay bounds for credential verification (full replay vs a checkpoint the verifier already trusts on other grounds — a verifier-chosen trust base, disclosed as such).
- Initial concrete attestation-type set beyond quality-endorsement (candidates from observed practice: integrity digest, review, provenance claim); registry vs configuration for the vocabulary; retraction-entry construction.
- Inaugural mutual-anchor procedure with the first partner instance operated outside this operator's control, and its observation log (input to the deferred trust-composition design).
