---
title: "Auditability: Head-Anchor Binding with Merkle Inclusion Proof — Design v0.3"
author: Masaomi Hatakeyama
date: 2026-07-20
version: 0.3
status: FROZEN v0.3 (frozen 2026-07-21 on R3 = 6/6 APPROVE subprocess + persona 3/3 APPROVE; N1-N3 all RESOLVED by all reviewers; residuals (c)/P1 advisory reflected pre-freeze: MPR-4 convention-definition input, MPR-9 identity-change disclosure register, MPR-7 bracketing cross-reference, §11 witness/genesis-identity notes)
review_note: R3 first subprocess run crashed (heartbeat_stale, detached worker); rerun completed 5/5 with no crash. R1 = 1/6 APPROVE (REVISE), R2 = 3/6 + persona 2/3 (REVISE), R3 = 6/6 + persona 3/3 (APPROVE).
supersedes: docs/drafts/auditability_head_anchor_design_v0.2_draft.md
dispositions:
  - docs/drafts/.auditability_head_anchor_r1_disposition.md
  - docs/drafts/.auditability_head_anchor_r2_disposition.md
inherits:
  - docs/drafts/hestia_anchor_attestation_design_v0.5_draft.md (ANC-1..9, one-way rule §5)
  - docs/drafts/attestation_home_migration_design_v0.3_draft.md (AHM-1..9, esp. AHM-4)
  - docs/drafts/unified_deposit_board_design_v0.3_draft.md (BRD-1..4)
seeds: L2 handoff_auditability_anchor_chain_head_design_20260720 (improvement level L1 of four)
method: design-by-invariant / anti-enumeration. Mechanism choices live only in §11. §6-10 intentionally absent.
scope: design phase only; implementation is a separate phase. Handoff levels L2 (head publication + cadence), L3 (reproduces foreign attestation), L4 (ZK) are out of scope and appear only in §5.
---

## §1 Purpose

This design adds a verifiable binding between the internal chain's cumulative state and publicly anchored entries, together with a Merkle inclusion proof capability that lets a third party verify membership, integrity at anchor time, and order of specific records without access to the chain and without disclosure of any record's content, within the computational-opacity limits MPR-2 discloses.

The binding is carried as committed content within anchor entries. An inclusion proof is a standalone artifact derivable from chain state at anchor time, consumable by an auditor who holds the proof, the anchor's published binding, and an authentic view of the anchor log. Together these close a stated gap: the chain can already prove its history to itself, but until now it could not prove membership or order to an outside party without granting chain access. What the proofs deliver is operator-independent *verification arithmetic*; how far the resulting claims are credible against the operator is governed by the inherited relational-honesty frame (ANC-8) and is stated inside the invariants, not glossed over.

## §2 Scope and Non-Goals

**Scope.** The properties of the head binding inside anchor entries, the properties inclusion and consistency proofs must satisfy, and the conditions under which an auditor can verify membership, integrity at anchor time, and order.

**Non-goals.**

