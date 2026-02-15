---
name: kairoschain_philosophy
description: "KairosChain philosophy, architecture, and layered skill design"
version: 1.0
layer: L1
tags: [documentation, readme, philosophy, architecture, layers, data-model]
readme_order: 1
readme_lang: en
---

## Philosophy

### The Problem

The biggest black box in LLM/AI agents is:

> **The inability to explain how current capabilities were formed.**

- Prompts are volatile
- Tool call histories are fragmented
- Skill evolution (redefinition, synthesis, deletion) leaves no trace

As a result, AI becomes an entity whose **causal process cannot be verified by third parties**, even when it:
- Becomes more capable
- Changes behavior
- Becomes potentially dangerous

### The Solution: KairosChain

KairosChain addresses this by:

1. **Defining skills as executable structures** (Ruby DSL), not just documentation
2. **Recording every skill change** on an immutable blockchain
3. **Enabling self-reference** so AI can inspect its own capabilities
4. **Enforcing safe evolution** with approval workflows and immutability rules

KairosChain is not a platform, currency, or DAO. It is a **Meta Ledger** — an audit trail for capability evolution.

### Minimum-Nomic Principle

KairosChain implements **Minimum-Nomic** — a system where:

- Rules (skills) **can** be changed
- But **who**, **when**, **what**, and **how** they were changed is always recorded and cannot be erased

This avoids both extremes:
- ❌ Completely fixed rules (no adaptation)
- ❌ Unrestricted self-modification (chaos)

Instead, we achieve: **Evolvable but not gameable systems**.

## Architecture

![KairosChain Layered Architecture](docs/kairoschain_linkedin_diagram.png)

*Figure: KairosChain's legal-system-inspired layered architecture for AI skill management*

### System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    MCP Client (Cursor / Claude Code)            │
└───────────────────────────────┬─────────────────────────────────┘
                                │ STDIO (JSON-RPC)
                                │   or
                                │ Streamable HTTP (POST /mcp)
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    KairosChain MCP Server                        │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────────┐ │
│  │ Server/HTTP  │ │   Protocol   │ │     Tool Registry        │ │
│  │ STDIO/Puma   │ │  JSON-RPC    │ │  23+ Tools Available     │ │
│  └──────────────┘ └──────────────┘ └──────────────────────────┘ │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Skills Layer                           │   │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────────────────┐│   │
│  │  │ kairos.rb  │ │ kairos.md  │ │    Kairos Module       ││   │
│  │  │ (DSL)      │ │ (Markdown) │ │  (Self-Reference)      ││   │
│  │  └────────────┘ └────────────┘ └────────────────────────┘│   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   Blockchain Layer                        │   │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────────────────┐│   │
│  │  │   Block    │ │   Chain    │ │     MerkleTree         ││   │
│  │  │ (SHA-256)  │ │ (JSON)     │ │  (Proof Generation)    ││   │
│  │  └────────────┘ └────────────┘ └────────────────────────┘│   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Layered Skills Architecture

KairosChain implements a **legal-system-inspired layered architecture** for knowledge management:

| Layer | Legal Analogy | Path | Blockchain Record (per-operation) | Mutability |
|-------|---------------|------|----------------------------------|------------|
| **L0-A** | Constitution | `skills/kairos.md` | - | Read-only |
| **L0-B** | Law | `skills/kairos.rb` | Full transaction | Human approval required |
| **L1** | Ordinance | `knowledge/` | Hash reference only | Lightweight constraints |
| **L2** | Directive | `context/` | None* | Free modification |

*Note: While individual L2 operations are not recorded, [StateCommit](#state-commit-tools-auditability) periodically captures all layers (including L2) in off-chain snapshots with on-chain hash references.

### L0: Kairos Core (`skills/`)

The foundation of KairosChain. Contains meta-rules about self-modification.

- **kairos.md**: Philosophy and principles (immutable, read-only)
- **kairos.rb**: Meta-skills in Ruby DSL (modifiable with full blockchain record)

Only these meta-skills can be placed in L0:
- `l0_governance`, `core_safety`, `evolution_rules`, `layer_awareness`, `approval_workflow`, `self_inspection`, `chain_awareness`, `audit_rules`

> **Note: L0 Self-Governance**  
> The `l0_governance` skill now defines which skills can exist in L0, implementing the Pure Agent Skill principle: all L0 governance criteria must be defined within L0 itself. See the [Pure Agent Skill FAQ](#q-what-is-pure-agent-skill-and-why-does-it-matter) for details.

> **Note: Skill-Tool Unification**  
> Skills in `kairos.rb` can also define MCP tools via the `tool` block. When `skill_tools_enabled: true` is set in config, these skills are automatically registered as MCP tools. This means **skills and tools are unified in L0-B** — you can add, modify, or remove tools by editing `kairos.rb` (subject to L0 constraints: human approval required, full blockchain record).

### L1: Knowledge Layer (`knowledge/`)

Project-specific universal knowledge in **Anthropic Skills format**.

```
knowledge/
└── skill_name/
    ├── skill_name.md       # YAML frontmatter + Markdown
    ├── scripts/            # Executable scripts (Python, Bash, Node)
    ├── assets/             # Templates, images, CSS
    └── references/         # Reference materials, datasets
```

Example `skill_name.md`:

```markdown
---
name: coding_rules
description: Project coding conventions
version: "1.0"
layer: L1
tags: [style, convention]
---

# Coding Rules

## Naming Conventions
- Class names: PascalCase
- Method names: snake_case
```

### L2: Context Layer (`context/`)

Temporary context for sessions. Same format as L1 but **no per-operation blockchain recording**.

```
context/
└── session_id/
    └── hypothesis/
        └── hypothesis.md
```

Use for:
- Working hypotheses
- Scratch notes
- Trial-and-error exploration

> **Note**: While individual L2 changes are not recorded, the [StateCommit](#state-commit-tools-auditability) feature can capture L2 state in periodic snapshots (stored off-chain with on-chain hash references).

### Why Layered Architecture?

1. **Not all knowledge needs the same constraints** — temporary thoughts shouldn't require per-operation blockchain records
2. **Separation of concerns** — Kairos meta-rules vs. project knowledge vs. temporary context
3. **AI autonomy with accountability** — free exploration in L2, tracked changes in L1, strict control in L0
4. **Cross-layer auditability** — [StateCommit](#state-commit-tools-auditability) enables periodic snapshots of all layers together for holistic audit trails

## Data Model: SkillStateTransition

Every skill change is recorded as a `SkillStateTransition`:

```ruby
{
  skill_id: String,        # Skill identifier
  prev_ast_hash: String,   # SHA-256 of previous AST
  next_ast_hash: String,   # SHA-256 of new AST
  diff_hash: String,       # SHA-256 of the diff
  actor: String,           # "Human" / "AI" / "System"
  agent_id: String,        # Kairos agent identifier
  timestamp: ISO8601,
  reason_ref: String       # Off-chain reason reference
}
```
