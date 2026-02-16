---
name: kairos-chain
description: >
  Self-amendment MCP server framework with layered skill architecture and blockchain auditability.
  Use when the user wants to manage knowledge, evolve skills, track changes with blockchain,
  audit skill health, promote knowledge between layers, or perform persona assembly for decision support.
---

# KairosChain - Self-Amendment MCP Server Framework

KairosChain provides a layered skill architecture (L0/L1/L2) where skills can evolve, promote, and audit themselves with blockchain-backed auditability.

## Architecture

### Three-Layer System
- **L0 (Constitution/Law)**: Immutable safety rules and meta-governance. Changes require human approval and full blockchain recording.
- **L1 (Knowledge)**: Project knowledge in Anthropic skills format. Changes recorded with hash references.
- **L2 (Context)**: Temporary session context. Free modification, no blockchain recording.

### Core Capabilities

#### Knowledge Management
- `knowledge_list` / `knowledge_get` - Browse and read L1 knowledge skills
- `knowledge_update` - Create, update, or delete L1 knowledge with blockchain recording
- `context_save` - Save temporary L2 context for session work

#### Skill Evolution
- `skills_evolve` - Propose and apply changes to L0 skill definitions (requires human approval)
- `skills_rollback` - Version management with snapshot and rollback capabilities
- `skills_promote` - Promote knowledge between layers (L2→L1, L1→L0) with optional Persona Assembly

#### Blockchain Auditability
- `chain_status` / `chain_verify` - Check and verify blockchain integrity
- `chain_history` - View skill transitions, knowledge updates, and state commits
- `chain_record` - Record data to the blockchain
- `state_commit` - Create snapshots of all layers for auditability

#### Health & Safety
- `skills_audit` - Audit knowledge health across layers (conflicts, staleness, dangerous patterns)
- `tool_guide` - Dynamic tool discovery and workflow recommendations

#### Persona Assembly
- Multi-perspective decision support using personas (kairos, conservative, radical, pragmatic, optimistic, skeptic)
- Available in `skills_promote` and `skills_audit` with `assembly_mode: "discussion"`

## Recommended Workflows

### Knowledge Lifecycle
1. Start with `context_save` for temporary work (L2)
2. When knowledge proves valuable, use `skills_promote` to move L2→L1
3. For mature patterns, promote L1→L0 with human approval

### Health Check
1. Run `skills_audit command="check"` for overall health
2. Use `skills_audit command="dangerous"` to check for safety issues
3. Review `skills_audit command="recommend"` for promotion/archive suggestions

### Skill Evolution
1. Use `skills_dsl_list` / `skills_dsl_get` to inspect current L0 skills
2. Propose changes with `skills_evolve command="propose"`
3. Apply with human approval via `skills_evolve command="apply"`
