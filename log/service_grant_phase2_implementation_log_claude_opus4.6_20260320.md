# Service Grant Phase 2 — Full Implementation Log

- **Date**: 2026-03-20
- **Author**: Claude Opus 4.6
- **Branch**: `feature/service-grant-skillset`
- **Phase 2 Commits**: `fc5536e`, `aa253f8`, `0b53a95`, `b3a86d5`, `fa6a4ae`, `9d183bb`
- **Final Tests**: 92 runs, 127 assertions, 0 failures

---

## 1. Summary

Phase 2 adds Trust Score integration, anti-collusion foundation, IP rate limiting infrastructure, and performance hardening to the Service Grant SkillSet. Implemented across 3 sub-phases (2A, 2B, 2C) with 8 rounds of multi-LLM review (R8-R15).

---

## 2. Sub-Phase Breakdown

### Phase 2A: IP Wiring + Anti-Collusion Foundation (commit `fc5536e`)

| Item | File(s) | Description |
|------|---------|-------------|
| 2A-1 | `access_gate.rb` | PgUnavailableError rescue (Path A 503) |
| 2A-0b | `client_ip_resolver.rb` (NEW) | X-Real-IP resolver, no XFF |
| D-5 | `http_server.rb`, `place_router.rb`, `place_middleware.rb` | remote_ip wired through both paths |
| FIX-10 | `grant_manager.rb` | Atomic INSERT + ROLLBACK in transaction |
| 2A-8 | `ip_rate_tracker.rb`, `002_grant_ip_events.sql` (NEW) | PG-backed atomic INSERT...SELECT |
| 2A-9 | `service_grant_guide.md` | Unregister ungated + IP documentation |
| 2A-0 | `synoptis/trust_identity.rb` (NEW) | `agent://<pubkey_hash>` canonical URIs |
| 2A-5 | `synoptis/trust_scorer.rb` | PageRank-weighted quality scoring |
| 2A-6 | `synoptis/trust_scorer.rb` | Cross-cluster bridge score |
| 2A-7 | `service_grant.yml` | Anti-collusion + IP resolution config |
| 3.4 | `service_grant_guide.md` | Anti-collusion threat model |

### Phase 2B: Trust Score Integration (commit `aa253f8`)

| Item | File(s) | Description |
|------|---------|-------------|
| 2B-1 | `trust_scorer_adapter.rb` (NEW) | Callable adapter, TTL cache, fail-closed |
| 2B-2 | `service_grant.rb` | Wire adapter into AccessChecker via build_trust_scorer |
| 2B-3 | `trust_scorer_adapter.rb` | Adapter-owned TTL cache (quality+bridge only) |
| 2B-4 | `service_grant.yml` | deposit_skill trust 0.0→0.1 |
| 2B-5 | `grant_manager.rb` | Recording retry (3 attempts, exponential backoff) |
| R11 fix | `trust_scorer.rb` | Bootstrap floor: return 0.0 without external |
| R11 fix | `trust_scorer.rb` | Bridge score: SCC-based (find_scc forward+reverse BFS) |
| R12 fix | `service_grant.rb` | FileRegistry.new(data_dir:) keyword arg |
| R12 fix | `trust_scorer_adapter.rb` | Returns quality+bridge only (trust-relevant) |

### Phase 2C: Infrastructure Hardening (commit `0b53a95`)

| Item | File(s) | Description |
|------|---------|-------------|
| 2C-1 | `pg_circuit_breaker.rb` | Two-phase mutex (lock-free in :closed) |
| 2C-2 | `pg_connection_pool.rb` | Bounded checkout with ConditionVariable |
| 2C-3 | `mmp/meeting_session_store.rb` | peer_id reverse index (O(1) lookup) |

### Post-Review Fixes

| Commit | Fixes |
|--------|-------|
| `b3a86d5` | R13: synoptis dependency, pool checkout leak, SCC-consistent anti-collusion |
| `fa6a4ae` | R14: PoolExhaustedError inheritance, allow_readonly doc, +5 infra tests |
| `9d183bb` | R15: Trust fail-closed (ConfigValidationError when trust required but unavailable) |

---

## 3. Review History

| Round | Stage | Claude Team | Codex | Cursor | Outcome |
|-------|-------|:-----------:|:-----:|:------:|---------|
| R8 | Phase 2 design v1.0 | COND PASS | FAIL | COND PASS | → v1.1 |
| R9 | Phase 2 design v1.1 | APPROVE | REVISE | APPROVE | Converged (2/3) |
| R10 | Phase 2A impl | COND PASS | FAIL | FAIL | → R10 fixes |
| R11 | Phase 2A fix | PASS | COND PASS | COND PASS | Converged |
| R12 | Phase 2B impl | PASS | FAIL | FAIL | → R12 fixes |
| R12.5 | Phase 2C impl | PASS (simplified) | — | — | PASS |
| R13 | Phase 2 full | PASS | FAIL | FAIL | → R13 fixes |
| R14 | Phase 2 fix | PASS | FAIL | COND PASS | → R14 evaluation |
| R15 | Phase 2 fix2 | PASS | COND PASS | COND PASS | **Converged** |

---

## 4. Debug Count

