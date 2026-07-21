# map-1 — KairosChain Mutual Anchoring Convention, version 1

Status: committed verification convention (MAP-1..4 of
aud_l2_mutual_anchoring_design_v0.5, FROZEN). The SHA-256 over this file's raw
bytes is the convention integrity digest; every artifact that names `map-1`
commits it as `convention_sha256`. A verifier holding a definition whose
digest does not match the committed one MUST treat the artifact's convention
as unresolvable and refuse to verify under it. Any change to this convention
is a new identifier (`map-2`, ...); this file is never edited in place.
map-1 builds on khab-1 (head bindings, cumulative commitments, proofs) and
does not modify it: a khab-1 binding is valid with or without any map-1
artifact present.

## 1. Chain identity credential (MAP-2)

A credential is a JSON object with exactly these fields:

| field | type | class |
|---|---|---|
| `format` | `"map-1/credential"` | verifiable (this document) |
| `convention_sha256` | 64-hex | verifiable (digest of this document) |
| `chain_identity` | `block1-sha256:<64-hex>` (khab-1 §5) | committed identifier |
| `algorithm` | `"ed25519"` | verifiable |
| `public_key` | 64-hex (32 raw bytes) | verifiable (key material) |
| `binding_sig` | 128-hex (64 raw bytes) | verifiable (self-signature) |

`binding_sig` is the Ed25519 signature, under `public_key`, over the UTF-8
bytes of the binding string:

    map-1/credential|<chain_identity>|<public_key>

A valid `binding_sig` proves that the holder of the private key asserts the
binding to the named chain identity — it is a SELF-attestation. That the
credential actually speaks for the chain is established only by the chain
committing the credential digest as one of its own records (§2); a verifier
without chain access treats the binding as claimed, not proven, exactly as
khab-1 §5 treats `chain_identity` itself.

The credential digest is the SHA-256 of the credential's canonical JSON
(keys sorted recursively, `JSON.generate` compact form).

### 1.1 Attestation signatures

An attestation payload is signed as the Ed25519 signature over the UTF-8
bytes of:

    map-1/attestation|<credential digest>|<payload sha256 hex>

Verification requires only the credential, the payload, and the signature
(MAP-2 self-authentication: no registry, no network). The MPR-4 trust base
carries over: the verifier still needs an authentic view of whatever log or
chain the payload claims membership in.

## 2. Credential commitment record

A chain adopts a credential by committing the record string:

    {"credential_digest":"<64-hex>","format":"map-1/credential-commitment"}

(canonical JSON: keys sorted recursively, compact form — all record literals
in this document are shown in canonical serialization) as an ordinary
internal-chain record. Committed position provides decidable anteriority
(MPR-8) for everything later signed under the credential.

## 3. Attestation types (MAP-4)

Every map-1-conforming attestation entry carries `attestation_type`, one of
the normative vocabulary below. Absence of the field marks a pre-map-1 entry:
grandfathered, valid, untyped (MAP-4 quantifies over entries PRESENTED as
conforming). The declaration is the issuer's claim of evidential role, not
self-certifying.

| type | outcome axis | issuance axis | forced by |
|---|---|---|---|
| `observation` | outcome-blind | automated | MAP-1 (head inscriptions) |
| `quality-endorsement` | outcome-aware | judgment-gated | MAP-3 boundary |
| `succession-designation` | outcome-blind | judgment-gated | MAP-2 |
| `retraction` | outcome-aware | judgment-gated | append-only substrate |

