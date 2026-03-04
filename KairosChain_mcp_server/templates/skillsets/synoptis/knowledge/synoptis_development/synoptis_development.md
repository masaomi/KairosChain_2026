---
name: synoptis_development
description: "Synoptis SkillSet developer guide — architecture, extension points, and internals"
version: "1.0"
layer: L1
tags: [synoptis, attestation, developer, architecture, extension]
---

# Synoptis SkillSet — Developer Guide

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                     MCP Tools (8)                       │
│  attestation_request  attestation_issue  attestation_   │
│  attestation_verify   attestation_revoke  _list         │
│  attestation_challenge_open  _challenge_resolve         │
│  trust_score_get                                        │
├─────────────────────────────────────────────────────────┤
│                  AttestationEngine                      │
│  create_request → build_proof → verify_proof → revoke   │
├──────────┬──────────┬──────────┬────────────────────────┤
│ Verifier │ TrustScorer │ ChallengeManager │ RevocationMgr │
│ (6-stage)│ (composite) │ (state machine)  │              │
├──────────┴──────────┴──────────┴────────────────────────┤
│              Core Data Model                            │
│  ProofEnvelope │ MerkleTree │ ClaimTypes                │
├─────────────────────────────────────────────────────────┤
│             Transport Layer                             │
│  Router → [MMPTransport, HestiaTransport, LocalTransport]│
├─────────────────────────────────────────────────────────┤
│              Registry Layer                             │
│  Base (interface) → FileRegistry (JSONL)                │
├─────────────────────────────────────────────────────────┤
│              Hooks                                      │
│  mmp_hooks.rb (MMP protocol integration)                │
└─────────────────────────────────────────────────────────┘
```

## Directory Structure

```
templates/skillsets/synoptis/
├── skillset.json                         # SkillSet metadata (name, version, layer, provides)
├── config/
│   └── synoptis.yml                      # All configurable parameters
├── knowledge/
│   └── synoptis_attestation_protocol/
│       └── synoptis_attestation_protocol.md  # L1 knowledge: protocol specification
├── lib/
│   ├── synoptis.rb                       # Top-level module, autoload hub, load!/config
│   └── synoptis/
│       ├── claim_types.rb                # 7 claim types with weights
│       ├── proof_envelope.rb             # ProofEnvelope data model
│       ├── merkle.rb                     # Binary Merkle tree (SHA-256)
│       ├── verifier.rb                   # 6-stage verification
│       ├── attestation_engine.rb         # Lifecycle orchestrator
│       ├── revocation_manager.rb         # Revocation logic
│       ├── trust_scorer.rb              # Composite trust scoring
│       ├── graph_analyzer.rb            # Graph-based anomaly detection
│       ├── challenge_manager.rb          # Challenge state machine
│       ├── hooks/
│       │   └── mmp_hooks.rb             # MMP protocol action registration
│       ├── registry/
│       │   ├── base.rb                  # Abstract registry interface
│       │   └── file_registry.rb         # JSONL file-based implementation
│       └── transport/
│           ├── base.rb                  # Abstract transport interface
│           ├── router.rb               # Priority-ordered transport routing
│           ├── mmp_transport.rb         # MMP delivery
│           ├── hestia_transport.rb      # Hestia discovery + MMP delivery
│           └── local_transport.rb       # Intra-instance delivery
└── tools/
    ├── attestation_request.rb
    ├── attestation_issue.rb
    ├── attestation_verify.rb
    ├── attestation_revoke.rb
    ├── attestation_list.rb
    ├── attestation_challenge_open.rb
    ├── attestation_challenge_resolve.rb
    └── trust_score_get.rb
