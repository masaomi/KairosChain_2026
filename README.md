<!-- AUTO-GENERATED FROM L1 KNOWLEDGE. DO NOT EDIT DIRECTLY. -->
<!-- To update: edit L1 knowledge files in KairosChain_mcp_server/knowledge/ -->
<!-- Then run: ruby scripts/build_readme.rb (or: rake build_readme) -->

# KairosChain MCP Server

**A Meta Ledger for Recording AI Skill Evolution**

> 📖 [日本語版 README はこちら (Japanese README)](README_jp.md)

KairosChain is a Model Context Protocol (MCP) server that records the evolution of AI capabilities on a private blockchain. It combines Pure Skills design (Ruby DSL/AST) with immutable ledger technology, enabling AI agents to have auditable, evolvable, and self-referential skill definitions.

## Table of Contents

- [Philosophy](#philosophy)
  - [The Problem](#the-problem)
  - [The Solution: KairosChain](#the-solution-kairoschain)
  - [Minimum-Nomic Principle](#minimum-nomic-principle)
- [Architecture](#architecture)
  - [System Overview](#system-overview)
- [Layered Skills Architecture](#layered-skills-architecture)
  - [L0: Kairos Core (`skills/`)](#l0-kairos-core-skills)
  - [L1: Knowledge Layer (`knowledge/`)](#l1-knowledge-layer-knowledge)
  - [L2: Context Layer (`context/`)](#l2-context-layer-context)
  - [Why Layered Architecture?](#why-layered-architecture)
- [Data Model: SkillStateTransition](#data-model-skillstatetransition)
- [Setup](#setup)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Optional: RAG (Semantic Search) Support](#optional-rag-semantic-search-support)
  - [Optional: SQLite Storage Backend (Team Use)](#optional-sqlite-storage-backend-team-use)
  - [Optional: Streamable HTTP Transport (Remote/Team Access)](#optional-streamable-http-transport-remoteteam-access)
  - [Admin UI (Browser-Based Management)](#admin-ui-browser-based-management)
- [Client Configuration](#client-configuration)
  - [Claude Code Configuration (Detailed)](#claude-code-configuration-detailed)
  - [Cursor IDE Configuration (Detailed)](#cursor-ide-configuration-detailed)
- [Upgrading the Gem](#upgrading-the-gem)
  - [How It Works](#how-it-works)
  - [L1 Knowledge Updates (v1.0.0+)](#l1-knowledge-updates-v100)
  - [Upgrade Commands](#upgrade-commands)
  - [Version Mismatch Warning](#version-mismatch-warning)
  - [Upgrade Workflow](#upgrade-workflow)
- [Testing the Setup](#testing-the-setup)
  - [1. Basic Command Line Tests](#1-basic-command-line-tests)
  - [2. Skills Tools Test](#2-skills-tools-test)
  - [3. Blockchain Tools Test](#3-blockchain-tools-test)
  - [4. Testing with SQLite Backend (Optional)](#4-testing-with-sqlite-backend-optional)
  - [5. Testing with RAG / Semantic Search (Optional)](#5-testing-with-rag-semantic-search-optional)
  - [6. Testing HTTP Mode (Optional)](#6-testing-http-mode-optional)
  - [7. Testing with Claude Code](#7-testing-with-claude-code)
  - [8. Testing with Cursor](#8-testing-with-cursor)
  - [Troubleshooting](#troubleshooting)
- [Usage Tips](#usage-tips)
  - [Basic Usage](#basic-usage)
  - [Practical Usage Patterns](#practical-usage-patterns)
  - [Best Practices](#best-practices)
  - [Tool Discovery with tool_guide](#tool-discovery-with-tool_guide)
  - [Common Commands Reference](#common-commands-reference)
  - [Security Considerations](#security-considerations)
- [Available Tools (25 core + skill-tools)](#available-tools-25-core-skill-tools)
  - [L0-A: Skills Tools (Markdown) - Read-only](#l0-a-skills-tools-markdown-read-only)
  - [L0-B: Skills Tools (DSL) - Full Blockchain Record](#l0-b-skills-tools-dsl-full-blockchain-record)
  - [Cross-Layer Promotion Tools](#cross-layer-promotion-tools)
  - [Audit Tools - Knowledge Lifecycle Management](#audit-tools-knowledge-lifecycle-management)
  - [Resource Tools - Unified Access](#resource-tools-unified-access)
  - [L1: Knowledge Tools - Hash Reference Record](#l1-knowledge-tools-hash-reference-record)
  - [L2: Context Tools - No Blockchain Record](#l2-context-tools-no-blockchain-record)
  - [Blockchain Tools](#blockchain-tools)
  - [State Commit Tools (Auditability)](#state-commit-tools-auditability)
  - [Authentication Tools (HTTP Mode Only)](#authentication-tools-http-mode-only)
  - [Guide Tools (Tool Discovery)](#guide-tools-tool-discovery)
  - [System Management Tools](#system-management-tools)
- [Usage Examples](#usage-examples)
  - [List Available Skills](#list-available-skills)
  - [Check Blockchain Status](#check-blockchain-status)
  - [Record a Skill Transition](#record-a-skill-transition)
- [Self-Evolution Workflow](#self-evolution-workflow)
- [Pure Skills Design](#pure-skills-design)
  - [skills.md vs skills.rb](#skillsmd-vs-skillsrb)
  - [Example Skill Definition](#example-skill-definition)
  - [Self-Referential Introspection](#self-referential-introspection)
- [Directory Structure](#directory-structure)
  - [Gem Structure (installed via `gem install kairos-chain`)](#gem-structure-installed-via-gem-install-kairos-chain)
  - [Data Directory (created by `kairos-chain init`)](#data-directory-created-by-kairos-chain-init)
  - [Repository Structure (cloned from GitHub)](#repository-structure-cloned-from-github)
- [Future Roadmap](#future-roadmap)
  - [Near-term](#near-term)
  - [Long-term Vision: Distributed KairosChain Network](#long-term-vision-distributed-kairoschain-network)
- [Deployment and Operation](#deployment-and-operation)
  - [Data Storage Overview](#data-storage-overview)
  - [Blockchain Storage Format](#blockchain-storage-format)
  - [Recommended Operation Patterns](#recommended-operation-patterns)
  - [Backup Strategy](#backup-strategy)
  - [Documentation Management](#documentation-management)
- [FAQ](#faq)
  - [Q: Can LLMs automatically modify L1/L2?](#q-can-llms-automatically-modify-l1l2)
  - [Q: How do I decide which layer to store knowledge in?](#q-how-do-i-decide-which-layer-to-store-knowledge-in)
  - [Q: How do I maintain L1 knowledge health? How do I prevent L1 bloat?](#q-how-do-i-maintain-l1-knowledge-health-how-do-i-prevent-l1-bloat)
  - [Q: What is Persona Assembly and when should I use it?](#q-what-is-persona-assembly-and-when-should-i-use-it)
  - [Q: Is API extension needed for team usage?](#q-is-api-extension-needed-for-team-usage)
  - [Q: Is a voting system needed for changes to kairos.rb or kairos.md in team settings?](#q-is-a-voting-system-needed-for-changes-to-kairosrb-or-kairosmd-in-team-settings)
  - [Q: How do I run local tests?](#q-how-do-i-run-local-tests)
  - [Q: What meta-skills are included in kairos.rb?](#q-what-meta-skills-are-included-in-kairosrb)
  - [Q: How do I modify L0 skills? What is the procedure?](#q-how-do-i-modify-l0-skills-what-is-the-procedure)
  - [Q: What is L0 Auto-Check? How does it help with the 15-item checklist?](#q-what-is-l0-auto-check-how-does-it-help-with-the-15-item-checklist)
  - [Q: How does KairosChain decide when to evolve its own skills? Is there a meta-skill for this?](#q-how-does-kairoschain-decide-when-to-evolve-its-own-skills-is-there-a-meta-skill-for-this)
  - [Q: What is Skill-Tool Unification? Can I add MCP tools without editing Ruby files?](#q-what-is-skill-tool-unification-can-i-add-mcp-tools-without-editing-ruby-files)
  - [Q: What is the difference between adding tools via kairos.rb vs tools/ directory?](#q-what-is-the-difference-between-adding-tools-via-kairosrb-vs-tools-directory)
  - [Q: Should KairosChain proactively recommend skill creation to the LLM?](#q-should-kairoschain-proactively-recommend-skill-creation-to-the-llm)
  - [Q: What happens when skills or knowledge contradict each other?](#q-what-happens-when-skills-or-knowledge-contradict-each-other)
  - [Q: What is StateCommit and how does it improve auditability?](#q-what-is-statecommit-and-how-does-it-improve-auditability)
  - [Q: What happens when too many skills accumulate? Is there a cleanup mechanism?](#q-what-happens-when-too-many-skills-accumulate-is-there-a-cleanup-mechanism)
  - [Q: How do I fix a skill when it provides incorrect or outdated information?](#q-how-do-i-fix-a-skill-when-it-provides-incorrect-or-outdated-information)
  - [Q: What are the advantages and disadvantages of using SQLite?](#q-what-are-the-advantages-and-disadvantages-of-using-sqlite)
  - [Q: How do I inspect SQLite data without SQL commands?](#q-how-do-i-inspect-sqlite-data-without-sql-commands)
  - [Q: What is Pure Agent Skill and why does it matter?](#q-what-is-pure-agent-skill-and-why-does-it-matter)
  - [Q: Why does KairosChain use Ruby, specifically DSL and AST?](#q-why-does-kairoschain-use-ruby-specifically-dsl-and-ast)
  - [Q: What's the difference between using local skills vs. KairosChain?](#q-whats-the-difference-between-using-local-skills-vs-kairoschain)
- [Subtree Integration Guide](#subtree-integration-guide)
  - [Why Subtree (Not Submodule)](#why-subtree-not-submodule)
  - [How It Works with KairosChain Layers](#how-it-works-with-kairoschain-layers)
  - [Setup: Adding KairosChain to a New Project](#setup-adding-kairoschain-to-a-new-project)
  - [Important: Data Directory Configuration for Subtree](#important-data-directory-configuration-for-subtree)
  - [Daily Operations](#daily-operations)
  - [Conflict Resolution](#conflict-resolution)
  - [Multi-Project Deployment Example](#multi-project-deployment-example)
  - [After Subtree Pull: Template Updates](#after-subtree-pull-template-updates)
  - [Reference](#reference)

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

---

## Setup

### Prerequisites

- Ruby 3.0+ (uses standard library only, no gems required for basic functionality)
- Claude Code CLI (`claude`) or Cursor IDE

### Installation

KairosChain can be installed either as a **Ruby gem** (recommended) or by **cloning the repository**.

#### Option A: Install as a Gem (Recommended)

```bash
# Install the gem
gem install kairos-chain

# Initialize data directory (creates .kairos/ in current directory)
kairos-chain init

# Or initialize at a specific path
kairos-chain init --data-dir /path/to/my-kairos-data

# Test basic execution
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | kairos-chain
```

The gem ships with zero runtime dependencies. Optional features (SQLite, RAG, HTTP) can be added by installing additional gems — see the Optional sections below.

**Data directory resolution** (priority order):
1. `--data-dir` CLI option
2. `KAIROS_DATA_DIR` environment variable
3. `.kairos/` in the current working directory

#### Option B: Clone the Repository

```bash
# Clone the repository
git clone https://github.com/masaomi/KairosChain_2026.git
cd KairosChain_2026/KairosChain_mcp_server

# Make executable
chmod +x bin/kairos-chain

# Test basic execution
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos-chain
```

> **Note**: When running from the repository, the data directory defaults to `.kairos/` in the current working directory. The server will auto-initialize on first run if the data directory doesn't exist.

### Optional: RAG (Semantic Search) Support

KairosChain supports optional semantic search using vector embeddings. This enables finding skills by meaning rather than exact keyword matches (e.g., searching "authentication" can find skills about "login" or "password").

**Without RAG gems:** Regex-based keyword search (default, no installation required)  
**With RAG gems:** Semantic vector search using sentence embeddings

#### Requirements

- C++ compiler (for native extensions)
- ~90MB disk space (for embedding model, downloaded on first use)

#### Installation

```bash
# If using the gem:
gem install hnswlib informers

# If using the repository with Bundler:
cd KairosChain_mcp_server
bundle install --with rag
```

#### Gems Used

| Gem | Version | Purpose |
|-----|---------|---------|
| `hnswlib` | ~> 0.9 | HNSW approximate nearest neighbor search |
| `informers` | ~> 1.0 | ONNX-based sentence embeddings |

#### Supported Layers

| Layer | Target | RAG Support | Index Path |
|-------|--------|-------------|------------|
| **L0** | `skills/kairos.rb` (meta-skills) | Yes | `storage/embeddings/skills/` |
| **L1** | `knowledge/` (project knowledge) | Yes | `storage/embeddings/knowledge/` |
| **L2** | `context/` (temporary context) | No | N/A (regex search only) |

L2 is excluded because temporary contexts are short-lived and typically few in number, making regex search sufficient.

#### Configuration

RAG settings in config (at `<data-dir>/config/config.yml` for gem, or `skills/config.yml` for repo):

```yaml
vector_search:
  enabled: true                                      # Enable if gems available
  model: "sentence-transformers/all-MiniLM-L6-v2"    # Embedding model
  dimension: 384                                     # Must match model
  index_path: "storage/embeddings"                   # Index storage path
  auto_index: true                                   # Auto-rebuild on changes
```

#### Installing RAG Later

If you install RAG gems after already using KairosChain:

1. Install the gems: `bundle install --with rag` or `gem install hnswlib informers`
2. **Restart the MCP server** (reconnect in Cursor/Claude Code)
3. On first search, the index is automatically rebuilt from all skills/knowledge
4. Initial model download (~90MB) and embedding generation will take some time

**Why this works:** The `@available` flag is checked at server startup and cached. FallbackSearch (regex-based) does not persist any index data. When switching to SemanticSearch, the `ensure_index_built` method triggers a full `rebuild_index` on first use, creating embeddings for all existing skills and knowledge.

**What happens to existing data:**
- Skills and knowledge files: Unchanged (source of truth)
- Vector index: Created fresh from current content
- No migration needed: FallbackSearch → SemanticSearch is seamless

#### Verification

```bash
# Check if RAG gems are available
ruby -e "require 'hnswlib'; require 'informers'; puts 'RAG gems installed!'"

# Test RAG with the gem (semantic search of L0 skills)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{"query":"safety"}}}' | kairos-chain

# Test RAG from the repository
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{"query":"safety"}}}' | bin/kairos-chain
```

> **Note**: The first RAG search will download the embedding model (~90MB) and build the vector index. Subsequent searches will be fast.

#### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                      Search Query                            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │  VectorSearch.available?  │
                    └─────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
    ┌─────────────────┐             ┌─────────────────┐
    │ Semantic Search │             │ Fallback Search │
    │ (hnswlib +      │             │ (Regex-based)   │
    │  informers)     │             │                 │
    └─────────────────┘             └─────────────────┘
              │                               │
              └───────────────┬───────────────┘
                              ▼
                    ┌─────────────────┐
                    │  Search Results │
                    └─────────────────┘
```

---

### Optional: SQLite Storage Backend (Team Use)

By default, KairosChain uses file-based storage (JSON/JSONL files). For team environments with concurrent access, you can optionally enable SQLite storage backend.

**Default (File-based):** No configuration required, suitable for individual use  
**SQLite:** Better concurrent access handling, suitable for small team use (2-10 people)

#### When to Use SQLite

| Scenario | Recommended Backend |
|----------|---------------------|
| Individual developer | File (default) |
| Small team (2-10) | **SQLite** |
| Large team (10+) | PostgreSQL (future) |
| CI/CD pipelines | SQLite |

#### Installation

```bash
# If using the gem:
gem install sqlite3

# If using the repository with Bundler:
cd KairosChain_mcp_server
bundle install --with sqlite
```

#### Configuration

Edit the config file to enable SQLite (at `<data-dir>/skills/config.yml` for gem, or `skills/config.yml` for repo):

```yaml
# Storage backend configuration
storage:
  backend: sqlite                         # Change from 'file' to 'sqlite'

  sqlite:
    path: "storage/kairos.db"             # Path to SQLite database file
    wal_mode: true                        # Enable WAL for better concurrency
```

#### Verification

```bash
# Check if SQLite gem is installed
ruby -e "require 'sqlite3'; puts 'SQLite3 gem installed!'"

# Test with the gem
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos-chain

# Test from the repository
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | bin/kairos-chain
```

#### Exporting Data from SQLite to Files

You can export SQLite data to human-readable files for backup or inspection:

```ruby
# In Ruby console or script
require 'kairos_mcp/storage/exporter'  # gem install
# or: require_relative 'lib/kairos_mcp/storage/exporter'  # from repository

# Export all data
KairosMcp::Storage::Exporter.export(
  db_path: "storage/kairos.db",
  output_dir: "storage/export"
)

# Output structure:
# storage/export/
# ├── blockchain.json       # All blocks
# ├── action_log.jsonl      # Action log entries
# ├── knowledge_meta.json   # Knowledge metadata
# └── manifest.json         # Export metadata
```

#### Rebuilding SQLite from Files

If SQLite database becomes corrupted, you can rebuild it from file-based data:

```ruby
# In Ruby console or script
require_relative 'lib/kairos_mcp/storage/importer'

# Rebuild from original file storage
KairosMcp::Storage::Importer.rebuild_from_files(
  db_path: "storage/kairos.db"
)

# Or import from exported files
KairosMcp::Storage::Importer.import(
  input_dir: "storage/export",
  db_path: "storage/kairos.db"
)
```

#### Using MCP Tools for Export/Import

You can also use MCP tools directly from your AI assistant (Cursor/Claude Code):

**Export (read-only, safe):**
```
# In Cursor/Claude Code chat:
"Export the SQLite database to files using chain_export"

# Or call directly:
chain_export output_dir="storage/backup"
```

**Import (requires approval):**
```
# Preview mode (shows impact without making changes):
chain_import source="files" approved=false

# Execute with automatic backup:
chain_import source="files" approved=true

# Import from exported directory:
chain_import source="export" input_dir="storage/backup" approved=true
```

**Safety features of chain_import:**
- Requires `approved=true` to execute (otherwise shows preview)
- Automatically creates backup at `storage/backups/kairos_{timestamp}.db`
- Shows impact summary before execution
- `skip_backup=true` available but NOT recommended

#### Switching Between Backends

**File → SQLite:**
1. Install sqlite3 gem
2. Change `storage.backend` to `sqlite` in config.yml
3. Run `Importer.rebuild_from_files` to migrate data
4. Restart the MCP server

**SQLite → File:**
1. Run `Exporter.export` to export data
2. Copy exported files to original locations:
   - `blockchain.json` → `storage/blockchain.json`
   - `action_log.jsonl` → `skills/action_log.jsonl`
3. Change `storage.backend` to `file` in config.yml
4. Restart the MCP server

#### Migrating to SQLite (Step-by-Step)

If you're already using KairosChain with file-based storage and want to migrate to SQLite:

**Step 1: Install sqlite3 gem**

```bash
cd KairosChain_mcp_server

# Using Bundler (recommended)
bundle install --with sqlite

# Or direct install
gem install sqlite3

# Verify installation
ruby -e "require 'sqlite3'; puts 'SQLite3 ready!'"
```

**Step 2: Update config.yml**

```yaml
# skills/config.yml
storage:
  backend: sqlite                         # Change from 'file' to 'sqlite'

  sqlite:
    path: "storage/kairos.db"
    wal_mode: true
```

**Step 3: Migrate existing data**

```bash
cd KairosChain_mcp_server

ruby -e "
require_relative 'lib/kairos_mcp/storage/importer'

result = KairosMcp::Storage::Importer.rebuild_from_files(
  db_path: 'storage/kairos.db'
)

puts 'Migration completed!'
puts \"Blocks imported: #{result[:blocks]}\"
puts \"Action logs imported: #{result[:action_logs]}\"
puts \"Knowledge metadata imported: #{result[:knowledge_meta]}\"
"
```

**Step 4: Restart MCP server**

Restart Cursor/Claude Code or reconnect the MCP server.

**Step 5: Verify migration**

```bash
# Check chain status (gem or repository)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'

# Verify chain integrity
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'
```

**Step 6: Keep original files as backup**

After migration, keep the original files as backup:

```
storage/
├── blockchain.json      # ← Original file (keep as backup)
├── kairos.db            # ← New SQLite database
└── kairos.db-wal        # ← WAL file (auto-generated)

skills/
└── action_log.jsonl     # ← Original file (keep as backup)
```

#### Troubleshooting SQLite

**sqlite3 gem won't load:**

```bash
# Check if installed
gem list sqlite3

# Reinstall if needed
gem uninstall sqlite3
gem install sqlite3
```

**Data not visible after migration:**

```bash
# Re-run migration
ruby -e "
require_relative 'lib/kairos_mcp/storage/importer'
KairosMcp::Storage::Importer.rebuild_from_files(db_path: 'storage/kairos.db')
"
```

**SQLite database corrupted:**

```bash
# Delete corrupted database and rebuild from original files
rm storage/kairos.db storage/kairos.db-wal storage/kairos.db-shm 2>/dev/null

ruby -e "
require_relative 'lib/kairos_mcp/storage/importer'
KairosMcp::Storage::Importer.rebuild_from_files(db_path: 'storage/kairos.db')
"
```

**Reverting to file-based storage:**

```yaml
# Simply change config.yml back
storage:
  backend: file    # Change from 'sqlite' to 'file'
```

The original files (`blockchain.json`, `action_log.jsonl`) will be used automatically.

#### Important Notes

- **Knowledge content (*.md files)**: Always stored in files regardless of backend
- **SQLite stores**: Blockchain, action logs, and knowledge metadata only
- **Human readability**: Use export feature to inspect data without SQL commands
- **Backup**: For SQLite, simply copy the `.db` file; for extra safety, also export to files

---

### Optional: Streamable HTTP Transport (Remote/Team Access)

By default, KairosChain uses stdio transport (local process). For remote access and team sharing, you can optionally enable Streamable HTTP transport with Bearer token authentication.

**Default (stdio):** Local process via stdin/stdout, no additional setup required  
**Streamable HTTP:** Remote access via `POST /mcp`, Bearer token authentication, team sharing

#### When to Use HTTP Transport

| Scenario | Recommended Transport |
|----------|----------------------|
| Individual developer (local Cursor/Claude Code) | stdio (default) |
| Team sharing a single KairosChain instance | **Streamable HTTP** |
| Remote access across network | **Streamable HTTP** |
| CI/CD integration via HTTP | **Streamable HTTP** |

#### Installation

```bash
# If using the gem:
gem install puma rack

# If using the repository with Bundler:
cd KairosChain_mcp_server
bundle install --with http

# For full team setup (HTTP + SQLite for concurrent access):
gem install puma rack sqlite3          # gem
bundle install --with http sqlite      # or Bundler

# Verify installation
ruby -e "require 'puma'; require 'rack'; puts 'HTTP transport gems installed!'"
```

#### Gems Used

| Gem | Version | Purpose |
|-----|---------|---------|
| `puma` | ~> 6.0 | High-performance concurrent web server |
| `rack` | ~> 3.0 | Modular Ruby web server interface |

#### Quick Start

```bash
# Using the gem:
kairos-chain --init-admin
kairos-chain --http --port 8080

# Using the repository:
ruby bin/kairos-chain --init-admin
ruby bin/kairos-chain --http --port 8080

# Test with curl (in another terminal)
curl http://localhost:8080/health
```

#### Setup Steps

**Step 1: Generate an Admin Token**

```bash
# Using the gem:
kairos-chain --init-admin

# Using the repository:
ruby bin/kairos-chain --init-admin
```

Output:
```
============================================================
  KairosChain Admin Token Generated
============================================================

  Token: kc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  User:  admin
  Role:  owner
  Expires: 2026-05-13T10:00:00+01:00

  IMPORTANT: Store this token securely.
  It will NOT be shown again.
============================================================
```

**Step 2: Start the HTTP Server**

```bash
# Using the gem:
kairos-chain --http                                    # default port 8080
kairos-chain --http --port 9090                        # custom port
kairos-chain --http --port 8080 --data-dir /path/to/data  # custom data dir

# Using the repository:
ruby bin/kairos-chain --http
ruby bin/kairos-chain --http --port 9090
ruby bin/kairos-chain --http --host 127.0.0.1 --port 8080
```

**Step 3: Configure Cursor to Connect**

Add to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "kairos-chain-http": {
      "url": "http://localhost:8080/mcp",
      "headers": {
        "Authorization": "Bearer kc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

Restart Cursor after saving.

#### Testing the HTTP Transport

**Unit tests (no gems required):**

```bash
ruby test_http.rb
```

**Integration tests (requires puma + rack):**

```bash
ruby test_http.rb --integration
```

**Manual testing with curl:**

```bash
# Health check (no auth required)
curl http://localhost:8080/health

# MCP initialize (with auth)
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-token>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

# List tools
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-token>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# Call a tool
curl -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-token>" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hello_world","arguments":{"name":"HTTP"}}}'
```

#### Token Management

After initial setup, manage tokens via the `token_manage` MCP tool:

```bash
# Create a token for a team member
token_manage command="create" user="alice" role="member"

# List active tokens
token_manage command="list"

# Rotate a token (revoke old, create new)
token_manage command="rotate" user="alice"

# Revoke a token
token_manage command="revoke" user="alice"
```

**Token roles (Phase 1: all roles have equal access):**

| Role | Description | Phase 2 Permissions |
|------|-------------|---------------------|
| `owner` | System administrator | Full access + token management |
| `member` | Team member | L1/L2 write, L0 read-only |
| `guest` | External collaborator | Read-only, own L2 only |

**Token expiry:**

| Duration | Option | Use Case |
|----------|--------|----------|
| 90 days (default) | `expires_in="90d"` | Daily use in Cursor |
| 24 hours | `expires_in="24h"` | CI/CD, temporary access |
| 7 days | `expires_in="7d"` | Short-term collaboration |
| No expiry | `expires_in="never"` | Owner tokens only |

#### CLI Options

```
Usage: kairos-chain [command] [options]

Commands:
    init              Initialize data directory with default templates
    upgrade           Preview template migrations after gem update
    upgrade --apply   Apply template migrations

Options:
    --data-dir DIR  Data directory path (default: .kairos/ in current dir)
    --http          Start in Streamable HTTP mode (default: stdio)
    --port PORT     HTTP port (default: 8080)
    --host HOST     HTTP bind host (default: 0.0.0.0)
    --init-admin    Generate initial admin token and exit
    --token-store PATH  Path to token store file
    -v, --version   Show version
    -h, --help      Show help

Environment Variables:
    KAIROS_DATA_DIR   Override data directory path
```

#### Production Deployment with HTTPS

For production use, place a reverse proxy in front of Puma to handle TLS/HTTPS. Puma only handles plain HTTP internally; the reverse proxy terminates SSL.

```
Client (Cursor) ──HTTPS──▶ Reverse Proxy ──HTTP──▶ Puma (:8080)
                           (Caddy/Nginx)
                           TLS termination
```

**Option A: Caddy (Recommended — Simplest)**

Caddy provides automatic HTTPS with Let's Encrypt certificates (zero configuration for TLS).

```bash
# Install Caddy
# macOS
brew install caddy

# Ubuntu/Debian
sudo apt install -y caddy

# Or see: https://caddyserver.com/docs/install
```

Create a `Caddyfile`:

```
kairos.example.com {
    reverse_proxy localhost:8080
}
```

Start Caddy:

```bash
# Foreground (for testing)
caddy run

# As a service (production)
sudo systemctl enable --now caddy
```

That's it. Caddy automatically:
- Obtains a Let's Encrypt certificate for `kairos.example.com`
- Renews it before expiry
- Redirects HTTP to HTTPS
- Handles TLS termination

**Option B: Nginx**

For environments where Nginx is already available or preferred.

```bash
# Install Nginx + Certbot
# macOS
brew install nginx

# Ubuntu/Debian
sudo apt install -y nginx certbot python3-certbot-nginx
```

Create Nginx config (`/etc/nginx/sites-available/kairos`):

```nginx
server {
    listen 80;
    server_name kairos.example.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Enable and get SSL certificate:

```bash
# Enable the site
sudo ln -s /etc/nginx/sites-available/kairos /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# Obtain Let's Encrypt certificate (automatic Nginx config update)
sudo certbot --nginx -d kairos.example.com
```

Certbot automatically modifies the Nginx config to add SSL and sets up auto-renewal.

**Option C: Self-Signed Certificate (LAN / Development)**

For LAN teams or development where you don't have a public domain:

```bash
# Generate self-signed certificate (valid for 1 year)
mkdir -p certs
openssl req -x509 -newkey rsa:4096 -keyout certs/key.pem -out certs/cert.pem \
  -days 365 -nodes -subj "/CN=kairos.local"
```

With Caddy (using self-signed cert):

```
kairos.local {
    tls /path/to/certs/cert.pem /path/to/certs/key.pem
    reverse_proxy localhost:8080
}
```

With Nginx:

```nginx
server {
    listen 443 ssl;
    server_name kairos.local;

    ssl_certificate /path/to/certs/cert.pem;
    ssl_certificate_key /path/to/certs/key.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**Cursor Configuration (HTTPS)**

After setting up HTTPS, update `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "kairos-chain-http": {
      "url": "https://kairos.example.com/mcp",
      "headers": {
        "Authorization": "Bearer kc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

**Comparison: Caddy vs Nginx**

| Aspect | Caddy | Nginx |
|--------|-------|-------|
| HTTPS setup | Automatic (zero config) | Manual (certbot required) |
| Certificate renewal | Automatic | Automatic (via certbot timer) |
| Configuration | Simple Caddyfile | More verbose |
| Performance | Good | Excellent (battle-tested) |
| Best for | New setups, simplicity | Existing Nginx infrastructure |

#### Configuration

HTTP settings in `skills/config.yml`:

```yaml
http:
  enabled: false                          # Set to true or use --http flag
  port: 8080                              # HTTP listen port
  host: "0.0.0.0"                         # Bind address
  token_store: "storage/tokens.json"      # Token storage path
  default_token_expiry_days: 90           # Default token expiry
```

#### Cleanup After Testing

All generated files are in `.gitignore`. To clean up:

```bash
cd KairosChain_mcp_server

rm -f storage/tokens.json       # Generated tokens
rm -rf vendor/bundle vendor/    # Locally installed gems
rm -rf .bundle/                 # Bundler cache
rm -f Gemfile.lock              # Lock file
```

Verify clean state: `git status` should show `working tree clean`.

#### Future Phases (Not Yet Implemented)

**Phase 2: Role-Based Authorization**
- Layer-specific permissions per role (owner/member/guest)
- `notifications/tools/list_changed` for dynamic tool updates
- Per-user permission overrides

**Phase 3: Wallet / JWT Integration (GenomicsChain)**
- JWT tokens issued by GenomicsChain Rails API
- Wallet-based authentication (MetaMask signature)
- Integration with PoC (Proof of Contribution) token system

---

### Admin UI (Browser-Based Management)

When running in HTTP mode, KairosChain provides a built-in browser-based admin UI at `/admin`. This is a lightweight management interface for server operators — no additional frameworks or gems required.

#### Accessing the Admin UI

1. Start the HTTP server: `kairos-chain --http` (gem) or `ruby bin/kairos-chain --http` (repository)
2. Open `http://localhost:8080/admin` in your browser
3. Log in with an `owner` role Bearer token

#### Available Screens

| Screen | Path | Purpose |
|--------|------|---------|
| **Dashboard** | `/admin` | Chain status, token count, L0/L1 overview, state commit status |
| **Tokens** | `/admin/tokens` | Create, list, revoke, and rotate Bearer tokens |
| **Chain** | `/admin/chain` | Browse block history, view block details, verify chain integrity |
| **Skills** | `/admin/skills` | View L0 DSL skills and their definitions (read-only) |
| **Knowledge** | `/admin/knowledge` | Browse and search L1 knowledge entries (read-only) |
| **Config** | `/admin/config` | View configuration, layer settings, storage info (read-only) |

#### Technical Details

- **Technology**: htmx + PicoCSS + ERB (Ruby stdlib) — no new gems required
- **Authentication**: Session cookie (HMAC-SHA256 signed) wrapping existing Bearer tokens
- **Authorization**: `owner` role only — other roles are redirected to login
- **CSRF Protection**: Token-based protection on all POST requests
- **Data Source**: Calls existing tool classes directly (no MCP protocol overhead)
- **Same Process**: Runs inside the existing Puma/Rack HTTP server

#### Design Philosophy

The admin UI is intentionally minimal. It is a **Phase 1 management tool** (see [MCP-to-SaaS Development Workflow](KairosChain_mcp_server/knowledge/mcp_to_saas_development_workflow/mcp_to_saas_development_workflow.md)). For richer UIs, build a custom SaaS frontend that consumes the Backend API and MCP tools.

---

## Client Configuration

### Claude Code Configuration (Detailed)

Claude Code is a CLI-based AI coding assistant.

#### Step 1: Verify Claude Code Installation

```bash
# Check if Claude Code is installed
claude --version

# If not installed, install from the official site
# https://docs.anthropic.com/claude-code
```

#### Step 2: Register the MCP Server

```bash
# If using the gem (recommended):
claude mcp add kairos-chain kairos-chain

# If using the repository:
claude mcp add kairos-chain ruby /path/to/KairosChain_mcp_server/bin/kairos-chain

# With a custom data directory:
claude mcp add kairos-chain kairos-chain -- --data-dir /path/to/my-kairos-data
```

#### Step 3: Verify Registration

```bash
# List registered MCP servers
claude mcp list

# You should see kairos-chain in the list
```

#### Step 4: Check Configuration File (Optional)

The following configuration is added to `~/.claude.json`:

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos-chain",
      "args": ["--data-dir", "/path/to/my-kairos-data"],
      "env": {}
    }
  }
}
```

For repository-based setup:

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "ruby",
      "args": ["/path/to/KairosChain_mcp_server/bin/kairos-chain"],
      "env": {}
    }
  }
}
```

#### Manual Configuration (Advanced)

To edit the configuration file directly:

```bash
# Open the configuration file
vim ~/.claude.json

# Or use VS Code
code ~/.claude.json
```

### Cursor IDE Configuration (Detailed)

Cursor is a VS Code-based AI coding IDE.

#### Option A: Via GUI (Recommended)

1. Open **Cursor Settings** (Cmd/Ctrl + ,)
2. Navigate to **Tools & MCP**
3. Click **New MCP Server**
4. Enter the server details:
   - **If using the gem:**
     - Name: `kairos-chain`
     - Command: `kairos-chain`
     - Args: `--data-dir /path/to/my-kairos-data` (optional)
   - **If using the repository:**
     - Name: `kairos-chain`
     - Command: `ruby`
     - Args: `/path/to/KairosChain_mcp_server/bin/kairos-chain`

#### Option B: Via Configuration File

#### Step 1: Locate the Configuration File

```bash
# macOS / Linux
~/.cursor/mcp.json

# Windows
%USERPROFILE%\.cursor\mcp.json
```

#### Step 2: Create/Edit the Configuration File

```bash
# Create directory if it doesn't exist
mkdir -p ~/.cursor

# Edit the configuration file
vim ~/.cursor/mcp.json
```

#### Step 3: Add the MCP Server

**If using the gem (recommended):**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos-chain",
      "args": ["--data-dir", "/path/to/my-kairos-data"],
      "env": {}
    }
  }
}
```

**If using the repository:**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "ruby",
      "args": ["/path/to/KairosChain_mcp_server/bin/kairos-chain"],
      "env": {}
    }
  }
}
```

**For multiple MCP servers:**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos-chain",
      "args": ["--data-dir", "/Users/yourname/.kairos"],
      "env": {}
    },
    "sushi-mcp-server": {
      "command": "ruby",
      "args": ["/path/to/SUSHI_self_maintenance_mcp_server/bin/sushi_mcp_server"],
      "env": {}
    }
  }
}
```

#### Step 4: Restart Cursor

After saving the configuration, **you must completely restart Cursor**.

#### Step 5: Verify MCP Server Connection

1. Open Cursor
2. Click the "MCP" icon in the top right (or search "MCP" in the command palette)
3. Verify that `kairos-chain` appears in the list with a green status indicator

---

## Upgrading the Gem

When a new version of `kairos-chain` is released (with new skills, config keys, bug fixes, etc.), updating the gem code is straightforward:

```bash
gem update kairos-chain
```

However, your data directory (`.kairos/`) contains template files that were copied at `init` time and may have been customized. The built-in upgrade system uses **3-way hash comparison** to safely migrate these files.

### How It Works

The upgrade system compares three versions of each template file:
- **Original**: The template hash recorded in `.kairos_meta.yml` at init time
- **Current**: Your version in the data directory (possibly customized)
- **New**: The latest template shipped with the gem

Based on this comparison, each file is classified:

| Pattern | User Modified? | Template Changed? | Action |
|---------|---------------|-------------------|--------|
| 0 (unchanged) | No | No | No action needed |
| 1 (auto-updatable) | No | Yes | Safe to auto-update |
| 2 (user-modified) | Yes | No | Keep user version |
| 3 (conflict) | Yes | Yes | Merge / review required |

For **config YAML files** (Pattern 3), a structural merge adds new keys while preserving your values. For **L0 kairos.rb** (Pattern 3), a `skills_evolve` proposal is generated, requiring human approval and blockchain recording.

### L1 Knowledge Updates (v1.0.0+)

Starting from v1.0.0, the gem also bundles **official L1 knowledge** (17 bundled templates) alongside the config and skills templates. When you run `system_upgrade` (or `kairos-chain upgrade --apply`):

- **New knowledge**: Files that don't exist in your data directory are installed
- **Unmodified knowledge**: Files unchanged since init are auto-updated to the latest bundled version
- **User-modified knowledge**: Files you've edited are preserved (your changes are kept)
- **Conflicts**: When both you and the gem have changed a file, the new version is saved to a `.new/` directory for manual review and merge

The `.kairos_meta.yml` file now tracks both `template_hashes` (for config/skills) and `knowledge_hashes` for L1 knowledge files, enabling the same 3-way comparison logic for knowledge updates.

### Upgrade Commands

#### Via CLI

```bash
# Preview what would change (recommended first step)
kairos-chain upgrade

# Apply the upgrade
kairos-chain upgrade --apply

# With custom data directory
kairos-chain upgrade --data-dir /path/to/data --apply
```

#### Via MCP Tool (from within an AI session)

```
system_upgrade command="check"       # Quick version check
system_upgrade command="preview"     # Detailed file-by-file analysis
system_upgrade command="apply" approved=true   # Apply upgrade
system_upgrade command="status"      # Show current meta status
```

### Version Mismatch Warning

When the MCP server starts and detects a version mismatch between the gem and the data directory, it displays a warning:

```
[KairosChain] Data directory was initialized with v1.0.0, current gem is v1.1.0.
[KairosChain] Run 'system_upgrade command="check"' or 'kairos-chain upgrade' to see available updates.
```

### Upgrade Workflow

1. Update the gem: `gem update kairos-chain`
2. Preview changes: `kairos-chain upgrade`
3. Review the output (especially any conflicts)
4. Apply: `kairos-chain upgrade --apply`
5. For L0 proposals, use `skills_evolve` to review and approve
6. Restart the MCP server

All upgrade operations are recorded to the KairosChain blockchain for traceability.

---

## Testing the Setup

> **Note**: The examples below show both the gem command (`kairos-chain`) and the repository command (`bin/kairos-chain`). Use whichever matches your installation.

### 1. Basic Command Line Tests

#### Initialize Test

```bash
# Using the gem:
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | kairos-chain

# Using the repository:
cd /path/to/KairosChain_mcp_server
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos-chain

# Expected response (excerpt):
# {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":...}}
```

#### Tools List Test

```bash
# Get list of available tools
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | kairos-chain

# If you have jq, display only tool names
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | kairos-chain 2>/dev/null | jq '.result.tools[].name'
```

#### Hello World Test

```bash
# Call the hello_world tool
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hello_world","arguments":{}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'

# Output: Hello from KairosChain MCP Server!
```

### 2. Skills Tools Test

```bash
# Get skills list
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'

# Get a specific skill
echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"skills_dsl_get","arguments":{"skill_id":"core_safety"}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'
```

### 3. Blockchain Tools Test

```bash
# Check blockchain status
echo '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'

# Verify chain integrity
echo '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'
```

### 4. Testing with SQLite Backend (Optional)

```bash
# 1. Install sqlite3 gem
gem install sqlite3

# 2. Edit config to enable SQLite
#    Change storage.backend from 'file' to 'sqlite' in <data-dir>/skills/config.yml

# 3. Test chain_status (should show SQLite backend info)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'

# 4. Record and verify
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chain_record","arguments":{"logs":["SQLite test record"]}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'

echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'
```

### 5. Testing with RAG / Semantic Search (Optional)

```bash
# 1. Install RAG gems
gem install hnswlib informers

# 2. Verify gems are available
ruby -e "require 'hnswlib'; require 'informers'; puts 'RAG gems installed!'"

# 3. Enable RAG in config
#    Set vector_search.enabled to true in <data-dir>/skills/config.yml

# 4. Test semantic search (first run downloads ~90MB embedding model)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{"query":"safety rules"}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'

# 5. Test knowledge search
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"knowledge_list","arguments":{"query":"layer placement"}}}' | kairos-chain 2>/dev/null | jq -r '.result.content[0].text'
```

### 6. Testing HTTP Mode (Optional)

```bash
# 1. Install HTTP gems
gem install puma rack

# 2. Initialize data and generate admin token
kairos-chain init --data-dir /tmp/kairos_test
kairos-chain --init-admin --data-dir /tmp/kairos_test
# Save the displayed token!

# 3. Start HTTP server
kairos-chain --http --port 9090 --data-dir /tmp/kairos_test

# 4. Test from another terminal
curl http://localhost:9090/health

curl -X POST http://localhost:9090/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_TOKEN>" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
```

### 7. Testing with Claude Code

```bash
# Launch Claude Code
claude

# Try these prompts in Claude Code:
# "List the available KairosChain tools"
# "Run skills_dsl_list"
# "Check chain_status"
```

### 8. Testing with Cursor

1. Open your project in Cursor
2. Open the chat panel (Cmd/Ctrl + L)
3. Try these prompts:
   - "List all KairosChain skills"
   - "Check the blockchain status"
   - "Show me the core_safety skill content"

### Troubleshooting

#### Server Doesn't Start

```bash
# Check Ruby version
ruby --version  # Requires 3.0+

# Check for syntax errors
ruby -c bin/kairos-chain

# Verify executable permission
ls -la bin/kairos-chain
chmod +x bin/kairos-chain
```

#### JSON-RPC Errors

```bash
# Check stderr for error messages
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos-chain

# Run without suppressing stderr (remove 2>/dev/null)
```

#### Gem Command Not Found

```bash
# If kairos-chain is not found after gem install
# Check if the gem bin directory is in your PATH
gem environment gemdir
# The executable should be in the bin/ directory under that path

# For rbenv users, rehash may be needed
rbenv rehash

# Verify the correct Ruby version has the gem
gem list kairos-chain
```

#### Cursor Connection Issues

1. Verify the path in `~/.cursor/mcp.json` is an absolute path (for repository setup)
2. Check JSON syntax (missing/extra commas, etc.)
3. Completely quit and restart Cursor

---

---

## Usage Tips

### Basic Usage

#### 1. Working with Skills

KairosChain manages AI capability definitions as "Skills".

```
# In Cursor / Claude Code:
"List all current skills"
"Show me the core_safety skill content"
"Use self_introspection to check Kairos state"
```

#### 2. Blockchain Recording

AI evolution processes are recorded on the blockchain.

```
# Checking records
"Show me the chain_history"
"Verify chain integrity with chain_verify"
```

### Practical Usage Patterns

#### Pattern 1: Starting a Development Session

```
# Session startup checklist
1. "Check blockchain status with chain_status"
2. "List available skills with skills_dsl_list"
3. "Verify chain integrity with chain_verify"
```

#### Pattern 2: Skill Evolution (Human Approval Required)

```yaml
# Enable evolution in config/safety.yml
evolution_enabled: true
require_human_approval: true
```

```
# Evolution workflow:
1. "Propose a change to my_skill using skills_evolve"
2. [Human] Review and approve the proposal
3. "Apply the change with skills_evolve (approved=true)"
4. "Verify the record with chain_history"
```

#### Pattern 3: Auditing and Traceability

```
# Track specific change history
"Show recent skill changes with chain_history"
"Get details of a specific block"

# Periodic integrity verification
"Verify the entire chain with chain_verify"
```

### Best Practices

#### 1. Be Cautious with Evolution

- Keep `evolution_enabled: false` as the default
- Start evolution sessions explicitly and disable after completion
- Route all changes through human approval

#### 2. Regular Verification

```bash
# Run daily/weekly
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos-chain
```

#### 3. Backups

```bash
# Regularly backup storage/blockchain.json
cp storage/blockchain.json storage/backups/blockchain_$(date +%Y%m%d).json

# Also backup skill versions
cp -r skills/versions skills/backups/versions_$(date +%Y%m%d)
```

#### 4. Sharing Across Multiple AI Agents

Share the same data directory to synchronize evolution history across multiple AI agents.

```json
// In ~/.cursor/mcp.json or ~/.claude.json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos-chain",
      "args": ["--data-dir", "/shared/kairos-data"],
      "env": {}
    }
  }
}
```

Or using the environment variable:

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "kairos-chain",
      "args": [],
      "env": {
        "KAIROS_DATA_DIR": "/shared/kairos-data"
      }
    }
  }
}
```

### Tool Discovery with tool_guide

The `tool_guide` tool helps you discover and learn about KairosChain tools dynamically.

```
# Browse all tools by category
"Run tool_guide command='catalog'"

# Search for tools by keyword
"Run tool_guide command='search' query='blockchain'"

# Get recommendations for a task
"Run tool_guide command='recommend' task='audit knowledge health'"

# Get detailed info about a specific tool
"Run tool_guide command='detail' tool_name='skills_audit'"

# Learn common workflow patterns
"Run tool_guide command='workflow'"
"Run tool_guide command='workflow' workflow_name='skill_evolution'"
```

**For tool developers (LLM-assisted metadata generation):**

```
# Suggest metadata for a tool
"Run tool_guide command='suggest' tool_name='my_new_tool'"

# Validate suggested metadata
"Run tool_guide command='validate' tool_name='my_new_tool' metadata={...}"

# Apply metadata with human approval
"Run tool_guide command='apply_metadata' tool_name='my_new_tool' metadata={...} approved=true"
```

### Common Commands Reference

| Task | Cursor/Claude Code Prompt |
|------|---------------------------|
| List Skills | "Run skills_dsl_list" |
| Get Specific Skill | "Get core_safety with skills_dsl_get" |
| Chain Status | "Check chain_status" |
| View History | "Show chain_history" |
| Verify Integrity | "Run chain_verify" |
| Record Data | "Record a log with chain_record" |
| Browse Tools | "Run tool_guide command='catalog'" |
| Search Tools | "Run tool_guide command='search' query='...'" |
| Get Tool Help | "Run tool_guide command='detail' tool_name='...'" |

### Security Considerations

1. **Safe Evolution Settings**
   - Keep `require_human_approval: true`
   - Only set `evolution_enabled: true` when needed

2. **Access Control**
   - Restrict allowed paths in `config/safety.yml`
   - Add sensitive files to the blocklist

3. **Audit Logging**
   - All operations are recorded in `action_log`
   - Review logs regularly

## Available Tools (25 core + skill-tools)

The base installation provides 24 tools (23 + 1 HTTP-only). Additional tools can be defined via `tool` blocks in `kairos.rb` when `skill_tools_enabled: true`.

### L0-A: Skills Tools (Markdown) - Read-only

| Tool | Description |
|------|-------------|
| `skills_list` | List all skills sections from kairos.md |
| `skills_get` | Get specific section by ID |

### L0-B: Skills Tools (DSL) - Full Blockchain Record

| Tool | Description |
|------|-------------|
| `skills_dsl_list` | List all skills from kairos.rb |
| `skills_dsl_get` | Get skill definition by ID |
| `skills_evolve` | Propose/apply skill changes |
| `skills_rollback` | Manage version snapshots |

> **Skill-defined tools**: When `skill_tools_enabled: true`, skills with `tool` blocks in `kairos.rb` are also registered here as MCP tools.

### Cross-Layer Promotion Tools

| Tool | Description |
|------|-------------|
| `skills_promote` | Promote knowledge between layers (L2→L1, L1→L0) with optional Persona Assembly |

Commands:
- `analyze`: Generate persona assembly discussion for promotion decision
- `promote`: Execute direct promotion
- `status`: Check promotion requirements

### Audit Tools - Knowledge Lifecycle Management

| Tool | Description |
|------|-------------|
| `skills_audit` | Audit knowledge health across L0/L1/L2 layers with optional Persona Assembly |

Commands:
- `check`: Health check across specified layers
- `stale`: Detect outdated items (L0: no date check, L1: 180 days, L2: 14 days)
- `conflicts`: Detect potential contradictions between knowledge
- `dangerous`: Detect patterns conflicting with L0 safety
- `recommend`: Get promotion and archive recommendations
- `archive`: Archive L1 knowledge (human approval required)
- `unarchive`: Restore from archive (human approval required)

### Resource Tools - Unified Access

| Tool | Description |
|------|-------------|
| `resource_list` | List resources across all layers (L0/L1/L2) with URI |
| `resource_read` | Read resource content by URI |

URI format:
- `l0://kairos.md`, `l0://kairos.rb` (L0 Skills)
- `knowledge://{name}`, `knowledge://{name}/scripts/{file}` (L1)
- `context://{session}/{name}` (L2)

### L1: Knowledge Tools - Hash Reference Record

| Tool | Description |
|------|-------------|
| `knowledge_list` | List all knowledge skills |
| `knowledge_get` | Get knowledge content by name |
| `knowledge_update` | Create/update/delete knowledge (hash recorded) |

### L2: Context Tools - No Blockchain Record

| Tool | Description |
|------|-------------|
| `context_save` | Save context (free modification) |
| `context_create_subdir` | Create scripts/assets/references subdir |

### Blockchain Tools

| Tool | Description |
|------|-------------|
| `chain_status` | Get blockchain status (includes storage backend info) |
| `chain_record` | Record data to blockchain |
| `chain_verify` | Verify chain integrity |
| `chain_history` | View block history (enhanced: shows StateCommit blocks with formatted details) |
| `chain_export` | Export SQLite data to files (SQLite mode only) |
| `chain_import` | Import files to SQLite with automatic backup (SQLite mode only, requires `approved=true`) |

### State Commit Tools (Auditability)

State commits provide cross-layer auditability by creating snapshots of all layers (L0/L1/L2) at specific commit points.

| Tool | Description |
|------|-------------|
| `state_commit` | Create an explicit state commit with reason (records to blockchain) |
| `state_status` | View current state, pending changes, and auto-commit trigger status |
| `state_history` | Browse state commit history and view snapshot details |

### Authentication Tools (HTTP Mode Only)

| Tool | Description |
|------|-------------|
| `token_manage` | Manage Bearer tokens (create, revoke, list, rotate). Requires `owner` role. |

### Guide Tools (Tool Discovery)

Dynamic tool guidance system for discovering and learning about KairosChain tools.

| Tool | Description |
|------|-------------|
| `tool_guide` | Dynamic tool discovery, search, and documentation |

Commands:
- `catalog`: List all tools organized by category
- `search`: Search tools by keyword
- `recommend`: Get tool recommendations for specific tasks
- `detail`: Get detailed information about a specific tool
- `workflow`: Show common workflow patterns
- `suggest`: Generate metadata suggestions for a tool (LLM-assisted)
- `validate`: Validate proposed metadata before applying
- `apply_metadata`: Apply metadata to a tool (requires human approval)

**Key features:**
- Snapshots stored off-chain (JSON files), hash references on-chain
- Auto-commit triggers: L0 changes, promotions/demotions, threshold-based (5 L1 changes or 10 total)
- Empty commit prevention: commits only when manifest hash actually changes

### System Management Tools

| Tool | Description |
|------|-------------|
| `system_upgrade` | Check for gem updates and safely migrate data directory templates |

Commands:
- `check`: Compare current and gem versions, show affected files
- `preview`: Detailed file-by-file analysis with merge previews
- `apply`: Execute upgrade (requires `approved=true`)
- `status`: Show `.kairos_meta.yml` status

## Usage Examples

### List Available Skills

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{}}}' | kairos-chain
```

### Check Blockchain Status

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | kairos-chain
```

### Record a Skill Transition

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_record","arguments":{"logs":["Skill X modified","Reason: improved accuracy"]}}}' | kairos-chain
```

## Self-Evolution Workflow

KairosChain supports **Safe Self-Evolution**:

1. **Enable Evolution** (in `skills/config.yml`):
   ```yaml
   evolution_enabled: true
   require_human_approval: true
   ```

2. **AI Proposes Change**:
   ```bash
   skills_evolve command=propose skill_id=my_skill definition="..."
   ```

3. **Human Reviews and Approves**:
   ```bash
   skills_evolve command=apply skill_id=my_skill definition="..." approved=true
   ```

4. **Change is Applied and Recorded**:
   - Snapshot created in `skills/versions/`
   - Transition recorded on blockchain
   - `Kairos.reload!` updates in-memory state

5. **Verification**:
   ```bash
   chain_verify  # Confirms integrity
   chain_history # Shows the transition record
   ```

---

## Pure Skills Design

### skills.md vs skills.rb

| Aspect | skills.md (Markdown) | skills.rb (Ruby DSL) |
|--------|---------------------|---------------------|
| Nature | Description | Definition |
| Executability | ❌ Cannot be evaluated | ✅ Parseable, validatable |
| Self-Reference | None | Via `Kairos` module |
| Auditability | Git commits only | Native (AST-based diff) |
| AI Role | Reader | Part of the structure |

### Example Skill Definition

```ruby
skill :core_safety do
  version "1.0"
  title "Core Safety Rules"
  
  guarantees do
    immutable
    always_enforced
  end
  
  evolve do
    deny :all  # Cannot be modified
  end
  
  content <<~MD
    ## Core Safety Invariants
    1. Evolution requires explicit enablement
    2. Human approval required by default
    3. All changes create blockchain records
  MD
end
```

### Self-Referential Introspection

```ruby
skill :self_inspection do
  version "1.0"
  
  behavior do
    Kairos.skills.map do |skill|
      {
        id: skill.id,
        version: skill.version,
        can_evolve: skill.can_evolve?(:content)
      }
    end
  end
end
```

## Directory Structure

### Gem Structure (installed via `gem install kairos-chain`)

```
kairos-chain (gem)
├── bin/
│   └── kairos-chain         # Executable (in PATH after gem install)
├── lib/
│   ├── kairos_mcp.rb             # Central module (data_dir management)
│   └── kairos_mcp/
│       ├── version.rb            # Gem version
│       ├── initializer.rb        # `init` command implementation
│       ├── server.rb             # STDIO server
│       ├── http_server.rb        # Streamable HTTP server (Puma/Rack)
│       ├── protocol.rb           # JSON-RPC handler
│       └── ...                   # (same structure as repository)
├── templates/                    # Default files copied on `init`
│   ├── skills/
│   │   ├── kairos.rb             # Default L0 DSL
│   │   ├── kairos.md             # Default L0 philosophy
│   │   └── config.yml            # Default configuration
│   └── config/
│       ├── safety.yml            # Default security settings
│       └── tool_metadata.yml     # Default tool metadata
└── kairos-chain.gemspec            # Gem specification
```

### Data Directory (created by `kairos-chain init`)

```
.kairos/                          # Default data directory (configurable)
├── skills/
│   ├── kairos.md                 # L0-A: Philosophy (read-only)
│   ├── kairos.rb                 # L0-B: Meta-rules (Ruby DSL)
│   ├── config.yml                # Layer & evolution settings
│   └── versions/                 # Version snapshots
├── knowledge/                    # L1: Project Knowledge (Anthropic format)
│   └── example_knowledge/
│       ├── example_knowledge.md  # YAML frontmatter + Markdown
│       ├── scripts/              # Executable scripts
│       ├── assets/               # Templates, resources
│       └── references/           # Reference materials
├── context/                      # L2: Temporary Context (Anthropic format)
│   └── session_xxx/
│       └── hypothesis/
│           └── hypothesis.md
├── config/
│   ├── safety.yml                # Security settings
│   └── tool_metadata.yml         # Tool guide metadata
└── storage/
    ├── blockchain.json           # Chain data (file mode)
    ├── kairos.db                 # SQLite database (sqlite mode)
    ├── embeddings/               # Vector search index (auto-generated)
    └── snapshots/                # StateCommit snapshots
```

### Repository Structure (cloned from GitHub)

```
KairosChain_mcp_server/
├── bin/
│   └── kairos-chain         # Executable
├── lib/
│   ├── kairos_mcp.rb             # Central module (data_dir management)
│   └── kairos_mcp/
│       ├── version.rb            # Gem version
│       ├── initializer.rb        # `init` command implementation
│       ├── server.rb             # STDIO server
│       ├── http_server.rb        # Streamable HTTP server (Puma/Rack)
│       ├── protocol.rb           # JSON-RPC handler
│       ├── kairos.rb             # Self-reference module
│       ├── safe_evolver.rb       # Evolution with safety
│       ├── layer_registry.rb     # Layered architecture management
│       ├── anthropic_skill_parser.rb  # YAML frontmatter + MD parser
│       ├── knowledge_provider.rb # L1 knowledge management
│       ├── context_manager.rb    # L2 context management
│       ├── admin/                # Admin UI (htmx + ERB)
│       │   ├── router.rb        # Route matching and controllers
│       │   ├── helpers.rb       # ERB helpers, session, CSRF
│       │   ├── views/           # ERB templates (layout, pages, partials)
│       │   └── static/          # CSS (PicoCSS overrides)
│       ├── auth/                 # Authentication module
│       │   ├── token_store.rb    # Token CRUD with SHA-256 hashing
│       │   └── authenticator.rb  # Bearer token verification
│       ├── kairos_chain/         # Blockchain implementation
│       │   ├── block.rb
│       │   ├── chain.rb
│       │   ├── merkle_tree.rb
│       │   └── skill_transition.rb
│       ├── state_commit/         # StateCommit module
│       │   ├── manifest_builder.rb
│       │   ├── snapshot_manager.rb
│       │   ├── diff_calculator.rb
│       │   ├── pending_changes.rb
│       │   └── commit_service.rb
│       └── tools/                # MCP tools (25 core)
│           ├── skills_*.rb       # L0 tools
│           ├── knowledge_*.rb    # L1 tools
│           ├── context_*.rb      # L2 tools
│           ├── state_*.rb        # StateCommit tools
│           └── token_manage.rb   # Token management (HTTP mode)
├── templates/                    # Default files for `init` command
│   ├── skills/                   # Default skill templates
│   └── config/                   # Default config templates
├── kairos-chain.gemspec            # Gem specification
├── Gemfile                       # Development dependencies
├── Rakefile                      # Build/test tasks
├── test_local.rb                 # Local test script
└── README.md
```

---

## Future Roadmap

### Near-term

1. **Ethereum Anchor**: Periodic hash anchoring to public chain
2. **Multi-Agent Support**: Track multiple AI agents via `agent_id`
3. **Zero-Knowledge Proofs**: Privacy-preserving verification
4. **Web Dashboard**: Visualize skill evolution history
5. **Team Governance**: Voting system for L0 changes (see FAQ)

### Long-term Vision: Distributed KairosChain Network

A future vision for KairosChain: multiple KairosChain MCP servers communicating over the internet via public MCP protocols, autonomously evolving their knowledge while adhering to their L0 constitutions.

**Key concepts**:
- L0 Constitution as distributed governance
- Knowledge cross-pollination between specialized nodes
- Autonomous evolution within constitutional bounds
- Integration with GenomicsChain PoC/DAO

**Implementation phases**:
1. Dockerization (deployment foundation)
2. ~~HTTP/WebSocket API (remote access)~~ ✅ Streamable HTTP transport (Phase 1 complete)
3. Inter-server communication protocol
4. Distributed consensus mechanism
5. Distributed L0 governance

For detailed vision document, see: [Distributed KairosChain Network Vision](docs/distributed_kairoschain_vision_20260128_en.md)

---

## Deployment and Operation

### Data Storage Overview

KairosChain stores data in the following locations:

| Directory | Contents | Git Tracked | Importance |
|-----------|----------|-------------|------------|
| `skills/kairos.rb` | L0 DSL (evolvable) | Yes | High |
| `skills/kairos.md` | L0 Philosophy (immutable) | Yes | High |
| `skills/config.yml` | Configuration | Yes | High |
| `skills/versions/` | DSL snapshots | Yes | Medium |
| `knowledge/` | L1 project knowledge | Yes | High |
| `context/` | L2 temporary context | Yes | Low |
| `storage/blockchain.json` | Blockchain data | Yes | High |
| `storage/embeddings/*.ann` | Vector index (auto-generated) | No | Low |
| `storage/snapshots/` | StateCommit snapshots (off-chain) | No | Medium |
| `skills/action_log.jsonl` | Action log | No | Low |

### Blockchain Storage Format

The private blockchain is stored as a **JSON flat file** at `storage/blockchain.json`:

```json
[
  {
    "index": 0,
    "timestamp": "1970-01-01T00:00:00.000000Z",
    "data": ["Genesis Block"],
    "previous_hash": "0000...0000",
    "merkle_root": "0000...0000",
    "hash": "a1b2c3..."
  },
  {
    "index": 1,
    "timestamp": "2026-01-20T10:30:00.123456Z",
    "data": ["{\"type\":\"skill_evolution\",\"skill_id\":\"...\"}"],
    "previous_hash": "a1b2c3...",
    "merkle_root": "xyz...",
    "hash": "789..."
  }
]
```

**Why JSON flat file?**
- **Simplicity**: No external dependencies
- **Readability**: Human-inspectable for auditing
- **Portability**: Copy to backup/migrate
- **Philosophy alignment**: Auditability is core to Kairos

### Recommended Operation Patterns

#### Pattern 1: Fork + Private Repository (Recommended)

Fork KairosChain and keep it as a private repository. This is the simplest approach.

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub                                                         │
│  ┌─────────────────────┐    ┌─────────────────────┐            │
│  │ KairosChain (public)│───▶│ your-fork (private) │            │
│  │ - code updates      │    │ - skills/           │            │
│  └─────────────────────┘    │ - knowledge/        │            │
│                             │ - storage/          │            │
│                             └─────────────────────┘            │
└─────────────────────────────────────────────────────────────────┘
```

**Pros:** Simple, everything in one place, full backup  
**Cons:** May conflict when pulling upstream updates

**Setup:**
```bash
# Fork on GitHub, then clone your private fork
git clone https://github.com/YOUR_USERNAME/KairosChain_2026.git
cd KairosChain_2026

# Add upstream for updates
git remote add upstream https://github.com/masaomi/KairosChain_2026.git

# Pull upstream updates (when needed)
git fetch upstream
git merge upstream/main
```

#### Pattern 2: Data Directory Separation

Keep KairosChain code and data in separate repositories.

```
┌─────────────────────────────────────────────────────────────────┐
│  Two repositories                                               │
│                                                                 │
│  ┌────────────────────┐    ┌─────────────────────────────┐     │
│  │ KairosChain (public│    │ my-kairos-data (private)    │     │
│  │ - lib/             │    │ - skills/                   │     │
│  │ - bin/             │    │ - knowledge/                │     │
│  │ - config/          │    │ - context/                  │     │
│  └────────────────────┘    │ - storage/                  │     │
│                            └─────────────────────────────┘     │
│                                                                 │
│  Link via symlinks:                                             │
│  $ ln -s ~/my-kairos-data/skills ./skills                       │
│  $ ln -s ~/my-kairos-data/knowledge ./knowledge                 │
│  $ ln -s ~/my-kairos-data/storage ./storage                     │
└─────────────────────────────────────────────────────────────────┘
```

**Pros:** Easy to pull upstream updates, clean separation  
**Cons:** Requires symlink setup, two repos to manage

#### Pattern 3: Cloud Sync (Non-Git)

Sync data directories with cloud storage (Dropbox, iCloud, Google Drive).

```bash
# Example: Symlink to Dropbox
ln -s ~/Dropbox/KairosChain/skills ./skills
ln -s ~/Dropbox/KairosChain/knowledge ./knowledge
ln -s ~/Dropbox/KairosChain/storage ./storage
```

**Pros:** Automatic sync, no Git knowledge required  
**Cons:** Weak version control, conflict resolution is harder

### Backup Strategy

#### Regular Backups

```bash
# Create backup script
#!/bin/bash
BACKUP_DIR=~/kairos-backups/$(date +%Y%m%d_%H%M%S)
mkdir -p $BACKUP_DIR

# Backup critical data
cp -r skills/ $BACKUP_DIR/
cp -r knowledge/ $BACKUP_DIR/
cp -r storage/ $BACKUP_DIR/

# Cleanup old backups (older than 30 days)
find ~/kairos-backups -mtime +30 -type d -exec rm -rf {} +

echo "Backup created: $BACKUP_DIR"
```

#### What to Back Up

| Priority | Directory | Reason |
|----------|-----------|--------|
| **Critical** | `storage/blockchain.json` | Immutable evolution history |
| **Critical** | `skills/kairos.rb` | L0 meta-rules |
| **High** | `knowledge/` | Project knowledge |
| **Medium** | `skills/versions/` | Evolution snapshots |
| **Low** | `context/` | Temporary (can be recreated) |
| **Skip** | `storage/embeddings/` | Auto-regenerated |

#### Verification After Restore

```bash
# After restoring from backup, verify integrity
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | kairos-chain
```

### Documentation Management

README.md and README_jp.md are **auto-generated** from L1 knowledge files. Do not edit them directly.

#### Single Source of Truth

The documentation content lives in L1 knowledge files under `KairosChain_mcp_server/knowledge/`:

| L1 Knowledge | Contents |
|---|---|
| `kairoschain_philosophy` / `_jp` | Philosophy, architecture, layered design |
| `kairoschain_setup` / `_jp` | Installation, configuration, testing |
| `kairoschain_usage` / `_jp` | Tools reference, usage patterns |
| `kairoschain_design` / `_jp` | Pure Skills design, directory structure |
| `kairoschain_operations` / `_jp` | Roadmap, deployment, operations |
| `kairoschain_faq` / `_jp` | FAQ, subtree integration |

Header/footer templates are in `scripts/readme_templates/`.

#### Updating Documentation

1. Edit the relevant L1 knowledge file in `KairosChain_mcp_server/knowledge/`
2. Regenerate READMEs:

```bash
# Generate README.md and README_jp.md from L1 knowledge
rake build_readme

# Or run the script directly
ruby scripts/build_readme.rb
```

3. Commit both the L1 knowledge change and the regenerated README

#### Other Commands

```bash
# Check if READMEs are up to date (useful in CI)
rake check_readme

# Preview what would be generated without writing files
rake preview_readme

# Show help and options
ruby scripts/build_readme.rb --help
```

#### Why Auto-Generated?

- **Single Source of Truth**: L1 knowledge is the only place to edit documentation
- **MCP Accessible**: LLMs can query documentation via `knowledge_get` / `knowledge_list`
- **Auditable**: Documentation changes are tracked as L1 knowledge updates (hash recorded on blockchain)
- **Semantic Search**: RAG-enabled search across all documentation via MCP

---

---

## FAQ

### Q: Can LLMs automatically modify L1/L2?

**A:** Yes, LLMs can modify L1/L2 autonomously (or upon user request) using MCP tools.

| Layer | LLM Modification | Conditions |
|-------|------------------|------------|
| **L0** (kairos.rb) | Possible but strict | `evolution_enabled: true` + `approved: true` (human approval) + blockchain record |
| **L1** (knowledge/) | Possible | Hash-only blockchain record, no human approval required |
| **L2** (context/) | Free | No per-operation record, no approval required |

Note: `kairos.md` is read-only and cannot be modified by LLMs.

**StateCommit addendum**: Regardless of per-operation recording, [StateCommit](#q-what-is-statecommit-and-how-does-it-improve-auditability) can capture all layers (including L2) at commit points. Snapshots are stored off-chain; only hash references are recorded on-chain.

**Usage Examples:**
- L2: Temporarily save hypotheses during research with `context_save`
- L1: Persist project coding conventions with `knowledge_update`
- L0: Propose meta-skill changes with `skills_evolve` (human approval required)

---

### Q: How do I decide which layer to store knowledge in?

**A:** Use the built-in `layer_placement_guide` knowledge (L1) for guidance. Here's a quick decision tree:

```
1. Does this modify Kairos's own rules or constraints?
   → YES: L0 (requires human approval)
   → NO: Continue

2. Is this temporary or session-specific?
   → YES: L2 (freely modifiable, no per-operation recording; can be captured by StateCommit)
   → NO: Continue

3. Will this be reused across multiple sessions?
   → YES: L1 (hash reference recorded)
   → NO: L2
```

**Key principle:** When in doubt, start with L2 and promote later.

| Layer | Purpose | Typical Content |
|-------|---------|-----------------|
| L0 | Kairos meta-rules | Safety constraints, evolution rules |
| L1 | Project knowledge | Coding conventions, architecture docs |
| L2 | Temporary work | Hypotheses, session notes, experiments |

**Promotion pattern:** Knowledge can move up as it matures: L2 → L1 → L0

For detailed guidance, use: `knowledge_get name="layer_placement_guide"`

---

### Q: How do I maintain L1 knowledge health? How do I prevent L1 bloat?

**A:** Use the `l1_health_guide` knowledge (L1) and the `skills_audit` tool for periodic maintenance.

**Key Thresholds:**

| Condition | Threshold | Action |
|-----------|-----------|--------|
| Review recommended | 180 days without update | Run `skills_audit` check |
| Archive candidate | 270 days without update | Consider archiving |
| Dangerous patterns | Detected | Update or archive immediately |

**Recommended Audit Schedule:**

| Frequency | Commands |
|-----------|----------|
| Monthly | `skills_audit command="check" layer="L1"` |
| Monthly | `skills_audit command="recommend" layer="L1"` |
| Quarterly | `skills_audit command="conflicts" layer="L1"` |
| On issues | `skills_audit command="dangerous" layer="L1"` |

**Self-Check Checklist (from l1_health_guide):**

- [ ] **Relevance**: Is this knowledge still applicable?
- [ ] **Uniqueness**: Does similar knowledge already exist?
- [ ] **Quality**: Is the information accurate and up-to-date?
- [ ] **Safety**: Does it align with L0 safety constraints?

**Archive Process:**

```bash
# Review knowledge
knowledge_get name="candidate_knowledge"

# Archive with approval
skills_audit command="archive" target="candidate_knowledge" reason="Project completed" approved=true
```

For detailed guidelines, use: `knowledge_get name="l1_health_guide"`

---

### Q: What is Persona Assembly and when should I use it?

**A:** Persona Assembly is an optional feature that provides multi-perspective evaluation when promoting knowledge between layers or auditing knowledge health. It helps surface different viewpoints before human decision-making.

**Assembly Modes:**

| Mode | Description | Token Cost | Use Case |
|------|-------------|------------|----------|
| `oneshot` (default) | Single-round evaluation by all personas | ~500 + 300×N | Routine decisions, quick feedback |
| `discussion` | Multi-round facilitated debate | ~500 + 300×N×R + 200×R | Important decisions, deep analysis |

*N = number of personas, R = number of rounds (default max: 3)*

**When to use each mode:**

| Scenario | Recommended Mode |
|----------|------------------|
| L2 → L1 promotion | oneshot |
| L1 → L0 promotion | **discussion** |
| Archive decision | oneshot |
| Conflict resolution | **discussion** |
| Quick validation | oneshot (kairos only) |
| High-stakes decision | discussion (all personas) |

**Available personas:**

| Persona | Role | Bias |
|---------|------|------|
| `kairos` | Philosophy Advocate / Default Facilitator | Auditability, constraint preservation |
| `conservative` | Stability Guardian | Prefers lower-commitment layers |
| `radical` | Innovation Advocate | Favors action, accepts higher risk |
| `pragmatic` | Cost-Benefit Analyst | Implementation complexity vs. value |
| `optimistic` | Opportunity Seeker | Focuses on potential benefits |
| `skeptic` | Risk Identifier | Looks for problems and edge cases |
| `archivist` | Knowledge Curator | Knowledge freshness, redundancy |
| `guardian` | Safety Watchdog | L0 alignment, security risks |
| `promoter` | Promotion Scout | Identifies promotion candidates |

**Usage:**

```bash
# Oneshot mode (default) - single evaluation
skills_promote command="analyze" source_name="my_knowledge" from_layer="L1" to_layer="L0" personas=["kairos", "conservative", "skeptic"]

# Discussion mode - multi-round with facilitator
skills_promote command="analyze" source_name="my_knowledge" from_layer="L1" to_layer="L0" \
  assembly_mode="discussion" facilitator="kairos" max_rounds=3 consensus_threshold=0.6 \
  personas=["kairos", "conservative", "radical", "skeptic"]

# With skills_audit
skills_audit command="check" with_assembly=true assembly_mode="oneshot"
skills_audit command="check" with_assembly=true assembly_mode="discussion" facilitator="kairos"

# Direct promotion without assembly
skills_promote command="promote" source_name="my_context" from_layer="L2" to_layer="L1" session_id="xxx"
```

**Discussion mode workflow:**

```
Round 1: Each persona states position (SUPPORT/OPPOSE/NEUTRAL)
         ↓
Facilitator: Summarizes agreements/disagreements, identifies concerns
         ↓
Round 2-N: Personas respond to concerns (if consensus < threshold)
         ↓
Final Summary: Consensus status, recommendation, key resolutions
```

**Configuration defaults (from `audit_rules` L0 skill):**

```yaml
assembly_defaults:
  mode: "oneshot"           # Default mode
  facilitator: "kairos"     # Discussion moderator
  max_rounds: 3             # Maximum rounds in discussion
  consensus_threshold: 0.6  # 60% = early termination
```

**Important:** Assembly output is advisory only. Human judgment remains the final authority, especially for L0 promotions.

Persona definitions can be customized in: `knowledge/persona_definitions/`

---

### Q: Is API extension needed for team usage?

**A:** KairosChain now supports **Streamable HTTP transport** for remote/team access. For team usage, the following options are available:

| Method | Additional Implementation | Suitable Scale |
|--------|---------------------------|----------------|
| **Git sharing** | Not required | Small teams (2-5 people) |
| **SSH tunneling** | Not required | LAN teams (2-10 people) |
| **Streamable HTTP** | ✅ Available (`--http` flag) | Medium teams (5-20 people) |
| **MCP over SSE** | Not needed (Streamable HTTP replaces) | When remote connection is needed |

**Git sharing (simplest):**
```
# Manage knowledge/, skills/, data/blockchain.json with Git
# Each member runs the MCP server locally
# Changes are synced via Git
```

**SSH tunneling (LAN teams, no code changes required):**

For teams on the same LAN, you can connect to a remote MCP server via SSH. This requires no additional implementation — just SSH access to the server machine.

**Setup:**

1. Run the MCP server on a shared machine (e.g., `server.local`):
   ```bash
   # On the server machine
   cd /path/to/KairosChain_mcp_server
   # Server is ready (stdio-based, no daemon needed)
   ```

2. Configure MCP client to connect via SSH:

   **For Cursor (`~/.cursor/mcp.json`):**
   ```json
   {
     "mcpServers": {
       "kairos-chain": {
         "command": "ssh",
         "args": [
           "-o", "StrictHostKeyChecking=accept-new",
           "user@server.local",
           "cd /path/to/KairosChain_mcp_server && ruby bin/kairos-chain"
         ]
       }
     }
   }
   ```

   **For Claude Code:**
   ```bash
   claude mcp add kairos-chain ssh -- -o StrictHostKeyChecking=accept-new user@server.local "cd /path/to/KairosChain_mcp_server && ruby bin/kairos-chain"
   ```

3. (Optional) Use SSH key authentication for passwordless access:
   ```bash
   # Generate key if not exists
   ssh-keygen -t ed25519
   
   # Copy to server
   ssh-copy-id user@server.local
   ```

**SSH tunneling advantages:**
- No code changes or HTTP server implementation needed
- Uses existing SSH infrastructure and authentication
- Encrypted communication by default
- Works with stdio-based MCP protocol as-is

**SSH tunneling limitations:**
- Requires SSH access to the server machine
- Each client opens a new server process (no shared state between connections)
- For concurrent writes, use Git to sync `storage/blockchain.json` and `knowledge/`

**When Streamable HTTP is better:**
- Remote access beyond SSH reach (internet-facing)
- Bearer token authentication needed
- Integration with CI/CD or external systems
- See [Optional: Streamable HTTP Transport](#optional-streamable-http-transport-remoteteam-access) for setup details

---

### Q: Is a voting system needed for changes to kairos.rb or kairos.md in team settings?

**A:** It depends on team size and requirements.

**Current implementation (single approver model):**
```yaml
require_human_approval: true  # One person's approval is sufficient
```

**Features that may be needed for team operations:**

| Feature | L0 | L1 | L2 |
|---------|----|----|----| 
| Voting system | Recommended | Optional | Not needed |
| Quorum | Recommended | - | - |
| Proposal period | Recommended | - | - |
| Veto power | Depends | - | - |

**Tools needed in the future (not implemented):**
```
governance_propose    - Create change proposals
governance_vote       - Vote on proposals (approve/reject/abstain)
governance_status     - Check proposal voting status
governance_execute    - Execute proposals that exceed threshold
```

**Special nature of kairos.md:**

Since `kairos.md` corresponds to a "constitution," consensus building outside the system (GitHub Discussion, etc.) is recommended:

1. Propose via GitHub Issue / Discussion
2. Offline discussion with the entire team
3. Reach consensus by unanimity (or supermajority)
4. Manually edit and commit the file

---

### Q: How do I run local tests?

**A:** Run tests with the following commands:

```bash
cd KairosChain_mcp_server
ruby test_local.rb
```

Test coverage:
- Layer Registry operation verification
- List of 18 core MCP tools
- Resource tools (resource_list, resource_read)
- L1 Knowledge read/write
- L2 Context read/write
- L0 Skills DSL (6 skills) loading

After testing, artifacts (`context/test_session`) are created. Delete if not needed:
```bash
rm -rf context/test_session
```

---

### Q: What meta-skills are included in kairos.rb?

**A:** Currently 8 meta-skills are defined:

| Skill | Description | Modifiability |
|-------|-------------|---------------|
| `l0_governance` | L0 self-governance rules | Content only |
| `core_safety` | Safety foundation | Not modifiable (`deny :all`) |
| `evolution_rules` | Evolution rules definition | Content only |
| `layer_awareness` | Layer structure awareness | Content only |
| `approval_workflow` | Approval workflow with checklist | Content only |
| `self_inspection` | Self-inspection capability | Content only |
| `chain_awareness` | Blockchain awareness | Content only |
| `audit_rules` | Knowledge lifecycle audit rules | Content only |

The `l0_governance` skill is special: it defines which skills can exist in L0, implementing the Pure Agent Skill principle of self-referential governance.

See `skills/kairos.rb` for details.

---

### Q: How do I modify L0 skills? What is the procedure?

**A:** L0 modification requires a strict multi-step procedure with human oversight. This is intentional — L0 is the "constitution" of KairosChain.

**Prerequisites:**
- `evolution_enabled: true` in `skills/config.yml` (must be set manually)
- Session evolution count < `max_evolutions_per_session` (default: 3)
- Target skill is not in `immutable_skills` (`core_safety` cannot be modified)
- Change is permitted by the skill's `evolve` block

**Step-by-Step Procedure:**

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Human: Manually set evolution_enabled: true in config.yml    │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. AI: skills_evolve command="propose" skill_id="..." def="..." │
│    - Syntax validation                                          │
│    - l0_governance allowed_skills check                         │
│    - evolve rules check                                         │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. Human: Review with 15-item checklist (approval_workflow)     │
│    - Traceability (3 items)                                     │
│    - Consistency (3 items)                                      │
│    - Scope (3 items)                                            │
│    - Authority (3 items)                                        │
│    - Pure Agent Compliance (3 items)                            │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. AI: skills_evolve command="apply" ... approved=true          │
│    - Creates version snapshot                                   │
│    - Updates kairos.rb                                          │
│    - Records to blockchain                                      │
│    - Kairos.reload!                                             │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. Verify: skills_dsl_get, chain_history, chain_verify          │
└───────────────────────────────┬─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. Human: Set evolution_enabled: false (recommended)            │
└─────────────────────────────────────────────────────────────────┘
```

**Key Points:**

| Aspect | Description |
|--------|-------------|
| **Enabling evolution** | Must be done manually (AI cannot change config.yml) |
| **Approval** | Human must verify 15-item checklist |
| **Recording** | All changes recorded on blockchain |
| **Rollback** | Use `skills_rollback` to restore from snapshot |
| **Immutable** | `core_safety` cannot be changed (`evolve deny :all`) |

**Adding a New L0 Skill Type:**

To add a completely new meta-skill type (e.g., `my_new_meta_skill`):

1. First, evolve `l0_governance` to add it to `allowed_skills` list
2. Then, use `skills_evolve command="add"` to create the new skill

Both steps require human approval and checklist verification.

**L1/L2 are NOT affected:**

| Layer | Tool | Human Approval | Evolution Enable |
|-------|------|----------------|------------------|
| **L0** | `skills_evolve` | Required | Required |
| **L1** | `knowledge_update` | Not required | Not required |
| **L2** | `context_save` | Not required | Not required |

L1 and L2 remain freely modifiable by AI as before.

---

### Q: What is L0 Auto-Check? How does it help with the 15-item checklist?

**A:** L0 Auto-Check is a feature that **automatically verifies mechanical checks** before L0 changes, reducing the human review burden.

**How it works:**

When you run `skills_evolve command="propose"`, the system automatically runs checks defined in the `approval_workflow` skill (which is part of L0). This keeps the check criteria self-referential (Pure Agent Skill compliant).

**Check Categories:**

| Category | Type | Items | Description |
|----------|------|-------|-------------|
| **Consistency** | Mechanical | 4 | In allowed_skills, not immutable, syntax valid, evolve rules |
| **Authority** | Mechanical | 2 | evolution_enabled, within session limit |
| **Scope** | Mechanical | 1 | Rollback possible |
| **Traceability** | Human | 2 | Reason documented, traceable to L0 rule |
| **Pure Compliance** | Human | 2 | No external deps, LLM-independent |

**Example Output:**

```
📋 L0 AUTO-CHECK REPORT
============================================================

✅ All 7 mechanical checks PASSED. 3 items require human verification.

### Consistency
✅ Skill in allowed_skills
   evolution_rules is in allowed_skills
✅ Skill not immutable
   evolution_rules is not immutable
✅ Ruby syntax valid
   Syntax is valid
✅ Evolve rules permit change
   Skill's evolve rules allow modification

### Authority
✅ Evolution enabled
   evolution_enabled: true in config
✅ Within session limit
   1/3 evolutions used

### Scope
✅ Rollback possible
   Version snapshots directory exists

### Traceability
✅ Reason documented
   Reason: Updating for clarity
⚠️ Traceable to L0 rule
   ⚠️ HUMAN CHECK: Verify this change can be traced to an explicit L0 rule.

### Pure Compliance
⚠️ No external dependencies
   ⚠️ HUMAN CHECK: Verify the change doesn't introduce external dependencies.
⚠️ LLM-independent semantics
   ⚠️ HUMAN CHECK: Would different LLMs interpret this change the same way?

------------------------------------------------------------
⚠️  3 item(s) require HUMAN verification.
    Review the ⚠️ items above before approving.
------------------------------------------------------------
```

**Benefits:**

| Without Auto-Check | With Auto-Check |
|-------------------|-----------------|
| Human verifies all 15 items | AI verifies 7 mechanical items |
| Easy to miss syntax errors | Syntax validated automatically |
| Manual l0_governance check | Automatic allowed_skills check |
| No structured report | Clear pass/fail report |

**Usage:**

```bash
# Include reason for better traceability
skills_evolve command="propose" skill_id="evolution_rules" definition="..." reason="Clarify evolution workflow"
```

**Pure Agent Skill Compliance:**

The check logic is defined **within L0** (in the `approval_workflow` skill's behavior block), not in external code. This means the criteria for checking L0 changes are themselves part of L0 — maintaining self-referential integrity.

---

### Q: How does KairosChain decide when to evolve its own skills? Is there a meta-skill for this?

**A:** **KairosChain intentionally does NOT include logic for deciding "when to evolve."** This decision is delegated to the human side (or the AI client interacting with humans).

**Current design responsibilities:**

| Responsibility | Owner | Details |
|----------------|-------|---------|
| **Evolution judgment (when/what)** | Human / AI client | Outside KairosChain |
| **Evolution constraints (allow/deny)** | KairosChain | Validated by internal rules |
| **Evolution approval** | Human | Explicit `approved: true` |
| **Evolution recording** | KairosChain | Automatically recorded on blockchain |

**What is already implemented:**
- ✅ Evolution constraints (`SafeEvolver`)
- ✅ Workflow (propose → review → apply)
- ✅ Layer structure (L0/L1/L2)
- ✅ 8 meta-skills definition

**What is NOT implemented (by design):**
- ❌ "When to evolve" decision logic
- ❌ Self-detection of capability gaps
- ❌ Recognition of learning opportunities
- ❌ Evolution trigger conditions

**Design rationale:**

This is intentional. From `kairos.md` (PHILOSOPHY-020 Minimum-Nomic):

| Approach | Problem |
|----------|---------|
| Completely fixed rules | No adaptation, system becomes obsolete |
| **Unrestricted self-modification** | **Chaos, no accountability** |

To avoid "unrestricted self-modification," KairosChain intentionally delegates evolution triggers to external actors. KairosChain serves as a **gatekeeper** and **recorder**, not an autonomous self-modifier.

**Future extensibility:**

If you want to add a meta-skill for "when to evolve," you could define something like:

```ruby
skill :evolution_trigger do
  version "1.0"
  title "Evolution Trigger Logic"
  
  evolve do
    allow :content      # Trigger conditions can be modified
    deny :behavior      # Decision logic itself is fixed
  end
  
  content <<~MD
    ## Evolution Trigger Conditions
    
    1. When the same error pattern occurs 3+ times
    2. When user explicitly says "remember this"
    3. When new domain knowledge is provided
    → Propose saving to L1
  MD
end
```

However, even with such a meta-skill, **final approval should remain with humans**. This is the core of KairosChain's safety design.

---

### Q: What is Skill-Tool Unification? Can I add MCP tools without editing Ruby files?

**A:** Yes! Skills in `kairos.rb` can now define MCP tools via the `tool` block. This unifies skills and tools in L0-B.

**How it works:**

```ruby
# In kairos.rb
skill :my_custom_tool do
  version "1.0"
  title "My Custom Tool"
  
  # Traditional behavior (for skill introspection)
  behavior do
    { capability: "..." }
  end
  
  # Tool definition (exposed as MCP tool)
  tool do
    name "my_custom_tool"
    description "Does something useful"
    
    input do
      property :arg, type: "string", description: "Argument"
      required :arg
    end
    
    execute do |args|
      # Tool implementation
      { result: process(args["arg"]) }
    end
  end
end
```

**Enable in config:**

```yaml
# skills/config.yml
skill_tools_enabled: true   # Default: false
```

**Key points:**
- Default is **disabled** (conservative)
- Adding/modifying tools requires editing `kairos.rb` (L0 constraints apply)
- Changes require human approval (`approved: true`)
- All changes are recorded on blockchain
- Aligns with Minimum-Nomic: "can change, but recorded"

**Why is this so strict?**

L0 (`kairos.rb`) is intentionally locked with **triple protection**:

| Protection | Setting | Effect |
|------------|---------|--------|
| 1 | `evolution_enabled: false` | Blocks any kairos.rb changes |
| 2 | `require_human_approval: true` | Requires explicit human approval |
| 3 | `skill_tools_enabled: false` | Skills not registered as tools |

**Important:** There is no MCP tool to modify `config.yml`. Even if an LLM is asked to "change these settings," it cannot — humans must manually edit `config.yml`.

This is by design: L0 corresponds to "constitution/law" in the legal analogy. It should rarely change. For frequent tool additions, consider:

- **Current limitation**: Only L0 supports `tool` blocks
- **Future possibility**: L1 tool definition support (lighter constraints, no human approval, hash-only recording)

For most use cases, **L0 tools should not need frequent changes**. The strict lock ensures system integrity.

---

### Q: What is the difference between adding tools via kairos.rb vs tools/ directory?

**A:** There are two ways to add MCP tools to KairosChain:

1. **Via `kairos.rb` (L0)**: Using the `tool` block in skill definitions
2. **Via `tools/` directory**: Adding Ruby files directly to `lib/kairos_mcp/tools/`

**Functional equivalence:** Both methods register MCP tools that can be called by LLMs.

**Key differences:**

| Aspect | `kairos.rb` (L0) | `tools/` directory |
|--------|------------------|-------------------|
| Addition method | Via `skills_evolve` tool | Manual file addition |
| Human approval | **Required** | Not required |
| Blockchain record | **Yes** (full record) | No |
| Activation | `skill_tools_enabled: true` | Always active |
| Under KairosChain management | **Yes** | No |

**Important:** Adding tools directly to `tools/` is **not via KairosChain**. It's a regular code change (tracked by git, but not audited by KairosChain's blockchain).

**Design intent:**

- **Core infrastructure** (`tools/`): Tools necessary for KairosChain itself to function. Should rarely change.
- **Extension tools** (`kairos.rb`): Custom tools added by users. Use when you want change history audited.

In other words:
- `kairos.rb` route: "Strict but auditable"
- `tools/` route: "Free but not audited"

**Future consideration:** L1 tool definition support may be added (lighter constraints, hash-only recording) for tools that are useful but don't need L0's strict controls.

---

### Q: Should KairosChain proactively recommend skill creation to the LLM?

**A:** **No. KairosChain should focus on "recording and constraining," not "recommending when to learn."** The logic for recommending skill creation should be delegated to the LLM/AI agent side (e.g., Cursor Rules, system_prompt).

**Why this separation?**

| Aspect | Implemented in KairosChain | Delegated to LLM/Agent |
|--------|---------------------------|------------------------|
| **Minimum-Nomic Principle** | "Changes should be rare and high-cost" | Agent decides when learning is valuable |
| **Separation of Concerns** | KairosChain = gatekeeper & recorder | LLM = decision-maker for learning triggers |
| **Customizability** | Same constraints for all users | Each user can configure different agent behaviors |
| **Prompt Injection Risk** | Recommendation logic could be attacked | Defense can be handled at agent level |

**KairosChain's role:**
- ✅ Record skill changes immutably
- ✅ Enforce evolution constraints (approval, layer rules)
- ✅ Provide tools for skill management
- ❌ Decide "when" or "what" to learn

**Recommended approach for proactive skill recommendations:**

Configure your AI agent (Cursor Rules, Claude system_prompt, etc.) to include:

```markdown
# Agent Learning Rules

## When to Recommend Skill Creation
- After solving a problem that required multiple iterations
- When the user says "I always forget..." or "This is a common pattern"
- When similar code patterns are generated repeatedly

## Recommendation Format
"I noticed [pattern]. Would you like me to capture this as a KairosChain skill?"

## Then use KairosChain tools:
- L2: `context_save` for temporary hypotheses
- L1: `knowledge_update` for project knowledge (hash-only record)
- L0: `skills_evolve` for meta-skills (requires human approval)
```

This keeps KairosChain as a **neutral infrastructure** while allowing each team/user to define their own learning policies at the agent level.

**Skill promotion triggers (same principle applies):**

KairosChain also does NOT automatically suggest skill promotion (L2→L1→L0). Configure your AI agent to suggest promotions:

```markdown
# Skill Promotion Rules (add to above)

## When to Suggest L2 → L1 Promotion
- Same context referenced 3+ times across sessions
- User says "this is useful" or "I want to keep this"
- Hypothesis validated through actual use

## When to Suggest L1 → L0 Promotion
- Knowledge governs KairosChain's own behavior
- Mature, stable pattern that shouldn't change often
- Team consensus reached (for shared instances)

## Promotion Suggestion Format
"This knowledge has been useful across multiple sessions. 
Would you like to promote it from L2 to L1?"

## Then use KairosChain tools:
- `skills_promote command="analyze"` - With Persona Assembly for deliberation
- `skills_promote command="promote"` - Direct promotion
```

---

### Q: What happens when skills or knowledge contradict each other?

**A:** Currently, KairosChain **does not have automatic contradiction detection** between skills/knowledge. This is a recognized limitation noted in the design paper.

**Why no automatic detection?**

KairosChain intentionally delegates "judgment" to external actors (LLM/human):

| KairosChain's Responsibility | Delegated to External |
|-----------------------------|----------------------|
| Record changes | Judge what to save |
| Enforce constraints | Judge content validity |
| Maintain history | Resolve contradictions |

**Current approach when contradictions occur:**

1. **Implicit layer priority**: `L0 (meta-rules) > L1 (project knowledge) > L2 (temporary context)` — lower layers take precedence
2. **LLM interpretation**: When multiple skills are referenced, the LLM interprets and mediates based on context
3. **Human resolution**: Important contradictions are resolved by humans updating the relevant skills

**Future possibility:**

Contradiction detection could be added as an L1 knowledge or L0 skill:

```markdown
# Contradiction Detection Skill (example)

## Detection Rules
- Same topic with different recommendations
- Conflicting constraint definitions
- Circular dependencies

## Resolution Flow
1. Warn user upon detection
2. Generate discussion via Persona Assembly
3. Human makes final decision
```

However, "what constitutes a contradiction" is itself a philosophical question, and KairosChain's current design intentionally does not make that judgment.

---

### Q: What is StateCommit and how does it improve auditability?

**A:** StateCommit is a feature that creates snapshots of all layers (L0/L1/L2) at specific "commit points" for improved auditability. Unlike individual skill change records, StateCommit captures the **entire system state** at a moment in time.

**Why StateCommit?**

| Existing Records | StateCommit |
|------------------|-------------|
| L0: Full blockchain transaction | Captures all layers together |
| L1: Hash reference only | Includes layer relationships |
| L2: No recording | Shows "why" via commit reason |

**Storage strategy:**
- **Off-chain**: Full snapshot JSON files in `storage/snapshots/`
- **On-chain**: Hash reference and summary only (prevents blockchain bloat)

**Commit types:**

| Type | Trigger | Reason |
|------|---------|--------|
| `explicit` | User calls `state_commit` | Required (user-provided) |
| `auto` | System detects trigger conditions | Auto-generated |

**Auto-commit triggers (OR conditions):**
- L0 change detected
- Promotion (L2→L1 or L1→L0) occurred
- Demotion/archive occurred
- Session end (when MCP server stops)
- L1 changes threshold (default: 5)
- Total changes threshold (default: 10)

**AND condition (empty commit prevention):**
Auto-commit only triggers if the manifest hash differs from the previous commit.

**Configuration (`skills/config.yml`):**

```yaml
state_commit:
  enabled: true
  snapshot_dir: "storage/snapshots"
  max_snapshots: 100

  auto_commit:
    enabled: true
    skip_if_no_changes: true  # AND condition

    on_events:
      l0_change: true
      promotion: true
      demotion: true
      session_end: true

    change_threshold:
      enabled: true
      l1_changes: 5
      total_changes: 10
```

**Usage:**

```bash
# Create explicit commit
state_commit reason="Feature complete"

# Check current status
state_status

# View commit history
state_history

# View specific commit details
state_history hash="abc123"
```

---

### Q: What happens when too many skills accumulate? Is there a cleanup mechanism?

**A:** KairosChain provides the `skills_audit` tool for knowledge lifecycle management across all layers.

**The `skills_audit` tool provides:**

| Command | Description |
|---------|-------------|
| `check` | Health check across L0/L1/L2 layers |
| `stale` | Detect outdated items (layer-specific thresholds) |
| `conflicts` | Detect potential contradictions between knowledge |
| `dangerous` | Detect patterns that may conflict with L0 safety |
| `recommend` | Get promotion/archive recommendations |
| `archive` | Archive L1 knowledge (human approval required) |
| `unarchive` | Restore from archive (human approval required) |

**Layer-specific staleness thresholds:**

| Layer | Threshold | Rationale |
|-------|-----------|-----------|
| L0 | No date check | Stability is a feature, not staleness |
| L1 | 180 days | Project knowledge should be periodically reviewed |
| L2 | 14 days | Temporary contexts should be cleaned up |

**Usage examples:**

```bash
# Run health check across all layers
skills_audit command="check" layer="all"

# Find stale L1 knowledge
skills_audit command="stale" layer="L1"

# Get recommendations for archiving and promotion
skills_audit command="recommend"

# Archive with Persona Assembly for deeper analysis
skills_audit command="check" with_assembly=true assembly_mode="discussion"

# Archive a stale knowledge item (requires human approval)
skills_audit command="archive" target="old_knowledge" reason="Unused for 1 year" approved=true
```

**Archive mechanism:**

- Archived knowledge is moved to `knowledge/.archived/` directory
- Archive metadata (reason, date, superseded_by) is stored in `.archive_meta.yml`
- Archived items are excluded from normal searches but can be restored
- All archive/unarchive operations are recorded on blockchain

**Human oversight:**

Archive and unarchive operations require explicit human approval (`approved: true`). This rule is defined in L0 `audit_rules` skill and is itself configurable (L0-B).

---

### Q: How do I fix a skill when it provides incorrect or outdated information?

**A:** KairosChain provides multiple tools for identifying and fixing problematic knowledge.

**Step 1: Identify issues with `skills_audit`**

```bash
# Check for dangerous patterns (safety conflicts)
skills_audit command="dangerous" layer="L1"

# Check for stale knowledge
skills_audit command="stale" layer="L1"

# Full health check with Persona Assembly
skills_audit command="check" with_assembly=true
```

**Step 2: Review and fix with knowledge tools**

| Tool | Purpose |
|------|---------|
| `knowledge_get` | Retrieve skill content for review |
| `knowledge_update command="update"` | Modify skill (recorded on blockchain) |
| `skills_audit command="archive"` | Archive if obsolete (human approval required) |

**Modification workflow:**

```
1. User: "That answer was wrong. Show me the skill you referenced."
2. LLM: Calls knowledge_get name="skill_name"
3. User: "The section about X is outdated. Fix it."
4. LLM: Proposes modified content
5. User: Approves changes
6. LLM: Calls knowledge_update command="update" content="..." reason="User feedback: outdated info"
```

**For obsolete knowledge (archive instead of delete):**

```bash
# Archive obsolete knowledge (preserves history, removes from active search)
skills_audit command="archive" target="outdated_skill" reason="Superseded by new_skill" approved=true

# Later, if needed, restore from archive
skills_audit command="unarchive" target="outdated_skill" reason="Still relevant" approved=true
```

**Dangerous pattern detection:**

The `skills_audit command="dangerous"` checks for:
- Language suggesting bypassing safety checks
- Hardcoded credentials or API keys
- Patterns that conflict with L0 `core_safety`

**Proactive maintenance:**

Configure your AI agent (Cursor Rules / system_prompt) to suggest periodic audits:

```markdown
# Skill Quality Rules

## Periodic Audit
- Run `skills_audit command="check"` monthly or when issues arise
- Review recommendations from `skills_audit command="recommend"`

## When User Reports Issues
1. Run `skills_audit command="dangerous"` to check for safety issues
2. Use `knowledge_get` to review the specific skill
3. Fix with `knowledge_update` or archive if obsolete
```

---

### Q: What are the advantages and disadvantages of using SQLite?

**A:** SQLite is an optional storage backend for team environments. Here's what you need to know:

**Advantages:**

| Advantage | Description |
|-----------|-------------|
| **Concurrent Access** | Built-in locking prevents data corruption when multiple users access simultaneously |
| **ACID Transactions** | Guarantees data integrity even during crashes |
| **WAL Mode** | Allows concurrent reads and writes (readers don't block writers) |
| **Single File** | Easy backup (just copy the `.db` file) |
| **No Server Required** | Unlike PostgreSQL/MySQL, no separate database server needed |
| **Fast Queries** | Indexed queries are faster than scanning JSON files |

**Disadvantages / Cautions:**

| Disadvantage | Description | Mitigation |
|--------------|-------------|------------|
| **External Dependency** | Requires `sqlite3` gem installation | Use file backend for simple deployments |
| **Network File System** | SQLite is NOT recommended on NFS/network drives | Use local disk or PostgreSQL for network storage |
| **Write Scalability** | Only one writer at a time (WAL helps but has limits) | Fine for small teams (2-10), consider PostgreSQL for larger |
| **Binary Format** | Cannot read data directly without tools | Use `Exporter` to create human-readable files |
| **Gem Updates** | Need to track `sqlite3` gem updates | Pin version in Gemfile, test before updating |

**When to Use SQLite:**

```
Individual use → File backend (default)
     │
     ▼
Small team (2-10 people)
  └─► SQLite backend ✓
     │
     ▼
Large team (10+ people)
  └─► PostgreSQL (future)
```

**Recovery from Issues:**

If SQLite database becomes corrupted or you encounter issues:

```ruby
# 1. Export current data (if possible)
KairosMcp::Storage::Exporter.export(
  db_path: "storage/kairos.db",
  output_dir: "storage/backup"
)

# 2. Delete corrupted database
# rm storage/kairos.db

# 3. Rebuild from files
KairosMcp::Storage::Importer.rebuild_from_files(
  db_path: "storage/kairos.db"
)
```

**Best Practices:**

1. **Regular Exports**: Periodically export to files for human-readable backups
2. **Version Pin**: Pin sqlite3 gem version in Gemfile
3. **Local Disk**: Always use local disk, not network drives
4. **Backup Strategy**: Backup both `.db` file AND exported files

---

### Q: How do I inspect SQLite data without SQL commands?

**A:** Use the built-in Exporter to create human-readable files:

```ruby
require_relative 'lib/kairos_mcp/storage/exporter'

# Export to human-readable JSON/JSONL files
KairosMcp::Storage::Exporter.export(
  db_path: "storage/kairos.db",
  output_dir: "storage/export"
)
```

This creates:
- `blockchain.json` - All blocks in readable JSON
- `action_log.jsonl` - Action logs (one JSON per line)
- `knowledge_meta.json` - Knowledge metadata
- `manifest.json` - Export information

You can then view these files with any text editor or JSON viewer.

**Note:** Knowledge content (`*.md` files) is always stored as files in `knowledge/` directory, regardless of storage backend. SQLite only stores metadata for faster queries.

---

### Q: What is Pure Agent Skill and why does it matter?

**A:** Pure Agent Skill is a design principle that ensures L0's semantic self-containment. It addresses a fundamental question: **How can an AI system govern its own evolution without external dependencies?**

**The Core Principle:**

> All rules, criteria, and justifications for modifying L0 must be explicitly described within L0 itself.

**What "Pure" means in this context:**

Pure does **not** mean:
- Complete absence of side effects
- Byte-level identical outputs

Pure **means**:
- Skill semantics don't change based on which LLM interprets them
- Meaning doesn't vary by who the approver is
- Meaning doesn't depend on execution history or time

**How KairosChain implements this:**

| Before | After |
|--------|-------|
| `config.yml` defined allowed L0 skills (external) | `l0_governance` skill defines this (self-referential) |
| Approval criteria were implicit | `approval_workflow` includes explicit checklist |
| Changes were possible without L0 awareness | L0 governs itself through its own rules |

**The `l0_governance` skill:**

```ruby
skill :l0_governance do
  behavior do
    {
      allowed_skills: [:core_safety, :l0_governance, ...],
      immutable_skills: [:core_safety],
      purity_requirements: { all_criteria_in_l0: true, ... }
    }
  end
end
```

This makes "what can be in L0" part of L0 itself, not external configuration.

**Theoretical Limits (Gödelian):**

Perfect self-containment is theoretically impossible due to:

1. **Halting Problem**: Cannot always mechanically verify if a change satisfies all criteria
2. **Meta-level Dependency**: The interpreter of L0 rules (code/LLM) exists outside L0
3. **Bootstrapping**: Initial L0 must be authored externally

KairosChain acknowledges these limits while aiming for **sufficient Purity**:

> If an independent reviewer, using only L0's documented rules, can reconstruct the justification for any L0 change, then L0 is sufficiently Pure.

**Practical Benefits:**

- **Auditability**: All governance criteria are in one place
- **Resistance to Drift**: Harder to accidentally break governance
- **Explicit Approval Criteria**: Human reviewers have a checklist
- **Self-documenting**: L0 explains itself

For full specification, see `skills/kairos.md` sections [SPEC-010] and [SPEC-020].

---

### Q: Why does KairosChain use Ruby, specifically DSL and AST?

**A:** KairosChain's choice of Ruby DSL/AST is not accidental but essential for self-modifying AI systems. A self-referential skill system must satisfy three constraints simultaneously:

| Requirement | Description | Ruby's Implementation |
|-------------|-------------|----------------------|
| **Static Analyzability** | Security verification before execution | `RubyVM::AbstractSyntaxTree` (standard library) |
| **Runtime Modifiability** | Add/modify skills during operation | `define_method`, `class_eval`, open classes |
| **Human Readability** | Specifications domain experts can read | Natural-language-like DSL syntax |

**Why these three matter for self-reference:**

KairosChain implements a unique self-referential structure where **skills are constrained by skills themselves**. For example, `evolution_rules` skill contains:

```ruby
evolve do
  allow :content
  deny :guarantees, :evolve, :behavior
end
```

This means "the rule about evolving cannot itself be evolved" — a bootstrap constraint that requires:
1. **Parsing** the rule definition (static analysis via AST)
2. **Evaluating** the constraint at runtime (metaprogramming)
3. **Understanding** what the rule means (human-readable DSL)

**Comparison with other languages:**

| Aspect | Lisp/Clojure | Ruby | Python | JavaScript |
|--------|-------------|------|--------|------------|
| **Homoiconicity (code=data)** | ○ Complete | × No | × No | × No |
| **Human readability** | △ S-expressions hard to read | ○ Natural | △ Brackets required | △ Syntax constraints |
| **AST tools in stdlib** | × Not needed but audit-hard | ○ Complete | △ Limited | △ External deps |
| **DSL expressiveness** | ○ | ○ | △ | △ |
| **Production ecosystem** | △ | ○ Proven (Rails, RSpec) | ○ | ○ |

**Theoretically optimal:** Lisp/Clojure (homoiconicity makes self-modification natural)  
**Practically optimal:** **Ruby** (balances readability + analyzability + evolvability)

**The decisive advantage — Separability:**

In KairosChain's self-referential system, the separation of **definition**, **analysis**, and **execution** is crucial:

```ruby
# 1. Definition: Human-readable
skill :evolution_rules do
  evolve { deny :evolve }  # Self-constraint
end

# 2. Analysis: Validate before execution
RubyVM::AbstractSyntaxTree.parse(definition)  # Static analysis

# 3. Execution: Evaluate constraint
skill.evolution_rules.can_evolve?(:evolve)  # => false
```

In Lisp, code=data blurs the boundary between "analysis" and "execution." While this provides freedom, achieving **auditability** requires additional mechanisms.

**Conclusion:** Given KairosChain's goal of "auditable AI skill evolution," Ruby is the **practical optimum** — not the only correct answer, but a realistic choice that satisfies all three constraints simultaneously.

---

### Q: What's the difference between using local skills vs. KairosChain?

**A:** AI agent editors (Cursor, Claude Code, Antigravity, etc.) typically provide a local skills/rules mechanism. Here's a comparison with KairosChain:

**Local Skills (e.g., `.cursor/skills/`, `CLAUDE.md`, agent rules)**

| Pros | Cons |
|------|------|
| Simple — just place files, ready to use | No change history — who/when/why is not tracked |
| Fast — direct file read, no MCP overhead | Too free — unintended modifications can occur |
| Native IDE integration | No layer concept — temporary hypotheses and permanent knowledge mix |
| Standard format (SKILL.md, etc.) | No self-reference — AI cannot inspect/explain its own skills |

**KairosChain (MCP server)**

| Pros | Cons |
|------|------|
| **Auditability** — all changes recorded on blockchain | MCP call overhead — slight latency |
| **Layered architecture** — L0 (meta-rules) / L1 (project knowledge) / L2 (temporary context) | Learning curve — must understand layers and tools |
| **Approval workflow** — L0 changes require human approval | Setup required — MCP server configuration |
| **Self-reference** — AI can inspect, explain, and evolve skills | Complexity — may be overkill for simple use cases |
| **Semantic search** — RAG-enabled meaning-based search | |
| **StateCommit** — system-wide snapshots at any point | |
| **Lifecycle management** — `skills_audit` for detecting/archiving stale knowledge | |

**Usage Guidelines:**

| Scenario | Recommendation |
|----------|----------------|
| Small personal project | Local skills |
| Audit/accountability required | KairosChain |
| Recording AI capability evolution | KairosChain |
| Team knowledge sharing | KairosChain (especially with SQLite backend) |
| Quick prototyping | Local skills → migrate to KairosChain when mature |

**The Essential Difference:**

- **Local Skills**: Function as "convenient documentation"
- **KairosChain**: Functions as an "auditable ledger of AI capability evolution"

KairosChain's philosophy:

> *"KairosChain answers not 'Is this result correct?' but 'How was this intelligence formed?'"*

If you just need to use skills, local skills are sufficient. However, if you need to **explain how the AI learned and evolved**, KairosChain is the appropriate choice.

**Hybrid Approach:**

You can use both simultaneously:
- Local skills for quick, informal knowledge
- KairosChain for knowledge that needs audit trails

KairosChain doesn't replace local skills — it provides an additional layer of auditability and governance when needed.

---

## Subtree Integration Guide

KairosChain_2026 is designed to be embedded into other projects using `git subtree`. This allows each project to:

- Receive framework updates from the upstream KairosChain_2026 repository
- Accumulate project-specific knowledge (L1) locally
- Keep everything in a single repository with no extra clone steps

> **Gem vs Subtree:** If you installed KairosChain as a gem (`gem install kairos-chain`), you do NOT need subtree setup. The gem approach and the subtree approach are independent installation methods. The subtree approach is for users who want the full source code embedded in their project repository. See the [Installation](#installation-gem-or-repository) section for details on the gem approach.

### Why Subtree (Not Submodule)

| Aspect | subtree | submodule |
|--------|---------|-----------|
| Local file additions | Managed naturally by parent repo | Complicated inside submodule |
| `git clone` for teammates | Just works (all files included) | Requires `git submodule init && update` |
| CI/CD | No special setup | Needs submodule initialization step |
| Knowledge accumulation | Commit directly to parent repo | Awkward cross-repo management |
| Accidental upstream push | Safe unless explicit `subtree push` | Easier to push to wrong remote |

### How It Works with KairosChain Layers

```
KairosChain_2026 (upstream)           YourProject (parent repo)
┌──────────────────────────┐          ┌─────────────────────────────────┐
│ L0: Framework code       │ subtree  │ server/                         │
│ L0: Meta-skills          │ --pull-> │   KairosChain_mcp_server/       │
│ L1: Generic templates    │          │     knowledge/                  │
│   example_knowledge/     │          │       example_knowledge/ <- sync│
│   persona_definitions/   │          │       persona_definitions/<-sync│
│                          │          │       your_project/   <- local  │
│                          │          │       your_tools/     <- local  │
│                          │          │     context/          <- L2     │
└──────────────────────────┘          └─────────────────────────────────┘
```

| Layer | Location | Managed By |
|-------|----------|------------|
| L0 (meta-skills, framework) | Upstream KairosChain_2026 | `subtree pull` syncs to all projects |
| L1 (project knowledge) | `knowledge/` in each project | Committed to parent repo only |
| L2 (session context) | `context/` | Ephemeral, gitignored |

### Setup: Adding KairosChain to a New Project

**Step 1: Add subtree**

```bash
git subtree add --prefix=server https://github.com/masaomi/KairosChain_2026 main --squash
```

**Step 2: Register remote (for convenience)**

```bash
git remote add mcp_server https://github.com/masaomi/KairosChain_2026
```

**Step 3: Configure .gitignore**

In `server/.gitignore`, add:

```gitignore
# Bundler
KairosChain_mcp_server/Gemfile.lock
KairosChain_mcp_server/.bundle/
KairosChain_mcp_server/vendor/

# L2 session context (ephemeral)
KairosChain_mcp_server/context/

# Vector search index files (auto-generated)
KairosChain_mcp_server/storage/embeddings/**/*.ann
KairosChain_mcp_server/storage/embeddings/**/*.json
!KairosChain_mcp_server/storage/embeddings/**/.gitkeep

# Action log
KairosChain_mcp_server/skills/action_log.jsonl
```

### Important: Data Directory Configuration for Subtree

Since the gemification update, KairosChain resolves data paths via `KairosMcp.data_dir`, which defaults to `.kairos/` in the current working directory. When using subtree, you **must** specify `--data-dir` to point to the existing data location inside the subtree, otherwise a new empty `.kairos/` directory will be created and your existing `skills/`, `knowledge/`, and `storage/` data will not be found.

**Cursor IDE (`mcp.json`):**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "server/KairosChain_mcp_server/bin/kairos-chain",
      "args": ["--data-dir", "server/KairosChain_mcp_server"]
    }
  }
}
```

**Claude Code (`.mcp.json`):**

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "server/KairosChain_mcp_server/bin/kairos-chain",
      "args": ["--data-dir", "server/KairosChain_mcp_server"]
    }
  }
}
```

Alternatively, use the environment variable:

```bash
export KAIROS_DATA_DIR=server/KairosChain_mcp_server
```

> **Note:** If you previously ran without `--data-dir` and a `.kairos/` directory was auto-created, you can safely delete it. Your actual data remains in `server/KairosChain_mcp_server/`.

### Daily Operations

**Pull upstream updates:**

```bash
git subtree pull --prefix=server mcp_server main --squash
```

- Files from upstream are updated/merged
- Locally added files (project knowledge) are NOT affected
- If a file exists both locally and upstream with different content, a normal merge conflict occurs — resolve as usual

**Commit project-specific knowledge:**

```bash
# Knowledge files created by MCP server appear as untracked
git add server/KairosChain_mcp_server/knowledge/your_project/
git add server/KairosChain_mcp_server/storage/blockchain.json
git commit -m "Add project-specific knowledge"
```

These commits go to the **parent repo only** — upstream is never affected.

**Push to upstream (CAUTION):**

```bash
# Only if you want to contribute changes back to KairosChain_2026
# Usually NOT needed for project-specific files
git subtree push --prefix=server mcp_server main
```

> **Warning:** Do NOT push unless you intentionally want to send changes to the KairosChain_2026 repository. Project-specific knowledge should stay in the parent repo.

### Conflict Resolution

When `subtree pull` encounters a conflict:

```bash
$ git subtree pull --prefix=server mcp_server main --squash
# CONFLICT (add/add): Merge conflict in server/.../some_file.md

# 1. Open the conflicted file and resolve
# 2. Stage and commit
git add server/KairosChain_mcp_server/...
git commit -m "Resolve subtree merge conflict, keep local changes"
```

**Rule of thumb:** For project knowledge files, prefer local content over upstream content.

### Multi-Project Deployment Example

```
ProjectA/                           ProjectB/
├── .git/                           ├── .git/
└── server/ (subtree)               └── server/ (subtree)
    └── KairosChain_mcp_server/         └── KairosChain_mcp_server/
        ├── knowledge/                      ├── knowledge/
        │   ├── example_knowledge/ (shared) │   ├── example_knowledge/ (shared)
        │   ├── tool_a/       (A-specific)  │   ├── tool_b/       (B-specific)
        │   └── utils_a/      (A-specific)  │   └── utils_b/      (B-specific)
        └── storage/                        └── storage/
            └── blockchain.json (A-specific)    └── blockchain.json (B-specific)
```

Each project independently:
- Pulls framework updates from the same upstream
- Accumulates its own L1 knowledge
- Manages its own blockchain state

### After Subtree Pull: Template Updates

When you pull upstream updates that include changes to template files (`kairos.rb`, `kairos.md`, `config.yml`, etc.), those changes are applied directly to the subtree directory since it contains the full source. However, if you have modified these files locally, you may encounter merge conflicts during `subtree pull`.

For subtree users, the `system_upgrade` MCP tool and `kairos-chain upgrade` CLI command are **not needed** — the subtree pull mechanism itself handles file updates. The upgrade tooling is designed for **gem-based installations** where template files are bundled inside the gem and need to be migrated to the user's data directory.

**Summary of update methods:**

| Installation Method | How to Update | Template Handling |
|---|---|---|
| **Gem** (`gem install`) | `gem update kairos-chain` + `system_upgrade` tool | 3-way hash merge via `.kairos_meta.yml` |
| **Subtree** (`git subtree`) | `git subtree pull` | Standard git merge (resolve conflicts manually) |
| **Repository clone** | `git pull` | Standard git merge (resolve conflicts manually) |

### Reference

- Upstream: `https://github.com/masaomi/KairosChain_2026`
- Subtree prefix: `server/` (or your preferred path)
- Remote alias: `mcp_server`

---

## License

See [LICENSE](./LICENSE) file.

---

**Version**: 1.0.0
**Last Updated**: 2026-02-15

> *"KairosChain answers not 'Is this result correct?' but 'How was this intelligence formed?'"*
