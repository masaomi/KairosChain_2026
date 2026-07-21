# khab-1 — KairosChain Head-Anchor Binding and Proof Convention, version 1

Status: committed verification convention (MPR-3 of
auditability_head_anchor_design_v0.3). The SHA-256 over this file's raw bytes
is the convention integrity digest, committed as `convention_sha256` inside
every head binding that names `khab-1`. A verifier holding a definition whose
digest does not match the committed one MUST treat the binding's convention as
unresolvable and refuse to verify under it. Any change to this convention is a
new identifier (`khab-2`, ...); this file is never edited in place.

## 1. Record commitment (leaf)

The internal chain is an ordered list of blocks; each block carries an ordered
list of records (strings). The anchored sequence is the concatenation of all
records of all blocks in block order, then record order within each block,
starting at the genesis block. The record commitment of a record is the
SHA-256 digest of the record string's raw bytes, in lowercase hexadecimal.
Record content never appears in any anchored structure or proof.

## 2. Cumulative commitment (tree)

The anchored cumulative commitment is the RFC 6962 Merkle tree hash over the
sequence of record commitments, where each leaf input is the 32 raw bytes
decoded from the record commitment hex:

- leaf hash:     `SHA-256(0x00 || leaf_bytes)`
- interior hash: `SHA-256(0x01 || left || right)`
- split point: for n > 1 leaves, the left subtree covers the largest power of
  two strictly less than n; the right subtree covers the remainder.
- the empty sequence commits to `SHA-256("")` (never anchored in practice).

The 0x00/0x01 domain prefixes are the role separation required by MPR-3: no
interior node value can verify as a record commitment and vice versa.

## 3. Proofs

An inclusion proof for the record at zero-based position `index` in a tree of
`tree_size` leaves is the RFC 6962 audit path: the sibling hashes from leaf to
root, each 64-char lowercase hex. Verification is RFC 9162 §2.1.3.2 against
`(record_commitment, index, tree_size, path, cumulative_root)`.

A consistency proof between an earlier binding of `first_size` leaves and a
later binding of `second_size` leaves is the RFC 6962 consistency path
(RFC 9162 §2.1.4.1); verification is RFC 9162 §2.1.4.2 against
`(first_root, first_size, second_root, second_size, path)`. The proof for
`first_size == second_size` is empty and valid iff the roots are equal.

Proof artifacts serialize as JSON objects with `format` equal to
`khab-1/inclusion` or `khab-1/consistency` and the fields named above.

## 4. Head binding field layout

A head binding is a JSON object inside the committed body of an anchor entry,
under the key `head_binding`, with exactly these fields:

| field | type | class |
|---|---|---|
| `convention` | `"khab-1"` | verifiable (this document) |
| `convention_sha256` | 64-hex | verifiable (digest of this document) |
| `chain_identity` | string, see §5 | committed identifier |
| `cumulative_root` | 64-hex | verifiable (§2 recomputation / §3 proofs) |
| `tree_size` | positive integer | verifiable (committed extent, MPR-8) |
| `chain_head_index` | non-negative integer | informational |
| `chain_head_hash` | 64-hex | informational |

Verifiable components are those the auditor can check with the MPR-4 trust
base (proofs + published bindings + authentic anchor-log view + this
definition), without internal-chain access. `chain_head_index` /
`chain_head_hash` describe the internal chain's native head block at anchor
time; they are recomputable only with chain access and are presented as
informational, never as proven (MPR-1 coherence clause).

## 5. Chain identity

The committed chain identity is the string `block1-sha256:` followed by the
native hash of the internal chain's block at index 1 (the first block after
genesis), in lowercase hex. It is content-derived and stable for the life of
the chain; it exists so that MPR-9's extension predicate quantifies over an
auditor-decidable committed identifier. Equality of two committed identities
is decidable from the anchor log alone; that the identity matches the chain's
actual block 1 is checkable only with chain access and is in that respect
informational. A binding committing a different `chain_identity` than a prior
binding terminates the extension claim across the change (MPR-9).

## 6. Head anchors

An anchor entry whose `anchor_type` is `chain_head` is a dedicated head
anchor: its entry `digest` field equals the binding's `cumulative_root`, and
the entry-level `canonicalization` self-description is superseded for this
type by §1–§2 of this convention (the "artifact" is the record-commitment
sequence, not a file). Any newly appended anchor entry of any type MAY carry a
`head_binding`; entries without one are ordinary anchor entries, and absence
of a binding is a statement of provenance, not a defect.

## 7. Verification procedure and trust base

To verify a claim "record R is member #index of the chain state anchored at
entry E":

1. Obtain an authentic view of the anchor log; check E's committed body and
   the log's hash chain.
2. Resolve `convention` / `convention_sha256` against this definition.
3. Verify the inclusion proof per §3 against E's `cumulative_root` and
   `tree_size`.
4. Order between two proven records is arithmetic on their committed
   positions within a common anchored state, or across anchors via a verified
   consistency proof between bindings committing the same `chain_identity`.

The proof binds a record COMMITMENT, not content: linking it to actual
content requires holding that content and recomputing §1. A verified proof
asserts membership, integrity at anchor time, position, and order — nothing
about quality, correctness, or completeness of anchoring (MPR-5/6).