- A head inscription (khab-1 §6 head anchor, or a foreign deposit carrying a
  partner's head binding) carries `observation`.
- An anchor-log `retraction` entry identifies its target unambiguously via
  `metadata.target_entry_hash` (the target's `entry_hash`) — that is the ONLY
  target form an anchor-log retraction carries; taking back an
  internal-chain record is the internal-chain retraction record's business
  (§4), never an anchor-log entry's. A retraction is valid only from the
  same issuer as its target. At map-1, the
  issuer of an anchor-log entry is its committed `depositor`: a retraction is
  coherent only if its depositor equals the target's depositor. For
  internal-chain succession records, issuer identity is credential-level
  (§4, signature-enforced). Credential-level binding of anchor-log entries is
  deferred to a later convention (design §11). A retraction withdraws the
  claim and never removes the entry nor subtracts from any anchored
  commitment's coverage. Retraction of a retraction is not recognized: a
  retracted claim stays retracted.
- `retraction` (map-1) is distinct from `withdrawal` (ANC-5): withdrawal
  governs anchor-log availability; retraction withdraws an evidential claim.

## 4. Succession records (MAP-2)

Succession artifacts are internal-chain record strings on the OLD chain, in
canonical JSON. A record is valid only in its canonical serialization with
exactly the fields shown — a non-canonical or extra-field record is not a
succession artifact and is ignored as noise:

designation:

    {"designation_sig":"<128-hex>","format":"map-1/succession-designation",
     "successor_credential_digest":"<64-hex>","successor_identity":"block1-sha256:<64-hex>"}

`designation_sig` is the Ed25519 signature, under the old chain's credential,
over the UTF-8 bytes of:

    map-1/succession-designation|<old credential digest>|<successor_identity>|<successor_credential_digest>

designation retraction:

    {"format":"map-1/succession-retraction","retraction_sig":"<128-hex>",
     "target_record_sha256":"<64-hex>"}

`retraction_sig` is the signature, under the SAME old-chain credential, over:

    map-1/succession-retraction|<old credential digest>|<target_record_sha256>

where `target_record_sha256` is the SHA-256 of the designation record string.

### 4.1 Governance evaluation

Given the old chain's ordered records, its credential, and optionally the
committed position of the changeover event, governance is computed by a
single scan in committed order:

1. Collect designations and retractions whose signatures verify under the
   old credential; unverifiable records are ignored as noise (not errors).
2. A designation is retracted iff a valid retraction targeting its record
   digest appears at a later committed position, at or before the changeover
   position when one is supplied. Retracted stays retracted.
3. The earliest non-retracted designation governs.
4. The changeover event is the successor chain's first extension act that
   commits the governing designation's record digest (this also covers a
   dead old chain: the event lives on the successor's side). Old-credential
   designations and retractions at committed positions after the changeover
   never alter governance and are reported as `contested`.
5. No designations → `orphan` (arithmetically verifiable, nobody entitled to
   extend). All designations retracted → `orphan` likewise.

The verdict is `governed` (with the governing successor), `orphan`, and a
possibly empty `contested` list. The contested list is one register: it
carries post-changeover acts, later non-retracted competitors, AND every
retracted designation (the retract-and-redesignate trail), so no path to a
governing successor is silent. Key compromise is indistinguishable from
the issuer by construction (MAP-2 disclosed limit); the scan reports what the
records show, never intent.

## 5. Declared anchoring rule (MAP-3)

A rule artifact is canonical JSON with exactly:

    {"format":"map-1/anchoring-rule","n":<positive int>,"trigger":"<trigger>"}

`trigger` is one of `every_n_records` | `every_n_days`. The schema is closed:
no other fields exist, so no outcome-referencing field can be expressed —
result-freedom holds by construction. A rule is valid only in its canonical
serialization, so one rule has exactly one digest. The rule is committed by
recording

    {"format":"map-1/rule-commitment","rule_digest":"<64-hex>"}

on the internal chain; committed position gives decidable anteriority to all
later anchors the rule governs.

Coverage: for `every_n_records`, with chain extent E records and the rule
committed at record position P, an anchor with a khab-1 head binding is
expected at every tree_size threshold P + k*n (k >= 1) <= E; for
`every_n_days`, expected at every n-day boundary after the rule's committed
moment, judged against binding-carrying anchor moments. The coverage report
lists expected points, matched anchors, and gaps. A sparse or vacuous rule
conforms; the report makes its cost visible (MPR-7 windows widen). Coverage
is assessed, never enforced: the checker reports, the reader prices.

## 6. Mutual anchor pair (MAP-1)

A mutual-anchor pair report over two anchor-log views A and B establishes
exactly: A's log contains an entry committing B's head binding, and B's log
contains an entry committing A's head binding, each at a committed position
under its log's hash chain. Everything stronger is conditional and the
report carries the conditions verbatim: partner independence is
auditor-supplied (a common operator can fabricate the pair); temporal weight
reaches only as far as each log's own khab-1 anchoring; equivocation
detection requires authentic views of both logs and actual cross-comparison.
The pair supplies split-view detection material; it closes nothing.

## 7. Verification procedure and trust base

All map-1 verification needs only: the artifacts named above, this
definition, and authentic views of the logs/chains the artifacts reference.
No registry, no network, no operator cooperation for verification —
production of artifacts remains the operator's act (MPR-4 asymmetry).
