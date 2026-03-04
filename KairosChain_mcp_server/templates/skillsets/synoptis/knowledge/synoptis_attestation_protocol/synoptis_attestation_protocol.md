# Synoptis Attestation Protocol

## Overview

Synoptis (from Greek synoptikos = "seeing the whole together") is the mutual attestation protocol for KairosChain inter-agent trust building.

In KairosChain's private chain context, trust derives not from chain existence but from **who verified what**. Synoptis cryptographically records and verifies this "who".

## Core Concepts

### Proof Envelope
A signed attestation record containing:
- **claim_type**: What is being attested (e.g., PIPELINE_EXECUTION, SKILL_QUALITY)
- **disclosure_level**: How much evidence is revealed (existence_only or full)
- **evidence_hash**: SHA256 hash of the evidence payload
- **signature**: RSA-SHA256 signature over canonical JSON
- **nonce**: Replay protection

### Attestation Flow
1. **Request**: Attester A requests attestation of Attestee B
2. **Evidence**: B provides evidence package
3. **Verification**: A verifies evidence, builds Proof Envelope, signs it
4. **Storage**: Both parties store the signed attestation
5. **Third-party verification**: Any party C can verify the attestation

### Trust Model
- Trust is based on quality and graph structure, not quantity
- Self-attestation is prohibited by default
- Revocation is supported from MVP
- Human judgment remains the final trust anchor (Proposition 9)

## Transports
- **MMP Direct P2P**: Always available (default)
- **Hestia Meeting Place**: Agent discovery + relay (optional)
- **Multiuser Local**: Same-instance DB path (optional)

## Claim Types
| Type | Weight | Description |
|------|--------|-------------|
| PIPELINE_EXECUTION | 1.0 | Re-execution reproducibility |
| GENOMICS_QC | 0.8 | Genomics data QC |
| DATA_INTEGRITY | 0.7 | Chain integrity |
| SKILL_QUALITY | 0.6 | Skill quality check |
| L0_COMPLIANCE | 0.5 | Framework compliance |
| L1_GOVERNANCE | 0.4 | Governance correctness |
| OBSERVATION_CONFIRM | 0.2 | Observation confirmation |

## Security
- RSA-SHA256 signatures via MMP::Crypto
- Nonce + canonical JSON for replay resistance
- Evidence hash mismatch = immediate invalid (no soft-fail)
- Revocation status always checked during verification
