---
title: "Auditability: Symmetric Mutual Anchoring across Instances — Design v0.1 (AUD-L2)"
author: Masaomi Hatakeyama
date: 2026-07-21
version: 0.1
status: DRAFT for multi-LLM review
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

# AUD-L2 Mutual Anchoring Design v0.1

## §1 Purpose

AUD-L1 established head-anchoring discipline for a single chain: the nine invariants (MPR-1 through MPR-9) guarantee that a KairosChain instance's audit chain head is bound to an external anchor point with coherence, minimal footprint, outcome-blind discipline, auditor-completeness, and inter-anchor consistency over committed chain identity. These properties hold within the boundary of a single instance and its relationship to its own anchor log. AUD-L2 extends this discipline to the mutual case. When two or more KairosChain instances anchor to each other — a situation that arises naturally from Meeting Place exchanges (skill deposit, attestation, federation) and from Synoptis anchor sharing — what additional properties must hold beyond those already guaranteed by AUD-L1 applied independently to each instance? The central insight is that the partner instance acts as an ordinary ANC-8 foreign depositor: no new mechanism kind is introduced. What is new is the relational structure — each party's head appears in a log outside its own control — and the properties that this relational structure must satisfy. This document defines those properties as invariants, following the same design-by-invariant and anti-enumeration discipline that governs AUD-L1.

## §2 Scope and Non-Goals

### In Scope

The following concerns fall within this design:

- **Mutual anchoring properties**: what must hold when two KairosChain instances inscribe each other's audit-chain head bindings in their respective Synoptis logs. This is the relational extension of AUD-L1's single-instance properties.
- **Chain identity**: how an instance identifies itself to a partner in a self-authenticating manner, including successor designation for key rotation and chain death scenarios.
- **Attestation type separation**: distinguishing the evidential role of different attestation entries in a mutual anchor relationship, so that consumers can tell apart an automated integrity check from a peer review from a provenance claim from a quality endorsement.
- **Outcome-blind discipline in the mutual case**: extending MPR-5's presence-never-completeness principle to mutual exchanges, with explicit boundary demarcation between outcome-blind anchoring and outcome-aware endorsement.

### Non-Goals

The following concerns are explicitly out of scope for this design. Each is stated with its rationale and, where applicable, its connection point to a future slice.

- **AUD-L1.5 (content-bridge between L2 attestation and head-anchor)**: The bridge that connects the L2 attestation ledger to the head-anchor log is a separate slice. This design provides one side of that bridge (the anchor-log entries created by mutual anchoring); the L2 attestation design provides the other side. AUD-L1.5 defines how they reference each other. It is stated here as a connection point only and is not designed in this document.

- **Honest limits of exclusive assets**: Double-transfer prevention — ensuring that a skill, dataset, or attestation deposited with one partner is not simultaneously deposited with another — cannot be closed without a consensus protocol, which this design does not provide. This design evidences provenance and reputation claims through its attestation network; it does not enforce exclusive ownership claims. Such claims require external L1 evidence (e.g., a consensus ledger, a legal registry, or a trusted third party). This is a disclosure-style boundary following the MPR-5/MPR-6 pattern: the design states what it does NOT guarantee, rather than attempting enforcement it cannot deliver. Consumers of mutual anchoring data must understand that an attestation of provenance is evidence that a party claimed provenance, not proof that no other party holds a competing claim.

- **Cadence mechanism**: How often mutual anchors fire, whether they are triggered by events or run on a periodic schedule, and how the two instances coordinate timing are all mechanism choices. They belong in §11 Backlog, not in the invariant body.

- **Verifiable Credential mapping depth**: MAP-2 defines a chain identity credential that could potentially be expressed as a W3C Verifiable Credential. The mapping is deferred until the credential's internal structure stabilizes through implementation experience. Premature standardization of the credential format would constrain the design space without delivering interoperability benefits, since no external VC ecosystem currently consumes KairosChain chain-identity credentials.

- **AUD-L3 (reproducibility guarantees)**: Reproducing foreign attestations — particularly quality-endorsement attestations — and connecting to GenomicsChain pipeline reproducibility is a future slice. This design provides the attestation type vocabulary (MAP-4) that AUD-L3 will consume, but does not define what "reproducing a foreign attestation" means.

