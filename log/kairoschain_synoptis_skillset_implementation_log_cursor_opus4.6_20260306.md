# Synoptis v2.1 SkillSet Implementation Log

**Date:** 2026-03-06
**Branch:** `feature/synoptis-skillset-v2`
**Commit:** `f0a850f`
**Author:** Cursor (claude-4.6-opus) + Dr. Masa Hatakeyama
**Plan:** `log/kairoschain_synoptis_skillset_plan2.1_cursor_opus4.6_20260306.md`

---

## 1. Background

Synoptis v1 was implemented on `feature/synoptis-skillset` but deviated from
KairosChain's philosophy in several critical areas (identity resolution, transport
layer, MMP core coupling). After two rounds of cross-LLM review and a v2.1 plan
revision, the decision was made to re-implement from scratch on a new branch.

### Key documents:
- v1 patch: `log/kairoschain_synoptis_skillset_patch_opus4.6_20260305.patch`
- v2.0 plan: `log/kairoschain_synoptis_skillset_plan2_cursor_opus4.6_20260306.md`
- v2.1 plan (revised): `log/kairoschain_synoptis_skillset_plan2.1_cursor_opus4.6_20260306.md`
- Reviews: `log/kairoschain_synoptis_skillset_plan2.1_review_*`

---

## 2. Implementation Phases

### Phase 0a: MMP Protocol register_handler (core change)

**File:** `KairosChain_mcp_server/templates/skillsets/mmp/lib/mmp/protocol.rb`

Added generic handler extension mechanism as class-level methods:

| Method | Purpose |
|--------|---------|
| `register_handler(action, &block)` | Register action name + handler in one step |
| `unregister_handler(action)` | Remove a registered handler |
| `extended_handler(action)` | Retrieve handler for an action |
| `extended_actions` | List all extended action names |
| `clear_extended_handlers!` | Clear all (for testing) |

Design decisions:
- **Mutex thread safety** (P2-C1 fix): All handler access wrapped in `@handler_mutex`
- **Built-in action protection**: `raise ArgumentError` if attempting to override ACTIONS
- **Handler signature**: `handler.call(msg_data, protocol_instance)` — passes symbolized message data and the Protocol instance
- **Error isolation**: Handler exceptions wrapped in `rescue StandardError`, logged to stderr, return generic error response (no internal details leaked)

Modified `supported_actions` to union base actions with `self.class.extended_actions`.
Modified `process_message` else-branch to dispatch to extended handlers before returning `action_not_supported`.

**Tests:** 172 existing tests pass (0 regressions).

### Phase 0b: PeerManager session lifecycle (core change)

**File:** `KairosChain_mcp_server/templates/skillsets/mmp/lib/mmp/peer_manager.rb`

Changes:
1. Added `:session_token` to `Peer` struct
2. `introduce_to`: extracts `response[:session_token]` and stores on peer
3. `send_message`: includes `Authorization: Bearer <token>` header when session_token available
4. `http_post`: accepts optional `headers:` keyword argument

**Design decision — session_token NOT persisted to disk:**
On server restart, the session_store is reset (in-memory), so persisted tokens would be stale. Peers start with `status: :unknown` and must re-introduce to get a new token. This is more secure and simpler.

**Tests:** 94 + 172 existing tests pass (0 regressions).

### Phase 0c: MeetingRouter _authenticated_peer_id injection (core change)

**File:** `KairosChain_mcp_server/lib/kairos_mcp/meeting_router.rb`

Changes:
1. `authenticate_meeting_request!`: stores validated `peer_id` in `env['meeting.authenticated_peer_id']`
2. `handle_message`: injects `body['_authenticated_peer_id'] = env['meeting.authenticated_peer_id']` before `process_message`

This prevents `from:` spoofing in extended handlers — the handler receives the Bearer-token-verified peer identity, not the self-declared `from:` field.

**Note on API:** `session_store.validate(token)` returns a String (peer_id), not a Hash. The plan's pseudo-code had this wrong; fixed during implementation.

### Phase 0d: Synoptis SkillSet skeleton

Created `.kairos/skillsets/synoptis/` with:
- `skillset.json`: `depends_on: [{"name": "mmp", "version": ">= 1.0.0"}]`
- `config/synoptis.yml`: Default configuration
- `lib/synoptis.rb`: Entry point with MMP handler registration
- Directory structure for lib, tools, config, knowledge, test

### Phase 1: Attestation Engine MVP

All files in `.kairos/skillsets/synoptis/lib/synoptis/`:

#### proof_envelope.rb
- Data model for attestation proofs
- **S-C1 fix**: `canonical_json` retains `nil` values as JSON null (no `.compact`)
- `sign!(crypto)` accepts `MMP::Crypto` instance (not raw private key — API corrected during implementation)
- Deterministic `content_hash` via `canonical_json`
- `expired?` check using ttl

#### verifier.rb
- **S-C5 fix**: Mandatory signature verification when `require_signature: true`
- No soft-fail path — missing signatures always fail in strict mode
- Checks: attester_id, subject_ref, claim, expiry, signature

