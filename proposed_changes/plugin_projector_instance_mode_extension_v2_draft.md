---
title: plugin_projector — instance mode privileged injection extension (v2)
status: draft for multi-LLM review (round 2)
audience: LLM reviewers (Codex, Cursor, Claude Code)
style: design-by-invariant, anti-enumeration
date: 2026-05-06
author: Masaomi Hatakeyama (drafted via Claude Code, Opus 4.7)
supersedes: plugin_projector_instance_mode_extension_draft.md (v1, 2026-05-06)
empirical_grounding: .kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/
---

# Glossary (read first)

Three terms that v1 collapsed into "canonical location":

- **Registry record** — an immutable, content-addressable entry in the kairos-chain mode registry. Source of truth for what a mode *is*. Lives outside any project working tree.
- **Projected artifact** — a project-local file (`.claude/kairos/instance_mode.md`) materialized from a registry record. A delivery vehicle. May be deleted and re-projected; the registry record persists.
- **Reference** — the line inside CLAUDE.md's managed region that points the harness at the projected artifact (`@.claude/kairos/instance_mode.md`). Triggers the harness's `@`-import privilege.

Three Prop references the document depends on, restated for self-containment:

- **Prop 5 (constitutive recording)** — what the system records is what the system is. Recording is constitutive, not evidential. → applied via I9.
- **Prop 9 (partial autopoiesis)** — definitional closure at L0/L1; execution depends on external substrates. → frames I1 as a substrate dependency, not a violation.
- **Prop 10 (revisability from within)** — instance constitution is replaceable by the instance. → applied via I6.

# Problem (restated)

Two channels currently deliver instance mode normative content (Masa Mode, Tutorial Mode, …) to Claude Code; both are inadequate.

| Channel | Reach to parent | Reach to subprocess (`claude -p`) | Reach to Agent tool sub-agent |
|---|---|---|---|
| MCP `instructions` | preamble only (truncated) | preamble only (truncated) | **absent entirely** |
| (gap) | — | — | — |

Empirical: `.kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/`. The Persona Agent team — Reviewer 1 in this project's multi-LLM review setup — has been operating without masa mode. The Prop 5 violation is therefore not just "recorded vs. operating divergence in the parent" but "recorded mode never reached two of three execution surfaces."

The CLAUDE.md `@`-import path delivers full content to all three surfaces (parent, subprocess, sub-agent) at least up to 107KB, with no observable difference between Opus 4.6 and 4.7. v2 extends `plugin_projector` to use this path.

# Invariants

- **I1 (privilege parity, validated).** Active instance mode body reaches the model through the CLAUDE.md `@`-import path, which is empirically demonstrated to deliver full content to parent, subprocess, and Agent sub-agent up to 107KB. Bodies above the policy threshold are refused at projection time, not silently truncated.
- **I2 (registry primacy).** The registry record is source of truth. The projected artifact is a delivery vehicle, not a copy under separate authority. Drift between registry and projected artifact is a fail-closed condition.
- **I3 (idempotent projection as recovery).** Re-running projection on an unchanged registry produces a byte-identical projected artifact and a byte-identical CLAUDE.md region (after platform normalization). If either has been mutated by another writer (`/init`, human edit, merge), re-projection restores the canonical state without operator reasoning. Idempotency is the recovery mechanism, not just a no-op guarantee.
- **I4 (cooperative boundary).** Projector reads and writes only inside the marker-delimited region of CLAUDE.md. Bytes outside the markers are invariant under projection. CLAUDE.md is acknowledged as a cooperative artifact (humans, `/init`, merges, other tools may also write); the projector does not assert exclusive ownership.
- **I5 (mode-switch atomicity via write-then-rename).** Mode switching uses POSIX atomic rename for the projected artifact (`write to .tmp → rename over canonical path`) and a single file `write` for CLAUDE.md region replacement. The observable transition for the harness is the next CLAUDE.md read; between projection event start and end, the harness may load either pre- or post-state but never a partial state. Removal is excluded from I5 — it is a defined separate operation with its own observability contract (canonical file deleted before region body cleared).
- **I6 (revisability with explicit override).** Per Prop 10, the active mode is replaceable from within the instance. Where I10 (fail-conflict-surface) detects a region-hash mismatch caused by intentional human revision, the projector exposes a `--accept-external` (or equivalent) command that re-baselines the region to the current bytes plus a fresh chain record. Fail-closed must not become fail-permanent.
- **I7 (single-channel delivery, sub-agent reach mandatory).** When the CLAUDE.md route is active for a given mode, the MCP `instructions` payload carries only the identity tag (mode id + version). The full normative body reaches the model exclusively via the projected artifact + reference. Because Agent tool sub-agents inherit CLAUDE.md but not MCP `instructions`, this single-channel rule is the only configuration in which sub-agents receive the mode at all.
- **I8 (consent-on-creation, not on update).** First projection that mutates a CLAUDE.md previously containing no marker region — or that creates CLAUDE.md from scratch — requires an explicit user acknowledgment surface. Subsequent projections that only update region body do not re-prompt. Non-interactive contexts (CI, automation) consent via an instance-level config flag set out-of-band; the flag itself is auditable and revocable.
- **I9 (auditable delivery, not just auditable event).** Every projection emits a chain record (Prop 5) carrying: mode id and registry record hash; projected artifact content hash (after platform normalization); CLAUDE.md region hashes before and after; and a delivery probe outcome — a post-projection check that confirms a fresh sub-agent can read a known canary inside the projected body. Chain record proves delivery, not merely that the projector ran.
- **I10 (fail-conflict-surface, platform-normalized).** If the marker region's pre-state hash does not match the projector's last-known hash — after normalizing line endings (LF) and BOM stripping — projection halts and surfaces a conflict with three named resolutions: re-project (overwrite), accept-external (adopt current bytes, re-baseline), or abort. Silent overwrite is forbidden; silent halt without a recovery surface is forbidden.
- **I11 (single-level @-import).** The projected artifact must be self-contained. Further `@`-import directives inside the artifact are not expanded by the harness (empirically confirmed) and must not be present in registry records. Composition of mode bodies (shared preambles, includes) happens at registry materialization time, producing a flat artifact.
- **I12 (model independence within current generation).** Privilege parity (I1) holds identically for Opus 4.6 and 4.7 under measurement. The projector does not condition behavior on detected model. Future-model re-validation is required before the projector trusts a new generation.

