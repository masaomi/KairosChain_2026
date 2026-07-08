# Attended Orchestrator Skill — Prototype B (v0.1, instance-local)

> **Status**: PROTOTYPE / attended / sandbox. Instance-local, NOT committed to
> KairosChain, NOT a formal L1 SkillSet (selective survival — see
> `resume_autonomous_growth_loop`). This is the "glue" the loop was missing:
> the orchestrator procedure that turns a human request into a governed
> multi-sub-goal `kairos_loop` pipeline.
>
> **Provenance**: authored 2026-07-07 after 段2 (pipeline composition observed).
> Codifies the orchestrator role that was performed by hand for the `pipeGrant`
> pipeline in that experiment. Invariant source:
> `governed_loop_orchestration_invariants` v0.3 FROZEN.

## What this is (and is not)

KairosChain's autonomous loop (`kairos_loop.py`, hermes body) has no context of its
own — the body sees only the hermes SOUL plus the task text it is handed. Someone
must stand at the boundary and supply what the body lacks: context, layer
information, decomposition, and qualitative judgment. That someone is the
**orchestrator** (Claude Code under Masa Mode) together with the **human**. This
prototype is the documented procedure for that role, plus a thin driver script for
its one mechanical step.

It is **not** an unattended auto-runner, **not** an L0/L1 self-modification path,
and **not** a quality judge. Those are explicitly out of scope and gated.

## The two halves and where they live

| Half | Home | Status |
|------|------|--------|
| (a) translate + decompose + launch | orchestrator (this procedure) + `kairos_orchestrate.py` for the launch mechanics | new (this prototype) |
| (b) monitor logs / cycle verdicts | existing subagent `agent-monitor` (`.claude/agents/agent-monitor.md`) | reused |

## Procedure (7 steps) mapped to invariants

| # | Step | Who | Mechanical or judgment | Invariant |
|---|------|-----|------------------------|-----------|
| 1 | Translate the human request into a self-contained abstract goal | orchestrator | judgment | INV-3 (executor gets only boundary-supplied context) |
| 2 | Decompose into ordered sub-goals with explicit dependencies | orchestrator + human | judgment | INV-4 (the **boundary** decomposes; the loop never splits a goal internally) |
| 3 | Author a mechanical, self-contained acceptance spec per sub-goal; pin **absolute-path** executors | human / verifier | judgment (authoring) | INV-4 (mechanical + self-authorable), B2 (independent criteria), **F-B lesson** |
| 4 | Launch `kairos_loop` per sub-goal into one shared run dir, in dependency order; halt on any non-`goal_achieved` | driver = `kairos_orchestrate.py` | **mechanical** | INV-6 (fail-closed) |
| 5 | Monitor logs, summarize cycle verdicts, flag anomalies | `agent-monitor` subagent | mechanical (observe) | — |
| 6 | Qualitative gate: "is the composed output good enough?" | **human** | judgment | INV-5 (actor never judges itself; quality = human) |
| 7 | Record run provenance, verdicts, composition evidence at the boundary | orchestrator | mechanical (record) | INV-1 (record writes only at the boundary) |

**Design crux**: steps 2 and 6 (decomposition, quality gate) are judgment and stay
with human + orchestrator. Only step 4 is automated. The script judges nothing
qualitative — its only verdict is the loop's own mechanical `stop_reason`.

## The driver script (`kairos_orchestrate.py`)

Lives next to `kairos_loop.py` in the hermes fork (`hermes-agent/kairos_body/`,
non-committed). It:

- takes a **human-authored pipeline spec** (ordered `sub_goals`, each with its own
  `goal` text and human `goal_spec` — B2);
- launches `kairos_loop` per sub-goal into a **shared run dir** so a later sub-goal
  can read an earlier one's artifact (composition, INV-4);
- **fail-closes** (INV-6): a sub-goal that does not reach `goal_achieved` halts the
  pipeline; dependent sub-goals are skipped, never run on a broken input;
- enforces the **F-B guard**: refuses acceptance checks that call a bare
  `python3`/`pytest` (which resolve against the confined PATH and false-negative),
  unless `--allow-bare-exec` is passed. This operationalizes the cheap guard
  "verifier must pin an absolute executor".

It does **not** decompose goals and does **not** judge output. `--dry-run`
validates a pipeline spec without spending any API budget.

## Safety posture (unchanged)

- Attended only. Sandbox chain only (kairos_loop enforces this). Separate billing.
- No unattended mode. No L0/L1 self-modification. Both remain design-gated OFF.
- The qualitative gate (step 6) is a human, always. The body never self-scores.

## Named deferrals (not built in v0.1)

- No automation of steps 1/2 (translation, decomposition) — these stay LLM+human.
- No automatic step-7 recording — the orchestrator records by hand (context_save).
- `agent-monitor` invocation is manual (the orchestrator spawns it) — not wired
  into the driver.
- Not promoted to an L1 SkillSet. Promote only after the prototype survives repeated
  attended use (selective survival).

## B-2 result (2026-07-08): driver reproduces the hand-run