#### attestation_engine.rb
- **S-C4 fix**: Duplicate detection strictly registry-dependent
- Normalizes key types with `.to_s` for consistent comparison
- `create_attestation` accepts `crypto:` parameter (MMP::Crypto instance)
- `verify_attestation` checks revocation before verification
- `list_attestations` with filter support

#### registry/file_registry.rb
- Append-only JSONL storage with atomic writes (`File.open + flock`)
- **PHIL-C1 fix**: `_prev_entry_hash` links each entry to the previous one
- **S-C3 fix**: Uses `File.open` with `flock` instead of `Tempfile`
- `verify_chain(type)` validates hash chain integrity
- Separate files per record type (proofs.jsonl, revocations.jsonl, challenges.jsonl)

#### revocation_manager.rb
- Authorization: only original attester or admin can revoke
- **High-1 fix**: `actor_user_id` and `actor_role` recorded in all audit records
- Uses `.to_s` for identity comparison (key type normalization)

#### challenge_manager.rb
- Append-only aware status resolution: `current_challenge_status` checks latest record per `challenge_id`
- `count_pending_challenges` groups by `challenge_id`, takes latest status
- Max active challenges per proof (configurable)
- Authorization: only original attester can respond

#### trust_scorer.rb
- 5-factor scoring: quality (0.3), freshness (0.25), diversity (0.25), velocity (0.1), revocation penalty (0.1)
- Quality: evidence + merkle_root + signature presence
- Freshness: 30-day decay curve
- Diversity: unique attesters ratio
- Velocity: attestation rate (capped at 5/day)
- Configurable weights

### Phase 2: Transport Layer

#### transport/base_transport.rb
- Abstract base class with NotImplementedError stubs

#### transport/mmp_transport.rb
- Uses `MMP::PeerManager.send_message` (which includes Bearer token after Phase 0b)
- `resolve_peer_manager` instantiates PeerManager from persisted `peers.json`
- Identity resolution via `MMP::Identity.introduce[:identity][:instance_id]`

#### transport/hestia_transport.rb
- **High-2 fix**: `available?` uses `defined?(::Hestia::PlaceRouter)` instead of non-existent `Hestia.loaded?`

#### transport/local_transport.rb
- **High-2 fix**: `available?` uses `defined?(::Multiuser::TenantManager)`

### Phase 3: MCP Tools

7 tools created in `tools/`:

| Tool | Purpose |
|------|---------|
| `attestation_issue` | Create signed attestation proof |
| `attestation_verify` | Verify proof by ID (structure, signature, expiry, revocation) |
| `attestation_revoke` | Revoke with authorization check |
| `attestation_list` | List with optional filters |
| `trust_query` | Calculate trust score + registry integrity check |
| `challenge_create` | Challenge an existing proof |
| `challenge_respond` | Respond to a challenge |

All tools:
- Use `Synoptis::ToolHelpers` mixin
- Resolve agent ID via `MMP::Identity.introduce[:identity][:instance_id]` (**Critical-2 fix**)
- Capture `actor_user_id` from `@safety.current_user[:user]` (**High-1 fix**)
- Return JSON via `text_content(JSON.pretty_generate(result))`

#### tool_helpers.rb (shared)
- `resolve_agent_id`: Uses MMP::Identity
- `resolve_crypto`: Accesses Identity's internal Crypto instance for signing
- `resolve_actor_user_id` / `resolve_actor_role`: From `@safety.current_user`
- Lazy-initialized registry, engine, revocation_manager, challenge_manager, trust_scorer

---

## 3. Bug Fixes Applied (from v1 review3)

| ID | Severity | Description | Status |
|----|----------|-------------|--------|
| S-C1 | CRITICAL | canonical_json .compact removes nil fields | FIXED: No .compact in canonical form |
| S-C3 | CRITICAL | Tempfile.close! may delete before rename | FIXED: File.open + flock |
| S-C4 | CRITICAL | Duplicate detection not registry-dependent | FIXED: Registry query with .to_s normalization |
| S-C5 | CRITICAL | Signature verification soft-fail | FIXED: Mandatory when require_signature=true |
| Critical-1 | CRITICAL | MMP Transport calls class method, no Bearer auth | FIXED: PeerManager.send_message with Bearer |
| Critical-2 | CRITICAL | KairosMcp.agent_id doesn't exist | FIXED: MMP::Identity.introduce[:identity][:instance_id] |
| High-1 | HIGH | No user-level RBAC audit | FIXED: actor_user_id + actor_role in all records |
| High-2 | HIGH | Hestia.loaded? / Multiuser.loaded? not implemented | FIXED: defined?(::Module::Class) checks |
| P-C1 | CRITICAL | PeerManager no Bearer token | FIXED: session_token + Authorization header |
| P-C3 | CRITICAL | Handler not receiving authenticated peer_id | FIXED: _authenticated_peer_id injection |
| PHIL-C1 | HIGH | No constitutive recording | FIXED: prev_entry_hash chain |

---

## 4. Implementation Corrections (deviations from plan pseudo-code)

