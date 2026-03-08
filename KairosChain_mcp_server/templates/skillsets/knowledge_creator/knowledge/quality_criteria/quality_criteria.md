---
name: quality_criteria
description: >
  Evidence-based quality evaluation criteria for KairosChain L1 knowledge.
  Defines evaluation dimensions, PASS/FAIL standards, readiness levels
  (READY/REVISE/DRAFT), and evaluation persona definitions.
  Used by kc_evaluate tool. NOT for evaluating code or SkillSet architecture.
version: "1.0"
layer: L1
tags: [meta, quality, evaluation, criteria, personas]
---

# L1 Knowledge Quality Criteria

## Quick Reference

| Dimension | Question | PASS requires |
|-----------|----------|---------------|
| Triggering quality | Does `description` enable accurate identification? | What + When + Negative scope in description |
| Self-containedness | No session-specific context leaks? | No references to "this session", "today", specific dates |
| Progressive disclosure | Body vs references/ balance? | Core info in body; details in subdirectories |
| Evidence | Claims factual and verifiable? | Concrete examples, not vague assertions |
| Discrimination | Provides info base LLM doesn't have? | KairosChain-specific knowledge the model wouldn't know |
| Redundancy | Overlap with existing L1? | Minimal overlap; unique perspective or content |
| Safety alignment | No L0 conflicts? | No contradiction with CLAUDE.md principles |

## Readiness Levels

| Level | Criteria | Action |
|-------|----------|--------|
| **READY** | All critical dimensions PASS; no session-specific leaks; description enables accurate triggering | Promote to L1 |
| **REVISE** | Most dimensions PASS but 1-2 specific issues identified; fixable without redesign | Fix identified issues, re-evaluate |
| **DRAFT** | Multiple FAILs or fundamental issues; needs significant rework | Return to L2 for further development |

## Evidence Requirements

- PASS requires citing **specific evidence** from the knowledge content
- Surface-level compliance is FAIL (e.g., frontmatter exists but description is vague)
- Burden of proof is on the assertion: "it looks fine" is not evidence
- Each evaluation dimension must include a quoted passage or specific observation

## Evaluation Personas

### evaluator
- **Role**: Knowledge Quality Inspector
- **Bias**: High bar for evidence; superficial compliance is failure
- **Focus**: Can I cite specific evidence for each criterion?
- **When useful**: Primary evaluation of any L1 knowledge

### guardian
- **Role**: L0/L1 Boundary Guardian
- **Bias**: Conservative; protect layer integrity
- **Focus**: Does this knowledge stay within its declared layer? Could it conflict with L0 meta-rules?
- **When useful**: Knowledge that touches system behavior, governance, or meta-level concerns

### pragmatic
- **Role**: Practical Value Assessor
- **Bias**: Real-world utility over theoretical purity
- **Focus**: Will an LLM actually use this knowledge effectively in a real session?
- **When useful**: All evaluations; counterbalance to overly strict evaluation

## Frontmatter Design Guidelines

### description field
- Format: **What** this knowledge contains + **When** to use it + **Negative scope** (what it's NOT for)
- Good: "Decision guide for Core vs SkillSet classification. Use when starting new KairosChain feature development. NOT for non-KairosChain projects."
- Bad: "A guide about SkillSets"

### tags field
- 5-7 tags maximum
- Structure: domain tags + function tags + meta tags
- Example: `[meta, guide, architecture, decision, skillset, core]`

### version field
- Semver string: "1.0", "0.1", etc.
- Increment on substantive content changes, not formatting fixes