- **AUD-L4 (zero-knowledge selective disclosure)**: Selective disclosure of attestation content without revealing the full attestation is a future slice. This design provides the chain identity credential (MAP-2) and attestation types (MAP-4) that define WHAT is disclosed; AUD-L4 will define HOW to disclose selectively without compromising the anchoring properties.

- **Trust composition and Sybil resistance**: How trust scores compose across multiple mutual-anchoring relationships, and how the system resists Sybil attacks (an adversary creating multiple colluding instances to inflate trust), are deferred to the §11 Backlog until real mutual-anchoring data exists. These are not assigned a numbered slice level because their design depends on empirical observation of actual mutual-anchoring patterns, which do not yet exist.

## §3 Kinds

This section defines the vocabulary used in §4. Each term is a conceptual kind, not an enumeration of instances.

### Mutual anchor

A mutual anchor is a pair of anchor-log entries, one in each instance's Synoptis log, where each entry references the other instance's chain identity. The two entries are independent appends: neither entry causally depends on the other, and there is no transactional coupling between the two instances' logs. Each entry is created by the instance that owns the log, using the partner's chain identity credential as the foreign-depositor identifier. The mutual relationship emerges from the pair, not from any single entry. A single entry without its counterpart is an ordinary unilateral foreign-deposit anchor — valid in its own right under AUD-L1, but not a mutual anchor.

### Chain identity credential

A chain identity credential is a self-authenticating identifier: verifying that an attestation was issued by the chain it names requires nothing beyond the credential, the attestation, and public material derivable from them — no external registry and no certificate authority. Two properties compose it: a content-derived component that ties the credential to the chain's own committed history (the committed chain identity MPR-9 already quantifies over, whose current form deliberately excludes the genesis block because genesis is identical across instances by construction), and a signature capability that lets the chain issue attestations a stranger can verify against the credential itself. The concrete derivation and encoding are mechanism (§11).

A chain identity credential includes a successor-designation rule: a mechanism by which the chain declares, on its own ledger, which identity credential will succeed it in the event of key rotation, chain migration, or chain death. The successor designation is itself an anchor-log-visible event, ensuring that the transition is auditable and that past attestations remain verifiable even when the original chain ceases to operate. The successor-designation rule is the chain's answer to the question "if I stop operating, who speaks for my history?"

### Attestation type

An attestation type is a declared category on an attestation entry that distinguishes its evidential role — what kind of claim the attestation makes about its subject. The type does not prescribe verification procedure; it tells the consumer what KIND of evidence the attestation constitutes, so that the consumer can apply the appropriate level of scrutiny.

The attestation type vocabulary is finite at any given moment and extensible over time. New types can be added without modifying the anchoring protocol, because the type is a property of the attestation entry, not of the anchoring mechanism. The vocabulary includes types that differ along two critical axes: (i) whether the attestation is outcome-blind or outcome-aware (the MAP-3 boundary), and (ii) whether the attestation is automated or human-gated. These axes are orthogonal to each other and to the subject matter of the attestation.

### Anchoring discipline

Anchoring discipline is the property that anchor-log entries recording "this exchange happened" are appended without foreknowledge of whether the anchored content will pass or fail review, validation, or any human gate applied to the exchanged content. This is the mutual-case extension of MPR-5's outcome-blind discipline.

Anchoring discipline is distinct from endorsement. An endorsement records "this work is endorsed" — it is inherently outcome-aware, because it can only be issued after a judgment has been rendered. Endorsement belongs to the quality-endorsement attestation type (defined in MAP-4), not to the anchoring mechanism. The boundary between anchoring discipline and endorsement is a boundary between mechanism kinds: anchoring is outcome-blind and can be automated; endorsement is outcome-aware and requires a human gate (or at minimum an explicit judgment act). Conflating the two is a category error that AUD-L1 design iteration identified and that this design preserves as a first-class boundary.

## §4 Invariants

### MAP-1: Relational symmetry via ordinary foreign deposit

**Statement.** Each instance inscribes the other's AUD-L1 head binding as an ordinary anchor entry on its own Synoptis log, using the existing ANC-8 foreign-depositor mechanism. No new mechanism kind is introduced. Symmetry is a property of the RELATIONSHIP — each party's head appears in a log outside its own control — not an atomicity claim. The two inscriptions are independent appends with no causal or transactional coupling between the two instances' logs.

