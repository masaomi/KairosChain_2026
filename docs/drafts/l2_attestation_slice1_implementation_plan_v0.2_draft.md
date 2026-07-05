---
title: L2 Attestation — Slice 1 Implementation Plan (v0.2 draft, decisions locked)
author: Masaomi Hatakeyama
date: 2026-07-05
status: DRAFT (implementation planning; three user decisions locked)
design_contract: docs/drafts/l2_attestation_constitutive_recording_design_v0.9_unified_FROZEN.md
extends: Synoptis SkillSet (L1), not core
supersedes: l2_attestation_slice1_implementation_plan_v0.1_draft.md
related_l2: [l2_attestation_seam_map_and_slice1_triage_20260705]
---

# L2 Attestation — Slice 1 Implementation Plan (v0.2)

## 0. Locked decisions (user, 2026-07-05)

1. **Store placement** — NOT the Meta Ledger (L0/L1 chain). Land constitutive entries on
   **Synoptis's attestation chain** (its `FileRegistry` append-only + hash-chain machinery).
   Two dedicated store *types* on that machinery, neither the Meta Ledger (LED-5):
   `l2_attestation` (the ledger) and `l2_operational_log` (telemetry).
2. **Active proposal from the start** — Slice 1 includes propose-only activation (the system
   proposes; the human approves). Justification is the user's: approval is human (ACT-1), so
   an imperfect criterion is safe (errors surface at the human gate, ACT-2's own rationale).
3. **First-cut criterion** — judgment-bearing types only: at session end, propose L2 contexts
   in the session whose frontmatter `type` ∈ {handoff, decision, debrief} (revisable, ACT-2).

## 1. Slice 1 goal

> The system, at a trigger point, **proposes** judgment-bearing L2 contexts for attestation;
> the human **approves** each; an approved content-attestation `(subject-id, digest, moment)`
> is appended to Synoptis's `l2_attestation` chain; declines and firings are logged to
> `l2_operational_log`.

Invariants satisfied: **LED-1, LED-2a, LED-3, LED-5, ACT-1, ACT-2 (simple), ACT-4, ACT-5.**
Deferred: **LED-2b, LED-4-as-mechanism, LED-6** (anchoring), **ACT-3** (supersession approval
binding — arrives with re-attest in Slice 2). Re-attest / revocation / snapshot / anchoring →
Slice 2+.

## 2. New / changed files (all under templates/skillsets/synoptis/)

New — constitutive module (does NOT edit attestation_engine / verifier / revocation_manager /
trust_scorer):

| Path | Responsibility |
|------|----------------|
| `lib/synoptis/constitutive/content_attestation_entry.rb` | Value object: `kind='content_attestation'`, `entry_id`, `subject_id`, `digest`, `digest_alg`, `moment`, `snapshot?`. `to_h`, `canonical_json`, `entry_hash`. No signature, no ttl. |
| `lib/synoptis/constitutive/subject_ref.rb` | Parse `context://session/name`; resolve to `KairosMcp.context_dir/session/name/name.md`; `digest(uri)` = SHA256 of file bytes; `content_state(uri)` = {exists, bytes, digest}; `frontmatter_type(uri)`. |
| `lib/synoptis/constitutive/attestation_chain.rb` | Wraps the shared `FileRegistry`. `append_content_attestation(entry)` → type `l2_attestation`; `append_trigger(surfaced_count)` / `append_decline(subject_id)` → type `l2_operational_log`; `entries` / `oplog` / `verify_chain`. |
| `lib/synoptis/constitutive/proposal_criterion.rb` | ACT-2 first-cut: given a session_id, list session contexts, read frontmatter `type`, return proposals for judgment types. Config-driven type set. |
| `tools/l2_attestation_scan.rb` | ACT-5+ACT-2: fire criterion, surface proposals, append one trigger record. Reads L2 content, writes only telemetry. |
| `tools/l2_attestation_commit.rb` | ACT-1: `approved:true` required; recompute digest, append content-attestation. Without approval → returns proposal, writes nothing. |
| `tools/l2_attestation_decline.rb` | ACT-4: append content-free decline record to oplog. |
| `test/test_l2_constitutive_slice1.rb` | Unit + wiring + regression (see §5). |

Changed:

| Path | Change |
|------|--------|
| `lib/synoptis/registry/file_registry.rb` | Add generic public `append(type, record)` and `read(type)` (non-breaking; existing typed methods untouched; `verify_chain(type)` already generic). |
| `lib/synoptis/tool_helpers.rb` | Add `constitutive_chain`, `proposal_criterion` accessors. |
| `skillset.json` | Add the 3 new tool classes to `tool_classes`. |
| `config/synoptis.yml` | Add `constitutive:` block: `digest_alg: sha256`, `judgment_types: [handoff, decision, debrief]`, store type names. Existing blocks untouched. |

## 3. Grounded seam decisions

- **ACT-1 approval = `approved: true` two-call** (same as `skills_evolve` / `skills_audit`
  archive). Workflow-level, human-in-the-loop, no crypto → exactly the L0/L1 posture
  (LED-6). Bypass by a mis-instructed agent accepted at the same level L0/L1 accept it;
  answered by revocation (Slice 2), not prevented.
- **Digest (LED-3) = SHA256 of the subject's persisted bytes** at
  `context_dir/<session>/<name>/<name>.md`. Distinct from `ProofEnvelope#content_hash`.
- **Moment = append moment** (`Time.now.utc.iso8601`).
- **subject-id (LED-3) = the `context://` URI**, stable across file rename/relocation.
- **Two stores on Synoptis's chain (LED-5)**: `l2_attestation` and `l2_operational_log`,
  distinct jsonl files, each its own hash chain, both under Synoptis `synoptis_data/`,
  neither on the Meta Ledger.
- **Criterion (ACT-2) is simple + config-driven + revisable**; starts as a frontmatter-type
  rule, later becomes LLM-semantic. Human gate (ACT-1) makes imperfection safe.

## 4. Regression firewall (unchanged Synoptis behaviour)

`attestation_engine.rb` (duplicate hard-reject), `verifier.rb` (signature), `revocation_manager.rb`,
`trust_scorer.rb`, `challenge_*`, transports, existing 7 tools: NOT edited. `file_registry.rb`
gains two additive methods only. Regression proven by `test/test_synoptis.rb` staying green.

## 5. Tests (fail-closed)

Entry/digest: canonical determinism; SHA256 byte-sensitivity; subject-id stability.
Chain (LED-2a): two appends → 2 lines, `_prev_entry_hash` links, `verify_chain` valid; no
edit/delete API. Two stores are distinct files (LED-5).
Criterion (ACT-2): judgment-type contexts proposed; non-judgment types not proposed.
Approval (ACT-1): commit without `approved` writes nothing; with `approved:true` appends one.
Trigger (ACT-5): scan appends exactly one trigger record with surfaced_count.
Decline (ACT-4): decline appends one content-free record; binds no content.
Selective (LED-1): commit does not modify/lock/create the live context file.
Separation (LED-5): `chain_status().length` unchanged by any of the above (nothing on Meta Ledger).
Regression: `test/test_synoptis.rb` green.

## 6. Build / run sequence (rbenv-aware)

```
cd /Users/masa/forback/github/KairosChain_2026
# unit (Bash Ruby 3.1.3 ok for pure Ruby):
ruby -I KairosChain_mcp_server/lib \
  KairosChain_mcp_server/templates/skillsets/synoptis/test/test_l2_constitutive_slice1.rb
ruby -I KairosChain_mcp_server/lib \
  KairosChain_mcp_server/templates/skillsets/synoptis/test/test_synoptis.rb
# wire into live MCP (Ruby 3.3.7):
RBENV_VERSION=3.3.7 gem build kairos-chain.gemspec
RBENV_VERSION=3.3.7 gem install ./kairos-chain-*.gem
kairos-chain upgrade   # sync .kairos/, then restart Claude Code
```

## 7. End-to-end verification (after wiring)

`l2_attestation_scan` → proposes this session's judgment contexts + one trigger record.
`l2_attestation_commit(subject, approved:true)` → one ledger line; digest matches manual
`shasum -a 256` of the context .md. `l2_attestation_decline(subject)` → one content-free
oplog line. Confirm `chain_status().length` unchanged (LED-5) and context file untouched (LED-1).

## 8. Carried forward
Slice 2: supersession (re-attest → append; reconcile Synoptis hard-reject), revocation-withdrawal
entry kind (reconcile revocation store), ACT-3 approval binding, TTL retirement.
Slice 3+: LLM-semantic criterion + versioning + approve/decline feedback (ACT-2), snapshot,
anchoring (LED-6). Optional: multi-LLM review of this plan before/after coding (implementation
review finds seam/fail-open/wiring/test-coverage bugs).
