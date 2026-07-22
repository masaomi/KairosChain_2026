---
title: "AUD-L4 ZK Range Proof — Phase 2 Design Spec v0.3 (KairosChain's first genuine zero-knowledge proof)"
author: Masaomi Hatakeyama
date: 2026-07-22
version: 0.3 (spike / not a frozen convention). CONVERGED at R2 (5 APPROVE / 1 REJECT, ≥ 4/6 rule; the lone REJECT and all other findings were (c) documentation-precision, 0 (a)/(b)). v0.3 folds those (c) clarifications in for implementation-readiness. See §0.1 changelog.
status: FROZEN design spec, pre-implementation (ready for the implementation session at the human commit gate). Elaborates Phase 2 of the AUD-L4 ZK aggregate spike. Authored by the orchestrator from ground-truth Phase 1 API + protocol; hardened after R1 (verifier-contract gaps) and polished after R2 (contract-precision).
inherits (ID reference only, never restated/narrowed/extended):
  - aud_l4_zk_aggregate_reproducibility_spike_design_v0.1 (Phase 1 memo; §2.3 range-proof direction, §3 the 32000 forgery this proof must stop)
  - aud_l4_selective_disclosure_design_v0.3 (SDP-1..5, FROZEN; esp. SDP-2 checkably-bound auxiliary, SDP-3 non-production, SDP-5 disclosed computational base)
  - aud_l3_reproducibility_design_v0.4 (RPR-1..5, FROZEN; RPR-4 fabrication/foreignness residue)
  - auditability_head_anchor_design_v0.3 (MPR-1..9, FROZEN; MPR-6 re-execution-fidelity residue)
method: design-by-invariant is deferred to promotion; this is a SPIKE, so the mechanism IS the subject — a range proof cannot be specified as an invariant without naming its construction. Promotion to a frozen convention (candidate id `sda-1`) re-abstracts to invariants later.
scope: specifies the per-score range proof (sub-claim C4) that closes the Phase-1 §3 attack. Additive: one new module `Synoptis::Anchoring::RangeProof` (file range_proof.rb), NEW subcommands added to bin/sda_verify.rb (existing subcommands unchanged), tests. Touches no frozen invariant.
labels: AUD-L1..L4 = auditability levels. Bare L0/L1/L2 = KairosChain memory layers. Never conflated.
---

# AUD-L4 ZK Range Proof — Phase 2 Design Spec v0.2

## §0.1 Changelog (v0.1 → v0.2), from R1 multi-LLM review

R1 (design, 3/6 APPROVE → REVISE) surfaced genuine (a) verifier-contract gaps the
honest-protocol math had hidden. v0.2 closes them:

- **(a, P0) §5 range escape:** verify_range now enforces the exact object shape
  (`format`, `vmax==7`, `bits==3`, exactly 3 bit-commitments paired 1:1 with 3
  or-proofs) BEFORE reconstruction, so a prover cannot supply extra bits to widen
  the range beyond [0,7].
