---
name: loop_validation
description: Use when closing any agent loop with mechanical verification — declare an evidence spec before the run, compute a fail-closed verdict without the acting LLM's self-report, pin criteria by hash, record the outcome as an attestation. Body-agnostic; reference engine in scripts/.
version: 0.4
tags: [loops, validation, verification, evidence, fail-closed, attestation, autonomy]
related: [loop_engineering_patterns, kairoschain_meta_philosophy, synoptis_attestation]
---

# Loop Validation — mechanical verdicts for agent loops

Distilled from the Autonomous Growth Loop governance design v0.3.1 (FROZEN
2026-07-03, 3-round multi-LLM review; `docs/drafts/autonomous_growth_loop_governance_design_v0.3_draft.md`)
and its slice-1 implementation, live-proven the same day. Realizes candidate A
of the loop-engineering keystone analysis (L2
`loop_engineering_validation_keystone_20260621`): the single self-scoring that
closes a loop. Sibling: [[loop_engineering_patterns]] (§B "encode verification
as a skill" — this entry is that skill).

## When to reference this entry

- Wiring ANY loop's success judgment (agent OODA REFLECT, autonomos cycles,
  external-body wrappers, one-shot semi-automation of a checkable task).
- Authoring an evidence spec for a run, attended or unattended.
- Deciding where a cycle's outcome record belongs (attestation vs Meta Ledger).
- Not for: outcomes that no command can decide (aesthetic/philosophical
  quality) — that is judge-session / multi_llm_review territory; and not for
  loop TYPE selection → [[loop_engineering_patterns]] §A.

## Core discipline (body-agnostic)

The acting LLM's self-report is never evidence. A verdict consumes only
mechanically observable results, and absence of evidence never defaults to a
pass. Five rules:

1. **Declare before the run.** An evidence spec (JSON object) is authored
   before the work starts: `task_ref`, optional `workdir`, and `checks[]` —
   each `{name, command, timeout?}` where exit 0 = pass. The acting session
   never authors or edits the spec that will judge it.
2. **Verdict is mechanical and fail-closed.** All checks exit 0 → `success`;
   everything else → `non_success`. The engine's fail-closed reasons, each
   verified by execution and mirrored one-to-one in its output `reason`
   field: `no evidence spec argument`; `spec unreadable` (file I/O or
   JSON-parse failure — an empty file is readable but unparseable and lands
   here); `spec is not a JSON object`; `empty or non-list check list`;
   per-check `check entry is not an object`, `missing command`, non-zero
   exit, timeout; and a residual `engine exception` catch-all. Two of these
   paths have additionally fired in production: a non-zero-exit check caught
   the slice-1 false self-report, and an accidentally empty spec fail-closed
   a later cycle. The engine always exits 0 and always emits the same JSON
   keys — the verdict lives in the output, so callers cannot confuse engine
   failure with check failure.
3. **Pin the criteria.** The spec's sha256 is part of the verdict record:
   WHICH criteria judged the run is itself auditable. Two runs judged by the
   same pinned spec are comparable; a criteria change is a visible event —
   and note it is a *norm* change (rule-change provenance in the sense of
   L0 `kairos.md` §Minimum-Nomic, governed by the design's INV-8/9
   asymmetry), not an execution event; its own ledger classification is
   future `validation_rubric` work.
4. **Record as event, not as capability change.** A cycle's cost + verdict
   changes no L0/L1 skill — it is an execution event, so its home is the
   **attestation subsystem** (issuer-committed, verifiable, revoke leaves a
   trace), NOT the Meta Ledger. The Meta Ledger is reserved for skill changes
   the cycle actually causes. Implemented and live-verified 2026-07-03:
   cycle events issue `attestation_issue(subject_ref:
   "cycle://<body>/<session>", claim: "cycle_verdict_<verdict>", actor_role:
   "automated", long ttl)`, with the **full verdict JSON — including
   `spec_sha256` — carried in the attestation's `evidence` field**, which is
   how rule 3's pin reaches the record; the Meta Ledger stayed untouched
   across the verifying cycles. TTL expiry ends the window in which
   verification reports the claim currently valid — the signature and the
   record persist in the append-only registry, so expiry is never deletion.
   Do not conflate the two ledgers.
5. **No silent unattended pass.** A run without a spec is attended-only; its
   verdict is recorded as `none_attended`, explicitly, with the same
   constant keys — never omitted, never defaulted to success. Unattended
   operation requires more than this entry provides: the design's §5 gate
   (full judgment track INV-1→INV-3 including INV-6's verdict half, plus the
   guard track with a human-authored mandate, INV-10), the spec outside the
   acting body's write reach (INV-1), and the record store append-only
   outside that reach (INV-6). The reference engine alone satisfies none of
   these; until they ship, runs are attended.

## Reference engine

`scripts/kairos_verdict.py` (plain Python 3 stdlib, no LLM, no framework):

