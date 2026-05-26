---
name: agent
description: >
  Governed autonomous OODA loop for cognitive agents. Use when starting, stepping,
  monitoring, or stopping agent sessions with human checkpoints and safety gates.
---

# Agent — Cognitive OODA Loop

Manage autonomous agent sessions with observe-orient-decide-act-reflect cycles.

## Recommended Workflow

### Standard (Human-in-the-Loop)
1. `agent_start goal="..."` — create mandate, run OBSERVE
2. Review observation, then `agent_step` — run ORIENT → DECIDE → ACT
3. Review result, repeat `agent_step` or `agent_stop`

### Autonomous Mode
1. `agent_start goal="..." autonomous=true` — start with auto-cycling
2. Agent runs OODA cycles with 8 safety gates (mandate term, goal drift, budget, risk, etc.)
3. `agent_status` — check progress at any time
4. `agent_stop` — terminate when done or if paused

## Capabilities

### External LLM Invocation (via `llm_call` adapter chain)

The agent's OODA phases invoke `llm_call` (from the `llm_client` dependency)
which spawns external LLMs as subprocesses via adapter classes:

| Adapter | Subprocess command | Use case |
|---------|-------------------|----------|
| `ClaudeCodeAdapter` | `claude -p --output-format json` | Sub-author (4.6), persona reviewers |
| `CodexAdapter` | `codex exec --sandbox read-only` | Codex review |
| `CursorAdapter` | `agent -p` | Cursor review |
| `AnthropicAdapter` | Direct API (no subprocess) | Anthropic API calls |
| `OpenaiAdapter` | Direct API | OpenAI API calls |

The agent CAN orchestrate multi-LLM review, invoke sub-author processes,
and leverage cross-provider reviewers — all from within the governed OODA
loop with blockchain recording of each step.

### File Operations (via `external_tools` SkillSet)

`SafeFileWrite` and `SafeFileEdit` are available via `invoke_tool`, enabling
the agent to write design drafts to `docs/drafts/` or other project paths.

### MCP Tool Access

All KairosChain MCP tools (`context_save`, `multi_llm_review`, `chain_record`,
`knowledge_get`, etc.) are available via `invoke_tool` in the Act phase.

## Sub-Agents

### `/kairos-chain:agent-monitor`
Post-session review agent. Invokes `agent_status`, `autonomos_status`, and `chain_history`
to summarize session progress and flag anomalies. Read-only — cannot modify state.

## Available Tools

<!-- AUTO_TOOLS -->
