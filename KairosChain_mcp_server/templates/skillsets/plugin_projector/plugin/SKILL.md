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

## Available Tools

<!-- AUTO_TOOLS -->
