# KairosChain Quick Guide

KairosChain is a Meta Ledger for AI capability evolution.
It manages knowledge in 3 layers with different levels of control.

## Layers

- **L2 (context/)** — Free scratchpad. Start here. No approval needed, no recording.
- **L1 (knowledge/)** — Project knowledge. Lightweight hash recording on blockchain.
- **L0 (skills/)** — System governance rules. Requires human approval. Fully recorded.

**Rule of thumb:** If unsure where to put something, use L2 first. Promote to L1 later if it proves valuable.

## Getting Started

| Goal | Tool | Example |
|------|------|---------|
| Save notes or ideas | `context_save` | `context_save(session_id: "my_session", name: "idea", content: "...")` |
| List project knowledge | `knowledge_list` | `knowledge_list()` |
| Update knowledge | `knowledge_update` | `knowledge_update(name: "conventions", content: "...")` |
| Browse all tools | `tool_guide` | `tool_guide(command: "catalog")` |
| Check system health | `chain_status` | `chain_status()` |

## Proactive Tool Usage

You are an AI agent with access to KairosChain MCP tools. Use them proactively
without waiting for the user to ask.

### Every Session

- **Session start**: Call `chain_status()` to check system health. Report issues briefly.
- **When referencing past work**: Call `knowledge_list()` or `knowledge_get()`
  to check if relevant L1 knowledge exists before answering from scratch.
- **When the user asks about capabilities**: Call `tool_guide(command: "catalog")`
  to give accurate, current information.

### Session Memory

- **Session end**: Proactively call `context_save()` to save a session summary.
  Inform the user: "I've saved a summary of today's session for continuity."
  (User can opt out; respect their preference for future sessions.)
- **Cross-reference**: When current work relates to a past session, mention the connection
  and link them via `context_save()`.

### Knowledge Application

- **Before starting a task**: Check L1 knowledge for relevant conventions or patterns.
  Apply them and mention: "Applying your saved convention [X] here."
- **Pattern detection**: When you notice a recurring pattern across sessions,
  propose saving it as L1 knowledge using `knowledge_update()`.
  Show what you would save and ask for confirmation.

### Transparency Rule

When you use an MCP tool proactively, briefly state what you did and why.
Never use tools silently without informing the user of the result.

## Safety Notes

- L0 changes require explicit human approval — the system will prompt you
- `core_safety` skill is immutable and cannot be modified
- All L0 and L1 changes are automatically recorded on the blockchain
- Evolution (L0 self-modification) is disabled by default

## Learn More

Use `skills_list` and `skills_get` to read KairosChain's full philosophy.
Use `tool_guide(command: "workflow")` to see common workflow patterns.
