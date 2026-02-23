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

## Safety Notes

- L0 changes require explicit human approval — the system will prompt you
- `core_safety` skill is immutable and cannot be modified
- All L0 and L1 changes are automatically recorded on the blockchain
- Evolution (L0 self-modification) is disabled by default

## Learn More

Use `skills_list` and `skills_get` to read KairosChain's full philosophy.
Use `tool_guide(command: "workflow")` to see common workflow patterns.
