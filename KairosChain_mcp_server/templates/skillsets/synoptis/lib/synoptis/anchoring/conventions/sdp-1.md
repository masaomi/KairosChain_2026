# sdp-1 — KairosChain Selective Disclosure Convention, version 1

Status: committed verification convention (SDP-1..5 of
aud_l4_selective_disclosure_design v0.3, FROZEN). The SHA-256 over this file's
raw bytes is the convention integrity digest; every artifact that names
`sdp-1` commits it as its convention reference. A verifier holding a
definition whose digest does not match the committed one MUST treat the
artifact's convention as unresolvable and refuse to verify under it. Any
change to this convention is a new identifier (`sdp-2`, ...); this file is
never edited in place.
sdp-1 builds on khab-1 (record commitments, cumulative commitments, proofs),
map-1 (credentials, §1.1 attestation signatures, types, retraction), and
rpr-1 (endorsement records) and modifies none of them: every khab-1/map-1/
rpr-1 artifact is valid, and verifiable by its own procedure, with or without
any sdp-1 artifact present (SDP-2).

All record literals below are canonical JSON (keys sorted recursively,
`JSON.generate` compact form). A record is valid only in its canonical
serialization with exactly the fields shown — a non-canonical or extra-field
record is not an sdp-1 artifact and is ignored as noise (map-1 §4 precedent).

## 0. Scope and disclosed narrowness

sdp-1 realizes the mechanism family "hash-based salted field-level selective
disclosure": it blinds the *values* of fields of a committed canonical-JSON
record while the record's committed digest, its field *names*, and its field
*count* stay public. It does NOT blind which committed record an assertion
concerns: the AUD-L4 *membership* predicate family (showing that some record
is a member without revealing which) requires a zero-knowledge proving
system and is deliberately outside sdp-1 — a later convention covers it.
This narrowness is disclosed, not hidden (rpr-1 bit-identity precedent).
Because a record's committed digest is revealed, the khab-1 record
commitment IS that digest (khab-1 §1), so khab-1 inclusion and consistency
proofs over the referenced record apply unchanged, and the open-level
selection and currency reads (SDP-3) remain available to the verifier.

## 1. Field commitments (SDP-2 auxiliary, checkably bound)

    {"fields":{"<name>":"<64-hex>",...},"format":"sdp-1/field-commitments",
     "record_sha256":"<64-hex>"}

`record_sha256` is the SHA-256 of the target record string (= its khab-1
record commitment). `fields` carries one entry per top-level field of the
target record — coverage is total, so the auxiliary determines exactly one
record shape and an omitted field cannot be hidden by omission. Field names
match `[a-z0-9_]+`. Each field digest is the SHA-256 of the UTF-8 bytes of:

    sdp-1/field|<salt>|<name>|<canonical JSON of the value>

where `<salt>` is 32-char lowercase hex (16 random bytes, fresh per field
per auxiliary). The `sdp-1/field` domain prefix is role separation (MPR-3
register): a field digest cannot verify as a record commitment or vice
versa. The auxiliary is committed as an ordinary internal-chain record
alongside its target; both records' membership and order are khab-1's
business, unchanged.

Checkable binding (SDP-2): a holder of the target record and the salts can
recompute `record_sha256` and every field digest; the auxiliary commits the
same content the record commits, or the recomputation fails. An auxiliary
whose digests do not recompute is not a conforming sdp-1 artifact. Residue
disclosed: binding checkability is available to holders of the record and
salts (the producer, and anyone the producer opens to); a third party holds
the binding as committed material whose consistency is attested by the
recomputations of others — the MPR-4 production/verification asymmetry.

## 2. Disclosure profile (SDP-4, closed schema)

    {"currency":"scan-checkable","format":"sdp-1/profile",
     "opened":["format","verdict"],"predicate":"claimed-verdict"}

`predicate` is one of `typed-existence` | `claimed-verdict` |
`conforming-verdict`. `currency` is one of `scan-checkable` |
`unestablished` (SDP-3: which currency reading the presentation supports is
declared, never implied). `opened` is the sorted, duplicate-free list of
opened field names and MUST include `format` (the record's format field is
always opened, so the closed schema of the referenced record kind is
readable and coverage is checkable against it). The schema is closed: no
other fields exist, so a profile cannot carry producer gloss — a profile
means what this section says a profile of its form means (SDP-4 pinning),
and a presentation's profile is checked against its actual opened set, so a
profile that overstates or understates what is opened fails verification
(statement-determining, SDP-4).

What every sdp-1 profile discloses by construction (SDP-3): the proof shows
the named predicate over the named committed record and withholds the values
of every field not listed in `opened`; it shows nothing about other records,
contrary verdicts, or the producer's selection among presentable records.

## 3. Presentation (offline artifact, never committed)