```

## Core Data Model: ProofEnvelope

The ProofEnvelope is the canonical unit of attestation — a signed, versioned, self-contained record.

### Field Definitions

| Field | Type | Description |
|-------|------|-------------|
| `proof_id` | String | Auto-generated: `"att_<uuid>"` |
| `claim_type` | String | One of the 7 registered claim types |
| `disclosure_level` | String | `'existence_only'` or `'full'` |
| `attester_id` | String | Identity of the issuing agent |
| `attestee_id` | String | Identity of the attested agent |
| `subject_ref` | String | Reference to the attested subject (e.g., `"skill:fastqc_v1"`) |
| `target_hash` | String | `sha256:<hex>` of `subject_ref` |
| `evidence_hash` | String | `sha256:<hex>` of the evidence JSON |
| `evidence` | Hash/nil | Actual evidence (only when `disclosure_level == 'full'`) |
| `merkle_root` | String | Root of the Merkle tree built from evidence values |
| `merkle_proof` | Array | Proof path: `[{hash:, side:}, ...]` for the first leaf |
| `nonce` | String | 32-char hex random nonce (or bound to `request_id`) |
| `signature` | String | Base64 RSA-SHA256 signature over canonical JSON |
| `attester_pubkey_fingerprint` | String | Fingerprint of the signing key |
| `transport` | String | Transport used: `'local'` default |
| `issued_at` | ISO8601 | Creation timestamp (UTC) |
| `expires_at` | ISO8601 | Expiry timestamp |
| `status` | String | `'active'`, `'revoked'`, or `'challenged'` |
| `revoke_ref` | Hash/nil | `{reason:, revoked_at:}` when revoked |

### Canonical JSON for Signing

The `SIGNABLE_FIELDS` define the deterministic payload:

```ruby
SIGNABLE_FIELDS = %w[proof_id claim_type disclosure_level attester_id attestee_id
                     subject_ref target_hash evidence_hash merkle_root nonce
                     issued_at expires_at]
```

`canonical_json` produces sorted-key JSON from these fields only. Evidence is excluded from the signed payload — only its hash participates, enabling selective disclosure.

### Key Methods

```ruby
proof.canonical_json          # Deterministic JSON for signing
proof.sign!(crypto)           # Signs in-place using MMP::Crypto
proof.valid_signature?(key)   # Verifies RSA-SHA256 signature
proof.expired? / revoked? / active?  # Status helpers
proof.to_anchor               # Convert to Hestia::Chain::Core::Anchor
ProofEnvelope.from_h(hash)    # Deserialize from Hash
```

## MerkleTree

Binary Merkle tree using SHA-256.

### Build Algorithm

```
Input:  [leaf_a, leaf_b, leaf_c]
Level 0: [SHA256(leaf_a), SHA256(leaf_b), SHA256(leaf_c)]
  → Odd count: duplicate last → [H(a), H(b), H(c), H(c)]
Level 1: [SHA256(H(a)+H(b)), SHA256(H(c)+H(c))]
Level 2: [SHA256(L1[0]+L1[1])]  ← root
```

### Proof Generation (`proof_for(index)`)

For each level below root:
- Even index: sibling at `index+1`, side `:right`
- Odd index: sibling at `index-1`, side `:left`
- Missing sibling (odd level length): duplicate current
- Parent: `index /= 2`

### Verification (`MerkleTree.verify(leaf, proof, expected_root)`)

```ruby
current = SHA256(leaf.to_s)
proof.each do |step|
  current = step[:side] == :right ?
    SHA256(current + step[:hash]) :
    SHA256(step[:hash] + current)
