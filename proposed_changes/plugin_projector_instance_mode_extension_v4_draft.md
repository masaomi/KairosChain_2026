---
title: plugin_projector — instance mode artifact type addition (v4)
status: draft for multi-LLM review (round 4)
audience: LLM reviewers (Codex, Cursor, Claude Code)
style: design-only (no implementation surface)
date: 2026-05-06
author: Masaomi Hatakeyama (drafted via Claude Code, Opus 4.7)
supersedes:
  - v2 (round 2): over-scoped, 12-invariant rewrite of an existing pipeline
  - v3 (round 3): scope-corrected but slipped into implementation-level claims
        (specific helper names, paths, marker strings, code-reuse promises)
        that created surfaces for inconsistency findings
empirical_grounding: .kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/
---

# What this change is

`plugin_projector` gains one additional artifact type: the active instance mode body (e.g., Masa Mode, Tutorial Mode). The new artifact type is added to the existing projection pipeline alongside skills, agents, hooks, and the knowledge meta skill.

# Why

Three observed gaps, recorded in the Theme A verification log:

1. The current MCP `instructions` channel is truncated by the Claude Code harness; only the identity preamble of mode bodies lands. The recorded instance constitution and the operating instance constitution diverge — a Prop 5 violation.

2. Agent tool sub-agents inherit project CLAUDE.md but do not inherit MCP `instructions`. The Persona Agent team — Reviewer 1 in this project's multi-LLM review — has been operating without the active instance mode entirely. This is the larger gap and is not solvable by adjusting MCP truncation.

3. The CLAUDE.md `@`-import path delivers full content to all three surfaces (parent, `claude -p` subprocess, Agent sub-agent) up to at least 107KB, with no observable difference between Opus 4.6 and 4.7. Single-level only — nested `@`-imports do not recurse.

# Properties the addition must satisfy

The new artifact type is governed by the same projection contract as all existing artifact types. Specifically:

- **Privileged delivery.** The mode body must reach the model through a path empirically demonstrated to bypass the MCP truncation cap (Theme A). The MCP channel carries identity and a pointer to the recorded body; the body itself is delivered through the privileged path.
- **Contract parity.** The new artifact type is atomic, idempotent under unchanged source, manifest-tracked, cleaned up when removed from source, and audited identically to existing artifact types. No new contract, no exceptional path.
- **Single-level composition.** The body delivered to the privileged path is self-contained. Composition of mode bodies (shared preambles, includes) happens at registry resolution time, before the body enters the projection pipeline.
- **Scope inheritance.** Whatever scope the existing projection pipeline supports — single project working tree, single writer, no worktree split — the new artifact type supports the same. No more, no less.
- **Recorded reachability for non-privileged consumers.** Consumers that do not load CLAUDE.md (other MCP clients, headless tooling) must still be able to reach the recorded body through the registry. The truncation problem is solved for the privileged path; it is not papered over for other consumers — they retrieve from the registry directly.

# Out of scope (unchanged from existing pipeline)

The new artifact type does not introduce, and is not expected to address:

- multi-instance projection in a single project tree;
- git worktree topologies sharing `.git`;
- concurrent projector processes;
- automatic recovery from third-party rewrites of the host file the privileged path depends on;
- self-projection of the projector itself (Prop 1 self-referentiality at the projector level — open philosophical question).

These constraints apply equally to existing artifact types; the new type inherits them without modification.

# Migration

After this change, the active instance mode reaches three surfaces (parent, subprocess, sub-agent) through the privileged path. The MCP channel is reduced to identity and pointer once the registry confirms the projection regime is in effect for the project. Until then, the MCP channel continues to carry whatever it carries today (truncated body) for backward compatibility.

# Open questions (genuinely open, not deferred implementation choices)

1. **Body size policy.** The privileged path was empirically validated to 107KB. The registry should refuse bodies above some threshold to keep per-turn token cost predictable. The threshold itself is a policy decision.

2. **Personal vs shared mode bodies.** Some modes are personal (carry private constitution); others are shared (Tutorial). Whether the registry record carries this distinction, and whether the projection pipeline reads it for downstream policy (e.g., gitignore default for materialized files), is a registry-data-model question that this change does not decide.

3. **Pointer payload.** What identity and reference data the MCP channel carries after the migration. The minimum is enough for a non-privileged consumer to retrieve the body from the registry; the maximum is bounded by the truncation cap. The exact shape is open.

# Verification record

- Theme A: `.kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/`. Establishes that the privileged path delivers full content to parent, subprocess, and Agent sub-agent at 107KB on Opus 4.6 and 4.7, single-level only.
- Existing projection contract: `KairosMcp::PluginProjector` in this codebase. Implementation phase verifies all "contract parity" claims by direct reference; the design phase asserts only that parity holds.
