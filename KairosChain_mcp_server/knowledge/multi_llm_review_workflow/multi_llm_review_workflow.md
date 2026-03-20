---
name: multi_llm_review_workflow
description: Multi-LLM review workflow pattern — design/implement with single LLM, review with multiple independent LLMs, user orchestrates convergence loop
version: 1.1
layer: L1
tags: [workflow, review, multi-llm, quality, process, orchestration]
---

# Multi-LLM Review Workflow

## Overview

This workflow uses a **primary LLM** for design/implementation and **multiple independent LLMs** for review. The user acts as orchestrator, routing outputs between tools. The cycle repeats until convergence (0 blockers).

The specific LLM tools used (which models, how many reviewers) are environment-specific and configured per project. This skill defines the general pattern.

Validated through Service Grant SkillSet: 6 rounds, 14 LLM reviews, design through implementation.

## When to Use (and When NOT to)

This workflow has significant overhead. Apply it selectively.

### Use this workflow when:

- **New SkillSet with security implications** — access control, payment, identity, cryptography
- **Cross-SkillSet changes** — modifications touching 3+ SkillSets or core hooks
- **Dual-path enforcement** — any feature that must work on both /mcp and /place/* paths
- **Schema design** — PostgreSQL tables, migration strategy, data model decisions
- **Breaking API changes** — changes to Safety, ToolRegistry, Protocol, or BaseTool contracts

### Use simplified review (1 LLM, 1 round) when:

- Bug fix in a single file (< 50 lines changed)
- Adding a new tool to an existing SkillSet (no new domain logic)
- Documentation, knowledge, or config-only changes
- Test additions without code changes
- Refactoring with no behavioral change

### Skip review entirely when:

- Typo fixes, comment updates
- Log/output formatting changes
- Development-only changes (test fixtures, dev scripts)

### Decision heuristic:

```
Does the change involve security, identity, or money?
  YES → full multi-LLM workflow
  NO  → Does it cross SkillSet boundaries or modify core hooks?
    YES → full multi-LLM workflow
    NO  → Does it add new domain logic (> 100 lines)?
      YES → simplified review (1 LLM, 1 round)
      NO  → skip or self-review
```

The user always has the final say — if they request multi-LLM review for a simple change, follow the workflow. If they say "skip review", skip it.

## Roles

| Role | Who | Responsibility |
|------|-----|---------------|
| **Designer/Implementer** | Primary LLM (single instance) | Design, implement, synthesize reviews, produce fix plans |
| **Reviewers** | N independent LLMs (N >= 2) | Independent multi-perspective review |
| **Orchestrator** | User | Route prompts to tools, collect results, trigger next phase |

The specific LLM tools and reviewer count are configured per environment (see auto memory or project config).

## Workflow Pattern

```
Phase N (Design or Implementation):

[1] Primary LLM designs/implements → outputs artifact + review prompt
         |
         ├── artifact:      log/{name}_v{N}_{llm}_{date}.md
         ├── review prompt:  log/{name}_v{N}_review_prompt.md
         └── L2 context:    saved via context_save
         |
[2] User copies review prompt → sends to N reviewer LLMs
         |
         ├── Reviewer 1:   independent review (may use agent team internally)
         ├── Reviewer 2:   independent review
         └── Reviewer N:   independent review
         |
[3] User reports reviews collected → primary LLM reads + synthesizes
         |
         ├── reads:         log/{name}_review{R}_{reviewer}_{date}.md  (×N)
         ├── outputs:       log/{name}_v{N+1}_{llm}_{date}.md         (revised artifact)
         ├── outputs:       log/{name}_v{N+1}_review_prompt.md         (next prompt)
         └── L2 context:    saved
         |
[4] If 0 blockers → proceed to next phase
    If blockers   → repeat from [2] with v{N+1}
```

## When the LLM Should Act

When the user says any of these, the primary LLM should follow this workflow automatically:

| User says | LLM does |
|-----------|----------|
| "設計してください" / "design this" | Create design doc + review prompt + save L2 |
| "実装してください" / "implement this" | Implement + create implementation log + review prompt + save L2 |
| "マルチLLMレビューが集まりました" | Read all review files, synthesize, create revised version + new review prompt |
| "レビューしてください" / "review this" | Run internal review (see below), auto-generate output filename |
| "統合して最終版を作ってください" | Synthesize reviews into final version, check for blockers |
| "ブロッカーがなければ実装に移ってください" | Check convergence → implement if clear, or output for more review |

### Internal review procedure ("レビューしてください")

When the primary LLM is asked to review, it should:

1. **Launch 2-3 parallel agents** with different review perspectives (e.g., Security, Correctness, Philosophy+Test)
2. Each agent reviews independently and produces findings
3. **Persona Assembly** synthesizes: cross-reference findings, resolve disagreements, produce consensus verdict
4. **Output** to file with auto-generated name following naming conventions:
   `log/{feature}_{review_type}_{primary_llm_team_id}_{date}.md`

The user does NOT need to specify the output filename. The LLM derives it from:
- `{feature}`: current feature context (e.g., `service_grant_phase1`)
- `{review_type}`: what is being reviewed (e.g., `implementation_review1`, `fix_plan_review`)
- `{primary_llm_team_id}`: the primary LLM's team identifier from auto memory (e.g., `claude_team_opus4.6`)
- `{date}`: today's date in `YYYYMMDD` format

If the user specifies a filename, use that instead.

### Auto-generated outputs for each phase

At the end of each major action, the LLM should automatically produce:

| Action completed | Auto-generate |
|-----------------|---------------|
| Design created | Review prompt file + L2 save |
| Implementation completed | Implementation log + review prompt + L2 save |
| Internal review completed | Review result file |
| Reviews synthesized | Revised artifact + next review prompt + L2 save |
| Fix plan created | Fix plan file + review prompt + L2 save |
| Fixes implemented | Fix implementation log + review prompt + L2 save + commit |

## File Naming Conventions

### Design Phase
```
log/{feature}_plan_v{version}_{llm}_{date}.md            # design doc
log/{feature}_v{version}_multi_llm_review_prompt.md       # review prompt
log/{feature}_plan_v{version}_review{R}_{reviewer}_{date}.md  # review result
```

### Implementation Phase
```
log/{feature}_plan_v{final}_implementation_log_{llm}_{date}.md  # impl log
log/{feature}_implementation_review_prompt_{date}.md            # review prompt
log/{feature}_implementation_review{R}_{reviewer}_{date}.md     # review result
```

### Fix Phase
```
log/{feature}_fix_plan_{llm}_{date}.md                          # fix plan
log/{feature}_fix_plan_review_prompt.md                         # review prompt
log/{feature}_fix_plan_review_{reviewer}_{date}.md              # review result
log/{feature}_fix_plan_v{N}_{llm}_{date}.md                    # revised fix plan
log/{feature}_fix_implementation_log_{llm}_{date}.md            # fix impl log
log/{feature}_fix_implementation_review_prompt_{date}.md         # fix review prompt
```

### LLM identifiers in filenames
Use short identifiers for each LLM tool. Examples: `claude_opus4.6`, `codex_gpt5.4`, `cursor_premium`. The mapping between identifiers and tools is environment-specific.

## Review Prompt Template

Every review prompt MUST begin with an **Orchestrator Instructions** section in English:

```markdown
## Orchestrator Instructions

Review this with an agent team from multiple perspectives, discuss findings
in a Persona Assembly, and produce a consolidated review.

Output the review result to:
\`\`\`
log/{feature}_{review_type}_{agent_tool_name}_{LLM+version}_{date}.md
\`\`\`
```

All prompt content (including Orchestrator Instructions) MUST be in **English**. This ensures consistent parsing across different LLM tools regardless of their language capabilities.

After the Orchestrator Instructions, every review prompt MUST include:

1. **Instructions** — What to review, what NOT to re-review
2. **Review history** — Table of all previous rounds and what was found
3. **Context** — Architecture summary for reviewers unfamiliar with codebase
4. **Artifact to review** — Full content (code, design, or plan) inline
5. **Specific questions** — Pointed questions to guide reviewers
6. **Severity ratings** — FAIL/CONCERN/NOTE/OK (or APPROVE/REJECT for plans)
7. **Output format** — Structured template for review output

Key: Inline the full content. Reviewers may not have file access.

## Review Types

### Design Review
- Focus: Architecture, enforcement paths, threat model, protocol
- Reviewers see: Design document text
- Output: FAIL/CONCERN/NOTE with specific findings

### Implementation Review
- Focus: Code correctness, security, test coverage, design-implementation gaps
- Reviewers see: Full source code inline
- Output: FAIL/CONCERN/NOTE with file:line references

### Fix Plan Review
- Focus: Completeness, correctness, prioritization, new problems
- Reviewers see: Fix plan with proposed code
- Output: APPROVE/CONCERN/REJECT per fix item

### Convergence Review (final round)
- Focus: Verify all previous findings resolved, no new issues
- Reviewers see: Resolution matrix + revised code
- Output: APPROVE/APPROVE WITH NOTES/REVISE

## Convergence Criteria

A round **converges** when:
- All reviewers: APPROVE or APPROVE WITH NOTES
- 0 FAIL / 0 REJECT findings
- NOTEs are documented but non-blocking

If any reviewer says REJECT or finds a FAIL → revise and re-review.

**Majority rule**: If (N-1)/N APPROVE and 1/N has non-blocking concerns, proceed with the concerns documented.

## Synthesis Pattern

When the primary LLM synthesizes N reviews:

1. **Build concordance matrix** — which findings appear in 2+ reviews?
2. **Classify each finding** — N/N agree (must fix), majority agree (should fix), 1/N only (evaluate)
3. **Check for conflicts** — do reviewers disagree? Document the majority decision.
4. **Create revised artifact** — apply all unanimous and majority findings, evaluate minority findings
5. **Create resolution matrix** — map each R(N) finding to its resolution
6. **Output new review prompt** — include resolution matrix for verification

## L2 Save Points

Save to L2 at these moments:
- After design/implementation complete (before review)
- After synthesis of reviews (revised version)
- After final convergence (implementation-ready)

## Agent Team Review (internal to primary LLM)

When the primary LLM reviews internally using an agent team:

1. Launch 2-3 parallel agents with different perspectives
2. Each agent reviews independently
3. **Persona Assembly** synthesizes: deduplicate, resolve severity conflicts, compress
4. Output single consolidated review file

### Why Persona Assembly matters

Parallel agents tend to produce exhaustive, overlapping findings. Without Assembly, the raw output is ~2x the volume of actionable findings. Assembly serves as an **editor**, not just a merger:

- **Deduplication**: Multiple agents find the same issue with different wording
- **Severity resolution**: Security says CONCERN, Design says FAIL for the same issue — Assembly decides
- **Signal compression**: ~50% of raw findings are consolidated without losing information
- **Compound risk identification**: Combinations of findings (e.g., "this bug is untested AND security-critical") that individual agents don't cross-reference

Observed compression ratio: parallel agent raw output → Assembly output ≈ 2:1

### When to use Assembly

- **Always use** when running 2+ agents in parallel (the raw output is too noisy without it)
- **Skip** only for single-agent review of trivial changes

### Typical perspectives
- Security / Correctness / Philosophy+Test (for implementation review)
- Design Consistency / Security+Feasibility (for fix plan review)

Note: Internal agent team review is a supplement, not a substitute for independent multi-LLM review. Different LLM providers catch different categories of bugs.

## Observed Statistics (Service Grant experiment)

| Metric | Value |
|--------|-------|
| Total rounds | 6 |
| Total LLM reviews | 14 |
| Design rounds to convergence | 3 (R1-R3) |
| Implementation review rounds | 1 (R4) |
| Fix plan rounds to convergence | 2 (R5-R6) |
| Design bugs found | 8 P0/P1 → 2 FAIL → 0 |
| Implementation bugs found | 6 FAIL + 5 CONCERN → 13 FIX |
| Fix plan issues found | Deadlock, missing items → 0 blockers |
| Implementation debug during coding | 2 |

## Anti-Patterns

- **Don't skip the review prompt** — Reviewers need inline content and context
- **Don't merge design + implementation review** — They find different bug classes
- **Don't implement Phase N+1 before Phase N review converges** — Prerequisites may change
- **Don't re-review from scratch** — Each round should be a convergence review checking only the delta
- **Don't use only internal agent team** — Independent LLMs from different providers catch more than agents within one LLM
