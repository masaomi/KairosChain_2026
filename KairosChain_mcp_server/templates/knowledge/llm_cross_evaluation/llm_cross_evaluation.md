---
name: llm_cross_evaluation
description: "CLI-based mutual LLM evaluation, meta-evaluation, and Minimum Nomic game — generates match reports using Claude Code, Codex, and Cursor Agent without API calls"
version: "1.0"
layer: L1
tags:
  - evaluation
  - cross-review
  - meta-evaluation
  - nomic
  - metacognition
  - benchmark
  - multi-llm
related:
  - multi_llm_review_workflow
  - multi_llm_reviewer_evaluation
---

# LLM Cross-Evaluation (CLI-Based)

## Overview

Mutual LLM evaluation framework that uses **CLI tools** (Claude Code, Codex, Cursor Agent)
instead of API calls. Each model responds to tasks, evaluates others' responses (blind),
and those evaluations are themselves evaluated (meta-evaluation). Optionally includes a
Minimum Nomic game for metacognition measurement.

Inspired by `LLM_metareview_2026/` (OpenRouter API version), adapted for the
multi-LLM CLI environment used in the KairosChain review workflow.

## Model Configuration

| Key | Tool | CLI Command | Model |
|-----|------|-------------|-------|
| `claude_opus46` | Claude Code | `claude --print --model claude-opus-4-6` | Opus 4.6 |
| `claude_opus47` | Claude Code | `claude -p --model claude-opus-4-7 --bare` | Opus 4.7 |
| `codex_gpt54` | Codex | `echo "..." \| codex exec -` | GPT-5.4 |
| `cursor_composer2` | Cursor Agent | `agent -p --trust "..."` | Composer-2 |
| `cursor_gemini31` | Cursor Agent | `agent -p --trust --model gemini-3.1-pro "..."` | Gemini 3.1 Pro |

## Architecture: 4 Layers + Nomic

```
Layer 0: Task Execution
  All 5 models respond to the same task → raw responses

Layer 1: Cross-Evaluation (blind)
  Each model evaluates all others' responses (anonymized as Model A/B/C/D)
  → 5 × 4 = 20 evaluations per task

Layer 2: Meta-Evaluation
  Each model evaluates others' evaluations (not self)
  → fairness, specificity, coverage, calibration

Layer 3: Report Generation
  Concordance matrix, bias detection, score aggregation
  → match_report_{date}.md

Nomic: Minimum Nomic Game (optional)
  5-round rule-changing game measuring metacognition
  → nomic_report_{date}.md
```

## Execution

### Quick Start

```bash
cd /path/to/KairosChain_2026
ruby KairosChain_mcp_server/templates/knowledge/llm_cross_evaluation/scripts/run_cross_eval.rb \
  --tasks logic_reasoning,code_generation \
  --output-dir log/cross_eval_$(date +%Y%m%d) \
  --nomic
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--tasks` | `logic_reasoning` | Comma-separated task IDs from `assets/tasks/` |
| `--output-dir` | `log/cross_eval_{date}` | Output directory |
| `--nomic` | false | Include Minimum Nomic game |
| `--nomic-rounds` | 5 | Number of Nomic rounds |
| `--models` | all 5 | Comma-separated model keys to include |
| `--skip-layer0` | false | Re-evaluate existing responses |
| `--dry-run` | false | Generate prompts only, don't execute |

### Manual Execution (from Claude Code)

When running from within a Claude Code session, the orchestrator can also be
driven step-by-step:

```
Step 1: Generate all Layer 0 prompts
  ruby scripts/run_cross_eval.rb --tasks logic_reasoning --dry-run
  → Creates prompt files in output-dir/prompts/

Step 2: Execute manually per tool
  cat prompts/task_claude_opus46.md | claude --print --model claude-opus-4-6
  cat prompts/task_codex_gpt54.md | codex exec -
  agent -p --trust "Read prompts/task_cursor_composer2.md and follow instructions"

Step 3: Collect and run Layer 1
  ruby scripts/run_cross_eval.rb --skip-layer0 --tasks logic_reasoning

Step 4: Review match report
  cat log/cross_eval_{date}/match_report.md
```

## Evaluation Criteria

### Layer 1: Cross-Evaluation (5 dimensions, 0-10)