end
current == expected_root
```

### Usage in AttestationEngine

Built from `evidence.values.map(&:to_s)` when evidence has >1 field. Proof generated for index 0 (first leaf).

## Verifier: 6-Stage Verification Flow

```ruby
verifier.verify(proof, options = {})
# => { valid: true/false, reasons: [], trust_hints: {} }
```

### Stage 1 — Signature Verification

RSA-SHA256 over `canonical_json`. If no public key provided, adds `'no_public_key_provided'` to reasons and notes in trust_hints.

### Stage 2 — Evidence Hash Verification

Computes `sha256:<hex>` of evidence JSON, compares to `proof.evidence_hash`. Only runs when both `evidence` and `evidence_hash` are present.

### Stage 3 — Revocation Check (full mode only)

Checks `proof.revoked?` and registry `find_revocation(proof_id)`. Populates trust_hints with revocation details.

### Stage 4 — Expiry Check (full mode only)

Compares `expires_at` against current UTC time.

### Stage 5 — Merkle Proof Verification (opt-in)

Only runs when `check_merkle: true` and merkle data is present. Uses `evidence.values.first.to_s` as leaf value. In `existence_only` mode, returns `'merkle_proof_unverifiable'` (no evidence to verify against).

### Stage 6 — Claim Type Validation

Validates `claim_type` against `ClaimTypes.valid_claim_type?`.

### Mode Summary

| Mode | Stages | Revocation | Expiry |
|------|--------|-----------|--------|
| `full` | 1-6 | Yes | Yes |
| `signature_only` | 1, 2, 6 | No | No |

## Trust Scoring

### Formula

```
score = quality × freshness × diversity × (1.0 - revocation_penalty) × (1.0 - velocity_penalty)
score = score.clamp(0.0, 1.0)
```

### Component Details

**quality_score** — Weighted evidence completeness:
```
quality = Σ(ClaimTypes.weight_for(claim_type) × evidence_completeness(proof)) / proof_count
```

Evidence completeness:
- `>= min_evidence_fields` keys: `1.0`
- Some evidence but fewer fields: `0.5`
- No evidence, `existence_only`: `0.7`
- No evidence otherwise: `0.3`

**freshness_score** — Exponential time decay:
```
freshness = mean( exp(-age_days × ln(2) / half_life_days) )
```
Default `half_life_days = 90`.

**diversity_score** — Attester uniqueness:
```
diversity = unique_attester_count / total_attestation_count
```

**revocation_penalty** — Attester's own revoked issuances:
```
revocation_penalty = revoked_issued_count / total_issued_count
```

**velocity_penalty** — Burst issuing:
```
if recent_24h_count > velocity_threshold:
  velocity_penalty = (count - threshold) / count
else: 0.0
```
Default `velocity_threshold_24h = 10`.

## Graph Analysis

Three metrics computed per agent:

### cluster_coefficient

Mutual attestation rate among an agent's attesters.

```
cluster_coeff = mutual_attesting_pairs / C(n, 2)
```

A pair is "mutual" if bidirectional attestation exists between any two attesters of the target agent. Flag: `'high_cluster_coefficient'` if > 0.8.

### external_connection_ratio

Fraction of attesters not in the mutual cluster.

```
ecr = external_attesters / total_unique_attesters
```

Flag: `'low_external_connections'` if < 0.3.

### velocity_anomaly

Count of attestations issued by the agent in the last 24h. Flag: `'velocity_anomaly'` if > 10.

The `trust_score_get` tool merges `TrustScorer.anomaly_flags` + `GraphAnalyzer.anomaly_flags` into a single list.

## Challenge Protocol

### State Transition Diagram

```
                 open_challenge()
  active proof ─────────────────► challenged proof
       │                              │
       │                    ┌─────────┴─────────┐
       │                    │                   │
       │          resolve('uphold')    resolve('invalidate')
       │                    │                   │
       │                    ▼                   ▼
       │            proof → active      proof → revoked
       │            challenge →         challenge →
       │            resolved_valid      resolved_invalid
       │
       │         deadline passes (no resolution)
       │                    │
       │                    ▼
       │            challenge → challenged_unresolved
       │            proof remains 'challenged'
```

### Guards

- `open_challenge`: proof must exist, not revoked, no existing open challenge for same proof, challenger < `max_active_challenges` (5)
- `resolve_challenge`: challenge must be open, decision must be `'uphold'` or `'invalidate'`

### Challenge Record Fields

```ruby
{
  challenge_id: "chl_<uuid>",
  challenged_proof_id:,
  challenger_id:,
  reason:,
  evidence_hash:,          # Optional sha256 of challenger evidence
  status: 'open',
  response: nil,
  response_at: nil,
  deadline_at:,            # now + response_window_hours (default 72h)
  resolved_at: nil,
  created_at:
}
```

## Transport Layer

### Router Priority Logic

```ruby
router.send(target_id, message)
```

Iterates configured priority list (default: `['mmp', 'hestia', 'local']`). Skips unavailable transports. Returns first success. If all fail:

```ruby
{ success: false, transport: 'none', error: 'All transports failed', details: [...] }
```

### Transport Implementations

| Transport | available? | Discovery | Delivery |
|-----------|-----------|-----------|----------|
| **MMP** | `defined?(MMP::Protocol)` | N/A | `MeetingRouter.instance.handle_message` |
| **Hestia** | `defined?(Hestia) && Hestia.loaded?` | `Hestia::AgentRegistry.find` | Via MMPTransport |
| **Local** | `defined?(Multiuser) && Multiuser.loaded?` | N/A | `Multiuser::TenantManager.deliver_to` |

Hestia is discovery-only: it finds agents via `AgentRegistry`, checks `capabilities.include?('mutual_attestation')`, then delegates delivery to MMP.

## Registry

### Base Interface

All methods raise `NotImplementedError`:

```ruby
save_proof(proof_hash)
find_proof(proof_id)
list_proofs(filters = {})
update_proof_status(proof_id, status, revoke_ref = nil)
save_revocation(revocation_hash)
find_revocation(proof_id)
save_challenge(challenge_hash)
find_challenge(challenge_id)
list_challenges(**filters)
update_challenge(challenge_id, updated_hash)
```

### FileRegistry Implementation

JSONL files with `Mutex` for thread safety:

```
storage_path/
  attestation_proofs.jsonl
  attestation_revocations.jsonl
  attestation_challenges.jsonl
