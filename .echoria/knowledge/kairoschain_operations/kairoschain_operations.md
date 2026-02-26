---
name: kairoschain_operations
description: "Future roadmap, deployment, and operations guide"
version: 1.1
layer: L1
tags: [documentation, readme, operations, deployment, roadmap, backup]
readme_order: 5
readme_lang: en
---

## Future Roadmap

### Completed Phases

The following development phases have been completed on the `feature/skillset-plugin` branch:

| Phase | Description | Key Deliverables |
|-------|-------------|-----------------|
| **Phase 1** | SkillSet Plugin Infrastructure | SkillSetManager, ToolRegistry extension, CLI subcommands, layer-based governance |
| **Phase 2** | MMP as SkillSet + P2P Direct Mode | MMP packaged as standalone SkillSet, MeetingRouter with 8 HTTP endpoints, 4 MCP tools |
| **Phase 2.5** | P2P Local Tests | 72 assertions across 4 test sections |
| **Phase 3** | Knowledge-only SkillSet Exchange | `knowledge_only?`/`exchangeable?` checks, tar.gz archive packaging, 3 new SkillSet endpoints |
| **Phase 3.5** | Security Fixes + Wire Protocol Spec | Name sanitization (H4), path traversal guard (H1), extended executable detection (H5), wire protocol specification |
| **Phase 3.7** | Pre-Phase 4 Hardening | RSA-2048 signature verification, semantic version constraints, PeerManager persistence, TOFU trust model |
| **Phase 3.75** | MMP Extension Infrastructure | Collision detection for core actions, extension override guards, pre-Phase 4 preparation |
| **Phase 4.pre** | Authentication + Hardening | Admin token rotation, session-based auth for P2P endpoints |
| **Phase 4A** | HestiaChain Foundation | Self-contained trust anchor SkillSet, DEE protocol (PhilosophyDeclaration, ObservationLog), chain migration (4 stages), 4 MCP tools, 77 test assertions |
| **Phase 4B** | Meeting Place Server | PlaceRouter, AgentRegistry, SkillBoard, HeartbeatManager, 6 HTTP endpoints, 2 MCP tools, 70 test assertions |

Test results: 356 passed, 0 failed (v2.0.0).

### Near-term

1. **Phase 4C: Message Relay**: E2E encrypted message relay with TTL (`/place/v1/relay/*`)
2. **Phase 4D: Federation**: Inter-Place discovery and mutual registration
3. **Ethereum Anchor**: Periodic hash anchoring to public chain (HestiaChain stages 2/3)
4. **Zero-Knowledge Proofs**: Privacy-preserving verification
5. **Web Dashboard**: Visualize skill evolution history
6. **Team Governance**: Voting system for L0 changes (see FAQ)

### Long-term Vision: Distributed KairosChain Network

A future vision for KairosChain: multiple KairosChain MCP servers communicating over the internet via public MCP protocols, autonomously evolving their knowledge while adhering to their L0 constitutions.

**Key concepts**:
- L0 Constitution as distributed governance
- Knowledge cross-pollination between specialized nodes
- Autonomous evolution within constitutional bounds
- Integration with GenomicsChain PoC/DAO

**Implementation phases**:
1. Dockerization (deployment foundation)
2. ~~HTTP/WebSocket API (remote access)~~ ✅ Streamable HTTP transport (complete)
3. ~~Inter-server communication protocol~~ ✅ MMP (Model Meeting Protocol) with P2P direct mode (complete)
4. ~~SkillSet Plugin Infrastructure~~ ✅ Layer-based governance, knowledge-only P2P exchange (complete)
5. ~~HestiaChain Meeting Place Server~~ ✅ Trust anchor + DEE protocol Meeting Place (complete, v2.0.0)
6. Distributed consensus mechanism
7. Distributed L0 governance

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
