---
description: Multi-LLM design review methodology with automated and manual execution modes
tags: [methodology, multi-llm, design-review, automation, quality-assurance, experiment]
version: "2.1"
---

# Multi-LLM Design Review Methodology

## Overview

Multi-LLM design review is a methodology where multiple independent LLMs review the same
design document, and their findings are compared and integrated before implementation.

This knowledge covers both the **methodology** (when/how to use multi-LLM review) and
the **execution mechanism** (automated CLI-based or manual copy-paste).

## Execution Modes

### Auto Mode (default)

Uses CLI tools to run 3 LLM reviews in parallel from Claude Code as orchestrator.
Auto mode is selected when both `codex` and `agent` commands are available in the environment.

### Manual Mode (fallback)

User manually copies review prompts to each LLM tool and collects results.
Used when CLI tools are unavailable or when the user explicitly requests manual mode.

### Mode Detection

At the start of a review workflow, check tool availability:

```bash
# Detection commands (run at workflow start)
which codex 2>/dev/null && echo "codex: available" || echo "codex: NOT FOUND"
which agent 2>/dev/null && echo "agent: available" || echo "agent: NOT FOUND"
```

- Both available -> Auto mode
- Either missing -> Manual mode (with note about which tool is missing)
- User override: `mode: manual` or `mode: auto` in review request

---

## Prompt Generation Rules

When generating a review prompt, the orchestrator MUST include:

### 1. Output Filename Specification

Every review prompt MUST contain a clear output filename directive at the top of the
prompt body, so that each LLM (and the user running it manually) knows where to save
the result.

**In the prompt body itself** (what the LLM sees):

```markdown
## Output

Save your review to: `log/{artifact}_review{N}_{llm_id}_{date}.md`
```

**In the surrounding prompt file** (what the user sees for manual execution):

Include a filename table at the top of the prompt file, BEFORE the prompt body:

```markdown
## Output Filenames

| Reviewer | Output filename |
|----------|----------------|
| Claude Code (CLI) | `log/{artifact}_{llm_id}_{date}.md` |
| Claude Agent Team | `log/{artifact}_{llm_id}_{date}.md` |
| Codex / Cursor GPT-5.4 | `log/{artifact}_{llm_id}_{date}.md` |
| Cursor Composer-2 | `log/{artifact}_{llm_id}_{date}.md` |
| Cursor Premium | `log/{artifact}_{llm_id}_{date}.md` |
```

### 2. Auto-Execution Commands

For each reviewer, include the ready-to-run CLI command with output redirection
already targeting the correct filename:

```markdown
## Auto-Execution Commands

### Codex
codex exec "$(cat /tmp/review_prompt.txt)" > log/{artifact}_{llm_id}_{date}.md 2>&1

### Cursor Composer-2
agent -p "$(cat /tmp/review_prompt.txt)" > log/{artifact}_{llm_id}_{date}.md 2>&1

### Cursor GPT-5.4 (manual fallback for Codex)
agent --model gpt-5.4-high -p "$(cat /tmp/review_prompt.txt)" > log/{artifact}_{llm_id}_{date}.md 2>&1
```

### 3. Rationale

Without explicit output filename instructions:
- Manual reviewers don't know where to save the output
- Auto commands may redirect to wrong filenames
- The orchestrator cannot reliably find and read review results
- File naming inconsistencies break the convergence analysis step

---

## Auto Mode: CLI Specifications (Tested 2026-03-20)

### Tool Matrix

| Tool | Role | Command | Prompt Input | Output Collection | Model Flag |
|------|------|---------|-------------|-------------------|------------|
| **Codex** | Reviewer 1 | `codex exec` | stdin pipe: `cat prompt.md \| codex exec -` | `-o /path/to/output.md` | `-m MODEL` |
| **Cursor Agent** | Reviewer 2 | `agent -p` | File reference in prompt (stdin NOT supported) | stdout redirect: `> output.md` | `--model MODEL` |
| **Claude Code** | Reviewer 3 | Agent tool (internal) | Direct prompt string | Return value or workspace file | Internal (inherits session model) |

### Critical Notes

- **Cursor Agent stdin limitation**: `cat file | agent -p -` does NOT work. The agent
  misinterprets stdin content. Always use file-reference prompts:
  `agent -p "Read the file log/review_prompt.md and follow the instructions in it."`
- **Cursor Agent trust flag**: `--trust` is required for headless/non-interactive mode
  to avoid workspace trust prompts.
- **Codex workspace**: Use `-C /path/to/workspace` to set the working directory.
- **Claude Agent write permissions**: Subagents may lack `/tmp` write permissions.
  Direct them to write within the workspace (e.g., `log/`) or capture via return value.

### Model Detection and Recording

Before executing reviews, detect and record which models each tool will use:

```bash
# Codex: default model (check config or output header)
codex exec -C . -o /dev/null "What model are you? Reply with only the model name." 2>&1

# Cursor Agent: list available models and current default
agent --list-models 2>&1 | grep "(current\|default)"

# Claude Code: known from session (e.g., claude-opus-4-6)
```

