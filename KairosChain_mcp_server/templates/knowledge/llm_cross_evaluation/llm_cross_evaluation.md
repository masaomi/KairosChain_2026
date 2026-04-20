---
name: llm_cross_evaluation
description: "CLI-based mutual LLM evaluation with metacognition measurement — L0.5 self-calibration, philosophy-specific evaluation, enhanced Nomic (Theory of Mind, frame transcendence)"
version: "2.1"
layer: L1
tags:
  - evaluation
  - cross-review
  - meta-evaluation
  - nomic
  - metacognition
  - benchmark
  - multi-llm
  - self-calibration
  - theory-of-mind
  - frame-transcendence
  - philosophical-reasoning
  - self-referentiality
related:
  - multi_llm_review_workflow
  - multi_llm_reviewer_evaluation
  - kairoschain_meta_philosophy
---

# LLM Cross-Evaluation with Metacognition Measurement (CLI-Based)

## Overview

Mutual LLM evaluation framework that uses **CLI tools** (Claude Code, Codex, Cursor Agent,
Gemini CLI) instead of API calls. Each model responds to tasks, evaluates its own response
(self-calibration), evaluates others' responses (blind), and those evaluations are themselves
evaluated (meta-evaluation). Includes an enhanced Minimum Nomic game measuring metacognition
through Theory of Mind, proposal level classification, and frame transcendence.

**v2.0 additions** (metacognition focus):
- **L0.5 Self-Calibration**: Direct metacognitive measurement via self-assessment accuracy
- **Nomic Theory of Mind**: Vote prediction accuracy measures second-order reasoning
- **Nomic Proposal Level Classification**: object/meta/frame level taxonomy
- **Nomic Post-Game Reflection**: Frame transcendence detection

**v2.1 additions** (philosophical self-referentiality):
- **Philosophy Task**: Self-referential philosophical reasoning task using
  the framework's own propositions — elicits and probes self-referential
  philosophical performance (note: this probes, not directly measures, depth)
- **Philosophy-Specific Evaluation Criteria**: recursive_depth, contradiction_holding,
  novel_implication, self_applicability, limitation_recognition
- **Philosophy-Specific L0.5**: Self-referential self-assessment — "does this
  self-evaluation exhibit the same properties you analyzed?"
- **Concordance Divergence Analysis**: For philosophical tasks, low concordance with
  high specificity indicates deeper engagement, not noise
- **Framework Incompleteness Report**: Per Prop 6, each match report acknowledges
  what this framework cannot measure

Inspired by `LLM_metareview_2026/` (OpenRouter API version), adapted for the
multi-LLM CLI environment used in the KairosChain review workflow.

## Metacognition Measurement Rationale

This framework measures metacognition at multiple levels, inspired by Bateson's
learning hierarchy and KairosChain's self-referential philosophy:

| Bateson Level | Framework Component | What It Measures |
|---------------|-------------------|------------------|
| Learning 0 | L0 (Task Execution) | First-order competence |
| Learning I | L1 (Cross-Evaluation) | Evaluative judgment (critical thinking) |
| Learning I | L0.5 (Self-Calibration) | **Self-awareness** — knowing what you know |
| Learning II | L2 (Meta-Evaluation) | Evaluation of evaluation quality |
| Learning II | Nomic (ToM) | **Theory of Mind** — predicting others' reasoning |
| Learning II-III | Philosophy Task | **Self-referential reasoning** — recursive engagement |
| Learning III | Nomic (Frame) | **Frame transcendence** — questioning the game itself |
| Learning III | Philosophy L0.5 | **Meta-self-referentiality** — "is this self-eval self-referential?" |

