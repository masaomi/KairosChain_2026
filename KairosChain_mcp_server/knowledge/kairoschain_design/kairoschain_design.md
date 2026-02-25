---
name: kairoschain_design
description: Pure Skills design and directory structure
version: 1.2
layer: L1
tags: [documentation, readme, design, architecture, directory-structure]
readme_order: 4
readme_lang: en
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

## DSL/AST Skill Formalization

KairosChain v2.1.0 introduces a **partial formalization layer** that bridges natural-language skill content and machine-verifiable structural definitions — without replacing human judgment or requiring LLM evaluation.

### Motivation

Skill content (natural language in `content` blocks) and skill behavior (Ruby code in `behavior` blocks) are semantically rich but opaque to structural analysis. The formalization layer adds an explicit **definition** layer that captures constraints, plans, tool calls, and semantic reasoning nodes in a diffable, verifiable AST.

### Three Layers of a Skill

```
┌─────────────────────────────────────────────────────────┐
│  Content Layer      (natural language, human-readable)  │
│  content <<~MD ... MD                                   │
├─────────────────────────────────────────────────────────┤
│  Definition Layer   (AST, machine-verifiable)           │
│  definition do                                          │
│    constraint :ethics_approval, required: true          │
│    node :review, type: :SemanticReasoning               │
│  end                                                    │
├─────────────────────────────────────────────────────────┤
│  Behavior Layer     (Ruby code, executable)             │
│  behavior do ... end                                    │
└─────────────────────────────────────────────────────────┘
```

### Node Types

| Node Type | Meaning | Machine-Verifiable? |
|-----------|---------|---------------------|
| `Constraint` | Invariant that must hold | ✅ Structural check |
| `Check` | Assertion to evaluate | ✅ Pattern-matched |
| `Plan` | Sequence of named steps | ✅ Step presence |
| `ToolCall` | MCP tool invocation | ✅ Command presence |
| `SemanticReasoning` | Requires human/LLM judgment | ❌ Marked as `human_required` |

### Example Definition Block

```ruby
skill :core_safety do
  version "3.0"
  title "Core Safety Rules"

  definition do
    constraint :no_destructive_ops,
      condition: "evolution_enabled == false",
      description: "Destructive operations require explicit evolution mode"
    constraint :human_approval_required,
      condition: "require_human_approval == true",
      description: "All evolution changes require human sign-off"
    node :safety_review,
      type: :SemanticReasoning,
      prompt: "Does this change maintain core safety invariants?"
  end

  content <<~MD
    ## Core Safety Invariants
    1. Evolution requires explicit enablement
    2. Human approval required by default
  MD
end
```

### Formalization Tools

| Tool | Description |
|------|-------------|
| `definition_verify` | Verify constraints against a context — reports satisfied/unknown/unsatisfied per node |
| `definition_decompile` | Reconstruct human-readable Markdown from the AST |
| `definition_drift` | Detect divergence between content and definition layers |
| `formalization_record` | Record a formalization decision on-chain (provenance) |
| `formalization_history` | Query past formalization decisions |

### Source of Truth Policy

**Ruby DSL (`.rb`) is the single authoritative source.** JSON representations are derived outputs for transport (MCP, blockchain). The direction of truth is always:

```
Ruby DSL (.rb) → AstEngine → JSON → Blockchain record
                           ↗
              Decompiler (reverse, advisory only)
```

See `docs/KairosChain_dsl_ast_source_of_truth_policy_20260225.md` for the full policy.

---

## SkillSet Plugin Architecture

SkillSets are modular, self-contained capability packages that extend KairosChain. They are managed by the SkillSetManager and follow layer-based governance.

### SkillSet Structure

```
.kairos/skillsets/{name}/
├── skillset.json              # Required: metadata and layer declaration
├── tools/                     # MCP Tool classes (Ruby)
├── lib/                       # Internal libraries
├── knowledge/                 # Knowledge files (Markdown + YAML frontmatter)
├── config/                    # Configuration templates
└── references/                # Reference materials
```

### skillset.json Schema

```json
{
  "name": "my_skillset",
  "version": "1.0.0",
  "description": "Description of the SkillSet",
  "author": "Author Name",
  "layer": "L1",
  "depends_on": [],
  "provides": ["capability_name"],
  "tool_classes": ["MyTool"],
  "config_files": ["config/my_config.yml"],
  "knowledge_dirs": ["knowledge/my_topic"]
}
```

### Layer-Based Governance

| Layer | Blockchain Recording | Approval | Typical Use |
|-------|---------------------|----------|-------------|
| **L0** | Full (all file hashes) | Human approval required | Core protocols |
| **L1** | Hash-only | Standard enable/disable | Standard SkillSets |
| **L2** | None | Free enable/disable | Community/experimental |

### MMP SkillSet (Model Meeting Protocol)

MMP is the reference SkillSet implementation that enables P2P communication between KairosChain instances.

**Key classes:**
- `MMP::Protocol` — Core protocol logic
- `MMP::Identity` — Agent identity and introduction
- `MMP::SkillExchange` — Skill acquisition workflow
- `MMP::PeerManager` — Peer tracking with persistence and TOFU trust
- `MMP::ProtocolLoader` — Dynamic protocol loading
- `MMP::ProtocolEvolution` — Protocol extension mechanism
- `MeetingRouter` — Rack-compatible HTTP router (11 endpoints)
- `MMP::Crypto` — RSA-2048 signature verification

**Security features:**
- Knowledge-only constraint: 14 executable extensions + shebang detection
- Name sanitization: `[a-zA-Z0-9][a-zA-Z0-9_-]*`, max 64 chars
- Path traversal guard: `expand_path` + `start_with?` verification
- Content hash verification: SHA-256 on package and install
- RSA signature verification with TOFU key caching

For detailed usage, see the [MMP P2P User Guide](docs/KairosChain_MMP_P2P_UserGuide_20260220_en.md).

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
