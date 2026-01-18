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

![KairosChain Layered Architecture](docs/kairoschain_linkedin_diagram.png)

*Figure: KairosChain's legal-system-inspired layered architecture for AI skill management*

### System Overview

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

## Layered Skills Architecture

KairosChain implements a **legal-system-inspired layered architecture** for knowledge management:

| Layer | Legal Analogy | Path | Blockchain Record | Mutability |
|-------|---------------|------|-------------------|------------|
| **L0-A** | Constitution | `skills/kairos.md` | - | Read-only |
| **L0-B** | Law | `skills/kairos.rb` | Full transaction | Human approval required |
| **L1** | Ordinance | `knowledge/` | Hash reference only | Lightweight constraints |
| **L2** | Directive | `context/` | None | Free modification |

### L0: Kairos Core (`skills/`)

The foundation of KairosChain. Contains meta-rules about self-modification.

- **kairos.md**: Philosophy and principles (immutable, read-only)
- **kairos.rb**: Meta-skills in Ruby DSL (modifiable with full blockchain record)

Only these meta-skills can be placed in L0:
- `core_safety`, `evolution_rules`, `layer_awareness`, `approval_workflow`, `self_inspection`, `chain_awareness`

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

Temporary context for sessions. Same format as L1 but **no blockchain recording**.

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

### Why Layered Architecture?

1. **Not all knowledge needs the same constraints** — temporary thoughts shouldn't require blockchain records
2. **Separation of concerns** — Kairos meta-rules vs. project knowledge vs. temporary context
3. **AI autonomy with accountability** — free exploration in L2, tracked changes in L1, strict control in L0

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

## Available Tools (21 total)

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

### L1: Knowledge Tools - Hash Reference Record

| Tool | Description |
|------|-------------|
| `knowledge_list` | List all knowledge skills |
| `knowledge_get` | Get knowledge content by name |
| `knowledge_update` | Create/update/delete knowledge (hash recorded) |
| `knowledge_scripts` | List scripts in a knowledge skill |
| `knowledge_assets` | List assets in a knowledge skill |

### L2: Context Tools - No Blockchain Record

