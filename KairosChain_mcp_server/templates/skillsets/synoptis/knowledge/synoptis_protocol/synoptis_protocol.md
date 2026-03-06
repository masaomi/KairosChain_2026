---
name: synoptis_attestation_protocol
version: "1.0.0"
actions:
  - attestation_request
  - attestation_response
  - attestation_revoke
  - challenge_create
  - challenge_respond
tags:
  - synoptis
  - attestation
  - trust
  - audit
---

# Synoptis Mutual Attestation Protocol

## Overview

Synoptis is an opt-in SkillSet for KairosChain that provides mutual attestation
between agents. It enables cross-agent trust verification through cryptographically
signed proof envelopes, stored in append-only registries with hash-chain integrity.

## MMP Actions

### attestation_request

Sent to request an attestation from a peer agent.

**Payload:**
- `subject_ref` (string): Reference to the subject being attested
- `claim` (string): The type of attestation requested
- `evidence_hints` (array, optional): Hints about what evidence to examine

### attestation_response

Sent in response to an attestation request, containing the signed proof envelope.

**Payload:**
- ProofEnvelope fields (proof_id, attester_id, subject_ref, claim, evidence, merkle_root, signature, timestamp, ttl)

### attestation_revoke

Broadcast when an attestation is revoked.

**Payload:**
- `proof_id` (string): The revoked proof ID
- `revoker_id` (string): Who revoked it
- `reason` (string): Reason for revocation

### challenge_create

Sent to challenge an existing attestation.

**Payload:**
- `challenge_id` (string): Unique challenge identifier
- `proof_id` (string): The challenged proof
- `challenge_type` (string): validity | evidence_request | re_verification
- `details` (string, optional): Challenge details

### challenge_respond

Sent by the original attester in response to a challenge.

**Payload:**
- `challenge_id` (string): The challenge being responded to
- `response` (string): Response text
- `evidence` (string, optional): Additional evidence

## Transport

Messages are delivered via MMP PeerManager with Bearer token authentication.
Handlers are registered via `MMP::Protocol.register_handler` during `Synoptis.load!`.

## Registry

All attestation data is stored in append-only JSONL files with hash-chain linking
(`_prev_entry_hash`), implementing constitutive recording (Proposition 5).

## Trust Scoring

Trust scores are calculated from: quality (0.3), freshness (0.25), diversity (0.25),
velocity (0.1), minus revocation penalty (0.1).
