# KairosChain MMP P2P Skill/SkillSet Exchange User Guide

**Date**: 2026-02-20
**Version**: 1.0.0
**Author**: Dr. Masa Hatakeyama
**Branch**: `feature/skillset-plugin`

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Setup](#3-setup)
4. [SkillSet Management (CLI)](#4-skillset-management-cli)
5. [P2P Individual Skill Exchange](#5-p2p-individual-skill-exchange)
6. [P2P SkillSet Exchange](#6-p2p-skillset-exchange)
7. [Offline Exchange via CLI](#7-offline-exchange-via-cli)
8. [Configuration Reference](#8-configuration-reference)
9. [Security Model](#9-security-model)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Overview

KairosChain uses the **Model Meeting Protocol (MMP)** to enable peer-to-peer knowledge exchange between agent instances. Two levels of exchange are supported:

| Level | Unit | Content | Use Case |
|-------|------|---------|----------|
| **Skill** | Single Markdown file | One knowledge file with YAML frontmatter | Quick sharing of a specific protocol or pattern |
| **SkillSet** | Packaged directory (tar.gz) | `skillset.json` + `knowledge/` + `config/` | Sharing a complete, versioned knowledge package |

Both levels enforce a **knowledge-only constraint**: only non-executable content (Markdown, YAML, etc.) may be exchanged over the network. SkillSets containing code (`tools/`, `lib/` with `.rb`, `.py`, `.sh`, etc.) must be installed manually via trusted channels.

### Architecture

```
Agent A (KairosChain)                    Agent B (KairosChain)
┌─────────────────────┐                  ┌─────────────────────┐
│ HttpServer :8080    │                  │ HttpServer :9090    │
│  └─ MeetingRouter   │  HTTP/JSON       │  └─ MeetingRouter   │
│      /meeting/v1/*  │ ◄──────────────► │      /meeting/v1/*  │
│                     │                  │                     │
│ SkillSetManager     │                  │ SkillSetManager     │
│  └─ .kairos/        │                  │  └─ .kairos/        │
│     skillsets/      │                  │     skillsets/       │
│     knowledge/      │                  │     knowledge/       │
└─────────────────────┘                  └─────────────────────┘
```

---

## 2. Prerequisites

- Ruby 3.0+
- KairosChain MCP server (`KairosChain_mcp_server/`)
- Gems: `rack`, `puma` (for HTTP mode)

```bash
cd KairosChain_mcp_server
bundle install   # or: gem install rack puma
```

---

## 3. Setup

### 3.1 Initialize Data Directories

Each agent needs its own data directory:

```bash
# Agent A
kairos-chain init --data-dir /path/to/agent_a/.kairos

# Agent B
kairos-chain init --data-dir /path/to/agent_b/.kairos
```

### 3.2 Install the MMP SkillSet

The MMP SkillSet is shipped as a template. Install it into each agent:

```bash
# Agent A
kairos-chain skillset install templates/skillsets/mmp --data-dir /path/to/agent_a/.kairos

# Agent B
kairos-chain skillset install templates/skillsets/mmp --data-dir /path/to/agent_b/.kairos
```

### 3.3 Configure MMP

Edit the MMP config at `.kairos/skillsets/mmp/config/meeting.yml`:

```yaml
# Enable MMP
enabled: true

# Set a unique identity for this agent
identity:
  name: "Agent Alpha"
  description: "Genomics knowledge agent"
  scope: "bioinformatics"

# Skill exchange settings
skill_exchange:
  public_by_default: true     # Make all skills visible to peers
  allow_executable: false      # Never accept executable content

# SkillSet exchange settings
skillset_exchange:
  enabled: true
  knowledge_only: true         # Only exchange knowledge-only SkillSets
  auto_install: false          # Require manual approval
```

### 3.4 Start HTTP Servers

Each agent runs on a different port:

```bash
# Terminal 1: Agent A on port 8080
kairos-chain --http --port 8080 --data-dir /path/to/agent_a/.kairos

# Terminal 2: Agent B on port 9090
kairos-chain --http --port 9090 --data-dir /path/to/agent_b/.kairos
```

---

## 4. SkillSet Management (CLI)

### List Installed SkillSets

```bash
kairos-chain skillset list
```

Output:
```
Installed SkillSets:

  mmp v1.0.0 [L1] (enabled)
    Model Meeting Protocol for P2P agent communication and skill exchange
    Tools: 4, Deps: none

  my_knowledge v1.0.0 [L2] (enabled)
    Custom knowledge pack
    Tools: 0, Deps: none
```

### Other Commands

```bash
kairos-chain skillset info <name>       # Show detailed SkillSet info
kairos-chain skillset enable <name>     # Enable a SkillSet
kairos-chain skillset disable <name>    # Disable a SkillSet
kairos-chain skillset remove <name>     # Remove a SkillSet
```

---

## 5. P2P Individual Skill Exchange

Individual skills are Markdown files with YAML frontmatter stored in the agent's `knowledge/` directory.

### 5.1 Create a Shareable Skill

Create a knowledge file at `.kairos/knowledge/my_protocol/my_protocol.md`:

```markdown
---
name: my_protocol
description: A custom communication protocol
version: 1.0.0
tags:
  - protocol
  - custom
public: true
---

# My Protocol

Protocol rules and documentation here...
```

The `public: true` flag makes this skill visible to peers.

### 5.2 Exchange Flow (HTTP API)

**Step 1 — Introduction**: Agent B discovers Agent A.

```bash
curl http://localhost:8080/meeting/v1/introduce
```

Response:
```json
{
  "identity": {
    "name": "Agent Alpha",
    "instance_id": "abc123...",
    "protocol_version": "1.0.0"
  },
  "capabilities": { "skills": true, "skillsets": true },
  "skills": [
    {
      "id": "sha256-...",
      "name": "my_protocol",
      "layer": "L1",
      "format": "markdown",
      "tags": ["protocol", "custom"],
      "content_hash": "e3b0c4..."
    }
  ]
}
```

**Step 2 — Discover Skills**: List all public skills.

```bash
curl http://localhost:8080/meeting/v1/skills
```

**Step 3 — Get Details**: Inspect a specific skill.

```bash
curl "http://localhost:8080/meeting/v1/skill_details?skill_id=my_protocol"
```

**Step 4 — Acquire Content**: Request the full skill content.

```bash
curl -X POST http://localhost:8080/meeting/v1/skill_content \
  -H "Content-Type: application/json" \
  -d '{"skill_id": "my_protocol", "to": "agent-beta"}'
```

Response includes the packaged skill with content and hash for verification.

---

## 6. P2P SkillSet Exchange

SkillSet exchange transfers entire versioned knowledge packages (multiple files, configs, metadata).

### 6.1 Create a Knowledge-Only SkillSet

Create the following directory structure:

```
my_knowledge_pack/
  skillset.json
  knowledge/
    topic_a/
      topic_a.md
    topic_b/
      topic_b.md
```

`skillset.json`:
```json
{
  "name": "my_knowledge_pack",
  "version": "1.0.0",
  "description": "Curated genomics analysis patterns",
  "author": "Your Name",
  "layer": "L2",
  "depends_on": [],
  "provides": ["genomics_patterns"],
  "tool_classes": [],
  "config_files": [],
  "knowledge_dirs": ["knowledge/topic_a", "knowledge/topic_b"]
}
```

Install it:
```bash
kairos-chain skillset install ./my_knowledge_pack
```

### 6.2 Exchange Flow (HTTP API)

**Step 1 — List Exchangeable SkillSets on Agent A**:

```bash
curl http://localhost:8080/meeting/v1/skillsets
```

Response:
```json
{
  "skillsets": [
    {
      "name": "my_knowledge_pack",
      "version": "1.0.0",
      "layer": "L2",
      "description": "Curated genomics analysis patterns",
      "knowledge_only": true,
      "content_hash": "a1b2c3...",
      "file_count": 3
    }
  ],
  "count": 1
}
```

Note: SkillSets with executable code (like `mmp` itself) are excluded.

**Step 2 — Get SkillSet Details**:

```bash
curl "http://localhost:8080/meeting/v1/skillset_details?name=my_knowledge_pack"
```

Returns full metadata including file list and content hash.

**Step 3 — Download SkillSet Archive**:

```bash
curl -X POST http://localhost:8080/meeting/v1/skillset_content \
  -H "Content-Type: application/json" \
  -d '{"name": "my_knowledge_pack"}' \
  > received_package.json
```

Response:
```json
{
  "skillset_package": {
    "name": "my_knowledge_pack",
    "version": "1.0.0",
    "content_hash": "a1b2c3...",
    "archive_base64": "H4sIAAAA...",
    "file_list": ["skillset.json", "knowledge/topic_a/topic_a.md", ...],
    "packaged_at": "2026-02-20T12:00:00Z"
  }
}
```

**Step 4 — Install on Agent B**:

```bash
# Using the CLI (recommended)
kairos-chain skillset install-archive received_package.json \
  --data-dir /path/to/agent_b/.kairos

# Or pipe via stdin
cat received_package.json | kairos-chain skillset install-archive - \
  --data-dir /path/to/agent_b/.kairos
```

The installer automatically:
1. Validates the SkillSet name (safe characters only)
2. Extracts the archive with path traversal protection
3. Verifies the content hash matches
4. Confirms no executable code is present
5. Installs into `.kairos/skillsets/my_knowledge_pack/`

---

## 7. Offline Exchange via CLI

You can exchange SkillSets without running HTTP servers, using the CLI `package` and `install-archive` commands.

### Export (Agent A)

```bash
kairos-chain skillset package my_knowledge_pack > my_knowledge_pack.json
```

Transfer `my_knowledge_pack.json` via any method (USB, email, scp, etc.).

### Import (Agent B)

```bash
kairos-chain skillset install-archive my_knowledge_pack.json
```

### Pipe Between Agents

```bash
# Direct pipe over SSH
ssh agent_a "kairos-chain skillset package my_knowledge_pack" | \
  kairos-chain skillset install-archive -
```

---

## 8. Configuration Reference

### meeting.yml (Full Reference)

```yaml
# Master switch
enabled: true                    # Enable/disable MMP entirely

# Agent identity
identity:
  name: "Agent Name"             # Display name
  description: "Description"     # What this agent does
  scope: "general"               # Domain scope

# Individual skill exchange
skill_exchange:
  allowed_formats:               # Accepted content formats
    - markdown
    - yaml_frontmatter
  allow_executable: false        # NEVER set to true for P2P
  public_by_default: false       # Default visibility of skills

# SkillSet package exchange
skillset_exchange:
  enabled: true                  # Enable SkillSet exchange endpoints
  knowledge_only: true           # Only exchange knowledge-only packages
  auto_install: false            # Auto-install received SkillSets

# Rate limiting
constraints:
  max_skill_size_bytes: 100000   # Max individual skill size
  rate_limit_per_minute: 10      # Request rate limit

# HTTP server (for MMP endpoints)
http_server:
  enabled: true
  host: "127.0.0.1"             # Bind address
  port: 8080                     # Port number
  timeout: 10                    # Request timeout (seconds)
```

### skillset.json (SkillSet Metadata)

```json
{
  "name": "my_skillset",          // REQUIRED: safe name [a-zA-Z0-9_-]
  "version": "1.0.0",            // REQUIRED: SemVer
  "description": "...",          // Recommended
  "author": "...",               // Recommended
  "layer": "L2",                 // L0=core, L1=standard, L2=community
  "depends_on": [],              // SkillSet dependencies
  "provides": ["capability"],    // Declared capabilities
  "tool_classes": [],             // Empty for knowledge-only
  "config_files": [],             // Config file paths
  "knowledge_dirs": ["knowledge/topic"]  // Knowledge directories
}
```

---

## 9. Security Model

### Knowledge-Only Constraint

Only SkillSets that contain **no executable code** may be exchanged over P2P. The system scans `tools/` and `lib/` directories for:

- **Executable file extensions**: `.rb`, `.py`, `.sh`, `.js`, `.ts`, `.pl`, `.lua`, `.exe`, `.so`, `.dylib`, `.dll`, `.class`, `.jar`, `.wasm`
- **Shebang lines**: Files starting with `#!` (e.g., `#!/usr/bin/env python3`)

SkillSets with any of these are blocked from packaging and from installation via archive.

### Name Validation

SkillSet names must:
- Match the pattern `[a-zA-Z0-9][a-zA-Z0-9_-]*`
- Be 64 characters or fewer
- Not contain path separators (`/`, `\`, `..`)

### Archive Path Traversal Protection

When extracting tar.gz archives:
- All paths are resolved to absolute paths and verified to stay within the target directory
- Symlinks and hard links in the archive are silently skipped
- Path traversal attempts (e.g., `../../etc/passwd`) raise a `SecurityError`

### Content Hash Verification

Every SkillSet has a content hash (SHA-256) computed from all of its files. On installation from an archive:
1. The archive is extracted to a temporary directory
2. The content hash is recomputed from the extracted files
3. If the hash does not match the declared hash, installation is rejected

### Layer-Based Governance

| Layer | Recording | Approval | Typical Use |
|-------|-----------|----------|-------------|
| L0 | Full blockchain record (all file hashes) | Human approval required to disable/remove | Core protocols |
| L1 | Hash-only blockchain record | Standard enable/disable | Standard SkillSets |
| L2 | No blockchain record | Free enable/disable | Community/experimental |

---

## 10. Troubleshooting

### "MMP SkillSet is not installed or not enabled" (503)

- Verify MMP is installed: `kairos-chain skillset list`
- Check `enabled: true` in `.kairos/skillsets/mmp/config/meeting.yml`

### "SkillSet exchange is not enabled" (403)

- Set `skillset_exchange.enabled: true` in `meeting.yml`

### "Only knowledge-only SkillSets can be packaged" (SecurityError)

- The SkillSet contains executable files in `tools/` or `lib/`
- Remove executable files or install manually via `kairos-chain skillset install <path>`

### "Invalid SkillSet name" (ArgumentError)

- Names must match `[a-zA-Z0-9][a-zA-Z0-9_-]*` and be at most 64 characters
- No slashes, dots, or special characters

### "Content hash mismatch" (SecurityError)

- The archive was modified in transit
- Re-download the SkillSet from the source

### "SkillSet already installed" (ArgumentError)

- Remove the existing one first: `kairos-chain skillset remove <name>`
- Then install again

### Checking Connectivity

```bash
# Verify Agent A's MMP endpoints are reachable
curl http://localhost:8080/meeting/v1/introduce

# Check health
curl http://localhost:8080/health
```

---

## Appendix: MMP Endpoint Quick Reference

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/meeting/v1/introduce` | Self-introduction |
| POST | `/meeting/v1/introduce` | Receive peer introduction |
| GET | `/meeting/v1/skills` | List public skills |
| GET | `/meeting/v1/skill_details?skill_id=X` | Skill metadata |
| POST | `/meeting/v1/skill_content` | Request skill content |
| POST | `/meeting/v1/request_skill` | Submit skill request |
| POST | `/meeting/v1/reflect` | Send reflection |
| POST | `/meeting/v1/message` | Generic MMP message |
| GET | `/meeting/v1/skillsets` | List exchangeable SkillSets |
| GET | `/meeting/v1/skillset_details?name=X` | SkillSet metadata |
| POST | `/meeting/v1/skillset_content` | Download SkillSet archive |

For the complete wire protocol specification, see:
`templates/skillsets/mmp/knowledge/meeting_protocol_wire_spec/meeting_protocol_wire_spec.md`
