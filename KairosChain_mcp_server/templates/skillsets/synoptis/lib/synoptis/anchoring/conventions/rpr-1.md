# rpr-1 — KairosChain Reproduction Endorsement Convention, version 1

Status: committed verification convention (RPR-1..5 of
aud_l3_reproducibility_design v0.4). The SHA-256 over this file's raw bytes is
the convention integrity digest; every artifact that names `rpr-1` commits it
as its convention reference. A verifier holding a definition whose digest does
not match the committed one MUST treat the artifact's convention as
unresolvable and refuse to verify under it. Any change to this convention is a
new identifier (`rpr-2`, ...); this file is never edited in place.
rpr-1 builds on map-1 (credentials, attestation signatures, attestation types,
retraction) and khab-1 (committed identity, committed order) and modifies
neither: a map-1 artifact is valid with or without any rpr-1 artifact present.

All record literals below are canonical JSON (keys sorted recursively,
`JSON.generate` compact form). A record is valid only in its canonical
serialization with exactly the fields shown — a non-canonical or extra-field
record is not an rpr-1 artifact and is ignored as noise (map-1 §4 precedent).

## 1. Re-execution target (RPR-2)

    {"environment_sha256":"<64-hex>","format":"rpr-1/target",
     "input_sha256":"<64-hex>","output_sha256":"<64-hex>",
     "pipeline_sha256":"<64-hex>"}

The target commits both halves of the verdict's referent: what is re-run
(inputs, environment, pipeline version) and what the re-run output is judged
against (the committed output). The first three digests — `input_sha256`,
`environment_sha256`, `pipeline_sha256` — constitute the target's **committed
computation identification** (design §3(b)): the identification of what is
re-run, which two targets can share while naming different committed outputs.
`output_sha256` completes the target but does not participate in that
identification. The target digest is the SHA-256 of the target's canonical
JSON. What the digests are digests OF (file formats, environment pinning,
pipeline identity) is the referenced material's business; rpr-1 commits
references, it does not validate referents (MPR-4 asymmetry, RPR-2 limit).

## 2. Tolerance declaration (RPR-3)

    {"format":"rpr-1/tolerance","kind":"bit-identity","target_sha256":"<64-hex>"}

A tolerance declaration is bound to a named target and is result-free by
construction: the schema is closed and `kind` is the only expressive field, so
no outcome-referencing content can be expressed. At rpr-1 the only kind is
`bit-identity` (re-run output matches the committed output byte for byte);
richer tolerance grammars (numerical bounds, domain equivalence) are a new
convention — this narrowness is disclosed, not hidden. The declaration is
committed as an internal-chain record ahead of the endorsements it governs;
committed position provides decidable anteriority (MPR-8). One declaration has
exactly one digest (canonical serialization).

### 2.1 Declaration-set assessment (RPR-3)

Conformance of an endorsement's tolerance is assessed against the record, not
the endorser's selection. Given target records, tolerance declarations with
their committed positions, and the endorsement's committed position, the
assessment reports:

- every anterior declaration bound to the endorsement's target;
- every anterior declaration bound to any sibling target sharing the same
  committed computation identification (§1) — a menu spread across
  near-duplicate targets is the same menu and is read as one set (at rpr-1,
  sharing = equality of the three computation-identification digests);
- the multiplicity of that pooled set and the invoked declaration's place in
  it;
- the unresolved residue: declarations whose `target_sha256` resolves to no
  supplied target record (sharing undecidable there), disclosed rather than
  silently dropped.

The assessment reports; the reader prices. A verdict judged under one of many
anterior declarations is conforming and wears the multiplicity openly; a
tolerance chosen after the result is non-conforming (its posteriority is
decidable from committed order). The assessment is a function of the committed
record alone, never of presentation order: a declaration committed at several
positions is one declaration (one digest) with several commitments; the
invoked declaration conforms iff any of its commitments is anterior,
represented by the earliest, with posterior commitments disclosed alongside;
multiplicity counts distinct declarations, and the invoked declaration's
place is reported as its rank in the pooled anterior set ordered by earliest
anterior position, with equal positions ordered by declaration digest — so
every reported quantity, ranks included, is decidable from the committed
record alone.

## 3. Reproduction endorsement (RPR-1, RPR-4)

hand-adjudicated:

    {"adjudication_mode":"hand","format":"rpr-1/endorsement",
     "target_sha256":"<64-hex>","tolerance_sha256":"<64-hex>",
     "verdict":"reproduced"}

procedure-adjudicated:

    {"adjudication_mode":"procedure","format":"rpr-1/endorsement",
     "procedure_sha256":"<64-hex>","target_sha256":"<64-hex>",
     "tolerance_sha256":"<64-hex>","verdict":"not-reproduced"}

`verdict` is `reproduced` or `not-reproduced`: the affirmative and the
negative verdict are the same kind of record under the same bindings, so the
record has a conforming place for failure as well as success (RPR-1).
`adjudication_mode` names the gate behind the verdict (RPR-4): `hand`, or
`procedure` with `procedure_sha256` naming the committed adjudication
procedure whose anterior adoption is the judgment act. `procedure_sha256` is
present exactly when the mode is `procedure` (closed schema per mode). The
named mode, like the attestation type itself, is a declaration and not a
proof (map-1 §3 non-self-certifying).

The endorsement is signed under the endorser's map-1 credential using the
map-1 §1.1 attestation signature, with the payload being the endorsement
record string. Verification needs only the credential, the record, and the
signature. The endorsement is carried with `attestation_type` =
`quality-endorsement` (map-1 §3, unchanged).

Foreignness (RPR-4) is a conformance condition: an endorsement whose issuer
credential digest equals the operator credential digest for the target's
chain is not a conforming rpr-1 endorsement, whatever else it may be as an
ordinary same-party claim. Distinctness is not independence: a colluding pair
can fabricate an endorsement, affirmative or negative, without any run having
occurred — the endorsement is evidence of a committed claim, never proof that
a re-execution happened (RPR-4 disclosed limit).

What a verified endorsement asserts is exactly: this endorser claimed, at a
committed moment, that the target was re-run and its output did or did not
match the target's committed output within the named tolerance — and nothing
else. No claim of correctness, validity, fitness, or significance (RPR-1,
MPR-6); absence of any endorsement proves nothing (MPR-9 non-production).

## 4. Retraction (RPR-5)

A mistaken endorsement is withdrawn by the map-1 §3 `retraction` unchanged:
same issuer, unambiguous target, appended. A retracted endorsement still
stands as a committed record that the verdict was once claimed and later
taken back; nothing is unsaid by deletion and no anchored commitment's
coverage is subtracted (AHM-4).

## 5. Verification procedure and trust base

All rpr-1 verification needs only: the artifacts named above, this
definition, the map-1 definition (for credentials, signatures, types, and
retraction), and authentic views of the logs/chains the artifacts reference.
No registry, no network, no operator cooperation for verification —
production of artifacts remains the endorser's act (MPR-4 asymmetry).
