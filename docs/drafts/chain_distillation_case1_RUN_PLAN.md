# Chain Distillation — case #1 RUN PLAN (multi_llm_review_workflow, product form B)

Prepared 2026-07-23. Execution is blocked until the confidentiality-guard regime
is active — activation is instance-start-only (CG-1), so a **Claude Code restart**
is required. This file is the ready-to-run recipe for the next session.

## Precondition (verify first)

After restart, confirm the guard came up active:

- `cg_status` must show `active: true`, `policy_empty: false`, and the
  `distillation_outward` surfaces `cd_release_distillate` / `cd_release_certificate`.
- Activation is wired via `.mcp.json` env `KAIROS_CONFIDENTIALITY_GUARD=1`
  (added 2026-07-23). Profile: `.kairos/skillsets/confidentiality_guard/config/profile.yml`
  (already adopted by masaomi, includes the two distillation crossings + api_key /
  private_key content classes).
- If `active:false`, do NOT run cd_distill — it will decline (CD-1). Re-check the
  env wiring and restart.

## Decisions (fixed 2026-07-23)

1. Capability: **multi_llm_review_workflow**.
2. Designation set (closed-world record indices):
   `[41, 49, 51, 64, 65, 66, 67, 73, 135, 159, 226, 230, 231, 254]`
   - 49/51/73/230/231/254 — `multi_llm_review_workflow` L1 create + revisions
   - 41 — `multi_llm_reviewer_evaluation` create (mandatory Step-0 companion WHO knowledge)
   - 226 — `multi_llm_reviewer_evaluation` 1.4->1.5 update
   - 135/159 — `multi_llm_review` SkillSet materialization (0.2.0 first -> 0.5.0)
   - 64/65 — autoexec intent+outcome (multi_llm_review_skillset_design_review_r1)
   - 66/67 — autoexec intent+outcome (uzh_fellowship_v3_multi_llm_review_execute)
   - Span disclosed = 41..254; selection is discrete (not aggregated into a score; CD-2 anti volume-gaming).
   - All substantive; no guard/cd_* meta-records. Only identifiers are bound, so
     even secret-bearing records would be safe to designate — but none here are.
3. Distillate: condensed, newly authored (NOT a copy of the 51KB source).
   File: `docs/drafts/chain_distillation_case1_distillate_multi_llm_review.json`.
   Human+model authorship is stated inside the object.
4. rpr-1: NOT paired this round (pure form-B, provenance-only; CD-3 demonstrated cleanly).

## Run (next session, after cg_status active)

```
# 1. distill
cd_distill(
  designation: [41,49,51,64,65,66,67,73,135,159,226,230,231,254],
  distillate:  <contents of docs/drafts/chain_distillation_case1_distillate_multi_llm_review.json>,
  attester_id: "chain_distillation"   # optional
)
# -> { status: "distilled", certificate: {...}, record_block_index: N }

# 2. verify (third-party path; supply the distillate JSON to enable the commitment check)
cd_verify(
  certificate:     <the returned certificate>,
  distillate_json: <canonical JSON string of the same distillate>,
  use_chain:       true
)
# -> expect { valid: true, revoked: false }
```

## Expected outcome & interpretation

- A certified distillate OBJECT + provenance certificate + a `cd_distillation`
  chain record (constitutive, written BEFORE release — CD-6).
- The certificate proves anti-fake ORIGIN only. It cannot express usefulness
  (CD-3); `cd_verify` rejects any claim-core key outside the pinned vocabulary.
- Slice-1 scope: this yields a certificate + certified object, NOT an installable/
  distributable SkillSet package. Decide whether to hold it for slice-2
  distribution or use the certificate standalone.

## Guard-side cautions for this session

Once the guard is active, other tool calls are gated too:
- `restricted_storage` denies reads of `.kairos/storage` (chain store) via
  safe_file_read/list — use MCP `chain_history` / `chain_status` instead.
- `persistent_admissions`: L1 inward writes denied, L2 permitted. `context_save`
  works; `knowledge_update` to L1 is denied while guarded.
- If the distillate ever trips a content class (api_key / private-key pattern),
  the release is denied and NOTHING is recorded — safe by construction.

## Refs
- Handoff: `.kairos/context/session_20260723_042400_aef85e3e/handoff_chain_distillation_case1_real_distillation_20260723/`
- Design v0.5 (CD-1..6): `docs/drafts/chain_distillation_skillset_design_v0.5_draft.md`
- To disable the guard afterwards: remove the `env` block from `.mcp.json` and restart.