- **(a, P1) §5 point/scalar validation:** verify_range decodes and curve-checks
  **every** point (`C`, all `B_j`, and each OR proof's `A_0,A_1`), rejects the
  identity, and parses `e_0,z_0,z_1` as canonical scalars in `[0, N)` (rejecting
  non-canonical `e+N` forms).
- **(a, minor) §2 blinding leak:** `r_2 == 0` is resampled (else `B_2 = b_2·G`
  loses hiding and leaks the top bit).
- **(hardening) §4 challenge binding:** the Fiat-Shamir transcript now binds the
  proof metadata (`format,vmax,bits`) and the bit index `j`, removing positional
  ambiguity and any cross-position OR-proof replay.
- **(disclosed limit) §9:** the pure-Ruby prover is **not constant-time**;
  timing/cache side-channels are out of scope for this non-production demonstrator
  (SDP-3) and disclosed, with fixed emit-ordering adopted as partial mitigation.
- **(c) wording:** §scope, §1.1 field-vs-scalar inverse, §3 emit order, §6 test
  example, §1/§8 ROM adjacency — all clarified.

## §0.2 Changelog (v0.2 → v0.3), from R2 multi-LLM review (CONVERGED)

R2 reached 5/6 APPROVE (≥ 4/6 rule); all findings were (c) documentation-precision
(0 (a)/(b)). v0.3 folds them in so the implementation session has no ambiguity:

- **verify_range takes the raw proof STRING** (§5): step-0's "canonical
  re-serialization == input bytes" requires the original bytes, so the argument is
  the JSON string (like `parse_score_record!` / the CLI `binding` path), not a
  pre-parsed Hash.
- **Canonical-JSON rule named** (§5 step 0): the re-serialization check is against
  `Entry.canonical_json` (recursively sorted keys, `JSON.generate`, integers as
  literals) — the same one-artifact-one-digest discipline as sdp-1.
- **decode canonicity spelled out** (§5 step 1): `EcGroup.decode` already enforces
  the canonical compressed encoding (prefix `02/03`, exactly 64 hex, `x < P`,
  on-curve); a non-canonical point encoding cannot survive it.
- **Admission-vs-algebra contract stated** (§5): every admission failure (schema,
  lengths, non-hex, scalar `≥ N`, off-curve, identity) RAISES `RangeError`; only a
  well-formed proof that fails an algebraic check (reconstruction or an OR
  equation) returns `false`. Resolves the lone R2 REJECT (raise-vs-return
  consistency).
- **§6 negative test split** accordingly: an over-width (4+ bit) object is a
  structural RAISE; the low-3-bits-of-32000 case is a reconstruction RETURN-false.
- **e_1 = 0 non-exploitability note** (§3/§8): reaching e_1 = 0 needs `e_0 = e`, but
  `e` is the Fiat-Shamir hash of a transcript containing `A_0,A_1`; a prover cannot
  choose `e_0` equal to that hash except with probability 1/N, so the degenerate
  case is not a soundness path.
- **Fixed-width concatenation note** (§4): all transcript operands are fixed-width
  (`encode` = 66-hex non-identity, scalars 64-hex, `j` single-digit), so the `|`
  join is injective; an implementer must keep them fixed-width.
- **§2 resample terminates**: `r_2 == 0` has probability 1/N, so the loop exits in
  one iteration w.h.p. (no unbounded-loop concern; a defensive bound is optional).
- **§7 aggregator named**: `full-audit-verify` orchestrates the existing C1/C3
  verifiers plus the new C4; §scope's "per-score range proof (C4)" is the new
  proof, the CLI merely wires it to the Phase-1 verifiers.

## §1 What this is, and the base it builds on

Phase 1 (commit `14a7bbf`) gave each per-DOI reproducibility score `s` a Pedersen
commitment `C = s·G + r·H` that perfectly hides `s`, is additively homomorphic
(so an aggregate mean opens without revealing any term), and is checkably bound
to an rpr-1 endorsement (SDP-2). Phase 1 deliberately proved **nothing about the
range of `s`**: its own §3 test pins the gap — an out-of-range term (32000) still
opens the aggregate, forging the mean.

**Phase 2 closes that gap and is KairosChain's first genuine zero-knowledge proof
(honest-verifier zero-knowledge, made non-interactive by Fiat-Shamir in the random
oracle model — §8).** For each committed score it demonstrates `s ∈ [0, 7]` (the
disclosed 3-bit reproducibility band, VMAX=7) **without revealing `s`**.

The construction is a **bit-decomposition Sigma range proof**: commit each bit of
`s`, prove each bit is 0 or 1 with a Cramer–Damgård–Schoenmakers '94 OR proof, and
prove the bits reconstruct `C`. No trusted setup; no new runtime dependency
(pure-Ruby secp256k1; the departure from "sha256 + Ed25519" is new *math*, not new
external code — SDP-5).

### §1.1 Phase 1 API this builds on (ground truth — do not re-derive)

- `Synoptis::Anchoring::EcGroup`: constants `P, A=0, B=7, N, H_SEED, INFINITY`,
  `class Point(#x,#y,#infinity?)`, `GroupError`. module_function: `g`, `h`,
  `add(p1,p2)`, `subtract(p1,p2)`, `negate(pt)`, `scalar_mul(k,pt)`,
  `on_curve?(pt)`, `mod_inv(a)`, `encode(pt)`/`decode(hex)` (compressed:
  `'02'/'03'+x64`, identity `'00'`), `sqrt_mod(v)`, `hash_to_curve`.
  **Inverse discipline (do not mix):** `EcGroup.mod_inv` is a **field** inverse
  (mod P) — used inside curve arithmetic only. RangeProof's `inv4` is a **scalar**
  (group-order) inverse, `4^(N-2) mod N` via `Integer#pow(N-2, N)` (N prime). Never
  route a scalar inverse through `mod_inv`.
- `Synoptis::Anchoring::Pedersen`: `commit(value, blinding) -> Point` (value ≥ 0
  integer, blinding non-zero mod N), `random_blinding`, `aggregate`, `open?`,
  `prove_aggregate_randomness`/`verify_aggregate_randomness`, and
  `challenge(pt_p, a_pt) -> Integer mod N` = `SHA256(CHALLENGE_DOMAIN | encode(g)
  | encode(h) | encode(pt_p) | encode(a_pt))` reduced mod N. RangeProof mirrors
  this Fiat-Shamir pattern with its own domain and richer transcript (§4).
- `Synoptis::Anchoring::AggregateDisclosure`: `SCORE_FORMAT='sda-1/score'`,
  `VMAX=7`, `commit_score(record, score:, blinding:, salts:) -> {'commitment' =>
  encoded, ...}` (the value a range proof targets is exactly the point this emits),
  `verify_mean(commitments:, sum_s:, sum_r:)`, `valid_band?(score)`.

## §2 Bit commitment and the reconstruction invariant

Let `s ∈ [0,7]`, `n = 3` bits, `C = s·G + r·H` (the Phase-1 commitment, blinding
`r`). Write `s = Σ_{j=0..2} b_j · 2^j`, `b_j ∈ {0,1}`.

**Per-bit commitments.** Sample bit blindings so all three are non-zero and they
reconstruct `r`:

```
loop:
  r_0, r_1 ← random non-zero mod N
  r_2 = (r − r_0 − 2·r_1) · inv4  (mod N),   inv4 = 4^(N-2) mod N   # N prime ⇒ 4 invertible
  break unless r_2 == 0            # resample: a zero r_2 makes B_2 = b_2·G, leaking the top bit
B_j = b_j·G + r_j·H  = Pedersen.commit(b_j, r_j)   (j = 0,1,2)
```

**Reconstruction invariant (holds by construction).**

```
Σ_{j} 2^j · B_j = (Σ_j 2^j b_j)·G + (Σ_j 2^j r_j)·H = s·G + r·H = C
```

because `Σ 2^j r_j = r_0 + 2 r_1 + 4·r_2 = r` by the choice of `r_2`. The verifier
recomputes `Σ 2^j·B_j` over **exactly three** decoded points (§5) and checks it
equals `C`, tying the bit-commitments to the *specific* Phase-1 commitment — a
prover cannot range-prove a different commitment than the one that entered the
aggregate.

Design decisions: (D1) `r_0,r_1` independent non-zero, `r_2` derived and resampled
if zero. (D2) bit index domain 0..2 only (VMAX=7); the object shape is fixed and
**enforced by the verifier** (§5), so a prover cannot smuggle extra bits to widen
the range. (D3) `B_j` is an ordinary Pedersen commitment (reuses `Pedersen.commit`).

## §3 Per-bit OR proof (CDS '94): `b_j ∈ {0,1}` in zero knowledge

For each `B_j`, prove the disjunction

```
  (branch 0)  B_j     = r_j·H       # b_j = 0: B_j is a pure H-multiple
   OR
  (branch 1)  B_j − G = r_j·H       # b_j = 1: B_j − G is a pure H-multiple
```

Both branches are Schnorr proofs of knowledge of a discrete log **base H**. Define
`X_0 = B_j`, `X_1 = B_j − G`. The prover knows the witness `r_j` for exactly one
branch (branch `b_j`). Standard CDS OR: run the true branch honestly, **simulate**
the false branch.

**Prover** (real branch `t = b_j`, fake branch `f = 1 − b_j`):

```
# fake branch f: sample challenge + response, back-solve the commitment
e_f, z_f  ← random in [0, N)
A_f = z_f·H − e_f·X_f

# real branch t: honest Schnorr commitment
k        ← random in [1, N)
A_t = k·H

# global challenge binds both A_0, A_1 (Fiat-Shamir, §4)
e   = H_challenge(j, C, B_j, A_0, A_1)          (mod N)
e_t = (e − e_f) mod N
z_t = (k + e_t · r_j) mod N
```

**Emit order is by BIT VALUE, not by real/fake:** the tuple `(A_0, A_1, e_0, z_0,
z_1)` is always indexed 0/1 by the statement branch. So when `b_j = 1` (real branch
1), the published `e_0` is the *fake* branch's challenge `e_f`, and `e_1 = e − e_0`
is the real one. Emitting in fixed statement-index order (independent of which was
real) is required — see §9 side-channel note.

**Verifier** for one bit (after the structural/point/scalar checks of §5):

```
e   = H_challenge(j, C, B_j, A_0, A_1)          (mod N)
e_1 = (e − e_0) mod N
check  z_0·H == A_0 + e_0·X_0     where X_0 = B_j
check  z_1·H == A_1 + e_1·(B_j − G)
```

Both equalities must hold. Honest-verifier zero-knowledge: the simulated branch is
distributed identically to a real one, so the transcript reveals nothing about
`b_j` beyond "it is 0 or 1". Special soundness: two accepting transcripts with the
same `A_0,A_1` but different `e` yield the witness for one branch, i.e. `B_j`
genuinely commits 0 or 1.

## §4 Fiat-Shamir: non-interactive challenge

Mirror `Pedersen.challenge`'s shape, binding the proof metadata and the bit index
so a challenge cannot be replayed at another position or under another policy:

```
H_challenge(j, C, B_j, A_0, A_1) =
  SHA256( "sda-1/range-proof-bit-challenge"
          | "sda-1/range-proof" | "vmax=7" | "bits=3" | "j=" + j
          | encode(G) | encode(H) | encode(C) | encode(B_j)
          | encode(A_0) | encode(A_1) )  reduced mod N
```

Binding `G,H` domain-separates to this group; binding `format,vmax,bits` ties the
challenge to the enforced policy (defense in depth with the §5 structural check);
binding `j`, `C`, and `B_j` makes each bit proof position-specific — even if two
`B_j` coincided, one OR proof is not replayable at another index. (A single
whole-proof challenge binding `C` and all three `B_j` at once is an equivalent
stricter alternative, §11.) The `|` join is injective because every operand is
fixed-width — `encode(...)` is 66 hex (identity already rejected in §5), the
implicit scalars are absent here, and `j` is single-digit at 3 bits; an
implementer must keep operands fixed-width so no delimiter ambiguity is
reintroduced.

## §5 Range proof object and verification

**Object** (canonical JSON, one artifact one digest — `Entry.canonical_json`,
which recurses through arrays-of-hashes):

```json
{
  "format": "sda-1/range-proof",
  "vmax": 7,
  "bits": 3,
  "bit_commitments": ["<enc B_0>", "<enc B_1>", "<enc B_2>"],
  "or_proofs": [
    {"a0": "<enc>", "a1": "<enc>", "e0": "<hex>", "z0": "<hex>", "z1": "<hex>"},
    { … B_1 … },
    { … B_2 … }
  ]
}
```

`C` is **not** carried inside the object: it is the caller's input (the commitment
from `commit_score`/`Pedersen.commit`), so a range proof is always verified
*against a named commitment*, never in isolation.