**Justification.** The partner's inscription serves three roles simultaneously. First, it acts as a time attestation from a party the instance does not control: the partner's log records WHEN it observed the instance's head, and the instance cannot retroactively alter the partner's log. Second, it provides equivocation-detection material: if the instance later presents a different head to a third party, the partner's log contradicts it, because the partner independently recorded what head it observed. Third, and most critically for the AUD lineage, it closes the who-anchors-the-anchor regress that MPR-4 (auditor-completeness / disclosed trust base) and MPR-9 (inter-anchor consistency over committed chain identity) left as a residual in the single-instance case. In AUD-L1, the anchor log's own integrity ultimately rests on trust in the anchor target (Zenodo, a public ledger, a partner). In AUD-L2, the ANC-4/ANC-6 split-view detection surface is closed because each chain's head is recorded in at least one foreign log that the chain does not control. The regress does not disappear — it terminates at the mutual relationship rather than at a single external authority.

Asymmetric anchoring — where instance A records instance B's head but instance B does not record instance A's head — would leave A unable to verify the relationship from its own log. A would have to trust B's claim that B recorded A's head, without being able to inspect B's log. This asymmetry violates the P2P-natural design principle: the relationship would have a structurally privileged party.

MAP-1 inherits MPR-4 (auditor-completeness / disclosed trust base), MPR-5 (presence-never-completeness / outcome-blind discipline deferred to L2), and MPR-9 (inter-anchor consistency over committed chain identity).

### MAP-2: Self-authenticating chain identity with successor designation

**Statement.** A chain identity credential is self-authenticating: it is derivable from the chain's own content and public-key material, it is signature-capable so that attestations issued under it are verifiable against the credential alone, and no external registry or certificate authority participates in its verification. On key rotation or chain loss, the successor identity is designated by a record ON the old chain, so that past attestations remain verifiable even when the original chain ceases to operate. The credential is an EXTENSION of the committed chain identity MPR-9 quantifies over — its current content-derived form remains valid under its original verification procedure — not a replacement. Any changeover between identity forms is itself an anchor-log-visible event and terminates extension claims under the prior form, exactly as MPR-9 already provides.

**Justification.** Dependence on an external identity registry — whether a certificate authority, a DNS-like name registry, or a centralized identity provider — would introduce a single point of trust and contradict KairosChain's P2P-natural design principle (Proposition 8, co-dependent ontology). The chain's own content is the only authority on what the chain is; any external authority that could override the chain's self-identification could also forge attestations on the chain's behalf or deny the chain's existence.

The successor-designation rule addresses a practical concern that arises in any long-lived attestation network: chains do not live forever. Keys are rotated for security reasons, instances are migrated to new infrastructure, and chains are occasionally retired. Without successor designation, the attestation history of a retired chain becomes an orphan — the attestations still exist in partners' logs, but no living entity can speak for them or extend them. The successor-designation record, placed on the old chain before it ceases to operate, creates an auditable link from the old identity to the new one.

The extension-not-replacement relation to MPR-9 ensures backward compatibility. Existing anchor entries that reference the old identity form (the content-derived hashes) remain valid under their original verification procedure. The transition to a successor identity is itself an event in the anchor log, so any consumer who replays the log can see when and why the identity changed. Claims made under the prior identity form are not retroactively attributed to the successor; they remain attributed to the original identity, with the successor link providing continuity of the chain's institutional identity rather than conflation of its attestation history.

MAP-2 inherits MPR-9 (inter-anchor consistency over committed chain identity) and MPR-1 (coherence).

### MAP-3: Outcome-blind mutual anchoring discipline

**Statement.** Mutual anchor entries are appended at exchange time, before either instance knows the outcome of any review, validation, or human gate applied to the exchanged content. This property applies to audit-chain head-anchor entries only — those that record "this exchange happened." It does NOT apply to the operator's own canonical-works registration (e.g., Zenodo deposit, constitutive note publication), which requires a human gate and is inherently outcome-aware. Outcome-aware endorsement belongs to the quality-endorsement attestation TYPE within the MAP vocabulary (MAP-4), not to a separate "constitutive attestation layer." The boundary is between mechanism kinds: anchoring (outcome-blind, automated) vs. endorsement (outcome-aware, human-gated).

**Justification.** The lesson from AUD-L1 design iteration is precise and hard-won: do not conflate outcome-blind automation of audit chain-head anchors with the human gate on the operator's own canonical works. These are categorically different acts. An anchor entry that records "instance A deposited skill X with instance B at time T" is a statement of fact about an event. It is true regardless of whether skill X subsequently passes review, fails validation, or is withdrawn. An endorsement entry that records "instance B reviewed skill X and found it satisfactory" is a statement of judgment. It is meaningful only after the judgment has been rendered, and its evidential weight depends on the reviewer's credibility and the review's rigor.

