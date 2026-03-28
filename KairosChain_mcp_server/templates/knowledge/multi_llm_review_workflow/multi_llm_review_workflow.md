---
name: multi_llm_review_workflow
description: "Multi-LLM review methodology and execution — workflow pattern, CLI tooling, consensus analysis, Persona Assembly. Applicable to design, implementation, documentation, or any artifact."
version: "3.1"
tags:
  - workflow
  - review
  - multi-llm
  - quality
  - process
  - orchestration
  - automation
related:
  - multi_llm_reviewer_evaluation
  - design_to_implementation_workflow
---

# Multi-LLM Review Workflow

## Overview

Multiple independent LLMs review the same artifact, and their findings are compared
and integrated. The user (or primary LLM) acts as orchestrator.

This skill covers:
- **WHAT/WHEN**: When to use multi-LLM review, review types, convergence criteria
- **HOW**: CLI commands, prompt generation, auto/manual execution, consensus analysis

For **WHO** (which LLM is good at what), see: `multi_llm_reviewer_evaluation`
For **development lifecycle** (design → implement → verify), see: `design_to_implementation_workflow`

## Roles

| Role | Who | Responsibility |
|------|-----|---------------|
| **Designer/Implementer** | Primary LLM (single instance) | Design, implement, synthesize reviews, produce fix plans |
| **Reviewers** | N independent LLMs (N >= 2) | Independent multi-perspective review |
| **Orchestrator** | User or primary LLM | Route prompts, collect results, trigger next phase |

## When to Use

### Use multi-LLM review when:
- Security-critical: access control, authentication, billing, cryptography
- Cross-component: modifications touching 3+ SkillSets or core hooks
- Tier 3+ complexity: architectural redesign, new subsystem
- High seam risk: designs that depend on existing codebase APIs
- Important documents: grant applications, papers, specifications

### Use single-LLM review when:
- Tier 1-2: new feature within existing pattern, single SkillSet
- Self-contained: minimal cross-component dependencies
- Well-understood: implementation path is clear

### Skip review when:
- Typo fixes, comment updates, formatting changes
- Development-only changes (test fixtures, dev scripts)

### Decision heuristic:
```
Security, identity, or money involved?
  YES → full multi-LLM review
  NO  → Crosses SkillSet boundaries or modifies core hooks?
    YES → full multi-LLM review
    NO  → New domain logic (> 100 lines)?
      YES → single-LLM review (1 round)
      NO  → skip or self-review
```

The user always has the final say.

## Workflow Pattern

```
[1] Primary LLM creates artifact → outputs artifact + review prompt
         |
         ├── artifact:      log/{name}_{llm}_{date}.md
         ├── review prompt: log/{name}_review_prompt.md
         └── L2 context:    saved via context_save
         |
[2] Orchestrator sends prompt → N reviewer LLMs execute in parallel
         |
         ├── Reviewer 1:   independent review
         ├── Reviewer 2:   independent review
         └── Reviewer N:   independent review
         |
[3] Orchestrator collects → primary LLM reads + synthesizes
         |
         ├── reads:    log/{name}_review{R}_{reviewer}_{date}.md  (×N)
         ├── outputs:  revised artifact + new review prompt
         └── L2 save:  consensus + revised artifact
         |
[4] If 0 FAIL → proceed to next phase
    If FAIL    → repeat from [2] with revised artifact
```

## Review Types

| Type | Focus | Reviewers See | Typical Use |
|------|-------|--------------|-------------|
| Design review | Architecture, enforcement paths, threat model | Design document | Before implementation |
| Implementation review | Code correctness, security, wiring, test coverage | Full source code | After implementation |
| Fix plan review | Completeness, correctness, prioritization | Fix plan with proposed code | After review findings |
| Document review | Accuracy, completeness, consistency | Document text | Grant applications, papers |
| Final/convergence review | All prior findings resolved, no new issues | Resolution matrix + revised artifact | Before merge |

## LLM Role Differentiation

Without explicit instruction, different LLMs naturally focus on different verification layers:

| Layer | Description | Example Findings |
|-------|-------------|-----------------|
| **Structural/Architectural** | System-level integrity, component relationships | Thread safety, load-order dependency |
| **Design-Implementation Seam** | Whether designed APIs actually exist in the codebase | Missing hook API, non-existent method, wrong return type |
| **Safety Defaults** | Fail-closed behavior, input validation | Fail-open on nil, missing charset validation |

**Key insight**: The "design-implementation seam" is the most valuable layer and most
likely to be missed by a single LLM reviewing its own design. For per-model profiles, see `multi_llm_reviewer_evaluation`.

## Convergence Rules

