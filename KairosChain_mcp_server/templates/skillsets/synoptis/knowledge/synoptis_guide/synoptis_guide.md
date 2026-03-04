---
name: synoptis_guide
description: "Synoptis SkillSet user guide — mutual attestation tools and workflows"
version: "1.0"
layer: L1
tags: [synoptis, attestation, trust, user-guide, skillset]
---

# Synoptis SkillSet — User Guide

## Overview

Synoptis is a mutual attestation SkillSet for KairosChain that enables agents to verify each other's claims through cryptographically signed proofs. It provides:

- **Mutual Attestation**: Agents issue and verify signed proofs about each other's capabilities, outputs, and compliance
- **Trust Scoring**: Composite trust metric combining quality, freshness, diversity, and anomaly detection
- **Challenge Protocol**: Dispute resolution for contested attestations
- **Selective Disclosure**: Evidence can be fully disclosed or existence-only (Merkle proof)

In the KairosChain architecture, Synoptis operates at L1 (knowledge/governance layer), providing the trust infrastructure that enables autonomous agents to evaluate each other without centralized authority.

## Quick Start

### 1. Enable Synoptis

In your KairosChain instance's `config/synoptis.yml`:

```yaml
enabled: true
```

Or install via SkillSet manager:

```
"Install the synoptis SkillSet"
```

### 2. Verify Installation

```
"Run attestation_list"
```

If the tool is available and returns an empty list, Synoptis is active.

## Tools Reference

Synoptis provides 8 MCP tools:

### attestation_request — Request an Attestation

Send an attestation request to a peer agent.

```
"Request attestation from agent-B for pipeline fastqc_v1 with claim type PIPELINE_EXECUTION"
```

JSON-RPC:
```json
{
  "jsonrpc": "2.0", "id": 1,
  "method": "tools/call",
  "params": {
    "name": "attestation_request",
    "arguments": {
      "target_agent": "agent-B",
      "claim_type": "PIPELINE_EXECUTION",
      "subject_ref": "skill:fastqc_v1",
      "disclosure_level": "existence_only"
    }
  }
}
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `target_agent` | Yes | Agent ID of the peer |
| `claim_type` | Yes | One of 7 claim types (see below) |
| `subject_ref` | Yes | Reference to the subject being attested |
| `disclosure_level` | No | `existence_only` (default) or `full` |

Returns: `request_id`, `nonce`, and delivery status.

### attestation_issue — Issue a Signed Attestation

Build, sign, and deliver a ProofEnvelope.

```
"Issue attestation for agent-B, claim type PIPELINE_EXECUTION, subject skill:fastqc_v1, evidence {\"output_hash\":\"abc123\",\"runtime_sec\":42}"
```

JSON-RPC:
```json
{
  "jsonrpc": "2.0", "id": 2,
  "method": "tools/call",
  "params": {
    "name": "attestation_issue",
    "arguments": {
      "target_agent": "agent-B",
      "claim_type": "PIPELINE_EXECUTION",
      "subject_ref": "skill:fastqc_v1",
      "evidence": "{\"output_hash\":\"abc123\",\"runtime_sec\":42}",
      "request_id": "req_...",
      "disclosure_level": "full",
      "expires_in_days": 90
    }
  }
}
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `target_agent` | Yes | Attestee agent ID |
| `claim_type` | Yes | Claim type |
| `subject_ref` | Yes | Subject reference |
| `evidence` | Yes | JSON string of evidence data |
| `request_id` | No | Links to a prior attestation_request (binds nonce) |
| `disclosure_level` | No | `existence_only` (default) or `full` |
| `expires_in_days` | No | Override default 180-day expiry |

Returns: `proof_id`, `status`, `issued_at`, `expires_at`, signature presence, delivery status.

### attestation_verify — Verify a Proof

Verify a serialized ProofEnvelope through up to 6 verification stages.

```
"Verify this attestation proof: {proof JSON}"
```

JSON-RPC:
```json
{
  "jsonrpc": "2.0", "id": 3,
  "method": "tools/call",
  "params": {
    "name": "attestation_verify",
    "arguments": {
      "proof_payload": "{...serialized proof...}",
      "mode": "full",
      "public_key_pem": "-----BEGIN PUBLIC KEY-----\n..."
    }
  }
}
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `proof_payload` | Yes | Serialized ProofEnvelope (JSON string) |
| `mode` | No | `full` (default, all 6 stages) or `signature_only` |
| `public_key_pem` | No | PEM public key for signature verification |

Verification stages (full mode):
1. Signature verification (RSA-SHA256)
2. Evidence hash verification
3. Revocation check
4. Expiry check
5. Merkle proof verification
6. Claim type validation

### attestation_revoke — Revoke an Attestation

```
"Revoke attestation att_abc123 because evidence was found to be inaccurate"
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `proof_id` | Yes | ID of the proof to revoke |
| `reason` | Yes | Reason for revocation |

Returns: `revocation_id`, `revoked_by`, `revoked_at`. Sends best-effort notification to attestee.

### attestation_list — List Attestations

```
"List all active attestations for agent-B with claim type PIPELINE_EXECUTION"
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `agent_id` | No | Filter by attester or attestee |
| `claim_type` | No | Filter by claim type |
| `status` | No | `active`, `revoked`, or `expired` |

Returns: `total_count`, `filters`, and `proofs[]` array with summary fields.

### attestation_challenge_open — Open a Challenge

Dispute an active attestation.

```
"Challenge attestation att_abc123 because output hash does not match re-execution"
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `proof_id` | Yes | Proof to challenge |
| `reason` | Yes | Reason for the challenge |
| `evidence` | No | Supporting evidence (JSON string, stored as sha256 hash) |