| # | Issue | Phase | Caught By |
|---|-------|-------|-----------|
| 1 | Bridge score 2-hop cluster too aggressive | 2B | Self-review (test failure) |
| 2 | Test assertions for cartel scores (threshold) | 2B | Test failure |
| 3 | Tests after `private` (dead tests) | 2B | R12 agent review |
| 4 | Bridge score SCC still wrong (mutual group) | 2B | Self-review (test failure) |
| 5 | `require 'set'` missing | 2A | R10 Codex |
| 6 | TrustIdentity normalizes non-agent refs | 2A | R10 Codex |
| 7 | Revoked proofs in graph helpers | 2A | R10 Codex |
| 8 | FileRegistry keyword arg | 2B | R12 Codex+Cursor |
| 9 | Self-only score > threshold | 2B | R12 Codex |
| 10 | synoptis dependency missing | R13 | Codex+Cursor |
| 11 | Pool checkout @checked_out leak | R13 | Codex |
| 12 | has_external_attestation? inconsistent with SCC | R13 | Codex |
| 13 | Trust fail-open on init failure | R14 | Codex (minority FAIL) |

**Total debug count Phase 2: 13** (4 self-caught, 9 review-caught)

---

## 5. Files Changed (Phase 2 total)

| Category | New | Modified |
|----------|:---:|:--------:|
| Service Grant lib | 2 (client_ip_resolver, trust_scorer_adapter) | 7 |
| Service Grant config | 0 | 2 (yml, json) |
| Service Grant migrations | 1 (002_grant_ip_events.sql) | 0 |
| Service Grant knowledge | 0 | 1 (guide) |
| Service Grant tests | 0 | 1 (+42 tests) |
| Core | 0 | 1 (http_server.rb) |
| Hestia | 0 | 1 (place_router.rb) |
| MMP | 0 | 1 (meeting_session_store.rb) |
| Synoptis | 1 (trust_identity.rb) | 1 (trust_scorer.rb) |
| L1 Knowledge | 0 | 1 (multi_llm_review_workflow) |

---

## 6. Key Architecture Decisions

### Trust-relevant score (quality + bridge only)

TrustScorerAdapter returns `quality + bridge` dimensions, excluding freshness/diversity/velocity. Reason: self-only agents score ~0.4 on non-trust dimensions, bypassing the 0.1 trust threshold. By using only trust-relevant dimensions, the adapter correctly returns 0.0 for agents without external attestation.

### SCC-based bridge score

Bridge score uses Strongly Connected Components (forward+reverse BFS intersection) to detect closed cliques. Closed clique A←B←C←A: all nodes in same SCC, bridge=0. External connection: attester outside SCC, bridge>0.

### Bootstrap floor enforcement

`attestation_weight` returns 0.0 immediately when `has_external_attestation?` is false, regardless of PageRank teleportation mass. This ensures cartel members cannot bootstrap trust through mutual attestation alone.

### Trust fail-closed

`build_trust_scorer` raises `ConfigValidationError` when `trust_requirements` are configured but Synoptis is unavailable or initialization fails. This prevents silent fail-open where trust gating is configured but not enforced.

### Majority rule → reference signal

L1 `multi_llm_review_workflow` updated: majority vote is a signal, not a decision mechanism. Minority FAIL must be evaluated on substance. This change was triggered by Codex R14's minority FAIL identifying a genuine fail-open vulnerability that majority had dismissed.

---

## 7. Phase 3 Follow-ups (tracked)

| Item | Source | Description |
|------|--------|-------------|
| `unload!` cleanup on ConfigValidationError | R15 Codex+Cursor | Partial state left after config error |
| Config numeric validation | R15 Codex | `to_f` coerces "strict"→0.0 silently |
| fail-closed direct tests | R15 Codex+Cursor | build_trust_scorer matrix branches |
| Recording retry WAL | Phase 2B design | Thread.new → bounded queue |
| grant_ip_events cleanup | Phase 2A | No TTL cleanup mechanism |
| D-6: PlaceRouter body agent_id | Phase 1 D-6 | Pre-existing Hestia issue |
| CB half-open test | R14 Cursor | Recovery path untested |

---

## 8. Multi-LLM Review Experiment Stats (Cumulative)

| Phase | Design Rounds | Impl Rounds | Fix Rounds | Total |
|-------|:------------:|:-----------:|:----------:|:-----:|
| Phase 1 | 3 (R1-R3) | 1 (R4) | 3 (R5-R7) | 7 |
| Phase 2 | 2 (R8-R9) | 3 (R10-R12.5) | 3 (R13-R15) | 8 |
| **Total** | **5** | **4** | **6** | **15** |

| Metric | Phase 1 | Phase 2 | Total |
|--------|:-------:|:-------:|:-----:|
| LLM reviews | ~18 | ~24 | ~42 |
| Bugs found by review | 11 | 13 | 24 |
| Bugs found by self | 2 | 4 | 6 |
| Tests at end | 50→90 | 90→92 | 92 |
| Assertions at end | — | — | 127 |

### Key Observation

Design review and implementation review find categorically different bugs. Anti-collusion algorithm correctness (bridge score, bootstrap floor, SCC) required multiple implementation review rounds to get right — design review could not catch these because they depend on graph algorithm semantics that only emerge in code.

Minority FAIL evaluation is critical. The trust fail-open vulnerability (R14) was found by only 1/3 reviewers but was the most important bug in Phase 2.
