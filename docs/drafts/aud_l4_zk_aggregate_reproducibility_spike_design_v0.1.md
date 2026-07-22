---
title: "AUD-L4 ZK Aggregate Reproducibility — Spike Design v0.1 (first zero-knowledge proof in KairosChain)"
author: Masaomi Hatakeyama
date: 2026-07-22
version: 0.1 (spike / not a frozen convention)
status: draft spike design. NOT the sdp-2 membership convention; a distinct AUD-L4 mechanism (aggregate over withheld scores). Target = a genuine zero-knowledge range proof (Phase 2).
inherits (ID reference only, never restated/narrowed/extended):
  - aud_l4_selective_disclosure_design_v0.3 (SDP-1..5, FROZEN; esp. SDP-2 checkably-bound auxiliary, SDP-3 non-production/currency, SDP-4 statement/relation pinning, SDP-5 disclosed computational base)
  - aud_l3_reproducibility_design_v0.4 (RPR-1..5, FROZEN; esp. RPR-1 verdict scope, RPR-4 foreignness + fabrication disclosure)
  - aud_l2_mutual_anchoring_design_v0.5 (MAP-1..4, FROZEN; map-1 §1.1 signature)
  - auditability_head_anchor_design_v0.3 (MPR-1..9, FROZEN; khab-1 committed set / inclusion proofs)
method: design-by-invariant / anti-enumeration for any promotable properties; but this is a SPIKE — mechanism IS the subject here, deliberately, because a spike's job is to pick and prove one concrete mechanism. Promotion to a frozen convention (if it happens) re-abstracts to invariants later.
scope: a demonstrator. Proves, over a public DOI set, coverage + a private-per-item aggregate with a genuine zero-knowledge range proof. Does NOT hide which records (that is sdp-2). Does NOT prove faithful re-execution (inherited RPR-4/MPR-6 limit).
labels: AUD-L1..L4 = auditability levels. Bare L0/L1/L2 = KairosChain memory layers. Never conflated.
---

# AUD-L4 ZK Aggregate Reproducibility — Spike Design v0.1

## §0 What this is, and what it is not

This spike puts the **first genuine zero-knowledge proof** into KairosChain. It
demonstrates, for a reproducibility-audit of a public set of works (the
inaugural scenario: a published list of BioRxiv DOIs), that the auditor:

1. **analysed every work in the public set** (coverage),
2. **keeps every individual reproducibility score secret** (no name-and-shame),
3. **published an aggregate (mean, and/or a threshold count) that is honestly
   computed from those secret scores**, and
4. **each secret score is a legitimate in-range value** — proven in zero
   knowledge, so the aggregate cannot be gamed with out-of-range junk.

It is **not** sdp-2 (which hides *which* record an assertion concerns). Here the
DOI set is public on purpose; what is hidden is the *per-item score value*, and
the zero-knowledge content is a **range proof** over each withheld score. It is
also **not** a claim that the re-executions were performed faithfully — that
residue is inherited from RPR-4 and stated in §6, unchanged.

Naming note: this mechanism is distinct from the sdp-1 (content-blinding) and
sdp-2 (membership-blinding) conventions. If promoted, a candidate convention id
is `sda-1` (selective disclosure — aggregate). This document does not commit a
convention; it is a spike whose output is a working demonstrator plus a
disposition on whether to promote.

## §1 The claim, decomposed (what needs a proof, and what kind)

The audience-facing statement is: *"We reproduced every one of these N public
DOIs; we will not publish any individual paper's score; but the mean
reproducibility over all N is M%, and this figure is honest."*

| # | sub-claim | mechanism | is it zero-knowledge? |
|---|---|---|---|
| C1 | coverage: an adjudicated reproduction endorsement exists for each of the N public DOIs | sdp-1 typed/claimed endorsement per DOI (verdict withheld), signed (map-1 §1.1), foreign (RPR-4) | no — commitment + signature |
| C2 | each individual score stays secret | Pedersen commitment hiding | no — a commitment, not a proof |
| C3 | the published aggregate equals the aggregate of the committed scores | Pedersen additive homomorphism + aggregate opening (Phase 1) | weak — opening a derived commitment |
| C4 | each committed score is a legitimate in-range value (so the aggregate is not forged with out-of-range values) | **range proof (Phase 2)** | **yes — the genuine zero-knowledge proof** |

The first genuine zero-knowledge proof in KairosChain is **C4**. C3 is
commitment arithmetic; without C4, the aggregate in C3 is provably gameable (see
§3 attack). The spike targets C1–C4, with C4 as the centrepiece.

