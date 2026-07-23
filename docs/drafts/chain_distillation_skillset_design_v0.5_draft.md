---
name: chain_distillation_skillset_design
title: "Chain Distillation SkillSet — provenance-certified distillation of a personal chain into distributable SkillSets"
version: 0.5
status: DRAFT (post-R4 revision)
revises: v0.4 (R4 4/6 APPROVE, persona 2/3 — re-issuance citation obligation re-keyed from distillate commitment to designation overlap, closing trivial-variation evasion; revocation scope wording unified; claim-core/openings boundary and presentation-inertness pinned in backlog)
date: 2026-07-22
layer_target: SkillSet (plugin level, not L0 core); the distiller is itself a SkillSet
parent: experience_as_capital productization direction (L2, 2026-07-22) — product form (B) with the structural-necessity framing
depends_on:
  - confidentiality_guard_skillset_design v0.3 (FROZEN 2026-07-22, CG-1..CG-6) — the gate every distillation output passes
  - synoptis khab-1 (AUD-L1, frozen + shipped), map-1 (AUD-L2, frozen + shipped), rpr-1 (AUD-L3, frozen + shipped), sdp-1 (AUD-L4 design v0.3 FROZEN 2026-07-22, slice 1 shipped)
  - synoptis attestation lifecycle (shipped structure as of 2026-07-22, kairos-chain gem 3.49 line: envelope with content-independent injectable identity, portable signature verification, revocation manager; a behavioral change to the carrier re-opens this dependency) — certificate carrier
related:
  - skillset_exchange / Meeting Place (distribution channel for distilled output)
  - agent_skillset_guard_track (regime pattern lineage, via confidentiality_guard)
tags: [distillation, provenance, design-by-invariant, experience-as-capital, confidentiality-guard, synoptis]
---

# Chain Distillation SkillSet — design v0.5

## 1. Frame and scope

An instance that has operated long enough holds two distinct assets: the
capability its records constitute, and the records themselves. The
productization direction (parent L2) concluded that the chain is not the
product — it is context-bound, secret-bearing, and its sale would contradict
the value proposition it evidences. What can be productized is a
**distillate**: a SkillSet extracted from the accumulated record, distributed
through the existing exchange, and carrying a **provenance certificate** —
the certificate makes verifiable origin claims (which chain, which
designated records, what span, under what gate) without disclosing those
records' content.

This design specifies the distiller as a SkillSet. Its two outputs are kept
distinct throughout: the **distilled SkillSet** (content, distributed like
any SkillSet) and the **certificate** (evidence, bound to the content and to
the source chain). The distiller itself is a third artifact — a tool anyone
may acquire, whose possession grants no provenance.

**In scope:** the act of distillation (selection of source records,
production of the distilled SkillSet, issuance of the certificate); the
certificate's claim vocabulary and its verification; the coupling of
distillation to the confidentiality guard; the recording of the distillation
act.

**Out of scope:** the quality of distilled SkillSets (owned by the
reproduction-endorsement channel, CD-3); the exchange and marketplace
mechanics themselves (owned by the existing skillset_exchange / Meeting
Place tracks, which this design consumes unchanged); valuation and pricing;
the anchoring machinery's own guarantees (inherited from the synoptis
family, never re-authored here — the SDP-2 discipline; SDP-1..5 are that
track's invariants, as CG-1..CG-6 are the guard's).

## 2. Threat model and roles

Four failure classes motivate the design:

- **Fabricated provenance** — a party claims their SkillSet distills real
  accumulated experience when it does not (authored yesterday, records
  invented or padded). The primary case: the certificate exists to make the
  origin claims structurally unforgeable and cheap to check. The defense is
  structural: certificate claims are functions of records that must already
  exist under external anchoring, so fabricating provenance requires
  fabricating an anchored history — the cost the anchoring tracks already
  impose. Certificate transplant — re-attaching a valid certificate to a
  different artifact — fails the commitment binding (CD-6).
- **Leakage through the distillate** — the distillation output republishes
  confidential content from the source chain (the raw-sale failure the
  parent L2 names). Fully delegated to the confidentiality guard: the output
  is outward-crossing content like any other (CD-1), and this design adds no
  second redaction machinery.
