---
name: kairoschain_self_development
description: "Self-referential development workflow: using KairosChain to develop KairosChain itself"
version: "1.2"
layer: L1
tags: [workflow, self-referentiality, development, dogfooding, meta, contributing]
readme_order: 5.5
readme_lang: en
---

# KairosChain Self-Development Workflow

KairosChain's own development uses KairosChain as its knowledge management layer.
This realizes structural self-referentiality (Proposition 7) at the development process level:
designing the system becomes an operation within the system.

## Setup

Initialize a `.kairos/` data directory in the project root:

```bash
cd KairosChain_2026
kairos-chain init
```

`.kairos/` is already listed in `.gitignore` — runtime data stays local,
while validated knowledge is promoted into the codebase via explicit commits.

## The Development Cycle

```
┌─────────────────────────────────────────────────┐
│  1. Develop with KairosChain                    │
│     - context_save (L2) for session work        │
│     - knowledge_update (L1) for discoveries     │
│     - skills_evolve (L0) for meta-rule changes  │
│                                                 │
│  2. Promote to codebase                         │
│     - Copy validated skills/knowledge from      │
│       .kairos/ to KairosChain_mcp_server/       │
│     - Edit core code directly when needed       │
│     - git commit                                │
│                                                 │
│  3. Reconstitute                                │
│     - gem build + gem install                   │
│     - kairos-chain upgrade                      │
│     - .kairos/ is updated with new templates    │
│                                                 │
│  (Loop: the upgraded system is used in step 1)  │
└─────────────────────────────────────────────────┘
```

Each commit is a Kairotic moment (Proposition 5): the system irreversibly
reconstitutes itself with knowledge discovered through its own use.

## Promotion Targets

When copying from `.kairos/` to the codebase, choose the correct destination:

| Source in .kairos/ | Destination | Effect |
|--------------------|-------------|--------|
| `knowledge/{name}/` | `templates/knowledge/{name}/` | Distributed to all users via `kairos-chain init` |
| `knowledge/{name}/` | `knowledge/{name}/` | Available in dev repo only |
| `skills/kairos.rb` changes | `templates/skills/kairos.rb` | Changes default L0 for all users |
| `skillsets/{name}/` | `templates/skillsets/{name}/` | New SkillSet available to all users |

For new patterns, start with `knowledge/` (dev-only). Promote to `templates/`
after the pattern has proven its value across multiple development cycles.

## Ordering Constraints

When a discovered pattern changes `kairos-chain init` or `upgrade` behavior itself:

1. Edit core code in `lib/` directly (not via `.kairos/`)
2. Run tests: `rake test`
3. Commit and rebuild gem
4. `kairos-chain upgrade` to apply changes to `.kairos/`

This avoids the chicken-and-egg problem where the tool you're upgrading
is the tool performing the upgrade.

## Philosophical Grounding

This workflow is a direct realization of several core propositions:

- **Proposition 5** (Constitutive Recording): Each commit constitutes
  a new version of the system's being, not merely documents it.
- **Proposition 6** (Incompleteness as Driving Force): Using KairosChain
  to develop itself inevitably reveals gaps — these gaps drive evolution.
- **Proposition 7** (Design-Implementation Closure): The design act
  (using KairosChain) and the implementation act (coding KairosChain)
  occur within the same operational structure.
- **Proposition 9** (Human-System Composite): The developer's metacognitive
  observations during self-referential use constitute the system's boundary.

## Instruction Mode: `self_developer`

A custom instruction mode (`self_developer`) is available for KairosChain development.
It extends the developer mode with self-development-specific behavior:

- Automatically loads `kairoschain_self_development` knowledge at session start
- References full L0 philosophy (`kairos.md`) via proactive tool usage
- Includes promotion guidelines and ordering constraints

Activate it via:

```
instructions_update(command: "set_mode", mode_name: "self_developer")
```

To revert to the standard developer mode:

```
instructions_update(command: "set_mode", mode_name: "developer")
```

## Future: Collaborative Self-Development

When multiple contributors join KairosChain development, the following
evolution is planned:

1. **Promote `self_developer` mode to templates**: Move `self_developer.md`
   to `templates/skills/` so it is distributed via `kairos-chain init`
2. **Replace the current `developer` mode**: Rename `self_developer` to
   `developer`, making the self-referential workflow the default for all
   KairosChain contributors
3. **Promote this knowledge to templates**: Move `kairoschain_self_development`
   to `templates/knowledge/` for distribution

This follows the standard promotion pattern: start in the dev repo (`knowledge/`),
prove value through use, then promote to `templates/` for all users.

## SkillSet Release Checklist

When a new SkillSet is implemented and tested, follow this checklist to release:

### 1. L1 Knowledge for README

Create L1 knowledge files (EN + JP) with `readme_order` and `readme_lang`
frontmatter so the SkillSet appears in the auto-generated README:

```
KairosChain_mcp_server/knowledge/{skillset_name}/
  {skillset_name}.md          # readme_order: N, readme_lang: en
KairosChain_mcp_server/knowledge/{skillset_name}_jp/
  {skillset_name}_jp.md       # readme_order: N, readme_lang: jp
```

Copy to templates for distribution:

```
KairosChain_mcp_server/templates/knowledge/{skillset_name}/
KairosChain_mcp_server/templates/knowledge/{skillset_name}_jp/
```

### 2. Regenerate README

```bash
ruby scripts/build_readme.rb          # or: rake build_readme
ruby scripts/build_readme.rb --check  # verify up-to-date
```

This reads all L1 knowledge files with `readme_order`/`readme_lang` frontmatter,
combines them with header/footer templates, and generates `README.md` + `README_jp.md`
at the project root.

### 3. Version and Changelog

1. Bump version in `lib/kairos_mcp/version.rb`
2. Add entry to `CHANGELOG.md` (follow existing format)
3. Commit all changes
4. Tag: `git tag v{VERSION}`

### 4. Gem Build and Publish

```bash
cd KairosChain_mcp_server
gem build kairos-chain.gemspec
gem install kairos-chain-{VERSION}.gem   # local test
gem push kairos-chain-{VERSION}.gem      # publish (after testing)
```

This checklist should be proposed automatically by the AI assistant in
`self_developer` mode when a SkillSet implementation is complete and tested.

## What This Is Not

- Not a requirement to use KairosChain for all development tasks.
  Use standard tools when they are simpler.
- Not a closed loop. External substrates (Ruby VM, git, gem infrastructure)
  remain outside the self-referential boundary. This is intentional
  ("sufficient self-referentiality", Proposition 1).