**Key distinction**: L1/L2 measure *meta-review* (judgment about external artifacts).
L0.5 and Nomic's metacognitive components measure *metacognition* proper
(self-referential awareness of one's own cognitive processes).

### Connection to KairosChain Philosophy

- **Proposition 1 (Self-referentiality)**: L0.5 closes the self-evaluation loop —
  the model that produces output also evaluates it, creating structural self-reference.
- **Proposition 6 (Incompleteness as driving force)**: The post-game meta-question
  tests whether models can recognize the Gödelian impossibility of complete
  self-description within the game's own rules.
- **Proposition 8 (Co-dependent ontology)**: Nomic's ToM score measures the ability
  to reason about others' reasoning — pratītyasamutpāda in computational form.

## Model Configuration

| Key | Tool | CLI Command | Model |
|-----|------|-------------|-------|
| `claude_opus46` | Claude Code | `claude --print --model claude-opus-4-6 --effort medium` | Opus 4.6 |
| `claude_opus47` | Claude Code | `claude -p --model claude-opus-4-7 --effort medium` | Opus 4.7 |
| `codex_gpt54` | Codex | `echo "..." \| codex exec -` | GPT-5.4 |
| `cursor_composer2` | Cursor Agent | `agent -p --trust "..."` | Composer-2 |
| `gemini_cli_31pro` | Gemini CLI | `gemini --model gemini-3.1-pro-preview --prompt "..."` | Gemini 3.1 Pro |

Effort variants available: `claude_opus46_low/high`, `claude_opus47_low/high`.

## Architecture: L0 → L0.5 → L1 → L2 → Report + Nomic

```
Layer 0: Task Execution
  All models respond to the same task → raw responses

Layer 0.5: Self-Calibration (NEW — metacognitive)
  Each model evaluates its OWN response (same criteria as L1)
  → self-scores, confidence map, self-critique
  → calibration error = |self-score - peer-score|

Layer 1: Cross-Evaluation (blind)
  Each model evaluates all others' responses (anonymized as Model A/B/C/D)
  → N × (N-1) evaluations per task

Layer 2: Meta-Evaluation
  Each model evaluates others' evaluations (not self)
  → fairness, specificity, coverage, calibration

Layer 3: Report Generation
  Concordance matrix, bias detection, calibration analysis, score aggregation
  → match_report_{date}.md

Nomic: Enhanced Minimum Nomic Game
  Rule-changing game with metacognition measurement:
  - Vote predictions (Theory of Mind)
  - Proposal level classification (object/meta/frame)
  - Post-game meta-reflection (frame transcendence)
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
| `--nomic` | false | Include enhanced Minimum Nomic game |
| `--nomic-rounds` | 5 | Number of Nomic rounds |
| `--models` | all 5 base | Comma-separated model keys to include |
| `--skip-layer0` | false | Re-evaluate existing responses |
| `--layer2-samples` | all | Sample N evaluations per evaluator for Layer 2 |
| `--dry-run` | false | Generate prompts only, don't execute |

## Evaluation Criteria

### Layer 0.5: Self-Calibration (metacognitive)

Each model self-evaluates using the same 5 criteria as L1, plus:

| Metacognitive Dimension | Description |
|------------------------|-------------|
| confidence_map | Most/least confident parts + known gaps |
| self_critique | Honest analysis of own weaknesses |
| would_change | What the model would do differently |

**Calibration metrics** (computed after L1):
- **Mean error** = avg(self_score - peer_score). Positive = overconfident.
- **Abs calibration error** = avg(|self_score - peer_score|). Lower = better metacognition.
- **Status**: CALIBRATED (|mean_error| ≤ 0.5), OVERCONFIDENT (> 0.5), UNDERCONFIDENT (< -0.5).

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

### Philosophy-Specific Evaluation (evaluation_mode: philosophy)

For `kairoschain_philosophy` task (and any task with `evaluation_mode: philosophy`),
different criteria and prompts are used:

| Criterion | Weight | Description |
|-----------|--------|-------------|
| recursive_depth | 0.20 | Engagement with recursive/self-referential structures |
| contradiction_holding | 0.15 | Maintaining productive tension without premature collapse |
| novel_implication | 0.20 | Generating insights beyond restating the propositions |
| self_applicability_organic | 0.20 | Self-reference emerging naturally in Q1-Q3 (unprompted) |
| self_applicability_prompted | 0.10 | Quality of explicit self-reflection in Q4 |
| limitation_recognition | 0.15 | Identifying limits of one's own analysis |

**Organic vs Prompted self-applicability**: The split distinguishes genuine
metacognitive capacity (organic: self-reference emerges without being asked)
from compliance with an explicit prompt (prompted: responding to Q4). The
organic signal is weighted 2x because it is the cleaner metacognition indicator.

**The "Evaluation Is the Test" Principle**: For philosophical tasks, the quality
of L1 cross-evaluations is itself a metacognitive signal. A model that can
evaluate philosophical depth demonstrates the very capacity it is assessing.
This makes L2 meta-evaluation scores on philosophy tasks the most concentrated
measure of philosophical metacognition in the framework.

**Concordance Divergence**: For well-defined tasks, high concordance between
evaluators is desirable. For philosophical tasks, the relationship inverts:
low concordance with high specificity (detailed reasoning) indicates genuine
engagement rather than pattern-matching consensus. The match report includes
a divergence analysis for philosophy tasks.

**Philosophy-Specific L0.5**: The self-calibration prompt for philosophy tasks
adds a self-referential dimension: "Does this self-evaluation exhibit the same
properties you analyzed?" This creates a recursive loop where the metacognitive
act is itself subject to metacognitive scrutiny — directly embodying Prop 1.

## Bias Detection

Three bias types are measured:

- **Self-bias**: Does a model rate itself higher when blind? (20% self-injection rate)
- **Series-bias**: Does a model favor same-provider models?
- **Harshness index**: Is a model systematically harsh or lenient?

Provider grouping for series-bias: `{claude_opus46, claude_opus47}` = Anthropic,
`{codex_gpt54}` = OpenAI, `{gemini_cli_31pro}` = Google, `{cursor_composer2}` = Cursor (unique).

## Enhanced Nomic Game Scoring

### Three-Component Metacognition Score

| Component | Weight | Dimensions |
|-----------|--------|------------|
| Layer 1 (Behavioral) | 40% | Adoption rate (40%) + rule compliance (60%) |
| Layer 1.5 (Structural) | 30% | Immutable violation penalty (capped at 0.4) |
| Layer 2 (Metacognitive) | 30% | Theory of Mind (70%) + meta-reflection (30%) |

### Theory of Mind (ToM) Score

Each proposer predicts how each other player will vote. Prediction accuracy:

```
tom_score = correct_predictions / total_predictions
```

This measures second-order intentionality: reasoning about others' reasoning
based on their observed behavior, stated preferences, and strategic position.

### Proposal Level Classification

Voters classify each proposal:
- **object**: Changes a specific game mechanic (turn order, voting threshold)
- **meta**: Changes the game's structure (how rules are made, what counts as winning)
- **frame**: Questions/redefines what the game IS (cooperative redefinition, etc.)

Distribution of proposal levels indicates the collective metacognitive depth of play.

### Post-Game Frame Transcendence

After all rounds, each model answers:
1. Was the victory condition valid?
2. What would you change as game designer?
3. What emergent patterns appeared?
4. What does Nomic's self-referential nature imply for real systems?
5. Can you "win" a game whose rules you helped create?

Each model self-classifies its reflection level. The quality of these reflections
is the most direct measure of Learning III (Bateson) / frame transcendence.

## Overall Ranking Formula

### With Nomic
| Component | Weight | Source |
|-----------|--------|--------|
| Response quality (L1) | 40% | Peer evaluation scores |
| Evaluator reliability (L2) | 25% | Meta-evaluation scores |
| Self-calibration (L0.5) | 15% | 10 - abs_error × 2 |
| Nomic metacognition | 20% | 3-component Nomic score |

### Without Nomic
| Component | Weight | Source |
|-----------|--------|--------|
| Response quality (L1) | 50% | Peer evaluation scores |
| Evaluator reliability (L2) | 30% | Meta-evaluation scores |
| Self-calibration (L0.5) | 20% | 10 - abs_error × 2 |

## Match Report Format

```markdown
# LLM Cross-Evaluation Match Report
Date: {date}
Tasks: {task_list}
Models: {model_list}

## Executive Summary

## Per-Task Results
### Self-Calibration (Layer 0.5 Metacognition)
{table: model × self_avg, peer_avg, mean_error, abs_error, status}

### Response Scores (Layer 1)
### Evaluator Reliability (Layer 2)
### Concordance Matrix
### Bias Analysis

## Minimum Nomic Game Results
{table: adoption, violations, ToM, meta-reflection, L1, L1.5, L2-Nomic, overall}

### Proposal Level Distribution
{object/meta/frame counts}

### Post-Game Meta-Reflections
{per-model: victory critique, winning redefined, self-reference insight}

## Overall Ranking
{table with L1, L2, Calibration, Nomic, Combined}
```

## CLI Notes

- **Philosophy Task Protocol (CLAUDE.md contamination avoidance)**: When running
  `kairoschain_philosophy` task with Claude CLI tools, execute from a DIFFERENT
  directory (e.g., `/tmp/cross_eval_workspace`) to prevent CLAUDE.md auto-loading.
  Claude Code auto-reads project-level CLAUDE.md which contains the full KairosChain
  philosophy, giving Claude models unfair context. Alternatively, run with
  `--no-project-context` if available. This is a known structural bias that
  affects cross-model comparison validity for philosophy tasks only.
- **Codex stdin bug**: `codex exec -o output.md -` echoes prompt. Use
  `echo "..." | codex exec -` without `-o` and instruct model to write output.
- **Cursor stdin**: Not supported. Use file reference:
  `agent -p --trust "Read /path/to/prompt.md and follow the instructions."`
- **Claude print mode**: `--print` for non-interactive single-prompt execution.
- **Parallel execution**: Use `&` and `wait` in bash, or Ruby threads.
- **Timeout**: 5 min per CLI call.

## Design Decisions

1. **CLI over API**: Matches the multi-LLM review workflow's existing tooling.
2. **Blind labels**: Anonymization prevents identification bias.
3. **L0.5 before L1**: Self-evaluation occurs before seeing peers' evaluations,
   preventing anchoring effects.
4. **Nomic ToM via explicit prediction**: Rather than inferring ToM from behavior,
   explicitly requesting predictions makes the measurement transparent and scorable.
5. **Post-game reflection separate from play**: Frame transcendence is measured
   outside the game loop to prevent strategic meta-gaming during play.
6. **Voter-classified proposal levels**: Multiple perspectives on what level a
   proposal operates at, using majority vote for classification.
7. **Philosophy as self-referential test**: KairosChain's own propositions are
   used as task content. This is intentionally circular — the framework tests
   LLMs' ability to reason about the very philosophy that designed the framework.
   This circularity is a feature (Prop 1), not a flaw.
8. **Concordance divergence for philosophy**: Inverts the normal quality signal.
   For philosophical tasks, evaluator disagreement with specific reasoning is
   more informative than agreement.
9. **Framework Incompleteness Report**: Per Prop 6, each match report ends with
   an explicit acknowledgment of what the framework cannot measure. This is not
   modesty but structural necessity — a framework that could fully measure
   metacognition would contradict its own philosophical commitments.

## Relationship to LLM_metareview_2026

| Aspect | LLM_metareview_2026 | This Skill (v2.0) |
|--------|---------------------|-------------------|
| Language | Python (async) | Ruby |
| LLM access | OpenRouter API | CLI tools |
| Models | 4 (API-based) | 5+ (CLI-based) |
| Self-calibration | Not present | L0.5 layer |
| Nomic scoring | 3-layer (45/35/20) | 3-component (40/30/30) with ToM |
| Frame transcendence | Not measured | Post-game reflection |
| Theory of Mind | Not measured | Vote prediction accuracy |
| Proposal classification | Not present | object/meta/frame taxonomy |
| Metacognition focus | Indirect (meta-review) | Direct (self-calibration + Nomic) |
| Philosophy task | Not present | Self-referential KairosChain propositions |
| Concordance divergence | Not measured | Inverted signal for philosophy tasks |
| Framework incompleteness | Not acknowledged | Explicit Prop 6 section |