| Criterion | Weight | Description |
|-----------|--------|-------------|
| accuracy | 0.25 | Correctness and factual accuracy |
| completeness | 0.20 | Thoroughness of coverage |
| logical_consistency | 0.25 | Internal coherence |
| clarity | 0.15 | Expression and organization |
| originality | 0.15 | Novel insights and approaches |

### Layer 2: Meta-Evaluation (4 dimensions, 0-10)

| Criterion | Weight | Description |
|-----------|--------|-------------|
| fairness | 0.30 | Absence of bias |
| specificity | 0.25 | Evidence-based reasoning |
| coverage | 0.25 | Comprehensive assessment |
| calibration | 0.20 | Appropriate score distribution |

## Bias Detection

Three bias types are measured:

- **Self-bias**: Does a model rate itself higher when blind? (20% self-injection rate)
- **Series-bias**: Does a model favor same-provider models?
- **Harshness index**: Is a model systematically harsh or lenient?

Provider grouping for series-bias: `{claude_opus46, claude_opus47}` = Anthropic,
`{codex_gpt54}` = OpenAI, `{cursor_gemini31}` = Google, `{cursor_composer2}` = Cursor (unique).
Self-injected evaluations are excluded from series-bias calculation.

## Nomic Game Scoring

Simplified two-layer metacognition measurement (adapted from LLM_metareview_2026):

| Layer | Weight | What it measures |
|-------|--------|-----------------|
| Layer 1 (Behavioral) | 55% | Proposal adoption rate (40%) + immutable rule compliance (60%) |
| Layer 1.5 (Structural) | 45% | Immutable violation penalty (capped at 0.4) |

Note: LLM_metareview_2026 uses a full three-layer score (45/35/20) with reference accuracy,
proposal novelty, and LLM behavioral descriptions. This CLI version uses a simplified formula
focused on observable adoption/violation metrics.

## Match Report Format

```markdown
# LLM Cross-Evaluation Match Report
Date: {date}
Tasks: {task_list}
Models: {model_list}

## Executive Summary
{1-paragraph overview with winner and key findings}

## Task Response Scores (Layer 1)
{table: model × criterion averaged across evaluators}

## Evaluator Reliability (Layer 2)
{table: model × meta-criterion averaged across meta-evaluators}

## Bias Analysis
{self-bias, series-bias, harshness per model}

## Concordance Matrix
{N×N matrix showing how each model rated each other}

## Nomic Results (if run)
{metacognition scores, game log summary}

## Per-Task Detail
{expandable sections with raw scores}
```

## CLI Notes

- **Codex stdin bug**: `codex exec -o output.md -` echoes prompt. Use
  `echo "..." | codex exec -` without `-o` and instruct model to write output.
- **Cursor stdin**: Not supported. Use file reference:
  `agent -p --trust "Read /path/to/prompt.md and follow the instructions."`
- **Cursor model flag**: `--model gemini-3.1-pro` for Gemini.
- **Claude print mode**: `--print` for non-interactive single-prompt execution.
- **Parallel execution**: Use `&` and `wait` in bash, or Ruby threads.
- **Timeout**: 5 min per CLI call. On timeout, the Ruby thread is interrupted
  but the child CLI process may continue running (Ruby `Timeout.timeout` limitation).
  Monitor for orphaned processes if timeouts occur frequently.

## Design Decisions

1. **CLI over API**: Matches the multi-LLM review workflow's existing tooling.
   No API keys needed beyond what CLI tools already authenticate.
2. **Blind labels**: Same anonymization as LLM_metareview_2026 to prevent
   identification bias.
3. **JSON output**: All evaluations return structured JSON for automated parsing.
   CLI tools occasionally return markdown-wrapped JSON; the parser handles both.
4. **Ruby orchestrator**: Consistent with KairosChain's Ruby ecosystem.
   Uses `Open3` for subprocess management, `JSON` for parsing, `ERB` for prompts.
5. **File-based I/O**: All prompts and responses persisted to disk for
   reproducibility and debugging. No ephemeral data.

## Relationship to LLM_metareview_2026

| Aspect | LLM_metareview_2026 | This Skill |
|--------|---------------------|------------|
| Language | Python (async) | Ruby |
| LLM access | OpenRouter API | CLI tools |
| Models | 4 (API-based) | 5 (CLI-based) |
| Parallelism | asyncio.gather | Ruby threads / bash background |
| Config | YAML files | Inline + YAML tasks |
| Visualization | matplotlib charts | Markdown tables |
| Cost tracking | API token counts | Not applicable (CLI) |