```
python3 scripts/kairos_verdict.py <spec.json>
# → single JSON object, ALWAYS these keys (null where unknown):
#   {verdict, reason, checks[], spec_sha256, task_ref}
```

Engine parameters that matter to record consumers: per-check timeout
defaults to 120 s (overridable per check); captured stdout/stderr are
truncated to 200 chars each — evidence in the record is a head, not the
full output. The engine reads only `task_ref`, `workdir`, and `checks`;
all unknown spec keys are ignored, so `_`-style note keys are safe (JSON
has no comments).

`assets/example_spec.json` is a working, instance-local example (absolute
paths deliberate, per the guidance below; placeholder-ize on promotion).
Spec authoring guidance: check the artifacts the body is SUPPOSED to produce
(files, test exits, line counts, chain deltas) from OUTSIDE its narrative;
give bodies absolute paths in the task text AND use absolute paths in check
commands — relative paths diverge when the body's shell cwd is stale, and
`workdir` alone protects only the engine's cwd, not the body's.

## Canonical evidence (why this exists)

First live cycle, 2026-07-03, hermes sandbox: the body reported "Done.
Created… exactly 3 lines… No other files were touched" — but had written the
file into a different repository (stale persistent-shell cwd). The mechanical
checks returned `non_success`; the confident false self-report never reached
the record. The absolute-path re-run passed, with the same `spec_sha256` in
both records proving the same pinned criteria judged both runs. One cycle,
both directions demonstrated: false-positive caught, true-positive passed.
(These two verdicts were recorded pre-R-1 to the sandbox Meta Ledger.)
Later the same day, the corrected rule-4 recording path was verified live
with two further cycles: registry proofs `aa20e3fa` (an accidentally empty
spec → fail-closed `non_success` via the unreadable-spec reason) and
`db4b6e79` (a passing run → `success`) were issued as attestations while
the Meta Ledger block count stayed unchanged.

## Layer placement

This entry = methodology + portable reference engine (body-agnostic; hermes,
Claude Code, codex, or a bare shell can all be the body — see
`references/hermes_adapter.md` for the one wired body, instance-local). Loop
WIRING (verdict inside the agent REFLECT phase, the `active_observe` seam) is
Agent/autonomos SkillSet territory, not this entry. Evolution of WHAT counts
as good (rubric/threshold revision) is governed by the design's norm-change
asymmetry (INV-8/9): the acting loop may propose spec changes, never apply
them to itself; keystone candidate B (`validation_rubric`) is the future
home — including where a norm change's *rationale* is recorded, beyond its
detectability in the `spec_sha256` lineage.

## Related

[[loop_engineering_patterns]] · [[synoptis_attestation]] (the event-record
subsystem rule 4 targets) · [[kairoschain_meta_philosophy]] (Prop 5
constitutive recording) · L0 `kairos.md` §Minimum-Nomic (rule-change
provenance) · design: `docs/drafts/autonomous_growth_loop_governance_design_v0.3_draft.md`
(FROZEN v0.3.1) · handoff L2: `handoff_autonomous_growth_loop_slice1_20260703`
(incl. R-1 attestation correction, R-2 loop/body end-state) · keystone L2:
`loop_engineering_validation_keystone_20260621` · improvement candidates L2:
`agent_skillset_loop_design_improvement_candidates` (candidate 1 = the REFLECT
integration this entry feeds).

## Changelog

- **v0.4 (2026-07-03)**: R2 response (REVISE, 3/6). Constant-key contract
  made true on the attended path too (wrapper's `none_attended` literal
  gained `task_ref`). Engine regained a distinct `spec unreadable` reason
  for file-I/O/JSON-parse failures (v0.3's hardening had folded it into
  `engine exception`, desynchronizing rule 2's taxonomy from the
  implementation); rule 2 now mirrors engine reasons one-to-one and credits
  both production-fired paths. Minimum-Nomic attributed to L0 `kairos.md`
  (the meta-philosophy L1 lacks the term). Rule 4 states the attestation
  `evidence` field carries the full verdict JSON incl. `spec_sha256`
  (binding rule 3's pin to the record). TTL wording refined. Rule 5's
  INV-1/INV-6 attribution made precise. Unknown-keys wording generalized.
  Both engine copies synced; all paths re-verified by execution.
- **v0.3 (2026-07-03)**: R1 response (REVISE, 3/6). Engine hardened against
  malformed spec shapes; constant keys on every path; example spec absolute
  paths + promotion note; §5 gate cited in full; proof attribution
  corrected; engine parameters documented; pre-R-1 markers in adapter.
- **v0.2 (2026-07-03)**: Rule 4 implemented — wrapper switched to
  `attestation_issue`, live-verified. Related adds [[synoptis_attestation]].
- **v0.1 (2026-07-03)**: Initial distillation of design v0.3.1 slice 1.