**Verification** `verify_range(commitment_enc, proof_string) -> bool`. The proof
argument is the **raw JSON string** (step 0 needs the original bytes for the
canonical re-serialization check), exactly as `parse_score_record!` takes a
`record_string`. **Contract (raise vs return):** every *admission* failure — schema,
array lengths, non-hex, a scalar `≥ N`, off-curve, or identity — RAISES
`RangeProof::RangeError`; only a *well-formed* proof that fails an *algebraic* check
(reconstruction or an OR equation) returns `false`. Steps 0–1 are the R1-hardened
admission checks; a malicious prover must clear them before any algebra runs.

0. **Structural admission (reject range-escape):**
   - `proof['format'] == 'sda-1/range-proof'`, `proof['vmax'] == 7`,
     `proof['bits'] == 3`, and object keys are exactly the closed schema.
   - `bit_commitments.length == 3` and `or_proofs.length == 3` (1:1 pairing);
     each or_proof has exactly the keys `a0,a1,e0,z0,z1`.
   - canonical re-serialization equals the input bytes: `Entry.canonical_json`
     (recursively sorted keys, `JSON.generate`, integers as literals — the sdp-1
     one-artifact-one-digest discipline) applied to the parsed object must equal
     `proof_string`.
1. **Point and scalar validation:**
   - decode `C` and each `B_j, A_0, A_1` with `EcGroup.decode`, which already
     enforces the canonical compressed encoding (prefix `02/03`, exactly 64 hex,
     `x < P`, on-curve); additionally reject the **identity** (`decode('00')` and
     any point with `#infinity?` — a range proof over `∞` would degenerate).
   - parse each `e_0, z_0, z_1` as fixed-width 64-hex lowercase integers and
     require `∈ [0, N)` (reject non-canonical `e+N` forms; malleability guard).
