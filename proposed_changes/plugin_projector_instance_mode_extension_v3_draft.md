---
title: plugin_projector — instance mode artifact type addition (v3)
status: draft for multi-LLM review (round 3)
audience: LLM reviewers (Codex, Cursor, Claude Code)
style: minimal delta to existing skillset
date: 2026-05-06
author: Masaomi Hatakeyama (drafted via Claude Code, Opus 4.7)
supersedes: plugin_projector_instance_mode_extension_v2_draft.md (REJECTed round 2 — over-scoped)
empirical_grounding: .kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/
---

# Scope correction (read first)

v2 was rewritten as a self-contained design with 12 invariants. Reviewers correctly observed that this expanded the review surface beyond what the change actually requires. v3 is recast as a **minimal delta to the existing `plugin_projector` SkillSet** — one new artifact type added to an established projection pipeline. All concerns about atomicity, idempotency, manifest tracking, stale cleanup, multi-writer behavior, path safety, host-file cooperative merging, and dual-mode (`:project` / `:plugin`) are inherited from the existing `KairosMcp::PluginProjector` (`KairosChain_mcp_server/lib/kairos_mcp/plugin_projector.rb`) without modification.

This draft proposes only what is specific to the new artifact type.

# What changes

`plugin_projector` gains one new projection target: the active instance mode body (Masa Mode, Tutorial Mode, …). After the change, projection produces:

- existing artifacts: SkillSet skills, agents, hooks, knowledge meta skill (unchanged)
- **new**: a flat materialized `.claude/kairos/instance_mode.md` and a managed region in project-root `CLAUDE.md` referencing it via `@`-import

# Why

Three observed gaps, recorded in `.kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/`:

1. **MCP `instructions` is truncated by the Claude Code harness.** Mode body's identity preamble lands; normative body does not. Prop 5 violation: recorded constitutive content ≠ operating constitutive content.

2. **Agent tool sub-agents do not inherit MCP `instructions`.** Sub-agents inherit project CLAUDE.md (including `@`-imported files) but receive no MCP server `instructions` block. The Persona Agent team — Reviewer 1 in this project's multi-LLM review — has been operating without the active instance mode entirely. This is the larger gap; it cannot be fixed by adjusting MCP truncation.

3. **CLAUDE.md `@`-import path is empirically privileged.** Theme A verification (round 2, fresh sessions) confirmed full body delivery up to 107KB to parent, `claude -p` subprocess, and Agent sub-agent, with no observable difference between Opus 4.6 and 4.7. Nested `@`-imports do **not** recurse (depth-1 only).

# How (delta)

## New artifact source

The `kairos-chain` mode registry resolves the active instance mode and exposes its body as a flat string (no `@`-import directives inside, per F2 of the verification log). The projector treats this body as a new artifact source, parallel to `plugin/SKILL.md` and `plugin/agents/*.md`.

## New projection target

Two outputs:

1. **`<output_root>/kairos/instance_mode.md`** — the flat mode body. Written via the existing `atomic_write` helper. Tracked in the existing `projection_manifest.json` as `{type: 'instance_mode', mode_id, mode_version}`.

2. **Managed region in project-root `CLAUDE.md`** — added by a new helper `write_instance_mode_to_claudemd!`, modeled on `write_hooks_to_settings!`. Region format:

   ```
   <!-- BEGIN kairos-chain:instance-mode _projected_by=kairos-chain -->
   @.claude/kairos/instance_mode.md
   <!-- END kairos-chain:instance-mode -->
   ```

   Merge semantics inherit from the settings.json hooks model: locate any existing region by marker, remove it, and append the freshly-built region. Bytes outside the markers are not touched. Atomicity uses the existing `atomic_write` (whole-CLAUDE.md tmpfile + rename), preserving I4-equivalent behavior.

   On removal (mode deactivation, SkillSet rebuild with no active mode), the region is removed via the same `cleanup_stale!` pathway already used for departed skills/agents — manifest tracks the region as a logical output; absence in current outputs triggers cleanup.

## Manifest entries

Two new entries in `projection_manifest.json.outputs`:

