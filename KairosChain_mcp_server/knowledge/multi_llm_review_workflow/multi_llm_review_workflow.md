---
name: multi_llm_review_workflow
description: "Multi-LLM review methodology and execution — workflow pattern, CLI tooling, consensus analysis, Persona Assembly. Applicable to design, implementation, documentation, or any artifact."
version: "3.3"
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

## Two Execution Paths (read this first)

There are **two distinct execution paths** with the same name "multi-LLM review".
They differ in subprocess lifecycle ownership and completion-detection mechanics.
Pick the right one for your environment:

### Path A — Host-tracked (Bash workflow)

- **Trigger**: orchestrator (LLM) calls Claude Code's `Bash` tool with
  `run_in_background: true` to spawn `claude -p`, `codex exec`, `agent -p` directly.
- **Process parent**: Claude Code (the host harness).
- **Completion detection**: **event-driven**. Claude Code's shell tracker monitors
  the spawned shells; when they exit, the LLM is notified through the standard
  tool-result mechanism. Statusbar shows `XX shells` while reviewers are running.
- **When to use**: interactive Claude Code sessions for one-off Tier 3 reviews.
- **Reference**: see "Orchestration Template" section below for the canonical
  `Bash(background)` pattern.

### Path B — MCP-managed (multi_llm_review SkillSet)

- **Trigger**: orchestrator calls the MCP tool `multi_llm_review`.
- **Process parent**: the kairos-chain Ruby gem (MCP server). The gem forks a
  detached worker (`bin/dispatch_worker.rb`) which calls `Process.setsid` and
  spawns CLI reviewers as a separate session leader.
- **Completion detection**: **polling required**. Claude Code is not the parent,
  so the spawned subprocesses do NOT appear in the `XX shells` statusbar count.
  The orchestrator must call `multi_llm_review_collect` (and optionally
  `multi_llm_review_wait` first) to observe completion.
- **When to use**: portable execution (other MCP hosts, autonomous Agent SkillSet),
  or any case where you want the consensus computation done server-side.
- **Recommended chain (3-step)**: `multi_llm_review` → `multi_llm_review_wait` →
  `multi_llm_review_collect`. Each Phase-1/1.5 response carries a `next_action`
  hint pointing at the next tool. wait is optional but recommended — without it,
  collect's internal polling still covers worker completion, but recovery hints
  for `still_pending`, `crashed`, and `past_collect_deadline` are less explicit.
- **Reference**: see "Orchestrator Delegation Protocol" + "Async/Parallel Collect
  Timing — Iron Rule" sections below.

### Quick selector

| Question | Answer |
|----------|--------|
| Are you in an interactive Claude Code session and just need one review? | **Path A** |
| Do you need this to work in Cursor / autonomous mode / other MCP host? | **Path B** |
| Do you want the consensus result inside the MCP tool response? | **Path B** |
| Did you observe `XX shells` in the statusbar last time it worked? | That was Path A |
| Did the run produce a `collect_token` and a `pending/<token>/` directory? | That was Path B |

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

- **3/4 APPROVE** (no REJECT) = proceed to next step
- **Any REJECT or FAIL** = revise and re-review
- **4/4 APPROVE** = highest confidence, proceed
- Legacy 3-reviewer mode: 2/3 APPROVE = proceed

### Consensus Patterns

| Agreement | Meaning | Action |
|-----------|---------|--------|
| **4/4** (or **3/3**) | Architectural-level gap | Must fix |
| **3/4** (or **2/3**) | Implementation-level issue | Should fix |
| **1/4 only** | Specialty-specific insight | Do NOT ignore — often the most novel finding |

