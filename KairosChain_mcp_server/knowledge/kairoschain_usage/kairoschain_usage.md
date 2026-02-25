---
name: kairoschain_usage
description: "KairosChain tools reference, usage patterns, and evolution workflow"
version: 1.2
layer: L1
tags: [documentation, readme, usage, tools, workflow, examples]
readme_order: 3
readme_lang: en
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

## Available Tools (31 core + skill-tools)

The base installation provides 31 tools (30 + 1 HTTP-only). Additional tools can be defined via `tool` blocks in `kairos.rb` when `skill_tools_enabled: true`.

### L0-A: Skills Tools (Markdown) - Read-only

| Tool | Description |
|------|-------------|
| `skills_list` | List all skills sections from kairos.md |
| `skills_get` | Get specific section by ID |

### L0-B: Skills Tools (DSL) - Full Blockchain Record

| Tool | Description |
|------|-------------|
| `skills_dsl_list` | List all skills from kairos.rb |
| `skills_dsl_get` | Get skill definition by ID (includes Definition, Formalization Notes, and Verification Status sections) |
| `skills_evolve` | Propose/apply skill changes |
| `skills_rollback` | Manage version snapshots |

### L0-C: DSL/AST Formalization Tools

These tools operate on the structural definition layer of skills, enabling verification, decompilation, and drift detection without LLM evaluation.

| Tool | Description |
|------|-------------|
| `definition_verify` | Verify a skill's AST constraints structurally (pattern-matched, eval-free) — reports each node as satisfied/unknown/unsatisfied |
| `definition_decompile` | Reconstruct a human-readable Markdown description from a skill's AST definition |
| `definition_drift` | Detect divergence between a skill's natural-language content and its formal definition layer |
| `formalization_record` | Record a formalization decision to the blockchain (skill_id, rationale, confidence, ambiguity levels) |
| `formalization_history` | Query past formalization decisions stored on-chain for a skill or across all skills |

> **Skill-defined tools**: When `skill_tools_enabled: true`, skills with `tool` blocks in `kairos.rb` are also registered here as MCP tools.

### L0: Instructions Management - Full Blockchain Record

| Tool | Description |
|------|-------------|
| `instructions_update` | Create, update, or delete custom instruction files and switch instructions_mode (L0-level, requires human approval) |

Commands:
- `status`: Show current mode and available instruction files
- `create`: Create a new instructions file (`skills/{mode_name}.md`)
- `update`: Update existing instructions file content
- `delete`: Delete a custom instructions file (built-in files protected)
- `set_mode`: Change `instructions_mode` in config.yml

Dynamic mode resolution: Setting `instructions_mode: 'researcher'` in config.yml loads `skills/researcher.md` as the AI system prompt instructions. Built-in modes (`developer`, `user`, `none`) are preserved.

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

### MMP Meeting Tools (SkillSet: mmp)

These tools are available when the MMP (Model Meeting Protocol) SkillSet is installed and enabled. MMP enables P2P communication and knowledge exchange between KairosChain instances.

| Tool | Description |
|------|-------------|
| `meeting_connect` | Connect to a remote KairosChain peer via MMP |
| `meeting_disconnect` | Disconnect from a peer session |
| `meeting_acquire_skill` | Acquire a skill or SkillSet from a connected peer |
| `meeting_get_skill_details` | Get metadata about a peer's available skills |

MMP SkillSet also exposes HTTP endpoints via MeetingRouter (`/meeting/v1/*`):

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/meeting/v1/introduce` | GET | Self-introduction (identity, capabilities) |
| `/meeting/v1/introduce` | POST | Receive peer introduction |
| `/meeting/v1/skills` | GET | List public skills |
| `/meeting/v1/skill_details` | GET | Get skill metadata (`?skill_id=X`) |
| `/meeting/v1/skill_content` | POST | Request skill content |
| `/meeting/v1/request_skill` | POST | Submit skill request |
| `/meeting/v1/reflect` | POST | Send reflection |
| `/meeting/v1/message` | POST | Generic MMP message |
| `/meeting/v1/skillsets` | GET | List exchangeable SkillSets |
| `/meeting/v1/skillset_details` | GET | Get SkillSet metadata (`?name=X`) |
| `/meeting/v1/skillset_content` | POST | Download SkillSet archive |

> **Knowledge-only constraint**: Only non-executable content (Markdown, YAML) can be exchanged over P2P. SkillSets containing executable code (`tools/`, `lib/` with .rb, .py, .sh, etc.) must be installed via trusted channels. See the [MMP P2P User Guide](docs/KairosChain_MMP_P2P_UserGuide_20260220_en.md) for details.

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

### P2P SkillSet Exchange

```bash
# 1. Start HTTP server for P2P (on Agent A)
kairos-chain --http --port 8080

# 2. Connect from Agent B
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"meeting_connect","arguments":{"url":"http://localhost:8080","mode":"direct"}}}' | kairos-chain

# 3. List peer's available skills
curl http://localhost:8080/meeting/v1/skills

# 4. Get SkillSet details
curl "http://localhost:8080/meeting/v1/skillset_details?name=my_knowledge_set"

# 5. Download SkillSet archive
curl -X POST http://localhost:8080/meeting/v1/skillset_content \
  -H "Content-Type: application/json" \
  -d '{"name":"my_knowledge_set"}'

# 6. Install received archive
kairos-chain skillset install-archive received_package.json
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
