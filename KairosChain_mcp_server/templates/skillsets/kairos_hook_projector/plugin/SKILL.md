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

v0.1 stage 0: skeleton + schema + `hooks_status` (read-only). Zero side effect,
structurally guaranteed via boot-time hash/mtime assertion on projection target
files (DoD-0-4). Later stages add compile / project / unproject / composition.

## Tools

### `hooks_status` (read-only)

Inspect current state of `kairos_hook_projector`. Reports stage, schema
location, and mode_hooks document inventory. Each invocation runs a pre/post
hash+mtime assertion over the watched projection targets
(`.claude/settings.json` and the SkillSet's own `plugin/hooks.json`); any
drift fails the call with `StructuralAssertionFailure`. This is the
structural side-effect-zero guarantee for stage 0, not a convention.

## Schema

`mode_hooks/_schema.json` defines the envelope for mode_hooks definitions
(JSON Schema draft-04). Required: `mode_name`, `version`. Optional: `hooks`,
plus reserved composition fields (`extends`, `conflict_policy`).

## Design

See `docs/drafts/kairos_hook_projector_design_v0.2_draft.md` (frozen).
