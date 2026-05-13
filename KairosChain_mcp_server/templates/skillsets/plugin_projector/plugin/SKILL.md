---
name: plugin_projector
description: >
  Manage Claude Code plugin projection from KairosChain SkillSets.
  Use when checking projection status, forcing re-projection, or verifying integrity.
---

# Plugin Projector

Projects KairosChain SkillSet artifacts to Claude Code plugin structure.

## Recommended Workflow

### Check Status
`plugin_project command="status"` — current projection mode, timestamp, output count

### Force Re-Projection
`plugin_project command="project" force=true` — re-project all artifacts regardless of digest

### Verify Integrity
`plugin_project command="verify"` — check if projected files match the manifest

## Automatic Projection

Projection runs automatically:
- On MCP server initialization (handle_initialize)
- After skill changes (skills_promote, skills_evolve, etc.) via hooks
- After SkillSet exchange (skillset_acquire, skillset_withdraw) via hooks

Run `/reload-plugins` after projection to activate new skills in Claude Code.

## Cross-Project Projection (`kairos-chain mode project`)

Project an instruction mode from one KairosChain data directory into a *different* consumer project root.

### Command shape

```
kairos-chain mode project \
  --data-dir   /path/to/source/.kairos \
  --project-root /path/to/consumer_project
```

- `--data-dir`: where the mode body is read from (`<data-dir>/skills/<active_mode>.md`).
- `--project-root`: where `CLAUDE.md` and `.claude/kairos/instruction_mode.md` are written.
- When `--data-dir` points outside the consumer workspace, `--project-root` is **required** (no plausible cwd default). `data_dir == project_root` is refused (`CoincidenceRefused`, v3.26.0).

### Which mode gets projected

The active mode is **not** chosen by the CLI — it is read from `instructions_mode` in `<data-dir>/skills/config.yml`. If that says `tutorial`, tutorial is projected even when `masa.md` exists in the same `skills/` directory.

To switch the active mode before projecting:

- Preferred: `instructions_update(mode: "masa")` MCP tool (records to blockchain).
- Direct: edit `instructions_mode:` in `<data-dir>/skills/config.yml`, then re-run `mode project`.

### Drift between config and artifact

`<data-dir>/skills/config.yml` (`instructions_mode`) and `<consumer>/.claude/kairos/instruction_mode.md` can diverge silently if `mode project` is not re-run after a config change. The CLI output line `mode : <name> v<ver>` is the authoritative record of what was last projected — compare it against `instructions_mode` to detect drift.

### After projection

Restart Claude Code in the consumer project. CLAUDE.md `@-imports` resolve only at session start; mid-session edits to the projected artifact do **not** reach Agent tool sub-agents.

## Available Tools

<!-- AUTO_TOOLS -->
