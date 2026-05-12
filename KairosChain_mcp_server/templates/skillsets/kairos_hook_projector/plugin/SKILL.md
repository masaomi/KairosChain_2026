---
name: kairos_hook_projector
description: >
  Compile mode_hooks definitions into the plugin_projector pipeline.
  Use to inspect mode_hooks status (read-only in stage 0).
---

# Kairos Hook Projector

Rides the existing `plugin_projector` pipeline as a compiler layer:
mode_hooks YAML → `plugin/hooks.json` → `.claude/settings.json` (via `plugin_projector`).

## Stage

v0.1 stage 0: skeleton + schema + `hooks_status` (read-only). Zero side effect.
Later stages add compile / project / unproject / composition.

## Design

See `docs/drafts/kairos_hook_projector_design_v0.2_draft.md` (frozen).