- **2/3 APPROVE** (no REJECT) = proceed to next step
- **Any REJECT or FAIL** = revise and re-review
- **3/3 APPROVE** = highest confidence, proceed

### Consensus Patterns

| Agreement | Meaning | Action |
|-----------|---------|--------|
| **3/3** | Architectural-level gap | Must fix |
| **2/3** | Implementation-level issue | Should fix |
| **1/3 only** | Specialty-specific insight | Do NOT ignore — often the most novel finding |

1/3 findings are not "minority opinions to discard." They represent unique expertise.

### Majority Rule — Reference Only

A single reviewer's FAIL may identify a critical vulnerability others missed.
**Never use majority rule to dismiss a finding without evaluating its substance.**

### Convergence Curve (typical for Tier 3)

```
Round 1: Architectural gaps     — "this is missing"     (existence)
Round 2: Fix correctness        — "the fix is wrong"    (accuracy)
Round 3: Refinement only        — "minor adjustments"   (polish)
```

Simpler artifacts (Tier 1-2, documents) may converge in 1-2 rounds.

### Severity Scale

Standard: FAIL / HIGH / MEDIUM / LOW for findings.
APPROVE / APPROVE WITH CHANGES / REJECT for verdicts.
Legacy mapping: CONCERN ≈ HIGH/MEDIUM, NOTE ≈ LOW, OK ≈ no finding.

## Persona Assembly Integration

When complexity warrants deeper analysis from the Claude reviewer:

| Complexity | Claude Mode | Rationale |
|-----------|------------|-----------|
| Tier 1-2 | Single perspective | Assembly overhead not justified |
| Tier 3+ | Persona Assembly (4+ personas) | Multiple viewpoints catch seam issues |
| Safety-critical | Assembly + Guardian persona | Adversarial thinking required |
| Final merge gate | Assembly (Kairos + Guardian + Pragmatist + Skeptic) | Comprehensive pre-merge check |
| Knowledge/methodology review | Single perspective | Content review benefits from LLM diversity, not persona diversity |

Assembly findings are weighted as a **single reviewer** (not 4 votes) to avoid
over-representing the Claude perspective in the consensus matrix.

## Synthesis Pattern

When the orchestrator integrates N reviews:

1. **Build concordance matrix** — which findings appear in 2+ reviews?
2. **Classify each finding** — N/N (must fix), majority (should fix), 1/N (evaluate substance)
3. **Evaluate minority findings on substance** — is it a real bug? Security issue?
4. **Create revised artifact** — apply all genuine bugs regardless of concordance count
5. **Create resolution matrix** — map each finding to its resolution with justification
6. **Output new review prompt** — include resolution matrix for verification

## L2 Save Points

Save to L2 context at these moments:
- After design/implementation complete (before review)
- After synthesis of reviews (revised version)
- After final convergence (implementation-ready / merge-ready)

---

# Execution

## Auto Mode vs Manual Mode

### Mode Detection

```bash
which codex 2>/dev/null && echo "codex: available" || echo "codex: NOT FOUND"
which agent 2>/dev/null && echo "agent: available" || echo "agent: NOT FOUND"
```

- Both available → Auto mode
- Either missing → Manual mode
- User override: `mode: manual` or `mode: auto`

### CLI Tool Matrix (Tested 2026-03-28)

| Tool | Command | Prompt Input | Output Collection | Model |
|------|---------|-------------|-------------------|-------|
| **Codex** | `codex exec` | stdin pipe: `cat prompt.md \| codex exec -` | `-o /path/output.md` | GPT-5.4 (default) |
| **Cursor Agent** | `agent -p` | File reference (stdin NOT supported) | stdout redirect: `> output.md` | Composer-2 (default) |
| **Claude Code** | Agent tool (internal) | Direct prompt string | Write to workspace file | Opus 4.6 (session) |

### Model Detection

Before executing reviews, detect and record models:

```bash
codex exec -C . -o /dev/null "What model are you? Reply with only the model name."
agent --list-models 2>&1 | grep "(current\|default)"
# Claude Code: known from session
```

### Critical CLI Notes

- **Cursor Agent stdin**: `cat file | agent -p -` does NOT work. Use file-reference:
  `agent -p --trust "Read log/prompt.md and follow the instructions."`
- **Cursor Agent trust**: `--trust` required for headless/non-interactive mode
- **Codex workspace**: `-C /path/to/workspace` to set working directory
- **Claude Agent paths**: Write within workspace (e.g., `log/`), not `/tmp`

## Prompt Generation Rules

Every review prompt MUST include these 7 items:

