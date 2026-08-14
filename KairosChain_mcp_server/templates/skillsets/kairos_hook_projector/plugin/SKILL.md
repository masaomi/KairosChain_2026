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

1. `mode_hooks_add mode="<mode>" gate="readable_gate"` writes
   `<mode>.mode_hooks.json` beside the mode body — creating it, or appending
   to it; an entry with the same gate already on the event is refused, never
   overwritten. Omitting `mode` targets the active mode, and on a stock init
   that is `tutorial` — a gem-shipped template body carrying no
   readable-output norm — so name your mode. The entry comes from the
   catalogue (`mode_hooks/_EXAMPLE.json`): event, section, blocking, and
   starting params. Tune the numbers in the written file afterwards, they are
   the mode's own — and edit `section` to a heading your mode body actually
   contains: it is copied from the catalogue, it is a claim about your own
   text, and the gate quotes it verbatim in every block reason. Called
   without `gate` it lists the catalogue and writes nothing. It stops at the
   declaration and never touches `.claude/settings.json`.
2. Or by hand, for someone who wants to write the numbers themselves: copy
   `mode_hooks/_EXAMPLE.json` beside your mode body as
   `<mode>.mode_hooks.json` (e.g. `.kairos/skills/masa.mode_hooks.json`),
   then edit `mode_name` inside it to `<mode>` — filename and field must
   agree — edit `section` to a heading your mode body actually contains (the
   gate quotes it verbatim in every block reason), and replace the example
   numbers with your own.
3. `mode_hooks_validate` reports what the declaration still needs.
4. `mode_hooks_project` proposes by default and writes nothing; to install,
   call again with `apply=true` and the `confirm_sha256` from the proposal.
5. `mode_hooks_validate`, run again, answers whether the gate is installed:
   its `installed` check compares declaration and `.claude/settings.json`.

The catalogue is gem-shipped and is not an extension point on the instance:
`system_upgrade` overwrites `mode_hooks/_EXAMPLE.json` on any reinstall — at
the same version, with no warning, without naming the file — so an edit to
the installed copy does not survive. Adding a gate kind is a core release
act: the catalogue entry, the kind in the compiler's known-gate table (until
then every call refuses it as `unknown_gate`), and the gate implementation
itself. Your declaration lives beside the mode body, outside the SkillSet,
for the same reason — the tool refuses to write declarations inside the
SkillSet directory because an upgrade would undo them.

## Removing a mode's hooks

Two routes, and either works: empty the declaration's `hooks` object
(`"hooks": {}`), or delete `<mode>.mode_hooks.json` entirely. Removal is an
apply like any other — run `mode_hooks_project`, then again with `apply=true`
and the new `confirm_sha256` — and it removes this mode's entries from
`.claude/settings.json`, leaving every other entry and key alone. The result
reports that settings.json was rewritten to the confirmed plan and asserts no
liveness in either direction; whether the gate is actually gone is
`mode_hooks_validate`'s question, the same as after an install.

`mode_hooks_validate` confirms it: a removed mode's `installed` check answers
`nothing_declared` — declaration installs no hooks, and none is installed.
Between the edit and the apply the same check reports the still-installed gate
under `stale` (verdict `STALE_INSTALLED`): the gate keeps running until the
apply.

Both routes leave the compiled configs behind under `.kairos/hook_configs/`.
Removal rewrites settings.json only, and neither the apply result nor
`mode_hooks_validate` mentions the leftover files. Nothing runs them once no
installed command names them; delete them by hand if you want them gone.

## Tools

- `mode_hooks_add` — write or extend a mode's declaration from the catalogue
  (`mode_hooks/_EXAMPLE.json`); append-only, stops at the declaration, never
  touches `.claude/settings.json`. Without `gate`, lists the catalogue.
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
