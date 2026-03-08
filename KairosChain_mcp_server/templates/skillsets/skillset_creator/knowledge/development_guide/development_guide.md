---
name: development_guide
description: >
  KairosChain SkillSet development workflow guide. Covers the 5-phase
  development meta-pattern (Design → Review → Revise → Implement → Verify),
  review escalation strategy, multi-LLM vs Persona Assembly decision guide,
  and review best practices. Use when starting SkillSet development,
  deciding on review level, or preparing review prompts.
  NOT for individual L1 knowledge creation (use creation_guide).
version: "1.0"
layer: L1
tags: [meta, workflow, skillset, development, review, multi-llm]
---

# SkillSet Development Guide

## Review Escalation (Decide First)

| Change Type | Review Level | What To Do |
|-------------|-------------|------------|
| New SkillSet / major architecture | **FULL** | All 5 phases with multi-LLM review |
| Core code modifications | **FULL** | All 5 phases with multi-LLM review |
| Knowledge-only or single-tool | **LIGHT** | Design → Persona Assembly → Implement |
| Bug fix / minor update | **MINIMAL** | Implement → commit |

**Default is LIGHT.** Only escalate to FULL for significant changes.

## The 5-Phase Pattern (FULL Review)

```
Phase 1: DESIGN    → Single LLM (context continuity)
Phase 2: REVIEW    → Multi-LLM or Persona Assembly (independent perspectives)
Phase 3: REVISE    → Single LLM, same as Phase 1 (integrates feedback)
Phase 4: IMPLEMENT → Single LLM, same as Phase 1 (builds from design)
Phase 5: VERIFY    → Multi-LLM or Persona Assembly (fresh eyes on code)
```

### Why Single LLM for Design/Implement
Context continuity is critical. Design decisions build on each other, and the implementing LLM must understand the full rationale chain from design through revision.

### Why Multi-LLM for Review
Independent perspectives prevent groupthink. Different models (Claude, GPT, Gemini) catch different issues due to different training and reasoning patterns.

## Multi-LLM Review Best Practices

- Summarize the design concisely; include KairosChain layer architecture context
- Specify 4-6 focus areas to bound the review scope
- Define expected feedback format (GOOD/CONCERN/ISSUE per area)
- Include CLAUDE.md principles as reference
- Use `sc_review command="design_review" review_mode="multi_llm"` to generate prompts

### Interpreting Conflicting Reviews
1. **Factual disputes** → verify against actual code/docs
2. **Preferential disputes** → use KairosChain philosophy as tiebreaker
3. **Document disagreements** and resolution rationale in the revised design

## Persona Assembly Fallback

Use when multi-LLM review is not available or not justified.

**Limitations:**
- Same model = same biases (simulated diversity, not genuine alterity)
- Less effective at catching blind spots
- Better than no review, but not equivalent to multi-LLM

**Recommended personas:** kairos (philosophy), pragmatic (feasibility), skeptic (risks)

## Log Naming Convention

Track workflow progress via file naming in `log/`:

```
log/{skillset_name}_plan_{agent}_{date}.md           # Phase 1
log/{skillset_name}_review_{reviewer}_{date}.md      # Phase 2
log/{skillset_name}_plan2_{agent}_{date}.md          # Phase 3
log/{skillset_name}_implementation_{agent}_{date}.md # Phase 4
```

Git history + `log/` directory listing provides natural cross-session tracking.

## Tools Available

| Tool | Phase | Purpose |
|------|-------|---------|
| `sc_design analyze` | 1 | Core-vs-SkillSet decision |
| `sc_design checklist` | 1 | Design completeness check |
| `sc_scaffold preview` | 4 | Preview directory structure |
| `sc_scaffold generate` | 4 | Create SkillSet skeleton |
| `sc_review design_review` | 2 | Generate design review prompt |
| `sc_review implementation_review` | 5 | Generate code review prompt |
| `kc_evaluate` (if available) | 4 | Evaluate bundled knowledge quality |