```

Filter support:
- `list_proofs`: `:agent_id` (matches attester or attestee), `:claim_type`, `:status`
- `list_challenges`: `:challenger_id`, `:challenged_proof_id`, `:status`

Updates rewrite the full file after in-memory modification.

## Extension Points

### Adding a New Claim Type

Edit `lib/synoptis/claim_types.rb`:

```ruby
TYPES = {
  # existing types...
  'MY_CUSTOM_TYPE' => { weight: 0.6, description: 'My custom attestation type' }
}.freeze
```

The weight (0.0–1.0) determines how much this type contributes to the trust quality score.

### Implementing a Custom Transport

1. Create `lib/synoptis/transport/my_transport.rb`:

```ruby
module Synoptis
  module Transport
    class MyTransport < Base
      def available?
        # Return true if transport dependencies are loaded
      end

      def send_message(target_id, message)
        # Deliver message to target
        # Return { success: true/false, ... }
      end
    end
  end
end
```

2. Register in the Router (modify `router.rb` or add dynamic registration).
3. Add to `transport.priority` in `config/synoptis.yml`.

### PostgreSQL Registry (Phase 5 — planned)

Implement `Synoptis::Registry::PostgresRegistry < Base`:

```ruby
class PostgresRegistry < Base
  def initialize(connection_config)
    @db = PG.connect(connection_config)
  end

  def save_proof(proof_hash)
    @db.exec_params("INSERT INTO attestation_proofs ...")
  end

  # ... implement all Base methods
end
```

Switch via config:
```yaml
storage:
  backend: postgres
  postgres:
    host: localhost
    database: synoptis
```

## Config Reference

Full `config/synoptis.yml` parameters:

```yaml
# Master switch
enabled: false

attestation:
  default_expiry_days: 180        # Proof time-to-live
  min_evidence_fields: 2          # Minimum keys required in evidence hash
  allow_self_attestation: false   # Whether agent can attest itself
  auto_reciprocate: false         # Auto-issue reverse attestation

trust:
  score_half_life_days: 90        # Exponential decay half-life for freshness
  cluster_threshold: 0.8          # Flag if cluster_coefficient exceeds this
  velocity_threshold_24h: 10      # Flag/penalize if >N attestations in 24h
  min_diversity: 0.3              # Flag if external_connection_ratio below this

challenge:
  response_window_hours: 72       # Deadline for challenge response
  max_active_challenges: 5        # Max open challenges per challenger

storage:
  backend: file                   # 'file' (JSONL) or future 'postgres'
  file_path: storage/synoptis     # Relative to .kairos data directory

transport:
  priority: [mmp, hestia, local]  # Ordered transport preference
```

## Running Tests

```bash
cd KairosChain_mcp_server

# Full Synoptis test suite
ruby test_synoptis.rb

# Run with verbose output
ruby test_synoptis.rb -v

# Run all tests including Synoptis
ruby test_local.rb
ruby test_skillset_manager.rb
```

The test suite covers:
- ProofEnvelope construction and serialization
- MerkleTree build, proof generation, and verification
- All 6 verification stages
- Trust scoring formula with edge cases
- Graph analysis metrics and anomaly detection
- Challenge protocol state transitions
- Transport routing with fallback
- FileRegistry CRUD and filtering
- All 8 MCP tool integrations
