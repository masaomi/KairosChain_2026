---
name: synoptis_attestation
description: "Synoptis Mutual Attestation — cross-agent trust verification through cryptographic proof envelopes"
version: 1.0
layer: L1
tags: [documentation, readme, synoptis, attestation, trust, p2p, audit, challenge]
readme_order: 4.7
readme_lang: en
---

## Synoptis: Mutual Attestation Protocol (v2.7.0)

### What is Synoptis?

Synoptis is an opt-in SkillSet for cross-agent trust verification through cryptographically signed attestation proofs. It enables agents to attest to facts about any subject (knowledge entries, skill hashes, chain blocks, pipeline outputs, etc.), and provides mechanisms to verify, revoke, and challenge those attestations.

Synoptis is implemented entirely as a SkillSet, preserving KairosChain's principle that new capabilities are expressed as SkillSets rather than core modifications.

### Architecture

```
KairosChain (MCP Server)
├── [core] L0/L1/L2 + private blockchain
├── [SkillSet: mmp] P2P direct mode, /meeting/v1/*
├── [SkillSet: hestia] Meeting Place + trust anchor
└── [SkillSet: synoptis] Mutual attestation protocol
      ├── ProofEnvelope       ← Signed attestation data structure
      ├── Verifier            ← Structural + cryptographic verification
      ├── AttestationEngine   ← Attestation lifecycle (create, verify, list)
      ├── RevocationManager   ← Revocation with authorization checks
      ├── ChallengeManager    ← Challenge/response lifecycle
      ├── TrustScorer         ← Weighted trust score calculation
      ├── Registry::FileRegistry ← Append-only JSONL with hash-chain integrity
      ├── Transport            ← MMP / Hestia / Local transport abstraction
      └── tools/               ← 7 MCP tools
```

### Quick Start

#### 1. Install the synoptis SkillSet

```bash
# Synoptis depends on MMP. Install both:
kairos-chain skillset install templates/skillsets/mmp
kairos-chain skillset install templates/skillsets/synoptis
```

#### 2. Issue an attestation

In Claude Code / Cursor:

```
"Attest that knowledge/my_skill has been integrity_verified"
```

This calls `attestation_issue(subject_ref: "knowledge/my_skill", claim: "integrity_verified")`.

#### 3. Verify and query trust

```
"What is the trust score for knowledge/my_skill?"
```

This calls `trust_query(subject_ref: "knowledge/my_skill")`.

### MCP Tools

| Tool | Description |
|------|-------------|
| `attestation_issue` | Issue a signed attestation proof for a subject |
| `attestation_verify` | Verify proof validity (structure, signature, expiry, revocation) |
| `attestation_revoke` | Revoke an attestation (original attester or admin only) |
| `attestation_list` | List attestations with optional filters (subject_ref, attester_id) |
| `trust_query` | Calculate trust score based on attestation history |
| `challenge_create` | Challenge an existing attestation (validity, evidence_request, re_verification) |
| `challenge_respond` | Respond to a challenge with additional evidence |

### MMP Integration

Synoptis registers 5 MMP actions via `MMP::Protocol.register_handler`, enabling P2P attestation exchange:

| MMP Action | Description |
|------------|-------------|
| `attestation_request` | Request an attestation from a peer |
| `attestation_response` | Respond with a signed ProofEnvelope |
| `attestation_revoke` | Broadcast a revocation |
| `challenge_create` | Send a challenge to the original attester |
| `challenge_respond` | Respond to a challenge over MMP |

All P2P messages use Bearer token authentication via `MMP::PeerManager`. The authenticated peer ID is injected by `MeetingRouter` as `_authenticated_peer_id`.

### Trust Scoring

Trust scores are calculated as a weighted composite:

| Factor | Weight | Description |
|--------|--------|-------------|
| Quality | 0.30 | Ratio of valid (non-revoked, non-expired) attestations |
| Freshness | 0.25 | Recency of latest attestation (exponential decay, 24h half-life) |
| Diversity | 0.25 | Number of unique attesters (capped at 5) |
| Velocity | 0.10 | Attestation rate in the last 7 days |
| Revocation penalty | −0.10 | Penalty for revoked attestations |

### Registry and Constitutive Recording

All attestation data is stored in append-only JSONL files with hash-chain linking (`_prev_entry_hash`). This implements constitutive recording (Proposition 5): each record irreversibly extends the system's history.

Registry types:
- `proofs.jsonl` — Attestation proof envelopes
- `revocations.jsonl` — Revocation records
- `challenges.jsonl` — Challenge and response records

Use `trust_query` to verify registry integrity — it includes a `registry_integrity.valid` field in its response.

### ProofEnvelope Structure

```json
{
  "proof_id": "uuid",
  "attester_id": "agent_instance_id",
  "subject_ref": "knowledge/my_skill",
  "claim": "integrity_verified",
  "evidence": "manual review of hash chain",
  "merkle_root": "sha256_of_content",
  "content_hash": "sha256_of_canonical_json",
  "signature": "rsa_sha256_signature",
  "timestamp": "2026-03-06T12:00:00Z",
  "ttl": 86400,
  "version": "1.0.0"
}
```

### Challenge Workflow

1. Any agent can call `challenge_create(proof_id, challenge_type, details)` to challenge an attestation
2. The original attester receives the challenge (via MMP or local notification)
3. The attester calls `challenge_respond(challenge_id, response, evidence)` with additional evidence
4. Challenge types: `validity` (proof may be incorrect), `evidence_request` (more evidence needed), `re_verification` (conditions may have changed)

### Transport Layer

Synoptis supports multiple transport mechanisms:

| Transport | Backend | Use Case |
|-----------|---------|----------|
| MMP | `MMP::PeerManager` | P2P direct attestation exchange |
| Hestia | `Hestia::PlaceRouter` | Via Meeting Place (future) |
| Local | Direct registry access | Single-instance and Multiuser mode |

Transport selection is automatic based on available SkillSets.

### Dependencies

- **Required**: MMP SkillSet (>= 1.0.0)
- **Optional**: Hestia SkillSet (for Meeting Place transport)

For the full protocol specification, install the synoptis SkillSet and refer to its bundled knowledge (`synoptis_protocol`).
