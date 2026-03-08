---
name: creation_guide
description: >
  Guide for creating and structuring L1 knowledge in KairosChain.
  Includes the Kairotic Creation Loop workflow and 6 structural patterns
  extracted from practical skill analysis. Use when creating new L1 knowledge,
  restructuring existing knowledge, or analyzing structural patterns.
  NOT for SkillSet architecture decisions (use core_or_skillset_guide).
version: "1.0"
layer: L1
tags: [meta, creation, workflow, patterns, structure, knowledge]
---

# L1 Knowledge Creation Guide

## Kairotic Creation Loop

Six phases for creating L1 knowledge. The LLM navigates these naturally in conversation; this is a reference, not a rigid procedure.

| Phase | Action | Key Question |
|-------|--------|-------------|
| **RECOGNIZE** | Identify repeating pattern across sessions | Has this come up 3+ times? |
| **DISTILL** | Extract the reusable core from session context | What's universal vs. session-specific? |
| **STRUCTURE** | Choose appropriate structural pattern (see below) | What format best serves this content? |
| **COMPOSE** | Write with proper frontmatter and body | Does description include What + When + NOT? |
| **EVALUATE** | Apply quality_criteria via kc_evaluate | READY / REVISE / DRAFT? |
| **ITERATE** | Fix issues and re-evaluate | Are all critical dimensions PASS? |

## 6 Structural Patterns

### 1. Quick Reference Table
**When**: Any knowledge that maps inputs to outputs or actions to approaches.
Always place at the top of the document.

```markdown
| Task | Approach | Notes |
|------|----------|-------|
| New MCP tool | SkillSet tool_classes | BaseTool inheritance |
| New layer concept | Core change | Rare; requires L0 review |
```

### 2. Deterministic Workflow
**When**: Multi-step ordered procedures where sequence matters.

```markdown
## Workflow
1. Check prerequisites → verify X exists
2. Execute action → run Y with parameters
3. Validate result → confirm Z matches expected
```

### 3. Critical Rules / Pitfalls
**When**: Domain-specific gotchas that cause repeated errors.

```markdown
## Critical Rules
- **NEVER** do X because Y (evidence: Z happened when this was violated)
- **ALWAYS** check A before B (reason: C depends on A being initialized)
```

### 4. Multi-Tool Selection
**When**: Multiple valid approaches exist for the same goal.

```markdown
| Tool | Best For | Limitation |
|------|----------|------------|
| Tool A | Simple cases | Doesn't handle edge case X |
| Tool B | Complex cases | Slower, requires config Y |
```

### 5. QA-First Verification
**When**: Output quality matters and errors are costly. Assume problems exist.

```markdown
## Verification Checklist
- [ ] Output matches expected format
- [ ] No placeholder values remain (search for TODO, FIXME)
- [ ] Edge cases tested: empty input, large input, special characters
```

### 6. Session Distillation (L2→L1)
**When**: Promoting session-specific work to reusable knowledge.

```markdown
## Distillation Steps
1. Remove all session-specific references (dates, filenames, user names)
2. Generalize the procedure: replace specific instances with patterns
3. Add frontmatter with description that answers: What + When + NOT
4. Evaluate with kc_evaluate
```

## Pattern Selection Guide

| Content Type | Primary Pattern | Secondary Pattern |
|-------------|-----------------|-------------------|
| Decision guide | Quick Reference Table | Critical Rules |
| Step-by-step procedure | Deterministic Workflow | QA-First |
| Tool/approach comparison | Multi-Tool Selection | Quick Reference Table |
| Domain-specific warnings | Critical Rules | Quick Reference Table |
| Reusable from session | Session Distillation | (varies by content) |
| Mixed reference | Quick Reference Table | Deterministic Workflow |