2. **Reconstruction:** compute `Σ_{j=0..2} 2^j·B_j` via EcGroup and check `== C`.
3. **Per-bit OR:** run the §3 verifier for each of the three `B_j`; all must hold.
4. Return true iff steps 0–3 all pass.

Passing ⇒ `C` commits a value `Σ b_j 2^j ∈ [0,7]` (step 0 fixes the width to 3
bits, step 3 forces each `b_j∈{0,1}`, step 2 + Pedersen binding forces `C`'s value
to equal the 3-bit sum).

Prover surface: `prove_range(score, blinding) -> proof` (requires `0 ≤ score ≤ 7`;
refuses out-of-band at the prover, mirroring `valid_band?` — but the *verifier*
never trusts that refusal, §6).

## §6 The §3 forgery as a mandatory negative test

The Phase-1 §3 attack committed 32000 to forge a mean. Phase 2 makes that
un-provable. With `C = Pedersen.commit(32000, r)`:

- A prover using the low 3 bits of 32000 (`32000 mod 8 = 0`) builds
  `Σ 2^j·B_j = 0·G + r·H = r·H`, which is **not** `C = 32000·G + r·H`. Step 2
  (reconstruction) fails.
- A prover trying to supply MORE than 3 bit-commitments (to represent 32000) is
  rejected at step 0 (`bits==3`, `bit_commitments.length==3`). No `{0,1}^3`
  assignment reconstructs > 7, and Pedersen binding forbids `C` (commits 32000)
  equalling a ≤7 commitment. No accepting proof exists.