Each review output file MUST include a header recording the model used:

```markdown
# Review: [artifact_name]
- **Reviewer**: [tool_name]
- **Model**: [model_id] (e.g., gpt-5.4-high, composer-2, claude-opus-4-6)
- **Date**: [ISO date]
- **Mode**: auto
```

### Model Selection (Optional Override)

Users can specify models per reviewer. If not specified, each tool uses its default.

```
codex exec -m gpt-5.4-high ...
agent -p --model claude-4.6-opus-high ...
```

Available model families (as of 2026-03-20):
- **Codex**: GPT-5.4 series (default: gpt-5.4-high)
- **Cursor Agent**: Composer-2 (default), Claude 4.6 Opus/Sonnet, GPT-5.4, Gemini 3.1, Grok 4.20
- **Claude Code**: Claude Opus 4.6 (session model)

### Orchestration Template

```
Step 1: Generate review prompt
  - Write prompt to log/{artifact}_review_prompt.md
  - Include: instructions, context, severity ratings, output format
  - Append the full design/implementation document
  - MUST include output filename table and auto-execution commands (see Prompt Generation Rules)

Step 2: Detect environment and models
  - Run: which codex && which agent
  - Record default models for each tool
  - Report to user: "Auto mode: Codex (gpt-5.4-high), Agent (composer-2), Claude (opus-4.6)"

Step 3: Execute 3 reviews in parallel
  - Bash(background): cat prompt.md | codex exec -C workspace -o log/review_codex.md -
  - Bash(background): agent -p --workspace path --trust \
      "Read log/{artifact}_review_prompt.md and follow the review instructions." \
      > log/review_cursor.md
  - Agent(background): Internal Claude review -> write to log/review_claude.md

Step 4: Collect and validate results
  - Wait for all 3 to complete (background task notifications)
  - Verify each output file exists and contains structured review
  - If any tool failed: report failure, offer manual fallback for that reviewer

Step 5: Consensus analysis
  - Read all 3 review files
  - Build concordance matrix (which findings overlap across reviewers)
  - Apply consensus rules (see Consensus Patterns section)
  - Generate integrated summary

Step 6: Report to user
  - Present: per-reviewer verdicts, concordance matrix, recommended actions
  - Save: log/{artifact}_review_consensus.md
```

### Error Handling

| Error | Detection | Recovery |
|-------|-----------|----------|
| CLI not found | `which` returns non-zero | Fall back to manual mode for that reviewer |
| Authentication expired | Exit code non-zero, auth error in stderr | Prompt user to re-login |
| Timeout (>5 min) | Background task timeout | Kill task, report partial result, offer retry |
| Empty/malformed output | Output file empty or missing verdict | Report failure, offer manual retry |
| Workspace trust prompt | Agent hangs waiting for input | Use `--trust` flag (already in template) |
| Usage limit hit | Exit code non-zero, "usage limit" in output | Fall back to alternate tool (e.g., Codex -> Cursor GPT-5.4 manual) |

### Timeout Configuration

```bash
# Codex and Agent: run via Bash with 5-minute timeout
timeout: 300000  # milliseconds

# Claude Agent: run via Agent tool with run_in_background
# (no explicit timeout; monitored via task notification)
```

---

## Manual Mode: Workflow

When auto mode is unavailable, the orchestrator generates review prompts and
the user distributes them manually.

### Steps

1. **Orchestrator generates prompt**: Writes `log/{artifact}_review_prompt.md`
   - MUST include output filename table and auto-execution commands
2. **User distributes**: Copies prompt to each LLM tool (separate terminals/windows)
3. **User collects**: Saves each review output to `log/{artifact}_review_{llm}.md`
4. **Orchestrator integrates**: Reads all review files and produces consensus analysis

### Naming Convention

```
log/{artifact}_review_prompt.md                    # Shared review prompt
log/{artifact}_review{N}_{llm_id}_{date}.md       # Individual reviews
log/{artifact}_review{N}_consensus_{date}.md       # Integrated consensus
```

LLM identifiers: `claude_opus4.6`, `claude_team_opus4.6`, `codex_gpt5.4`,
`cursor_premium`, `cursor_composer2`, `cursor_gpt5.4`

---

## Observed LLM Role Differentiation

Without explicit instruction, different LLMs naturally focus on different verification layers:

| Layer | Description | Example LLM Behavior |
|-------|-------------|---------------------|
| **Structural/Architectural** | System-level integrity, component relationships, concurrency | Found: thread safety, load-order dependency, admin privilege escalation |
| **Design-Implementation Seam** | Whether designed APIs actually exist in the codebase | Found: `/place/*` bypass, missing pubkey field, non-existent hook API |
| **Safety Defaults** | Fail-closed behavior, input validation, constraint completeness | Found: fail-open on nil, hex charset validation, nonce constraints |