- **Provenance–quality conflation** — a verifiable origin claim is read as a
  usefulness claim, by buyers or by the seller's own marketing. Addressed by
  vocabulary restriction (CD-3): the certificate is made incapable of
  expressing quality, and the quality channel is a separate, composable
  signal.
- **Volume gaming** — provenance measured by record count invites padding.
  Addressed by what the certificate binds (CD-2): extent is disclosed as a
  span and a designated selection, never aggregated into a score this design
  would then have to defend.

The copied-chain variant — an attacker re-anchoring a copy of another
party's chain under their own identity — is excluded by the anchoring
tracks' identity binding (khab-1/map-1 identity continuity), which this
design inherits as an assumption rather than re-establishing.

Roles: the **distiller-operator** (the human–instance composite that owns
the source chain and runs the distillation); the **acquirer** (obtains the
distilled SkillSet through the exchange); the **verifier** (any third party
checking the certificate — possibly but not necessarily the acquirer); the
**guard policy author** (unchanged from the confidentiality guard design).
The deciding model is untrusted for confidentiality verdicts (inherited
CG-3) and untrusted for provenance claims: it can author distillate content,
but no claim it authors enters the certificate unless derivable from records
(CD-2).

## 3. Invariants

**CD-1 (distillation behind the guard).** Certified distillation runs only
under an active confidentiality-guard regime. The distilled SkillSet and the
certificate are presented at the guard's outward surface as ordinary
content — judged by CG-2/CG-3, recorded by CG-4 — and the distiller holds no
private path past the guard. When the regime is not active, the distiller
does not produce an uncertified distillate as a degraded mode; it declines,
and the refusal is reported by the distiller itself following the same
non-leaking report discipline as CG-6. The certificate names the guard
policy version in force and is bound to the guard's verdict records for the
crossing that released the distillate. The distillate and the certificate
cross the guard separately, in that order. The certificate cites, as
chain-internal citations, only what precedes its finalization: the CD-6
record family (including any predecessor record CD-6 obliges it to cite)
and the distillate-crossing verdict records, alongside the external
anchor references its identity claims carry. The certificate's own release
through the guard is judged as ordinary outward content; its verdict
record — a chain record whose checkability follows CD-2's taxonomy — cites
the certificate's identity, and the certificate never carries or cites it.

*Why:* the product positioning is "safe by construction", and that claim is
only as strong as its weakest path out. A distiller that could run unguarded
would make the certificate an assertion about the operator's diligence; run
behind the guard, it is an assertion about a machine-checked gate, and the
verdict records let a verifier confirm the gate was in force — not merely
claimed — with checkability per CD-2's taxonomy. Declining rather than
degrading keeps the artifact class uniform:
everything this SkillSet has ever emitted passed the gate.

**CD-2 (origin claims as record functions, structurally unforgeable).** Every claim
in the certificate is a function of existing chain records: the source
chain's identity under its external head anchor, the designated selection of
records named as the distillation's input, the span they cover, and the record of
the distillation act itself (CD-6). No record, no claim — the certificate
cannot assert experience the chain does not evidence, and the "must
accumulate first" property is therefore a structural consequence of the
artifact, not a policy this design imposes. Verification is
holder-independent to the extent the anchoring tracks make it so: a verifier
checks certificate claims against the anchored history without trusting the
distiller-operator's cooperation beyond what those tracks already require.
Every certificate claim carries a disclosed checkability status: *checkable*
(from the certificate and anchor access alone), *anchor-pending* (checkable
once a subsequent anchoring event covers the cited records), or *trusted* —
every claim carries the strongest checkability status the carrier and
anchoring actually support at issuance — anchor-pending claims mature to
checkable as anchoring events cover them — and labeling a checkable claim
as trusted is the same defect as the converse; a certificate exhibiting
either mislabeling fails verification as a whole. The drawn-from link — that the distillate's content was in fact derived from the
designated records — is disclosed as trusted. The certificate carries what binding verification needs for the
released artifacts themselves — commitment openings for content the holder
already possesses — never openings over anything else (aligned with CG-4's
no-content clause).

