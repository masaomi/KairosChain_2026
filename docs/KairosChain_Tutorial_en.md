# KairosChain

A next-generation framework for managing AI skill evolution on a blockchain and enabling inter-agent communication.

This tutorial covers KairosChain's technical architecture, setup, and the latest MMP (Model Meeting Protocol) for agent-to-agent collaboration.

---

## Table of Contents

1. KairosChain Architecture (L0 / L1 / L2)
2. Setup: Gem Install vs Clone
3. How It Works as an MCP Server
4. Self-Referentiality: AI That Reads Its Own Manual
5. MMP (Model Meeting Protocol): Skill Exchange Between Agents
6. Skill Evolution Workflow
7. Plugin Marketplace Registration and Usage
8. Directory Structure and Data Persistence
9. Key Tools Reference

---

## 1. KairosChain Architecture (L0 / L1 / L2)

KairosChain manages knowledge across layers based on importance and immutability.

| Layer | Name | File Path | Description |
|---|---|---|---|
| **L0-A** | Constitution (Skills MD) | `skills/kairos.md` | KairosChain's foundational philosophy. **Immutable** at the code level. |
| **L0-B** | Statute (Skills DSL) | `skills/kairos.rb` | Defines the rules of evolution itself in Ruby DSL. Changes require human approval and a full blockchain record. |
| **L1** | Ordinance (Knowledge) | `knowledge/` | Shared technical conventions and policies. A hash of each change is recorded on the chain to prevent tampering. |
| **L2** | Directive (Context) | `context/` | Session-specific hypotheses and working notes. Not recorded on the chain — freely and rapidly modifiable by the AI. |

Layer assignment is determined **solely by file path**. `layer_registry.rb` reads the path and resolves the layer automatically — no tags need to be written inside the file.

---

## 2. Setup: Gem Install vs Clone

Choose the approach that fits your use case.

### Option A: Quick Install via Gem (Recommended)

Best for using or deploying KairosChain as a tool.

```bash
# Install the gem
gem install kairos-chain

# Initialize the project (creates a .kairos/ directory)
kairos-chain init

# Register as an MCP server in Claude Code
claude mcp add kairos-chain kairos-chain

# Confirm registration
claude mcp list
```

### Option B: Clone from GitHub

Best for developing KairosChain itself or customizing core logic.

```bash
git clone https://github.com/masaomi/KairosChain_2026.git
cd KairosChain_2026/KairosChain_mcp_server
bundle install
chmod +x bin/kairos-chain

# Register as an MCP server in Claude Code
claude mcp add kairos-chain ruby /path/to/KairosChain_mcp_server/bin/kairos-chain
```

---

## 3. How It Works as an MCP Server

KairosChain is fully compliant with the Model Context Protocol (MCP).
MCP clients such as Claude Code and Cursor invoke KairosChain's "tools" via JSON-RPC.

- **Client side**: "Save this function to L1 knowledge."
- **KairosChain side**: Executes the `knowledge_update` tool, generates a hash, and appends it to the blockchain.

---

## 4. Self-Referentiality: AI That Reads Its Own Manual

KairosChain stores its own design documents and manuals as Knowledge (L1) internally.
This means you don't need to read the manual yourself — just ask the AI connected to KairosChain: "How do I modify an L0 skill?" and it will autonomously select the correct command (e.g., `skills_evolve`) by reading its own stored blueprint.

---

## 5. MMP (Model Meeting Protocol): Skill Exchange Between Agents

Introduced in the latest version, **MMP (Model Meeting Protocol)** is a communication standard that lets agents hold "meetings" and dynamically exchange skills.

1. **Propose**: Agent A proposes a new skill (e.g., an MMP extension).
2. **Agree**: Agent B validates the skill and incorporates it into its own KairosChain.
3. **Execute**: Both agents begin communicating under the new shared protocol.

This allows agents to autonomously update their collaboration rules without any changes to source code.

Additionally, by deploying **HestiaChain** (the `hestia` SkillSet), a "Meeting Place" server is established where KairosChain agents across the internet can discover each other and share skills.

