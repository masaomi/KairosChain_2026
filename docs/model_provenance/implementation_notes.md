# model_provenance v0.1.0 — implementation notes (2026-09-24)

Design: `docs/model_provenance/design_v0.3.md` (frozen after 2 design rounds). Implementation reviewed in 2
conformance rounds (`impl_r1_artifact.md`, `impl_r2_artifact.md`; raw seat outputs in
`impl_r1_raw/`, and the round-2 collect result in this session's tool output).

## Where the implementation settles something the design left to § 7

- Run boundary: a subagent run starts only at a user record with `origin.kind` in
  {coordinator, peer} that is not `turnCompanion`. Measured on 389 local subagent
  transcripts: companion records (Skill body, image caption, empty-output nudge) carry no
  `origin`; task notifications carry `task-notification`; 35 coordinator/peer resumes.
- A run start explains a model change but does not end a fallback stretch.
- `/model` counts only in the main transcript, as a command message or a
  `local_command` "Set model to" record.
- Observer state (all cursors, shown causes, announced flag) is one file per session,
  `observer_state.json`, replaced by a single rename; an unreadable state file restarts
  observation with a one-time note instead of failing every Stop.
- Observation records carry `schema: 2`. Records written by the review-time reader
  (no schema; it misread Skill bodies as resumes) stay in the append-only store but are
  never resolved.
- Binding resolution: exact agent id from the file name; the newest record decides
  whether the state is known (unreadable → unobserved; itself unobserved → that answer);
  otherwise the latest run, complete before incomplete.
- The projected command guards itself: with neither `KAIROS_DATA_DIR` nor
  `CLAUDE_PROJECT_DIR`, a variable NAMED `CODEX*` (checked by ruby, the same test the
  script uses) → silent exit 0; otherwise exit 1 with the cause.

## Review outcome

| Round | Opus 4.6 CLI | gpt-6-astra | composer-2.5 | Opus 5.5 personas |
|---|---|---|---|---|
| impl R1 (C1–C21) | SKIP (timeout 600 s) | REVISE | REVISE | REVISE (3) |
| impl R2 (R1-D1..D13, K1–K11) | APPROVE | REVISE | APPROVE | REVISE (2) |

R1: 13 distinct defects with reaching inputs → fixed in U1–U5. R2: remaining findings
(commit ordering under I/O failure, corrupt state file, incomplete-record supersession,
unsafe-id key, host-guard name check, local_command scope) → fixed in F1–F5 plus record
versioning. The F-fixes were not put through a third review round (operator standing
rule: 1–2 rounds, then measure); they are covered by tests and a mutation check.

Tests: model_provenance 59 runs (hook command, store, observer, reader); multi_llm_review
567 runs in both copies. Mutation checks: 10 + 7 + 14 + 8 + 1 mutants, all killed except
two equivalent ones noted in the session (a doubled text-sanitising step).

## Known limits (not fixed; for the queue)

- Running workflow agents are not listed in `background_tasks` (the task id is the
  workflow's), so Stop may read one mid-run; its backstop record can describe a partial run
  until a later record supersedes it.
- Under `--agent`, Claude Code's internal agents report the session's agent name rather than
  an empty `agent_type`, so SubagentStop still writes an unobserved record for them.
- Fork transcripts open with the parent's Agent tool_use record, counted as a response.
- A `task-notification` wake after a fallback is not a run start (0 of 25 in the corpus).
- A per-run record classifies the latest run from an empty state, so a run resumed on the
  fallback model records the models but no anomaly (persona divergence is still caught).
- `KAIROS_DATA_DIR` set without `CLAUDE_PROJECT_DIR` and no CODEX name → the script's own
  host check exits 1 (visible), not a silent no-op.
- `multi_llm_review_wait` reports `crashed: heartbeat_stale` about 6 minutes into a slow
  seat while the worker and the seat are still running (seen twice today; the Opus 4.6 seat
  then finished at 441 s). Separate defect in multi_llm_review; not touched here.
