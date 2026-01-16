# KairosChain MCP Server

**A Meta Ledger for Recording AI Skill Evolution**

KairosChain is a Model Context Protocol (MCP) server that records the evolution of AI capabilities on a private blockchain. It combines Pure Skills design (Ruby DSL/AST) with immutable ledger technology, enabling AI agents to have auditable, evolvable, and self-referential skill definitions.

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

```
┌─────────────────────────────────────────────────────────────────┐
│                    MCP Client (Cursor / Claude Code)            │
└───────────────────────────────┬─────────────────────────────────┘
                                │ STDIO (JSON-RPC)
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    KairosChain MCP Server                        │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────────────────┐ │
│  │    Server    │ │   Protocol   │ │     Tool Registry        │ │
│  │  STDIO Loop  │ │  JSON-RPC    │ │  12+ Tools Available     │ │
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

## Setup

### Prerequisites

- Ruby 3.3+ (uses standard library only, no gems required)
- Claude Code CLI (`claude`) or Cursor IDE

### Installation

```bash
# Clone the repository
git clone https://github.com/your-repo/KairosChain_2026.git
cd KairosChain_2026/KairosChain_mcp_server

# Make executable
chmod +x bin/kairos_mcp_server

# Test basic execution
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server
```

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
# Register KairosChain MCP server
claude mcp add kairos-chain ruby /path/to/KairosChain_mcp_server/bin/kairos_mcp_server

# Example with actual path (use full path)
claude mcp add kairos-chain ruby ~/forback/github/KairosChain_2026/KairosChain_mcp_server/bin/kairos_mcp_server
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
      "command": "ruby",
      "args": ["/path/to/KairosChain_mcp_server/bin/kairos_mcp_server"],
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

```json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "ruby",
      "args": ["/path/to/KairosChain_mcp_server/bin/kairos_mcp_server"],
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
      "command": "ruby",
      "args": ["/Users/yourname/KairosChain_mcp_server/bin/kairos_mcp_server"],
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

## Testing the Setup

### 1. Basic Command Line Tests

#### Initialize Test

```bash
cd /path/to/KairosChain_mcp_server

# Send initialize request
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server

# Expected response (excerpt):
# {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":...}}
```

#### Tools List Test

```bash
# Get list of available tools
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | bin/kairos_mcp_server

# If you have jq, display only tool names
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | bin/kairos_mcp_server 2>/dev/null | jq '.result.tools[].name'
```

#### Hello World Test

```bash
# Call the hello_world tool
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hello_world","arguments":{}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# Output: Hello from KairosChain MCP Server!
```

### 2. Skills Tools Test

```bash
# Get skills list
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# Get a specific skill
echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"skills_dsl_get","arguments":{"skill_id":"core_safety"}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 3. Blockchain Tools Test

```bash
# Check blockchain status
echo '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'

# Verify chain integrity
echo '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | bin/kairos_mcp_server 2>/dev/null | jq -r '.result.content[0].text'
```

### 4. Testing with Claude Code

```bash
# Launch Claude Code
claude

# Try these prompts in Claude Code:
# "List the available KairosChain tools"
# "Run skills_dsl_list"
# "Check chain_status"
```

### 5. Testing with Cursor

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
ruby --version  # Requires 3.3+

# Check for syntax errors
ruby -c bin/kairos_mcp_server

# Verify executable permission
ls -la bin/kairos_mcp_server
chmod +x bin/kairos_mcp_server
```

#### JSON-RPC Errors

```bash
# Check stderr for error messages
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | bin/kairos_mcp_server

# Run without suppressing stderr (remove 2>/dev/null)
```

#### Cursor Connection Issues

1. Verify the path in `~/.cursor/mcp.json` is an absolute path
2. Check JSON syntax (missing/extra commas, etc.)
3. Completely quit and restart Cursor

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
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_verify","arguments":{}}}' | bin/kairos_mcp_server
```

#### 3. Backups

```bash
# Regularly backup storage/blockchain.json
cp storage/blockchain.json storage/backups/blockchain_$(date +%Y%m%d).json

# Also backup skill versions
cp -r skills/versions skills/backups/versions_$(date +%Y%m%d)
```

#### 4. Sharing Across Multiple AI Agents

Share the same `blockchain.json` to synchronize evolution history across multiple AI agents.

```json
// In ~/.cursor/mcp.json or ~/.claude.json
{
  "mcpServers": {
    "kairos-chain": {
      "command": "ruby",
      "args": ["/shared/path/KairosChain_mcp_server/bin/kairos_mcp_server"],
      "env": {
        "KAIROS_STORAGE": "/shared/storage"
      }
    }
  }
}
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

## Available Tools

### Skills Tools (Markdown)

| Tool | Description |
|------|-------------|
| `skills_list` | List all skills sections from kairos.md |
| `skills_get` | Get specific section by ID |

### Skills Tools (DSL)

| Tool | Description |
|------|-------------|
| `skills_dsl_list` | List all skills from kairos.rb |
| `skills_dsl_get` | Get skill definition by ID |
| `skills_evolve` | Propose/apply skill changes |
| `skills_rollback` | Manage version snapshots |

### Blockchain Tools

| Tool | Description |
|------|-------------|
| `chain_status` | Get blockchain status |
| `chain_record` | Record data to blockchain |
| `chain_verify` | Verify chain integrity |
| `chain_history` | View block history |

## Usage Examples

### List Available Skills

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"skills_dsl_list","arguments":{}}}' | bin/kairos_mcp_server
```

### Check Blockchain Status

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_status","arguments":{}}}' | bin/kairos_mcp_server
```

### Record a Skill Transition

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chain_record","arguments":{"logs":["Skill X modified","Reason: improved accuracy"]}}}' | bin/kairos_mcp_server
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

```
KairosChain_mcp_server/
├── bin/
│   └── kairos_mcp_server         # Executable
├── config/
│   └── safety.yml                # Security settings
├── lib/
│   └── kairos_mcp/
│       ├── server.rb             # STDIO server
│       ├── protocol.rb           # JSON-RPC handler
│       ├── kairos.rb             # Self-reference module
│       ├── safe_evolver.rb       # Evolution with safety
│       ├── kairos_chain/         # Blockchain implementation
│       │   ├── block.rb
│       │   ├── chain.rb
│       │   ├── merkle_tree.rb
│       │   └── skill_transition.rb
│       └── tools/                # MCP tools
├── skills/
│   ├── kairos.md                 # Human-readable docs
│   ├── kairos.rb                 # Executable definitions
│   ├── config.yml                # Evolution settings
│   └── versions/                 # Version snapshots
├── storage/
│   ├── blockchain.json           # Chain data
│   └── off_chain/                # AST diffs, reasons
└── README.md
```

## Future Roadmap

1. **Ethereum Anchor**: Periodic hash anchoring to public chain
2. **Multi-Agent Support**: Track multiple AI agents via `agent_id`
3. **Zero-Knowledge Proofs**: Privacy-preserving verification
4. **Web Dashboard**: Visualize skill evolution history

## License

See [LICENSE](../LICENSE) file.

---

**Version**: 0.1.0  
**Last Updated**: 2026-01-15

> *"KairosChain answers not 'Is this result correct?' but 'How was this intelligence formed?'"*