Mixing these two kinds of entry in the same mechanism — allowing the anchoring mechanism to also serve as an endorsement mechanism — creates a category error with practical consequences. If anchor entries are withheld pending review outcome, the anchoring mechanism becomes a gatekeeper: only "good" exchanges are recorded, and the audit trail becomes a filtered view of history rather than a complete one. If endorsement entries are automated like anchor entries, quality claims are issued without judgment, degrading the credibility of the entire attestation network.

The quality-endorsement attestation type provides the connection point to AUD-L3 (reproducibility). When AUD-L3 defines what it means to reproduce a foreign attestation, the quality-endorsement type will be the primary subject: reproducing an integrity check is trivial (re-run the hash), but reproducing a quality endorsement requires re-running the review process — which, in the GenomicsChain case, means re-running the bioinformatics pipeline and comparing outputs.

MAP-3 inherits MPR-5 (presence-never-completeness / outcome-blind discipline) and ANC v0.5 §2 non-goal (canonical-works human-gate is not head-anchoring).

### MAP-4: Attestation type vocabulary

**Statement.** Every attestation entry in a mutual anchor carries a declared type from a finite, extensible vocabulary. The type distinguishes the evidential role of the attestation — what kind of claim is being made — without prescribing the mechanism for verifying it. The vocabulary includes at minimum four types that cover the primary evidential roles observed in the current KairosChain attestation practice: integrity-check (automated verification that content has not been altered), peer-review (human or LLM-assisted evaluation of content quality), provenance-claim (assertion of authorship, origin, or chain of custody), and quality-endorsement (the outcome-aware type through which AUD-L3 reproducibility connects, and through which the MAP-3 boundary between anchoring and endorsement is operationalized).

**Justification.** Without type separation, all attestations look alike to a consumer. A consumer who queries "what attestations exist for skill X?" would receive a flat list in which an automated hash check, a multi-LLM design review, a provenance assertion by the original author, and a quality endorsement by a trusted peer are indistinguishable. The consumer cannot apply appropriate scrutiny — a hash check is deterministic and can be re-verified trivially, while a quality endorsement carries the endorser's reputation and requires understanding the endorsement criteria.

The quality-endorsement type is particularly important for two reasons. First, it is the connection point to AUD-L3 (reproducibility of foreign attestations): when AUD-L3 asks "can this attestation be reproduced?", the answer depends critically on the attestation type. Integrity checks are trivially reproducible; quality endorsements require reproducing the review process. Second, quality-endorsement is the type that crosses the MAP-3 boundary: it is outcome-aware, human-gated (or at minimum judgment-gated), and therefore categorically different from the outcome-blind anchor entries that MAP-3 governs.

The vocabulary is extensible so that new attestation kinds can be added as the mutual-anchoring practice matures. The current four types are derived from observed practice, not from a priori taxonomy. As real mutual-anchoring data accumulates, new types may emerge (e.g., availability-attestation, compliance-certification, delegation-of-authority). Specific type definitions — including their verification requirements, their trust-weight in score computation, and their interaction with the challenge mechanism — belong in §11 Backlog, not in the invariant body.

MAP-4 inherits ANC-8 (attestation relation types).

## §5 Growth Path

This section identifies connection points to future design slices. Each entry states what THIS design provides and what the future slice will add. No future slice is designed here.

### AUD-L1.5: Content-bridge

MAP-1's symmetric entries provide the anchor-log side of the bridge: each instance's Synoptis log contains an entry referencing the partner's chain identity and head binding. The L2 attestation ledger provides the content side: detailed attestation records with subjects, claims, and evidence. AUD-L1.5 defines how these two sides reference each other — how an anchor-log entry points to the attestation records it covers, and how an attestation record points back to the anchor-log entry that timestamps it. This is a separate slice because the referencing structure depends on both the anchor-log format (stabilized in AUD-L1) and the L2 attestation ledger format (stabilized in the L2 attestation design), and neither should be modified to accommodate the bridge until both are independently stable.

### AUD-L3: Reproducibility

