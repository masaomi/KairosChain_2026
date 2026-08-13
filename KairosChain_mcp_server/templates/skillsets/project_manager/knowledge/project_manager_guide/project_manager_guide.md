---
name: project_manager_guide
description: Orientation note for the project_manager SkillSet — what it is, where its tools and invariants are defined, and which artifact is authoritative for what. Use when you need to know where a project_manager rule lives, not to learn the rule itself.
version: 0.3.0
tags: [project_management, digest, attestation, attention, orientation]
---

# project_manager SkillSet — orientation

A domain-neutral vessel for project and work-item management. Everything domain-specific (KairosChain
development, wet-lab research, generic software) enters as *content*, never as schema.

This note deliberately restates nothing. Each rule has one authoritative home, and duplicating them
here is how they drift.

## Where things are defined

| What | Authoritative source |
|---|---|
| Invariants INV-PM-1..7 (two-tier recording, human gate, meaningful touch, derived dormancy, single authority, layer discipline, data-model minimality) | `docs/drafts/secretary_project_manager_design_v0.5_FROZEN.md` |
| Tool names, arguments, and marker effects | the tool schemas themselves, surfaced in the projected Skill at `.claude/skills/project_manager/SKILL.md` (generated from introspection at projection time) |
| Item, project, and attention schema | `lib/project_manager/store.rb` |
| When the operator may be asked about attention, and what may be written into that record (the operator's own report only — never the agent's view of its own legibility) | `plugin/agents/secretary.md` § The attention record |
| Dormancy threshold and digest horizon | `config/pm.yml` |
| The secretarial disposition (how a report reads, what it proposes) | `plugin/agents/secretary.md`, projected to `.claude/agents/project_manager-secretary.md`. Carried by the sub-agent, not by this SkillSet |
| Why the disposition is a sub-agent rather than an instruction mode | `docs/drafts/project_manager_plugin_projection_draft_v0.7_FROZEN.md` (frozen 2026-07-26; the earlier numbered drafts are superseded) |

## What the tools do not carry

No disposition. The SkillSet *ships* one — `plugin/agents/secretary.md`, projected as a sub-agent —
but the tools neither read it nor require it: they work with no secretary present, and the secretary
is inert without them (INV-PM-2). Nothing in the tools or in this note names how a report should read
or what tone it should take. That belongs to whichever disposition an operator installs over these
tools, and one operator's temperament must not arrive as a property of the capability.

## Why this file sits where it does

The knowledge registry resolves a SkillSet-bundled entry as `knowledge/<name>/<name>.md`, and
`skillset.json`'s `knowledge_dirs` must name that directory. Deviating from the layout — a
differently-named directory, or a file called `SKILL.md` — leaves the entry listed but unreadable.
This note was in that state until 2026-07-27; the frozen design records the period when SkillSet
knowledge was unreachable altogether, which a core change on 2026-07-27 ended.