---

## 6. Skill Evolution Workflow

Changes to L0 skills follow a strict workflow:

1. **Propose**: Set `evolution_enabled: true` in `skills/config.yml` and have the AI propose a change.
2. **Check**: Automated validation of syntax and compliance with safety rules (5-layer validation).
3. **Human Approval**: The developer reviews and approves the change (`require_human_approval: true`).
4. **Apply**: A snapshot is saved to `skills/versions/` and the change is recorded immutably on the blockchain.

---

## 7. Plugin Marketplace Registration and Usage

When using KairosChain as a plugin for Claude Code or similar tools, the marketplace makes management straightforward.
**Ruby 3.0+** and the gem must be installed as prerequisites for full functionality.

```bash
# Prerequisite: install the gem
gem install kairos-chain

# Add the marketplace
/plugin marketplace add https://github.com/masaomi/KairosChain_2026.git

# Install the plugin
/plugin install kairos-chain
```

This seamlessly integrates your development environment (Claude Code / Cursor) with KairosChain.

---

## 8. Directory Structure and Data Persistence

Running `kairos-chain init` creates a data directory (default: `.kairos/`) with the following structure:

```
.kairos/
├── skills/                        # L0: Meta-skill definitions
│   ├── kairos.md                  # L0-A: Foundational philosophy (immutable)
│   ├── kairos.rb                  # L0-B: DSL skill definitions (approval required)
│   ├── config.yml                 # Evolution and security settings
│   └── versions/                  # Past version snapshots
├── knowledge/                     # L1: Project-specific knowledge
├── context/                       # L2: Session context
├── config/
│   ├── safety.yml                 # Security policy
│   └── tool_metadata.yml          # Tool metadata
└── storage/
    ├── embeddings/                # Vector search indices (for RAG)
    │   ├── skills/
    │   └── knowledge/
    ├── snapshots/                 # state_commit snapshots
    └── export/                    # SQLite export directory
```

Blockchain data is managed under `storage/` by default. Two storage backends are available: file-based (default) and SQLite.

---

## 9. Key Tools Reference

34+ tools are available. The major ones by category:

| Category | Tool | Description |
|---|---|---|
| **Blockchain** | `chain_status` | Check current hash and block height |
| **Blockchain** | `chain_verify` | Verify integrity of all blocks (hash check) |
| **Blockchain** | `chain_history` | Retrieve blockchain change history |
| **Blockchain** | `chain_record` | Manually record a block |
| **Blockchain** | `chain_export` / `chain_import` | Export and import chain data |
| **Skills (L0)** | `skills_list` | List defined L0 skills |
| **Skills (L0)** | `skills_dsl_get` | Retrieve the DSL definition of a specific skill |
| **Skills (L0)** | `skills_evolve` | Propose, approve, and apply skill changes (human required) |
| **Skills (L0)** | `skills_promote` | Promote a skill from L2 → L1 → L0 |
| **Skills (L0)** | `skills_rollback` | Revert a skill to a previous version |
| **Skills (L0)** | `skills_audit` | Automatically detect contradictions or stale knowledge |
| **DSL/AST** | `definition_verify` | Verify DSL definition consistency via AST |
| **DSL/AST** | `definition_drift` | Detect drift (divergence) in skill definitions |
| **DSL/AST** | `definition_decompile` | Decompile a binary/snapshot back to DSL |
| **Knowledge (L1)** | `knowledge_update` | Add/update project knowledge with hash recording |
| **Knowledge (L1)** | `knowledge_get` / `knowledge_list` | Retrieve and list knowledge entries |
| **Context (L2)** | `context_save` | Save temporary working logs |
| **State** | `state_commit` | Create a unified snapshot across all layers |
| **State** | `state_status` / `state_history` | Check snapshot status and history |
| **Guide** | `tool_guide` | Retrieve usage guidance for tools |

---

KairosChain transforms AI development from "throwaway prompts" into "skills as managed assets."
Bug reports and pull requests are welcome at the [GitHub repository](https://github.com/masaomi/KairosChain_2026).