`pipeGrantB2_20260708` (spec: `specs/pipeGrantB2_20260708_pipeline.json`) ran the
grant pipeline through the driver: SG-1 and SG-2 both `goal_achieved` (1 cycle,
7/7 checks each), composition anchors and un-forced inheritance ("Streamable
HTTP", `AbstractSyntaxTree`) reproduced. Dogfood finding: sub-goals sharing one
`run_id` **collide on cycle records** (`records/<run_id>/cycle_1.json` and
`loop_result.json` keep only the last sub-goal — provenance loss vs INV-1; the
pipeline verdict itself is unaffected because the driver reads each result
immediately). Known F2 re-observed (cost meter 0.0 on sonnet-5). L2:
`orchestrator_B2_dogfood_launcher_reproduces_handrun_20260708`.

## B-2b result (2026-07-08): record collision fixed at the driver

The loop (impl FROZEN) is untouched; the fix is boundary-side (INV-1 — recording
is the boundary's job). After reading each sub-goal's result, the driver moves
`loop_result.json` → `loop_result_<SG>.json` and `records/<run_id>/cycle_*.json`
→ `records/<run_id>/<SG>/`. Two fail-closed guards added: a stale
`loop_result.json` before launch (would be misread as the new sub-goal's result
if the loop dies before writing — a latent fail-open B-2 exposed), and a
pre-existing records stash. 7 driver tests (`test_kairos_orchestrate.py`,
loop stubbed, no API): stash correctness for 2 SGs, stale-result fail-closed,
stash-collision fail-closed, halt keeps failed-SG evidence, B2/dependency/F-B
guards. The per-SG run-id-suffix alternative was rejected: the run dir derives
from run_id, so it would break the shared run dir = the composition mechanism.
Note: the B-2 run's own SG-1 record was already overwritten (unrecoverable);
its on-disk evidence stays as-is, documented in the B-2 L2.

## B-3 result (2026-07-08): step 5 wired — pipeline summary + loop-monitor

Two pieces, replacing the original "reuse agent-monitor" plan. Dogfood found a
**layer mismatch**: `agent-monitor` reviews KairosChain agent-skillset sessions
via MCP tools (`agent_status` / `autonomos_status` / `chain_history`); a hermes
pipeline run's evidence is files (logs, cycle records, loop results) — a
different layer needing different instruments.

1. **Driver increment** — the driver now persists `pipeline_result.json` into
   the run dir on every completed pipeline (success AND halt; not on dry-run):
   status, per-SG results, spec sha256, per-SG evidence paths. The monitor and
   the record step read this file, not the orchestrator's memory of stdout
   (INV-1). 8 driver tests green.
2. **New subagent `.claude/agents/loop-monitor.md`** (read-only; sibling of
   agent-monitor, per-layer instruments): reads pipeline_result / loop results /
   launch-log pin lines / cycle-record check exits; flags non-goal_achieved,
   F2 cost==0.0 (always), missing evidence, missing pin lines, breach/tamper
   lines; verdict is `evidence-complete | investigate | rerun`. It judges
   evidence integrity ONLY — quality stays the human gate (INV-5).

Dogfood (on the pre-fix B-2 run, monitor prompt run inline via a read-only
agent): the monitor independently rediscovered, from evidence alone, both the
record collision that B-2b fixed and the F2 cost fail-open, plus one new note
(believe_done advisory=False vs verdict=success on both SGs), and correctly
answered `investigate`. Step 5 now has teeth: a future run missing pins or
evidence will be flagged mechanically.

## B-4 result (2026-07-08): goal-spec authoring helper

`kairos_goalspec.py` (next to the driver, non-committed): turns a declarative
typed check list (`file_exists` / `grep` / `grep_all` / `word_count_min` /
`pytest` / `raw`) into a goal-spec JSON whose commands pin absolute-path
executors **by construction** — the F-B guard cannot fire on its output. It is
a pen, not a judge: step 3 (what to check) stays a human/orchestrator judgment;
the helper only removes the mechanical way that judgment used to go wrong.
Fail-closed on relative paths, unknown types, duplicate names, and fragile
`raw` commands (same fragility rule as the launcher, kept in sync). 7 tests,
including executing every emitted command against a real file in both the
passing and the failing direction; 15/15 green with the driver regression.

## Full-kit run (2026-07-08): all seven steps with the complete kit

`pipeRomanKit_20260708` (roman-numeral module + composed pytest suite): decl →
helper → `goal_spec_path` (specs now live OUTSIDE the body-writable run dir,
closing the B-2 placement note) → launcher (B-2b stash + B-3 summary worked
live for the first time — SG-1's cycle record survived) → `loop-monitor`
spawned **by name** (verdict: evidence-complete, cross-references verified) →
human gate materials presented → recorded. Both SGs goal_achieved (1 cycle;
5/5 and 6/6 checks, pytest 5 passed). Strongest composition evidence so far:
SG-2's tests cover SG-1's own "bool explicitly rejected" design decision,
present in neither SG-2's task text nor its checks. The end-to-end pass also
found and fixed one new fail-open: the F-B guard scanned only inline
goal_specs, not `goal_spec_path` files — now both, unreadable path
fail-closed, 16 driver tests green. F2 (cost 0.0) flagged for the third
consecutive run. L2: `orchestrator_fullkit_run_pipeRomanKit_20260708`.

## Next increments (candidates)
- F2 cost-meter fail-closed (three consecutive runs flagged — rising priority).
- Promote to an L1 SkillSet only after repeated attended use (unchanged;
  current record: 2 real pipeline runs + 1 full-kit pass).
