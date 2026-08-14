---
name: kairos_hook_projector
description: >
  Project an instruction mode's declared hooks into .claude/settings.json.
  Declare per-mode gates, validate them — including against what is
  installed — and install them behind an explicit confirmation.
---

# Kairos Hook Projector

Stage 2: compile + validate + gated projection. A mode declares its own gate
thresholds in a mode_hooks document; the core ships the gate implementation
(`readable_gate`) and no thresholds of its own. Projection writes hook entries
into `.claude/settings.json` — marked `_projected_by`/`_mode`, so hand-written
hooks and other modes' entries are left alone — and per-gate config files
under `.kairos/hook_configs/`.

## Declaring hooks for a mode

Not auto-installed (not a core SkillSet): install it by name first —
`system_upgrade command="apply" approved=true names=["kairos_hook_projector"]`.

1. Copy `mode_hooks/_EXAMPLE.json` beside your mode body as
   `<mode>.mode_hooks.json` (e.g. `.kairos/skills/masa.mode_hooks.json`).
2. Edit `mode_name` inside it to `<mode>` — filename and field must agree —
   and replace the example numbers with your own.
3. `mode_hooks_validate` reports what the copy still needs.
4. `mode_hooks_project` proposes by default and writes nothing; to install,
   call again with `apply=true` and the `confirm_sha256` from the proposal.
5. `mode_hooks_validate`, run again, answers whether the gate is installed:
   its `installed` check compares declaration and `.claude/settings.json`.

## Tools

- `mode_hooks_validate` (read-only) — mode body vs declaration drift, compile
  resolvability, and declared-vs-installed divergence in both directions.
- `mode_hooks_project` — compile and install; touches only entries it placed
  for the named mode, and chain-records every apply before writing.
- `hooks_status` (read-only) — stage and declaration inventory (which
  mode_hooks documents exist, not what is installed), run under a pre/post
  hash+mtime assertion over `.claude/settings.json`; any drift fails the call.

## Schema

`mode_hooks/_schema.json` (JSON Schema draft-04). Required: `mode_name`,
`version`. Optional: `hooks`, `binding`, `not_gated`, and reserved
composition fields (`extends`, `conflict_policy`).
