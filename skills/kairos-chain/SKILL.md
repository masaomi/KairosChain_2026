---
name: kairos-chain
description: >
  Self-amendment MCP server framework with layered skill architecture and blockchain auditability.
  Use when managing knowledge layers, evolving skills, auditing health, or understanding
  KairosChain's architecture and capabilities.
---

# KairosChain — Self-Amendment MCP Server Framework

KairosChain provides a layered skill architecture (L0/L1/L2) with blockchain-backed auditability.
All core functionality is provided via MCP tools. This skill provides an architectural overview
and guides you to per-SkillSet skills for detailed workflows.

## Three-Layer Architecture

### L0 — Constitution (Self-Referential)
Immutable safety rules and meta-governance. **L0 defines the rules that govern L0 itself** —
this structural self-referentiality is the foundation of KairosChain's design.
Changes require human approval and full blockchain recording.

### L1 — Knowledge
Project knowledge in structured format. Changes recorded with hash references.
Use `knowledge_list` and `knowledge_get` to browse, `skills_promote` to promote from L2.

### L2 — Context
Temporary session context. Free modification, no blockchain recording.
Use `context_save` for session work, promote to L1 when proven valuable.

## Key Principle: Layer Governance

```
L2 (free) → skills_promote → L1 (recorded) → skills_promote → L0 (human approval + blockchain)
```

Each layer has increasing governance requirements. This gradient ensures that
volatile ideas can be captured freely (L2) while stable knowledge is protected (L0).

## Per-SkillSet Skills

Detailed workflow guides are provided by individual SkillSets:
- **agent** — Cognitive OODA loop with autonomous mode
- **skillset_exchange** — P2P SkillSet exchange via Meeting Place
- **skillset_creator** — Scaffold and design new SkillSets
- **plugin_projector** — Manage Claude Code plugin projection
- **kairos-knowledge** — Browse available L1 knowledge (auto-generated)

Use `tool_guide` for dynamic tool discovery and workflow recommendations.

## When MCP Is Not Connected

If the MCP server is not running, these skills and agents are still visible but MCP tools
will not be available. To connect:
1. Ensure `gem install kairos-chain` is installed (Ruby 3.0+ required)
2. Check `.mcp.json` configuration in the project root
3. Restart Claude Code or run `/reload-plugins`