1/4 (or 1/N) findings are not "minority opinions to discard." They represent unique expertise.

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
which claude 2>/dev/null && echo "claude: available" || echo "claude: NOT FOUND"
```

- All three available → Auto mode (4 reviewers, default)
- Codex + Agent only → Auto mode (3 reviewers, legacy)
- Any of codex/agent missing → Manual mode
- User override: `mode: manual` or `mode: auto`

### CLI Tool Matrix (Tested 2026-03-28)

| Tool | Command | Prompt Input | Output Collection | Model |
|------|---------|-------------|-------------------|-------|
| **Codex** | `codex exec` | stdin pipe: `cat prompt.md \| codex exec -` | `-o /path/output.md` | GPT-5.4 (default) |
| **Cursor Agent** | `agent -p` | File reference (stdin NOT supported) | stdout redirect: `> output.md` | Composer-2 (default) |
| **Claude Code** | Agent tool (internal) | Direct prompt string | Write to workspace file | Opus 4.6 (session) |
| **Claude CLI (4.7)** | `claude -p --model claude-opus-4-7 --bare` | stdin pipe: `cat prompt.md \| claude -p --model claude-opus-4-7 --bare` | stdout redirect: `> output.md` | Opus 4.7 |

### Model Detection

Before executing reviews, detect and record models:

```bash
codex exec -C . -o /dev/null "What model are you? Reply with only the model name."
agent --list-models 2>&1 | grep "(current\|default)"
# Claude Code: known from session
```

### Orchestrator Self-Identification (Self-Referential Model Reporting)

**Rule**: When invoking `multi_llm_review` (or running this workflow manually), the
orchestrating LLM MUST pass its own model identifier as `orchestrator_model`.

**Rationale**: The reviewer roster typically contains both Opus 4.6 and Opus 4.7
entries. To avoid the orchestrator reviewing its own output (no independent signal),
the dispatcher excludes any roster entry whose `model` matches `orchestrator_model`.
This keeps the same SkillSet useful regardless of which Opus version the user has
toggled to via `/model` — review composition adapts automatically.

**Why "argument-passing" not "file-introspection"**:
- The orchestrator's model identity lives in *its own context* (system prompt
  declares e.g. "You are powered by Opus 4.7"). No external file or env var is
  authoritative — `/model` switches change context immediately.
- MCP protocol does not transmit caller-model info; only the orchestrator can
  truthfully report its own identity. This is genuine self-reference: the system
  reports its own state to itself.
- Reading `~/.claude/projects/<cwd>/<sessionId>.jsonl` works but depends on
  Claude Code internals (format may change between versions). Argument-passing
  has zero internal-format dependency.

**How orchestrator obtains its model ID**:
- Claude Code sessions: read the system prompt line "You are powered by the
  model named ... The exact model ID is `claude-opus-X-Y`". Use the exact ID.
- Other hosts: use whatever introspection the host provides; if none, pass
  `null` and accept that no exclusion happens.

**Tool invocation example**:
```
multi_llm_review(
  artifact_path: "log/design.md",
  review_type: "design",
  orchestrator_model: "claude-opus-4-7"   # MUST be set by caller
)
```

**Dispatcher behavior** (config: `exclude_orchestrator_model: true`, default `true`):
- If `orchestrator_model` matches a roster entry's `model`, that entry is skipped.
- `min_quorum` and `convergence_rule` apply to the remaining reviewers.
- 4-reviewer roster → 3 reviewer; recommended `convergence_rule: "2/3 APPROVE"`
  when one Opus is excluded.
- If `orchestrator_model` is `null` or unmatched, full roster runs (back-compat).

**Manual-mode equivalent**: When orchestrating by hand, do not assign yourself
as a reviewer. Pick the *other* Opus version for the Claude CLI subprocess
reviewer (4.6 if you are 4.7, and vice versa).

### Orchestrator Delegation Protocol (Two-Phase, opt-in)

The `delegate` strategy lets the orchestrator perform persona-based "Agent Team"
review in its own context — preserving inherited project context that a fresh
`claude -p` subprocess loses. Subprocess reviewers (codex, cursor, opposite-Opus)
remain single-LLM.

**Why**: The orchestrator already holds the artifact in context with full project
awareness. Re-shipping it to a sandboxed subprocess discards that context. Same-
model persona switching gives stylistic / framing diversity (validated empirically);
cross-model subprocess reviewers give epistemic diversity. The two are complementary.

**Call 1**: `multi_llm_review(orchestrator_strategy: "delegate", orchestrator_model: "...")`
- SkillSet drops the orchestrator-matching reviewer from dispatch
- Subprocess reviewers run synchronously (no background threads)
- Subprocess results persisted to `.kairos/multi_llm_review/pending/<uuid>.json`
- Returns `status: "delegation_pending"`, `collect_token`, `persona_count_min/max`

**Orchestrator's obligation** (between calls):
- Recognize the `delegation_pending` status
- Spawn 2-4 parallel `Agent` tool calls with self-chosen personas appropriate to
  the artifact (e.g. design → architect/security/operability; code → correctness/
  performance/api-design; doc → ontologist/skeptic/integration)
- Collect persona results: each as `{persona, verdict (APPROVE|REVISE|REJECT),
  reasoning, findings: [{severity, issue}, ...]}`

**Call 2**: `multi_llm_review_collect(collect_token, orchestrator_reviews: [...])`
- Persona Assembly: any REJECT → REJECT; else any REVISE → REVISE; else APPROVE
- Assembled into one synthetic reviewer entry `claude_team_<orchestrator_model>`
- Combined with persisted subprocess results, run Consensus, return final verdict
- Idempotent: repeated calls with the same token return the cached result

**Failure modes**:
- `expired_or_unknown_token`: orchestrator missed `must_collect_by` deadline
  (default 1800s since v3.23.2; was 600s), or token never existed. The pending
  review is gone; call `multi_llm_review` again from scratch.
- `error: invalid orchestrator_reviews`: persona count outside 2-4 or missing
  required fields. Fix and retry collect with the same token.
- All-subprocess-failed at Call 1: returns error immediately; no token issued.

**Default**: `orchestrator_strategy` defaults to `"exclude"` (back-compat). Use
`"delegate"` explicitly until validated by use.

#### Async/Parallel Collect Timing — Iron Rule

When `delegation.parallel.default: true` (the v3.x default), Call 1 returns
`delegation_pending` **immediately** (~50ms) and a detached worker runs the
subprocess reviewers in parallel with the orchestrator's persona Agent
reviews. This is faster, but introduces a timing trap:

> **The orchestrator MUST call `multi_llm_review_collect` immediately after
> the persona Agent reviews complete — without intervening user dialogue,
> unrelated tool calls, or context switches.**

Why this matters:

- The LLM is **not event-driven**. When the worker finishes writing
  `subprocess_status: "done"` to `state.json`, nothing wakes the orchestrator.
  The orchestrator only notices when it next calls `multi_llm_review_collect`.
- `multi_llm_review_collect` already polls internally at
  `poll_interval_seconds: 0.5` for up to `collect_max_wait_seconds: 420` (7min)
  per call. Polling is not the bottleneck — the bottleneck is the orchestrator
  forgetting to call collect at all.
- The token expires at `collect_deadline` (default 30min since v3.23.2). If
  user dialogue or other work intervenes between persona Agent completion and
  the collect call, the token can expire while the subprocess results sit
  ready and unread on disk.

Recommended orchestrator flow (single LLM turn, no detours):

```
1. multi_llm_review(...) → receive delegation_pending + collect_token
2. Spawn persona Agent reviews (Agent tool, parallel, 2-4 personas)
3. As soon as ALL personas return → multi_llm_review_collect(collect_token, ...)
4. Return final consensus to user
```

Anti-pattern (do NOT do this):

```
1. multi_llm_review(...) → delegation_pending
2. Run persona Agent reviews
3. ❌ "By the way, while we wait, let me explain X to the user…"
4. ❌ User asks an unrelated question, conversation drifts
5. ❌ 30+ minutes later, finally try collect → expired_or_unknown_token
```

If the orchestrator is genuinely interrupted (user explicitly switches topic,
or persona Agent itself takes a long time and the orchestrator wants to
report progress), it should still **call collect first** — collect returns
quickly if the worker is already done, or blocks up to 7min if not. Either
way, the token stays alive and consensus is captured before resuming side
work.

Manual recovery if expiry happens: subprocess results are persisted at
`.kairos/multi_llm_review/pending/<token>/subprocess_results.json` and remain
readable until GC. Read them directly and synthesize manually, then re-run
`multi_llm_review` for fresh results if needed.

### Critical CLI Notes

- **Cursor Agent stdin**: `cat file | agent -p -` does NOT work. Use file-reference:
  `agent -p --trust "Read log/prompt.md and follow the instructions."`
- **Cursor Agent trust**: `--trust` required for headless/non-interactive mode
- **Codex workspace**: `-C /path/to/workspace` to set working directory
- **Claude Agent paths**: Write within workspace (e.g., `log/`), not `/tmp`
- **Claude CLI (Opus 4.7)**: `claude -p --model claude-opus-4-7 --bare` runs as external process. Uses stdin pipe (like Codex). `--bare` required for review tasks (skips hooks, CLAUDE.md, avoids bias from project instructions). Without `--bare`, CLAUDE.md's three-layer response structure may distort review output
- **Claude CLI parallelism**: Agent tool (internal, Opus 4.6) + Bash `claude -p` (external, Opus 4.7) run truly in parallel as separate processes
- **Claude CLI file access**: `claude -p` with `--bare` has no MCP tools or file access. Ensure review prompt includes all artifact content inline (rule #6). Use `--add-dir` + `--allowedTools "Read,Glob,Grep"` if file access is needed (but note: this loads CLAUDE.md unless `--bare` is also used)

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

### XML Block Structure for Review Prompts

Review prompts SHOULD use XML blocks to give LLMs explicit structural contracts.
This reduces hallucination, enforces grounded findings, and standardizes output.

```xml
<task>
Review the provided artifact for [review type: design correctness / implementation bugs / ...].
Target: [artifact name and version]
Scope: [what changed since last round, or "initial review"]
</task>