| Tool | Description |
|------|-------------|
| `context_sessions` | List all active sessions |
| `context_list` | List contexts in a session |
| `context_get` | Get context content |
| `context_save` | Save context (free modification) |
| `context_create_subdir` | Create scripts/assets/references subdir |

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
│       ├── layer_registry.rb     # Layered architecture management
│       ├── anthropic_skill_parser.rb  # YAML frontmatter + MD parser
│       ├── knowledge_provider.rb # L1 knowledge management
│       ├── context_manager.rb    # L2 context management
│       ├── kairos_chain/         # Blockchain implementation
│       │   ├── block.rb
│       │   ├── chain.rb
│       │   ├── merkle_tree.rb
│       │   └── skill_transition.rb
│       └── tools/                # MCP tools (21 total)
│           ├── skills_*.rb       # L0 tools
│           ├── knowledge_*.rb    # L1 tools
│           └── context_*.rb      # L2 tools
├── skills/                       # L0: Kairos Core
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
├── storage/
│   ├── blockchain.json           # Chain data
│   └── off_chain/                # AST diffs, reasons
├── test_local.rb                 # Local test script
└── README.md
```

## Future Roadmap

1. **Ethereum Anchor**: Periodic hash anchoring to public chain
2. **Multi-Agent Support**: Track multiple AI agents via `agent_id`
3. **Zero-Knowledge Proofs**: Privacy-preserving verification
4. **Web Dashboard**: Visualize skill evolution history
5. **Team Governance**: Voting system for L0 changes (see FAQ)

---

## FAQ

### Q: LLMはL1/L2を自動的に改変しますか？

**A:** はい、LLMはMCPツールを使って自発的に（またはユーザーの依頼で）L1/L2を改変できます。

| レイヤー | LLMによる改変 | 条件 |
|---------|---------------|------|
| **L0** (kairos.rb) | 可能だが厳格 | `evolution_enabled: true` + `approved: true`（人間承認）+ ブロックチェーン記録 |
| **L1** (knowledge/) | 可能 | ハッシュのみブロックチェーン記録、人間承認不要 |
| **L2** (context/) | 自由 | 記録なし、承認不要 |

※ `kairos.md` は読み取り専用で、LLMは改変できません。

**使用例:**
- L2: 調査中の仮説を `context_save` で一時保存
- L1: プロジェクトのコーディング規約を `knowledge_update` で永続化
- L0: メタスキルの変更を `skills_evolve` で提案（人間承認必須）

---

### Q: チーム利用の場合、APIへの拡張が必要ですか？

**A:** 現在の実装はstdio経由のローカル利用に限定されています。チーム利用には以下の選択肢があります：

| 方式 | 追加実装 | 適合規模 |
|------|----------|----------|
| **Git共有** | 不要 | 小規模チーム（2-5人） |
| **HTTP API化** | 必要 | 中規模チーム（5-20人） |
| **MCP over SSE** | 必要 | リモート接続が必要な場合 |

**Git共有（最もシンプル）:**
```
# knowledge/, skills/, data/blockchain.json をGitで管理
# 各メンバーがローカルでMCPサーバーを起動
# 変更はGit経由で同期
```

**HTTP API化が必要な場合:**
- リアルタイム同期が必要
- 認証・認可が必要
- 同時編集のコンフリクト解決が必要

---

### Q: チーム運用でkairos.rbやkairos.mdの変更に投票システムは必要ですか？

**A:** チーム規模と要件によります。

**現在の実装（単一承認者モデル）:**
```yaml
require_human_approval: true  # 1人が承認すればOK
```

**チーム運用で必要になる可能性がある機能:**

| 機能 | L0 | L1 | L2 |
|------|----|----|----| 
| 投票システム | 推奨 | オプション | 不要 |
| 定足数（Quorum） | 推奨 | - | - |
| 提案期間 | 推奨 | - | - |
| 拒否権（Veto） | 場合による | - | - |

**将来的に必要なツール（未実装）:**
```
governance_propose    - 変更提案を作成
governance_vote       - 提案に投票（賛成/反対/棄権）
governance_status     - 提案の投票状況を確認
governance_execute    - 閾値を超えた提案を実行
```

**kairos.mdの特殊性:**

`kairos.md`は「憲法」に相当するため、システム外での合意形成（GitHub Discussion等）を推奨します：

1. GitHub Issue / Discussionで提案
2. チーム全員でオフライン議論
3. 全員一致（またはスーパーマジョリティ）で合意
4. 手動でファイルを編集してコミット

---

### Q: ローカルテストの実行方法は？

**A:** 以下のコマンドでテストを実行できます：

```bash
cd KairosChain_mcp_server
ruby test_local.rb
```

テスト内容：
- Layer Registry の動作確認
- 21個のMCPツール一覧
- L1 Knowledge の読み書き
- L2 Context の読み書き
- L0 Skills DSL（6スキル）の読み込み

テスト後にアーティファクト（`context/test_session`）が作成されるので、不要なら削除してください：
```bash
rm -rf context/test_session
```

---

### Q: kairos.rbに含まれるメタスキルは何ですか？

**A:** 現在6つのメタスキルが定義されています：

| スキル | 説明 | 改変可能性 |
|--------|------|------------|
| `core_safety` | 安全性の基盤 | 不可（`deny :all`） |
| `evolution_rules` | 進化ルールの定義 | contentのみ可 |
| `layer_awareness` | レイヤー構造の認識 | contentのみ可 |
| `approval_workflow` | 承認ワークフロー | contentのみ可 |
| `self_inspection` | 自己検査能力 | contentのみ可 |
| `chain_awareness` | ブロックチェーン認識 | contentのみ可 |

詳細は `skills/kairos.rb` を参照してください。

---

## License

See [LICENSE](../LICENSE) file.

---

**Version**: 0.2.1  
**Last Updated**: 2026-01-18

> *"KairosChain answers not 'Is this result correct?' but 'How was this intelligence formed?'"*
