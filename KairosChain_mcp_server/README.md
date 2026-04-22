# KairosChain MCP Server

[![Gem Version](https://img.shields.io/gem/v/kairos-chain)](https://rubygems.org/gems/kairos-chain)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.0-red)](https://www.ruby-lang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A self-referential [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server for auditable skill self-management. KairosChain enables AI agents to define, evolve, and audit their own capabilities through a three-layer knowledge system backed by a private blockchain.

## Features

- **Three-Layer Knowledge System** — L0 Skills (Ruby DSL/AST), L1 Knowledge (accumulated insights), L2 Context (session-specific)
- **Blockchain-Backed History** — Immutable change records for all skill definitions, promotions, and evolution events
- **Cognitive Agent Framework** — OODA loop with autonomous mode, safety gates, and human checkpoints
- **SkillSet Plugin Architecture** — Install, upgrade, evolve, and promote modular capability packages
- **HestiaChain Meeting Place** — P2P skill and knowledge exchange between agent instances
- **SkillSet Exchange** — Deposit, browse, acquire, and withdraw knowledge packs via Meeting Places
- **MMP (Model Meeting Protocol)** — PlaceClient for structured peer communication
- **Multi-User Support** — PostgreSQL backend with role-based access control
- **Service Grant Tokenomics** — Token-based service grants with budget tracking
- **Attestation System (Synoptis)** — Cryptographic attestation and trust scoring
- **Dream Mode** — Speculative knowledge proposals with community review
- **Claude Code Plugin Projection** — Auto-project SkillSets as Claude Code plugins (hooks, agents, slash commands)
- **Multi-LLM Review** — Parallel dispatch to heterogeneous LLMs (Claude, Codex, Cursor) via CLI subprocesses; consensus verdict with aggregated findings

## Installation

```bash
gem install kairos-chain
kairos-chain init
```

## Usage

### As MCP Server (stdio — default)

Add to your Claude Code MCP configuration (`.mcp.json`):

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos-chain",
      "args": []
    }
  }
}
```

### As HTTP Server

```bash
kairos-chain --http --port 8080
```

### CLI Commands

```bash
kairos-chain init [DIR]            # Initialize data directory
kairos-chain upgrade [--apply]     # Check/apply template migrations
kairos-chain skillset list         # List installed SkillSets
kairos-chain skillset install PATH # Install a SkillSet from path
kairos-chain skillset enable NAME  # Enable a SkillSet
kairos-chain skillset info NAME    # Show SkillSet details
kairos-chain -v                    # Show version
```

## Directory Structure

```
.kairos/
├── skills/              # L0 — Skill definitions (DSL/AST)
├── knowledge/           # L1 — Accumulated knowledge
├── contexts/            # L2 — Session contexts
├── skillsets/            # Installed SkillSet plugins
├── storage/
│   └── blockchain.json  # Immutable change history
└── config/
    └── safety.yml       # Safety policies
```

## SkillSets

| SkillSet | Description |
|----------|-------------|
| agent | Cognitive agent with OODA loop and autonomous mode |
| autoexec | Automated task execution with scheduling |
| autonomos | Autonomous multi-cycle agent operations |
| document_authoring | LLM-powered document generation |
| dream | Speculative knowledge proposals |
| hestia | HestiaChain Meeting Place server |
| introspection | System health and safety checks |
| knowledge_creator | Knowledge scaffolding tools |
| llm_client | Multi-provider LLM integration |
| mcp_client | Remote MCP server connection |
| mmp | Model Meeting Protocol client |
| multiuser | PostgreSQL multi-user backend |
| plugin_projector | Claude Code plugin projection |
| service_grant | Token-based service grants |
| skillset_creator | SkillSet scaffolding |
| skillset_exchange | P2P SkillSet deposit/browse/acquire |
| synoptis | Attestation and trust system |

## Philosophy

KairosChain's architecture flows from one principle: **meta-level operations are expressed in the same structure as base-level operations.** This structural self-referentiality enables agents to reason about, modify, and evolve their own capabilities using the same tools they use for base-level tasks.

See [CLAUDE.md](../CLAUDE.md) for the full philosophical framework including the Nine Propositions.

## Author

**Masaomi Hatakeyama**
University of Zurich / Functional Genomics Center Zurich
[genomicschain.ch](https://genomicschain.ch)

## License

[MIT](LICENSE)