- Content disclosure. Proofs demonstrate membership and order; they never reveal the content of the attested record or of any sibling in the tree.
- Cross-instance federation. Verifying proofs across distinct KairosChain instances is out of scope here.
- Zero-knowledge proofs. Proving membership without revealing *which* record is a member requires ZK machinery deferred to the growth path.
- Anchoring discipline. When and how often anchors are written — automation, cadence, and their governance — belongs to the L2 head-publication level (the anchoring-cadence posture of the canonical note's §7; ANC-4/6 close the place-side residual there) and is not legislated here; §4 states only what its absence costs (MPR-5).

**Inherited invariant families.** ANC-1 through ANC-9 (anchor design v0.5, including its §2 non-goal that anchoring the operator's own canonical works stays a human act, and its §5 one-way rule), AHM-1 through AHM-9 (attestation home migration v0.3), and BRD-1 through BRD-4 (board design v0.3) remain in force without modification. Where this design's invariants reference inherited ones by ID, the reference is for traceability only — no inherited invariant is restated, narrowed, or extended here.

## §3 Kinds

This section establishes vocabulary only; every constraint appears in §4.

### (a) Record commitment

A record commitment is the fixed-size digest by which one internal-chain record is represented in an anchored tree. It is the leaf-level object proofs quantify over; no record content appears in any anchored structure.

### (b) Anchored cumulative commitment

The anchored cumulative commitment is a single digest committing to the entire ordered sequence of record commitments of the internal chain up to the anchor moment — not to any one block or sub-range. It is the root against which inclusion and consistency proofs verify. The internal chain's native per-block structures are substrate from which this commitment must be derivable; the derivation is a mechanism (§11).

### (c) Head binding

The head binding is the committed material an anchor entry carries about internal-chain state at anchor time: an identifier of the internal chain whose state it commits (the chain identity), the anchored cumulative commitment, an identifier of the verification convention under which it and its proofs are computed, and any further state descriptors the depositor includes. It is carried within the anchor entry itself, not alongside it.

### (d) Inclusion proof

An inclusion proof connects one record commitment to an anchored cumulative commitment; it consists of sibling hashes plus the structural data (position and extent) needed to recompute the root. A consistency proof is the companion artifact connecting two anchored cumulative commitments, demonstrating that the later commits to an extension of the sequence the earlier commits to.

### (e) Auditor

An auditor is any party — human or automated — holding proofs, published head bindings, and an authentic view of the anchor log. The auditor needs no access to the internal chain and no cooperation from its operator to run verification.

### (f) Anchor entry extension

The anchor entry extension is the additive enrichment of newly appended anchor entries with a head binding. Entries without one — past or future — are ordinary anchor entries; absence of a binding is a statement of provenance.

## §4 Invariants: MPR (Membership-Proof Requirements)

**MPR-1. Binding commitment and coherence.** The head binding is committed content of the anchor entry: it is covered by the entry's own hash and therefore by the anchor log's hash chain (ANC-1), and it attaches only to newly appended anchor entries, leaving every already-published entry's committed content, hash, chain position, relation label, and withdrawal authority untouched (AHM-4). Within the binding, every component presented as verifiable is derivable from the same internal-chain state under the committed convention; a component that cannot be so verified by the auditor is presented as informational, never as proven.

*Justification.* If the binding were outside the committed content, the operator could silently substitute a different chain state after publication without disturbing the anchor log's integrity checks; committing it makes substitution break the entry hash and hence the chain (the entry model's existing committed/non-committed distinction — AHM-3's per-entry governing identity being the non-committed precedent — shows the two sides are already separable, and the binding deliberately falls on the committed side). The coherence clause exists because a binding could otherwise pair a genuine-looking state identifier with a root of a fabricated tree: whatever the auditor cannot recompute from the committed convention must not borrow the credibility of what they can, so unverifiable components are demoted to informational rather than silently trusted. Attaching only to new entries is what preserves AHM-4 without weakening the commitment.

**MPR-2. Sibling containment.** An inclusion or consistency proof carries only hashes and structural data; no sibling's content — the data from which any hash was derived — ever crosses the anchor boundary. This opacity is load-bearing only because leaf preimages are themselves fixed-size record digests; where a preimage is guessable low-entropy data, a hash confirms guesses, and the design discloses rather than denies this residual.

*Justification.* ANC-2 makes containment a property of the anchor boundary, and proofs must not become the side channel that reopens it: sibling hashes confirm structural position without revealing occupancy. The entropy clause keeps the claim honest — hash opacity is computational, not unconditional, and the standard transparency-log caveat about enumerable preimages applies here exactly because the design promises content non-disclosure to closed-chain operators.

**MPR-3. Self-describing determinism.** Proof generation and verification are deterministic relative to a committed, self-describing verification convention: the head binding names the convention (as ANC-2 already commits digest algorithm and canonicalization), the identifier resolves to a convention definition whose own integrity the auditor can verify, the same chain state always yields the same anchored cumulative commitment under it, the same record always yields the same proof, and the convention excludes cross-role ambiguity — no interior node of an anchored structure can verify as a record commitment or vice versa. A change of convention between anchors is itself anchor-log-visible, and a proof spanning the change is governed by the later binding's committed convention.

*Justification.* Determinism claimed without naming its convention is unfalsifiable: two honest implementations could disagree and neither would be wrong, which destroys the auditor's ability to treat proof failure as evidence. Binding the convention identifier into the committed material makes "recompute and compare" well-defined for a stranger with no side agreement, the same move ANC-2 makes for bare digests — and an identifier that resolved to nothing checkable would reopen the same hole one step removed, so the definition's own verifiability is part of the property. The ambiguity exclusion is stated at property level because a construction that lets interior nodes masquerade as leaves admits forged memberships without any hash being broken; the changeover rule exists so that convention evolution cannot orphan or silently re-scope earlier commitments (its construction is a §11 mechanism).

**MPR-4. Auditor-completeness with a disclosed trust base.** Verification succeeds with exactly: the proof, the published head binding or bindings it targets, the record commitment in question where the proof is an inclusion proof, an authentic view of the anchor log, and the resolvable convention definition the binding names (MPR-3) — no internal-chain access and no operator cooperation. Two boundaries of this claim are part of it: *production* of a proof is the operator's act and is not cooperation-free, only verification is; and the proofs bind commitments, not contents — linking a record commitment to actual content requires holding that content and recomputing its digest under the committed rule, a channel outside this design. What is operator-independent is the verification arithmetic; the credibility of the binding itself, for a same-party anchor, rests on the inherited relational frame (ANC-8) and reaches externally credible strength only under head publication and split-view detection (ANC-4/6), which are deferred (§5).

*Justification.* If verification needed chain access, the operator would remain gatekeeper of their own audit, defeating the purpose; enumerating the trust base closes the opposite failure, an overclaim — the auditor does depend on seeing the true anchor log (the storage-layer-rewrite residual ANC-1 discloses for scope X) and on the committed convention, and pretending otherwise would sell exactly the "appearance of external anchoring" ANC-8 exists to prevent. The production/verification asymmetry and the commitment/content distinction are disclosed in the same spirit: a regulator reading "no operator cooperation" must not conclude that proofs materialize without the operator or that a verified commitment certifies bytes the auditor never held. Stating all of it inside one invariant keeps the deliverable (arithmetic now) and the deferrals (credibility upgrades at L2/L3) from being confused, mirroring how ANC-7/8/9 carry their limits inside themselves.

**MPR-5. Presence, never completeness.** A verified proof establishes that a record was present in the anchored state; no artifact in this design establishes that everything computed was anchored. The audit-grade reading "all computations are represented" is conditional on an outcome-blind anchoring discipline — anchoring whose occurrence cannot be selected by result — which this design neither delivers nor verifies: it belongs to the L2 head-publication level (§2, §5), and until it is in force, suppression of a never-anchored state is invisible to the auditor and is disclosed as such.

*Justification.* Selective anchoring is the deployment-level attack this whole line of work targets — anchor the convenient, omit the rest — yet no proof over what *was* anchored can speak about what was not, so the honest statement is a limit in the register of MPR-7, not an obligation this design cannot enforce. Placing the discipline itself out of scope also keeps faith with the frozen lineage: ANC v0.5 expressly reserves publication rhythm for scope Y and non-goals ungated self-anchoring of the operator's canonical works, so an in-force automation mandate here would contradict the inheritance this document promises to leave unmodified. What survives in force is the negative property: nothing in the proof system's own semantics varies with computation outcome.

**MPR-6. Proof scope.** A valid proof asserts membership, integrity of the record commitment at anchor time, committed position, and order derivable under MPR-8/MPR-9 — and nothing else. It makes no claim about the quality, correctness, fitness, or significance of the attested content, none about content the auditor has not independently obtained (MPR-4), and none about records or states it does not cover.

*Justification.* Membership and merit are orthogonal, and conflating them would turn the proof into a counterfeit quality seal — "has a valid proof" misread as "is correct." Correctness claims require re-execution or verifiable computation, which are the L3/L4 levels of the growth path, so the boundary is drawn here once and the other invariants can stay silent about it.

**MPR-7. Membership without temporal bounding before the first anchor.** Every record of the anchored state — including records committed before any head-binding anchor existed — is provable as a member from the first anchored cumulative commitment onward; what a record older than the first anchor lacks is a temporal bound. Its recording moment is attested only as "no later than the first anchor that covers it": before that anchor, the backdating window is unbounded, and no retroactive tightening is ever fabricated. Between anchors, a record's moment is bounded by the bracketing anchors — the bound derived from committed position against committed extents (MPR-8), and sound only where the bracketing anchors' consistency is established (MPR-9) — so denser anchoring narrows every subsequent window.

*Justification.* v0.2 claimed pre-first-anchor records had "no proof coverage," which contradicts the cumulative commitment's own definition — the first root commits to the entire sequence beneath it, so membership proofs exist for all of it; the honest limit is temporal, not membership. Retroactive tightening would require modifying published anchor entries (breaking AHM-4) or backdating fresh ones (breaking the integrity being sold); an honestly unbounded first window is strictly better than either. The consequence is directional: the guarantee strengthens monotonically as anchoring history deepens, the same "cadence, not a single act" posture the canonical note's §7 establishes.

**MPR-8. Committed position and order.** An inclusion proof binds its record commitment to a definite position within the anchored sequence, and the head binding commits the sequence's extent; order between any two proven records — including two records under the same anchor — is derived by comparing committed positions within a common anchored state (directly, or via MPR-9 consistency between the two anchors), never from wall-clock timestamps, which remain informational, and never from a premise of absence that no artifact proves.

*Justification.* v0.1's ordering argument leaned on "B appears only later," a non-membership premise inclusion proofs cannot establish; committing position and extent replaces that unverifiable negative with a verifiable positive — each record's place is part of what the root commits to, so relative order is arithmetic on proven positions, and "member #N" becomes attestable rather than approximate. Timestamps are excluded from the criterion because a same-party depositor controls its own clock; positions inside a committed state are fixed by the commitment itself. Cross-anchor comparison is delegated to MPR-9 because without verified extension-relatedness, positions in two roots are numbers in two unrelated coordinate systems.

**MPR-9. Inter-anchor consistency.** Any two head bindings committing the same chain identity are verifiably extension-related: a consistency proof, producible under the committed convention and verifiable with the MPR-4 trust base, demonstrates that the later commitment includes the earlier's entire sequence unchanged as a prefix, and a verified proof of the contrary is conclusive evidence of rewriting or forking. Because production is the operator's act (MPR-4), absence of a consistency proof is not proof of rewriting: it leaves the extension claim unestablished, and an extension claim that remains unestablished while the operator continues anchoring is itself disclosed audit-relevant information. Consistency relates only anchors that carry head bindings; binding-less anchor entries contribute no coverage. A change of the committed chain identity is anchor-log-visible and terminates the extension claim across it — continuity of identity is never presumed, and the change is itself disclosed audit-relevant information in the same register as an unestablished extension claim.

*Justification.* Without this property every root verifies in isolation and the central audit claim — "the chain was not rewritten" — is unsupportable: an operator could rewrite history and anchor a fresh, internally consistent root, and each membership proof would still pass. Extension-relatedness is precisely what transparency logs add for this reason. Quantifying over committed chain identity (rather than an undefined "same chain") makes the predicate auditor-decidable and closes the fork excuse — an operator claiming "those anchors bind different chains" must have committed different identities, and that difference is itself visible in the log the auditor already holds. Treating non-production as unestablished-rather-than-guilty keeps the evidentiary claim within what artifacts can support, while still denying the operator a silent exit: the gap itself is reportable. Response-time discipline and coverage cadence belong to L2; within scope X the invariant detects rewriting *between* anchored states, and wholesale substitution of the anchor log itself remains the ANC-1 residual closed at L2.

## §5 Growth Path

The binding and proof properties are the fixed foundation; each later level upgrades credibility without redesign. At L2, head publication beyond operator control and split-view detection (ANC-4/6) close the anchor-log residual disclosed in MPR-4/MPR-9, and the outcome-blind anchoring discipline MPR-5 names as conditional acquires its enforceable home — cadence, automation, and response-time policy live there, under the inherited human-gate non-goal for the operator's own canonical works. At L3, an independent auditor with closed access re-executes recorded computations and endorses reproducibility by foreign attestation, adding the third-party endorsement and correctness dimension MPR-6 excludes. At L4, zero-knowledge techniques allow proving membership without revealing which record is the member, for privacy-sensitive disclosure. Nothing at L2-L4 alters the MPR properties; they strengthen the conditions under which the same proofs are believed.

## §6–§10

Intentionally absent.

## §11 Backlog

Mechanism choices deferred from the body, recorded as the known decision surface:

- Derivation of the anchored cumulative commitment from the internal chain's native per-block structures (per-block merkle_root + prev_hash), including whether the cumulative structure is maintained incrementally or built at anchor time, and how the chain's native head hash appears in the binding (verifiable component vs informational descriptor per MPR-1).
- Chain-identity descriptor: its form, issuance, and how an identity change is recorded so it is anchor-log-visible (MPR-9); whether identity is derived from chain content (e.g. a genesis commitment), which would promote it from informational to verifiable under MPR-1's coherence clause.
- Tree construction and its committed convention identifier: algorithm family, leaf/interior domain separation satisfying MPR-3's ambiguity exclusion, position/extent encoding satisfying MPR-8; where the convention definition is published and how its integrity is verified (MPR-3); convention-changeover construction (dual commitment or equivalent).
- Consistency-proof construction satisfying MPR-9 (transparency-log style consistency paths or equivalent), including the positive inconsistency-witness construction — verification failure of an operator-supplied proof is not by itself such a witness.
- Proof serialization format and the proof-request surface (how an auditor asks for inclusion/consistency proofs; served vs locally generated); response-time expectations deferred to L2 policy.
- Storage of proofs (precomputed vs on-demand; caching and invalidation on new anchors).
- Anchor-entry field layout for the head binding within the existing committed body, honoring size bounds (ANC-2) and the append-line store format.
- Verification tooling for auditors (offline verifier; what ships with the public verification view).
- Inaugural head-binding anchor procedure for the operator's production chain, and its relation to the existing document-digest anchor at position #1.