**Required tests** (design; implemented in Phase 3). The positive example is
written against the real API — `commit_score` returns a Hash and the SAME blinding
must feed both the commitment and the proof:

```
r = Pedersen.random_blinding
c = AggregateDisclosure.commit_score(rec, score: s, blinding: r)['commitment']   # for s in 0..7
assert RangeProof.verify_range(c, RangeProof.prove_range(s, r))
```

- positive: true for every `s ∈ 0..7`.
- **negative (mandatory), two distinct paths per the §5 contract:**
  (i) a *well-formed* proof for `C = Pedersen.commit(32000, r)` built from the low
  3 bits (`32000 mod 8 = 0`) fails step-2 reconstruction and `verify_range`
  RETURNS false; (ii) an *over-width* object (4+ bit-commitments, to try to
  represent 32000) is a step-0 structural violation and RAISES `RangeError`. The
  test asserts both — never a raise-that-passes. This test carries the "first
  zero-knowledge proof" guarantee.
- tamper: flip any `z/e/A/B_j` byte ⇒ false; a non-canonical `e_0 ≥ N` ⇒ false
  (step 1); a range proof of `C'` presented against `C` ⇒ reconstruction false.
- structural: `bits != 3`, wrong array lengths, identity point, off-curve `A` ⇒
  false/reject.
- zero-knowledge smoke: two proofs of the same `s` (fresh randomness) differ; the
  object carries no opened value field.

## §7 CLI surface (NEW subcommands in sda_verify.rb; existing ones unchanged)

Additive subcommands, same helper conventions (`die/reject/read_file/load_json/
strict_int/hex_scalar`), exit 0=VERIFIED / 1=REJECTED / 2=usage:

- `range-verify <commitment_hex> <range_proof.json>` — verify one score's range
  proof against its commitment; prints VERIFIED/REJECTED and the failing check.
- `full-audit-verify <bundle.json>` — the whole audit in one pass:
  C1 coverage (one signed foreign rpr-1 endorsement per DOI, via sdp-1),
  C3 aggregate (`verify_mean`), and C4 **every** per-score range proof. Reports
  which of C1/C3/C4 hold and the honest-limit notes (§9). `bundle.json` carries
  the DOI-set commitment, the per-item {commitment, range_proof, endorsement
  presentation}, and the aggregate opening.

## §8 SDP-5 disclosure (soundness, hiding, no setup)