**Key insight**: The "design-implementation seam" layer is the most valuable and most
likely to be missed by a single LLM reviewing its own design. A different LLM brings
different assumptions about what the codebase actually provides.

## Consensus Patterns

| Agreement Level | Typical Meaning | Action |
|----------------|-----------------|--------|
| **3/3 consensus** | Architectural-level fundamental gap | Must fix -- these are real design holes |
| **2/3 consensus** | Implementation-level correctness issue | Should fix -- likely real but may be a matter of perspective |
| **1/3 only** | Specialty-specific insight | Do NOT ignore -- often the most novel finding (e.g., thread safety, hex regex) |

1/3 findings are not "minority opinions to discard" -- they represent the unique
expertise of that LLM's verification approach. In the Service Grant experiment,
single-LLM findings included FAIL-level issues (PgCircuitBreaker thread safety)
and schema hardening adopted into the design (pubkey_hash hex constraint).

## Convergence Curve

For a Tier 3 complexity design (rewriting an existing implementation approach):

```
Round 1: Architectural gaps     -- "this is missing"        (existence)
Round 2: Fix correctness        -- "the fix is wrong"       (accuracy)
Round 3: Refinement only        -- "minor adjustments"      (polish)
```

3 rounds achieved convergence (0 FAIL, implementation-ready) for this complexity level.
Simpler designs (Tier 1-2) may converge in 1-2 rounds.

## Convergence Rule

- **2/3 APPROVE** (with no REJECT) = proceed to next step
- **Any REJECT or FAIL** = revise and re-review
- **All 3 APPROVE** = high confidence, proceed

## Cost-Benefit Hypothesis

**Hypothesis under test**: Multi-LLM design review loops before implementation
reduce post-implementation review/debug cycles.

**Baseline data** (Service Grant v1.3):
- Design versions: v1.0 -> v1.1 -> v1.2 -> v1.3
- Review rounds: 3
- Issues found and fixed pre-implementation: 18 P0/P1/FAIL + ~20 CONCERN
- Issues remaining at implementation start: 0 FAIL, 7 minor CONCERN

**To be measured**: Debug/review count during Phase 1 implementation.

## Practical Guidelines

### When to use multi-LLM review
- Tier 3+ complexity (architectural redesign, cross-component integration)
- Security-critical designs (access control, authentication, billing)
- Designs that depend on existing codebase APIs (high seam risk)

### When single-LLM review suffices
- Tier 1-2 complexity (new feature within existing pattern)
- Self-contained SkillSets with minimal cross-component dependencies
- Designs where the implementation path is well-understood

### Review prompt design
- Include full architectural context (HTTP routing, hook APIs, existing code structure)
- Include findings from previous rounds for verification
- Ask for structured output (resolution tables, severity ratings, confidence levels)
- Append the full design document to the prompt (avoids copy-paste errors)
- MUST include output filename specification (see Prompt Generation Rules)

### Integration strategy
- Compare reviews side-by-side before integrating
- Use consensus level to prioritize fixes
- Single-LLM integration (Opus 4.6) of all findings into next version worked well
- Agent team review (4-persona + Persona Assembly) for internal Claude rounds

## Relation to multi_agent_design_workflow

This skill is the detailed execution guide for **Step 5 (Multi-LLM Integration)**
of the `multi_agent_design_workflow`. While `multi_agent_design_workflow` covers the
overall design workflow including Claude-internal persona assembly (Steps 1-4, 6),
this skill covers the external multi-LLM review mechanism: CLI commands, auto/manual
modes, consensus analysis, and convergence patterns.

## Experimental Context

- **Test case**: Service Grant SkillSet for KairosChain
- **Complexity**: Tier 3 (replacing multiuser-skillset with fundamentally different approach)
- **LLMs used**: Claude Opus 4.6 (agent team), Codex GPT-5.4, Cursor Premium
- **Date**: 2026-03-18
- **Design logs**: log/service_grant_plan_v1.{1,2,3}_*.md
- **Review logs**: log/service_grant_plan_v1.{1,2,3}_review{1,2,3}_*.md

### Automation Test (2026-03-20)

CLI-based parallel execution tested with Service Grant Phase 1 Fix Plan review prompt:

| Tool | Command | Result | Model Used |
|------|---------|--------|------------|
| Codex (`codex exec`) | stdin pipe + `-o` | Success (49 lines, REJECT verdict) | gpt-5.4-high (default) |
| Cursor Agent (`agent -p`) | File reference prompt + stdout redirect | Success (79 lines, APPROVE WITH CHANGES) | composer-2 (default) |
| Claude Code (Agent tool) | Internal background agent | Success (review generated, write permission issue) | claude-opus-4-6 |

Key findings:
- All 3 tools produced structured reviews from the same prompt
- Cursor Agent does NOT support stdin pipe -- must use file-reference prompts
- Claude subagent may need workspace-internal output paths
- Parallel execution via `run_in_background` works for all 3
