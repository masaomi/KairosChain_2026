---
name: kairoschain_design
description: Pure Skills design and directory structure
version: 1.0
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

## Directory Structure

### Gem Structure (installed via `gem install kairos_mcp`)

```
kairos_mcp (gem)
├── bin/
│   └── kairos_mcp_server         # Executable (in PATH after gem install)
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
└── kairos_mcp.gemspec            # Gem specification
```

### Data Directory (created by `kairos_mcp_server init`)

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
│   └── kairos_mcp_server         # Executable
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
├── kairos_mcp.gemspec            # Gem specification
├── Gemfile                       # Development dependencies
├── Rakefile                      # Build/test tasks
├── test_local.rb                 # Local test script
└── README.md
```