*Why:* this is the anti-fake core, and it is inherited rather than invented:
tamper-evidence and external anchoring already make the history expensive to
forge, so binding the certificate to that history transfers the cost of
faking provenance onto the cost of faking an anchored past. Framing
accumulation as consequence rather than gate matters for the product's
honesty — the certificate is impossible without constitutive records for the
same reason a hash is impossible without its preimage, which is a different
thing from a vendor withholding a feature.

**CD-3 (provenance is not quality; two channels, composable and distinct).**
The certificate's claim vocabulary expresses origin only: which chain, what
selection, what span, under what gate, recorded where. It is incapable of
expressing usefulness, correctness, or fitness — there is no field a quality
claim could occupy. The quality signal for a distilled SkillSet is the
existing reproduction-endorsement channel (rpr-1), attached to the
distillate like to any SkillSet; a distillate may carry both signals, and
neither implies, strengthens, nor substitutes for the other. Presentation
surfaces under this design's control never render one as the other.

*Why:* the certificate's credibility is a depreciating asset if it can be
read as an endorsement — the first useless-but-certified SkillSet would
spend it. Restricting the vocabulary is stronger than warning against
misreading: a claim language that cannot express quality cannot overclaim
it. Reusing rpr-1 instead of inventing a quality score keeps this design
inside its competence — reproduction by independent parties is a signal this
project has already carried through review; a quality metric authored here
would be neither.

**CD-4 (tool and content distinct; the tool is itself a SkillSet).** The
distiller is a SkillSet, distributed through the same exchange as its
outputs, and structurally so: distillation — a meta-level act over the
chain — is expressed in the same SkillSet form as the base-level
capabilities it packages. Possession of the distiller grants nothing: no
provenance, no certificate, no standing. Certificates issue only over the
possessor's own accumulated records (CD-2), so two parties running the
identical tool over different histories obtain incomparable artifacts, and a
party with no history obtains none.

*Why:* the meta-in-same-structure form is the project's generative principle
(Prop 1/4) applied where it is load-bearing for the business frame: the
distiller can itself be exchanged, its own provenance certified by the same
machinery, without any new distribution channel. The grants-nothing clause
is what lets the tool circulate freely — even to competitors — without
diluting the product: the scarce input is the accumulated record, and CD-2
has already made that unforgeable.

**CD-5 (evidence under selective disclosure).** The certificate is evidence
about records, never a republication of them. Its bindings follow the
selective-disclosure discipline (SDP-1..5): claims assert no more than their
open forms would, content is withheld by commitment rather than by trust,
withholding and soundness rest on disclosed assumptions, and the existing
record structures are cited, never re-authored. In particular the
certificate honors the guard's no-content clause (CG-4): a verifier learns
that designated records ground the claims and checks their integrity,
without the certificate leaking what the source chain contains beyond what
its designations deliberately disclose.

*Why:* the certificate travels with the distillate into environments the
source chain will never see, so it is itself an outward crossing of
evidence — and the reconciliation of "re-derivable" with "never contains"
has already been designed and reviewed twice in this project (CG-4's
commitments, SDP-1's bounds). Inheriting that machinery is both the
anti-enumeration move and the safe one: a second disclosure calculus
authored here would be the design's largest untested surface.

**CD-6 (the distillation act is constitutively recorded).** The
certificate's identity is content-independent and assigned before issuance —
a property the attestation carrier already provides. A certificate's
grounding is fixed at issuance: its authoritative distillation record is
the record whose commitments its claim core matches and which its finalized
form cites — a binding the verifier checks positively, never by exhaustion.
That no other record bears the same certificate identity — identity
uniqueness on the source chain — is a disclosed trusted sub-claim, in the
same honest register as revocation absence; a record bearing an identity
whose certificate it does not ground grounds nothing, and identity
uniqueness and revocation are scoped to the named source chain (on any
other chain the identity claims simply do not bind). Each distillation is
recorded on the source chain before its outputs are released: the designated
selection it drew from, the guard policy version in force, commitments
binding the distillate and the certificate's claim core (the certificate's
claim content — excluding its citation of this record, carrier lifecycle
metadata, and commitment openings, all of which sit outside the core), and
the certificate's identity.
The guard verdict on the distillate's crossing precedes this record
(verdict-precedes-effect, CG-2, where release is the effect); this record
precedes certificate finalization; binding direction is one-way,
later-cites-earlier. Carrier lifecycle metadata added at issuance lies outside the claim core and can carry no origin claim. Record-precedes-release is distiller-internal discipline; its violation yields no certificate rather than a false one — a residual in the same honest register as the guard's own salt residual. The certificate cites this record — so the act of
making the claim is inside the history the claim is about — and subsequent
distillations can cite their predecessors. Revocation is keyed to the
certificate identity and is effective across the entire source chain,
regardless of which record a certificate copy cites. A subsequent
certificate — the obligation evaluated at its issuance — whose designation
shares records with a then-revoked certificate's
designation must cite the revoked predecessor — the obligation is keyed to
the input designation, a first-class origin claim, so varying the output
does not evade it; a certificate omitting such a predecessor is defective,
and — the omission being checkable only against the source chain —
observance of this obligation is itself a disclosed trusted claim. The chain record is the
authoritative revocation channel; the carrier's revocation lifecycle mirrors
it, never the reverse. Absence of revocation is not provable from a private
chain; revocation status is a trusted claim unless an external visibility
channel exists, which this design does not add.