base fields, always present:

    {"aux_record":"<field-commitments record string>",
     "format":"sdp-1/presentation",
     "opened":{"<name>":{"salt":"<32-hex>","value":<JSON value>},...},
     "profile":{...profile object...}}

additionally, exactly when `profile.predicate` is `claimed-verdict` or
`conforming-verdict`: `"credential"` (the endorser's map-1 credential
object) and `"signature"` (128-hex, the map-1 §1.1 attestation signature
over the referenced endorsement record). Additionally, exactly when
`profile.currency` is `scan-checkable`: `"carrier_entry_hash"` (64-hex, the
anchor-log entry that carried the referenced record's attestation — the
producer's disclosure that makes the retraction scan runnable). The schema
is closed per shape (rpr-1 per-mode precedent).

`opened` keys must equal `profile.opened` exactly. Each opened field
verifies by recomputing §1's field digest from `salt`, the name, and the
canonical JSON of `value` against the auxiliary's committed digest.

## 4. Predicates (SDP-1 bounds)

- `typed-existence`: a committed record of the opened `format` exists with
  digest `record_sha256`. Membership in an anchored state is shown, when
  wanted, by a khab-1 inclusion proof over `record_sha256` — unchanged, not
  part of the presentation.
- `claimed-verdict`: the opened `format` must be `rpr-1/endorsement` and
  `verdict` must be opened. The signature verifies under the presented
  credential over the signing string

      map-1/attestation|<credential digest>|<record_sha256>

  which requires NO record content (map-1 §1.1 commits the payload by
  digest). The claim is exactly: this credential's holder claimed this
  verdict in this committed endorsement — the weaker predicate under its
  own name (SDP-1 face/substance rule). No foreignness, anteriority, or
  conformance is asserted.
- `conforming-verdict`: `claimed-verdict`, and additionally
  `adjudication_mode`, `target_sha256`, and `tolerance_sha256` are opened
  (plus `procedure_sha256` exactly when the opened mode is `procedure`),
  and verification REQUIRES the operator credential (foreignness: endorser
  credential digest ≠ operator credential digest, rpr-1 §3) and the rpr-1
  §2.1 declaration-set material (targets, declarations with positions, the
  endorsement's committed position); the invoked tolerance must assess as
  conforming, and it must be bound to the endorsement's opened target or to
  a sibling target sharing its committed computation identification (the
  rpr-1 §2.1 pooling rule: a sibling menu is one menu; a tolerance bound to
  an unrelated computation fails), decided from the supplied target records.
  Where the material is not supplied, or the coherence is undecidable in the
  supplied view, verification fails — refuse, not degrade (SDP-1 upward
  bound: the open form's conformance conditions are inside the checked
  predicate, never alongside it).

## 5. Currency scan (SDP-3)

Given a view of anchor-log entries (each with `entry_hash`,
`attestation_type`, `depositor`, `position`, and retraction `metadata`), the
scan reports whether a `retraction` entry from the carrier's own depositor
(map-1 §3 issuer rule) targets `carrier_entry_hash` at a committed position
at or before a named extent. The verdict is `retracted` / `unretracted` up
to that extent, or `unestablished` where the carrier entry — or its
depositor, without which the issuer rule is undecidable — is not in the
supplied view. Duplicate views of one committed entry are one entry.
Same-issuer retractions beyond the extent or without a decidable position,
and non-issuer entries targeting the carrier (which retract nothing), are
disclosed as residue lines, never silently dropped. `unretracted` speaks
only to the scanned view and extent — absence beyond them proves nothing
(MPR-9 register). A profile declaring `currency: "unestablished"` supports
no scan and says so on its face.

## 6. Hiding and soundness base (SDP-1/SDP-5)

Hiding is computational and content-only: a withheld value is hidden exactly
as far as its field's salt is secret and sha256 preimage resistance holds —
16-byte random salts make guess-and-confirm infeasible even for low-entropy
values (the MPR-2 caveat is answered by the salt, and returns in full if a
salt is reused or leaks). What sdp-1 never hides: the record's committed
digest, field names and count, the profile, the producer's credential where
presented, and the fact of presentation itself — a presentation's existence,
timing, and provenance are outside any profile's promise (SDP-1). Soundness
rests on SHA-256 collision resistance and Ed25519 unforgeability only; there
is no setup to trust (SDP-5: transparent, stated rather than implied).

## 7. Verification procedure and trust base

All sdp-1 verification needs only: the artifacts named above, this
definition, the map-1 definition (credentials, signatures, retraction), the
rpr-1 definition (for verdict predicates), and authentic views of the
logs/chains the artifacts reference. No registry, no network, no producer
cooperation for verification — production of presentations, like production
of proofs, remains the producer's act (MPR-4 asymmetry), and the producer's
selection among presentable records is invisible by construction (SDP-3).