MAP-4's attestation type vocabulary provides the classification that AUD-L3 will consume. In particular, the quality-endorsement type identifies attestations whose reproduction is non-trivial: reproducing an integrity check means re-running a hash function, but reproducing a quality endorsement means re-running the review or analysis process that produced the endorsement. AUD-L3 defines what "reproducing a foreign attestation" means for each attestation type, with GenomicsChain pipeline reproducibility as the canonical use case: a quality endorsement of a genomics analysis result is reproducible if and only if the pipeline can be re-run on the same inputs and produces the same outputs (within defined tolerance). The MAP-3 boundary (outcome-blind vs. outcome-aware) determines which attestation types are candidates for reproduction and which are definitionally non-reproducible (an outcome-blind anchor entry records a fact, not a judgment, so "reproducing" it is just verifying the fact still holds).

### AUD-L4: Zero-knowledge selective disclosure

MAP-2's chain identity credential and MAP-4's attestation types define WHAT is disclosed in a mutual-anchoring relationship. AUD-L4 defines HOW to disclose selectively — revealing that an attestation of a certain type exists without revealing the attestation's content, or proving that a chain identity credential is valid without revealing the chain's full content. The connection point is structural: selective disclosure operates on the same attestation entries and chain identity credentials that MAP-1 through MAP-4 define, but applies a privacy-preserving transformation to them.

### Verifiable Credential mapping

MAP-2's chain identity credential is structurally similar to a W3C Verifiable Credential: it is a self-authenticating claim about a subject (the chain), issued by the subject itself, with a verification method (chain replay). Expressing it as a VC would enable interoperability with external credential ecosystems. This mapping is deferred until the credential's internal structure stabilizes through implementation experience with MAP-2. Premature mapping would lock in format choices that may need to change as the mutual-anchoring practice matures.

## §6–§10

Intentionally absent.

## §11 Backlog

The following topics are mechanism choices or design decisions that are deferred from the invariant body. They are listed here to acknowledge their existence and to prevent them from being silently omitted.

- **Mutual anchor exchange coordination**: How the two independent appends (one per instance) are triggered. Whether instance A notifies instance B that it has appended, or whether both append independently based on a shared event (e.g., a Meeting Place exchange), or whether a third-party coordinator signals both. The invariant (MAP-1) requires that both appends eventually happen; the backlog item is HOW they are triggered.

- **Chain identity credential format**: The key scheme, the derivation that binds the public-key component to the content-derived committed identity (current implemented form: `block1-sha256:<hash>` under the khab-1 convention — chosen over genesis because genesis is identical across instances), the encoding of the credential (binary, base64, multibase), and the versioning strategy for the credential format itself. MAP-2 defines the properties; this backlog item defines the representation.

- **Successor designation record format**: What the old-chain record contains when designating a successor. At minimum it must contain the successor's chain identity credential and a signature under the old chain's key. Whether it also contains a reason for succession, a validity period, or delegation constraints is a format decision.

- **Attestation type vocabulary initial set**: Which types ship in the first implementation, beyond the four named in MAP-4 (integrity-check, peer-review, provenance-claim, quality-endorsement). Whether additional types are needed for the initial Meeting Place exchange scenarios. Whether the type vocabulary is defined in a registry, a configuration file, or hardcoded.

- **Cadence policy**: How often mutual anchors fire. Whether anchoring is triggered by specific events (a Meeting Place exchange, a skill deposit, a federation handshake) or runs on a periodic schedule (every N blocks, every N hours). Whether different cadences apply to different partner relationships.

- **Identity transition ceremony**: How an instance migrates between identity forms in practice. The anchor-log visibility requirement (MAP-2) constrains the ceremony but does not specify it. The ceremony must ensure that the old identity's attestation history remains accessible and that the transition is visible to all partners who hold mutual anchors with the transitioning instance.

- **Replay verification bounds**: How much of a chain must be replayed to verify a chain identity credential. Full replay from genesis is definitive but expensive. Whether partial replay (from a trusted checkpoint) is acceptable, and under what conditions, is a performance-vs-trust tradeoff that depends on the verification context.

- **Trust composition and Sybil resistance**: How trust scores compose across multiple mutual-anchoring relationships (if instance A trusts B and B trusts C, what can A infer about C?). How the system detects and resists Sybil attacks (an adversary creating multiple colluding instances to inflate trust scores). These topics are deferred until real mutual-anchoring data exists, because their design depends on empirical observation of actual trust-network topology, which does not yet exist. They are not assigned a numbered slice level because their scope may span multiple slices or require a design approach orthogonal to the AUD-L1..L4 progression.