*Why:* recording is constitutive, not evidential (Prop 5) — a distillation
that left no trace would be an experience-as-capital product exempting
itself from the regime it sells, and the exemption would be the first thing
a skeptical verifier asked about. The self-citation closes the loop that
makes verification temporal: a verifier checks not only that records ground
the claims but that the claiming itself is part of the anchored history,
which is what defeats backdating and unrecorded claiming.

## 4. Certificate shape (property level)

The certificate is bounded by three properties, and its vocabulary is
exhausted by them: **identity** (which chain, under which external head
anchor, issued by which instance), **derivation** (which designated
selection of records, over what span, released under which guard policy
version and verdict records), and **recording** (which chain record
constitutes the distillation act, and where revocation would appear). The
certificate is **attestation-carried**: it rides the existing attestation
machinery, whose issuance, verification, and revocation lifecycle CD-6's
clauses map onto — reviewed structure reused rather than a parallel one
authored (resolved at the attended unknowns pass, 2026-07-22). The
carrier's identity model is constrained by CD-2's holder-independent
verifiability — a carrier that cannot support it does not satisfy this
design. The derivation claim binds the **input designation and the output
commitment, and characterizes nothing between**: the transformation from
designated records to distillate is human–model authorship whose description
would be unverifiable prose, and CD-3's channel separation already directs
quality questions to the endorsement channel (likewise resolved at the
pass). The certificate claims no source outside the designation — a bound on
the claim vocabulary, not a guarantee about the authoring process.
Selection designation reuses the closed-world posture of the guard's policy
vocabulary, and the certificate's span claims cover the designated
selection, not the chain's totality.

## 5. Relation to existing tracks

- **Confidentiality guard (v0.3 FROZEN):** the gate. This design is a
  consumer of CG-1..CG-6 and adds no obligations to them; the distiller is
  an ordinary enrolled surface user. Certified distillation needs the
  guard's outward surface (guard slice 2, not yet implemented); by attended
  decision (2026-07-22) the minimal outward surface — enrollment and verdict
  path for the distillation crossing — is implemented in the guard track as
  the guard's own first increment of its slice 2, owned by the guard; this
  design only sequences that increment's delivery with slice 1 and enrolls
  the distiller as an ordinary surface user. Nothing of the guard is
  authored, forked, or relaxed here. The remainder of guard slice 2
  (general external-model, deposit, and export surfaces) stays with the
  guard track.
- **Synoptis family (khab-1, map-1, rpr-1, sdp-1):** the evidence machinery.
  Head anchoring gives CD-2 its unforgeability transfer; selective
  disclosure gives CD-5 its calculus; reproduction endorsement is CD-3's
  quality channel. Identity continuity (khab-1/map-1) is an inherited
  assumption this design names explicitly. All are cited as frozen
  structures; none are re-authored.
