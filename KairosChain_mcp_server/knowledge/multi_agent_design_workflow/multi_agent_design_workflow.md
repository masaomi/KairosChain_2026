---
name: multi_agent_design_workflow
description: "Multi-agent deliberation workflow for design, implementation, and iterative review"
version: "1.0"
layer: L1
tags: [workflow, multi-agent, design, review, persona-assembly, multi-llm]
---

# Multi-Agent Design Workflow

Implementation decisions are made through structured multi-agent deliberation,
not by a single agent acting alone. This workflow applies to both initial design
and post-implementation review, forming an iterative loop.

## Workflow Overview

```
┌─────────────────────────────────────────────────────┐
│  1. Rough Idea (Human)                              │
│     - Present rough thoughts, goals, constraints    │
│                                                     │
│  2. Agent Team Analysis                             │
│     - Multiple agents analyze from different angles │
│     - Surface trade-offs, risks, alternatives       │
│                                                     │
│  3. Persona Assembly                                │
│     - Project-philosophy-aware discussion            │
│     - e.g., KairosChain: consider 9 propositions   │
│     - Filter proposals through project identity     │
│                                                     │
│  4. Final Proposal Selection                        │
│     - Design: select design plan                    │
│     - Review: identify critical blockers            │
│     - Human makes the final call                    │
│                                                     │
│  5. (Optional) Multi-LLM Integration               │
│     - Run Gemini, GPT, etc. in separate terminals   │
│     - Integrate diverse LLM perspectives            │
│     - Synthesize before proceeding                  │
│                                                     │
│  6. Implementation / Revision                       │
│     - Execute the agreed plan                       │
│     - On first pass: implement                      │
│     - On subsequent passes: apply fixes             │
│                                                     │
│  ┌─── Review Loop (steps 2-6) ───────────────┐     │
│  │  After implementation, loop back to step 2 │     │
│  │  for review. Continue until exit condition. │     │
│  └────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────┘
```

## Review Loop and Termination

After the initial implementation (step 6), the workflow loops back to step 2
for review. Each review iteration may produce further fixes, which are then
reviewed again.

### Exit Conditions (whichever comes first)

| Condition | Description |
|-----------|-------------|
| **No critical defects** | No blockers or fatal flaws remain after review |
| **Max loop count reached** | Default: **3 iterations**. Adjustable per task. |

### Loop Behavior

- **Iteration 1**: Full review — architectural, logical, edge cases
- **Iteration 2**: Focused review — only issues from iteration 1 fixes
- **Iteration 3+**: Regression check — confirm no new issues introduced

If the max loop count is reached but blockers remain, the workflow pauses
and escalates to the human for a decision (continue, defer, or accept as-is).

## Output Artifacts

Each workflow execution produces two distinct artifacts, saved to both
L2 context and the `log/` directory.

### Pre-Implementation Plan

Saved **before** step 6 (first implementation):

- **L2 context**: `context_save()` with tag `plan`
- **log/ file**: `log/{date}_{feature}_plan.md`
- **Contents**: design decision, rationale, rejected alternatives, risks

### Post-Implementation Review Log

Saved **after** each review loop iteration:

- **L2 context**: `context_save()` with tag `review`
- **log/ file**: `log/{date}_{feature}_review_N.md` (N = iteration number)
- **Contents**: findings, severity, fixes applied, remaining issues

### Naming Convention

```
log/20260313_auth_refactor_plan.md
log/20260313_auth_refactor_review_1.md
log/20260313_auth_refactor_review_2.md
```

## When to Use This Workflow

- New feature design with significant architectural impact
- Refactoring that touches multiple components
- Any change where "just implement it" risks cascading problems
- Bug fixes that require root cause analysis before patching

## When NOT to Use

- Trivial fixes (typos, single-line changes)
- Well-understood, isolated changes with no design ambiguity
- Exploratory prototyping where speed matters more than correctness

## Relation to Existing Tools

| Step | KairosChain Tool |
|------|-----------------|
| Agent Team Analysis | Agent tool with multiple subagents |
| Persona Assembly | `skills_audit(command: "check")` or manual persona invocation |
| Multi-LLM Integration | External (separate terminal sessions) |
| Plan/Review output | `context_save()` + file write to `log/` |