1. **Output filename table** — so each reviewer knows where to save
2. **Auto-execution commands** — ready-to-run CLI per reviewer
3. **Review instructions** — what to focus on, what NOT to re-review
4. **Review history** (R2+) — table of previous rounds and findings
5. **Context** — architecture summary for reviewers unfamiliar with codebase
6. **Full artifact content inline** — reviewers may not have file access
7. **Severity ratings + output format** — structured template for review output

All prompt content MUST be in **English** for consistent parsing across LLM tools.

### Output Directive in Prompt Body

The prompt body itself (what the LLM sees) must contain:
```markdown
## Output
Save your review to: `log/{artifact}_review{N}_{llm_id}_{date}.md`
```

### Review Output Header

Each review file MUST include:
```markdown
- **Reviewer**: [tool_name]
- **Model**: [model_id]
- **Date**: [ISO date]
- **Overall Verdict**: APPROVE / APPROVE WITH CHANGES / REJECT
```

## Orchestration Template

```
Step 1: Generate review prompt
  - Write to log/{artifact}_review_prompt.md
  - Include all 7 required items (see Prompt Generation Rules)
  - Append full artifact content

Step 2: Detect environment and models
  - Run: which codex && which agent
  - Detect default models
  - Report: "Auto mode: Codex (gpt-5.4), Agent (composer-2), Claude (opus-4.6)"

Step 3: Execute N reviews in parallel
  - Bash(background): cat prompt.md | codex exec -C workspace -o log/review_codex.md -
  - Bash(background): agent -p --trust "Read prompt and review..." > log/review_cursor.md
  - Agent(background): Internal Claude review → write to log/review_claude.md

Step 4: Collect and validate
  - Wait for all to complete (background task notifications)
  - Verify each output file exists and contains structured review
  - Failed tool → offer manual fallback

Step 5: Consensus analysis
  - Read all review files
  - Build concordance matrix
  - Apply consensus rules
  - Generate: log/{artifact}_consensus.md

Step 6: Report to user
  - Per-reviewer verdicts, concordance matrix, recommended actions
  - Save L2 context
```

## Error Handling

| Error | Detection | Recovery |
|-------|-----------|----------|
| CLI not found | `which` non-zero | Manual mode fallback |
| Auth expired | Non-zero exit, auth error | Prompt re-login |
| Timeout (>5 min) | Background task timeout | Kill, report partial, retry |
| Empty output | Missing verdict | Report failure, manual retry |
| Trust prompt | Agent hangs | `--trust` flag |
| Usage limit | "usage limit" in output | Alternate tool fallback |

## File Naming Conventions

```
log/{artifact}_review_prompt.md                    # Shared prompt
log/{artifact}_review{N}_{llm_id}_{date}.md       # Individual reviews
log/{artifact}_review{N}_consensus_{date}.md       # Consensus analysis
```

LLM identifiers: `claude_opus4.6`, `claude_team_opus4.6`, `codex_gpt5.4`,
`cursor_composer2`, `cursor_gpt5.4`, `cursor_premium`

## Internal Agent Team Review

When the primary LLM reviews using its own agent team:

1. Launch 2-3 parallel agents with different perspectives
2. Each reviews independently
3. **Persona Assembly** synthesizes: deduplicate, resolve severity, compress
4. Output single consolidated review file

Compression ratio: parallel agent raw → Assembly ≈ 2:1

## Anti-Patterns

- Don't skip the review prompt — reviewers need inline content and context
- Don't merge design + implementation review — they find different bug classes
- Don't advance to Phase N+1 before Phase N review converges
- Don't re-review from scratch — each round checks only the delta
- Don't use only internal agent team — different providers catch different bugs
- Don't dismiss 1/3 findings without evaluating substance
- Don't use Persona Assembly in every intermediate round (save for final gate)

---

## Experimental Data

### Service Grant (Tier 3, 2026-03-18)
- 3 review rounds, 3 LLMs → 8 P0/P1 design bugs found
- Implementation review: 6 FAIL + 5 CONCERN → 13 FIX
- Fix plan: 2 rounds → deadlock found → converged

### Attestation Nudge (Tier 2, 2026-03-28)
- Design: 2 rounds, 3 LLMs → v0.1(REJECT) → v0.3(converged)
- Implementation review: 1 round → 3/3 FAIL (missing call site)
- Final review + Persona Assembly: 3/3 APPROVE, 0 FAIL
- Codex convergence: REJECT → REJECT → REJECT → APPROVE (4 rounds)
- Self-referential review: v3.0 of this skill reviewed by its own process → v3.1

**Key insight**: Design reviews and implementation reviews find
**categorically different bugs**. Both phases are necessary.
