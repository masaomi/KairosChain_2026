---
name: skillset_creator
description: >
  Scaffold and design new SkillSets. Use when creating new SkillSet packages
  with tools, knowledge, and optional Claude Code plugin artifacts.
---

# SkillSet Creator

Create new SkillSet packages with scaffolding and design review.

## Recommended Workflow

### Preview Before Creating
1. `sc_scaffold command="preview" skillset_name="my_skill"` — see the directory structure
2. Review the structure, adjust tools/knowledge names

### Generate
1. `sc_scaffold command="generate" skillset_name="my_skill" output_path=".kairos/skillsets" tools=["my_tool"] has_plugin=true`
2. Edit the generated files (skillset.json, tools, SKILL.md)
3. `sc_review` — design review of the SkillSet

### With Plugin Support
Add `has_plugin=true` to include a `plugin/` directory with:
- `plugin/SKILL.md` — Claude Code workflow guide template
- `plugin/agents/` — sub-agent definitions (optional)

## Available Tools

<!-- AUTO_TOOLS -->
