---
name: core_or_skillset_guide
description: >
  Decision guide for determining whether a new capability should be
  implemented as a SkillSet (plugin) or requires KairosChain core changes.
  Use when starting any new feature development for KairosChain.
  NOT for non-KairosChain projects or for deciding between L0/L1/L2 layers.
version: "1.0"
layer: L1
tags: [meta, guide, architecture, decision, skillset, core]
---

# Core or SkillSet?

## Quick Decision

Ask these questions in order. Stop at the first "Core" answer.

| # | Question | If YES |
|---|----------|--------|
| 1 | Does this add new MCP tools? | **SkillSet** — use tool_classes in skillset.json |
| 2 | Does this need access to existing knowledge/context? | **SkillSet** — use KnowledgeProvider, ContextManager directly |
| 3 | Does this need Persona Assembly? | **SkillSet** — generate structured prompts (same as skills_promote) |
| 4 | Does this need new blockchain recording types? | **Might need Core** — evaluate case-by-case |
| 5 | Does this add a new layer concept (beyond L0/L1/L2)? | **Core change** |
| 6 | Does this modify tool registration mechanism? | **Core change** |
| 7 | Does this add new built-in extension hooks? | **Core change** |

## What SkillSets CAN Do

- Define new MCP tools (inherit from `KairosMcp::Tools::BaseTool`)
- Access `KnowledgeProvider`, `ContextManager`, `Chain` directly
- Bundle `knowledge/` for distribution with the SkillSet
- Register hooks: Safety policies, gates, filters, path resolvers
- Generate Persona Assembly prompts (same pattern as `skills_promote.rb`)
- Read/write to filesystem
- Use config files for customization

## What SkillSets CANNOT Do (Core Required)

- Add new tool registration mechanisms
- Modify SkillSet loading itself (`skillset.rb`, `skillset_manager.rb`)
- Add new layer types
- Change blockchain structure
- Modify MCP protocol handling (`http_server.rb`, `stdio_server.rb`)
- Add new built-in extension hooks

## CLAUDE.md Principle

> "Can this be a new SkillSet instead of core bloat?"
> Keep the DNA (core) simple.
> New requirements should become new SkillSets where possible.

## Common Patterns

### "I need a new MCP tool"
→ Always SkillSet. Create a class inheriting from `KairosMcp::Tools::BaseTool` and register it in `tool_classes`.

### "I need to read/write knowledge"
→ SkillSet. Use `KnowledgeProvider.new` with `add_external_dir` for bundled knowledge.

### "I need multi-perspective evaluation"
→ SkillSet. Generate Persona Assembly prompts (the tool returns a structured prompt; the LLM executes the evaluation).

### "I need to modify how SkillSets are loaded"
→ Core change. This modifies `skillset.rb` and `skillset_manager.rb`.

### "I need a new hook type"
→ Core change. But first check if existing hooks (register_gate, register_filter, register_path_resolver) can serve your purpose.

## Edge Cases

### Optional dependency on another SkillSet
Current core does not support `optional: true` in `depends_on`. Use runtime detection instead:
```ruby
def other_skillset_available?
  defined?(::OtherSkillsetModule)
end
```

### SkillSet knowledge not appearing in knowledge_list
SkillSet-bundled knowledge requires `add_external_dir` in the entry point. It is NOT automatically added to the global `knowledge_list`. This is by design: SkillSet tools access their own knowledge directly.