- the file path `<output_root>/kairos/instance_mode.md` with `{type: 'instance_mode', mode_id, mode_version}`
- the symbolic key `claudemd:instance-mode-region` with `{type: 'claudemd_region', mode_id, mode_version}` — written and cleaned up alongside the file

The existing `compute_source_digest` is extended to include `mode_id` and the registry record hash, so a mode change triggers re-projection through `project_if_changed!` without changes to the digest mechanism.

## MCP `instructions` migration

The MCP `instructions` payload is changed to:

- mode identity (id + version)
- a short reference (registry record hash + recommended retrieval path)

The full body is no longer sent over MCP. Backward compatibility surface: any consumer that reads `instructions` still gets identifying information and a pointer; non-Claude-Code consumers fetch the body from the registry directly. This addresses the only Prop 5 concern raised against single-channel delivery (round 2 C9): the recorded body remains reachable for any consumer, just not through the truncating channel.

# What is inherited (no new design)

The following are existing PluginProjector behaviors and are reused unchanged:

- **Atomic writes**: `atomic_write` (tmpfile + rename).
- **Idempotency**: `project_if_changed!` via `source_digest` comparison.
- **Manifest as external state**: `.kairos/projection_manifest.json` stores all hashes and output paths outside the projected files (no self-referential hash problem).
- **Stale cleanup**: `cleanup_stale!` removes files (and now regions) that disappeared from the manifest between runs.
- **Path safety**: `safe_path?`, `safe_name?`.
- **Cooperative host-file merging**: `_projected_by` tagging pattern from `write_hooks_to_settings!`.
- **Dual mode**: `:project` writes to `.claude/`, `:plugin` writes to plugin root. Instance mode artifact follows the same routing.
- **Hook-driven re-projection**: existing hooks (`skills_promote`, `skills_evolve`, `skillset_acquire`, `skillset_withdraw`) re-trigger projection. Mode changes will additionally fire on the existing initialization path and on a new `mode_activate` event (out of scope here; the projector reacts to whatever the registry resolves).

# Out of scope (explicit)

These are not addressed by this change. They apply equally to the existing PluginProjector and are not new concerns introduced by this extension:

- **Multi-instance projection** in a single project working tree — not supported by existing plugin_projector either; same scope.
- **Git worktrees** sharing `.git` but with separate working trees — same scope as existing plugin_projector.
- **Concurrent projector processes** — existing plugin_projector is single-writer per project; this change inherits that constraint.
- **`/init` clobber recovery** — the existing manifest + `project_if_changed!` already provides recovery via re-projection (force=true on demand). The marker hint comment inside the region tells a re-running `/init` (LLM-driven) what to preserve; preservation is best-effort, recovery is exact via re-projection.
- **Projector self-projection** (Prop 1 self-referentiality at the projector level) — open philosophical question, not part of this delta.

# Migration

After this change ships, the first projection run on a project produces both the file and the CLAUDE.md region. There is no separate migration step — `project_if_changed!` detects the new source digest and projects on the next trigger. Consent surface for first-time CLAUDE.md mutation is handled by the same channel as existing plugin_projector first-time `.claude/settings.json` mutation (whatever exists today is reused).

# Open questions

1. **Mode body size policy.** Theme A confirms 107KB delivery; the registry should refuse to materialize bodies above some threshold to keep CLAUDE.md per-turn token cost predictable. Suggested initial threshold: warn at 150KB, refuse at 256KB. Threshold is policy, not invariant.

2. **`.gitignore` default for `.claude/kairos/instance_mode.md`.** For personal modes (Masa Mode), the artifact is private and should not be tracked. For shared/team modes (Tutorial Mode), the artifact should be tracked. Recommended default: ignored. Operators override per-project.

3. **MCP pointer format.** What exactly does the trimmed MCP payload contain? Minimal proposal: `{mode_id, mode_version, registry_record_hash, retrieval_hint}`. Reviewers may suggest a more standard form.

# Verification record

- Theme A: `.kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/`. Validates `@`-import privilege parity at 107KB across parent / subprocess / sub-agent for Opus 4.6 and 4.7.
- Existing `KairosMcp::PluginProjector`: `KairosChain_mcp_server/lib/kairos_mcp/plugin_projector.rb`. All behavior cited as "inherited" is verifiable by direct code reference.