- **Soundness** rests on: (i) discrete-log hardness in the secp256k1 prime-order
  group; (ii) special-soundness of each CDS Sigma OR proof (⇒ each `B_j` commits
  0/1) — **contingent on the verifier decoding and curve-checking `A_0,A_1` and
  range-checking the response scalars** (§5); (iii) the Fiat-Shamir transform in
  the random-oracle model (SHA-256 as RO). Reconstruction over the fixed 3 bits
  plus Pedersen computational binding pin `C`'s value to `[0,7]`. The degenerate
  `e_1 = 0` case (where the branch-1 equation collapses to `z_1·H == A_1`) is not a
  soundness path: reaching it requires `e_0 = e`, but `e` is the RO hash of a
  transcript that already contains `A_0,A_1`, so a prover cannot fix `e_0` equal to
  that hash except with probability 1/N (the standard CDS argument that at most one
  branch is simulatable).
- **Hiding / zero-knowledge:** Pedersen perfect hiding for `C` and each `B_j`, plus
  honest-verifier zero-knowledge of the CDS OR proof (simulated false branch). "ZK"
  in this document always means HVZK made non-interactive in the ROM — never an
  unqualified claim.
- **No trusted setup.** Generators `G` (standard) and `H` (nothing-up-my-sleeve
  from `H_SEED`, `log_G H` unknown) are the only public parameters; both are
  recomputable. Stated, not implied.
- **Disclosed base delta:** first construction beyond "sha256 + Ed25519" — new
  math, no new runtime dependency; OpenSSL remains a test-only oracle. Coarse band
  (0..7) disclosed as deliberate.

## §9 Honest limits (must stay in the demo — not theatre)

- (a) A valid range proof shows `s ∈ [0,7]`; it does **not** show `s` is the true
  re-execution result. Garbage-in remains — the RPR-4/MPR-6 residue, unchanged by
  any zero-knowledge machinery.
- (b) Range/aggregate honesty is about the *committed* scores only. Coverage (C1)
  and the aggregate (C3) are the Phase-1 pieces; the range proof (C4) only forbids
  out-of-range terms.
- (c) The band is coarse (3-bit) by disclosure; a finer band is more bits and a
  heavier proof, not a different construction.
- (d) **Not constant-time.** The pure-Ruby prover uses variable-time big-integer
  and point operations; a local adversary timing the *prover* could learn which OR
  branch is real. This is out of scope for a non-production demonstrator (SDP-3),
  disclosed rather than silently assumed. Partial mitigation adopted: proof
  elements are emitted in fixed statement-index order (§3), so the *published*
  transcript leaks nothing; only prover-local timing is at issue. The *verifier* is
  public-input only and carries no secret to leak.

## §10 Deliverables and staging (for the implementation session)

- New module `Synoptis::Anchoring::RangeProof` in
  `.kairos/skillsets/synoptis/lib/synoptis/anchoring/range_proof.rb`
  (`prove_range`, `verify_range`, internal `bit_or_prove`/`bit_or_verify`,
  `range_challenge`, `RangeError`, a module-local `inv4`), reusing EcGroup/Pedersen.
  Scalar parsing reuses the Phase-1 strict-hex + `< N` discipline.
- CLI additions in `bin/sda_verify.rb` (§7); existing subcommands untouched.
- Tests in `test/test_sda_range_proof.rb`: positive 0..7, the mandatory 32000
  negative (incl. over-width object), tamper, non-canonical scalar, structural
  (bits/length/identity/off-curve-A), ZK smoke; reconstruction cross-checks and the
  OpenSSL oracle where points are involved. Follow the existing assert-runner.
- **Template mirror** to `KairosChain_mcp_server/templates/skillsets/synoptis/`
  (lib + bin + test). Additive only; existing synoptis suites stay green; **stop
  at the commit gate (human)**.
- Then: a disposition on promoting the aggregate+range mechanism to a frozen
  convention (`sda-1`, re-abstracted to invariants) or keeping it a demonstrator.

## §11 Backlog / open choices (not blocking implementation)

- Whole-proof single challenge (bind `C` + all `B_j` once) vs the §4 per-bit
  challenge (which already binds `j`, `C`, and the metadata). Equivalent soundness;
  revisit if a reviewer prefers the single-transcript form.
- Batch verification of the three OR proofs (one multi-scalar check) — an
  optimisation, not needed at N-small demo scale.
- Constant-time prover (out of the demonstrator's scope; §9d) if this is ever
  promoted toward production.
- Aggregate-of-booleans threshold variant ("≥ K passed at score ≥ t"), the spike
  memo §4 stretch — strictly more machinery; out of Phase 2 scope.