- **skillset_exchange / Meeting Place:** the distribution channel, consumed
  unchanged. A distillate deposits like any SkillSet; the certificate
  travels with it. Whether deposit metadata surfaces the certificate is an
  exchange-side presentation concern, out of this design's scope beyond
  CD-3's no-conflation constraint on surfaces this design controls.
- **L0 core:** untouched. Distiller, certificate, and records all live at
  SkillSet and chain-record level.

## 6. Slices

- **Slice 1 — distill and certify, in-instance.** Selection designation,
  distillate production, certificate issuance, CD-6 recording, and the CD-1
  coupling to the guard — including the minimal guard outward surface for
  the distillation crossing (delivered by the guard track — see §5), brought forward as the guard's own first
  slice-2 increment so CD-1 holds unrelaxed from the first shipped slice.
  Output verifiable in taxonomy terms: identity claims checkable as
  record-and-anchor bindings, with identity continuity a trusted inherited
  assumption (§2); derivation- and recording-family claims anchor-pending
  until the next covering anchoring event, with identity uniqueness and
  designation-overlap citation observance trusted (CD-6); the drawn-from
  link and revocation status trusted, as disclosed. No exchange integration.
  Self-contained and validatable
  against a single instance's own chain (MasaChain_2026 as case #1).
- **Slice 2 — distribution.** Deposit of certified distillates through the
  exchange, certificate traveling with the artifact, revocation path
  exercised end to end.
- **Slice 3 — verification ergonomics.** The verifier-side path for a party
  holding neither KairosChain nor the source chain: what they need, what
  they check, what they must trust. Explicitly last: CD-2 fixes what is
  checkable from the start, and this slice packages rather than extends it.

## 7. Non-goals

Not a quality certification, rating, or review system (CD-3). Not a
marketplace or pricing mechanism. Not a chain-export or backup facility —
the distillate is a new artifact, not a projection of the chain. Not an
anonymization guarantee beyond what CD-1's gate and CD-5's disclosure
discipline explicitly provide: an operator who designates secret-bearing
records for open disclosure has made a policy decision the machinery will
faithfully execute. Not a claim that provenance makes a SkillSet
trustworthy to run — acquisition-side safety review is the acquirer's
existing discipline, unchanged by the presence of a certificate. Not a
proof of content derivation from the designated records — the drawn-from
link is a disclosed trusted claim (CD-2). Span and selection shape can
reveal activity patterns; designation is the control point. Holders who
never re-check retain a certificate that verified at acquisition time.

## 8. Resolved unknowns and mechanism backlog

The pre-review unknowns pass (attended, 2026-07-22) surfaced three
design-determining questions; all three were resolved by the human and are
folded into the body — none remain open: the derivation claim binds input
designation and output commitment only (§4), the certificate is
attestation-carried (§4), and slice 1 carries the minimal guard outward
surface forward (§5, §6). Findings that reopen these as preferences are (c)
advisory; findings that show a resolution to be internally contradictory or
unrealizable remain blocking.

Mechanism backlog (explicitly not body content): selection-designation
vocabulary and file format, including the designation-overlap relation the
re-issuance obligation keys on; certificate serialization and the
commitment and salt parameters (aligned with sdp-1; the claim-core boundary
places commitment openings outside the core); attestation-carrier field
mapping
and lifecycle wiring; distillate packaging layout and how the certificate
physically travels with a deposit; guard-surface enrollment details for the
distiller and the brought-forward distillation crossing; destination
designation for the in-instance release crossing under the guard's
closed-world destination vocabulary; span-claim time semantics relative to
anchoring cadence; verifier-side checking procedure and its minimal toolset
(slice-1 verifiability statements must be exercisable, not deferred entirely
to slice 3); revocation record format; revocation mirror cadence between
chain and carrier; a full per-claim-family checkability-status table pinned
in the certificate profile (subsumes identity-continuity claim-status
pinning, cross-references §2's inherited assumption, notes the
duplicate-identity over-revocation coupling, and directs presenters to
treat non-claim-core carrier content as inert); distillation-record
schema and record sequencing (total order within a block); naming
of the SkillSet and its tools; test and probe naming; MasaChain_2026
case-#1 run parameters.