<structured_output_contract>
Output a Markdown file with this structure:
- **Reviewer**: [tool_name]
- **Model**: [model_id]
- **Date**: [ISO date]
- **Overall Verdict**: APPROVE / APPROVE WITH CHANGES / REJECT

For each finding:
- **Severity**: FAIL / HIGH / MEDIUM / LOW
- **Confidence**: 0.0-1.0 (how certain you are this is a real issue)
- **Location**: file:line or section reference
- **What can go wrong**: concrete failure scenario
- **Why this is vulnerable**: code path or design gap
- **Likely impact**: data loss, security breach, silent corruption, etc.
- **Recommended fix**: specific change (not "consider improving")
</structured_output_contract>

<grounding_rules>
Ground every finding in the provided artifact text or referenced source files.
If a claim is an inference (not directly visible in the artifact), label it:
  "[INFERRED] Based on X, this likely means Y."
Do not invent files, methods, or runtime behavior not shown in the artifact.
Keep confidence scores honest — 0.5 if uncertain, 0.9+ only if directly evidenced.
</grounding_rules>

<verification_loop>
Before finalizing your review:
1. Re-read each FAIL/HIGH finding. Is the failure scenario concrete and reproducible?
2. Check for second-order failures: empty-state, retry, stale state, rollback risk.
3. Verify file paths and line numbers are accurate.
4. If you found zero issues, state that explicitly — do not manufacture findings.
</verification_loop>