1. **ProofEnvelope#sign!**: Plan passed `private_key` (raw PEM). Actual `MMP::Crypto#sign` uses internal `@private_key`. Corrected to accept `crypto:` (MMP::Crypto instance).

2. **MeetingRouter API**: Plan's pseudo-code used `parse_json_body` (doesn't exist) and `session_store.validate(token)[:peer_id]` (returns String, not Hash). Corrected during implementation.

3. **ChallengeManager active count**: Plan didn't account for append-only storage where old 'pending' records persist after 'responded' records are appended. Added `count_pending_challenges` that groups by challenge_id and checks latest status.

4. **session_token persistence**: Plan suggested persisting to peers.json. Decided against it — stale tokens are useless after server restart (session_store is in-memory).

---

## 5. Test Results

```
SECTION 1: ProofEnvelope ............ 17 passed
SECTION 2: Verifier .................. 9 passed
SECTION 3: FileRegistry ............. 16 passed
SECTION 4: AttestationEngine ........ 10 passed
SECTION 5: RevocationManager ......... 5 passed
SECTION 6: ChallengeManager .......... 7 passed
SECTION 7: TrustScorer ............... 7 passed
SECTION 8: MMP register_handler ..... 14 passed
SECTION 9: Transport checks .......... 3 passed
─────────────────────────────────────────
TOTAL: 88 passed, 0 failed

MMP Regression: 94 + 172 = 266 passed, 0 failed
Grand Total: 354 passed, 0 failed
```

---

## 6. File Summary

### Core changes (3 files, +82 lines)
- `KairosChain_mcp_server/lib/kairos_mcp/meeting_router.rb`
- `KairosChain_mcp_server/templates/skillsets/mmp/lib/mmp/peer_manager.rb`
- `KairosChain_mcp_server/templates/skillsets/mmp/lib/mmp/protocol.rb`

### Synoptis SkillSet (24 files, +1997 lines)
- `templates/skillsets/synoptis/skillset.json`
- `templates/skillsets/synoptis/config/synoptis.yml`
- `templates/skillsets/synoptis/lib/synoptis.rb`
- `templates/skillsets/synoptis/lib/synoptis/proof_envelope.rb`
- `templates/skillsets/synoptis/lib/synoptis/verifier.rb`
- `templates/skillsets/synoptis/lib/synoptis/attestation_engine.rb`
- `templates/skillsets/synoptis/lib/synoptis/revocation_manager.rb`
- `templates/skillsets/synoptis/lib/synoptis/challenge_manager.rb`
- `templates/skillsets/synoptis/lib/synoptis/trust_scorer.rb`
- `templates/skillsets/synoptis/lib/synoptis/tool_helpers.rb`
- `templates/skillsets/synoptis/lib/synoptis/registry/file_registry.rb`
- `templates/skillsets/synoptis/lib/synoptis/transport/base_transport.rb`
- `templates/skillsets/synoptis/lib/synoptis/transport/mmp_transport.rb`
- `templates/skillsets/synoptis/lib/synoptis/transport/hestia_transport.rb`
- `templates/skillsets/synoptis/lib/synoptis/transport/local_transport.rb`
- `templates/skillsets/synoptis/tools/attestation_issue.rb`
- `templates/skillsets/synoptis/tools/attestation_verify.rb`
- `templates/skillsets/synoptis/tools/attestation_revoke.rb`
- `templates/skillsets/synoptis/tools/attestation_list.rb`
- `templates/skillsets/synoptis/tools/trust_query.rb`
- `templates/skillsets/synoptis/tools/challenge_create.rb`
- `templates/skillsets/synoptis/tools/challenge_respond.rb`
- `templates/skillsets/synoptis/knowledge/synoptis_protocol/synoptis_protocol.md`
- `templates/skillsets/synoptis/test/test_synoptis.rb`

---

## 7. Philosophical Alignment

| Proposition | Realization |
|-------------|-------------|
| P1 (Self-referentiality) | SkillSet extends MMP without core modification (register_handler) |
| P5 (Constitutive Recording) | prev_entry_hash chain in FileRegistry |
| P6 (Incompleteness) | Synoptis is opt-in, not forced — gaps drive extension |
| P7 (Design-Implementation Closure) | Developed using KairosChain's own tools (.kairos/) |
| P8 (Co-dependent Ontology) | Trust scores emerge from cross-agent attestation relationships |
| P9 (Human-System Composite) | actor_user_id captures human at the boundary |

---

## 8. Known Limitations and Future Work

1. **Token expiry**: MVP uses manual reconnect. Document limitation; add refresh in future.
2. **GraphAnalyzer**: Collusion detection not yet implemented (planned for Phase 5).
3. **Hestia/Local transport**: Stub implementations — actual delivery logic TBD when those SkillSets are ready.
4. **Integration test**: Unit tests pass; P2P integration test with actual HTTP connection needed.
5. **Selective disclosure**: Merkle proof construction utilities not yet implemented (ProofEnvelope stores `merkle_root` but doesn't build trees).