Returns: `challenge_id`, `status: 'open'`, `deadline_at` (default 72h). Notifies attester.

### attestation_challenge_resolve — Resolve a Challenge

```
"Resolve challenge chl_xyz789 with decision uphold, response 'Re-execution confirmed original result'"
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `challenge_id` | Yes | Challenge to resolve |
| `decision` | Yes | `uphold` (proof stays active) or `invalidate` (proof revoked) |
| `response` | No | Explanatory text |

Returns: resolution status, decision, timestamps. Notifies both parties.

### trust_score_get — Get Trust Score

```
"Get trust score for agent-B"
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `agent_id` | Yes | Agent to evaluate |
| `window_days` | No | Lookback window (default: 180) |

Returns:
- `score`: 0.0–1.0 composite trust score
- `breakdown`: quality, freshness, diversity, revocation_penalty, velocity_penalty
- `graph_metrics`: cluster_coefficient, external_connection_ratio, velocity_24h
- `anomaly_flags`: list of detected anomalies
- `attestation_count`: number of attestations in the window

## Workflow Examples

### Pattern 1: Pipeline Attestation — Issue and Verify

A typical flow where Agent A runs a pipeline and Agent B verifies the result:

```
# Step 1: Agent B requests attestation from Agent A
"Request attestation from agent-A for skill:rnaseq_pipeline claim type PIPELINE_EXECUTION"

# Step 2: Agent A issues the attestation with evidence
"Issue attestation for agent-B, claim type PIPELINE_EXECUTION,
 subject skill:rnaseq_pipeline,
 evidence {\"output_hash\":\"sha256:abc...\",\"sample_count\":12,\"runtime_sec\":3600}"

# Step 3: Agent B verifies the received proof
"Verify this attestation proof: {received proof JSON}"

# Step 4: Check trust score
"Get trust score for agent-A"
```

### Pattern 2: Challenging a Fraudulent Attestation

When an agent discovers an attestation is incorrect:

```
# Step 1: Agent C finds a suspicious attestation
"List attestations for agent-X with claim type GENOMICS_QC"

# Step 2: Open a challenge with evidence
"Challenge attestation att_suspicious123,
 reason: 'QC metrics do not match re-analysis',
 evidence: {\"reanalysis_hash\":\"sha256:def...\",\"discrepancy\":\"fastqc scores differ by >20%\"}"

# Step 3: Wait for resolution (72h deadline)
# The attester or a resolver can respond:
"Resolve challenge chl_abc with decision invalidate,
 response: 'Confirmed — original analysis used corrupted input file'"

# Result: The attestation is automatically revoked
```

### Pattern 3: Trust Evaluation Before Collaboration

Before relying on another agent's output:

```
# Check trust score with breakdown
"Get trust score for agent-candidate"

# Interpret the result:
# - score > 0.7: Generally trustworthy
# - score 0.4-0.7: Moderate trust, verify key claims
# - score < 0.4: Low trust, require full verification
# - anomaly_flags present: Investigate before proceeding
```

## Claim Types

| Claim Type | Weight | Use When |
|------------|--------|----------|
| `PIPELINE_EXECUTION` | 1.0 | Verifying a pipeline/skill re-execution for reproducibility |
| `GENOMICS_QC` | 0.8 | Genomics data quality control (GenomicsChain-specific) |
| `DATA_INTEGRITY` | 0.7 | Verifying chain-wide data integrity |
| `SKILL_QUALITY` | 0.6 | Confirming a skill's behavior and output quality |
| `L0_COMPLIANCE` | 0.5 | Verifying framework (L0) rule compliance |
| `L1_GOVERNANCE` | 0.4 | Verifying governance/knowledge correctness |
| `OBSERVATION_CONFIRM` | 0.2 | Simply confirming an observation (lowest weight) |

Higher-weight claim types contribute more to the trust score's quality component.

### Disclosure Levels

| Level | When to Use |
|-------|------------|
| `existence_only` | Default. Proves the attestation exists without revealing evidence. Uses Merkle root + proof path. |
| `full` | When the verifier needs access to the actual evidence data. |

## Transport Overview

Synoptis delivers attestation messages through three transport mechanisms, tried in priority order:

1. **MMP** (Model Meeting Protocol): P2P delivery via KairosChain's meeting system. Used when both agents are connected via MMP.
2. **Hestia**: Discovery via Hestia agent registry, delivery via MMP. Used when target is registered in a Hestia network.
3. **Local**: Intra-instance delivery via multiuser tenant manager. Used for agents on the same KairosChain instance.

Transport priority is configurable in `config/synoptis.yml`:
```yaml
transport:
  priority: [mmp, hestia, local]
```

If all transports fail, the operation still succeeds locally (the proof is saved to the registry) but delivery is marked as failed.

## Security Considerations

1. **Self-Attestation**: Disabled by default (`allow_self_attestation: false`). An agent cannot attest itself.
2. **Velocity Limits**: More than 10 attestations in 24h triggers anomaly flags and trust score penalties.
3. **Challenge Limits**: Each agent can have at most 5 open challenges simultaneously, preventing challenge flooding.
4. **Signature Verification**: All proofs are signed with RSA-SHA256. Without the attester's public key, signature verification is skipped but noted in `trust_hints`.
5. **Evidence Integrity**: Evidence is hashed (sha256) and the hash is included in the signed payload. Tampering with evidence after signing is detectable.
6. **Expiry**: Proofs expire after 180 days by default. Expired proofs fail verification in full mode.
7. **Selective Disclosure**: In `existence_only` mode, evidence is not included in the envelope — only its hash and Merkle proof. This allows proving facts without revealing underlying data.