<default_follow_through_policy>
Complete the full review in one pass. Do not ask clarifying questions.
If context is missing, note it as a finding with severity LOW and confidence 0.3.
</default_follow_through_policy>
```

**Usage**: Include these XML blocks in the prompt body (rule #3 "Review instructions").
They replace or supplement free-form review instructions. The blocks are
LLM-agnostic and work with Claude, GPT, and Composer models.

**When to use full XML blocks vs. lightweight**:
- **Full** (all 5 blocks): Design review, implementation review, security-critical
- **Lightweight** (`<task>` + `<structured_output_contract>` only): Fix plan review, document review

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
  - Run: which codex && which agent && which claude
  - Detect default models
  - Report: "Auto mode: Codex (gpt-5.4), Agent (composer-2), Claude (opus-4.6), Claude CLI (opus-4.7)"

Step 3: Execute N reviews in parallel (default 4 reviewers)
  - Bash(background): cat prompt.md | codex exec -C workspace -o log/review_codex.md -
  - Bash(background): agent -p --trust "Read prompt and review..." > log/review_cursor.md
  - Agent(background): Claude Team (Opus 4.6) → write to log/review_claude_opus4.6.md
  - Bash(background): cat prompt.md | claude -p --model claude-opus-4-7 --bare > log/review_claude_opus4.7.md 2>log/review_claude_opus4.7.stderr.log

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

LLM identifiers: `claude_opus4.6`, `claude_team_opus4.6`,
`claude_cli_opus4.7`, `codex_gpt5.4`, `cursor_composer2`, `cursor_gpt5.4`,
`cursor_premium`

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
- Don't dismiss 1/4 (or 1/N) findings without evaluating substance
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
- Self-referential review: v3.2 (4-reviewer update, 2026-04-19) reviewed with new 4-reviewer default (Opus 4.6 + 4.7 + Codex + Composer-2). 4/4 APPROVE WITH CHANGES R1. Findings integrated → v3.3

**Key insight**: Design reviews and implementation reviews find
**categorically different bugs**. Both phases are necessary.
