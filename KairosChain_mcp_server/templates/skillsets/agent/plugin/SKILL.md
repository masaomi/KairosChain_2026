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
| `ClaudeCodeAdapter` | `claude -p --output-format json` | Sub-author (Sonnet 5.5), persona reviewers |
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

### MCP Tool Access — the act route is an allow-list

A step runs in the Act phase only if its tool is in the act-route table
(`lib/agent/act_classification.yml`: read-only tools, `context_save`,
`operator_report`, sandboxed `llm_call`, and `safe_file_write` / `safe_file_edit`
/ `safe_file_copy`). Every other step is set aside, with its dependents, and
returned to the operator at the end of the cycle as `awaiting_operator`.

Work-tree writes are allowed by place: a `safe_file_*` write runs only when
every location it names lands inside the table's `write_roots` (shipped:
`docs/drafts`) with one of its `write_extensions` (`.md`, `.txt`). Any other
write is set aside. With the guard on, every work-tree write is set aside,
because the confined route is not wired.

A withdrawal takes effect at the next `agent_step` call, not part-way through
a running call; it is not an emergency stop (use `agent_stop`).

The table is in force only while the operator's latest terminal ruling names
the sha256 of its bytes. A fresh install, an upgrade that changes the table, or
a withdrawal leaves the act route running nothing; every response says so under
`classification`. Rule it into force yourself, in a terminal (the tool refuses
to run without one):

    ruby .kairos/skillsets/agent/bin/agent_rule.rb status
    ruby .kairos/skillsets/agent/bin/agent_rule.rb activate

The file route (`agent_execute`) is closed until it is wired confined. Behind
the table, the 3.88.2 refusals stay: record-store and configuration writers,
`llm_call` with a provider that carries tools, and any step whose path
arguments reach the KairosChain stores, `.claude/`, `.codex/`, `.git/`,
`.github/`, `.vscode/`, `.cursor/`, `.gemini/`, `.mcp.json`, `.envrc`,
`CLAUDE.md`, `AGENTS.md`, or anywhere outside the project. LLM calls made by
the agent or its act run sandboxed. Do not run the agent unattended until the
approval-delegation work is complete.

## Sub-Agents

### `/kairos-chain:agent-monitor`
Post-session review agent. Invokes `agent_status`, `autonomos_status`, and `chain_history`
to summarize session progress and flag anomalies. Read-only — cannot modify state.

## Available Tools

<!-- AUTO_TOOLS -->