## §2 Construction

### §2.1 The committed audit (bound to the frozen structures — SDP-2)

- The **public DOI set** S = {d_1, …, d_N} is itself committed/anchored (khab-1)
  before any score exists, so the auditor cannot substitute DOIs after seeing
  results. The set-commitment (a khab-1 record or a Merkle root over the DOI
  digests) is the fixed referent of every downstream claim.
- For each d_i the auditor holds an rpr-1 reproduction endorsement E_i whose
  target references d_i's committed computation (target digests — public,
  because the DOI is public), whose verdict/score field is the score s_i, and
  which is foreign-signed (auditor ≠ paper authors; RPR-4). Coverage (C1) is:
  one signed E_i per d_i.
- The **score commitment** is the SDP-2 auxiliary: a Pedersen commitment
  `C_i = g^{s_i} · h^{r_i}` over a prime-order group, **checkably bound** to E_i.
  Binding here means: a committed reference ties `C_i` to `E_i`'s digest, and
  the auditor discloses (to whoever they open to) that `C_i` commits the same
  score the endorsement's withheld field commits — the sdp-1 §1 field digest of
  the score and `C_i` are two commitments of one value, and their agreement is
  the checkable-binding obligation (SDP-2). An unbound `C_i` (a Pedersen
  commitment the auditor could desynchronise from the endorsement's score) is a
  re-authoring under another name and is non-conforming.

### §2.2 Phase 1 — aggregate opening (C3)

- Publish the N commitments C_1…C_N. Pedersen is additively homomorphic, so
  `∏ C_i = g^{Σ s_i} · h^{Σ r_i}`.
- To prove the mean M = (Σ s_i)/N, the auditor opens the aggregate: publish
  `Σ s_i` and `Σ r_i`; anyone checks `∏ C_i = g^{Σ s_i} · h^{Σ r_i}`. Individual
  s_i stay perfectly hidden (Pedersen hiding). Optionally, to avoid revealing
  even `Σ r_i`, replace the opening with a Schnorr proof of knowledge that
  `∏ C_i · g^{-Σ s_i}` is of the form `h^{Σ r_i}` (a Sigma protocol) — genuinely
  hides the aggregate randomness; still not the load-bearing ZK.
- This is *necessary* to tie the published number to the hidden scores, but
  *insufficient*: it constrains nothing about the value of each s_i.

### §2.3 Phase 2 — per-score range proof (C4, the zero-knowledge core)

- For each C_i, a **range proof** demonstrates `s_i ∈ [0, V_max]` **without
  revealing s_i**. This is the genuine zero-knowledge proof: a property of a
  hidden value shown without disclosing the value.
- Candidate mechanisms (a spike-time choice, §5): (i) Bulletproofs (log-size,
  no trusted setup) as verifier — strongest but heaviest; (ii) a bit-decomposition
  Sigma proof — commit each bit of s_i, prove each bit is 0/1 (a Schnorr OR
  proof), and prove the bits reconstruct C_i; for a small V_max (e.g. a 0–7
  three-bit score, or 0–100 in seven bits) this is implementable in pure Ruby
  over an elliptic-curve group with no external prover.
- With C4 in force, the §3 attack is closed: an out-of-range value cannot
  produce a valid range proof, so the aggregate in C3 is over legitimate scores
  and the published mean is both secret-preserving and unforgeable within the
  disclosed trust base (§6).

## §3 The attack Phase 2 exists to stop (why C4 is necessary, concretely)

Without the range proof, a Pedersen commitment binds the auditor to *some*
value but never to a *legitimate* one:

- True scores are poor — true mean 8 (out of 100). The auditor wants to publish
  mean 40.
- Commit 999 real low scores (sum 8000) and, for the 1000th, commit the value
  32000 (out of any legitimate range).
- `Σ = 40000`, published mean 40; the Phase-1 aggregate check
  `∏ C_i = g^{40000} · h^{ΣR}` **passes**, because Pedersen constrains no range.
- Phase 2 closes it: the 1000th commitment's range proof (`∈ [0,100]`) cannot be
  produced for 32000; the forgery is detected. To reach an honest mean of 40 the
  auditor now needs real in-range scores summing to 40000 — i.e., genuinely good
  papers.

## §4 Threshold variant (optional stretch — "at least K passed")

If the audience-facing figure is a count ("≥ K of the N reproduced at score ≥ t")
rather than a mean, each item additionally carries a boolean commitment
`b_i ∈ {0,1}` for "s_i ≥ t", proven consistent with s_i's range decomposition,
and the sum `Σ b_i ≥ K` is shown by an aggregate range proof on `Σ b_i`. This is
strictly more machinery than the mean; the spike treats it as a follow-on to the
mean demonstrator, not the first target.

## §5 Mechanism decision surface (spike choices — the §11 of a spike)

- Group / curve: a prime-order group with a clean Ruby scalar-multiplication
  path. Options: a pure-Ruby prime-field EC (e.g. secp256k1 / ristretto255 field
  arithmetic hand-rolled — most self-contained, slowest), a thin dependency
  (an EC gem), or OpenSSL EC point arithmetic (awkward Ruby API). Whatever is
  chosen, it is the FIRST external-or-nontrivial cryptographic dependency in the
  synoptis anchoring stack — a deliberate departure from the "sha256 + Ed25519
  only" rule of khab/map/rpr/sdp-1, and must be disclosed as such (SDP-5).
- Range-proof form: Bulletproofs-as-verifier vs bit-decomposition Sigma OR
  proofs; V_max size (small V_max makes bit-decomposition cheap — a demo may use
  a coarse 0–7 or 0–15 reproducibility band and disclose the coarseness).
- Pedersen generators g, h: how h is derived so that `log_g h` is unknown to the
  auditor (nothing-up-my-sleeve derivation from a public seed) — a binding
  requirement; disclose the derivation (SDP-5).
- SDP-2 binding construction: the concrete committed reference tying `C_i` to
  `E_i`, and the checkable equality between the sdp-1 score field commitment and
  the Pedersen commitment of the same score.
- DOI-set commitment: khab-1 record vs Merkle root; how "no substitution" is
  presented to the audience.
- Aggregate-opening form: plain opening of `(Σs_i, Σr_i)` vs a Schnorr proof
  hiding `Σr_i`.
- Proof serialization, verifier CLI surface, and how the range proofs' soundness
  assumptions and (absence of) trusted setup are surfaced to the verifier (SDP-5).

## §6 Honest limits (must be stated in the demo, so it is not theatre)

- (a) The aggregate is honest *relative to the committed scores*; that each score
  is the *true re-execution result* is NOT proven — garbage-in remains, exactly
  the RPR-4/MPR-6 residue, unchanged by any zero-knowledge machinery.
- (b) "Analysed all N" means "committed and signed N adjudicated endorsements
  bound to the N public DOIs", not "ran N reproductions"; a colluding or
  fabricating auditor can sign without running (RPR-4 fabrication disclosure).
- (c) The DOI set must be committed before results exist, or substitution
  reopens; the spike commits it (khab-1) and presents that as a precondition.
- (d) The range proof's soundness rests on the group's discrete-log hardness (and
  the honest derivation of h); hiding rests on Pedersen's perfect hiding. No
  trusted setup for bit-decomposition Sigma / Bulletproofs — stated, not implied
  (SDP-5).
- (e) This is a spike demonstrator, additive, touching no frozen invariant and no
  existing file; it is not a promoted convention until a separate promotion step.

## §7 Deliverables and staging (for the implementing session)

- Phase 1 slice: Pedersen commitment module (group ops, commit, homomorphic add,
  aggregate open / Schnorr aggregate proof), bound to a synthetic rpr-1
  endorsement set; tests; CLI (commit / aggregate-verify). No range proof yet.
- Phase 2 slice: range proof (chosen form), per-score, with the §3 forgery as a
  negative test that MUST fail to verify; tests; CLI (range-verify, full-audit-
  verify). This slice carries the "first zero-knowledge proof" claim.
- Both: additive under synoptis anchoring (new files only), template mirror,
  existing suites green, commit gate (human) before any release.
- Then: a disposition on whether to promote to a frozen convention (`sda-1`),
  re-abstracted to invariants, or keep as a demonstrator.

## §8 Relation to the rest of the roadmap

- Independent of sdp-2 (membership hiding); the two can proceed in either order.
- Directly serves the GenomicsChain reproducibility-audit direction (L2
  tee_zkvm_verifiable_computation_discussion_20260722): this is the confidential-
  aggregate half that TEE was floated for, achieved instead with commitments +
  a range proof, no CPU-vendor trust root.
- The inaugural public-data reproducibility audit (BioRxiv) needs no secrecy for
  the audit itself; this spike is the layer that lets the *scores* stay private
  while the *aggregate* is public and honest — the piece that turns a name-and-
  shame liability into a publishable, verifiable statistic.