# Mechanism (concise)

Marker region in CLAUDE.md:

```
<!-- BEGIN kairos-chain:instance-mode -->
<!-- Managed by plugin_projector. /init must preserve. Recovery: re-run plugin_projector. -->
<!-- mode-id: <id>  version: <semver>  registry-hash: <hex>  region-hash: <hex> -->
@.claude/kairos/instance_mode.md
<!-- END kairos-chain:instance-mode -->
```

Projection event sequence:

1. Resolve active mode → registry record.
2. Materialize flat artifact (no `@`-import inside) into `.claude/kairos/instance_mode.md.tmp`.
3. Atomic rename `.tmp` → `instance_mode.md`.
4. Compute new region body (header comments + `@`-import line). Read existing CLAUDE.md, locate-or-create region, compare existing region hash to last-known.
5. On hash match (or first-creation with consent): write CLAUDE.md region in place; emit chain record; run delivery probe (spawn ephemeral sub-agent, ask for canary, record outcome in chain).
6. On hash mismatch: halt with conflict surface (I10).

Removal is its own operation: delete `.claude/kairos/instance_mode.md`, then clear region body. Order matters: a window where region references a missing file is preferable to a window where mode body persists without governance.

# Risks (recast — none open)

| Risk (v1 label) | v2 disposition |
|---|---|
| R1 token budget | Folded into I1: policy threshold refuses oversized bodies. |
| R2 multi-instance | Marker namespace `<!-- BEGIN kairos-chain:<instance-id>:instance-mode -->`; multiple instances coexist, each owns a disjoint region. |
| R3 user edits inside region | Folded into I6 + I10: detected as conflict, recoverable via `--accept-external`. |
| R4 .gitignore policy | Out of mechanism scope; documented as an operator decision with sane default (`.claude/kairos/instance_mode.md` in `.gitignore` for personal modes). |
| R5 truncated-mode revalidation | Out of projector scope; addressed in Tutorial Mode SkillSet's own test plan. |
| R6 CLAUDE.md contested | Folded into I3 + I4: cooperative boundary + idempotent recovery. |
| (NEW) `/init` clobber | Covered by I3 + marker hint comment. Recovery is one re-projection. |
| (NEW) CRLF / line-ending drift | Covered by I10 normalization clause. |
| (NEW) sub-agent gap | First-class motivation; covered by I7. |
| (NEW) delivery vs event audit | Covered by I9 delivery probe. |

# Non-goals

The projector is not a CLAUDE.md general editor; write authority terminates at the marker. It is not a mode authoring tool. It is not a runtime hot-reload mechanism — projection is a discrete, recorded event. It does not adjudicate between competing modes (the registry is the source of activeness; projector consumes whatever the registry resolves).

# Migration

Existing MCP `instructions` payload is reduced to identity tag once the chain record from I9 confirms successful delivery for a given project. "Confirmed delivery" requires the chain record to include a positive delivery-probe outcome (I9), not merely a projection-occurred event. Absent that record, MCP retains the legacy (truncated) payload — backward compatibility is preserved, but the truncated state is the visible default until projection is run.

Sub-agent reach is the migration's primary user-visible improvement: after projection, Persona Agent team reviewers gain the mode body for the first time.

# Open questions for review

1. **Policy threshold for I1.** 107KB validated; what is the right warn / refuse threshold? Suggested: warn ≥ 150KB, refuse ≥ 256KB. Bias toward conservative until further empirical data.
2. **Delivery probe design (I9).** Spawning an ephemeral sub-agent on every projection adds latency. Is a once-per-session probe (cached) acceptable, or should every projection re-probe?
3. **Marker namespace under multi-instance (R2 disposition).** Is `<!-- BEGIN kairos-chain:<instance-id>:instance-mode -->` the right disambiguator, or should the marker reference the registry-record-hash directly?
4. **Removal order (I5 exclusion clause).** Delete artifact-then-clear-region, or clear-region-then-delete-artifact? The former errs toward "no governance" briefly; the latter errs toward "broken reference" briefly. Which is the safer momentary state?
5. **`--accept-external` re-baseline (I6).** Should adopting external edits emit a *new* chain record with the user as author, or a *transition* record marking the divergence? Prop 5 reconstructibility likely prefers the latter.

# Verification record

This v2 rests on the empirical observations recorded in `.kairos/context/session_20260506_071916_d34fad54/plugin_projector_theme_a_premise_verification_result/`. Reviewers should treat I1's claim as substantiated up to 107KB and unprobed above; F2 (nested @-import does not recurse) and F3 (sub-agent MCP gap) as observed facts; F5 (`/init` has no marker awareness) as confirmed by skill behavior inspection.
